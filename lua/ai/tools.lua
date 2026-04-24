-- ai/tools.lua
-- Tool definitions for PandaVim AI (modelled after OpenCode + claw-code).
-- Each tool: JSON schema (sent to API) + Lua execute function.
--
-- Tools: read, write, edit, bash, glob, grep
-- Permission: read/glob/grep = auto-allow; write/edit/bash = ask-once then auto-allow
-- Trust mode: /trust toggles S.trust_mode — skips all permission prompts.

local M = {}

-- ── Tool JSON schemas (sent to the API in the tools[] array) ─────────────────

M.DEFINITIONS = {
  {
    name = 'read',
    description = [[Read a file from the local filesystem. Returns content with line numbers.
If the path is a directory, lists entries with trailing / for subdirs.
Use offset/limit for large files (default: first 2000 lines).]],
    parameters = {
      type = 'object',
      properties = {
        filePath = { type = 'string', description = 'Absolute path to the file or directory to read' },
        offset   = { type = 'integer', description = 'Line number to start from (1-indexed, default 1)' },
        limit    = { type = 'integer', description = 'Max lines to read (default 2000)' },
      },
      required = { 'filePath' },
      additionalProperties = false,
    },
  },
  {
    name = 'write',
    description = [[Write content to a file on the local filesystem. Creates parent directories if needed.
Overwrites existing files. You MUST read the file first if it exists.]],
    parameters = {
      type = 'object',
      properties = {
        filePath = { type = 'string', description = 'Absolute path to write to' },
        content  = { type = 'string', description = 'The full file content to write' },
      },
      required = { 'filePath', 'content' },
      additionalProperties = false,
    },
  },
  {
    name = 'edit',
    description = [[Perform exact string replacement in a file. The oldString must match exactly.
Use replaceAll=true to replace all occurrences. The file must exist.]],
    parameters = {
      type = 'object',
      properties = {
        filePath   = { type = 'string', description = 'Absolute path to the file' },
        oldString  = { type = 'string', description = 'The exact text to find and replace' },
        newString  = { type = 'string', description = 'The replacement text' },
        replaceAll = { type = 'boolean', description = 'Replace all occurrences (default false)' },
      },
      required = { 'filePath', 'oldString', 'newString' },
      additionalProperties = false,
    },
  },
  {
    name = 'bash',
    description = [[Execute a shell command. Returns stdout and stderr.
Use for running builds, tests, git commands, installing packages, etc.
Commands time out after 120 seconds by default.]],
    parameters = {
      type = 'object',
      properties = {
        command     = { type = 'string', description = 'The shell command to execute' },
        timeout     = { type = 'integer', description = 'Timeout in milliseconds (default 120000)' },
        description = { type = 'string', description = 'Short 5-10 word description of the command' },
      },
      required = { 'command' },
      additionalProperties = false,
    },
  },
  {
    name = 'glob',
    description = [[Find files matching a glob pattern. Returns matching paths sorted by modification time.
Supports patterns like "**/*.lua", "src/**/*.ts", etc. Limited to 100 results.]],
    parameters = {
      type = 'object',
      properties = {
        pattern = { type = 'string', description = 'The glob pattern to match' },
        path    = { type = 'string', description = 'Directory to search in (default: cwd)' },
      },
      required = { 'pattern' },
      additionalProperties = false,
    },
  },
  {
    name = 'grep',
    description = [[Search file contents using a regex pattern. Returns file paths and matching line numbers.
Uses ripgrep (rg) if available, falls back to grep. Limited to 100 results.]],
    parameters = {
      type = 'object',
      properties = {
        pattern = { type = 'string', description = 'Regex pattern to search for' },
        path    = { type = 'string', description = 'Directory to search in (default: cwd)' },
        include = { type = 'string', description = 'File pattern filter (e.g. "*.lua", "*.{ts,tsx}")' },
      },
      required = { 'pattern' },
      additionalProperties = false,
    },
  },
}

-- ── Permission levels ────────────────────────────────────────────────────────

