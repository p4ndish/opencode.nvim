-- ai/stream_filter.lua
-- Character-stream filter that hides `<tool_use>...</tool_use>` and
-- `<think>...</think>` blocks from the visible chat while still letting the
-- rest of the plugin parse them.
--
-- Why:
--   - During streaming, our client emits chunks of assistant text. When the
--     model is in ReAct mode or is a reasoning model, those chunks contain
--     raw XML / think tags that should not show up in the chat UI.
--   - We buffer enough to recognize our specific opener tags, suppress the
--     whole block, and still keep the full raw stream for end-of-turn
--     parsing (ai.react.parse) and for the Thinking-block UI.
--
-- Usage:
--   local F = require('ai.stream_filter').new()
--   F:feed(chunk)              -> returns the *visible* portion that can
--                                 safely be appended to the chat buffer
--   F:raw_text()               -> full accumulated raw text (for react.parse)
--   F:thinking_text()          -> accumulated <think>...</think> inner content
--   F:thinking_segments()      -> list of { text, open_pos, close_pos } per block
--   F:has_unfinished_tag()     -> true if we're mid-block (waiting for closer)
--   F:current_tag_kind()       -> 'think' | 'tool_use' | nil — what block we're in
--   F:flush()                  -> emit any buffered trailing text at end of stream
--
-- The filter is stateless beyond the per-instance table, so creating a new
-- one for each stream is cheap.

local M = {}

local Filter = {}
Filter.__index = Filter

-- How many bytes of lookahead we wait for before deciding whether a raw `<`
-- is the start of one of our recognized tags. A `<` followed by this many
-- chars that don't form `<tool_use` or `<think` is safe to emit literally.
local LOOKAHEAD_BYTES = 10

-- Recognized openers.
-- Each entry: { match = 'literal start', close = '</literal>', name = 'kind' }.
-- Order matters: longer / more specific prefixes should come first.
local OPENERS = {
  { match = '<tool_use', close = '</tool_use>', name = 'tool_use' },
  { match = '<think',    close = '</think>',    name = 'think'    },
}

-- F1: Stray closer tags that may appear without a matching opener.
-- Some models (Qwen, R1-style) emit `</think>` to mark end of reasoning even
-- when the opener was already consumed/elided upstream. We strip these
-- silently along with any trailing whitespace they introduce, so the chat
-- doesn't get a leftover `</think>` line + a tall blank stripe.
local STRAY_CLOSERS = {
  '</think>',
  '</tool_use>',
}

-- Try to match a stray closer at `s[from]`. Returns the closer string on hit.
local function match_stray_closer(s, from)
  for _, c in ipairs(STRAY_CLOSERS) do
    local clen = #c
    if s:sub(from, from + clen - 1) == c then return c end
  end
  return nil
end

-- True if `s[from..]` could still grow into one of our stray closers.
-- Used to decide whether to wait or to emit `<` literally when we see the
-- start of `</`.
local function could_be_stray_closer(s, from)
  local remaining = #s - from + 1
  for _, c in ipairs(STRAY_CLOSERS) do
    local clen = #c
    local cmp_len = math.min(remaining, clen)
    if s:sub(from, from + cmp_len - 1) == c:sub(1, cmp_len) then
      return true
    end
  end
  return false
end

--- Try to match a recognized opener tag starting at `s[from]`.
-- Returns (name, close_str, open_end_inclusive) on success, nil otherwise.
-- `open_end_inclusive` is the byte index of the `>` that closes the opener.
local function match_opener(s, from)
  for _, o in ipairs(OPENERS) do
    local mlen = #o.match
    if s:sub(from, from + mlen - 1) == o.match then
      -- Found the prefix; find the closing `>` of the opening tag
      local end_pos = s:find('>', from + mlen, true)
      if end_pos then
        return o.name, o.close, end_pos
      end
      return nil  -- prefix matched but no `>` yet — wait for more chunks
    end
  end
  return nil
end

-- True if the opener-prefix MIGHT still become a recognized tag given the
-- bytes we have; false if no registered opener could possibly match.
-- Used to decide whether to wait or to emit `<` literally.
local function could_be_opener(s, from)
  local remaining = #s - from + 1
  for _, o in ipairs(OPENERS) do
    local mlen = #o.match
    local cmp_len = math.min(remaining, mlen)
    if s:sub(from, from + cmp_len - 1) == o.match:sub(1, cmp_len) then
      return true
    end
  end
  return false
