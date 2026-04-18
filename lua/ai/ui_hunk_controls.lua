-- ai/ui_hunk_controls.lua
-- Cursor-style per-hunk control widget for the inline-apply diff session.
--
-- Rendering: a single virt_lines bar ABOVE every pending hunk listing the
-- key bindings. Format:
--   ▸ [hunk 1/N]  y Accept  d Reject  <Tab> Next  e Edit  c Chat  <Esc> Cancel
--
-- Why no floating window? An earlier version used a rounded-bordered float
-- anchored to the current hunk, but with height=1 + border=rounded the float
-- occupies 3 screen rows and would ALWAYS cover either the hunk's first line
-- (when shown above) or the lines immediately after the hunk's anchor (when
-- shown below). That made it impossible to clearly see the edited content in
-- many cases. virt_lines is a virtual row BETWEEN real buffer lines, so it
-- cannot overlap content — strictly safer. The keys are also surfaced in
-- three other places (1.5s toast on entry, chat-side banner above the input,
-- and statusline), so the float was pure redundancy.
--
-- Key actions are wired through buffer-local keymaps in inline_apply.lua
-- (`y`, `d`, `<Tab>`, `<S-Tab>`, `<CR>`, `<Esc>`, `Y`, `D`, `e`, `c`).
-- This module is purely visual.
--
-- Public API:
--   M.show(bufnr, ns, hunks, current_idx, hunk_first_row_map, on_button_click)
--   M.hide(bufnr)

local M = {}

-- Per-bufnr presence marker. Today it's just `{ ns = ns }` while a hunk
-- review is active; kept as a table for forward compatibility (e.g. if we
-- ever attach more state per session). The toast in ui.lua still uses the
-- AiHunkFloatBg / AiHunkFloatBorder highlight groups defined below.
local active = {}

local function ensure_highlights()
  local function hl(n, o)
    pcall(vim.api.nvim_set_hl, 0, n, o)
  end
  -- Per-hunk virt_text strip (above every pending hunk)
  hl('AiHunkBarBg',     { fg = '#808080' })
  hl('AiHunkBarKey',    { fg = '#fab283', bold = true })
  hl('AiHunkBarAccept', { fg = '#7fd88f', bold = true })
  hl('AiHunkBarReject', { fg = '#e06c75', bold = true })
  -- Floating window (active hunk)
  hl('AiHunkFloatBg',     { bg = '#1e1e1e', fg = '#eeeeee' })
  hl('AiHunkFloatBorder', { bg = '#1e1e1e', fg = '#fab283' })
  hl('AiHunkFloatAccept', { bg = '#1e1e1e', fg = '#7fd88f', bold = true })
  hl('AiHunkFloatReject', { bg = '#1e1e1e', fg = '#e06c75', bold = true })
  hl('AiHunkFloatKey',    { bg = '#1e1e1e', fg = '#fab283', bold = true })
  hl('AiHunkFloatLabel',  { bg = '#1e1e1e', fg = '#eeeeee' })
end

-- ── virt_lines bar above every pending hunk ───────────────────────────────

local function bar_for_hunk(hunk_idx, total_hunks, is_active)
  -- Returns the virt_lines content for one virt_line (single line, multi-chunk).
  -- Key labels match inline_apply.lua's new keymap scheme:
  --   y = accept   d = reject   <Tab>/<S-Tab> = next/prev   <Esc> = cancel
  local marker = is_active and '▸ ' or '  '
  return {
    { marker, 'AiHunkBarBg' },
    { string.format('[hunk %d/%d] ', hunk_idx, total_hunks), 'AiHunkBarBg' },
    { 'y', 'AiHunkBarKey' }, { ' Accept ', 'AiHunkBarAccept' },
    { '  ' },
    { 'd', 'AiHunkBarKey' }, { ' Reject ', 'AiHunkBarReject' },
    { '  ' },
    { '<Tab>', 'AiHunkBarKey' }, { ' Next', 'AiHunkBarBg' },
    { '  ' },
    { 'e', 'AiHunkBarKey' }, { ' Edit', 'AiHunkBarBg' },
    { '  ' },
    { 'c', 'AiHunkBarKey' }, { ' Chat', 'AiHunkBarBg' },
    { '  ' },
    { '<Esc>', 'AiHunkBarKey' }, { ' Cancel', 'AiHunkBarBg' },
  }
end

local function render_per_hunk_bars(bufnr, ns, hunks, current_idx, hunk_first_row)
  for idx, h in ipairs(hunks) do
    if h.decision == 'pending' and hunk_first_row[idx] then
      local is_active = (idx == current_idx)
      local row = hunk_first_row[idx]  -- 0-indexed
      pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
        virt_lines = { bar_for_hunk(idx, #hunks, is_active) },
        virt_lines_above = true,
      })
    end
  end
end

-- ── Public API ────────────────────────────────────────────────────────────

function M.show(bufnr, ns, hunks, current_idx, hunk_first_row, on_button_click)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  ensure_highlights()

  -- Clear any prior state (no-op, kept for symmetry with M.hide callers).
  M.hide(bufnr)

  -- Render per-hunk virt_lines bars. This is all the visual chrome we
  -- install; the virt_lines sit BETWEEN real buffer rows and cannot
  -- obscure buffer content.
  render_per_hunk_bars(bufnr, ns, hunks, current_idx, hunk_first_row)

  -- Mark the buffer as having active hunk controls so M.hide() can clean
  -- up any future state we add. Today it's just a presence marker.
  active[bufnr] = { ns = ns }
end

function M.hide(bufnr)
  -- We no longer open a floating window, so there's nothing to close.
  -- The virt_lines bars are cleared by the caller (inline_apply.finalize)
  -- via nvim_buf_clear_namespace — we just drop our state.
  active[bufnr] = nil
end

return M