M.PERMISSION = {
  read = 'auto',   -- always auto-allow
  glob = 'auto',   -- always auto-allow
  grep = 'auto',   -- always auto-allow
  write = 'ask',   -- ask first time, then auto-allow
  edit  = 'ask',   -- ask first time, then auto-allow
  bash  = 'ask',   -- ask first time, then auto-allow
}

-- Session-level approved tools (reset on /new)
local approved = {}

-- Session-level approved external file paths: { [abs_path] = true }
-- Reset on /new. Populated when user picks "always external" in the per-call
-- external-file permission prompt (see ui.lua run_tool_loop).
local approved_external = {}

function M.reset_approvals()
  approved = {}
  approved_external = {}
end

--- Check if a tool call is permitted (ignoring target file path).
-- Returns true if allowed, false if denied.
-- trust_mode: if true, everything is auto-allowed.
function M.is_allowed(tool_name, trust_mode)
  if trust_mode then return true end
  local perm = M.PERMISSION[tool_name]
  if perm == 'auto' then return true end
  if approved[tool_name] then return true end
  return false
end

--- Mark a tool as approved for the rest of the session.
function M.approve(tool_name)
  approved[tool_name] = true
end

--- Mark an external file path as approved for the rest of the session.
-- Used when the user picks "always external" on the external-file prompt.
function M.approve_external(abs_path)
  if abs_path and abs_path ~= '' then
    approved_external[vim.fn.fnamemodify(abs_path, ':p')] = true
  end
end

--- Check if an external path has been approved for this session.
function M.is_external_approved(abs_path)
  if not abs_path or abs_path == '' then return false end
  return approved_external[vim.fn.fnamemodify(abs_path, ':p')] == true
end

-- Extract the target file path from tool args, if any. Used by the scope
-- check. Returns nil for tools without a file-path argument (bash, glob).
function M.extract_path(tool_name, args)
  if not args or type(args) ~= 'table' then return nil end
  if tool_name == 'read' or tool_name == 'write' or tool_name == 'edit' then
    return args.filePath
  end
  if tool_name == 'grep' then return args.path end
  if tool_name == 'glob' then return args.path end
  return nil
end

--- Decide permission for a destructive tool call given its target path.
-- Returns one of:
--   'auto'      — fully auto-allowed (read-only tool, or trust mode)
--   'in_scope'  — in-scope destructive; defer to existing ask-once flow
--   'external'  — out-of-scope destructive; requires dedicated prompt
-- Caller must have scope_fn(path) -> bool that uses editor_state+context.
function M.path_permission(tool_name, args, trust_mode, scope_fn)
  if trust_mode then return 'auto' end
  -- Read-only tools: always auto-allow regardless of path scope.
  if tool_name == 'read' or tool_name == 'glob' or tool_name == 'grep' then
    return 'auto'
  end
  -- Destructive tools: check path scope.
  local path = M.extract_path(tool_name, args)
  if not path or path == '' then
    -- bash has no file path argument — always requires the standard prompt.
    return 'in_scope'
  end
  local abs = vim.fn.fnamemodify(path, ':p')
  -- Session-approved external paths are treated as in-scope.
  if approved_external[abs] then return 'in_scope' end
  if scope_fn and scope_fn(abs) then return 'in_scope' end
  return 'external'
end

-- ── Tool execution functions ─────────────────────────────────────────────────