end

--- Construct a new filter instance.
function M.new()
  return setmetatable({
    raw       = '',        -- full accumulated raw text so far
    emitted   = 0,         -- bytes of raw already returned to the caller
    thinking  = '',        -- concatenation of all <think> inner bodies
    think_segments = {},   -- list of { start, close_end } in raw positions
    current_tag = nil,     -- 'think' | 'tool_use' | nil (unfinished block)
  }, Filter)
end

--- Feed a raw chunk (from the API stream).
-- Returns the visible portion that appeared since the last feed().
function Filter:feed(chunk)
  -- Defensive: streams can produce vim.NIL (userdata) for empty deltas.
  if type(chunk) ~= 'string' or chunk == '' then return '' end
  self.raw = self.raw .. chunk

  local out = {}
  local i = self.emitted + 1
  local n = #self.raw

  while i <= n do
    local c = self.raw:sub(i, i)

    if c == '<' then
      -- F1: First check for a STRAY closer (e.g. </think> with no opener).
      -- Drop it silently along with any whitespace that immediately follows.
      local stray = match_stray_closer(self.raw, i)
      if stray then
        local after = i + #stray
        -- Greedily consume trailing whitespace (spaces, tabs, newlines).
        -- BUT: if we'd consume to end-of-stream, hold off in case more
        -- non-whitespace text is about to arrive. Wait for visible char or flush.
        local j = after
        while j <= n do
          local cc = self.raw:sub(j, j)
          if cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r' then
            j = j + 1
          else
            break
          end
        end
        if j > n then
          -- Reached end-of-buffer mid-trim. Flush() handles end-of-stream;
          -- here, treat what we've consumed as committed and break to wait
          -- for more chunks (so we keep stripping any further whitespace).
          i = j
          break
        end
        i = j
      else
        -- Potential opener: try to match one of our recognized tags.
        local name, close, open_end = match_opener(self.raw, i)
        if name then
          -- We have a complete opening tag. Look for its matching closer.
          local close_start, close_end = self.raw:find(close, open_end + 1, true)
          if close_start then
            -- Full block present; absorb it silently.
            if name == 'think' then
              local inner = self.raw:sub(open_end + 1, close_start - 1)
              self.thinking = self.thinking .. inner
              table.insert(self.think_segments, {
                inner_start = open_end + 1,
                inner_end   = close_start - 1,
              })
            end
            i = close_end + 1
            self.current_tag = nil
          else
            -- Opening tag present but closer not yet streamed. Stop emitting
            -- anything further until the block closes.
            self.current_tag = name
            break
          end
        else
          -- `<` was seen but no recognized opener / stray closer matches yet.
          -- If lookahead is still too short AND remainder could grow into
          -- one of our patterns, wait.
          if (could_be_opener(self.raw, i) or could_be_stray_closer(self.raw, i))
              and (n - i + 1) < LOOKAHEAD_BYTES then
            break
          end
          -- Otherwise the `<` is literal (e.g. HTML or comparison op). Emit it.
          table.insert(out, c)
          i = i + 1
        end
      end
    else
      table.insert(out, c)
      i = i + 1
    end
  end

  self.emitted = i - 1
  return table.concat(out)
end

--- Flush any trailing buffered content that is safe to emit.
-- Called at end-of-stream when we know no more bytes are coming.
-- If we are still inside an unclosed tag block, drop the content silently.
function Filter:flush()
  if self.current_tag then
    -- Unclosed tag — drop remaining buffered content (it was meant to be
    -- hidden anyway). Mark everything as emitted.
    self.emitted = #self.raw
    return ''
  end
  -- Anything left between emitted and the end is literal text (we were
  -- waiting in case a `<` turned into a real tag; it didn't).
  local tail = self.raw:sub(self.emitted + 1)
  self.emitted = #self.raw
  return tail
end

--- Full raw accumulated text (for react.parse / tool_support.detect_from_response).
function Filter:raw_text() return self.raw end

--- Concatenation of every <think> block's inner text.
function Filter:thinking_text() return self.thinking end

--- List of { inner_start, inner_end } ranges (for future advanced rendering).
function Filter:thinking_segments() return self.think_segments end

--- True if an opening tag has been seen but its closer hasn't arrived.
function Filter:has_unfinished_tag() return self.current_tag ~= nil end

--- Which tag kind is currently open ('think' | 'tool_use' | nil).
function Filter:current_tag_kind() return self.current_tag end

return M
