-- AI API Client for PandaVim
-- Supports OpenAI, Anthropic, and any OpenAI-compatible endpoint.
-- Supports native function-calling AND a ReAct XML fallback (see ai.react).
-- Optional debug logging of requests + responses.

local M = {}
local config = require('ai.config')
local react  = require('ai.react')
local StreamFilter = require('ai.stream_filter')

-- F2b: same allow-list as ai/react.lua. Native tool calls go through this
-- gate too, so empty/unknown tool names trigger the retry path instead of
-- producing an "Unknown tool: " card.
local VALID_TOOL_NAMES = {
  read = true, write = true, edit = true,
  bash = true, glob = true, grep = true,
}

-- Split a list of tool calls into (valid, errors). Errors are shaped like
-- ai/react.lua's parse() errors so the upstream retry path treats them the
-- same way.
local function partition_native_calls(calls)
  local valid, errs = {}, {}
  for i, tc in ipairs(calls or {}) do
    if not tc.name or tc.name == '' or not VALID_TOOL_NAMES[tc.name] then
      table.insert(errs, {
        block_index = i,
        message = string.format(
          "Unknown or empty tool name '%s'. Valid tools: read, write, edit, bash, glob, grep.",
          tostring(tc.name)),
      })
    else
      table.insert(valid, tc)
    end
  end
  return valid, errs
end

-- ── Debug log ─────────────────────────────────────────────────────────────
-- Path: ~/.local/state/pandavim/debug.log
-- Toggled via ai.client.set_debug(true/false) (called from /debug command).
local debug_enabled = false
local DEBUG_DIR  = vim.fn.stdpath('state') .. '/pandavim'
local DEBUG_PATH = DEBUG_DIR .. '/debug.log'
local MAX_DEBUG_BYTES = 10 * 1024 * 1024  -- 10 MB rotate threshold

local function debug_log(kind, payload)
  if not debug_enabled then return end
  vim.fn.mkdir(DEBUG_DIR, 'p')
  -- Rotate if too large
  local stat = vim.loop.fs_stat(DEBUG_PATH)
  if stat and stat.size > MAX_DEBUG_BYTES then
    pcall(os.rename, DEBUG_PATH, DEBUG_PATH .. '.1')
  end
  local f = io.open(DEBUG_PATH, 'a')
  if not f then return end
  local stamp = os.date('%Y-%m-%d %H:%M:%S')
  local line
  if type(payload) == 'string' then
    line = payload
  else
    local ok, enc = pcall(vim.json.encode, payload)
    line = ok and enc or tostring(payload)
  end
  f:write(string.format('[%s] [%s] %s\n', stamp, kind, line))
  f:close()
end

function M.set_debug(enabled)
  debug_enabled = enabled and true or false
end

function M.debug_path()
  return DEBUG_PATH
end

-- ── Curl arg builder ──────────────────────────────────────────────────────
local function build_curl_args(method, url, api_key, wire_format, body_json)
  local args = {
    'curl', '--silent', '--no-buffer',
    '-X', method,
    '-H', 'Content-Type: application/json',
  }
  if wire_format == 'anthropic' then
    table.insert(args, '-H')
    table.insert(args, 'x-api-key: ' .. api_key)
    table.insert(args, '-H')
    table.insert(args, 'anthropic-version: 2023-06-01')
  else
    table.insert(args, '-H')
    table.insert(args, 'Authorization: Bearer ' .. api_key)
  end
  if body_json and body_json ~= '{}' then
    table.insert(args, '-d')
    table.insert(args, body_json)
  end
  table.insert(args, url)
  return args
end