--- Read a file or directory. Returns content with line numbers.
local function exec_read(args)
  local path   = args.filePath
  local offset = args.offset or 1
  local limit  = args.limit or 2000

  if not path or path == '' then
    return nil, 'filePath is required'
  end

  -- Resolve relative paths
  if not path:match('^/') and not path:match('^%a:') then
    path = vim.fn.getcwd() .. '/' .. path
  end

  -- Directory listing
  local stat = vim.loop.fs_stat(path)
  if not stat then
    return nil, 'Path not found: ' .. path
  end

  if stat.type == 'directory' then
    local entries = {}
    local handle = vim.loop.fs_scandir(path)
    if handle then
      while true do
        local name, ftype = vim.loop.fs_scandir_next(handle)
        if not name then break end
        if ftype == 'directory' then
          table.insert(entries, name .. '/')
        else
          table.insert(entries, name)
        end
      end
    end
    table.sort(entries)
    return table.concat(entries, '\n')
  end

  -- File reading with offset/limit
  local f = io.open(path, 'r')
  if not f then return nil, 'Cannot open file: ' .. path end

  local lines = {}
  local i = 0
  local total_bytes = 0
  local MAX_BYTES = 51200  -- 50KB cap like OpenCode

  for line in f:lines() do
    i = i + 1
    if i >= offset and i < offset + limit then
      local numbered = i .. ': ' .. line
      total_bytes = total_bytes + #numbered + 1
      if total_bytes > MAX_BYTES then
        table.insert(lines, '... (truncated at 50KB)')
        break
      end
      table.insert(lines, numbered)
    end
    if i >= offset + limit then break end
  end
  f:close()

  if #lines == 0 then
    return '(empty file or offset beyond end, ' .. i .. ' total lines)'
  end

  return table.concat(lines, '\n')
end

--- Write content to a file. Creates directories if needed.
local function exec_write(args)
  local path    = args.filePath
  local content = args.content

  if not path or path == '' then return nil, 'filePath is required' end
  if not content then return nil, 'content is required' end

  -- Resolve relative paths
  if not path:match('^/') and not path:match('^%a:') then
    path = vim.fn.getcwd() .. '/' .. path
  end

  -- Create parent directories
  local dir = vim.fn.fnamemodify(path, ':h')
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, 'p')
  end

  local f = io.open(path, 'w')
  if not f then return nil, 'Cannot write to: ' .. path end
  f:write(content)
  f:close()

  -- Reload buffer if it's open in Neovim
  local was_loaded = false
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == path then
        was_loaded = true
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd('edit!')
        end)
        break
      end
    end
  end

  -- If the file was newly created (not already open), open it in a new
  -- vertical split so the user sees it immediately.
  if not was_loaded then
    vim.schedule(function()
      -- Only open if we're not inside the sidebar (avoid disrupting chat)
      local cur_win = vim.api.nvim_get_current_win()
      local cur_buf = vim.api.nvim_win_get_buf(cur_win)
      local cur_ft = vim.api.nvim_buf_get_option(cur_buf, 'filetype') or ''
      local is_sidebar = cur_ft == 'AiChat' or cur_ft == 'AiInput' or cur_ft == 'AiTopbar'
      if is_sidebar then
        -- Focus the last editor window first, then open the file
        local last_editor = nil
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          local b = vim.api.nvim_win_get_buf(w)
          local ft = vim.api.nvim_buf_get_option(b, 'filetype') or ''
          if ft ~= 'AiChat' and ft ~= 'AiInput' and ft ~= 'AiTopbar' then
            last_editor = w
            break
          end
        end
        if last_editor and vim.api.nvim_win_is_valid(last_editor) then
          vim.api.nvim_set_current_win(last_editor)
        end
      end
      pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(path))
    end)
  end

  local line_count = select(2, content:gsub('\n', '\n')) + 1
  return 'Wrote ' .. line_count .. ' lines to ' .. path
end

