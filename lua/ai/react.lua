-- ai/react.lua
-- ReAct-style tool calling for models that don't support native function calls.
-- Parses <tool_use><name>X</name><arguments>{...}</arguments></tool_use> blocks
-- from an assistant text response and returns them in the same format as the
-- native tool_calls callback so the tool loop can handle them uniformly.
--
-- Why: Many local / hosted open-weight models (Qwen proxies, Ollama, older
-- Llama deployments) silently drop the OpenAI `tools[]` field. Giving them
-- instructions to emit <tool_use> XML instead makes tool calling work
-- reliably across any provider that can echo structured text.

local M = {}

-- ── Instructions appended to system prompt when tool_mode == 'react' ──────
M.INSTRUCTIONS = [[
# Tool Calling (ReAct Fallback Mode)

This provider does not support native function calling. To use tools, emit
one or more `<tool_use>` XML blocks in your response. The system parses these
blocks, executes the tools, and returns results to you so you can continue.

## Format

<tool_use>
  <name>TOOL_NAME</name>
  <arguments>JSON_OBJECT</arguments>
</tool_use>

- `TOOL_NAME` must be exactly one of: read, write, edit, bash, glob, grep.
- `JSON_OBJECT` must be a single valid JSON object matching the tool schema.
- After emitting `</tool_use>`, stop generating. You may emit multiple
  `<tool_use>` blocks in one turn when the calls are independent (they are
  executed in order before you continue).
- Do NOT wrap the block in a ```xml``` code fence. The outer brackets must
  be the raw `<tool_use>` characters.

## Examples

User: create hello.py with a hello world function
<tool_use>
  <name>write</name>
  <arguments>{"filePath": "hello.py", "content": "def hello():\n    print(\"Hello, world!\")\n\nhello()\n"}</arguments>
</tool_use>

User: what's in my config?
<tool_use>
  <name>read</name>
  <arguments>{"filePath": "/home/user/.config/nvim/init.lua"}</arguments>
</tool_use>

User: find all lua files
<tool_use>
  <name>glob</name>
  <arguments>{"pattern": "**/*.lua"}</arguments>
</tool_use>

## Rules

1. USE the tools whenever the user asks for file/shell operations. Do not
   emit a code block as a "suggested solution" — emit a <tool_use> block to
   actually apply it.
2. Paths must be absolute when possible. Resolve relative paths against the
   working directory shown in the <env> block above.
3. For destructive or system-changing bash commands (rm, install, git reset),
   briefly explain what the command does before emitting the <tool_use>.
4. After tool results come back, either emit more <tool_use> blocks or give
   the final textual answer to the user. Do not re-emit the same tool call
   unless retrying with different arguments.
]]

-- ── XML parser ────────────────────────────────────────────────────────────
-- Parses <tool_use>...</tool_use> blocks from a text response.
-- Tolerant of whitespace and different attribute orderings.
-- Returns a list: { { id, name, arguments, arguments_raw }, ... }
--
-- ID generation: since ReAct has no natural ID, we synthesize unique IDs
-- per call (`react_1`, `react_2`, ...) within a single parse.

-- Find tool_use blocks and yield (start_byte, end_byte, inner) for each.
-- Uses an iterator so strip() can reuse positions without reparsing.
local function iter_blocks(text)
  local pos = 1
  return function()
    if pos > #text then return nil end
    local bs, be = text:find('<tool_use[^>]*>', pos, false)
    if not bs then return nil end
    -- Support both <tool_use> and <tool_use foo="bar">
    local es, ee = text:find('</tool_use>', be + 1, false)
    if not es then return nil end
    local inner = text:sub(be + 1, es - 1)
    pos = ee + 1
    return bs, ee, inner
  end
end

-- Parse a single block's inner text into {name, arguments_raw}.
local function parse_inner(inner)
  local name = inner:match('<name>%s*(.-)%s*</name>')
  local args_raw = inner:match('<arguments>%s*(.-)%s*</arguments>')
  if not name or not args_raw then
    return nil, 'Missing <name> or <arguments> in tool_use block'
  end
  name = vim.trim(name)
  args_raw = vim.trim(args_raw)
  if name == '' then return nil, 'Empty tool name in tool_use block' end
  return name, args_raw
