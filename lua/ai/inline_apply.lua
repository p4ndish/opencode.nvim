-- ai/inline_apply.lua
-- Per-hunk inline diff with accept / reject keys in the target editor buffer.
-- Modeled after avante.nvim's replace_in_file.lua (virt_lines for new content,
-- red bg on removed lines, y/n/]/[  buffer-local keymaps while active).
--
-- Flow:
--   1. M.show(bufnr, path, old_content, new_content, on_done)
--   2. Computes hunks via Myers diff grouping
--   3. Renders each hunk inline:
--        - original lines get red bg  (AiInlineDel highlight)
--        - replacement lines rendered as green virt_lines above them (AiInlineAdd)
--        - sign column: ▎+ / ▎- markers
--   4. Installs buffer-local keymaps:  y = accept   n = reject   ] = next   [ = prev   <Esc> = cancel all
--   5. When every hunk is resolved → writes the final (possibly partially-
--      accepted) content to disk, clears all decorations, deletes keymaps,
--      fires on_done({ accepted = true/false, hunks_accepted = N, hunks_total = M,
--                       final_content = '...' })
--
-- Public API:
--   M.is_buffer_open(abs_path)  -> (bufnr|nil, winid|nil)
--   M.show(bufnr, path, old, new, on_done)
--   M.cancel(bufnr)

local M = {}
local HunkControls = require('ai.ui_hunk_controls')

-- NOTE: We use `vim.diff` (histogram) directly rather than ai.diff.myers_diff
-- because the latter has edge-case bugs around interior edits. `vim.diff` is
-- the same implementation avante uses and is battle-tested.

-- Per-buffer active diff state. Keyed by bufnr.
-- state = {
--   bufnr        = int,
--   path         = string,
--   old_lines    = { string... },
--   new_lines    = { string... },
--   hunks        = { { old_start, old_len, new_start, new_len,
--                      decision = 'pending' | 'accepted' | 'rejected' }, ... },
--   cur_idx      = int,
--   ns           = int,   -- extmark namespace
--   on_done      = fn,
--   prev_stl     = string? -- original statusline to restore
-- }
local active = {}

local NS_NAME = 'ai_inline_apply'
local SIGN_GROUP = 'ai_inline_apply'

-- ── Utility ───────────────────────────────────────────────────────────────

--- Split a string on '\n' into a list of lines (no trailing empty).
local function split_lines(s)
  if s == nil or s == '' then return {} end
  local lines = vim.split(s, '\n', { plain = true })
  -- If the content ends in a trailing newline, vim.split leaves an empty last
  -- element — drop it so diff counts match up.
  if lines[#lines] == '' then table.remove(lines) end
  return lines
end

--- Find a bufnr+winid for `path` (absolute), if open in any window.
function M.is_buffer_open(path)
  if not path or path == '' then return nil, nil end
  local abs = vim.fn.fnamemodify(path, ':p')
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local name = vim.api.nvim_buf_get_name(b)
      if name ~= '' and vim.fn.fnamemodify(name, ':p') == abs then
        -- Find a visible window showing this buffer, if any
        for _, w in ipairs(vim.api.nvim_list_wins()) do
          if vim.api.nvim_win_is_valid(w) and vim.api.nvim_win_get_buf(w) == b then
            return b, w
          end
        end
        return b, nil  -- loaded but not in a window
      end
    end
  end
  return nil, nil
end

-- True if `winid` looks like a normal editing window (not the AI sidebar
-- or any other plugin float we shouldn't hijack).
local function is_editor_win(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return false end
  local cfg = vim.api.nvim_win_get_config(winid)
  if cfg.relative ~= '' then return false end  -- floating
  local buf = vim.api.nvim_win_get_buf(winid)
  local ok, ft = pcall(vim.api.nvim_buf_get_option, buf, 'filetype')
  if ok and (ft == 'AiChat' or ft == 'AiTopbar' or ft == 'AiInput') then
    return false
  end
  local ok2, bt = pcall(vim.api.nvim_buf_get_option, buf, 'buftype')
  if ok2 and (bt == 'nofile' or bt == 'terminal' or bt == 'help'
    or bt == 'quickfix' or bt == 'prompt') then
    return false
  end
  return true
end

--- Ensure `path` is loaded in a buffer AND visible in a window. If the file
-- is not loaded, load it. If it's loaded but hidden, open it in a split that
-- doesn't disturb the AI sidebar.
-- Returns (bufnr, winid) on success, (nil, nil) on failure.
--
-- opts.dry_run (default false): if true, perform NO side effects (no buffer
-- load, no window creation). Returns (true, true) sentinel pair when the
-- operation WOULD succeed, or (nil, nil) when it would fail. Used by
-- M.can_apply() to decide whether to skip the chat permission prompt.
function M.ensure_buffer_visible(path, opts)
  opts = opts or {}
  if not path or path == '' then return nil, nil end
  local abs = vim.fn.fnamemodify(path, ':p')
  if vim.fn.filereadable(abs) == 0 then return nil, nil end

  -- Already open + visible?
  local b, w = M.is_buffer_open(abs)
  if b and w then return b, w end

  -- Try to find an existing editor window (non-sidebar, non-floating)
  local target_win
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if is_editor_win(winid) then target_win = winid; break end
  end

  -- Dry-run: report what we'd do without actually doing it.
  if opts.dry_run then
    -- We can always either (a) reuse an editor window or (b) create a
    -- topleft vsplit. Both are guaranteed to succeed since the file is
    -- already known readable. Return non-nil sentinels so the caller can
    -- treat the result as a boolean.
    return true, true
  end

  if target_win then
    -- Switch the editor window to this file
    pcall(vim.api.nvim_set_current_win, target_win)
    pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(abs))
    return M.is_buffer_open(abs)
  end

  -- No editor window available — create one with a left split (keeps the AI
  -- sidebar on the right intact)
  pcall(vim.cmd, 'topleft vsplit ' .. vim.fn.fnameescape(abs))
  return M.is_buffer_open(abs)
end

--- Predicate: would M.show() (and therefore the inline diff confirmation
-- flow) succeed for this tool call? Used by ui.lua to skip the chat
-- permission prompt when the editor is going to be the confirmation
-- surface anyway.
--
-- Pure: no side effects, no buffer/window creation.
--
-- @param path     string  absolute or relative file path
-- @param old_str  string? for `edit` calls — must be findable in the file.
--                          Pass nil/'' for `write` calls.
-- @param new_str  string? unused today, kept for forward compat.
-- @return bool, reason?  true if inline-apply will fire; false + a short
--                         reason string for diagnostics otherwise.
function M.can_apply(path, old_str, _new_str)
  if type(path) ~= 'string' or path == '' then
    return false, 'no path'
  end
  local abs = vim.fn.fnamemodify(path, ':p')
  -- File must exist on disk (write to a brand-new file falls back to disk
  -- write — we only inline-apply edits to existing files).
  if vim.fn.filereadable(abs) == 0 then
    return false, 'file does not exist'
  end
  -- For `edit`: oldString must be findable verbatim, otherwise the eventual
  -- replacement would no-op and there'd be nothing to show.
  if old_str and old_str ~= '' then
    local f = io.open(abs, 'r')
    if not f then return false, 'unreadable' end
    local content = f:read('*a') or ''
    f:close()
    if not content:find(old_str, 1, true) then
      return false, 'oldString not found'
    end
  end
  -- A buffer + window must be obtainable (dry-run, no side effects).
  local buf_ok, win_ok = M.ensure_buffer_visible(abs, { dry_run = true })
  if not buf_ok or not win_ok then
    return false, 'no window obtainable'
  end
  return true
end

-- ── Hunk computation (via vim.diff / histogram) ──────────────────────────
--
-- Each hunk is one contiguous region of change. `vim.diff` returns hunks as
-- `{ start_a, count_a, start_b, count_b }` (1-indexed). We convert each into
-- our internal shape:
--   { old_start, old_len, new_start, new_len,
--     old_lines, new_lines, decision = 'pending' }
local function compute_hunks(old_lines, new_lines)
  local old_str = table.concat(old_lines, '\n') .. '\n'
  local new_str = table.concat(new_lines, '\n') .. '\n'
  local ok, indices = pcall(vim.diff, old_str, new_str, {
    algorithm   = 'histogram',
    result_type = 'indices',
    ctxlen      = 0,
  })
  if not ok or type(indices) ~= 'table' then return {} end

  local hunks = {}
  for _, h in ipairs(indices) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]
    -- vim.diff: when there is nothing to remove/add, start is the index BEFORE
    -- the change (0 for before line 1). Our hunk needs a proper 1-indexed
    -- start even for pure-insertion / pure-deletion.
    local olds = {}
    if count_a > 0 then
      for i = start_a, start_a + count_a - 1 do
        table.insert(olds, old_lines[i] or '')
      end
    end
    local news = {}
    if count_b > 0 then
      for i = start_b, start_b + count_b - 1 do
        table.insert(news, new_lines[i] or '')
      end
    end
    table.insert(hunks, {
      old_start = count_a > 0 and start_a or (start_a + 1),
      old_len   = count_a,
      new_start = count_b > 0 and start_b or (start_b + 1),
      new_len   = count_b,
      old_lines = olds,
      new_lines = news,
      decision  = 'pending',
    })
  end
  return hunks
end

-- ── Highlighting ──────────────────────────────────────────────────────────

local function ensure_highlights()
  local function hl(n, o)
    local ok = pcall(vim.api.nvim_get_hl, 0, { name = n })
    if ok then vim.api.nvim_set_hl(0, n, o) end
  end
  -- Full-row red bg for old (removed) lines (matches Cursor)
  hl('AiInlineDel',         { bg = '#3b1a1e' })
  -- Full-row green bg for new lines (matches Cursor's stacked diff)
  hl('AiInlineAdd',         { bg = '#1a3024' })
  hl('AiInlineActiveHunk',  { fg = '#fab283', italic = true })  -- peach hint
  hl('AiInlineSignAdd',     { fg = '#7fd88f' })
  hl('AiInlineSignDel',     { fg = '#e06c75' })
  -- File-level bottom bar (Feature 3)
  hl('AiInlineFileBar',     { fg = '#fab283', bold = true })
  hl('AiInlineFileBarKey',  { fg = '#7fd88f', bold = true })
  hl('AiInlineFileBarReject', { fg = '#e06c75', bold = true })
  pcall(vim.fn.sign_define, 'AiInlineAdd', { text = '▎', texthl = 'AiInlineSignAdd' })
  pcall(vim.fn.sign_define, 'AiInlineDel', { text = '▎', texthl = 'AiInlineSignDel' })
end

-- ── Rendering ─────────────────────────────────────────────────────────────

-- Compute the "applied" buffer content from the hunk decisions.
-- Cursor-style: pending hunks show BOTH old and new lines stacked
-- (old lines first, then new lines below them). When the user resolves a
-- hunk, we delete the unwanted half and keep the chosen half.
--
-- Strategy: walk old_lines; at each hunk's old_start, output:
--   pending  → old_lines (red bg) + new_lines (green bg)
--   accepted → new_lines only
--   rejected → old_lines only
--
-- Returns:
--   lines       — array of buffer lines after applying decisions
--   row_meta    — per-output-row metadata { type='old'|'new'|'context', hunk_idx? }
--                 used by render() to apply highlights and signs.
local function apply_decisions_to_buffer(st)
  local out      = {}
  local row_meta = {}
  local old_lines = st.old_lines

  local mod_at  = {}  -- old_len > 0
  local ins_at  = {}  -- old_len == 0
  for idx, h in ipairs(st.hunks) do
    h._idx = idx
    if h.old_len > 0 then mod_at[h.old_start] = h
    else ins_at[h.old_start] = ins_at[h.old_start] or {}; table.insert(ins_at[h.old_start], h) end
  end

  local function push(line, meta)
    table.insert(out, line)
    table.insert(row_meta, meta)
  end

  local function emit_hunk(h)
    if h.decision == 'pending' then
      for _, l in ipairs(h.old_lines) do push(l, { type = 'old', hunk_idx = h._idx }) end
      for _, l in ipairs(h.new_lines) do push(l, { type = 'new', hunk_idx = h._idx }) end
    elseif h.decision == 'accepted' then
      for _, l in ipairs(h.new_lines) do push(l, { type = 'accepted', hunk_idx = h._idx }) end
    else  -- rejected
      for _, l in ipairs(h.old_lines) do push(l, { type = 'rejected', hunk_idx = h._idx }) end
    end
  end

  local i = 1
  while i <= #old_lines do
    if ins_at[i] then
      for _, h in ipairs(ins_at[i]) do emit_hunk(h) end
      ins_at[i] = nil
    end
    local h = mod_at[i]
    if h then
      emit_hunk(h)
      i = i + h.old_len
    else
      push(old_lines[i], { type = 'context' })
      i = i + 1
    end
  end
  -- Trailing pure-insertion hunks
  local tail = ins_at[#old_lines + 1]
  if tail then
    for _, h in ipairs(tail) do emit_hunk(h) end
  end

  return out, row_meta
end

-- Render the file-level bottom bar (Feature 3): a virt_line attached to the
-- last buffer line that summarizes counts and shows Y/N keybinds.
local function render_file_bar(st)
  local bufnr = st.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then return end

  local pending, accepted, rejected = 0, 0, 0
  for _, h in ipairs(st.hunks) do
    if     h.decision == 'pending'  then pending  = pending  + 1
    elseif h.decision == 'accepted' then accepted = accepted + 1
    elseif h.decision == 'rejected' then rejected = rejected + 1 end
  end

  local label = string.format(' [%d/%d resolved]  ', #st.hunks - pending, #st.hunks)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, st.ns, line_count - 1, 0, {
    virt_lines_above = false,
    virt_lines = {
      {
        { '  ' },
        { label, 'AiInlineFileBar' },
        { 'Y', 'AiInlineFileBarKey' },
        { ' Accept File   ', 'AiInlineFileBar' },
        { 'D', 'AiInlineFileBarReject' },
        { ' Reject File   ', 'AiInlineFileBar' },
        { '<Tab>', 'AiInlineFileBarKey' },
        { '/', 'AiInlineFileBar' },
        { '<S-Tab>', 'AiInlineFileBarKey' },
        { ' Next/Prev   ', 'AiInlineFileBar' },
        { '<Esc>', 'AiInlineFileBarReject' },
        { ' Cancel ', 'AiInlineFileBar' },
      },
    },
  })
end

-- Re-render the buffer from current decisions + draw extmarks/signs.
-- The buffer content matches `apply_decisions_to_buffer`'s output exactly,
-- and `row_meta` tells us which type each output row is so we can highlight.
local function render(st)
  local bufnr = st.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Rebuild buffer content based on current decisions
  local lines, row_meta = apply_decisions_to_buffer(st)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)

  -- Clear prior decorations
  vim.api.nvim_buf_clear_namespace(bufnr, st.ns, 0, -1)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })

  -- Build a map: hunk_idx → first row of that hunk's content (for the
  -- current decision state) so the active-hunk indicator can be placed.
  local hunk_first_row = {}

  for row, meta in ipairs(row_meta) do
    local row0 = row - 1  -- 0-indexed for highlights
    if meta.type == 'old' then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, st.ns, 'AiInlineDel',
        row0, 0, -1)
      pcall(vim.fn.sign_place, 0, SIGN_GROUP, 'AiInlineDel', bufnr,
        { lnum = row, priority = 100 })
      if meta.hunk_idx and not hunk_first_row[meta.hunk_idx] then
        hunk_first_row[meta.hunk_idx] = row0
      end
    elseif meta.type == 'new' then
      pcall(vim.api.nvim_buf_add_highlight, bufnr, st.ns, 'AiInlineAdd',
        row0, 0, -1)
      pcall(vim.fn.sign_place, 0, SIGN_GROUP, 'AiInlineAdd', bufnr,
        { lnum = row, priority = 100 })
      if meta.hunk_idx and not hunk_first_row[meta.hunk_idx] then
        hunk_first_row[meta.hunk_idx] = row0
      end
    elseif meta.type == 'accepted' then
      pcall(vim.fn.sign_place, 0, SIGN_GROUP, 'AiInlineAdd', bufnr,
        { lnum = row, priority = 100 })
      if meta.hunk_idx and not hunk_first_row[meta.hunk_idx] then
        hunk_first_row[meta.hunk_idx] = row0
      end
    end
  end

  -- Cache for cursor jumping
  st._hunk_rows = hunk_first_row

  -- Feature 2: per-hunk virt_lines bar + floating window for active hunk
  HunkControls.show(bufnr, st.ns, st.hunks, st.cur_idx, hunk_first_row,
    function(action) M._dispatch_button(bufnr, action) end)

  -- Feature 3: file-level bottom bar
  render_file_bar(st)
