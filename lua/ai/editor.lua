-- ai/editor.lua
-- Captures the user's Neovim editor state and formats it for LLM consumption.
-- Mirrors how Cursor / Windsurf / Copilot inject per-turn editor context.
--
-- Capture scope (chosen by the user):
--   - Active file  + language  + total line count
--   - Cursor line + column
--   - Visual selection (if present in origin buffer's last-visual marks)
--   - Open buffers (real files only — skip terminal / help / quickfix / nofile / our sidebar)
--   - cwd
--
-- Token expansion: @current @buffer @file @selection @sel @buffers @project @cursor
--
-- Scope check: path_in_scope() tells the tool-call permission layer whether
-- a target file is inside the user's editor scope (active / open / attached)
-- so we know when to apply the "external file" permission prompt.

local M = {}

-- Filetypes / buftypes that should never count as "open buffers" from the
-- user's editing perspective.
local SKIP_BUFTYPES  = { nofile = true, terminal = true, help = true,
                         quickfix = true, prompt = true, nowrite = true }
local SKIP_FILETYPES = { AiChat = true, AiTopbar = true, AiInput = true,
                         ['ai-chat'] = true, ['ai-input'] = true, ['ai-topbar'] = true,
                         NvimTree = true, neo__tree = true, ['neo-tree'] = true,
                         TelescopePrompt = true, lazy = true, mason = true,
                         help = true }

-- Max bytes for a captured selection (truncate long selections)
local MAX_SELECTION_BYTES = 8192
-- Max number of open buffers to list
local MAX_OPEN_BUFFERS    = 16
-- Max number of files listed from @project
local MAX_PROJECT_FILES   = 100

-- ── Utilities ─────────────────────────────────────────────────────────────

local function is_sidebar_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return true end
  local ok, ft = pcall(vim.api.nvim_buf_get_option, bufnr, 'filetype')
  if ok and ft and SKIP_FILETYPES[ft] then return true end
  local ok2, bt = pcall(vim.api.nvim_buf_get_option, bufnr, 'buftype')
  if ok2 and bt and SKIP_BUFTYPES[bt] then return true end
  return false
end

local function abs_path(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if not name or name == '' then return nil end
  return vim.fn.fnamemodify(name, ':p')
end

local function get_buf_filetype(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return '' end
  local ok, ft = pcall(vim.api.nvim_buf_get_option, bufnr, 'filetype')
  return ok and (ft or '') or ''
end

local function line_count(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return 0 end
  return vim.api.nvim_buf_line_count(bufnr)
end

-- Capture the last visual selection in `bufnr` using the '< and '> marks.
-- Returns { start_line, end_line, text } or nil if no valid selection exists.
local function capture_selection(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  -- vim.fn.getpos returns { bufnum, lnum, col, off } using the current buffer.
  -- To read another buffer's marks we need to switch into it transiently.
  local ok, s_line, e_line = pcall(function()
    local sp = vim.api.nvim_buf_get_mark(bufnr, '<')
    local ep = vim.api.nvim_buf_get_mark(bufnr, '>')
    return sp, ep
  end)
  if not ok then return nil end
  local sp, ep = s_line, e_line
  if not sp or not ep then return nil end
  if not sp[1] or not ep[1] or sp[1] == 0 or ep[1] == 0 then return nil end
  local s = math.min(sp[1], ep[1])
  local e = math.max(sp[1], ep[1])
  if s < 1 or e < 1 or e < s then return nil end

  -- Bounds check against actual line count
  local lc = line_count(bufnr)
  if s > lc or e > lc then return nil end
  if s == e and sp[2] == ep[2] then return nil end  -- single char, treat as no-selection

  local lines = vim.api.nvim_buf_get_lines(bufnr, s - 1, e, false)
  local text  = table.concat(lines, '\n')
  if #text > MAX_SELECTION_BYTES then
    text = text:sub(1, MAX_SELECTION_BYTES) .. '\n... (selection truncated)'
  end
  if text == '' then return nil end

  return { start_line = s, end_line = e, text = text }
end

-- List all loaded non-sidebar buffers that correspond to real files.
-- Returns an array of { path, bufnr, is_active }.
local function list_open_buffers(active_path)
  local out = {}
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) and not is_sidebar_buf(b) then
      local p = abs_path(b)
      if p then
        table.insert(out, { path = p, bufnr = b, is_active = (p == active_path) })
      end
    end
    if #out >= MAX_OPEN_BUFFERS then break end
  end
  return out
end

-- ── Public: capture ───────────────────────────────────────────────────────

--- Capture the current editor state.
-- @param opts table|nil
--   opts.origin_buf integer? — preferred "active" buffer (the one the user
--                               was on before opening the sidebar). If omitted,
--                               falls back to the most recently-visited non-
--                               sidebar buffer or the current buffer.
-- @return table state (see module header for fields)
function M.capture(opts)
  opts = opts or {}
  local origin_buf = opts.origin_buf

  -- Validate origin_buf; if it's a sidebar buffer, try to find a better one
  if origin_buf and (not vim.api.nvim_buf_is_valid(origin_buf) or is_sidebar_buf(origin_buf)) then
    origin_buf = nil
  end

  -- Fallback: the buffer in the previous window (before we opened the sidebar)
  if not origin_buf then
    local cur_buf = vim.api.nvim_get_current_buf()
    if not is_sidebar_buf(cur_buf) then
      origin_buf = cur_buf
    end
  end

  -- Fallback 2: scan buffer list for the first real file
  if not origin_buf then
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(b) and not is_sidebar_buf(b) and abs_path(b) then
        origin_buf = b
        break
      end
    end
  end

  local active_file  = abs_path(origin_buf)
  local active_lang  = origin_buf and get_buf_filetype(origin_buf) or ''
  local active_lines = origin_buf and line_count(origin_buf) or 0

  -- Cursor position (only meaningful if origin_buf has a window showing it)
  local cursor_line, cursor_col = nil, nil
  if origin_buf then
    -- Find a window displaying origin_buf
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == origin_buf then
        local ok, pos = pcall(vim.api.nvim_win_get_cursor, w)
        if ok and pos then
          cursor_line = pos[1]
          cursor_col  = pos[2] + 1  -- 0-indexed col → 1-indexed
        end
        break
      end
    end
  end

  -- Visual selection from the origin buffer's marks
  local sel = origin_buf and capture_selection(origin_buf) or nil
  local selection_text, selection_range = nil, nil
  if sel then
    selection_text  = sel.text
    selection_range = { start_line = sel.start_line, end_line = sel.end_line,
                        file = active_file }
  end

  return {
    active_file     = active_file,
    active_lang     = active_lang,
    active_lines    = active_lines,
    cursor_line     = cursor_line,
    cursor_col      = cursor_col,
    selection_text  = selection_text,
    selection_range = selection_range,
    open_buffers    = list_open_buffers(active_file),
    cwd             = vim.fn.getcwd(),
    origin_buf      = origin_buf,
  }
end

-- ── Public: format_block ──────────────────────────────────────────────────

--- Render the state as an XML-like block to prepend to the user message.
-- @param state table (from M.capture)
-- @return string  (empty string if state has no active file AND no buffers)
function M.format_block(state)
  if not state then return '' end
  -- If we have literally nothing useful, skip the block entirely
  if not state.active_file and #(state.open_buffers or {}) == 0 then
    return ''
  end

  local lines = { '<editor_state>' }

  if state.active_file then
    table.insert(lines, '  <active_buffer>')
    table.insert(lines, '    Path: ' .. state.active_file)
    if state.active_lang and state.active_lang ~= '' then
      table.insert(lines, '    Language: ' .. state.active_lang)
    end
    if state.active_lines and state.active_lines > 0 then
      table.insert(lines, '    Total lines: ' .. state.active_lines)
    end
    if state.cursor_line then
      local cpos = 'line ' .. state.cursor_line
      if state.cursor_col then cpos = cpos .. ', col ' .. state.cursor_col end
      table.insert(lines, '    Cursor: ' .. cpos)
    end
    table.insert(lines, '  </active_buffer>')
  end

  if state.open_buffers and #state.open_buffers > 0 then
    table.insert(lines, '  <open_buffers>')
    for _, b in ipairs(state.open_buffers) do
      local suffix = b.is_active and ' (active)' or ''
      table.insert(lines, '    ' .. b.path .. suffix)
    end
    table.insert(lines, '  </open_buffers>')
  end

  if state.selection_text and state.selection_range then
    local sr = state.selection_range
    table.insert(lines, string.format(
      '  <selection file="%s" lines="%d-%d">',
      sr.file or '?', sr.start_line or 0, sr.end_line or 0))
    for _, l in ipairs(vim.split(state.selection_text, '\n', { plain = true })) do
      table.insert(lines, '    ' .. l)
    end
    table.insert(lines, '  </selection>')
  end

  if state.cwd and state.cwd ~= '' then
    table.insert(lines, '  <cwd>' .. state.cwd .. '</cwd>')
  end

  table.insert(lines, '</editor_state>')
  return table.concat(lines, '\n')
end

-- ── Public: get_active_file ───────────────────────────────────────────────

--- Return just the active file path (for footer display).
function M.get_active_file(state)
  return state and state.active_file or nil
end

--- Short display name for UI chips: "test.py" or "test.py:42".
function M.short_label(state)
  if not state or not state.active_file then return nil end
  local short = vim.fn.fnamemodify(state.active_file, ':t')
  if state.cursor_line then
    return short .. ':' .. state.cursor_line
  end
  return short
end

--- Short display for a selection: "sel L10-15".
function M.selection_label(state)
  if not state or not state.selection_range then return nil end
  local sr = state.selection_range
  if sr.start_line == sr.end_line then
    return 'sel L' .. sr.start_line
  end
  return 'sel L' .. sr.start_line .. '-' .. sr.end_line
end

-- ── Public: expand_tokens ─────────────────────────────────────────────────
-- Replaces @current / @buffer / @file / @selection / @sel / @buffers /
-- @project / @cursor in `text`.
--
-- Returns (expanded_text, files_to_attach).
--   expanded_text   — the user text with tokens replaced inline
--   files_to_attach — list of absolute paths the caller should attach to
--                     context (for @current / @buffer / @file / @cursor).

local function short_project_tree(cwd)
  -- Use glob to gather up to MAX_PROJECT_FILES paths relative to cwd.
  local files = vim.fn.globpath(cwd, '**/*', false, true)
  if type(files) ~= 'table' then return '(could not list project)' end
  local out = {}
  for i, f in ipairs(files) do
    if i > MAX_PROJECT_FILES then
      table.insert(out, '... (' .. (#files - MAX_PROJECT_FILES) .. ' more)')
      break
    end
    local stat = vim.loop.fs_stat(f)
    if stat and stat.type == 'file' then
      table.insert(out, vim.fn.fnamemodify(f, ':.'))
    end
  end
  if #out == 0 then return '(no files in ' .. cwd .. ')' end
  return table.concat(out, '\n')
end

function M.expand_tokens(text, state)
  if not text or text == '' then return text, {} end
  state = state or {}
  local attach = {}

  -- Helper: replace once or many; add path to attach list if applicable
  local function sub(pattern, repl_fn)
    text = text:gsub(pattern, function(...)
      local replacement, att = repl_fn(...)
      if att then table.insert(attach, att) end
      return replacement
    end)
  end

  -- @current / @buffer / @file  → active file path
  sub('@current%f[%A]', function()
    if state.active_file then return state.active_file, state.active_file end
    return '@current'  -- leave unchanged if no active file
  end)
  sub('@buffer%f[%A]', function()
    if state.active_file then return state.active_file, state.active_file end
    return '@buffer'
  end)
  -- Note: @file is tricky because it could conflict with @file.py style (existing
  -- file attachment). Only expand @file when it's a bare word.
  sub('@file%f[%A]', function()
    if state.active_file then return state.active_file, state.active_file end
    return '@file'
  end)

  -- @selection / @sel → formatted selection snippet
  sub('@selection%f[%A]', function()
    if state.selection_text and state.selection_range then
      local sr = state.selection_range
      local fn_label = vim.fn.fnamemodify(sr.file or '?', ':t')
      return string.format('(selection from %s lines %d-%d:\n```\n%s\n```\n)',
        fn_label, sr.start_line, sr.end_line, state.selection_text)
    end
    return '(no selection)'
  end)
  sub('@sel%f[%A]', function()
    if state.selection_text and state.selection_range then
      local sr = state.selection_range
      local fn_label = vim.fn.fnamemodify(sr.file or '?', ':t')
      return string.format('(selection from %s lines %d-%d:\n```\n%s\n```\n)',
        fn_label, sr.start_line, sr.end_line, state.selection_text)
    end
    return '(no selection)'
  end)

  -- @buffers → bullet list of open buffer paths
  sub('@buffers%f[%A]', function()
    local buffers = state.open_buffers or {}
    if #buffers == 0 then return '(no open buffers)' end
    local lst = {}
    for _, b in ipairs(buffers) do
      table.insert(lst, '- ' .. b.path .. (b.is_active and ' (active)' or ''))
    end
    return '(open buffers:\n' .. table.concat(lst, '\n') .. '\n)'
  end)

  -- @project → short glob-based file tree
  sub('@project%f[%A]', function()
    local cwd = state.cwd or vim.fn.getcwd()
    return '(project tree at ' .. cwd .. ':\n' .. short_project_tree(cwd) .. '\n)'
  end)

  -- @cursor → "file:line" of active cursor
  sub('@cursor%f[%A]', function()
    if state.active_file and state.cursor_line then
      return state.active_file .. ':' .. state.cursor_line, state.active_file
    end
    return '@cursor'
  end)

  -- Dedupe attach list
  local seen, dedup = {}, {}
  for _, p in ipairs(attach) do
    if p and not seen[p] then
      seen[p] = true; table.insert(dedup, p)
    end
  end
  return text, dedup
end

-- ── Public: scope check ───────────────────────────────────────────────────

--- Return true if `path` is within the user's "editor scope":
--   - the active file
--   - one of the open buffers
--   - one of the files currently attached to context
--   - inside the cwd AND user-supplied (allow cwd-relative work by default)
-- Returns false for paths completely outside all of the above.
function M.path_in_scope(path, state, context_files)
  if not path or path == '' then return false end
  state = state or {}
  local p = vim.fn.fnamemodify(path, ':p')

  if state.active_file and state.active_file == p then return true end

  for _, b in ipairs(state.open_buffers or {}) do
    if b.path == p then return true end
  end

  if context_files then
    for _, f in ipairs(context_files) do
      if f == p or (f and vim.fn.fnamemodify(f, ':p') == p) then return true end
    end
  end

  -- Paths inside the project cwd are "in scope" (user's workspace)
  local cwd = state.cwd or vim.fn.getcwd()
  if cwd and cwd ~= '' then
    local cwd_abs = vim.fn.fnamemodify(cwd, ':p')
    if p:sub(1, #cwd_abs) == cwd_abs then return true end
  end

  return false
end

return M