--- Edit a file by exact string replacement.
local function exec_edit(args)
  local path       = args.filePath
  local old_str    = args.oldString
  local new_str    = args.newString
  local replace_all = args.replaceAll or false

  if not path or path == '' then return nil, 'filePath is required' end
  if not old_str or old_str == '' then return nil, 'oldString is required' end
  if new_str == nil then return nil, 'newString is required' end
  if old_str == new_str then return nil, 'oldString and newString must be different' end

  -- Resolve relative paths
  if not path:match('^/') and not path:match('^%a:') then
    path = vim.fn.getcwd() .. '/' .. path
  end

  local f = io.open(path, 'r')
  if not f then return nil, 'File not found: ' .. path end
  local content = f:read('*a')
  f:close()

  -- Helper: count plain-string occurrences of needle in haystack
  local function count_occurrences(haystack, needle)
    if not needle or needle == '' then return 0 end
    local n, pos = 0, 1
    while true do
      local s, e = haystack:find(needle, pos, true)
      if not s then break end
      n = n + 1
      pos = e + 1
    end
    return n
  end

  -- Check if oldString exists in the file
  local pre_count = count_occurrences(content, old_str)

  if pre_count == 0 then
    return nil, 'oldString not found in file'
  end

  if pre_count > 1 and not replace_all then
    return nil, 'Found ' .. pre_count .. ' matches. Use replaceAll=true to replace all, or provide more context in oldString.'
  end

  -- Perform replacement.
  -- CRITICAL: do NOT chain `:gsub('%%','%%%%')` inline as a gsub's `repl`
  -- argument — gsub returns TWO values (string, count) and the count gets
  -- passed as the outer gsub's `n` (max-replacements) limit. If new_str has
  -- no `%` characters, that's `n = 0` → zero replacements → silent no-op.
  local new_content
  if replace_all then
    local escaped_repl = new_str:gsub('%%', '%%%%')  -- only the string value
    new_content = content:gsub(vim.pesc(old_str), escaped_repl)
  else
    local s, e = content:find(old_str, 1, true)
    new_content = content:sub(1, s - 1) .. new_str .. content:sub(e + 1)
  end

  -- Post-write verification: cross-check the replacement actually happened.
  -- This catches future regressions of the Lua gsub-return-value trap above.
  local expected_replacements = replace_all and pre_count or 1
  local post_count = count_occurrences(new_content, old_str)
  -- Only meaningful when old_str and new_str don't overlap; for non-overlapping
  -- tokens (the common case), post_count should be pre_count - expected.
  -- When new_str CONTAINS old_str (e.g. rename "foo" to "foo_bar"), every
  -- replacement re-introduces the token. Handle that case by also counting
  -- new_str occurrences in new_content and requiring growth.
  local old_in_new = count_occurrences(new_str, old_str)
  if old_in_new == 0 then
    -- Simple case: old_str disappears after replacement
    local actual = pre_count - post_count
    if actual ~= expected_replacements then
      return nil, string.format(
        'Edit verification failed: expected %d replacement(s), got %d. '
          .. 'File left unchanged.',
        expected_replacements, actual)
    end
  else
    -- Overlap case: expect post_count >= old_in_new * expected_replacements
    if post_count < (old_in_new * expected_replacements) then
      return nil, 'Edit verification failed (overlap case).'
    end
  end

  local fw = io.open(path, 'w')
  if not fw then return nil, 'Cannot write to: ' .. path end
  fw:write(new_content)
  fw:close()

  -- Reload buffer if open
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name == path then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd('edit!')
        end)
        break
      end
    end
  end

  return 'Replaced ' .. expected_replacements .. ' occurrence(s) in ' .. path
end

--- Execute a shell command. Returns stdout + stderr.
local function exec_bash(args)
  local command = args.command
  local timeout = args.timeout or 120000

  if not command or command == '' then return nil, 'command is required' end

  -- Use vim.fn.system for synchronous execution (simpler, blocks briefly)
  -- For long-running commands, this is acceptable since the tool loop is async
  local output = vim.fn.system({ 'bash', '-c', command })
  local exit_code = vim.v.shell_error

  local result = output or ''
  -- Truncate long output (50KB / 2000 lines like OpenCode)
  local lines = vim.split(result, '\n', { plain = true })
  if #lines > 2000 then
    result = table.concat({ unpack(lines, 1, 2000) }, '\n')
      .. '\n... (output truncated at 2000 lines)'
  end
  if #result > 51200 then
    result = result:sub(1, 51200) .. '\n... (output truncated at 50KB)'
  end

  if exit_code ~= 0 then
    return result .. '\n[exit code: ' .. exit_code .. ']'
  end

  return result
end