end

-- Jump cursor to the first row of the current hunk (post-render buffer).
local function jump_to_current(st)
  if not st.cur_idx then return end
  local winid = vim.fn.bufwinid(st.bufnr)
  if winid == -1 then return end
  local target = st._hunk_rows and st._hunk_rows[st.cur_idx]
  if target then
    local total = vim.api.nvim_buf_line_count(st.bufnr)
    local line = math.min(target + 1, total)
    pcall(vim.api.nvim_win_set_cursor, winid, { line, 0 })
  end
end

local function find_next_pending(st, from)
  for idx = (from or 1), #st.hunks do
    if st.hunks[idx].decision == 'pending' then return idx end
  end
  return nil
end

local function find_prev_pending(st, from)
  for idx = (from or 1), 1, -1 do
    if st.hunks[idx].decision == 'pending' then return idx end
  end
  return nil
end

-- ── Finalize ──────────────────────────────────────────────────────────────

-- reason: 'resolved' (normal y/d flow) | 'cancelled' (user pressed <Esc> /
-- clicked away) | 'abort' (external cancel from ui.lua, e.g. new turn)
local function finalize(st, reason)
  reason = reason or 'resolved'
  local bufnr = st.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    active[bufnr] = nil
    if st.on_done then st.on_done({
      accepted = false, cancelled = (reason == 'cancelled'),
      hunks_accepted = 0, hunks_rejected = 0,
      hunks_total = #st.hunks, final_content = '',
    }) end
    return
  end

  -- Count outcomes
  local accepted = 0
  local rejected = 0
  for _, h in ipairs(st.hunks) do
    if h.decision == 'accepted' then accepted = accepted + 1 end
    if h.decision == 'rejected' then rejected = rejected + 1 end
  end

  -- Clear decorations
  vim.api.nvim_buf_clear_namespace(bufnr, st.ns, 0, -1)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
  HunkControls.hide(bufnr)

  -- Remove keymaps (updated key set after the y/d/Tab remap)
  for _, key in ipairs({ 'y', 'd', 'Y', 'D', '<CR>', '<Tab>', '<S-Tab>',
                         'e', 'c', '<Esc>' }) do
    pcall(vim.keymap.del, 'n', key, { buffer = bufnr })
  end

  -- Restore statusline
  if st.prev_stl ~= nil then
    local winid = vim.fn.bufwinid(bufnr)
    if winid ~= -1 then
      pcall(vim.api.nvim_win_set_option, winid, 'statusline', st.prev_stl)
    end
  end

  -- Apply decisions to get final_lines and write buffer + disk
  local final_lines = apply_decisions_to_buffer(st)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, final_lines)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)

  -- Write to disk if any hunk was accepted
  local final_content = table.concat(final_lines, '\n')
  -- Preserve trailing newline if the original had one
  if st.new_content and st.new_content:sub(-1) == '\n' then
    final_content = final_content .. '\n'
  elseif st.old_content and st.old_content:sub(-1) == '\n' then
    final_content = final_content .. '\n'
  end

  if accepted > 0 then
    local f = io.open(st.path, 'w')
    if f then f:write(final_content); f:close() end
    -- Buffer & disk now agree; mark buffer clean
    pcall(function()
      vim.api.nvim_buf_call(bufnr, function()
        vim.cmd('silent! write!')
      end)
    end)
  end

  active[bufnr] = nil
  if st.on_done then
    st.on_done({
      accepted       = accepted > 0,
      cancelled      = reason == 'cancelled',
      hunks_accepted = accepted,
      hunks_rejected = rejected,
      hunks_total    = #st.hunks,
      final_content  = final_content,
    })
  end
