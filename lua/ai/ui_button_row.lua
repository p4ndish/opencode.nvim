-- ai/ui_button_row.lua
-- Inline button-row widget for confirmation prompts.
-- Renders buttons directly inside a chat buffer line using extmarks and
-- manages focus + activation via buffer-local keymaps.
--
-- Modeled after avante.nvim's `ui/button_group_line.lua` but simplified:
-- a single instance per prompt (we never render more than one concurrent
-- button row because our tool loop is sequential).
--
-- Public API:
--   M.show(bufnr, row, buttons, callbacks)
--     bufnr    : chat buffer
--     row      : 0-indexed row to place buttons on (the row must already
--                exist — typically a blank line reserved by ui_tool_card)
--     buttons  : { { id='allow', label='Allow', icon='', danger=false }, ... }
--     callbacks:
--       on_click(button_id)  -- required
--       on_cancel()          -- optional, called if user navigates away
--   M.hide()                 -- remove the currently-active row
--   M.is_active()            -> bool
--   M.activate_focused()     -- fire on_click for the currently-focused button
--   M.focus_next() / focus_prev()
--
-- Keyboard:
--   Tab / S-Tab  → focus next / previous button
--   Enter        → activate focused button (calls on_click)
--   y / n / a    → accelerator aliases (caller wires these by matching
--                   the button `id` field: y=first `allow*`, n=first `reject*`,
--                   a=first id containing `always`)

local M = {}

local NS_NAME = 'ai_button_row'
local ns      = nil   -- created lazily

local active = nil     -- { bufnr, row, buttons, focused, extmark_id, on_click, on_cancel, prev_maps }

-- Highlight groups (defined in ui.lua setup_highlights)
local HL_DEFAULT = 'AiButton'
local HL_FOCUS   = 'AiButtonFocus'
local HL_DANGER  = 'AiButtonDanger'
local HL_DANGER_FOCUS = 'AiButtonDangerFocus'

local function get_ns()
  if not ns then
    ns = vim.api.nvim_create_namespace(NS_NAME)
  end
  return ns
end

-- Build the button row line + per-button byte ranges.
-- Returns (line_string, ranges) where ranges[i] = { start_col, end_col }.
local function build_line(buttons, focused)
  local text = '     '  -- 5-space left indent (matches avante's button row indent)
  local ranges = {}
  for i, b in ipairs(buttons) do
    if i > 1 then text = text .. '   ' end
    local label
    if b.icon and b.icon ~= '' then
      label = string.format(' %s %s ', b.icon, b.label)
    else
      label = string.format('  %s  ', b.label)
    end
    local s = #text
    text = text .. label
    ranges[i] = { s, #text, is_danger = b.danger == true }
  end
  return text, ranges
end

-- Apply highlights to the button row based on current focus.
local function apply_highlights()
  if not active then return end
  local bufnr = active.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  -- Clear prior highlights for this namespace on this row
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, get_ns(), active.row, active.row + 1)

  for i, rng in ipairs(active.ranges) do
    local hl
    if i == active.focused then
      hl = rng.is_danger and HL_DANGER_FOCUS or HL_FOCUS
    else
      hl = rng.is_danger and HL_DANGER or HL_DEFAULT
    end
    pcall(vim.api.nvim_buf_add_highlight, bufnr, get_ns(), hl, active.row, rng[1], rng[2])
  end
end

-- Write the button row line into the buffer.
local function render()
  if not active then return end
  local bufnr = active.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end

  local line, ranges = build_line(active.buttons, active.focused)
  active.ranges = ranges

  pcall(vim.api.nvim_buf_set_option, bufnr, 'modifiable', true)
  pcall(vim.api.nvim_buf_set_lines, bufnr, active.row, active.row + 1, false, { line })
  pcall(vim.api.nvim_buf_set_option, bufnr, 'modifiable', false)
  apply_highlights()
end

local function clear_keymaps()
  if not active or not active.bufnr then return end
  local bufnr = active.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  for _, key in ipairs({ '<Tab>', '<S-Tab>', '<CR>', 'y', 'n', 'a' }) do
    pcall(vim.keymap.del, { 'n', 'i' }, key, { buffer = bufnr })
  end
  -- Restore the chat buffer's normal <CR>/Tab mappings if we swapped any.
  -- (We track via active.prev_maps if needed — keep it simple for now;
  -- chat buffer normally has these free.)
end

function M.is_active() return active ~= nil end

function M.focus_next()
  if not active then return end
  active.focused = (active.focused % #active.buttons) + 1
  apply_highlights()
end

function M.focus_prev()
  if not active then return end
  active.focused = active.focused - 1
  if active.focused < 1 then active.focused = #active.buttons end
  apply_highlights()
end

function M.activate_focused()
  if not active then return end
  local btn = active.buttons[active.focused]
  if not btn then return end
  local cb = active.on_click
  M.hide()
  if cb then cb(btn.id) end
end

-- Accelerator: find a button whose id matches one of the given patterns
-- and activate it.
local function activate_by_pattern(...)
  if not active then return end
  local patterns = { ... }
  for i, b in ipairs(active.buttons) do
    for _, pat in ipairs(patterns) do
      if b.id:match(pat) then
        active.focused = i
        M.activate_focused()
        return true
      end
    end
  end
  return false
end

function M.hide()
  if not active then return end
  clear_keymaps()
  local bufnr = active.bufnr
  if vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr, get_ns(), active.row, active.row + 1)
  end
  active = nil
end

function M.show(bufnr, row, buttons, callbacks)
  -- Hide any prior row first
  if active then M.hide() end
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  if not buttons or #buttons == 0 then return end

  active = {
    bufnr     = bufnr,
    row       = row,
    buttons   = buttons,
    focused   = 1,  -- first button focused by default
    on_click  = callbacks and callbacks.on_click or nil,
    on_cancel = callbacks and callbacks.on_cancel or nil,
    ranges    = {},
  }
  render()

  -- Install buffer-local keymaps
  local opts = { buffer = bufnr, noremap = true, silent = true, nowait = true }

  vim.keymap.set({ 'n', 'i' }, '<Tab>',   function() M.focus_next() end, opts)
  vim.keymap.set({ 'n', 'i' }, '<S-Tab>', function() M.focus_prev() end, opts)
  vim.keymap.set({ 'n', 'i' }, '<CR>',    function() M.activate_focused() end, opts)

  -- Accelerators (only fire when the row is active):
  -- y → allow / allow_once   |   a → allow_always   |   n → reject*
  vim.keymap.set({ 'n', 'i' }, 'y', function()
    if not activate_by_pattern('^allow_once$', '^allow$') then
      -- fallback: if no pure 'allow_once', treat y as generic first-allow
      activate_by_pattern('^allow')
    end
  end, opts)
  vim.keymap.set({ 'n', 'i' }, 'a', function()
    activate_by_pattern('always')
  end, opts)
  vim.keymap.set({ 'n', 'i' }, 'n', function()
    activate_by_pattern('^reject', '^deny')
  end, opts)
end

-- ── Tests helper ──────────────────────────────────────────────────────────
function M._get_active() return active end

-- F4b: expose namespace + bulk-clear so callers can wipe all stale extmarks
-- (e.g. on /new when sessions reset).
function M._ns() return get_ns() end

function M.clear_buf(bufnr)
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then return end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, get_ns(), 0, -1)
  -- Also drop the active state if it referenced this buffer.
  if active and active.bufnr == bufnr then active = nil end
end

return M
