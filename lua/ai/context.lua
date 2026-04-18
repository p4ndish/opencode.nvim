-- Context file management for PandaVim AI
-- Handles attaching files to the conversation and building system context blocks

local M = {}

-- ── State ──────────────────────────────────────────────────────────────────

-- Each entry: { path = string, lines = string[], label = string }
local attached_files = {}

-- Listeners notified when context changes (used to refresh the context pane)
local listeners = {}

-- ── Internal helpers ───────────────────────────────────────────────────────

local function notify_listeners()
  for _, fn in ipairs(listeners) do
    pcall(fn)
  end
end

--- Derive a short display label from a full path
-- Shows at most 2 path components: "dir/file.lua"
local function make_label(path)
  local parts = vim.split(path, '/', { plain = true })
  if #parts >= 2 then
    return parts[#parts - 1] .. '/' .. parts[#parts]
  end
  return parts[#parts] or path
end

--- Detect filetype from path extension (for code-fence language tag)
local function lang_from_path(path)
  local ext = path:match('%.([^%.]+)$') or ''
  local map = {
    lua = 'lua', py = 'python', ts = 'typescript', tsx = 'typescriptreact',
    js = 'javascript', jsx = 'javascriptreact', go = 'go', rs = 'rust',
    c = 'c', cpp = 'cpp', h = 'c', java = 'java', rb = 'ruby',
    sh = 'bash', zsh = 'bash', bash = 'bash', md = 'markdown',
    json = 'json', yaml = 'yaml', yml = 'yaml', toml = 'toml',
    html = 'html', css = 'css', scss = 'scss', dart = 'dart',
  }
  return map[ext] or ext
end

-- ── Public API ─────────────────────────────────────────────────────────────

--- Register a callback called whenever the context changes
function M.add_listener(fn)
  table.insert(listeners, fn)
end

--- Attach a file to the context.
-- If the file is already attached, this is a silent no-op (matches OpenCode's add() guard).
-- @param path string: absolute or relative path
-- @return boolean, string: success, error_message
function M.add_file(path)
  -- Resolve to absolute path
  local abs = vim.fn.fnamemodify(path, ':p')

  -- Dedup guard: already attached → silent no-op, no listener notification
  for _, f in ipairs(attached_files) do
    if f.path == abs then return true, nil end
  end

  -- Check file exists and is readable
  if vim.fn.filereadable(abs) == 0 then
    return false, 'File not readable: ' .. path
  end

  -- Check size limit (200 KB) to avoid massive prompts
  local size = vim.fn.getfsize(abs)
  if size > 200 * 1024 then
    return false, 'File too large (> 200 KB): ' .. path
  end

  local lines = vim.fn.readfile(abs)
  table.insert(attached_files, {
    path  = abs,
    label = make_label(abs),
    lang  = lang_from_path(abs),
    lines = lines,
  })

  notify_listeners()
  return true, nil
end

--- Remove a file from context by absolute path
function M.remove_file(path)
  local abs = vim.fn.fnamemodify(path, ':p')
  for i, f in ipairs(attached_files) do
    if f.path == abs then
      table.remove(attached_files, i)
      notify_listeners()
      return
    end
  end
end

--- Clear all attached files
function M.clear()
  attached_files = {}
  notify_listeners()
end

--- Return list of attached file entries (read-only view)
function M.get_files()
  return attached_files
end

--- Return the number of attached files
function M.count()
  return #attached_files
end

--- Build a system-context string to prepend to the AI conversation.
-- Returns nil if no files are attached.
-- @return string|nil
function M.build_system_context()
  if #attached_files == 0 then return nil end

  local parts = { '## Attached Files\n' }
  for _, f in ipairs(attached_files) do
    table.insert(parts, string.format('### %s\n', f.label))
    table.insert(parts, string.format('```%s\n', f.lang))
    table.insert(parts, table.concat(f.lines, '\n'))
    table.insert(parts, '\n```\n')
  end

  return table.concat(parts, '')
end

--- Build the messages array to send to the API, prepending context if present.
-- @param conversation_messages table: [{role, content}]
-- @param system_prompt string: base system prompt from config
-- @return table: messages array ready for the API
function M.build_messages(conversation_messages, system_prompt)
  local ctx = M.build_system_context()
  local full_system = system_prompt or ''
  if ctx then
    full_system = full_system .. '\n\n' .. ctx
  end

  local messages = {}
  if full_system ~= '' then
    table.insert(messages, { role = 'system', content = full_system })
  end
  for _, m in ipairs(conversation_messages) do
    -- If the message carries an api_content variant (e.g. user messages
    -- augmented with <editor_state> by ai/ui.lua), send that to the API
    -- while ai/ui.lua's chat buffer continues to show the clean `content`.
    -- Tool-call messages and assistant messages keep their original shape.
    if m.api_content and m.role == 'user' then
      table.insert(messages, {
        role    = 'user',
        content = m.api_content,
      })
    else
      table.insert(messages, m)
    end
  end
  return messages
end

return M