end

local function update_statusline(st)
  local winid = vim.fn.bufwinid(st.bufnr)
  if winid == -1 then return end
  local pending = 0
  for _, h in ipairs(st.hunks) do
    if h.decision == 'pending' then pending = pending + 1 end
  end
  local done = #st.hunks - pending
  pcall(vim.api.nvim_win_set_option, winid, 'statusline',
    string.format(' [AI diff %d/%d resolved] y=accept d=reject <Tab>=next <S-Tab>=prev <Esc>=cancel ',
      done, #st.hunks))
end

-- ── Public: show ──────────────────────────────────────────────────────────

function M.show(bufnr, path, old_content, new_content, on_done)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    if on_done then on_done({ accepted = false, hunks_accepted = 0, hunks_total = 0, final_content = new_content or '' }) end
    return
  end

  ensure_highlights()

  local old_lines = split_lines(old_content)
  local new_lines = split_lines(new_content)
  local hunks     = compute_hunks(old_lines, new_lines)

  if #hunks == 0 then
    -- Nothing changed; write new content (if different only in trailing nl) and done
    if on_done then
      on_done({ accepted = true, hunks_accepted = 0, hunks_total = 0, final_content = new_content or '' })
    end
    return
  end

  local ns = vim.api.nvim_create_namespace(NS_NAME .. '_' .. bufnr)

  local prev_stl
  local winid = vim.fn.bufwinid(bufnr)
  if winid ~= -1 then
    prev_stl = vim.api.nvim_win_get_option(winid, 'statusline')
  end

  local st = {
    bufnr     = bufnr,
    path      = path,
    old_content = old_content,
    new_content = new_content,
    old_lines = old_lines,
    new_lines = new_lines,
    hunks     = hunks,
    cur_idx   = 1,
    ns        = ns,
    on_done   = on_done,
    prev_stl  = prev_stl,
  }
  active[bufnr] = st

  -- Start buffer at the "old" content (we'll progressively accept)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, old_lines)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', false)

  -- Install buffer-local keymaps.
  --
  -- Key design:
  --   y / <CR>   accept current hunk
  --   d          reject current hunk      (was `n` — deliberately changed:
  --                                         `n` is vim's "next search match"
  --                                         and the muscle-memory hit caused
  --                                         unintended rejections in practice)
  --   Y          accept ALL remaining
  --   D          reject ALL remaining     (was `N`)
  --   <Tab>      next pending hunk        (was `]`)
  --   <S-Tab>    prev pending hunk        (was `[`)
  --   <Esc>      CANCEL (distinct from reject: no tool retry)
  --   e          edit the proposed change
  --   c          focus chat input
  --
  -- nowait=true so single-letter keys fire immediately without ambiguity.
  local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }

  local function accept_current()
    local s = active[bufnr]; if not s then return end
    local h = s.hunks[s.cur_idx]
    if h and h.decision == 'pending' then h.decision = 'accepted' end
    local nxt = find_next_pending(s, s.cur_idx + 1)
    if nxt then s.cur_idx = nxt; render(s); update_statusline(s); jump_to_current(s)
    else finalize(s) end
  end
  local function reject_current()
    local s = active[bufnr]; if not s then return end
    local h = s.hunks[s.cur_idx]
    if h and h.decision == 'pending' then h.decision = 'rejected' end
    local nxt = find_next_pending(s, s.cur_idx + 1)
    if nxt then s.cur_idx = nxt; render(s); update_statusline(s); jump_to_current(s)
    else finalize(s) end
  end

  vim.keymap.set('n', 'y',    accept_current, opts)
  vim.keymap.set('n', '<CR>', accept_current, opts)  -- Cursor-style "Accept ⏎"
  vim.keymap.set('n', 'd',    reject_current, opts)

  vim.keymap.set('n', '<Tab>', function()
    local s = active[bufnr]; if not s then return end
    local nxt = find_next_pending(s, s.cur_idx + 1) or find_next_pending(s, 1)
    if nxt then s.cur_idx = nxt; render(s); update_statusline(s); jump_to_current(s) end
  end, opts)

  vim.keymap.set('n', '<S-Tab>', function()
    local s = active[bufnr]; if not s then return end
    local nxt = find_prev_pending(s, s.cur_idx - 1)
    if not nxt then
      -- wrap to last pending
      for i = #s.hunks, 1, -1 do
        if s.hunks[i].decision == 'pending' then nxt = i; break end
      end
    end
    if nxt then s.cur_idx = nxt; render(s); update_statusline(s); jump_to_current(s) end
  end, opts)

  -- 'e' → open inline edit prompt to modify the current hunk's proposed change
  --       (delegates to ai/inline_edit.lua if available)
  vim.keymap.set('n', 'e', function()
    local s = active[bufnr]; if not s then return end
    local h = s.hunks[s.cur_idx]
    if not h then return end
    -- Build a simple prompt asking the user how to revise the proposed change
    local prompt = string.format(
      'Revise the proposed change for hunk %d/%d (currently:\n%s\n→\n%s\n)',
      s.cur_idx, #s.hunks,
      table.concat(h.old_lines, '\n'),
      table.concat(h.new_lines, '\n'))
    vim.ui.input({ prompt = 'Edit hunk: ', default = table.concat(h.new_lines, '\n') }, function(input)
      if input == nil then return end  -- user cancelled
      h.new_lines = vim.split(input, '\n', { plain = true })
      h.new_len   = #h.new_lines
      h.decision  = 'pending'  -- keep pending so user can still accept/reject
      render(s); jump_to_current(s)
    end)
  end, opts)

  -- 'c' → focus the AI chat input pane to ask for revision
  vim.keymap.set('n', 'c', function()
    local ok, ui = pcall(require, 'ai.ui')
    if ok and ui.focus_input then
      ui.focus_input()
    end
  end, opts)

  -- Capital Y → accept ALL remaining pending hunks
  vim.keymap.set('n', 'Y', function()
    local s = active[bufnr]; if not s then return end
    for _, h in ipairs(s.hunks) do
      if h.decision == 'pending' then h.decision = 'accepted' end
    end
    finalize(s, 'resolved')
  end, opts)

  -- Capital D → reject ALL remaining pending hunks (was `N`)
  vim.keymap.set('n', 'D', function()
    local s = active[bufnr]; if not s then return end
    for _, h in ipairs(s.hunks) do
      if h.decision == 'pending' then h.decision = 'rejected' end
    end
    finalize(s, 'resolved')
  end, opts)

  -- <Esc> → CANCEL (distinct from reject).
  --   reject = "user doesn't want THIS change, try a different approach"
  --   cancel = "user walked away, stop and wait for next prompt — do NOT retry"
  -- The tool-result wording differs so the model doesn't loop on Esc.
  -- Pending hunks stay 'pending' (treated as no-decision); counted as rejected
  -- in stats so the summary card shows the full effect.
  vim.keymap.set('n', '<Esc>', function()
    local s = active[bufnr]; if not s then return end
    for _, h in ipairs(s.hunks) do
      if h.decision == 'pending' then h.decision = 'rejected' end
    end
    finalize(s, 'cancelled')
  end, opts)

  render(st)
  update_statusline(st)
  jump_to_current(st)
end

-- External cancel (e.g. new user turn arrived while review was pending).
-- Finalizes with reason='abort' so the on_done callback can differentiate
-- from a user-driven <Esc> cancel.
function M.cancel(bufnr)
  local st = active[bufnr]
  if not st then return end
  for _, h in ipairs(st.hunks) do
    if h.decision == 'pending' then h.decision = 'rejected' end
  end
  finalize(st, 'abort')
end

--- Accept ALL pending hunks in `bufnr` and finalize. Used by the chat-side
-- "Accept all" summary button (Feature 5).
function M.accept_all_in_buffer(bufnr)
  local s = active[bufnr]; if not s then return end
  for _, h in ipairs(s.hunks) do
    if h.decision == 'pending' then h.decision = 'accepted' end
  end
  finalize(s, 'resolved')
end

--- Reject ALL pending hunks in `bufnr` and finalize.
function M.reject_all_in_buffer(bufnr)
  local s = active[bufnr]; if not s then return end
  for _, h in ipairs(s.hunks) do
    if h.decision == 'pending' then h.decision = 'rejected' end
  end
  finalize(s, 'resolved')
end

--- Return list of bufnrs with active inline sessions.
function M.list_active_buffers()
  local out = {}
  for b, _ in pairs(active) do
    if vim.api.nvim_buf_is_valid(b) then table.insert(out, b) end
  end
  return out
end

--- Return summary { [bufnr] = { path, pending, accepted, rejected, total } }
-- for all active sessions.
function M.summary()
  local out = {}
  for b, s in pairs(active) do
    if vim.api.nvim_buf_is_valid(b) then
      local p, a, r = 0, 0, 0
      for _, h in ipairs(s.hunks) do
        if     h.decision == 'pending'  then p = p + 1
        elseif h.decision == 'accepted' then a = a + 1
        elseif h.decision == 'rejected' then r = r + 1 end
      end
      out[b] = { path = s.path, pending = p, accepted = a, rejected = r, total = #s.hunks }
    end
  end
  return out
end

-- Dispatch a button-id action from HunkControls (or future click handler)
function M._dispatch_button(bufnr, action)
  local s = active[bufnr]; if not s then return end
  if action == 'accept'      then M._accept_current(bufnr)
  elseif action == 'reject'  then M._reject_current(bufnr)
  elseif action == 'next'    then
    local nxt = nil
    for i = s.cur_idx + 1, #s.hunks do
      if s.hunks[i].decision == 'pending' then nxt = i; break end
    end
    if nxt then s.cur_idx = nxt; render(s); jump_to_current(s) end
  elseif action == 'prev'    then
    local nxt = nil
    for i = s.cur_idx - 1, 1, -1 do
      if s.hunks[i].decision == 'pending' then nxt = i; break end
    end
    if nxt then s.cur_idx = nxt; render(s); jump_to_current(s) end
  end
end

-- For tests
function M._get_state(bufnr) return active[bufnr] end
function M._compute_hunks(old, new)
  return compute_hunks(split_lines(old), split_lines(new))
end
function M._accept_current(bufnr)
  local s = active[bufnr]; if not s then return end
  local h = s.hunks[s.cur_idx]
  if h and h.decision == 'pending' then h.decision = 'accepted' end
  local nxt = find_next_pending(s, s.cur_idx + 1)
  if nxt then s.cur_idx = nxt; render(s); update_statusline(s); jump_to_current(s)
  else finalize(s, 'resolved') end
end
function M._reject_current(bufnr)
  local s = active[bufnr]; if not s then return end
  local h = s.hunks[s.cur_idx]
  if h and h.decision == 'pending' then h.decision = 'rejected' end
  local nxt = find_next_pending(s, s.cur_idx + 1)
  if nxt then s.cur_idx = nxt; render(s); update_statusline(s); jump_to_current(s)
  else finalize(s, 'resolved') end
end

return M