end

-- F2: allow-list of valid tool names. Anything else routes to errors so the
-- model gets retry feedback instead of us trying to execute an unknown tool.
local VALID_TOOL_NAMES = {
  read = true, write = true, edit = true,
  bash = true, glob = true, grep = true,
}

--- Parse all <tool_use> blocks in a text response.
-- @param text string
-- @return table list of { id, name, arguments (table), arguments_raw (string) }
-- @return table list of parse errors { { block_index, message } } (may be empty)
function M.parse(text)
  if not text or text == '' then return {}, {} end
  local calls = {}
  local errors = {}
  local idx = 0
  for _, _, inner in iter_blocks(text) do
    idx = idx + 1
    local name, args_raw = parse_inner(inner)
    if not name then
      table.insert(errors, { block_index = idx, message = args_raw })
    elseif not VALID_TOOL_NAMES[name] then
      -- F2: empty / unknown tool name → route to retry feedback
      table.insert(errors, {
        block_index = idx,
        message = string.format(
          "Unknown or empty tool name '%s'. Valid tools: read, write, edit, bash, glob, grep.",
          name),
      })
    else
      local ok_j, parsed = pcall(vim.json.decode, args_raw)
      if not ok_j or type(parsed) ~= 'table' then
        table.insert(errors, {
          block_index = idx,
          message = 'Invalid JSON in <arguments>: ' .. (args_raw:sub(1, 120)),
        })
      else
        table.insert(calls, {
          id            = 'react_' .. idx,
          name          = name,
          arguments     = parsed,
          arguments_raw = args_raw,
        })
      end
    end
  end
  return calls, errors
end

--- Return `text` with every <tool_use>...</tool_use> block removed.
-- Used to clean the assistant response before display so the user doesn't
-- see the raw XML (the executed tool calls are shown separately).
-- Preserves surrounding text and collapses multiple blank lines that result
-- from removal.
function M.strip(text)
  if not text or text == '' then return text or '' end
  local out = {}
  local last = 1
  for bs, ee in iter_blocks(text) do
    if bs > last then
      table.insert(out, text:sub(last, bs - 1))
    end
    last = ee + 1
  end
  if last <= #text then
    table.insert(out, text:sub(last))
  end
  local result = table.concat(out)
  -- Collapse 3+ consecutive newlines into 2
  result = result:gsub('\n\n\n+', '\n\n')
  -- Trim leading / trailing whitespace
  result = result:gsub('^%s+', ''):gsub('%s+$', '')
  return result
end

--- Quick check: does text contain any <tool_use> block?
function M.has_blocks(text)
  if not text or text == '' then return false end
  return text:find('<tool_use[^>]*>', 1, false) ~= nil
end

--- Format a parse-error list as a message to feed back to the model so it
-- can retry the tool call with valid JSON. Mirrors the pattern Claude Code /
-- Cursor use ("Your last tool call failed to parse: <reason>. Please retry").
-- Returns a single user-role message string (not a table — caller wraps).
function M.format_parse_error_for_retry(errs, raw_text)
  local parts = {
    'Your previous response contained <tool_use> blocks that failed to parse.',
    '',
    'Issues:',
  }
  for _, e in ipairs(errs or {}) do
    table.insert(parts, string.format('  - Block %d: %s',
      e.block_index or 0, e.message or 'unknown'))
  end
  table.insert(parts, '')
  table.insert(parts, 'Please emit a SINGLE valid <tool_use> block with '
    .. 'a strict JSON object in <arguments>. Example:')
  table.insert(parts, '')
  table.insert(parts, '<tool_use>')
  table.insert(parts, '  <name>write</name>')
  table.insert(parts, '  <arguments>{"filePath": "/abs/path.py", "content": "code here"}</arguments>')
  table.insert(parts, '</tool_use>')
  table.insert(parts, '')
  table.insert(parts, 'Do NOT wrap the block in a code fence. Do NOT add extra keys. '
    .. 'Emit only the corrected tool_use block — no other text before or after.')
  return table.concat(parts, '\n')
end

return M