--- Find files matching a glob pattern.
local function exec_glob(args)
  local pattern = args.pattern
  local search_path = args.path or vim.fn.getcwd()

  if not pattern or pattern == '' then return nil, 'pattern is required' end

  -- Use fd if available, fallback to find
  local cmd
  if vim.fn.executable('fd') == 1 then
    cmd = 'fd --glob "' .. pattern .. '" "' .. search_path .. '" --max-results 100 2>/dev/null'
  elseif vim.fn.executable('find') == 1 then
    cmd = 'find "' .. search_path .. '" -name "' .. pattern .. '" -maxdepth 10 2>/dev/null | head -100'
  else
    -- Fallback to vim.fn.glob
    local results = vim.fn.glob(search_path .. '/' .. pattern, false, true)
    if #results > 100 then results = { unpack(results, 1, 100) } end
    return #results > 0 and table.concat(results, '\n') or '(no matches)'
  end

  local output = vim.fn.system(cmd)
  if vim.trim(output) == '' then return '(no matches)' end
  return vim.trim(output)
end

--- Search file contents with regex.
local function exec_grep(args)
  local pattern = args.pattern
  local search_path = args.path or vim.fn.getcwd()
  local include = args.include

  if not pattern or pattern == '' then return nil, 'pattern is required' end

  local cmd
  if vim.fn.executable('rg') == 1 then
    cmd = 'rg --line-number --no-heading --max-count 5 --max-filesize 1M'
    if include then cmd = cmd .. ' --glob "' .. include .. '"' end
    cmd = cmd .. ' "' .. pattern:gsub('"', '\\"') .. '" "' .. search_path .. '" 2>/dev/null | head -100'
  else
    cmd = 'grep -rn'
    if include then cmd = cmd .. ' --include="' .. include .. '"' end
    cmd = cmd .. ' "' .. pattern:gsub('"', '\\"') .. '" "' .. search_path .. '" 2>/dev/null | head -100'
  end

  local output = vim.fn.system(cmd)
  if vim.trim(output) == '' then return '(no matches)' end
  return vim.trim(output)
end

-- ── Dispatch ─────────────────────────────────────────────────────────────────

local EXECUTORS = {
  read  = exec_read,
  write = exec_write,
  edit  = exec_edit,
  bash  = exec_bash,
  glob  = exec_glob,
  grep  = exec_grep,
}

--- Execute a tool by name with the given arguments.
-- Returns (result_string, nil) on success, or (nil, error_string) on failure.
function M.execute(tool_name, args)
  local executor = EXECUTORS[tool_name]
  if not executor then
    return nil, 'Unknown tool: ' .. tostring(tool_name)
  end
  local ok, result, err = pcall(executor, args)
  if not ok then
    return nil, 'Tool execution error: ' .. tostring(result)
  end
  return result, err
end

--- Get tool definitions formatted for the API.
-- OpenAI format: [{type:"function", function:{name, description, parameters}}]
-- Anthropic format: [{name, description, input_schema}]
function M.get_api_tools(wire_format)
  local tools = {}
  for _, def in ipairs(M.DEFINITIONS) do
    if wire_format == 'anthropic' then
      table.insert(tools, {
        name         = def.name,
        description  = def.description,
        input_schema = def.parameters,
      })
    else
      table.insert(tools, {
        type = 'function',
        ['function'] = {
          name        = def.name,
          description = def.description,
          parameters  = def.parameters,
        },
      })
    end
  end
  return tools
end

--- Get a short human-readable summary for a tool call (for chat display).
function M.format_tool_call(tool_name, args)
  if tool_name == 'read' then
    return 'Reading ' .. (args.filePath or '?')
  elseif tool_name == 'write' then
    local lines = args.content and (select(2, args.content:gsub('\n', '\n')) + 1) or 0
    return 'Writing ' .. lines .. ' lines to ' .. (args.filePath or '?')
  elseif tool_name == 'edit' then
    return 'Editing ' .. (args.filePath or '?')
  elseif tool_name == 'bash' then
    local cmd = args.command or '?'
    if #cmd > 60 then cmd = cmd:sub(1, 57) .. '...' end
    return 'Running: ' .. cmd
  elseif tool_name == 'glob' then
    return 'Finding files: ' .. (args.pattern or '?')
  elseif tool_name == 'grep' then
    return 'Searching: ' .. (args.pattern or '?')
  end
  return tool_name .. '(...)'
end

return M