--- Non-streaming request (unchanged).
function M.request(endpoint, method, body, callback)
  local provider    = config.get_provider()
  local api_key     = config.get_api_key(provider)
  local base_url    = config.get_base_url(provider)
  local wire_format = config.get_wire_format(provider)

  if not api_key or api_key == '' then
    callback(nil, 'No API key configured for provider: ' .. provider)
    return
  end
  if not base_url or base_url == '' then
    callback(nil, 'No base URL configured for provider: ' .. provider)
    return
  end

  local url       = base_url .. endpoint
  local body_json = vim.json.encode(body)
  local args      = build_curl_args(method, url, api_key, wire_format, body_json)

  local stdout_chunks = {}
  local stderr_chunks = {}
  local done = false

  vim.fn.jobstart(args, {
    on_stdout = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          if chunk ~= '' then table.insert(stdout_chunks, chunk) end
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        for _, chunk in ipairs(data) do
          if chunk ~= '' then table.insert(stderr_chunks, chunk) end
        end
      end
    end,
    on_exit = function(_, code)
      if done then return end
      done = true
      if code ~= 0 then
        callback(nil, 'HTTP request failed (exit ' .. code .. '): ' .. table.concat(stderr_chunks, '\n'))
        return
      end
      callback({ body = table.concat(stdout_chunks, '\n') }, nil)
    end,
    stdout_buffered = false,
    stderr_buffered = false,
  })
end

--- Stream a chat completion with tool use support (native + ReAct fallback).
--
-- options:
--   model         string   — model id (default from config)
--   temperature   number   — default 0.7
--   max_tokens    number   — default 4096
--   tools         table?   — tool definitions (omitted when tool_mode='off')
--   tool_mode     string?  — 'native' | 'react' | 'off'. Default 'native'.
--   provider      string?  — override the provider (used for debug tagging)
--
-- Callbacks:
--   on_chunk(text)               — visible text delta (filter strips
--                                  <tool_use>/<think> blocks live — see
--                                  ai/stream_filter.lua)
--   on_complete()                — text-only response finished (no tool calls)
--   on_error(err)                — error occurred
--   on_usage({prompt,completion,total}) — token counts
--   on_tool_calls(tool_calls)    — model wants to call tools
--
-- Additional callbacks pulled from options (keyword-style to avoid a very long
-- positional signature):
--   options.on_thinking(text)              — accumulated <think> content (per turn)
--   options.on_malformed_tool_calls(errs,  — ReAct blocks present but failed to
--                                    raw_text)  parse; caller may retry via
--                                               ai.react.format_parse_error_for_retry()
function M.chat_completion(messages, options, on_chunk, on_complete, on_error, on_usage, on_tool_calls)
  local provider    = (options and options.provider) or config.get_provider()
  local wire_format = config.get_wire_format(provider)
  local cfg         = config.get_config()
  local model       = (options and options.model) or config.get_model()
  local temperature = (options and options.temperature) or cfg.temperature or 0.7
  local max_tokens  = (options and options.max_tokens)  or cfg.max_tokens  or 4096
  local tools       = options and options.tools
  local tool_mode   = (options and options.tool_mode) or 'native'
  -- New optional callbacks (see header doc).
  local on_thinking              = options and options.on_thinking
  local on_malformed_tool_calls  = options and options.on_malformed_tool_calls

  -- Build request body
  local endpoint, body

  if wire_format == 'anthropic' then
    endpoint = '/messages'
    local system_msg    = nil
    local user_messages = {}
    for _, m in ipairs(messages) do
      if m.role == 'system' then
        system_msg = m.content
      else
        table.insert(user_messages, m)
      end
    end
    body = {
      model       = model,
      messages    = user_messages,
      max_tokens  = max_tokens,
      temperature = temperature,
      stream      = true,
    }
    if system_msg then body.system = system_msg end
    -- Only send tools in native mode. ReAct uses text-only calls.
    if tool_mode == 'native' and tools and #tools > 0 then
      body.tools = tools
    end
  else
    endpoint = '/chat/completions'
    body = {
      model       = model,
      messages    = messages,
      temperature = temperature,
      max_tokens  = max_tokens,
      stream      = true,
    }
    if tool_mode == 'native' and tools and #tools > 0 then
      body.tools       = tools
      body.tool_choice = 'auto'
    end
  end

  local api_key  = config.get_api_key(provider)
  local base_url = config.get_base_url(provider)

  if not api_key or api_key == '' then
    if on_error then on_error('No API key for provider: ' .. provider) end
    return
  end

  local url       = base_url .. endpoint
  local body_json = vim.json.encode(body)
  local args      = build_curl_args('POST', url, api_key, wire_format, body_json)

  -- Debug: log the request (sanitized — strip Authorization header effect
  -- by not logging raw args)
  debug_log('request', {
    provider    = provider,
    model       = model,
    url         = url,
    wire_format = wire_format,
    tool_mode   = tool_mode,
    message_count = #messages,
    tools_sent  = body.tools and #body.tools or 0,
  })

  -- ── State ───────────────────────────────────────────────────────────────
  local buffer           = ''
  local completed        = false
  local errored          = false
  local last_event       = ''
  local got_sse_data     = false
  local raw_output       = {}      -- all raw stdout lines (for error dumps)
  local accumulated_text = {}      -- visible text chunks (already filtered)
  -- Per-request filter: strips <tool_use>...</tool_use> and <think>...</think>
  -- from streamed chunks before they reach the user's chat buffer. The raw
  -- text (including hidden blocks) is still available via stream_filter:raw_text().
  local stream_filter    = StreamFilter.new()

  -- Token usage
  local usage_prompt     = 0
  local usage_completion = 0

  -- Native tool-call accumulators
  local tool_call_accum = {}       -- OpenAI: {[idx] = {id,name,arguments_parts}}
  local has_tool_calls  = false
  local anth_tool_accum = {}       -- Anthropic: {[idx] = {id,name,input_json_parts}}
  local anth_has_tools  = false

  -- ── Helpers ─────────────────────────────────────────────────────────────
  local function fire_usage()
    if on_usage and (usage_prompt > 0 or usage_completion > 0) then
      on_usage({
        prompt     = usage_prompt,
        completion = usage_completion,
        total      = usage_prompt + usage_completion,
      })
    end
  end

  local function collect_native_calls_openai()
    if not has_tool_calls then return nil end
    local calls = {}
    for _, tc in pairs(tool_call_accum) do
      local args_str = table.concat(tc.arguments_parts, '')
      local ok_json, parsed_args = pcall(vim.json.decode, args_str)
      table.insert(calls, {
        id        = tc.id,
        name      = tc.name,
        arguments = ok_json and parsed_args or {},
        arguments_raw = args_str,
      })
    end
    return #calls > 0 and calls or nil
  end

  local function collect_native_calls_anthropic()
    if not anth_has_tools then return nil end
    local calls = {}
    for _, tc in pairs(anth_tool_accum) do
      local json_str = table.concat(tc.input_json_parts, '')
      local ok_json, parsed_args = pcall(vim.json.decode, json_str)
      table.insert(calls, {
        id        = tc.id,
        name      = tc.name,
        arguments = ok_json and parsed_args or {},
        arguments_raw = json_str,
      })
    end
    return #calls > 0 and calls or nil
  end

  -- Central completion handler. Checks native tool_calls first, then ReAct
  -- blocks in accumulated text (when tool_mode allows). Fires exactly ONE of:
  --   on_tool_calls(calls)  → tool loop runs
  --   on_complete()         → text-only response done
  local function do_complete()
    if completed then return end
    completed = true
    vim.schedule(function()
      fire_usage()

      -- 1. Try native tool calls (works for any mode except 'off')
      local native = (wire_format == 'anthropic')
        and collect_native_calls_anthropic()
        or  collect_native_calls_openai()
      if native and on_tool_calls then
        -- F2b: filter out empty/unknown tool names. If ALL calls are bad,
        -- route to the malformed-retry path; otherwise execute the valid ones
        -- and report the bad ones as errors-with-retry only if no valid calls.
        local valid, errs = partition_native_calls(native)
        if #valid > 0 then
          debug_log('native_tool_calls', { count = #valid, names = vim.tbl_map(function(c) return c.name end, valid) })
          on_tool_calls(valid)
          return
        end
        -- All native calls invalid → trigger retry feedback like the ReAct path
        if #errs > 0 then
          debug_log('native_tool_calls_invalid', errs)
          if on_malformed_tool_calls then
            local raw = stream_filter:raw_text() or ''
            on_malformed_tool_calls(errs, raw)
            return
          end
        end
      end

      -- Flush any trailing visible text buffered by the filter (e.g. a lone
      -- `<` at end of stream that we had been waiting to classify).
      local tail = stream_filter:flush()
      if tail ~= '' then
        table.insert(accumulated_text, tail)
        if on_chunk then on_chunk(tail) end
      end

      -- 2. Try ReAct blocks in the FULL raw text (including hidden <tool_use>
      -- blocks that were stripped from the visible chat).
      if tool_mode ~= 'off' and on_tool_calls then
        local full_text = stream_filter:raw_text()
        if react.has_blocks(full_text) then
          local calls, errs = react.parse(full_text)
          debug_log('react_tool_calls', {
            count = #calls,
            errors = #errs,
            names = vim.tbl_map(function(c) return c.name end, calls),
          })
          if #calls > 0 then
            if on_thinking and stream_filter:thinking_text() ~= '' then
              on_thinking(stream_filter:thinking_text())
            end
            on_tool_calls(calls)
            return
          end
          if #errs > 0 then
            debug_log('react_parse_errors', errs)
            -- Expose parse errors to the caller so they can trigger a retry
            -- (see ai/ui.lua run_tool_loop). Shaped like tool_calls but flagged.
            if on_malformed_tool_calls then
              on_malformed_tool_calls(errs, full_text)
              return
            end
          end
        end
      end

      -- 3. Plain text response — also surface any captured thinking
      if on_thinking and stream_filter:thinking_text() ~= '' then
        on_thinking(stream_filter:thinking_text())
      end
      debug_log('text_complete', { text_length = #table.concat(accumulated_text, '') })
      if on_complete then on_complete() end
    end)
  end

  -- Route every streamed chunk through the StreamFilter. The filter hides
  -- <tool_use> and <think> blocks from the visible chat output (they end up
  -- in stream_filter:raw_text() / :thinking_text() for later use).
  local function emit_chunk(text)
    local visible = stream_filter:feed(text)
    if visible ~= '' then
      table.insert(accumulated_text, visible)
      if on_chunk then on_chunk(visible) end
    end
  end

  -- ── jobstart ────────────────────────────────────────────────────────────
  return vim.fn.jobstart(args, {
    stdout_buffered = false,
    stderr_buffered = true,
    on_stdout = function(_, data)
      if not data then return end
      for _, raw in ipairs(data) do
        buffer = buffer .. raw .. '\n'
        if raw ~= '' then table.insert(raw_output, raw) end
      end

      local lines = vim.split(buffer, '\n', { plain = true })
      buffer = lines[#lines]
      lines[#lines] = nil

      for _, line in ipairs(lines) do
        line = vim.trim(line)
        if line:sub(1, 7) == 'event: ' then
          last_event = line:sub(8)
        elseif line:sub(1, 6) == 'data: ' then
          got_sse_data = true
          local data_str = line:sub(7)
          if data_str == '[DONE]' then
            do_complete()
          else
            local ok, parsed = pcall(vim.json.decode, data_str)
            if ok and parsed then

              if wire_format == 'anthropic' then
                -- Anthropic tool_use start
                if parsed.type == 'content_block_start' and parsed.content_block then
                  local cb = parsed.content_block
                  if cb.type == 'tool_use' then
                    local idx = parsed.index or 0
                    anth_tool_accum[idx] = { id = cb.id, name = cb.name, input_json_parts = {} }
                    anth_has_tools = true
                  end
                end
                if parsed.type == 'content_block_delta' and parsed.delta then
                  if parsed.delta.type == 'input_json_delta' then
                    local idx = parsed.index or 0
                    if anth_tool_accum[idx] then
                      table.insert(anth_tool_accum[idx].input_json_parts, parsed.delta.partial_json or '')
                    end
                  elseif parsed.delta.type == 'text_delta' then
                    local text = parsed.delta.text
                    if type(text) == 'string' and text ~= '' then emit_chunk(text) end
                  end
                end
                if parsed.type == 'message_start' and parsed.message and parsed.message.usage then
                  usage_prompt = parsed.message.usage.input_tokens or 0
                end
                if parsed.type == 'message_delta' and parsed.usage then
                  usage_completion = parsed.usage.output_tokens or 0
                end
                if last_event == 'message_stop' or parsed.type == 'message_stop' then
                  do_complete()
                end

              else
                -- OpenAI-compatible
                local choices = parsed.choices
                if choices and choices[1] then
                  local delta = choices[1].delta

                  if delta and type(delta.content) == 'string' and delta.content ~= '' then
                    emit_chunk(delta.content)
                  end

                  if delta and delta.tool_calls then
                    for _, tc_delta in ipairs(delta.tool_calls) do
                      local idx = tc_delta.index or 0
                      if not tool_call_accum[idx] then
                        tool_call_accum[idx] = {
                          id = tc_delta.id or '',
                          name = (tc_delta['function'] and tc_delta['function'].name) or '',
                          arguments_parts = {},
                        }
                        has_tool_calls = true
                      end
                      if tc_delta.id and tc_delta.id ~= '' then
                        tool_call_accum[idx].id = tc_delta.id
                      end
                      if tc_delta['function'] and tc_delta['function'].name and tc_delta['function'].name ~= '' then
                        tool_call_accum[idx].name = tc_delta['function'].name
                      end
                      if tc_delta['function'] and tc_delta['function'].arguments then
                        table.insert(tool_call_accum[idx].arguments_parts, tc_delta['function'].arguments)
                      end
                    end
                  end

                  local finish = choices[1].finish_reason
                  if finish == 'tool_calls' or finish == 'stop' then
                    do_complete()
                  end
                end
                if parsed.usage then
                  usage_prompt     = parsed.usage.prompt_tokens     or usage_prompt
                  usage_completion = parsed.usage.completion_tokens or usage_completion
                end
              end
            end
          end
        end
      end
    end,

    on_stderr = function(_, data)
      if data then
        local msg = table.concat(data, '\n'):gsub('^%s+', ''):gsub('%s+$', '')
        if msg ~= '' and on_error then
          errored = true
          debug_log('stderr', msg)
          vim.schedule(function() on_error('curl stderr: ' .. msg) end)
        end
      end
    end,

    on_exit = function(_, code)
      if code ~= 0 and not completed and not errored then
        debug_log('exit_error', 'exit code ' .. code)
        vim.schedule(function()
          if on_error then on_error('curl exited with code ' .. code) end
        end)
      elseif not completed and not errored then
        -- Curl exited 0 without us seeing SSE completion. Check for JSON error.
        vim.schedule(function()
          if not got_sse_data and #raw_output > 0 then
            local raw_body = table.concat(raw_output, '\n')
            debug_log('non_sse_response', raw_body:sub(1, 2000))
            local ok_j, parsed = pcall(vim.json.decode, raw_body)
            if ok_j and parsed and parsed.error then
              local msg = parsed.error.message or parsed.error.type or vim.json.encode(parsed.error)
              if on_error then on_error(msg) end
              return
            end
            if on_error then
              on_error('Unexpected response: ' .. raw_body:sub(1, 200))
            end
            return
          end
          do_complete()
        end)
      end
    end,
  })
end

-- ── Test exports (stable underscore-prefixed surface) ────────────────────
M._partition_native_calls = partition_native_calls
M._VALID_TOOL_NAMES       = VALID_TOOL_NAMES

return M
