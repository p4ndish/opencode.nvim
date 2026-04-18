-- AI Chat UI — Gemini-style
-- Layout: topbar split (top) + chat split (middle) + input split (bottom)

local M = {}

local config       = require('ai.config')
local client       = require('ai.client')
local skills_m     = require('ai.skills')
local context      = require('ai.context')
local sessions     = require('ai.sessions')
local agents       = require('ai.agents')
local providers_m  = require('ai.providers')
local tools_m      = require('ai.tools')
local system_m     = require('ai.system')        -- system prompt builder
local tool_support = require('ai.tool_support')  -- native/react detection
local editor_m     = require('ai.editor')        -- editor state capture
local ToolCard     = require('ai.ui_tool_card')  -- boxed tool-call widget (Phase 2)
local ButtonRow    = require('ai.ui_button_row') -- inline button widget (Phase 3)
local InlineApply  = require('ai.inline_apply')  -- per-hunk diff in editor buffer

-- ── Layout constants ──────────────────────────────────────────────────────
local W        = 56
local TOPBAR_H = 1
local INPUT_H  = 6
local MIN_COLS = W + 20
local P        = 3              -- left/right padding inside chat area (increased for breathing room)
local CHAT_W   = W - 2 * P     -- usable text width

-- ── Namespaces ────────────────────────────────────────────────────────────
local NS_CHAT   = nil
local NS_TOPBAR = nil
local NS_AT     = nil   -- used by @ file autocomplete float for per-line extmarks

-- ── State ─────────────────────────────────────────────────────────────────
local S = {
  chat_win  = nil, input_win  = nil, topbar_win  = nil,
  chat_buf  = nil, input_buf  = nil, topbar_buf  = nil,
  is_open      = false,
  is_streaming = false,
  stream_line  = nil,
  stream_text  = '',
  messages     = {},
  last_editor_win = nil,
  win_augroup  = nil,
  input_history = {},
  history_idx   = 0,
  showing_welcome = false,
  -- session
  session_id   = nil,
  -- streaming job handle (for cancel)
  stream_job   = nil,
  -- last known token usage (populated by on_usage callback)
  token_last   = { prompt = 0, completion = 0, total = 0 },
  -- undo/redo stacks (each entry = snapshot of messages at that point)
  undo_stack   = {},
  redo_stack   = {},
  -- thinking mode (show chain-of-thought markers)
  thinking     = false,
  -- braille spinner state (updated by timer while streaming)
  spinner_frame = 1,
  spinner_timer = nil,
  -- per-turn metadata (set at submit time, used by response footer)
  turn_start_time = nil,
  turn_model      = nil,
  turn_agent      = nil,
  -- sticky-scroll: auto-scrolls to bottom unless user has scrolled up
  scroll_pinned   = true,
  -- prompt history: saved draft text when navigating with Up/Down
  history_draft   = '',
  -- frecency data for @ file autocomplete
  file_frecency   = nil,  -- loaded on first use
  -- timestamps visibility toggle (loaded from config on setup)
  show_timestamps = true,  -- overridden in M.setup() from config
  -- cumulative token/cost tracking for footer
  token_total     = 0,
  cost_total      = 0,
  -- tool use
  trust_mode      = false,  -- when true, skip all permission prompts
  pending_permission = nil, -- {tool_name, args, callback} — awaiting user response
  -- editor awareness (Cursor / Windsurf style)
  origin_buf      = nil,    -- the non-sidebar buffer the user was on when the sidebar opened
  origin_win      = nil,    -- the window we restored focus to on <Esc>
  editor_state    = nil,    -- last captured state (populated at submit time)
  approved_external = {},   -- { [file_path] = true } — tool writes approved for external files this session
  -- Files attached via the @ picker since the last submit. Rendered as chips
  -- INSIDE the user's message bubble at submit time; cleared immediately after.
  -- Also reset by /new, /clear, and when the user regenerates.
  pending_attachments = {},
  -- Turn-scoped flag: set when the user explicitly REJECTS an inline-apply
  -- result (distinct from Esc-cancel). When true, the next agentic
  -- iteration injects a hard-stop instruction so the model stops guessing
  -- alternative edits and asks the user to clarify instead. Reset at the
  -- start of every submit() and at /new.
  turn_had_rejection = false,
}

-- ── Spinner frames (braille — matches OpenCode's animated progress indicator) ──
local SPINNER_FRAMES = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' }

-- ── Forward declarations ──────────────────────────────────────────────────
-- These locals are referenced before their definition in the file.
local render_input_bar
local render_topbar
local session_save
local append_message
local refocus_input
local open_provider_picker         -- referenced by open_model_picker (defined later)
local open_model_picker            -- referenced by open_provider_picker and prompt_add_provider
local prompt_add_provider          -- referenced by open_provider_picker
local prompt_builtin_apikey        -- referenced by open_provider_picker
local prompt_add_custom_provider   -- referenced by open_provider_picker
local process_slash_command        -- referenced by open_command_picker (defined later)
local render_footer                -- referenced by prompt_add_custom_provider (defined later)

-- ── Spinner helpers ───────────────────────────────────────────────────────
-- Braille spinner that animates while streaming (120ms per frame).
-- Uses vim.loop timer so it works even when the main loop is idle.
local function start_spinner()
  if S.spinner_timer then return end  -- already running
  S.spinner_frame = 1
  S.spinner_timer = vim.loop.new_timer()
  S.spinner_timer:start(0, 120, vim.schedule_wrap(function()
    if not S.is_streaming then return end
    S.spinner_frame = (S.spinner_frame % #SPINNER_FRAMES) + 1
    if render_topbar then render_topbar() end
    if render_input_bar then render_input_bar() end
    -- Also update footer to show spinner there
    pcall(render_footer)
  end))
end

local function stop_spinner()
  if S.spinner_timer then
    S.spinner_timer:stop()
    S.spinner_timer:close()
    S.spinner_timer = nil
  end
  S.spinner_frame = 1
  -- one final render to clear the spinner glyph
  vim.schedule(function() if render_topbar then render_topbar() end end)
end


-- ── Bottom status spinner (avante-style) ──────────────────────────────────
-- Shows a centered virt_line at the bottom of the chat buffer indicating
-- the current operation state. States:
--   'generating'   — LLM streaming text (violet + braille)
--   'tool calling' — a tool is executing (cyan + braille)
--   'thinking'     — reasoning model is thinking (magenta + 🤯/🙄)
--   'succeeded'    — brief confirmation then disappear (green, no spinner)
--   'failed'       — brief error indicator (red, no spinner)
-- Cleared by state_clear().
local STATE_SPINNER_FRAMES = {
  generating   = { '·', '✢', '✳', '∗', '✻', '✽' },
  ['tool calling'] = { '⣾', '⣽', '⣻', '⢿', '⡿', '⣟', '⣯', '⣷' },
  thinking     = { '🤯', '🙄' },
}
local STATE_HL = {
  generating     = 'AiToolStateGenerating',
  ['tool calling'] = 'AiToolStateRunning',
  thinking       = 'AiToolStatePermission',  -- yellow-ish; reuse palette
  succeeded      = 'AiToolStateSuccess',
  failed         = 'AiToolStateFailed',
}

local state_ns         -- lazy-created extmark namespace
local state_extmark_id -- current extmark
local state_timer
local state_spinner_idx = 1
local state_name        -- current state or nil

local function get_state_ns()
  if not state_ns then state_ns = vim.api.nvim_create_namespace('ai_state_spinner') end
  return state_ns
end

local function state_clear()
  state_name = nil
  if state_timer then
    pcall(function() state_timer:stop(); state_timer:close() end)
    state_timer = nil
  end
  if S.chat_buf and vim.api.nvim_buf_is_valid(S.chat_buf) and state_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, S.chat_buf, get_state_ns(), state_extmark_id)
  end
  state_extmark_id = nil
end

local function state_render()
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  if not S.chat_win or not vim.api.nvim_win_is_valid(S.chat_win) then return end
  if not state_name then return end

  local frames = STATE_SPINNER_FRAMES[state_name]
  local hl     = STATE_HL[state_name] or 'AiToolStateGenerating'
  local spinner_char = ''
  if frames then
    state_spinner_idx = (state_spinner_idx % #frames) + 1
    spinner_char = frames[state_spinner_idx]
  end
  local label = spinner_char ~= ''
    and (' ' .. spinner_char .. ' ' .. state_name .. ' ')
    or  (' ' .. state_name .. ' ')

  -- Compute centering inside the chat window
  local win_w = vim.api.nvim_win_get_width(S.chat_win)
  local pad = math.max(0, math.floor((win_w - vim.fn.strdisplaywidth(label)) / 2))

  local last_line = vim.api.nvim_buf_line_count(S.chat_buf) - 1
  if last_line < 0 then last_line = 0 end

  -- Clear any prior extmark, draw a fresh one as a virt_line below last line
  if state_extmark_id then
    pcall(vim.api.nvim_buf_del_extmark, S.chat_buf, get_state_ns(), state_extmark_id)
  end
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, S.chat_buf, get_state_ns(),
    last_line, 0, {
      virt_lines = { { { string.rep(' ', pad) }, { label, hl } } },
      virt_lines_above = false,
      hl_mode = 'combine',
    })
  if ok then state_extmark_id = id end
end

local function state_set(name)
  state_name = name
  state_spinner_idx = 1
  -- Stop any prior timer
  if state_timer then
    pcall(function() state_timer:stop(); state_timer:close() end)
    state_timer = nil
  end
  state_render()
  -- Only spinner states get the animation timer
  if STATE_SPINNER_FRAMES[name] then
    state_timer = vim.loop.new_timer()
    state_timer:start(160, 160, vim.schedule_wrap(function()
      if not state_name or not STATE_SPINNER_FRAMES[state_name] then return end
      state_render()
    end))
  else
    -- Non-spinner terminal states auto-clear after 2s
    vim.defer_fn(function()
      if state_name == name then state_clear() end
    end, 2000)
  end
end


-- ── Toast notification system ─────────────────────────────────────────────
-- Top-right popup for feedback messages. Auto-dismiss after 3s. Stacks vertically.
local toast_stack = {}

local function toast_dismiss(entry)
  if entry.timer then
    pcall(function() entry.timer:stop(); entry.timer:close() end)
    entry.timer = nil
  end
  if entry.win and vim.api.nvim_win_is_valid(entry.win) then
    pcall(vim.api.nvim_win_close, entry.win, true)
  end
  for i, e in ipairs(toast_stack) do
    if e == entry then table.remove(toast_stack, i); break end
  end
  -- reposition remaining toasts
  for i, e in ipairs(toast_stack) do
    if e.win and vim.api.nvim_win_is_valid(e.win) then
      pcall(vim.api.nvim_win_set_config, e.win, {
        relative = 'editor',
        row = i - 1, col = math.max(0, vim.o.columns - e.width - 2),
      })
    end
  end
end

local function toast(msg, level)
  level = level or 'info'
  local icon = ({ info = 'ℹ', success = '✓', error = '✗', warn = '⚠' })[level] or 'ℹ'
  local text = ' ' .. icon .. ' ' .. msg .. ' '
  local width = vim.fn.strdisplaywidth(text)

  local tbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(tbuf, 0, -1, false, { text })

  local row = #toast_stack
  local col = math.max(0, vim.o.columns - width - 2)

  local twin = vim.api.nvim_open_win(tbuf, false, {
    relative  = 'editor',
    row       = row,
    col       = col,
    width     = width,
    height    = 1,
    style     = 'minimal',
    border    = 'rounded',
    zindex    = 250,
    focusable = false,
    noautocmd = true,
  })

  local hl = ({
    info    = 'AiToastInfo',
    success = 'AiToastSuccess',
    error   = 'AiToastError',
    warn    = 'AiToastWarn',
  })[level] or 'AiToastInfo'

  vim.api.nvim_win_set_option(twin, 'winhighlight', 'Normal:' .. hl .. ',FloatBorder:' .. hl)

  local entry = { win = twin, buf = tbuf, width = width, timer = nil }
  table.insert(toast_stack, entry)

  entry.timer = vim.loop.new_timer()
  entry.timer:start(3000, 0, vim.schedule_wrap(function()
    toast_dismiss(entry)
  end))
end


-- ── Colour palette (OpenCode "opencode" dark theme) ──────────────────────
-- Source: opencode-ref/packages/opencode/src/cli/cmd/tui/context/theme/opencode.json
local C = {
  bg         = '#0a0a0a',   -- theme.background
  bg_panel   = '#141414',   -- theme.backgroundPanel (user msg, code blocks)
  bg_elem    = '#1e1e1e',   -- theme.backgroundElement (pickers, menus)
  bg_input   = '#1e1e1e',   -- composer / input bg (matches backgroundElement)
  bg_send    = '#1f3760',   -- send button bg
  fg         = '#eeeeee',   -- theme.text
  fg2        = '#eeeeee',   -- secondary (same as text in OpenCode)
  fg3        = '#808080',   -- theme.textMuted
  fg4        = '#808080',   -- theme.textMuted (alias)
  user_fg    = '#eeeeee',   -- user block text
  asst_fg    = '#eeeeee',   -- assistant text
  send_fg    = '#eeeeee',   -- send button icon
  sparkle    = '#5c9cf5',   -- theme.secondary (agent color, replaces Gemini blue)
  sep        = '#484848',   -- theme.border
  stream     = '#5c9cf5',   -- streaming dot (agent color)
  primary    = '#fab283',   -- theme.primary (selection highlight)
  secondary  = '#5c9cf5',   -- theme.secondary (agent color)
  accent     = '#9d7cd8',   -- theme.accent
  success    = '#7fd88f',   -- theme.success
  error      = '#e06c75',   -- theme.error
  warning    = '#f5a742',   -- theme.warning
  info       = '#56b6c2',   -- theme.info
}

-- ── Highlights (matched to OpenCode's "opencode" dark theme) ──────────────
local function setup_highlights()
  local function hl(name, opts) vim.api.nvim_set_hl(0, name, opts) end

  -- Base regions
  hl('AiChatBg',  { bg = C.bg,       fg = C.fg })
  hl('AiTopBg',   { bg = C.bg,       fg = C.fg })
  hl('AiInputBg', { bg = C.bg_input, fg = C.fg })

  -- Topbar winbar elements
  hl('AiTopTitle',    { bg = C.bg, fg = C.fg,  bold = true })
  hl('AiTopArrow',    { bg = C.bg, fg = C.fg3 })
  hl('AiTopMeta',     { bg = C.bg, fg = C.fg3 })
  hl('AiTopIcon',     { bg = C.bg, fg = C.fg })
  hl('AiTopProvider', { bg = C.bg, fg = C.fg3 })
  hl('AiTopSep',      { bg = C.bg, fg = C.sep })
  hl('AiTopStream',   { bg = C.bg, fg = C.secondary, bold = true })
  hl('AiTopTokens',   { bg = C.bg, fg = C.fg3 })

  -- User message block (OpenCode: left ┃ border in secondary, bg = backgroundPanel)
  hl('AiUserBorder', { bg = C.bg_panel, fg = C.secondary })
  hl('AiUserBlock',  { bg = C.bg_panel, fg = C.fg })
  hl('AiUserMeta',   { bg = C.bg, fg = C.fg3 })

  -- Assistant message (OpenCode: no bg, text = theme.text, paddingLeft=3)
  hl('AiAsstAvatar',     { bg = C.bg, fg = C.secondary, bold = true })
  hl('AiAsstText',       { bg = C.bg, fg = C.fg })
  hl('AiAsstBorder',     { bg = C.bg, fg = C.secondary })  -- thin │ in agent color
  -- Per-message toolbar (Change A — Cursor-style icon row)
  hl('AiMsgToolbar',     { bg = C.bg, fg = C.fg3 })
  hl('AiMsgToolbarKey',  { bg = C.bg, fg = C.fg, bold = true })
  hl('AiAsstMeta',       { bg = C.bg, fg = C.fg3 })
  hl('AiAsstFooterIcon', { bg = C.bg, fg = C.secondary })
  hl('AiAsstFooter',     { bg = C.bg, fg = C.fg3 })

  -- System / info
  hl('AiSysText', { bg = C.bg, fg = C.fg3, italic = true })

  -- Welcome screen
  hl('AiSparkle',      { bg = C.bg, fg = C.secondary, bold = true })
  hl('AiWelcomeHi',    { bg = C.bg, fg = C.fg, bold = true })
  hl('AiWelcomeTitle', { bg = C.bg, fg = C.fg3 })
  hl('AiWelcomeSub',   { bg = C.bg, fg = C.fg3 })

  -- Input left border (OpenCode: agent-colored ┃ on input pane)
  hl('AiInputBorder', { bg = C.bg_input, fg = C.secondary })
  hl('AiInputPlaceholder', { bg = C.bg_input, fg = C.fg3 })

  -- Input bar winbar chips
  hl('AiBarBg',      { bg = C.bg_input, fg = C.fg })
  hl('AiBarAdd',     { bg = C.bg_input, fg = C.fg })
  hl('AiBarTools',   { bg = C.bg_input, fg = C.fg })
  hl('AiBarModel',   { bg = C.bg_input, fg = C.fg3 })
  hl('AiBarCtx',     { bg = C.bg_input, fg = C.secondary })
  hl('AiBarSend',    { bg = C.bg_send,  fg = C.fg, bold = true })
  hl('AiBarAgent',   { bg = C.bg_input, fg = C.secondary })
  hl('AiBarSpinner', { bg = C.bg_input, fg = C.secondary })

  -- Picker float (OpenCode: bg = backgroundPanel #141414, sel = primary)
  hl('AiPickerBg',       { bg = C.bg_panel, fg = C.fg })
  hl('AiPickerTitle',    { bg = C.bg_panel, fg = C.fg, bold = true })
  hl('AiPickerSel',      { bg = C.primary, fg = C.bg, bold = true })
  hl('AiPickerItem',     { bg = C.bg_panel, fg = C.fg })
  hl('AiPickerHint',     { bg = C.bg_panel, fg = C.fg3 })
  hl('AiPickerQuery',    { bg = C.bg_panel, fg = C.fg3 })         -- typed text = textMuted
  hl('AiPickerCat',      { bg = C.bg_panel, fg = C.accent, bold = true })
  hl('AiPickerCurrent',  { fg = C.primary })
  hl('AiPickerGutter',   { fg = C.success })
  hl('AiPickerEsc',      { bg = C.bg_panel, fg = C.fg3 })
  hl('AiPickerFootKey',  { bg = C.bg_panel, fg = C.fg,  bold = true })
  hl('AiPickerFootBind', { bg = C.bg_panel, fg = C.fg3 })
  hl('AiPickerCursor',   { bg = C.primary, fg = C.primary })      -- cursor = primary peach

  -- Markdown rendering in chat (OpenCode markdown theme keys)
  hl('AiCode',       { bg = C.bg_panel, fg = C.fg })
  hl('AiCodeLang',   { bg = C.bg_panel, fg = C.accent, italic = true })
  hl('AiCodeInline', { bg = C.bg_panel, fg = '#7fd88f' })           -- markdownCode = green
  hl('AiBold',       { bg = C.bg, fg = C.warning, bold = true })    -- markdownStrong = orange
  hl('AiHeading',    { bg = C.bg, fg = C.accent, bold = true })     -- markdownHeading = accent
  hl('AiBullet',     { bg = C.bg, fg = C.primary })                 -- markdownListItem = primary

  -- Slash command float (matches picker bg)
  hl('AiSlashDesc',   { bg = C.bg_panel, fg = C.fg3 })
  hl('AiSlashKey',    { bg = C.bg_panel, fg = C.fg3, italic = true })
  hl('AiSlashKeySel', { bg = C.primary, fg = C.bg, italic = true })

  -- @ file autocomplete float (matches picker bg)
  hl('AiAtDir',  { bg = C.bg_panel, fg = C.fg3 })
  hl('AiAtFile', { bg = C.bg_panel, fg = C.fg })

  -- Toast notifications
  hl('AiToastInfo',    { bg = '#1e3a5f', fg = C.secondary })
  hl('AiToastSuccess', { bg = '#1e3a2a', fg = C.success })
  hl('AiToastError',   { bg = '#5f1e1e', fg = C.error })
  hl('AiToastWarn',    { bg = '#5f4b1e', fg = C.warning })

  -- Backdrop overlay
  hl('AiBackdrop', { bg = '#000000', fg = '#000000' })

  -- Inline error display (OpenCode: left border = theme.error, bg = backgroundPanel)
  hl('AiErrorBorder', { bg = C.bg_panel, fg = C.error })
  hl('AiErrorText',   { bg = C.bg_panel, fg = C.fg3 })

  -- File attachment badges (OpenCode colors: secondary, accent, primary)
  hl('AiBadgeFile',  { bg = C.secondary, fg = C.bg })
  hl('AiBadgeImage', { bg = C.accent,    fg = C.bg })
  hl('AiBadgePdf',   { bg = C.primary,   fg = C.bg })

  -- Tool call display in chat — avante-style boxed cards
  hl('AiToolHeader',  { bg = C.bg_panel, fg = C.secondary, bold = true })  -- ╭─ border lines
  hl('AiToolBody',    { bg = C.bg_panel, fg = C.fg3 })                     -- generic body
  hl('AiToolBorder',  { bg = C.bg_panel, fg = C.secondary })               -- left │ border (legacy)
  hl('AiToolError',   { bg = C.bg_panel, fg = C.error })                   -- error output
  hl('AiToolPerm',    { bg = C.bg_panel, fg = C.warning, bold = true })    -- permission prompt
  -- State badges on the card header (colored icon+label segment)
  hl('AiToolStateGenerating',  { bg = '#ab9df2', fg = '#1e222a', bold = true })  -- violet
  hl('AiToolStateRunning',     { bg = '#56b6c2', fg = '#1e222a', bold = true })  -- cyan
  hl('AiToolStatePermission',  { bg = '#f5a742', fg = '#1e222a', bold = true })  -- yellow
  hl('AiToolStateSuccess',     { bg = '#7fd88f', fg = '#1e222a', bold = true })  -- green
  hl('AiToolStateFailed',      { bg = '#e06c75', fg = '#1e222a', bold = true })  -- red
  -- Mini-diff inside the card
  hl('AiToolDiffAdd',          { bg = '#183024', fg = '#7fd88f' })                -- + green bg
  hl('AiToolDiffDel',          { bg = '#3b1a1e', fg = '#e06c75' })                -- - red bg
  -- +N / -M stat badge in the card header (Feature 4)
  hl('AiToolStatAdd',          { bg = C.bg_panel, fg = '#7fd88f', bold = true })
  hl('AiToolStatDel',          { bg = C.bg_panel, fg = '#e06c75', bold = true })
  hl('AiToolButtonsPlaceholder', { bg = C.bg_panel, fg = C.fg3 })                 -- before buttons rendered
  -- Inline button widget (Phase 3)
  hl('AiButton',              { bg = '#2a2e37', fg = C.fg,   bold = false })
  hl('AiButtonFocus',         { bg = '#7fd88f', fg = '#1e222a', bold = true  })
  hl('AiButtonDanger',        { bg = '#3b1a1e', fg = C.error, bold = false })
  hl('AiButtonDangerFocus',   { bg = '#e06c75', fg = '#1e222a', bold = true  })

  -- Footer status bar
  hl('AiFooterBg',    { bg = C.bg, fg = C.fg3 })
  hl('AiFooterDir',   { bg = C.bg, fg = C.fg3 })
  hl('AiFooterCtx',   { bg = C.bg, fg = C.secondary })
  hl('AiFooterToken', { bg = C.bg, fg = C.fg3 })
  hl('AiFooterCost',  { bg = C.bg, fg = C.fg3 })
  hl('AiFooterWarn',  { bg = C.bg, fg = C.warning, bold = true })
  hl('AiFooterError', { bg = C.bg, fg = C.error,   bold = true })
end

-- ── Buffer / window helpers ───────────────────────────────────────────────
local function make_buf(name, mod)
  local buf = vim.api.nvim_create_buf(false, true)
  pcall(vim.api.nvim_buf_set_name, buf, name)
  vim.api.nvim_buf_set_option(buf, 'buftype',   'nofile')
  vim.api.nvim_buf_set_option(buf, 'swapfile',  false)
  vim.api.nvim_buf_set_option(buf, 'buflisted', false)
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  if mod ~= nil then
    vim.api.nvim_buf_set_option(buf, 'modifiable', mod)
  end
  return buf
end

local function bset(buf, s, e, lines)
  pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, s, e, false, lines)
  pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', false)
end

-- Visual breathing room between the last chat content and the input chatbox
-- below. Maintained as N trailing blank lines in the chat buffer; scroll
-- positioning then anchors the LAST (blank) line at the window bottom so the
-- last meaningful content sits BOTTOM_MARGIN rows above the chatbox edge.
local BOTTOM_MARGIN = 2

-- Ensure the chat buffer has EXACTLY BOTTOM_MARGIN trailing blank lines.
-- Idempotent — called from scroll_bottom on every render so the invariant
-- self-corrects after any code path that overwrites the buffer (welcome,
-- redraw_chat_from_messages, stream_chunk, etc.).
local function ensure_bottom_margin(buf)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then return end
  local lc = vim.api.nvim_buf_line_count(buf)
  if lc == 0 then return end
  -- Find the last non-blank line (count only TRAILING blanks; in-content
  -- blank lines between messages are preserved).
  local last_content = lc
  while last_content > 0 do
    local line = vim.api.nvim_buf_get_lines(buf, last_content - 1, last_content, false)[1]
    if not line or vim.trim(line) ~= '' then break end
    last_content = last_content - 1
  end
  local target = last_content + BOTTOM_MARGIN
  local diff = target - lc
  if diff == 0 then return end
  pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', true)
  if diff > 0 then
    local pad = {}
    for i = 1, diff do pad[i] = '' end
    pcall(vim.api.nvim_buf_set_lines, buf, lc, lc, false, pad)
  else
    -- Too many trailing blanks (e.g. content shrank) — trim to target.
    pcall(vim.api.nvim_buf_set_lines, buf, target, lc, false, {})
  end
  pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', false)
end

local function scroll_bottom(win, buf)
  if not S.scroll_pinned then return end
  if not (win and vim.api.nvim_win_is_valid(win)) then return end
  -- Maintain bottom-margin invariant on every scroll. The trailing blank
  -- lines act as visual padding between the last content row and the input
  -- chatbox edge.
  ensure_bottom_margin(buf)
  local lc = math.max(1, vim.api.nvim_buf_line_count(buf))
  pcall(vim.api.nvim_win_call, win, function()
    -- Anchor the last (blank) line at the window bottom; the actual content
    -- then sits BOTTOM_MARGIN rows above the chatbox edge.
    vim.api.nvim_win_set_cursor(win, { lc, 0 })
    vim.cmd('normal! zb')
  end)
end

-- Test exports (matches existing M._foo testability convention)
M._ensure_bottom_margin = ensure_bottom_margin
M._BOTTOM_MARGIN        = BOTTOM_MARGIN

local function win_ok(w)
  return w ~= nil and vim.api.nvim_win_is_valid(w)
end

local function is_sidebar_win(w)
  return w ~= nil and (w == S.chat_win or w == S.input_win or w == S.topbar_win)
end

local function center(str, w)
  local len = vim.fn.strdisplaywidth(str)
  if len >= w then return str end
  local pad = math.floor((w - len) / 2)
  return string.rep(' ', pad) .. str .. string.rep(' ', w - pad - len)
end


-- ── Shared fuzzy scorer (used by slash complete + @ file complete) ─────────
-- Simple subsequence fuzzy score: higher = better match.
-- Scores: consecutive chars +3, start-of-word +5, first-char +8, else +1.
local function fuzzy_score(needle, haystack)
  if needle == '' then return 1 end
  local ni, hi = 1, 1
  local score = 0
  local prev_match = false
  local nlen, hlen = #needle, #haystack
  local nl, hl = needle:lower(), haystack:lower()
  while ni <= nlen and hi <= hlen do
    if nl:byte(ni) == hl:byte(hi) then
      if ni == 1 and hi == 1 then
        score = score + 8
      elseif hi == 1 or haystack:byte(hi - 1) == 32 or haystack:byte(hi - 1) == 45 then
        score = score + 5
      elseif prev_match then
        score = score + 3
      else
        score = score + 1
      end
      prev_match = true
      ni = ni + 1
    else
      prev_match = false
    end
    hi = hi + 1
  end
  if ni <= nlen then return nil end
  return score
end


-- ── Frecency helpers (for @ file autocomplete) ───────────────────────────
local FRECENCY_PATH = vim.fn.stdpath('data') .. '/ai_frecency.json'

local function load_frecency()
  local f = io.open(FRECENCY_PATH, 'r')
  if not f then return {} end
  local data = f:read('*a'); f:close()
  local ok, tbl = pcall(vim.fn.json_decode, data)
  return ok and type(tbl) == 'table' and tbl or {}
end

local function save_frecency(data)
  local f = io.open(FRECENCY_PATH, 'w')
  if f then f:write(vim.fn.json_encode(data)); f:close() end
end

local function update_frecency(path)
  if not S.file_frecency then S.file_frecency = load_frecency() end
  local entry = S.file_frecency[path] or { count = 0, last = 0 }
  entry.count = entry.count + 1
  entry.last = os.time()
  S.file_frecency[path] = entry
  save_frecency(S.file_frecency)
end


-- ── Model state: favorites + recent (persisted to JSON) ──────────────────
local MODEL_STATE_PATH = vim.fn.stdpath('data') .. '/ai_model_state.json'
local model_state = nil  -- lazy-loaded

local function load_model_state()
  if model_state then return model_state end
  local f = io.open(MODEL_STATE_PATH, 'r')
  if not f then
    model_state = { favorites = {}, recent = {} }
    return model_state
  end
  local data = f:read('*a'); f:close()
  local ok, tbl = pcall(vim.fn.json_decode, data)
  if ok and type(tbl) == 'table' then
    model_state = tbl
    if not model_state.favorites then model_state.favorites = {} end
    if not model_state.recent then model_state.recent = {} end
  else
    model_state = { favorites = {}, recent = {} }
  end
  return model_state
end

local function save_model_state()
  if not model_state then return end
  local f = io.open(MODEL_STATE_PATH, 'w')
  if f then f:write(vim.fn.json_encode(model_state)); f:close() end
end

local function is_favorite(provider_id, model_id)
  local ms = load_model_state()
  for _, fav in ipairs(ms.favorites) do
    if fav.provider == provider_id and fav.model == model_id then return true end
  end
  return false
end

local function toggle_favorite(provider_id, model_id)
  local ms = load_model_state()
  for i, fav in ipairs(ms.favorites) do
    if fav.provider == provider_id and fav.model == model_id then
      table.remove(ms.favorites, i)
      save_model_state()
      return false  -- removed
    end
  end
  table.insert(ms.favorites, { provider = provider_id, model = model_id })
  save_model_state()
  return true  -- added
end

local function add_recent_model(provider_id, model_id)
  local ms = load_model_state()
  -- Remove if already present (will re-insert at front)
  for i, r in ipairs(ms.recent) do
    if r.provider == provider_id and r.model == model_id then
      table.remove(ms.recent, i)
      break
    end
  end
  table.insert(ms.recent, 1, { provider = provider_id, model = model_id })
  while #ms.recent > 10 do table.remove(ms.recent) end
  save_model_state()
end


-- ── Backdrop overlay (used behind pickers and prompts) ───────────────────
local function create_backdrop()
  local bbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(bbuf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(bbuf, 'bufhidden', 'wipe')
  local bwin = vim.api.nvim_open_win(bbuf, false, {
    relative  = 'editor',
    row       = 0,
    col       = 0,
    width     = vim.o.columns,
    height    = vim.o.lines,
    style     = 'minimal',
    zindex    = 199,
    focusable = false,
    noautocmd = true,
  })
  vim.api.nvim_win_set_option(bwin, 'winhighlight', 'Normal:AiBackdrop')
  vim.api.nvim_win_set_option(bwin, 'winblend', 60)  -- ~59% opacity like OpenCode
  return { win = bwin, buf = bbuf }
end

local function close_backdrop(bd)
  if bd and bd.win and vim.api.nvim_win_is_valid(bd.win) then
    pcall(vim.api.nvim_win_close, bd.win, true)
  end
end


-- ── Top bar ───────────────────────────────────────────────────────────────
-- Line 0 (winbar): " agent ▼  [spinner]         + ↑Xk ↓Yk  provider · model "
-- Line 1 (buffer): "────────────────────────────────────────────────────────"

-- Token formatter: 1234 → "1k", 12345 → "12k", 234 → "234"
local function fmt_tok(n)
  if n == nil or n == 0 then return '0' end
  if n >= 1000 then return math.floor(n / 1000) .. 'k' end
  return tostring(n)
end

render_topbar = function()
  if not S.topbar_win or not win_ok(S.topbar_win) then return end
  if not S.topbar_buf or not vim.api.nvim_buf_is_valid(S.topbar_buf) then return end

  local function chip(hl, text)
    return '%#' .. hl .. '#' .. text:gsub('%%', '%%%%') .. '%*'
  end

  local provider  = config.get_provider()
  local model     = config.get_model()
  local disp_m    = #model > 22 and (model:sub(1, 20) .. '…') or model
  local streaming = S.is_streaming

  -- Left: title with breathing room (OpenCode: generous padding)
  local left = chip('AiTopBg', '  ')
    .. chip('AiTopTitle', 'PandaVim AI')
    .. chip('AiTopBg', '  ')

  -- Right: provider · model, with padding
  local right = ''
  if streaming then
    right = right .. chip('AiTopStream', '● ')
      .. chip('AiTopBg', ' ')
  end
  if S.token_last.prompt > 0 or S.token_last.completion > 0 then
    local tok_str = '↑' .. fmt_tok(S.token_last.prompt)
      .. ' ↓' .. fmt_tok(S.token_last.completion)
    right = right .. chip('AiTopTokens', tok_str)
      .. chip('AiTopBg', '  ')
  end
  right = right
    .. chip('AiTopProvider', provider)
    .. chip('AiTopBg', ' · ')
    .. chip('AiTopMeta', disp_m)
    .. chip('AiTopBg', '  ')

  local winbar = left .. '%=' .. right
  pcall(vim.api.nvim_win_set_option, S.topbar_win, 'winbar', winbar)

  -- Separator line in the buffer
  pcall(vim.api.nvim_buf_set_option, S.topbar_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(S.topbar_buf, 0, -1, false,
    { string.rep('─', W) })
  if NS_TOPBAR then
    vim.api.nvim_buf_clear_namespace(S.topbar_buf, NS_TOPBAR, 0, -1)
    vim.api.nvim_buf_add_highlight(S.topbar_buf, NS_TOPBAR, 'AiTopSep', 0, 0, -1)
  end
  pcall(vim.api.nvim_buf_set_option, S.topbar_buf, 'modifiable', false)
end

-- ── Top bar keymaps / pickers ─────────────────────────────────────────────
-- ── Native picker float ───────────────────────────────────────────────────
-- Modelled after OpenCode's DialogSelect.
--
-- opts:
--   title        string            — header
--   items        table             — flat list of values (used when no categories)
--   categories   table|nil         — [{label, items[]}] for grouped display
--   format       fn(item)->string  — display label (default tostring)
--   format_desc  fn(item)->string|nil — muted description after title
--   format_footer fn(item)->string|nil — right-aligned muted text (e.g. "Free")
--   format_gutter fn(item)->{text,hl}|nil — left gutter with custom highlight (e.g. green ✓)
--   current      fn(item)->bool|nil — returns true for the currently-active item (● dot)
--   on_confirm   fn(item)          — called with selected item on <CR>
--   on_cancel    fn()|nil          — called when dismissed
--   footer_keys  table|nil         — [{key,label}] shown as hint at bottom
--   on_keypress  fn(key,close,item)->bool|nil — intercept keys; item = highlighted item
local function open_picker(opts)
  local title       = opts.title or 'Select'
  local on_confirm  = opts.on_confirm or function() end
  local on_cancel   = opts.on_cancel  or function() end
  local fmt         = opts.format or tostring
  local fmt_desc    = opts.format_desc     -- fn(item)->string|nil
  local fmt_footer  = opts.format_footer   -- fn(item)->string|nil
  local fmt_gutter  = opts.format_gutter   -- fn(item)->{text,hl}|nil
  local fmt_current = opts.current         -- fn(item)->bool|nil
  local footer_keys = opts.footer_keys or {}   -- [{key,label}]
  local on_keypress = opts.on_keypress         -- fn(key,close,item)->bool

  -- Build flat all_items + category_map from either opts.items or opts.categories
  local all_items      = {}
  local category_order = {}   -- list of category label strings in insertion order
  local category_map   = {}   -- label -> [items]

  if opts.categories and #opts.categories > 0 then
    for _, cat in ipairs(opts.categories) do
      table.insert(category_order, cat.label)
      category_map[cat.label] = cat.items
      for _, item in ipairs(cat.items) do
        table.insert(all_items, item)
      end
    end
  else
    all_items = opts.items or {}
  end

  if #all_items == 0 then
    vim.notify('AI: no items to pick from', vim.log.levels.WARN)
    on_cancel()
    return
  end

  -- ── constants ──────────────────────────────────────────────────────────────
  -- OpenCode uses medium=60, large=88; we scale to terminal.
  -- MAX_ITEMS: no hard ceiling — on a tall terminal the picker grows to fill
  -- the screen (minus 8 rows for chrome: title + gap + input + gap + footer +
  -- top/bottom padding + cushion). Previously capped at 26 which felt cramped
  -- on large terminals and made scrolling feel necessary even when not.
  local FLOAT_W   = math.min(88, math.max(52, vim.o.columns - 6))
  local MAX_ITEMS = math.max(8, vim.o.lines - 8)
  local ns        = vim.api.nvim_create_namespace('AiPicker')

  -- ── state ──────────────────────────────────────────────────────────────────
  local query      = ''
  local filtered   = {}   -- flat list of matching items
  local sel        = 1    -- 1-indexed into filtered
  local scroll_top = 1    -- first visible item row (1-indexed into filtered)

  -- Build a virtual row list that interleaves category headers with items.
  -- Each row is { type='cat', label=... } or { type='item', item=..., rank=... }
  -- or { type='blank' }. This is rebuilt whenever filtered/query changes.
  local display_rows = {}  -- virtual rows for the current filtered state

  local function rebuild_display_rows()
    display_rows = {}
    local show_cats = query == '' and #category_order > 0
    if show_cats then
      local non_empty = 0
      local rank = 0
      for _, lbl in ipairs(category_order) do
        local cat_items = category_map[lbl] or {}
        local cat_filtered = {}
        for _, fi in ipairs(filtered) do
          for _, ci in ipairs(cat_items) do
            if fi == ci then table.insert(cat_filtered, fi); break end
          end
        end
        if #cat_filtered > 0 then
          non_empty = non_empty + 1
          if non_empty > 1 then
            table.insert(display_rows, { type = 'blank' })
          end
          table.insert(display_rows, { type = 'cat', label = lbl })
          for _, item in ipairs(cat_filtered) do
            rank = rank + 1
            table.insert(display_rows, { type = 'item', item = item, rank = rank })
          end
        end
      end
    else
      for i, item in ipairs(filtered) do
        table.insert(display_rows, { type = 'item', item = item, rank = i })
      end
    end
  end

  -- rebuild filtered from all_items matching query (fuzzy when typing)
  local function rebuild()
    local q = query
    filtered = {}
    if q == '' then
      for _, item in ipairs(all_items) do table.insert(filtered, item) end
    else
      local scored = {}
      for _, item in ipairs(all_items) do
        local label = fmt(item)
        local sc = fuzzy_score(q, label)
        -- Also try matching against description if available
        if not sc and fmt_desc then
          local desc = fmt_desc(item)
          if desc then sc = fuzzy_score(q, desc) end
        end
        if sc then table.insert(scored, { item = item, score = sc }) end
      end
      table.sort(scored, function(a, b) return a.score > b.score end)
      for _, s in ipairs(scored) do table.insert(filtered, s.item) end
    end
    sel = math.max(1, math.min(sel, math.max(1, #filtered)))
    -- rebuild virtual display rows (categories + items interleaved)
    rebuild_display_rows()
    -- adjust scroll_top to keep sel visible within display_rows
    -- find the display row containing the selected item
    local sel_drow = 1
    for di, dr in ipairs(display_rows) do
      if dr.type == 'item' and dr.rank == sel then sel_drow = di; break end
    end
    if sel_drow < scroll_top then scroll_top = sel_drow end
    if sel_drow > scroll_top + MAX_ITEMS - 1 then scroll_top = sel_drow - MAX_ITEMS + 1 end
    if scroll_top < 1 then scroll_top = 1 end
  end

  -- ── buffer ─────────────────────────────────────────────────────────────────
  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(pbuf, 'buftype',   'nofile')
  vim.api.nvim_buf_set_option(pbuf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(pbuf, 'swapfile',  false)
  vim.api.nvim_buf_set_option(pbuf, 'modifiable', true)

  -- ── window ─────────────────────────────────────────────────────────────────
  local closed = false

  local function float_height()
    local total_rows = #display_rows
    if total_rows == 0 then total_rows = 1 end  -- "No results found"
    local visible = math.min(total_rows, MAX_ITEMS)
    local footer = #footer_keys > 0 and 1 or 0
    -- Layout: title + blank + input + blank + items + footer + bottom pad
    return visible + footer + 5  -- +1 title +1 gap +1 input +1 gap +1 bottom pad
  end

  local function open_win()
    local h = float_height()
    return vim.api.nvim_open_win(pbuf, true, {
      relative  = 'editor',
      row       = math.floor((vim.o.lines   - h) / 2),
      col       = math.floor((vim.o.columns - FLOAT_W) / 2),
      width     = FLOAT_W,
      height    = h,
      style     = 'minimal',
      border    = 'rounded',
      zindex    = 200,
      noautocmd = true,
    })
  end

  rebuild()
  local backdrop = create_backdrop()
  local pwin = open_win()

  vim.api.nvim_win_set_option(pwin, 'winhighlight',
    'Normal:AiPickerBg,NormalFloat:AiPickerBg,FloatBorder:AiTopSep,Cursor:AiPickerCursor')
  vim.api.nvim_win_set_option(pwin, 'cursorline', false)
  vim.api.nvim_win_set_option(pwin, 'wrap',       false)
  vim.api.nvim_win_set_option(pwin, 'number',     false)
  vim.api.nvim_win_set_option(pwin, 'relativenumber', false)
  vim.api.nvim_win_set_option(pwin, 'signcolumn', 'no')

  -- ── render (OpenCode-style) ─────────────────────────────────────────────────
  local function render()
    if not vim.api.nvim_win_is_valid(pwin) then return end

    local h = float_height()
    pcall(vim.api.nvim_win_set_config, pwin, {
      relative = 'editor',
      row      = math.floor((vim.o.lines   - h) / 2),
      col      = math.floor((vim.o.columns - FLOAT_W) / 2),
      width    = FLOAT_W,
      height   = h,
    })

    local lines    = {}
    local hl_rows  = {}   -- { row(0-indexed), hl_group } for full-line highlights
    local ext_data = {}   -- { row, col_start, col_end, hl_group } for partial highlights

    -- row 0: title (left, bold, padded 4) + position indicator (when scrolling
    -- is in play) + "esc" (right, muted)
    local esc_str    = 'esc '
    -- Show "sel/total" when the list doesn't fit — gives the user a visible
    -- anchor so they always know their position even if the highlighted row
    -- briefly moves at a boundary.
    local pos_str = ''
    if #filtered > MAX_ITEMS then
      pos_str = string.format('%d/%d  ', sel, #filtered)
    end
    local title_left = '    ' .. title  -- 4-space left padding (OpenCode paddingLeft=4)
    local title_pad  = math.max(0, FLOAT_W - vim.fn.strdisplaywidth(title_left) - #pos_str - #esc_str)
    local title_line = title_left .. string.rep(' ', title_pad) .. pos_str .. esc_str
    table.insert(lines, title_line)
    table.insert(hl_rows, { #lines - 1, 'AiPickerTitle' })
    -- Esc label sits at the very end of the line.
    table.insert(ext_data, { row = #lines - 1, col_start = #title_line - #esc_str, col_end = #title_line, hl = 'AiPickerEsc' })
    -- Position indicator sits immediately to the left of the esc label.
    if pos_str ~= '' then
      local pos_end   = #title_line - #esc_str
      local pos_start = pos_end - #pos_str
      table.insert(ext_data, {
        row = #lines - 1, col_start = pos_start, col_end = pos_end, hl = 'AiPickerHint',
      })
    end

    -- row 1: blank line (gap between title and input, OpenCode paddingTop=1)
    table.insert(lines, string.rep(' ', FLOAT_W))
    table.insert(hl_rows, { #lines - 1, 'AiPickerBg' })

    -- row 2: search input (padded 4, with virtual placeholder "Search" when empty)
    table.insert(lines, '    > ' .. query)
    local input_row = #lines - 1
    table.insert(hl_rows, { input_row, 'AiPickerQuery' })

    -- row 3: blank line (gap between input and items, OpenCode gap=1)
    table.insert(lines, string.rep(' ', FLOAT_W))
    table.insert(hl_rows, { #lines - 1, 'AiPickerBg' })

    -- ── helper: build one item line with current/cursor separation ──────────
    -- Returns line string and extmark positions
    local function build_item_line(item, is_sel)
      local is_cur = fmt_current and fmt_current(item) or false
      local gutter = fmt_gutter and fmt_gutter(item) or nil  -- {text, hl}

      -- Prefix with padding (OpenCode: paddingLeft=1 on scrollbox + 1 on item)
      local prefix
      if is_cur then
        prefix = '   ● '
      elseif gutter then
        prefix = '   ' .. gutter.text .. ' '
      else
        prefix = '     '
      end

      local label  = fmt(item)
      local desc   = fmt_desc and fmt_desc(item) or nil
      local foot   = fmt_footer and fmt_footer(item) or nil

      -- Truncate label if it exceeds available space (5 prefix + 2 right pad)
      local max_label = FLOAT_W - 7
      if foot then max_label = max_label - #foot - 2 end
      if desc then max_label = max_label - #desc - 2 end
      if vim.fn.strdisplaywidth(label) > max_label then
        label = label:sub(1, math.max(1, max_label - 1)) .. '…'
      end

      local line = prefix .. label
      local ext = { is_current = is_cur }

      if desc then
        ext.desc_start = #line + 2
        line = line .. '  ' .. desc
        ext.desc_end = #line
      end

      if foot then
        local pad = math.max(2, FLOAT_W - #line - #foot - 2)  -- -2 for right padding
        ext.foot_start = #line + pad
        line = line .. string.rep(' ', pad) .. foot
        ext.foot_end = #line
      end

      -- Record the ● dot position for current-item coloring (after '   ')
      if is_cur then
        ext.dot_start = 3  -- byte offset of ● (after 3 leading spaces)
        ext.dot_end   = 3 + #'●'
      elseif gutter then
        ext.gutter_start = 3
        ext.gutter_end   = 3 + #gutter.text
        ext.gutter_hl    = gutter.hl
      end

      -- Pad to full width
      if #line < FLOAT_W then line = line .. string.rep(' ', FLOAT_W - #line) end
      return line, ext
    end

    -- Track extmark data per rendered item line
    local item_ext = {}

    -- Render from display_rows with unified scroll logic
    local visible_end = math.min(#display_rows, scroll_top + MAX_ITEMS - 1)
    for di = scroll_top, visible_end do
      local dr = display_rows[di]
      if dr.type == 'blank' then
        table.insert(lines, string.rep(' ', FLOAT_W))
        table.insert(hl_rows, { #lines - 1, 'AiPickerBg' })
      elseif dr.type == 'cat' then
        local sep_label = '     ' .. dr.label
        local sep_line  = sep_label .. string.rep(' ', math.max(0, FLOAT_W - #sep_label))
        table.insert(lines, sep_line)
        table.insert(hl_rows, { #lines - 1, 'AiPickerCat' })
      elseif dr.type == 'item' then
        local is_sel = (dr.rank == sel)
        local line, ext = build_item_line(dr.item, is_sel)
        table.insert(lines, line)
        local hl = is_sel and 'AiPickerSel' or 'AiPickerItem'
        table.insert(hl_rows, { #lines - 1, hl })
        table.insert(item_ext, { row = #lines - 1, ext = ext, is_sel = is_sel })
      end
    end

    if #filtered == 0 then
      table.insert(lines, '    No results found')
      table.insert(hl_rows, { #lines - 1, 'AiPickerHint' })
    end

    -- footer: OpenCode-style "**Title** key" — bold action name, then muted keybind
    if #footer_keys > 0 then
      local foot_line = '  '
      local foot_ext = {}
      for fi, fk in ipairs(footer_keys) do
        if fi > 1 then foot_line = foot_line .. '   ' end
        local name_start = #foot_line
        foot_line = foot_line .. fk.label
        local name_end = #foot_line
        foot_line = foot_line .. ' '
        local key_start = #foot_line
        foot_line = foot_line .. fk.key
        local key_end = #foot_line
        table.insert(foot_ext, { ns = name_start, ne = name_end, ks = key_start, ke = key_end })
      end
      if #foot_line < FLOAT_W then foot_line = foot_line .. string.rep(' ', FLOAT_W - #foot_line) end
      table.insert(lines, foot_line)
      local foot_row = #lines - 1
      table.insert(hl_rows, { foot_row, 'AiPickerBg' })
      for _, fe in ipairs(foot_ext) do
        table.insert(ext_data, { row = foot_row, col_start = fe.ns, col_end = fe.ne, hl = 'AiPickerFootKey' })
        table.insert(ext_data, { row = foot_row, col_start = fe.ks, col_end = fe.ke, hl = 'AiPickerFootBind' })
      end
    end

    -- Bottom padding row (OpenCode: paddingBottom=1)
    table.insert(lines, string.rep(' ', FLOAT_W))
    table.insert(hl_rows, { #lines - 1, 'AiPickerBg' })

    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)

    -- Full-line highlights
    for _, hr in ipairs(hl_rows) do
      pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, hr[2], hr[1], 0, -1)
    end

    -- Partial highlights (title esc, footer keys)
    for _, ed in ipairs(ext_data) do
      pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, ed.hl, ed.row, ed.col_start, ed.col_end)
    end

    -- Per-item overlays: description, footer, current dot
    for _, ie in ipairs(item_ext) do
      if ie.is_sel then
        -- Selected row: everything gets AiPickerSel (already applied).
        -- No overlay needed — the vivid bg + dark fg applies to all text.
      else
        -- Description column: dimmed
        if ie.ext.desc_start then
          pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, 'AiPickerHint', ie.row, ie.ext.desc_start, ie.ext.desc_end)
        end
        -- Footer column: dimmed
        if ie.ext.foot_start then
          pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, 'AiPickerHint', ie.row, ie.ext.foot_start, ie.ext.foot_end)
        end
        -- Current item ● dot: primary peach color
        if ie.ext.is_current and ie.ext.dot_start then
          pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, 'AiPickerCurrent', ie.row, ie.ext.dot_start, ie.ext.dot_end)
        end
        -- Custom gutter highlight (e.g. green ✓)
        if ie.ext.gutter_start and ie.ext.gutter_hl then
          pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, ie.ext.gutter_hl, ie.row, ie.ext.gutter_start, ie.ext.gutter_end)
        end
      end
    end

    -- Show "Search" placeholder as virtual text when query is empty
    if query == '' then
      pcall(vim.api.nvim_buf_set_extmark, pbuf, ns, input_row, 6, {
        virt_text = { { 'Search', 'AiPickerHint' } },
        virt_text_pos = 'overlay',
      })
    end

    -- Cursor on the input row (row 3, 1-indexed), after '    > '
    pcall(vim.api.nvim_win_set_cursor, pwin, { input_row + 1, 6 + #query })
  end

  -- ── actions ────────────────────────────────────────────────────────────────
  local function do_close()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_name, 'AiPickerInput')
    pcall(vim.api.nvim_win_close, pwin, true)
    close_backdrop(backdrop)
    refocus_input()
  end

  local function do_confirm()
    local item = filtered[sel]
    do_close()
    if item then vim.schedule(function() on_confirm(item) end) end
  end

  local function do_cancel()
    do_close()
    vim.schedule(on_cancel)
  end

  -- Find the display_rows index for a given item rank (1-indexed into filtered)
  local function drow_for_rank(rank)
    for di, dr in ipairs(display_rows) do
      if dr.type == 'item' and dr.rank == rank then return di end
    end
    return 1
  end

  -- Ensure scroll_top keeps the selected item's display row visible
  local function ensure_visible()
    local di = drow_for_rank(sel)
    if di < scroll_top then scroll_top = di end
    -- scroll back to show category header if it's right above
    if scroll_top > 1 and display_rows[scroll_top - 1]
      and display_rows[scroll_top - 1].type == 'cat' then
      scroll_top = scroll_top - 1
      if scroll_top > 1 and display_rows[scroll_top - 1]
        and display_rows[scroll_top - 1].type == 'blank' then
        scroll_top = scroll_top - 1
      end
    end
    if di > scroll_top + MAX_ITEMS - 1 then scroll_top = di - MAX_ITEMS + 1 end
    if scroll_top < 1 then scroll_top = 1 end
    -- Defensive post-condition: if `di` is still outside [scroll_top,
    -- scroll_top + MAX_ITEMS - 1], clamp again. This closes the class of
    -- bugs where a category-header adjustment above could leave sel off the
    -- visible window bottom.
    local last = scroll_top + MAX_ITEMS - 1
    if di > last then scroll_top = di - MAX_ITEMS + 1 end
    if scroll_top < 1 then scroll_top = 1 end
  end

  local function move(delta)
    if #filtered == 0 then return end
    sel = sel + delta
    if sel < 1 then sel = #filtered end
    if sel > #filtered then sel = 1 end
    ensure_visible()
    render()
  end

  -- ── keymaps ────────────────────────────────────────────────────────────────
  local ib = { buffer = pbuf, noremap = true, silent = true, nowait = true }
  local nb = { buffer = pbuf, noremap = true, silent = true, nowait = true }

  vim.keymap.set('i', '<Up>',   function() move(-1) end, ib)
  vim.keymap.set('i', '<Down>', function() move(1)  end, ib)
  vim.keymap.set('i', '<C-p>',  function() move(-1) end, ib)
  vim.keymap.set('i', '<C-n>',  function() move(1)  end, ib)
  vim.keymap.set('i', '<C-k>',  function() move(-1) end, ib)
  vim.keymap.set('i', '<C-j>',  function() move(1)  end, ib)
  vim.keymap.set('i', '<CR>',   do_confirm,              ib)
  vim.keymap.set('i', '<Tab>',  do_confirm,              ib)
  vim.keymap.set('i', '<Esc>',  do_cancel,               ib)

  vim.keymap.set('n', 'j',      function() move(1)  end, nb)
  vim.keymap.set('n', 'k',      function() move(-1) end, nb)
  vim.keymap.set('n', '<Down>', function() move(1)  end, nb)
  vim.keymap.set('n', '<Up>',   function() move(-1) end, nb)
  vim.keymap.set('n', '<C-n>',  function() move(1)  end, nb)
  vim.keymap.set('n', '<C-p>',  function() move(-1) end, nb)
  vim.keymap.set('n', '<CR>',   do_confirm,              nb)
  vim.keymap.set('n', '<Esc>',  do_cancel,               nb)
  vim.keymap.set('n', 'q',      do_cancel,               nb)

  -- Page navigation
  local page_size = math.max(1, MAX_ITEMS - 2)
  local function page_move(delta)
    if #filtered == 0 then return end
    sel = math.max(1, math.min(sel + delta, #filtered))
    ensure_visible()
    render()
  end
  local function goto_first()
    sel = 1; scroll_top = 1; render()
  end
  local function goto_last()
    sel = #filtered
    ensure_visible()
    render()
  end

  vim.keymap.set('i', '<PageDown>', function() page_move(page_size)  end, ib)
  vim.keymap.set('i', '<PageUp>',  function() page_move(-page_size) end, ib)
  vim.keymap.set('i', '<Home>',    goto_first,                           ib)
  vim.keymap.set('i', '<End>',     goto_last,                            ib)
  vim.keymap.set('n', '<PageDown>', function() page_move(page_size)  end, nb)
  vim.keymap.set('n', '<PageUp>',  function() page_move(-page_size) end, nb)
  vim.keymap.set('n', '<Home>',    goto_first,                           nb)
  vim.keymap.set('n', '<End>',     goto_last,                            nb)

  -- Mouse wheel: advance selection by 3 rows per click, matching most TUI
  -- conventions. Bound buffer-local so it doesn't leak to other windows.
  local function wheel_down() page_move(3)  end
  local function wheel_up()   page_move(-3) end
  vim.keymap.set('i', '<ScrollWheelDown>', wheel_down, ib)
  vim.keymap.set('i', '<ScrollWheelUp>',   wheel_up,   ib)
  vim.keymap.set('n', '<ScrollWheelDown>', wheel_down, nb)
  vim.keymap.set('n', '<ScrollWheelUp>',   wheel_up,   nb)

  -- Extra keypress handler for on_keypress (e.g. 'p' → open provider picker)
  -- Passes the currently highlighted item as the third argument
  if on_keypress then
    for _, fk in ipairs(footer_keys) do
      local key = fk.key
      local bopt_i = vim.tbl_extend('force', ib, {})
      local bopt_n = vim.tbl_extend('force', nb, {})
      vim.keymap.set('i', key, function()
        if on_keypress then
          local handled = on_keypress(key, do_close, filtered[sel])
          if handled then return end
        end
      end, bopt_i)
      vim.keymap.set('n', key, function()
        if on_keypress then
          local handled = on_keypress(key, do_close, filtered[sel])
          if handled then return end
        end
      end, bopt_n)
    end
  end

  -- ── TextChangedI ───────────────────────────────────────────────────────────
  local ag = vim.api.nvim_create_augroup('AiPickerInput', { clear = true })
  vim.api.nvim_create_autocmd('TextChangedI', {
    group  = ag,
    buffer = pbuf,
    callback = function()
      if closed then return end
      -- Input is on row 2 (0-indexed): '    > query' or '    > Search' (placeholder)
      local raw   = vim.api.nvim_buf_get_lines(pbuf, 2, 3, false)[1] or ''
      local new_q = raw:match('^%s*>%s?(.*)$') or raw
      if new_q ~= query then
        query      = new_q
        sel        = 1
        scroll_top = 1
        rebuild()
      end
      render()
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    group    = ag,
    buffer   = pbuf,
    once     = true,
    callback = function()
      vim.schedule(function()
        if not closed then do_cancel() end
      end)
    end,
  })

  render()
  vim.api.nvim_win_set_cursor(pwin, { 2, 3 })
  vim.cmd('startinsert!')
end

-- ── open_prompt ───────────────────────────────────────────────────────────────
-- Lightweight single-field text-input overlay — mirrors OpenCode's DialogPrompt.
-- Opens a small centered float; user types in insert mode; <CR> confirms, <Esc> cancels.
--
-- opts:
--   title        string          — bold header line
--   description  string|nil      — optional muted second line
--   placeholder  string|nil      — ghost text hint in the input area
--   masked       bool|nil        — show *** instead of typed chars (for API keys)
--   initial      string|nil      — prefill the input
--   on_confirm   fn(value)       — called with trimmed text on <CR>
--   on_cancel    fn()|nil        — called on <Esc>
local function open_prompt(opts)
  local title       = opts.title or 'Input'
  local description = opts.description
  local placeholder = opts.placeholder or 'Type and press Enter…'
  local masked      = opts.masked or false
  local on_confirm  = opts.on_confirm or function() end
  local on_cancel   = opts.on_cancel  or function() end
  local initial_val = opts.initial    or ''

  local PROMPT_W = math.min(80, math.max(44, vim.o.columns - 10))
  local ns       = vim.api.nvim_create_namespace('AiPrompt')
  local closed   = false
  local value    = initial_val   -- current typed text

  -- height: title + (description?) + input + footer
  local function win_height()
    return (description and 4 or 3)
  end

  local pbuf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(pbuf, 'buftype',    'nofile')
  vim.api.nvim_buf_set_option(pbuf, 'bufhidden',  'wipe')
  vim.api.nvim_buf_set_option(pbuf, 'swapfile',   false)
  vim.api.nvim_buf_set_option(pbuf, 'modifiable', true)

  local h    = win_height()
  local prompt_backdrop = create_backdrop()
  local pwin = vim.api.nvim_open_win(pbuf, true, {
    relative  = 'editor',
    row       = math.floor((vim.o.lines   - h) / 2),
    col       = math.floor((vim.o.columns - PROMPT_W) / 2),
    width     = PROMPT_W,
    height    = h,
    style     = 'minimal',
    border    = 'rounded',
    zindex    = 210,
    noautocmd = true,
  })
  vim.api.nvim_win_set_option(pwin, 'winhighlight',
    'Normal:AiPickerBg,NormalFloat:AiPickerBg,FloatBorder:AiTopSep,Cursor:AiPickerCursor')
  vim.api.nvim_win_set_option(pwin, 'cursorline',     false)
  vim.api.nvim_win_set_option(pwin, 'wrap',           false)
  vim.api.nvim_win_set_option(pwin, 'number',         false)
  vim.api.nvim_win_set_option(pwin, 'relativenumber', false)
  vim.api.nvim_win_set_option(pwin, 'signcolumn',     'no')

  local function render()
    if not vim.api.nvim_win_is_valid(pwin) then return end
    local lines    = {}
    local hl_rows  = {}
    local ext_data = {}

    -- title line: bold title (left) + muted "esc" (right) — OpenCode style
    local esc_str   = 'esc '
    local title_pad = math.max(0, PROMPT_W - vim.fn.strdisplaywidth(title) - 2 - #esc_str)
    -- row 0: title (4-space padding, like OpenCode)
    local title_left = '    ' .. title
    local title_pad2 = math.max(0, PROMPT_W - vim.fn.strdisplaywidth(title_left) - #esc_str)
    local title_line = title_left .. string.rep(' ', title_pad2) .. esc_str
    table.insert(lines, title_line)
    table.insert(hl_rows, { 0, 'AiPickerTitle' })
    table.insert(ext_data, { row = 0, col_start = #title_line - #esc_str, col_end = #title_line, hl = 'AiPickerEsc' })

    -- optional description (4-space padding)
    if description then
      table.insert(lines, '    ' .. description)
      table.insert(hl_rows, { #lines - 1, 'AiPickerHint' })
    end

    -- input line: "    > " + value (or placeholder if empty)
    local display_val
    if masked and value ~= '' then
      display_val = string.rep('*', #value)
    elseif value == '' then
      display_val = placeholder
    else
      display_val = value
    end
    table.insert(lines, '    > ' .. display_val)
    local input_row = #lines - 1
    if value == '' then
      table.insert(hl_rows, { input_row, 'AiPickerHint' })
    else
      table.insert(hl_rows, { input_row, 'AiPickerQuery' })
    end

    -- footer: "    enter submit"
    local foot = '    enter submit'
    table.insert(lines, foot)
    local foot_row = #lines - 1
    table.insert(hl_rows, { foot_row, 'AiPickerBg' })
    table.insert(ext_data, { row = foot_row, col_start = 4, col_end = 9, hl = 'AiPickerFootBind' })
    table.insert(ext_data, { row = foot_row, col_start = 10, col_end = #foot, hl = 'AiPickerFootKey' })

    vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
    vim.api.nvim_buf_clear_namespace(pbuf, ns, 0, -1)
    for _, hr in ipairs(hl_rows) do
      pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, hr[2], hr[1], 0, -1)
    end
    for _, ed in ipairs(ext_data) do
      pcall(vim.api.nvim_buf_add_highlight, pbuf, ns, ed.hl, ed.row, ed.col_start, ed.col_end)
    end

    -- cursor at end of input line (after '    > ')
    local col = 6 + (masked and #string.rep('*', #value) or #value)
    if value == '' then col = 6 + #placeholder end
    pcall(vim.api.nvim_win_set_cursor, pwin, { input_row + 1, math.min(col, PROMPT_W - 1) })
  end

  local function do_close()
    if closed then return end
    closed = true
    pcall(vim.api.nvim_del_augroup_by_name, 'AiPromptInput')
    pcall(vim.api.nvim_win_close, pwin, true)
    close_backdrop(prompt_backdrop)
    refocus_input()
  end

  local function do_confirm()
    local v = vim.trim(value)
    do_close()
    vim.schedule(function() on_confirm(v) end)
  end

  local function do_cancel()
    do_close()
    vim.schedule(on_cancel)
  end

  local ib = { buffer = pbuf, noremap = true, silent = true, nowait = true }
  local nb = { buffer = pbuf, noremap = true, silent = true, nowait = true }
  vim.keymap.set('i', '<CR>',  do_confirm, ib)
  vim.keymap.set('i', '<Esc>', do_cancel,  ib)
  vim.keymap.set('n', '<CR>',  do_confirm, nb)
  vim.keymap.set('n', '<Esc>', do_cancel,  nb)
  vim.keymap.set('n', 'q',     do_cancel,  nb)

  local ag = vim.api.nvim_create_augroup('AiPromptInput', { clear = true })
  vim.api.nvim_create_autocmd('TextChangedI', {
    group  = ag,
    buffer = pbuf,
    callback = function()
      if closed then return end
      local input_row = description and 2 or 1  -- 0-indexed
      local raw = vim.api.nvim_buf_get_lines(pbuf, input_row, input_row + 1, false)[1] or ''
      local new_v = raw:match('^%s*>%s?(.*)$') or raw
      -- if user typed into placeholder area, strip placeholder artefacts
      if new_v:find(placeholder, 1, true) == 1 then
        new_v = new_v:sub(#placeholder + 1)
      end
      value = new_v
      render()
    end,
  })

  vim.api.nvim_create_autocmd('WinLeave', {
    group    = ag,
    buffer   = pbuf,
    once     = true,
    callback = function()
      vim.schedule(function()
        if not closed then do_cancel() end
      end)
    end,
  })

  render()
  -- Put cursor on the input line
  local input_row = description and 3 or 2
  if initial_val ~= '' then
    pcall(vim.api.nvim_win_set_cursor, pwin, { input_row, 3 + #initial_val })
  else
    pcall(vim.api.nvim_win_set_cursor, pwin, { input_row, 3 })
  end
  vim.cmd('startinsert!')
end

-- ── open_model_picker ─────────────────────────────────────────────────────────
-- Modelled after OpenCode's DialogModel:
--   Categories: Favorites → Recent → per-provider groups
--   Footer keys: 'p' → provider picker, 'f' → toggle favorite
--   Description: provider name (in Fav/Recent) or "(Favorite)" in provider section
--   Current model marked with ●
-- Can be scoped to a single provider via the optional provider_filter arg.
open_model_picker = function(provider_filter)
  local current_model    = config.get_model()
  local current_provider = config.get_provider()
  local ms = load_model_state()

  -- Build a lookup of all valid models keyed by "provider/model"
  local all_providers = providers_m.list()
  local model_lookup = {}  -- "prov/model" → item
  for _, prov in ipairs(all_providers) do
    if not provider_filter or prov.name == provider_filter then
      for _, mid in ipairs(providers_m.model_ids(prov)) do
        local key = prov.name .. '/' .. mid
        model_lookup[key] = {
          provider_id      = prov.name,
          provider_display = prov.display_name or prov.name,
          model_id         = mid,
          model_name       = providers_m.model_name(prov, mid),
        }
      end
    end
  end

  if vim.tbl_isempty(model_lookup) then
    toast('No models configured', 'warn')
    return
  end

  -- Track which models go into Favorites / Recent (to exclude from provider sections)
  local used = {}  -- set of "prov/model" keys

  -- Favorites category
  local fav_items = {}
  for _, fav in ipairs(ms.favorites) do
    local key = fav.provider .. '/' .. fav.model
    local item = model_lookup[key]
    if item then
      table.insert(fav_items, item)
      used[key] = true
    end
  end

  -- Recent category (minus favorites)
  local recent_items = {}
  for _, r in ipairs(ms.recent) do
    local key = r.provider .. '/' .. r.model
    if not used[key] then
      local item = model_lookup[key]
      if item then
        table.insert(recent_items, item)
        used[key] = true
      end
    end
  end

  -- Per-provider categories (minus favorites and recent)
  local categories = {}
  if #fav_items > 0 then
    table.insert(categories, { label = 'Favorites', items = fav_items })
  end
  if #recent_items > 0 then
    table.insert(categories, { label = 'Recent', items = recent_items })
  end
  for _, prov in ipairs(all_providers) do
    if not provider_filter or prov.name == provider_filter then
      local prov_items = {}
      for _, mid in ipairs(providers_m.model_ids(prov)) do
        local key = prov.name .. '/' .. mid
        if not used[key] then
          local item = model_lookup[key]
          if item then table.insert(prov_items, item) end
        end
      end
      if #prov_items > 0 then
        table.insert(categories, {
          label = prov.display_name or prov.name,
          items = prov_items,
        })
      end
    end
  end

  open_picker({
    title      = provider_filter and ('Models — ' .. provider_filter) or 'Select model',
    categories = categories,
    format     = function(item)
      return item.model_name
    end,
    current    = function(item)
      return item.model_id == current_model and item.provider_id == current_provider
    end,
    format_desc = function(item)
      -- In Fav/Recent sections: show provider name
      -- In provider sections: show "(Favorite)" if favorited
      local in_fav_or_recent = false
      for _, f in ipairs(fav_items) do
        if f == item then in_fav_or_recent = true; break end
      end
      if not in_fav_or_recent then
        for _, r in ipairs(recent_items) do
          if r == item then in_fav_or_recent = true; break end
        end
      end
      if in_fav_or_recent then
        return item.provider_display
      elseif is_favorite(item.provider_id, item.model_id) then
        return '(Favorite)'
      end
      return nil
    end,
    footer_keys = {
      { key = 'p', label = 'Connect provider' },
      { key = 'f', label = 'Favorite' },
    },
    on_keypress = function(key, close_fn, selected)
      if key == 'p' then
        close_fn()
        vim.schedule(function() open_provider_picker() end)
        return true
      end
      if key == 'f' and selected then
        local added = toggle_favorite(selected.provider_id, selected.model_id)
        close_fn()
        toast(added and 'Added to favorites' or 'Removed from favorites', 'info')
        vim.schedule(function() open_model_picker(provider_filter) end)
        return true
      end
    end,
    on_confirm = function(item)
      add_recent_model(item.provider_id, item.model_id)
      config.set_provider(item.provider_id)
      config.set_model(item.model_id)
      render_topbar()
      render_input_bar()
    end,
  })
end

-- ── open_provider_picker ──────────────────────────────────────────────────────
-- ── open_provider_picker ──────────────────────────────────────────────────────
-- Modelled after OpenCode's DialogProvider:
--   Categories: "Popular" (priority providers) + "Other"
--   Gutter: ✓ for connected providers
--   Descriptions: per-provider hints like "(API key)", "(Recommended)"
--   Sorted by priority within each category
-- Selecting a connected provider → opens model picker scoped to that provider.
-- Selecting an unconnected provider → short API key prompt (builtin) or full wizard (custom).
-- Footer key: 'a' → add a new custom provider.
local PROVIDER_PRIORITY = {
  openai    = 1,
  anthropic = 2,
  google    = 3,
  groq      = 4,
  mistral   = 5,
  deepseek  = 6,
}

local PROVIDER_DESC = {
  openai     = '(API key)',
  anthropic  = '(API key)',
  google     = '(API key)',
  groq       = '(API key, Free tier)',
  mistral    = '(API key)',
  deepseek   = '(API key)',
  xai        = '(API key)',
  openrouter = '(API key, Multi-provider)',
  together   = '(API key)',
  fireworks  = '(API key)',
  perplexity = '(API key, Search)',
  cohere     = '(API key)',
  ollama     = '(Local, No key needed)',
}

-- API key hints for known providers. Any builtin provider gets the short flow.
-- Providers without a specific hint get a generic one.
local BUILTIN_KEY_HINTS_SPECIFIC = {
  openai     = 'Get your key at  platform.openai.com/api-keys',
  anthropic  = 'Get your key at  console.anthropic.com/settings/keys',
  google     = 'Get your key at  aistudio.google.dev/apikey',
  groq       = 'Get your key at  console.groq.com/keys',
  mistral    = 'Get your key at  console.mistral.ai/api-keys',
  deepseek   = 'Get your key at  platform.deepseek.com/api_keys',
  xai        = 'Get your key at  console.x.ai',
  openrouter = 'Get your key at  openrouter.ai/settings/keys',
  together   = 'Get your key at  api.together.ai/settings/api-keys',
  fireworks  = 'Get your key at  fireworks.ai/account/api-keys',
  perplexity = 'Get your key at  perplexity.ai/settings/api',
  cohere     = 'Get your key at  dashboard.cohere.com/api-keys',
  ollama     = 'No key needed for local Ollama (leave blank or type "ollama")',
  lmstudio   = 'No key needed for local LM Studio (leave blank)',
  huggingface = 'Get your token at  huggingface.co/settings/tokens',
  nvidia     = 'Get your key at  build.nvidia.com',
}

-- All builtin providers get the short API key flow
local function get_key_hint(provider_name)
  if BUILTIN_KEY_HINTS_SPECIFIC[provider_name] then
    return BUILTIN_KEY_HINTS_SPECIFIC[provider_name]
  end
  -- Generic hint using the env var from the provider spec
  local spec = providers_m.get(provider_name)
  if spec and spec.api_key_env then
    return 'Enter your API key (env: ' .. spec.api_key_env .. ')'
  end
  return 'Enter your API key'
end

open_provider_picker = function()
  local all = providers_m.list()

  -- Build items with connection status, sorted by priority
  local popular_items = {}
  local other_items   = {}

  for _, prov in ipairs(all) do
    local key       = config.get_api_key(prov.name)
    local connected = key ~= nil and key ~= ''
    local item = {
      name         = prov.name,
      display_name = prov.display_name or prov.name,
      builtin      = prov.builtin or false,
      connected    = connected,
      priority     = PROVIDER_PRIORITY[prov.name] or 99,
      desc         = PROVIDER_DESC[prov.name],
    }
    if PROVIDER_PRIORITY[prov.name] then
      table.insert(popular_items, item)
    else
      table.insert(other_items, item)
    end
  end

  -- Sort popular by priority, other alphabetically
  table.sort(popular_items, function(a, b) return a.priority < b.priority end)
  table.sort(other_items, function(a, b) return a.display_name < b.display_name end)

  local categories = {}
  if #popular_items > 0 then
    table.insert(categories, { label = 'Popular', items = popular_items })
  end
  if #other_items > 0 then
    table.insert(categories, { label = 'Other', items = other_items })
  end

  -- Add custom provider option at the bottom
  local custom_item = {
    name         = '__add_custom__',
    display_name = '+ Add custom provider',
    builtin      = false,
    connected    = false,
    is_add_custom = true,
    desc         = '(OpenAI-compatible URL)',
  }
  table.insert(categories, { label = 'Custom', items = { custom_item } })

  local cur_provider = config.get_provider()
  open_picker({
    title  = 'Connect a provider',
    categories = categories,
    format = function(item)
      return item.display_name
    end,
    format_gutter = function(item)
      if item.connected then return { text = '✓', hl = 'AiPickerGutter' } end
      return nil
    end,
    current = function(item)
      return item.name == cur_provider
    end,
    format_desc = function(item)
      return item.desc
    end,
    on_confirm = function(item)
      if item.is_add_custom then
        -- Launch the add-custom-provider flow
        vim.schedule(function() prompt_add_custom_provider() end)
      elseif item.connected then
        config.set_provider(item.name)
        local first_model = config.get_models(item.name)[1]
        if first_model then config.set_model(first_model) end
        render_topbar()
        vim.schedule(function() open_model_picker(item.name) end)
      elseif item.builtin then
        vim.schedule(function() prompt_builtin_apikey(item) end)
      else
        vim.schedule(function() prompt_add_provider(item) end)
      end
    end,
  })
end


-- ── prompt_add_custom_provider ─────────────────────────────────────────────────
-- Streamlined flow for adding any OpenAI-compatible provider:
-- Step 1: Enter base URL (e.g. https://api.example.com/v1)
-- Step 2: Enter API key (optional for local providers)
-- Step 3: Auto-test connection by fetching /models
-- Step 4: Let user pick models from the discovered list, or enter manually
-- Step 5: Register the provider and transition to model picker

prompt_add_custom_provider = function()
  -- Step 1: Provider name
  open_prompt({
    title       = 'Add custom provider',
    description = 'Give this provider a name',
    placeholder = 'My Provider',
    on_cancel   = function() end,
    on_confirm  = function(display_name)
      if display_name == '' then toast('Name is required', 'warn'); return end

      -- Derive a clean provider ID from the name
      local provider_id = display_name:lower():gsub('%s+', '-'):gsub('[^%w%-]', '')
      if provider_id == '' then provider_id = 'custom' end
      local base_id = provider_id
      local suffix = 1
      while providers_m.get(provider_id) do
        suffix = suffix + 1
        provider_id = base_id .. '-' .. suffix
      end

      -- Step 2: URL
      vim.schedule(function()
        open_prompt({
          title       = display_name .. ' — Base URL',
          description = 'Enter the OpenAI-compatible base URL',
          placeholder = 'https://api.example.com/v1',
          on_cancel   = function() end,
          on_confirm  = function(url)
            if url == '' then toast('URL is required', 'warn'); return end
            url = url:gsub('/+$', '')

            -- Step 3: API key
            vim.schedule(function()
              open_prompt({
                title       = display_name .. ' — API key',
                description = 'Enter API key (leave blank for local/no-auth)',
                placeholder = 'sk-... or leave blank',
                masked      = true,
                on_cancel   = function() end,
                on_confirm  = function(api_key)

            -- Use a dummy key for no-auth endpoints
            if api_key == '' then api_key = 'none' end

            -- Step 3: Test connection by fetching /models
            toast('Testing connection...', 'info')
            local test_url = url .. '/models'
            local curl_args = {
              'curl', '-s', '-w', '\n%{http_code}',
              '-H', 'Authorization: Bearer ' .. api_key,
              '--connect-timeout', '10',
              test_url,
            }

            vim.fn.jobstart(curl_args, {
              stdout_buffered = true,
              on_stdout = function(_, data)
                vim.schedule(function()
                  local output = table.concat(data or {}, '\n')
                  local status = output:match('(%d%d%d)%s*$')
                  local code = tonumber(status) or 0
                  local body = output:gsub('%d%d%d%s*$', '')

                  if code >= 200 and code < 300 then
                    -- Try to parse models from the response
                    local discovered_models = {}
                    local ok_j, parsed = pcall(vim.json.decode, body)
                    if ok_j and parsed and parsed.data then
                      for _, m in ipairs(parsed.data) do
                        if m.id then
                          table.insert(discovered_models, {
                            id   = m.id,
                            name = m.id,  -- use id as name
                          })
                        end
                      end
                    end

                    if #discovered_models > 0 then
                      -- Step 4: Show discovered models in a picker
                      toast('Found ' .. #discovered_models .. ' models', 'success')
                      vim.schedule(function()
                        local items = {}
                        for _, m in ipairs(discovered_models) do
                          table.insert(items, { id = m.id, name = m.name, selected = false })
                        end
                        -- Let user pick which models to add
                        open_picker({
                          title  = display_name .. ' — Select models',
                          items  = items,
                          format = function(item) return item.name end,
                          format_desc = function() return '(press Enter to add)' end,
                          on_confirm = function(selected_item)
                            -- Register with the selected model + all discovered
                            -- (user picked one to be default, but we add all)
                            local sf = nil
                            if api_key ~= 'none' then
                              sf = providers_m.write_secret(provider_id, api_key)
                            end
                            providers_m.register({
                              name         = provider_id,
                              display_name = display_name,
                              base_url     = url,
                              wire_format  = 'openai',
                              secrets_file = sf,
                              models       = discovered_models,
                            })
                            config.set_provider(provider_id)
                            config.set_model(selected_item.id)
                            toast(display_name .. ' connected with ' .. #discovered_models .. ' models', 'success')
                            render_topbar(); render_input_bar(); render_footer()
                            vim.schedule(function() open_model_picker(provider_id) end)
                          end,
                        })
                      end)
                    else
                      -- No models discovered — ask user to enter model IDs manually
                      toast('Connected but no models listed. Enter model IDs manually.', 'info')
                      vim.schedule(function()
                        open_prompt({
                          title       = display_name .. ' — Model IDs',
                          description = 'Comma-separated model IDs (e.g. gpt-4o, llama3)',
                          placeholder = 'model-id-1, model-id-2',
                          on_cancel   = function() end,
                          on_confirm  = function(raw)
                            local models = {}
                            if raw ~= '' then
                              for _, entry in ipairs(vim.split(raw, ',', { plain = true })) do
                                local e = vim.trim(entry)
                                if e ~= '' then table.insert(models, { id = e, name = e }) end
                              end
                            end
                            if #models == 0 then
                              table.insert(models, { id = 'default', name = 'default' })
                            end
                            local sf = nil
                            if api_key ~= 'none' then
                              sf = providers_m.write_secret(provider_id, api_key)
                            end
                            providers_m.register({
                              name         = provider_id,
                              display_name = display_name,
                              base_url     = url,
                              wire_format  = 'openai',
                              secrets_file = sf,
                              models       = models,
                            })
                            config.set_provider(provider_id)
                            config.set_model(models[1].id)
                            toast(display_name .. ' connected', 'success')
                            render_topbar(); render_input_bar(); render_footer()
                            vim.schedule(function() open_model_picker(provider_id) end)
                          end,
                        })
                      end)
                    end

                  elseif code == 401 or code == 403 then
                    toast('Invalid API key (HTTP ' .. code .. ')', 'error')
                  elseif code >= 400 then
                    -- Still register — the /models endpoint might not exist
                    -- but the chat endpoint could work
                    toast('Models endpoint returned HTTP ' .. code .. '. Registering anyway.', 'warn')
                    vim.schedule(function()
                      open_prompt({
                        title       = display_name .. ' — Model IDs',
                        description = 'Enter model IDs to use with this provider',
                        placeholder = 'model-id-1, model-id-2',
                        on_cancel   = function() end,
                        on_confirm  = function(raw)
                          local models = {}
                          if raw ~= '' then
                            for _, entry in ipairs(vim.split(raw, ',', { plain = true })) do
                              local e = vim.trim(entry)
                              if e ~= '' then table.insert(models, { id = e, name = e }) end
                            end
                          end
                          if #models == 0 then
                            table.insert(models, { id = 'default', name = 'default' })
                          end
                          local sf = nil
                          if api_key ~= 'none' then
                            sf = providers_m.write_secret(provider_id, api_key)
                          end
                          providers_m.register({
                            name         = provider_id,
                            display_name = display_name,
                            base_url     = url,
                            wire_format  = 'openai',
                            secrets_file = sf,
                            models       = models,
                          })
                          config.set_provider(provider_id)
                          config.set_model(models[1].id)
                          toast(display_name .. ' connected', 'success')
                          render_topbar(); render_input_bar(); render_footer()
                          vim.schedule(function() open_model_picker(provider_id) end)
                        end,
                      })
                    end)
                  else
                    toast('Could not reach ' .. url, 'error')
                  end
                end)
              end,
              on_stderr = function() end,
              on_exit = function(_, exit_code)
                if exit_code ~= 0 then
                  vim.schedule(function()
                    toast('Connection failed (curl exit ' .. exit_code .. ')', 'error')
                  end)
                end
              end,
            })
          end,
        })
      end)
    end,
  })
end)
end,
})
end


-- ── prompt_builtin_apikey ──────────────────────────────────────────────────────
-- Test an API key by sending a minimal request to the provider.
-- Calls on_result(ok, message) asynchronously.
local function test_provider_key(provider_name, api_key, on_result)
  local spec = providers_m.get(provider_name)
  if not spec then on_result(false, 'Unknown provider'); return end

  local base_url = spec.base_url or ''
  local wire     = spec.wire_format or 'openai'
  local model    = providers_m.model_ids(spec)[1]
  if not model then on_result(false, 'No models configured'); return end

  local url, headers, body_json
  if wire == 'anthropic' then
    url = base_url .. '/messages'
    headers = {
      'Content-Type: application/json',
      'x-api-key: ' .. api_key,
      'anthropic-version: 2023-06-01',
    }
    body_json = vim.fn.json_encode({
      model      = model,
      max_tokens = 1,
      messages   = { { role = 'user', content = 'hi' } },
    })
  else
    url = base_url .. '/chat/completions'
    headers = {
      'Content-Type: application/json',
      'Authorization: Bearer ' .. api_key,
    }
    body_json = vim.fn.json_encode({
      model      = model,
      max_tokens = 1,
      messages   = { { role = 'user', content = 'hi' } },
    })
  end

  local curl_args = { 'curl', '-s', '-w', '\n%{http_code}', '-X', 'POST', url }
  for _, h in ipairs(headers) do
    table.insert(curl_args, '-H')
    table.insert(curl_args, h)
  end
  table.insert(curl_args, '-d')
  table.insert(curl_args, body_json)
  table.insert(curl_args, '--connect-timeout')
  table.insert(curl_args, '10')

  vim.fn.jobstart(curl_args, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      vim.schedule(function()
        local output = table.concat(data or {}, '\n')
        local status = output:match('(%d%d%d)%s*$')
        local code = tonumber(status) or 0
        if code >= 200 and code < 300 then
          on_result(true, 'Connected successfully')
        elseif code == 401 or code == 403 then
          on_result(false, 'Invalid API key (HTTP ' .. code .. ')')
        elseif code >= 400 then
          on_result(false, 'API error (HTTP ' .. code .. ')')
        else
          on_result(false, 'Could not reach API')
        end
      end)
    end,
    on_stderr = function() end,
    on_exit = function(_, exit_code)
      if exit_code ~= 0 then
        vim.schedule(function()
          on_result(false, 'Connection failed (curl exit ' .. exit_code .. ')')
        end)
      end
    end,
  })
end

-- Short flow for builtin providers: single API key prompt with connection test.
prompt_builtin_apikey = function(item)
  local hint = get_key_hint(item.name)
  local is_local = item.name == 'ollama' or item.name == 'lmstudio'
  open_prompt({
    title       = item.display_name .. ' — API key',
    description = hint,
    placeholder = is_local and 'ollama' or 'sk-...',
    masked      = not is_local,
    on_cancel   = function() end,
    on_confirm  = function(key)
      -- Local providers don't need a key — use a dummy value
      if is_local and key == '' then key = 'ollama' end
      if key == '' then toast('API key required', 'warn'); return end

      local sf, err = providers_m.write_secret(item.name, key)
      if not sf then toast('Could not save key: ' .. (err or '?'), 'error'); return end

      -- Test the connection
      toast('Testing connection...', 'info')
      test_provider_key(item.name, key, function(ok, msg)
        if ok then
          toast(item.display_name .. ' — ' .. msg, 'success')
          config.set_provider(item.name)
          local first_model = config.get_models(item.name)[1]
          if first_model then config.set_model(first_model) end
          render_topbar(); render_input_bar()
          vim.schedule(function() open_model_picker(item.name) end)
        else
          toast(item.display_name .. ' — ' .. msg, 'error')
          -- Don't transition — user can try /connect again
        end
      end)
    end,
  })
end


-- ── prompt_add_provider ────────────────────────────────────────────────────────
-- Streamlined add-provider form (4 steps, down from 6).
-- Modelled closer to OpenCode's approach: minimal steps, sensible defaults.
-- Optional pre_item: a provider item from the provider picker (prefills known fields).
prompt_add_provider = function(pre_item)

  -- Final step: register and transition to model picker
  local function finalize(state)
    local models_list = {}
    if state.models_raw and state.models_raw ~= '' then
      for _, entry in ipairs(vim.split(state.models_raw, ',', { plain = true })) do
        local e = vim.trim(entry)
        if e ~= '' then
          local mid, mname = e:match('^([^:]+):(.+)$')
          if mid then
            table.insert(models_list, { id = vim.trim(mid), name = vim.trim(mname) })
          else
            table.insert(models_list, { id = e, name = e })
          end
        end
      end
    end
    providers_m.register({
      name         = state.id,
      display_name = state.display_name,
      base_url     = state.base_url,
      wire_format  = state.wire_fmt or 'openai',
      api_key_env  = state.api_key_env,
      secrets_file = state.secrets_file,
      models       = models_list,
    })
    config.set_provider(state.id)
    if #models_list > 0 then config.set_model(models_list[1].id) end
    toast('"' .. state.display_name .. '" connected', 'success')
    vim.schedule(function()
      render_topbar(); render_input_bar()
      open_model_picker(state.id)
    end)
  end

  -- Step 4: Models (optional) — then finalize
  local function step_models(state)
    open_prompt({
      title       = state.display_name .. ' — Models',
      description = 'model-id:Name, ...  (leave blank to skip)',
      placeholder = 'llama3:Llama 3, mixtral:Mixtral',
      on_cancel   = function() finalize(state) end,
      on_confirm  = function(raw)
        state.models_raw = raw
        finalize(state)
      end,
    })
  end

  -- Step 3: API key — then wire format picker → models
  local function step_key(state)
    open_prompt({
      title       = state.display_name .. ' — API key',
      description = 'Literal key  or  {env:VAR_NAME}',
      placeholder = 'sk-...',
      masked      = true,
      on_cancel   = function() end,
      on_confirm  = function(raw)
        if raw == '' then toast('API key required', 'warn'); return end
        local env_match = raw:match('^{env:([^}]+)}$')
        if env_match then
          state.api_key_env  = vim.trim(env_match)
          state.secrets_file = nil
        else
          local sf, err = providers_m.write_secret(state.id, raw)
          if not sf then toast('Could not save key: ' .. (err or '?'), 'error'); return end
          state.secrets_file = sf
          state.api_key_env  = nil
        end
        -- Wire format picker
        vim.schedule(function()
          open_picker({
            title  = state.display_name .. ' — API format',
            items  = {
              { id = 'openai',    label = 'OpenAI-compatible (most providers)' },
              { id = 'anthropic', label = 'Anthropic-compatible' },
            },
            format = function(x) return x.label end,
            on_cancel = function()
              state.wire_fmt = 'openai'
              vim.schedule(function() step_models(state) end)
            end,
            on_confirm = function(x)
              state.wire_fmt = x.id
              vim.schedule(function() step_models(state) end)
            end,
          })
        end)
      end,
    })
  end

  -- Step 2: Base URL — then API key
  local function step_url(state)
    open_prompt({
      title       = state.display_name .. ' — Base URL',
      placeholder = 'https://api.example.com/v1',
      on_cancel   = function() end,
      on_confirm  = function(url)
        if url == '' then toast('URL required', 'warn'); return end
        state.base_url = url
        vim.schedule(function() step_key(state) end)
      end,
    })
  end

  -- Step 1: Provider ID — auto-generates display name, then Base URL
  local function step_id()
    open_prompt({
      title       = 'Add custom provider',
      description = 'Enter a unique provider ID (e.g. ollama, my-api)',
      placeholder = 'provider-id',
      initial     = pre_item and pre_item.name or '',
      on_cancel   = function() end,
      on_confirm  = function(id)
        if id == '' then toast('Provider ID required', 'warn'); return end
        local existing = providers_m.get(id)
        if existing and existing.builtin then
          toast('"' .. id .. '" is a builtin provider', 'warn'); return
        end
        local display = id:sub(1,1):upper() .. id:sub(2)
        local state = { id = id, display_name = display }
        vim.schedule(function() step_url(state) end)
      end,
    })
  end

  step_id()
end


-- ── Global command picker (like OpenCode's Ctrl+K / command_list) ────────────
-- Opens all primary commands in open_picker(), grouped into Suggested + Other,
-- each with its description and keybind hint.
local function open_command_picker()
  local entries = cmd_entries()
  local suggested_items = {}
  local other_items     = {}
  for _, e in ipairs(entries) do
    local label = '/' .. e.name
    if e.desc ~= '' then label = label .. '  ' .. e.desc end
    if e.key then label = label .. '  (' .. e.key .. ')' end
    local item = { name = e.name, label = label, desc = e.desc }
    if e.suggested then
      table.insert(suggested_items, item)
    else
      table.insert(other_items, item)
    end
  end
  local categories = {}
  if #suggested_items > 0 then
    table.insert(categories, { label = 'Suggested', items = suggested_items })
  end
  if #other_items > 0 then
    table.insert(categories, { label = 'Commands', items = other_items })
  end
  open_picker({
    title      = 'Commands',
    categories = categories,
    format     = function(item) return item.label end,
    on_confirm = function(item)
      vim.schedule(function()
        local ok, err = pcall(process_slash_command, '/' .. item.name)
        if not ok then
          vim.notify('cmd error: ' .. tostring(err), vim.log.levels.ERROR)
        end
      end)
    end,
  })
end


local function setup_topbar_keymaps()
  local buf  = S.topbar_buf
  local bopt = { buffer = buf, noremap = true, silent = true }
  local e    = function(t) return vim.tbl_extend('force', bopt, t) end
  vim.keymap.set('n', 'm', open_model_picker,    e{ desc = 'AI: model' })
  vim.keymap.set('n', 'p', open_provider_picker, e{ desc = 'AI: provider' })
  vim.keymap.set('n', 'k', open_command_picker,  e{ desc = 'AI: commands' })
  vim.keymap.set('n', 'q', function() M.close() end, e{ desc = 'AI: close' })
  vim.keymap.set('n', '+', function()
    S.messages = {}
    bset(S.chat_buf, 0, -1, {})
    render_welcome()
  end, e{ desc = 'AI: new chat' })
  vim.keymap.set('n', '<Tab>', function()
    if win_ok(S.input_win) then
      vim.api.nvim_set_current_win(S.input_win)
      vim.cmd('startinsert')
    end
  end, e{ desc = 'AI: focus input' })
  vim.keymap.set('n', '<Esc>', function() M.focus_editor() end, e{ desc = 'AI: focus editor' })
end


-- ── Welcome screen ───────────────────────────────────────────────────────
-- Gemini style:
--   ✦  (sparkle, centred)
--   "Hello there"     bold, centred
--   "Where would you like to start?"  muted, centred
--   [blank space]
--   suggestion chips pushed to bottom:
--     [ ✦ Create image ]  [ ◎ Help me learn ]
--     [ ✎ Write anything] [ ⚡ Boost my day  ]

local function render_welcome()
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  S.showing_welcome = true

  local chat_h = 30
  if win_ok(S.chat_win) then
    chat_h = vim.api.nvim_win_get_height(S.chat_win)
  end

  local pad_str = string.rep(' ', P)
  local function cpad(s)
    local dw = vim.fn.strdisplaywidth(s)
    if dw >= CHAT_W then return pad_str .. s end
    local lp = math.floor((CHAT_W - dw) / 2)
    return pad_str .. string.rep(' ', lp) .. s
  end

  -- Centered sparkle + greeting (OpenCode-style: clean, no chips)
  local ctr = {}
  local ctr_hl = {}
  local function cpush(s, h) table.insert(ctr, s); ctr_hl[#ctr] = h end

  cpush(cpad('✦'),                              'AiSparkle')
  cpush('',                                     'AiChatBg')
  cpush(cpad('Hello there'),                    'AiWelcomeHi')
  cpush('',                                     'AiChatBg')
  cpush(cpad('Where would you like to start?'), 'AiWelcomeTitle')

  -- Vertically center the block
  local top_pad = math.max(2, math.floor((chat_h - #ctr) / 2))

  local all_lines, all_hl = {}, {}
  local function push(s, h)
    table.insert(all_lines, s)
    if h then all_hl[#all_lines - 1] = h end
  end

  for _ = 1, top_pad do push('', 'AiChatBg') end
  for i, l in ipairs(ctr) do push(l, ctr_hl[i]) end
  -- Fill remaining space
  local remaining = math.max(0, chat_h - top_pad - #ctr)
  for _ = 1, remaining do push('', 'AiChatBg') end

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(S.chat_buf, 0, -1, false, all_lines)
  if NS_CHAT then
    vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1)
    for row, h in pairs(all_hl) do
      vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, h, row, 0, -1)
    end
  end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
end


-- ── Word-wrap helper ─────────────────────────────────────────────────────
local function wrap_text(text, max_w)
  if max_w <= 0 then return { '' } end
  local lines = {}
  for _, raw in ipairs(vim.split(text, '\n', { plain = true })) do
    if raw == '' then
      table.insert(lines, '')
    else
      local words = vim.split(raw, ' ', { plain = true })
      local cur   = ''
      for _, word in ipairs(words) do
        local cand = cur == '' and word or (cur .. ' ' .. word)
        if vim.fn.strdisplaywidth(cand) <= max_w then
          cur = cand
        else
          if cur ~= '' then table.insert(lines, cur) end
          if vim.fn.strdisplaywidth(word) > max_w then
            local w2 = word
            while vim.fn.strdisplaywidth(w2) > max_w do w2 = w2:sub(1, #w2-1) end
            table.insert(lines, w2); cur = ''
          else
            cur = word
          end
        end
      end
      if cur ~= '' then table.insert(lines, cur) end
    end
  end
  return #lines > 0 and lines or { '' }
end

-- ── Markdown highlight post-render ────────────────────────────────────────
-- Called AFTER assistant text is written to the buffer.
-- buf_start_row: 0-indexed buffer row where the assistant block starts (first text line).
-- raw_text: the full plain text that was written (used to drive the parser).
-- Does NOT rewrite buffer content — only adds extmarks/highlights.
local function render_markdown_highlights(buf_start_row, _raw_text)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  if not NS_CHAT then return end
  if not buf_start_row or buf_start_row < 0 then return end

  -- Read actual buffer lines (these include the ASST prefix)
  local total = vim.api.nvim_buf_line_count(S.chat_buf)
  if buf_start_row >= total then return end
  local ok_lines, buf_lines = pcall(vim.api.nvim_buf_get_lines, S.chat_buf, buf_start_row, total, false)
  if not ok_lines or not buf_lines then return end
  local in_fence = false

  for i, buf_line in ipairs(buf_lines) do
    if not buf_line then break end
    local row = buf_start_row + i - 1

    -- Stop at blank lines or footer lines (end of this assistant message)
    if buf_line == '' then break end
    -- Stop at footer line (▣)
    if buf_line:match('▣') then break end

    -- Strip the new prefix "   │ ✦  " or "   │    " to get actual content.
    -- │ is a 3-byte UTF-8 character; ✦ is 3-byte as well.
    local content = buf_line:gsub('^%s*│%s*✦?%s*', '')
    -- Track where the actual content starts in the buffer line
    local content_start = #buf_line - #content

    -- Fenced code blocks
    local fence_open  = content:match('^```(%S*)')
    local fence_close = content:match('^```%s*$')

    if not in_fence and fence_open and not fence_close then
      in_fence = true
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiCodeLang', row, 0, -1)
    elseif in_fence and fence_close then
      in_fence = false
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiCode', row, 0, -1)
    elseif in_fence then
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiCode', row, 0, -1)
    else
      -- Heading (# ...)
      if content:match('^#+%s') then
        pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiHeading', row, 0, -1)
      end

      -- Bullet / list item (- ... or 1. ...)
      if content:match('^[-*+]%s') or content:match('^%d+%.%s') then
        -- Highlight the bullet character
        local bullet_pos = buf_line:find('[%-*+%d]')
        if bullet_pos then
          pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiBullet', row, bullet_pos - 1, bullet_pos + 1)
        end
      end

      -- Inline backtick `code` spans — search the actual buffer line
      local col = 0
      local s = buf_line
      while true do
        local a, b = s:find('`[^`]+`')
        if not a then break end
        local abs_a = col + a - 1
        local abs_b = col + b
        pcall(vim.api.nvim_buf_set_extmark, S.chat_buf, NS_CHAT, row, abs_a, {
          end_col  = abs_b,
          hl_group = 'AiCodeInline',
        })
        s   = s:sub(b + 1)
        col = col + b
      end

      -- Bold **text** spans — search the actual buffer line
      col = 0
      s = buf_line
      while true do
        local a, b = s:find('%*%*[^%*]+%*%*')
        if not a then break end
        local abs_a = col + a - 1
        local abs_b = col + b
        pcall(vim.api.nvim_buf_set_extmark, S.chat_buf, NS_CHAT, row, abs_a, {
          end_col  = abs_b,
          hl_group = 'AiBold',
        })
        s   = s:sub(b + 1)
        col = col + b
      end
    end
  end
end


--
-- USER  — right-aligned bubble:
--   (blank spacer)
--   ░░░░░░░░░░░░░░░░░░░ text line ░  <- bg_user highlight, right-padded
--   (timestamp right-aligned, muted)
--
-- ASSISTANT — left-aligned, no bubble:
--   ✦  text starts here word-wrapped   <- sparkle on first line only
--      continuation lines indented
--   (timestamp muted)
--
-- The bubble "width" for user = min(text_w + 4, W - 4).
-- Right-aligning: we left-pad with spaces on bg to push bubble right.

-- Padding applied to every content line in the chat buffer.
-- P = left/right margin (2 spaces each side).
-- This simulates CSS padding:2 inside the chat area.
-- The effective text width is W - 2*P.
-- Aliases for streaming code — match the new bar-prefixed layout.
-- ASST_INDENT is used by stream_begin for the initial sparkle line.
-- ASST_CONT is used by stream_end for the timestamp + footer lines (no bar —
-- the footer is visually separated from the response).
local ASST_INDENT  = '   │ ✦  '
local ASST_CONT    = '   │    '

-- Append a user message block (OpenCode-style: left ┃ border, bg #141414, full-width)
local USER_BORDER = '┃'
local USER_PAD_L  = string.rep(' ', P)            -- left margin before border
local USER_PREFIX = USER_PAD_L .. USER_BORDER .. '  '  -- margin + border + inner padding
local USER_META_PFX = USER_PAD_L .. ' ' .. '  '       -- same width, no border char

local function pad_to_width(line)
  -- Pad line to full W so background color fills the entire row
  local dw = vim.fn.strdisplaywidth(line)
  if dw < W then return line .. string.rep(' ', W - dw) end
  return line
end

-- Given a file path, return (badge_text, badge_hl_group) matching the
-- OpenCode-style chip that lives at the top of a user message bubble.
-- Mirrors the logic previously inlined in the 'Attached: ...' system-message
-- branch; extracted so both code paths share one source of truth.
local function chip_badge_for(path)
  local ext = (path:match('%.([^%.]+)$') or ''):lower()
  if ext:match('^png$') or ext:match('^jpe?g$')
     or ext == 'gif' or ext == 'webp' or ext == 'svg' then
    return ' img ', 'AiBadgeImage'
  elseif ext == 'pdf' then
    return ' pdf ', 'AiBadgePdf'
  end
  return ' txt ', 'AiBadgeFile'
end

local function append_user(text, attachments)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end

  if S.showing_welcome then
    S.showing_welcome = false
    bset(S.chat_buf, 0, -1, {})
    if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
  end

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  local base = vim.api.nvim_buf_line_count(S.chat_buf)
  local add  = {}

  -- Blank line before each message (marginTop=1, like OpenCode)
  if base > 0 then table.insert(add, '') end

  -- Top padding inside the block (paddingTop=1 like OpenCode)
  table.insert(add, pad_to_width(USER_PREFIX))

  -- ── Chip rows: one per attachment, rendered INSIDE the bubble at the top.
  -- We pre-render into `chip_rows` and track byte ranges for per-chip
  -- badge highlights later.
  attachments = attachments or {}
  local chip_rows = {}         -- { { line=string, badge_range={s,e}, badge_hl=string, path_start=int } }
  for _, att_path in ipairs(attachments) do
    local badge, badge_hl = chip_badge_for(att_path)
    -- Display the short project-relative path when possible
    local display = vim.fn.fnamemodify(att_path, ':.')
    local body    = badge .. ' ' .. display
    local line    = pad_to_width(USER_PREFIX .. body)
    local prefix_len = #USER_PREFIX  -- byte length of "┃   " prefix
    table.insert(chip_rows, {
      line        = line,
      badge_start = prefix_len,
      badge_end   = prefix_len + #badge,
      badge_hl    = badge_hl,
      path_start  = prefix_len + #badge + 1,   -- +1 for the space
    })
    table.insert(add, line)
  end
  -- Separator blank line between chips and text (only when there ARE chips)
  if #chip_rows > 0 then
    table.insert(add, pad_to_width(USER_PREFIX))
  end

  -- Wrap text to fit inside the border block
  local inner_w = W - vim.fn.strdisplaywidth(USER_PREFIX) - P  -- minus right padding
  local wrapped = wrap_text(text, inner_w)

  for _, l in ipairs(wrapped) do
    table.insert(add, pad_to_width(USER_PREFIX .. l))
  end

  -- Bottom padding inside the block (paddingBottom=1)
  table.insert(add, pad_to_width(USER_PREFIX))

  -- Timestamp below the block with same left margin (togglable)
  local ts_lines = 0
  if S.show_timestamps then
    table.insert(add, USER_META_PFX .. os.date('%H:%M'))
    ts_lines = 1
  end

  vim.api.nvim_buf_set_lines(S.chat_buf, base, base, false, add)
  if NS_CHAT then
    local off = base
    local i   = (base > 0) and 1 or 0
    local border_start = #USER_PAD_L
    local border_end   = border_start + #USER_BORDER

    -- Total block lines = toppad + chip_rows + (separator if chips) + text + bottompad
    local chip_sep_lines = #chip_rows > 0 and 1 or 0
    local block_lines = 1 + #chip_rows + chip_sep_lines + #wrapped + 1
    for j = 0, block_lines - 1 do
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiUserBlock', off + i + j, 0, -1)
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiUserBorder', off + i + j, border_start, border_end)
    end

    -- Per-chip badge + path highlights. Chip rows occupy [off+i+1, off+i+#chips].
    for k, chip in ipairs(chip_rows) do
      local chip_row = off + i + k  -- 0-indexed row: toppad at +0, chip1 at +1, ...
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, chip.badge_hl,
        chip_row, chip.badge_start, chip.badge_end)
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiSysText',
        chip_row, chip.path_start, -1)
    end

    -- Timestamp in muted
    if ts_lines > 0 then
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiUserMeta', off + i + block_lines, 0, -1)
    end
  end

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
  vim.schedule(function() scroll_bottom(S.chat_win, S.chat_buf) end)
end

-- ── Per-message action toolbar (Change A — Cursor-style) ─────────────────
-- Renders a row of icon-only buttons below each assistant message using a
-- virt_lines extmark. Buttons are keyboard-accessible via buffer-local
-- keymaps (y=copy, r=regenerate, u=👍, i=👎, o=open in scratch), scoped to
-- only trigger when the cursor is on the message the toolbar belongs to.
--
-- Storage: S.message_toolbars = { [msg_idx] = { row = extmark_row } }
local MSG_TOOLBAR_NS = 'ai_msg_toolbar'
local msg_toolbar_ns
local function get_msg_toolbar_ns()
  if not msg_toolbar_ns then
    msg_toolbar_ns = vim.api.nvim_create_namespace(MSG_TOOLBAR_NS)
  end
  return msg_toolbar_ns
end

-- Render a toolbar below buffer row `row` (0-indexed). Sets an extmark that
-- shows the toolbar as a virt_line.
-- `msg_idx` is the 1-indexed position in S.messages (for keybind dispatch).
local function render_message_toolbar(row, msg_idx)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  local line_count = vim.api.nvim_buf_line_count(S.chat_buf)
  if row < 0 or row >= line_count then return end

  -- Minimal shortcut-hint row (no emoji icons — users found them noisy).
  -- Single muted-gray line with key letters called out in accent color.
  local virt_line = {
    { '     ' },  -- left pad (matches assistant text indent)
    { 'y', 'AiMsgToolbarKey' }, { '=copy  ', 'AiMsgToolbar' },
    { 'r', 'AiMsgToolbarKey' }, { '=regen  ', 'AiMsgToolbar' },
    { 'u', 'AiMsgToolbarKey' }, { '/', 'AiMsgToolbar' },
    { 'i', 'AiMsgToolbarKey' }, { '=rate  ', 'AiMsgToolbar' },
    { 'o', 'AiMsgToolbarKey' }, { '=open', 'AiMsgToolbar' },
  }

  pcall(vim.api.nvim_buf_set_extmark, S.chat_buf, get_msg_toolbar_ns(), row, 0, {
    virt_lines       = { virt_line },
    virt_lines_above = false,
  })

  -- Record for dispatch. msg_idx is the 1-indexed S.messages entry.
  S.message_toolbars = S.message_toolbars or {}
  S.message_toolbars[msg_idx] = { row = row }
end

-- Find the message index whose toolbar row is closest-above the given cursor
-- row. Used by toolbar keymaps to know "which message did the user interact
-- with?".
local function find_msg_at(cursor_row)
  if not S.message_toolbars then return nil end
  local best_idx, best_row = nil, -1
  for idx, info in pairs(S.message_toolbars) do
    if info.row <= cursor_row and info.row > best_row then
      best_row = info.row
      best_idx = idx
    end
  end
  return best_idx
end

-- Clear all message toolbars (called on /new).
local function clear_message_toolbars()
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  pcall(vim.api.nvim_buf_clear_namespace, S.chat_buf, get_msg_toolbar_ns(), 0, -1)
  S.message_toolbars = {}
end

-- ── Per-message toolbar action handlers ──────────────────────────────────

-- Store feedback per (session, msg_idx) in ~/.local/state/pandavim/feedback.json
local FEEDBACK_PATH = vim.fn.stdpath('state') .. '/pandavim/feedback.json'
local function record_feedback(msg_idx, rating)
  vim.fn.mkdir(vim.fn.fnamemodify(FEEDBACK_PATH, ':h'), 'p')
  local data = {}
  local f = io.open(FEEDBACK_PATH, 'r')
  if f then
    local txt = f:read('*a'); f:close()
    local ok, t = pcall(vim.json.decode, txt)
    if ok and type(t) == 'table' then data = t end
  end
  local entry = {
    ts        = os.date('%Y-%m-%d %H:%M:%S'),
    session   = S.session_id or 'unknown',
    msg_idx   = msg_idx,
    rating    = rating,   -- 'up' or 'down'
    model     = config.get_model(),
    provider  = config.get_provider(),
    content_preview = (S.messages[msg_idx] and S.messages[msg_idx].content or ''):sub(1, 200),
  }
  table.insert(data, entry)
  local fw = io.open(FEEDBACK_PATH, 'w')
  if fw then fw:write(vim.json.encode(data)); fw:close() end
end

-- Exposed action handlers (called by the buffer-local keymaps below)
function M._msg_copy(msg_idx)
  local msg = S.messages[msg_idx]
  if not msg then toast('No message at this position', 'warn'); return end
  vim.fn.setreg('+', msg.content or '')
  toast('Copied message to clipboard', 'success')
end

function M._msg_regenerate(msg_idx)
  if not S.messages[msg_idx] then toast('No message', 'warn'); return end
  -- Find the most recent user message at or before this assistant message
  local user_msg
  for i = msg_idx, 1, -1 do
    if S.messages[i].role == 'user' then user_msg = S.messages[i]; break end
  end
  if not user_msg then toast('No user message to regenerate from', 'warn'); return end
  -- Truncate history to BEFORE this user message (we'll re-submit it)
  local truncate_before
  for i = msg_idx, 1, -1 do
    if S.messages[i].role == 'user' then truncate_before = i; break end
  end
  if truncate_before then
    while #S.messages >= truncate_before do table.remove(S.messages) end
  end
  toast('Regenerating…', 'info')
  -- Rebuild the UI to reflect the truncated history
  if redraw_all then redraw_all() end
  -- Inject the prompt into the input pane and fire submit
  if S.input_buf and vim.api.nvim_buf_is_valid(S.input_buf) then
    pcall(vim.api.nvim_buf_set_option, S.input_buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(S.input_buf, 0, -1, false,
      vim.split(user_msg.content or '', '\n', { plain = true }))
    pcall(vim.api.nvim_buf_set_option, S.input_buf, 'modifiable', false)
    -- Focus input then trigger submit
    if win_ok(S.input_win) then
      vim.api.nvim_set_current_win(S.input_win)
      vim.schedule(function()
        if submit then submit() end
      end)
    end
  end
end

function M._msg_feedback(msg_idx, rating)
  record_feedback(msg_idx, rating)
  toast('Feedback recorded: ' .. rating, 'info')
end

function M._msg_open_scratch(msg_idx)
  local msg = S.messages[msg_idx]
  if not msg then toast('No message', 'warn'); return end
  -- Create a scratch buffer in a horizontal split
  vim.cmd('botright split')
  local bufnr = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, bufnr)
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].buftype   = 'nofile'
  vim.bo[bufnr].filetype  = 'markdown'
  local lines = vim.split(msg.content or '', '\n', { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
  vim.api.nvim_buf_set_name(bufnr, 'AI Response #' .. msg_idx)
end

-- Append an assistant message.
-- Visual style: thin │ bar in agent color at column P, then indented text.
-- Matches avante's subtle left-border pattern while staying non-modal.
-- Layout:  "   │ ✦  text"   (first line)
--          "   │    text"   (continuation)
-- The bar is highlighted with AiAsstBorder (agent color); the text with AiAsstText.
-- F3: normalize assistant text whitespace before render.
-- - Strip trailing blank lines (models often emit \n\n at end of turn)
-- - Collapse 3+ consecutive newlines to 2 (visual stripe → single blank)
local function normalize_assistant_text(s)
  if type(s) ~= 'string' or s == '' then return s end
  -- Strip trailing whitespace including newlines
  s = (s:gsub('%s+$', ''))
  -- Collapse runs of blank lines (3+ newlines → 2)
  s = s:gsub('\n%s*\n%s*\n+', '\n\n')
  return s
end

-- Test export (stable underscore-prefixed surface; matches M._render_inline_summary etc.)
M._normalize_assistant_text = normalize_assistant_text

local ASST_BAR     = '│'
local ASST_PAD_L   = string.rep(' ', P)                -- 3 leading spaces
local ASST_AVATAR  = ASST_PAD_L .. ASST_BAR .. ' ✦  ' -- pad + bar + space + sparkle + 2 spaces
local ASST_TEXT_PFX = ASST_PAD_L .. ASST_BAR .. '    ' -- pad + bar + 4 spaces (same width as AVATAR)
-- Byte range of the bar character for highlighting: after the leading pad
local ASST_BAR_START = #ASST_PAD_L
local ASST_BAR_END   = ASST_BAR_START + #ASST_BAR

local function append_assistant(text)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end

  if S.showing_welcome then
    S.showing_welcome = false
    bset(S.chat_buf, 0, -1, {})
    if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
  end

  -- F3: trim trailing blanks + collapse blank-line runs
  text = normalize_assistant_text(text)

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  local base    = vim.api.nvim_buf_line_count(S.chat_buf)
  local inner_w = W - vim.fn.strdisplaywidth(ASST_AVATAR) - P  -- minus right padding
  local wrapped = wrap_text(text, inner_w)
  local add     = {}

  -- marginTop=1 (blank line before)
  if base > 0 then table.insert(add, '') end

  -- Text lines: sparkle on first line, continuation prefix on rest.
  -- F5: blank-content lines get a no-bar prefix (just spaces) so we don't
  -- paint a visible │ stripe on padding/whitespace lines.
  local blank_rows = {}  -- 1-indexed rows in `wrapped` that are blank
  local NO_BAR_PFX = string.rep(' ', vim.fn.strdisplaywidth(ASST_TEXT_PFX))
  for j, l in ipairs(wrapped) do
    local is_blank = vim.trim(l) == ''
    local prefix
    if is_blank then
      prefix = NO_BAR_PFX
      blank_rows[j] = true
    else
      prefix = j == 1 and ASST_AVATAR or ASST_TEXT_PFX
    end
    table.insert(add, prefix .. l)
  end

  -- Footer: ▣ AgentName · model · duration · timestamp
  local icon = '▣'
  local agent_name = (agents.active_name and agents.active_name()) or 'Code'
  if not agent_name or agent_name == '' then agent_name = 'Code' end
  local model_name = config.get_model():match('([^/]+)$') or config.get_model()
  local fparts = { icon .. ' ' .. agent_name, model_name }
  if S.turn_start_time then
    local dur = os.time() - S.turn_start_time
    if dur >= 60 then
      table.insert(fparts, string.format('%dm%ds', math.floor(dur/60), dur%60))
    else
      table.insert(fparts, dur .. 's')
    end
  end
  if S.show_timestamps then
    table.insert(fparts, os.date('%H:%M'))
  end
  -- Blank line before footer for breathing room
  table.insert(add, '')
  local footer_line = ASST_TEXT_PFX .. table.concat(fparts, ' · ')
  table.insert(add, footer_line)

  vim.api.nvim_buf_set_lines(S.chat_buf, base, base, false, add)

  if NS_CHAT then
    local off = base
    local i   = (base > 0) and 1 or 0
    -- Text lines: AiAsstText on full row, then bar overlay (skipped on blanks), then sparkle on first
    for j = 0, #wrapped - 1 do
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiAsstText', off + i + j, 0, -1)
      -- F5: skip bar overlay on blank-content lines (the prefix is already
      -- substituted with spaces in the buffer above, so there's no │ glyph).
      if not blank_rows[j + 1] then
        pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiAsstBorder',
          off + i + j, ASST_BAR_START, ASST_BAR_END)
      end
    end
    -- Sparkle avatar color on first line (the ✦ character starts after bar+space)
    local sparkle_start = ASST_BAR_END + 1  -- +1 for the space after the bar
    pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiAsstAvatar',
      off + i, sparkle_start, sparkle_start + #'✦')
    -- Footer line (after blank line): icon in agent color, rest muted
    local footer_row = off + i + #wrapped + 1  -- +1 for the blank line
    pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiAsstFooter', footer_row, 0, -1)
    local icon_start = #ASST_TEXT_PFX
    local icon_end   = icon_start + #icon
    pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiAsstFooterIcon', footer_row, icon_start, icon_end)
  end

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)

  -- Post-render markdown highlights
  local first_text_row = base + ((base > 0) and 1 or 0)
  render_markdown_highlights(first_text_row, text)

  -- Change A: per-message action toolbar below the footer row
  local footer_row = first_text_row + #wrapped + 1
  -- S.messages has just had the assistant response appended by submit/stream
  local msg_idx = #S.messages
  vim.schedule(function()
    render_message_toolbar(footer_row, msg_idx)
    scroll_bottom(S.chat_win, S.chat_buf)
  end)
end

-- Generic dispatch used by submit/stream paths.
-- The 3rd param is role-specific: for 'user' it's the list of attachment paths
-- that render as chips inside the bubble; for other roles it's ignored.
append_message = function(role, text, extra)
  if role == 'user' then
    append_user(text, extra)
  elseif role == 'assistant' then
    append_assistant(text)
  elseif role == 'system' then
    if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end

    if S.showing_welcome then
      S.showing_welcome = false
      bset(S.chat_buf, 0, -1, {})
      if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
    end

    pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
    local base = vim.api.nvim_buf_line_count(S.chat_buf)
    local sys  = {}
    if base > 0 then table.insert(sys, '') end

    -- Detect file attachment lines and render as badges (OpenCode-style)
    local attached_file = text:match('^Attached: (.+)$')
    if attached_file then
      local ext = attached_file:match('%.([^%.]+)$') or ''
      local badge, badge_hl
      if ext:match('^png$') or ext:match('^jpe?g$') or ext:match('^gif$') or ext:match('^webp$') or ext:match('^svg$') then
        badge, badge_hl = ' img ', 'AiBadgeImage'
      elseif ext == 'pdf' then
        badge, badge_hl = ' pdf ', 'AiBadgePdf'
      else
        badge, badge_hl = ' txt ', 'AiBadgeFile'
      end
      local line = '  ' .. badge .. ' ' .. attached_file
      table.insert(sys, line)

      vim.api.nvim_buf_set_lines(S.chat_buf, base, base, false, sys)
      if NS_CHAT then
        local row = base + (base > 0 and 1 or 0)
        -- Badge highlight
        pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, badge_hl, row, 2, 2 + #badge)
        -- Filename in muted
        pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiSysText', row, 2 + #badge, -1)
      end
    else
      for _, l in ipairs(vim.split(text, '\n', { plain = true })) do
        table.insert(sys, '  ' .. l)
      end
      vim.api.nvim_buf_set_lines(S.chat_buf, base, base, false, sys)
      if NS_CHAT then
        local off = base
        for j = (base > 0 and 1 or 0), #sys - 1 do
          vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, 'AiSysText', off + j, 0, -1)
        end
      end
    end

    pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
    vim.schedule(function() scroll_bottom(S.chat_win, S.chat_buf) end)
  end
end

function M.append_system(text)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  append_message('system', text)
end

-- ── Inline-apply turn summary (Feature 5) ────────────────────────────────
-- Renders a single coordinator card at the bottom of the chat showing all
-- currently-pending inline-apply sessions across files, with Accept-all /
-- Reject-all buttons. Re-renders in place every time the summary changes.
local SUMMARY_CARD_ID = 'inline_summary'

--- Record a finalized inline session into the per-turn stats so the summary
-- card persists for the rest of the turn.
-- @param path string  absolute path
-- @param accepted_count int
-- @param rejected_count int
-- @param adds int    lines added across the file
-- @param dels int    lines removed across the file
function M._record_inline_result(path, accepted_count, rejected_count, adds, dels)
  S.turn_stats = S.turn_stats or { files = {}, total_files = 0 }
  if not S.turn_stats.files[path] then
    S.turn_stats.total_files = S.turn_stats.total_files + 1
    S.turn_stats.files[path] = { adds = 0, dels = 0, accepted = 0, rejected = 0 }
  end
  local f = S.turn_stats.files[path]
  f.accepted = f.accepted + (accepted_count or 0)
  f.rejected = f.rejected + (rejected_count or 0)
  f.adds     = f.adds + (adds or 0)
  f.dels     = f.dels + (dels or 0)
end

function M._reset_turn_stats()
  S.turn_stats = { files = {}, total_files = 0 }
  ToolCard.remove(SUMMARY_CARD_ID)
end

function M._render_inline_summary()
  -- Active (still-pending) sessions
  local active_summary = InlineApply.summary()
  local total_pending, total_active_files = 0, 0
  for _, info in pairs(active_summary) do
    total_active_files = total_active_files + 1
    total_pending = total_pending + info.pending
  end

  -- Resolved sessions accumulated this turn (Change 3)
  local resolved_files = 0
  local total_adds, total_dels = 0, 0
  if S.turn_stats and S.turn_stats.files then
    for _, f in pairs(S.turn_stats.files) do
      resolved_files = resolved_files + 1
      total_adds = total_adds + (f.adds or 0)
      total_dels = total_dels + (f.dels or 0)
    end
  end

  -- Show summary if there's been ANY file activity this turn (Change 3:
  -- always-visible, Cursor parity).
  if total_active_files == 0 and resolved_files == 0 then
    ToolCard.remove(SUMMARY_CARD_ID)
    return
  end

  -- Build body lines: one per file (active first, then resolved-only)
  local body_lines = {}
  for _, info in pairs(active_summary) do
    table.insert(body_lines, string.format('%s — %d/%d hunks pending',
      vim.fn.fnamemodify(info.path, ':.'), info.pending, info.total))
  end
  if S.turn_stats and S.turn_stats.files then
    for path, f in pairs(S.turn_stats.files) do
      if not active_summary[path] then  -- skip if still active (already shown above)
        local detail = string.format('%s — +%d -%d (%d accepted, %d rejected)',
          vim.fn.fnamemodify(path, ':.'), f.adds, f.dels, f.accepted, f.rejected)
        table.insert(body_lines, detail)
      end
    end
  end

  local total_files = total_active_files + resolved_files
  local title = string.format('%d file%s changed  +%d -%d',
    total_files, total_files == 1 and '' or 's', total_adds, total_dels)

  -- R3+R4: passive, button-less summary. Accept/reject lives in the editor;
  -- the chat just shows a status line. Pending state hints at "see editors";
  -- resolved state shows final stats.
  local title_with_status
  if total_pending > 0 then
    title_with_status = string.format('%s  · %d pending — see editor%s',
      title, total_pending, total_active_files > 1 and 's' or '')
  else
    title_with_status = title  -- e.g. "1 file changed  +1 -1"
  end

  local spec = {
    tool_name  = title_with_status,
    args       = {},
    body_lines = body_lines,
    body_hl    = 'AiToolBody',
    summary    = true,  -- forces ToolCard.build_inline (single-line bar)
    state      = total_pending > 0 and 'proposing' or 'succeeded',
    footer     = '',
    -- NO permission, NO buttons — accept/reject is editor-only now.
  }

  -- F4a: clear any leftover button-row extmarks before re-rendering the
  -- summary card. The previous incarnation may have rendered an
  -- [Accept all] / [Reject all] row which lives in a different namespace
  -- than ToolCard, so ToolCard.render() alone won't wipe it.
  ButtonRow.hide()

  ToolCard.render(SUMMARY_CARD_ID, spec)
end

-- Append an error message with red left-border (OpenCode-style inline error)
function M.append_error(text)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then
    -- Fallback: if no chat buffer, just use append_system
    M.append_system('Error: ' .. (text or ''))
    return
  end

  if S.showing_welcome then
    S.showing_welcome = false
    bset(S.chat_buf, 0, -1, {})
    if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
  end

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  local base = vim.api.nvim_buf_line_count(S.chat_buf)
  local lines = {}
  if base > 0 then table.insert(lines, '') end
  for _, l in ipairs(vim.split(tostring(text), '\n', { plain = true })) do
    table.insert(lines, '  │ ' .. l)
  end
  vim.api.nvim_buf_set_lines(S.chat_buf, base, base, false, lines)
  if NS_CHAT then
    local off = base
    for j = (base > 0 and 1 or 0), #lines - 1 do
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiErrorBorder', off + j, 0, #'  │')
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiErrorText', off + j, #'  │ ', -1)
    end
  end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
  vim.schedule(function() scroll_bottom(S.chat_win, S.chat_buf) end)
end


-- ── Streaming (Gemini style) ──────────────────────────────────────────────
-- stream_begin: write the sparkle prefix line, record where text starts
-- stream_chunk: replace text lines in-place as chunks arrive
-- stream_end:   append timestamp, finalise

local function stream_begin()
  if not S.chat_buf then return nil end

  if S.showing_welcome then
    S.showing_welcome = false
    bset(S.chat_buf, 0, -1, {})
    if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
  end

  -- Begin showing the bottom state spinner (violet generating badge).
  state_set('generating')

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  local lc  = vim.api.nvim_buf_line_count(S.chat_buf)
  local add = {}
  if lc > 0 then table.insert(add, '') end
  -- first text line (empty placeholder with sparkle)
  table.insert(add, ASST_INDENT)

  vim.api.nvim_buf_set_lines(S.chat_buf, lc, lc, false, add)
  if NS_CHAT then
    local row = lc + (lc > 0 and 1 or 0)
    vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, 'AiAsstText', row, 0, -1)
    -- Bar in agent color
    pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiAsstBorder',
      row, ASST_BAR_START, ASST_BAR_END)
    -- Sparkle in agent color (starts after "│ ")
    local sparkle_start = ASST_BAR_END + 1
    vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, 'AiAsstAvatar',
      row, sparkle_start, sparkle_start + #'✦')
  end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
  render_topbar()
  render_input_bar()

  -- return 0-indexed row of first text line
  return lc + (lc > 0 and 1 or 0)
end

-- Throttled markdown refresh during streaming (60ms). Re-renders markdown
-- highlights (code fences, bullets, bold, inline code) on the in-progress
-- response so the user sees formatted output as it arrives, not plain text.
local md_throttle_pending = false
local function schedule_markdown_refresh()
  if md_throttle_pending then return end
  md_throttle_pending = true
  vim.defer_fn(function()
    md_throttle_pending = false
    if S.stream_line and S.stream_text and S.stream_text ~= '' then
      render_markdown_highlights(S.stream_line, S.stream_text)
    end
  end, 60)
end

local function stream_chunk(chunk)
  if not S.stream_line or not S.chat_buf then return end
  S.stream_text = S.stream_text .. chunk

  -- F3: normalize text for display (collapse runs, strip trailing).
  -- Don't mutate S.stream_text itself — the raw stream is still useful for
  -- tool detection. Only apply normalization to the WRAPPED render path.
  local display_text = normalize_assistant_text(S.stream_text)
  local text_w    = W - vim.fn.strdisplaywidth(ASST_AVATAR) - P  -- account for right padding
  local wrapped   = wrap_text(display_text, text_w)
  -- F5: track which lines are blank so we can skip the bar prefix + highlight.
  local NO_BAR_PFX = string.rep(' ', vim.fn.strdisplaywidth(ASST_TEXT_PFX))
  local blank_rows = {}
  local new_lines = {}
  for j, l in ipairs(wrapped) do
    local is_blank = vim.trim(l) == ''
    if is_blank then
      new_lines[j] = NO_BAR_PFX .. l
      blank_rows[j] = true
    else
      new_lines[j] = (j == 1 and ASST_AVATAR or ASST_TEXT_PFX) .. l
    end
  end

  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  local cur_end = vim.api.nvim_buf_line_count(S.chat_buf)
  vim.api.nvim_buf_set_lines(S.chat_buf, S.stream_line, cur_end, false, new_lines)
  if NS_CHAT then
    for j = 0, #new_lines - 1 do
      local row = S.stream_line + j
      vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, 'AiAsstText', row, 0, -1)
      -- F5: skip bar on blank rows
      if not blank_rows[j + 1] then
        pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiAsstBorder',
          row, ASST_BAR_START, ASST_BAR_END)
        if j == 0 then
          local sparkle_start = ASST_BAR_END + 1
          vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, 'AiAsstAvatar',
            row, sparkle_start, sparkle_start + #'✦')
        end
      end
    end
  end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
  schedule_markdown_refresh()  -- Step 3: throttled live markdown render
  scroll_bottom(S.chat_win, S.chat_buf)
end

local function stream_end()
  S.is_streaming = false
  S.stream_job   = nil
  stop_spinner()
  -- Brief success flash before clearing the state spinner
  state_set('succeeded')
  if S.chat_buf and vim.api.nvim_buf_is_valid(S.chat_buf) then
    pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)

    -- Strip any trailing blank lines first (ensure_bottom_margin adds
    -- padding during streaming; we want the timestamp / footer to sit
    -- directly underneath the last content line, not after the padding).
    local lc = vim.api.nvim_buf_line_count(S.chat_buf)
    while lc > 0 do
      local line = vim.api.nvim_buf_get_lines(S.chat_buf, lc - 1, lc, false)[1] or ''
      if vim.trim(line) == '' then
        pcall(vim.api.nvim_buf_set_lines, S.chat_buf, lc - 1, lc, false, {})
        lc = lc - 1
      else
        break
      end
    end

    -- Timestamp line
    local ts = ASST_CONT .. os.date('%H:%M')
    vim.api.nvim_buf_set_lines(S.chat_buf, lc, lc, false, { ts })
    if NS_CHAT then
      vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, 'AiAsstMeta', lc, 0, -1)
    end

    -- Response footer: ▣  agent · model · Ns  (matches OpenCode's text-part-meta)
    local elapsed = os.time() - (S.turn_start_time or os.time())
    local dur_str
    if elapsed < 60 then
      dur_str = elapsed .. 's'
    else
      dur_str = math.floor(elapsed / 60) .. 'm ' .. (elapsed % 60) .. 's'
    end
    local footer_parts = {}
    local ta = S.turn_agent
    if ta and ta ~= '' then table.insert(footer_parts, ta) end
    table.insert(footer_parts, S.turn_model or config.get_model())
    table.insert(footer_parts, dur_str)
    local footer = ASST_CONT .. '▣  ' .. table.concat(footer_parts, ' · ')
    local footer_row = lc + 1
    vim.api.nvim_buf_set_lines(S.chat_buf, footer_row, footer_row, false, { footer })
    if NS_CHAT then
      vim.api.nvim_buf_add_highlight(S.chat_buf, NS_CHAT, 'AiAsstMeta', footer_row, 0, -1)
    end

    pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
  end
  -- F3: normalize the final stored content (so future redraws via append_assistant
  -- and any /copy / message-toolbar operations see the cleaned-up version).
  local final_text = normalize_assistant_text(S.stream_text)
  table.insert(S.messages, { role = 'assistant', content = final_text })
  -- Capture stream_line before clearing — needed for markdown post-render
  local md_start = S.stream_line
  S.stream_line = nil
  -- Apply markdown highlights to the streamed block before clearing stream_text
  render_markdown_highlights(md_start, final_text)
  S.stream_text = ''
  -- Change A: per-message toolbar below the footer line
  local toolbar_row = vim.api.nvim_buf_line_count(S.chat_buf) - 1
  render_message_toolbar(toolbar_row, #S.messages)
  -- Heuristic tool-support detection: if the model responded with text that
  -- looks like "here's how to do it" but didn't call any tools, mark the
  -- provider as needing ReAct fallback for future requests.
  tool_support.detect_from_response(config.get_provider(), final_text, false)
  session_save()
  render_topbar()
  render_input_bar()
  pcall(render_footer)
  scroll_bottom(S.chat_win, S.chat_buf)
end


-- ── Tool call display in chat ─────────────────────────────────────────────
-- Show a tool call block: header (tool name + args summary) + output
local TOOL_PREFIX = string.rep(' ', P + 1) .. '│ '
local TOOL_HEADER_PFX = string.rep(' ', P + 1)

local function append_tool_call(tool_name, args, status)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  local base = vim.api.nvim_buf_line_count(S.chat_buf)
  local add = {}
  local summary = tools_m.format_tool_call(tool_name, args)
  local icon = status == 'running' and '⟳' or status == 'done' and '✓' or status == 'error' and '✗' or '▶'
  table.insert(add, TOOL_HEADER_PFX .. icon .. ' ' .. summary)
  vim.api.nvim_buf_set_lines(S.chat_buf, base, base, false, add)
  if NS_CHAT then
    local hl = status == 'error' and 'AiToolError' or 'AiToolHeader'
    pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, hl, base, 0, -1)
  end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
  scroll_bottom(S.chat_win, S.chat_buf)
  return base  -- row of the header (for updating later)
end

local function append_tool_output(output, is_error)
  if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
  local base = vim.api.nvim_buf_line_count(S.chat_buf)
  local add = {}
  -- Truncate long output for display (keep first 20 lines)
  local lines = vim.split(output or '', '\n', { plain = true })
  local max_display = 20
  for i, l in ipairs(lines) do
    if i > max_display then
      table.insert(add, TOOL_PREFIX .. '... (' .. (#lines - max_display) .. ' more lines)')
      break
    end
    table.insert(add, TOOL_PREFIX .. l)
  end
  vim.api.nvim_buf_set_lines(S.chat_buf, base, base, false, add)
  if NS_CHAT then
    local hl = is_error and 'AiToolError' or 'AiToolBody'
    for j = 0, #add - 1 do
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, hl, base + j, 0, -1)
      -- Border highlight
      pcall(vim.api.nvim_buf_add_highlight, S.chat_buf, NS_CHAT, 'AiToolBorder', base + j,
        #string.rep(' ', P + 1), #string.rep(' ', P + 1) + #'│')
    end
  end
  pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
  scroll_bottom(S.chat_win, S.chat_buf)
end

-- ── Tool execution loop (agentic loop) ───────────────────────────────────
-- Called when the model responds with tool_calls.
-- Executes each tool, shows output in chat, pushes results as messages,
-- then re-calls the API. Loops until the model responds with text only.

-- Maximum number of recursive agentic tool-call iterations per user turn.
-- Each iteration = model emits tool calls → we execute → we re-call the API.
-- A healthy "read, edit, verify" flow is usually 2-4 iterations; 10 is a
-- generous upper bound that still catches runaway retry loops (e.g. the
-- "rejected edit → retry → rejected again → …" pattern that can happen
-- when the inline-apply reject key is hit repeatedly).
local MAX_TOOL_DEPTH = 10

-- ── Diff-mode toast (editor side) ─────────────────────────────────────
-- A 1-second floating overlay shown in the editor window when inline-apply
-- activates, telling the user which keys are live. Mitigates the "focus
-- got stolen and now random keys reject my changes" surprise.
local function show_diff_mode_toast(winid)
  if not winid or not vim.api.nvim_win_is_valid(winid) then return end
  local line = ' Diff mode  ·  y accept  ·  d reject  ·  <Tab> next  ·  <Esc> cancel '
  local width = vim.fn.strdisplaywidth(line)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
  pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', false)
  pcall(vim.api.nvim_buf_set_option, buf, 'bufhidden',  'wipe')
  local win_w = vim.api.nvim_win_get_width(winid)
  local col   = math.max(0, math.floor((win_w - width) / 2))
  local fwin = vim.api.nvim_open_win(buf, false, {
    relative  = 'win',
    win       = winid,
    anchor    = 'NW',
    row       = 0,
    col       = col,
    width     = width,
    height    = 1,
    style     = 'minimal',
    border    = 'rounded',
    focusable = false,
    noautocmd = true,
    zindex    = 100,
  })
  pcall(vim.api.nvim_win_set_option, fwin, 'winhighlight',
    'Normal:AiHunkFloatBg,FloatBorder:AiHunkFloatBorder')
  -- Auto-close after a short delay so it doesn't obscure the diff content.
  vim.defer_fn(function()
    if vim.api.nvim_win_is_valid(fwin) then
      pcall(vim.api.nvim_win_close, fwin, true)
    end
  end, 1500)
end

-- ── Decision-pending banner (chat side) ──────────────────────────────
-- When an inline-apply session is live, display a persistent virt_lines
-- extmark above the input buffer with the key hints. Clears when all
-- active sessions finalize. Rendered unconditionally; a no-op if no
-- active sessions. Called from:
--   1. try_inline_apply() right after InlineApply.show starts
--   2. The InlineApply on_done callback (to clear on resolve)
local DECISION_BANNER_NS
local function get_decision_banner_ns()
  if not DECISION_BANNER_NS then
    DECISION_BANNER_NS = vim.api.nvim_create_namespace('ai_decision_banner')
  end
  return DECISION_BANNER_NS
end

function M._render_decision_banner()
  if not S.input_buf or not vim.api.nvim_buf_is_valid(S.input_buf) then return end
  local ns = get_decision_banner_ns()
  vim.api.nvim_buf_clear_namespace(S.input_buf, ns, 0, -1)
  local ok_ia, IA = pcall(require, 'ai.inline_apply')
  if not ok_ia then return end
  local active = IA.list_active_buffers and IA.list_active_buffers() or {}
  if #active == 0 then return end
  -- Anchor above line 1 of the input buffer
  pcall(vim.api.nvim_buf_set_extmark, S.input_buf, ns, 0, 0, {
    virt_lines_above = true,
    virt_lines = { {
      { ' ⚠ Diff review in editor  ·  ', 'AiSysText' },
      { 'y', 'AiMsgToolbarKey' }, { ' accept  ·  ', 'AiSysText' },
      { 'd', 'AiMsgToolbarKey' }, { ' reject  ·  ', 'AiSysText' },
      { '<Tab>', 'AiMsgToolbarKey' }, { ' next  ·  ', 'AiSysText' },
      { '<Esc>', 'AiMsgToolbarKey' }, { ' cancel ', 'AiSysText' },
    } },
  })
end

local function run_tool_loop(tool_calls, all_messages, on_done, on_error_cb, depth)
  depth = depth or 0
  if depth >= MAX_TOOL_DEPTH then
    M.append_system('⚠ Stopped after ' .. MAX_TOOL_DEPTH ..
      ' tool iterations this turn. Send a new message with clearer instructions.')
    if on_done then on_done() end
    return
  end
  if not tool_calls or #tool_calls == 0 then
    if on_done then on_done() end
    return
  end

  local wire_format = config.get_wire_format()

  -- Build the assistant message with tool_calls (needed for the API conversation history)
  if wire_format == 'anthropic' then
    -- Anthropic: assistant message content = [{type:"tool_use", id, name, input}]
    local content_blocks = {}
    for _, tc in ipairs(tool_calls) do
      table.insert(content_blocks, {
        type  = 'tool_use',
        id    = tc.id,
        name  = tc.name,
        input = tc.arguments,
      })
    end
    table.insert(all_messages, { role = 'assistant', content = content_blocks })
  else
    -- OpenAI: assistant message with tool_calls array
    local oai_tool_calls = {}
    for _, tc in ipairs(tool_calls) do
      table.insert(oai_tool_calls, {
        id   = tc.id,
        type = 'function',
        ['function'] = {
          name      = tc.name,
          arguments = tc.arguments_raw or vim.json.encode(tc.arguments),
        },
      })
    end
    table.insert(all_messages, { role = 'assistant', tool_calls = oai_tool_calls, content = nil })
  end

  -- Execute each tool call sequentially
  local results = {}
  local function execute_next(idx)
    if idx > #tool_calls then
      -- All tools executed — push results and re-call API
      for _, r in ipairs(results) do
        if wire_format == 'anthropic' then
          table.insert(all_messages, {
            role = 'user',
            content = { {
              type        = 'tool_result',
              tool_use_id = r.id,
              content     = r.output,
              is_error    = r.is_error,
            } },
          })
        else
          table.insert(all_messages, {
            role         = 'tool',
            tool_call_id = r.id,
            content      = r.output,
          })
        end
      end

      -- Single-rejection stop: if the user explicitly rejected (not
      -- cancelled) an inline-apply result during this batch, inject a
      -- hard instruction so the model asks instead of retrying.
      -- A single rejection is a strong signal — the user saw the change
      -- and said no. Guessing an alternative usually wastes tokens and
      -- frustrates the user; asking for specifics is strictly better.
      if S.turn_had_rejection then
        local stop_msg = '[system] The user rejected your previous edit. ' ..
                         'Do NOT attempt another edit or write. Instead, ' ..
                         'respond with a brief, specific clarifying ' ..
                         'question asking what the user actually wants.'
        if wire_format == 'anthropic' then
          table.insert(all_messages, { role = 'user', content = stop_msg })
        else
          table.insert(all_messages, { role = 'user', content = stop_msg })
        end
        -- Consume the flag so it only injects once per trigger.
        S.turn_had_rejection = false
      end

      -- Re-call the API with tool results
      vim.schedule(function()
        local provider_id  = config.get_provider()
        local model_id     = config.get_model()
        local loop_mode    = tool_support.effective_mode(provider_id, model_id)
        local loop_use     = loop_mode ~= 'off'
        local tools_api    = loop_use and tools_m.get_api_tools(wire_format) or nil
        S.stream_text = ''
        S.stream_line = stream_begin()

        S.stream_job = client.chat_completion(
          all_messages,
          {
            model     = model_id,
            tools     = tools_api,
            tool_mode = loop_mode,
            provider  = provider_id,
          },
          -- on_chunk
          function(chunk) vim.schedule(function() stream_chunk(chunk) end) end,
          -- on_complete (text-only response — done)
          function() vim.schedule(function()
            stream_end()
            if on_done then on_done() end
          end) end,
          -- on_error
          function(err) vim.schedule(function()
            S.is_streaming = false
            S.stream_job = nil
            stop_spinner()
            M.append_error(tostring(err))
            render_topbar()
            render_input_bar()
            if on_error_cb then on_error_cb(err) end
          end) end,
          -- on_usage
          function(usage) vim.schedule(function()
            S.token_last = usage
            if usage then S.token_total = S.token_total + (usage.total_tokens or 0) end
            render_topbar()
            render_footer()
          end) end,
          -- on_tool_calls (recursive — model wants more tools)
          function(new_tool_calls) vim.schedule(function()
            -- Finalize current stream text if any
            if S.stream_text ~= '' then
              table.insert(S.messages, { role = 'assistant', content = S.stream_text })
              local md_start = S.stream_line
              S.stream_line = nil
              render_markdown_highlights(md_start, S.stream_text)
              S.stream_text = ''
            end
            run_tool_loop(new_tool_calls, all_messages, on_done, on_error_cb, depth + 1)
          end) end
        )
      end)
      return
    end

    local tc = tool_calls[idx]
    local tool_name = tc.name
    local tool_args = tc.arguments
    local card_id   = tc.id or ('t' .. tostring(idx))

    -- Build the spec common to every card render for this tool call.
    local function base_spec()
      return {
        tool_name = tool_name,
        args      = tool_args,
      }
    end

    -- For write/edit we want a diff preview in the card. Compute old_str/new_str.
    local function compute_diff_strs()
      if tool_name == 'write' and type(tool_args.filePath) == 'string' then
        local path = tool_args.filePath
        local new_str = tool_args.content or ''
        local ok_f, f = pcall(io.open, path, 'r')
        local old_str = ''
        if ok_f and f then old_str = f:read('*a') or ''; f:close() end
        return { old_str = old_str, new_str = new_str }
      elseif tool_name == 'edit'
          and type(tool_args.oldString) == 'string'
          and type(tool_args.newString) == 'string' then
        return { old_str = tool_args.oldString, new_str = tool_args.newString }
      end
      return nil
    end

    -- Try to route write/edit through the inline-diff-in-editor flow.
    -- Returns true if the inline flow was started (caller must not also run
    -- do_execute_disk), false if the caller should fall back to disk-write.
    local function try_inline_apply()
      if tool_name ~= 'write' and tool_name ~= 'edit' then
        return false
      end
      local path = tool_args.filePath
      if type(path) ~= 'string' or path == '' then return false end

      -- Single source of truth: same precondition the upstream permission
      -- gate uses to decide whether to skip the chat prompt. Keeping these
      -- two callsites consistent prevents a class of bugs where we'd skip
      -- the chat prompt AND then fail to start the inline flow (resulting
      -- in a silent disk write with no confirmation at all).
      if not InlineApply.can_apply(path,
                                   tool_args.oldString,
                                   tool_args.newString or tool_args.content) then
        return false
      end

      -- Canonical absolute path. fnamemodify(p, ':p') handles relative,
      -- ~, and . / .. correctly.
      local abs = vim.fn.fnamemodify(path, ':p')

      -- For `edit`, compute the FULL new file content (not just the snippet)
      -- by reading the file from disk and applying the replacement, so the
      -- inline diff shows the change in context.
      local function build_full_diff_for_edit()
        local f = io.open(abs, 'r')
        if not f then return nil end
        local old_full = f:read('*a') or ''; f:close()
        local old_str = tool_args.oldString or ''
        local new_str = tool_args.newString or ''
        if old_str == '' or not old_full:find(old_str, 1, true) then return nil end
        local replace_all = tool_args.replaceAll == true
        -- Simulate the same replacement exec_edit will do, without writing
        local escaped_repl = new_str:gsub('%%', '%%%%')
        local pesc_old = vim.pesc(old_str)
        local new_full
        if replace_all then
          new_full = old_full:gsub(pesc_old, escaped_repl)
        else
          local s, e = old_full:find(old_str, 1, true)
          new_full = old_full:sub(1, s - 1) .. new_str .. old_full:sub(e + 1)
        end
        return { old_str = old_full, new_str = new_full }
      end

      -- Pick the right diff source:
      --   write → tool args contain full content (compute_diff_strs handles it)
      --   edit  → must read disk + apply replacement (compute_diff_strs gives only snippets)
      local diffs
      if tool_name == 'write' then
        diffs = compute_diff_strs()
      else
        diffs = build_full_diff_for_edit()
      end
      if not diffs then
        -- Fall back to chat-button flow if we can't compute a sensible diff
        return false
      end

      -- Make sure the file is loaded AND visible in an editor window.
      -- This handles the common case where the user opened the sidebar from
      -- a different file or where the buffer was loaded but hidden.
      local target_buf, target_win = InlineApply.ensure_buffer_visible(abs)
      if not target_buf or not target_win then
        -- Fall back to chat-button flow if we still can't get a window.
        return false
      end

      -- Confirmed: destructive op on a file we can show inline. Start.
      -- R2: chat is now PASSIVE — render a one-liner only. Accept/reject UI
      -- lives entirely in the editor (HunkControls + buffer-local Y/N keys).
      state_set('tool calling')
      ToolCard.render(card_id, vim.tbl_extend('force', base_spec(), {
        state = 'proposing',
        diff  = diffs,  -- gives the +N -M badge
      }))
      scroll_bottom(S.chat_win, S.chat_buf)

      -- Focus the target window so the user sees the diff. Flash a toast
      -- listing the live keys so the focus steal isn't silent — mitigates
      -- the "something just took my cursor and now my keys do weird things"
      -- surprise. The chat-side banner (_render_decision_banner) stays up
      -- for the full duration; the toast is a 1.5s primer.
      pcall(vim.api.nvim_set_current_win, target_win)
      show_diff_mode_toast(target_win)

      InlineApply.show(target_buf, abs, diffs.old_str, diffs.new_str, function(res)
        vim.schedule(function()
          -- Three outcomes, distinct for both the user-facing card and the
          -- tool-result fed back to the model:
          --   accepted=true            → SUCCESS (some hunks applied)
          --   accepted=false,
          --     cancelled=true         → CANCELLED (user walked away; model
          --                              must NOT retry; is_error=false so
          --                              the agentic loop treats this as
          --                              "user will prompt again")
          --   accepted=false,
          --     cancelled=false        → REJECTED (user explicitly declined;
          --                              model must stop and ask for
          --                              clarification — see the
          --                              turn_had_rejection stop-injection
          --                              in run_tool_loop)
          local accepted  = res.accepted
          local cancelled = res.cancelled == true
          local lines, is_error, tool_state
          if accepted then
            lines = {
              string.format('Applied %d of %d hunk(s) to %s',
                res.hunks_accepted, res.hunks_total, path),
            }
            is_error   = false
            tool_state = 'succeeded'
          elseif cancelled then
            lines      = { 'Review cancelled — no changes written' }
            is_error   = false   -- NOT an error: model should stop, not retry
            tool_state = 'succeeded'  -- neutral card, green-ish; no red alarm
          else
            lines      = { 'Changes rejected by user' }
            is_error   = true
            tool_state = 'failed'
            -- Arm the single-rejection stop for the next agentic iteration.
            S.turn_had_rejection = true
          end
          ToolCard.render(card_id, vim.tbl_extend('force', base_spec(), {
            state      = tool_state,
            body_lines = lines,
            body_hl    = is_error and 'AiToolError' or 'AiToolBody',
            diff       = accepted and diffs or nil,  -- keep +/- badge using full diff
          }))
          scroll_bottom(S.chat_win, S.chat_buf)
          -- Record per-turn stats for the summary card
          local adds, dels = 0, 0
          if accepted and diffs then
            local d = ToolCard.compute_diff(diffs.old_str, diffs.new_str, 9999, 0)
            for _, item in ipairs(d) do
              if item.type == 'add' then adds = adds + 1 end
              if item.type == 'del' then dels = dels + 1 end
            end
          end
          M._record_inline_result(abs,
            res.hunks_accepted or 0,
            res.hunks_rejected or 0,
            adds, dels)
          M._render_inline_summary()
          -- Clear the chat-side "decision pending" banner now that this
          -- inline session has resolved.
          M._render_decision_banner()
          table.insert(results, {
            id       = tc.id,
            output   = table.concat(lines, '\n'),
            is_error = is_error,
          })
          if win_ok(S.input_win) then
            pcall(vim.api.nvim_set_current_win, S.input_win)
          end
          execute_next(idx + 1)
        end)
      end)
      -- Feature 5: refresh the multi-file summary card now that this session
      -- has been registered with InlineApply.
      vim.schedule(function() M._render_inline_summary() end)
      -- Show the chat-side "decision pending" banner above the input bar so
      -- the user sees a persistent reminder of the live keys even after the
      -- 1.5s editor-side toast fades.
      vim.schedule(function() M._render_decision_banner() end)
      return true
    end

    local function do_execute()
      -- Try inline apply first for write/edit on open buffers
      if try_inline_apply() then return end

      state_set('tool calling')
      ToolCard.render(card_id, vim.tbl_extend('force', base_spec(),
        { state = 'running', diff = compute_diff_strs() }))
      scroll_bottom(S.chat_win, S.chat_buf)
      vim.schedule(function()
        local result, err = tools_m.execute(tool_name, tool_args)
        local output = result or err or 'No output'
        local is_error = (result == nil)
        local body = vim.split(output or '', '\n', { plain = true })
        ToolCard.render(card_id, vim.tbl_extend('force', base_spec(), {
          state      = is_error and 'failed' or 'succeeded',
          body_lines = body,
          body_hl    = is_error and 'AiToolError' or 'AiToolBody',
          diff       = not is_error and compute_diff_strs() or nil,
        }))
        scroll_bottom(S.chat_win, S.chat_buf)
        table.insert(results, {
          id       = tc.id,
          output   = output,
          is_error = is_error,
        })
        execute_next(idx + 1)
      end)
    end

    -- Common permission renderer: draw the card with `permission` state and
    -- install the inline button row at the reserved placeholder line.
    local function prompt_permission(buttons, on_allow, on_always, on_deny)
      local render_info = ToolCard.render(card_id, vim.tbl_extend('force', base_spec(), {
        state       = 'permission',
        diff        = compute_diff_strs(),
        permission  = { buttons = buttons },
      }))
      scroll_bottom(S.chat_win, S.chat_buf)
      if not render_info then return end
      -- Prefer the explicit button_row exposed by the renderer so we don't
      -- have to encode knowledge of the card's internal padding here.
      local btn_row = render_info.button_row or (render_info.end_row - 2)
      ButtonRow.show(S.chat_buf, btn_row, buttons, {
        on_click = function(bid)
          if bid == 'allow_once'  or bid == 'allow'       then on_allow()  end
          if bid == 'allow_always'                         then on_always() end
          if bid == 'reject_once' or bid == 'deny' or bid == 'reject'
                                                           then on_deny()   end
        end,
      })
      -- Move cursor onto the button row so Tab/Enter work intuitively.
      if win_ok(S.chat_win) then
        pcall(vim.api.nvim_win_set_cursor, S.chat_win, { btn_row + 1, 1 })
      end
    end

    local function record_denied(reason)
      table.insert(results, {
        id       = tc.id,
        output   = 'Permission denied by user' .. (reason and (' (' .. reason .. ')') or ''),
        is_error = true,
      })
      ToolCard.render(card_id, vim.tbl_extend('force', base_spec(), {
        state      = 'failed',
        body_lines = { 'Permission denied' .. (reason and (' (' .. reason .. ')') or '') },
        body_hl    = 'AiToolError',
      }))
      execute_next(idx + 1)
    end

    -- Render a preparing card immediately so the user sees activity.
    ToolCard.render(card_id, vim.tbl_extend('force', base_spec(),
      { state = 'generating', diff = compute_diff_strs() }))
    scroll_bottom(S.chat_win, S.chat_buf)

    -- ── Tiered permission check ─────────────────────────────────────────────
    -- 1. Read-only tools → auto-allow (regardless of path scope).
    -- 2. write/edit on a file we CAN inline-apply → SKIP the chat prompt.
    --    The editor diff (y/n per hunk) IS the per-call confirmation surface.
    --    This honors the principle "editor owns accept/reject for inline-apply;
    --    chat is a passive observer". Without this gate we'd double-prompt.
    -- 3. Destructive tools on files outside the editor scope → ask, with a
    --    distinct "external file" button set.
    -- 4. Destructive tools on in-scope files (or bash) → existing tool-level
    --    permission (ask-once per session via /trust).
    local scope_fn = function(p)
      local ctx_files = (context.get_files and context.get_files()) or nil
      return editor_m.path_in_scope(p, S.editor_state, ctx_files)
    end
    local path_perm = tools_m.path_permission(tool_name, tool_args, S.trust_mode, scope_fn)

    -- Will the inline-apply flow handle confirmation in the editor? If so,
    -- we never need to prompt in chat (the editor diff IS the approval).
    local can_inline = (tool_name == 'edit' or tool_name == 'write')
      and InlineApply.can_apply(
            tool_args.filePath,
            tool_args.oldString,
            tool_args.newString or tool_args.content)

    if path_perm == 'auto' then
      do_execute()
    elseif can_inline then
      -- Editor-confirmed flow. do_execute() routes through try_inline_apply()
      -- first, which will show the diff with hunk-level y/n. No chat prompt.
      do_execute()
    elseif path_perm == 'external' then
      local path = tools_m.extract_path(tool_name, tool_args) or '?'
      prompt_permission(
        {
          { id = 'allow_once',   label = 'Allow',        icon = ''  },
          { id = 'allow_always', label = 'Always (this file)', icon = ''  },
          { id = 'reject_once',  label = 'Reject',       icon = '✗', danger = true },
        },
        function() do_execute() end,
        function()
          tools_m.approve_external(path)
          toast('Approved external file for this session', 'info')
          do_execute()
        end,
        function() record_denied('external file') end
      )
    else
      if tools_m.is_allowed(tool_name, S.trust_mode) then
        do_execute()
      else
        prompt_permission(
          {
            { id = 'allow_once',   label = 'Allow',        icon = ''  },
            { id = 'allow_always', label = 'Allow Always', icon = ''  },
            { id = 'reject_once',  label = 'Reject',       icon = '✗', danger = true },
          },
          function() do_execute() end,
          function()
            tools_m.approve(tool_name)
            toast(tool_name .. ' auto-approved for this session', 'info')
            do_execute()
          end,
          function() record_denied() end
        )
      end
    end
  end

  execute_next(1)
end


-- ── File picker ───────────────────────────────────────────────────────────
local function pick_file_telescope()
  local ok, tbi = pcall(require, 'telescope.builtin')
  if ok then
    tbi.find_files({
      prompt_title = ' Attach file',
      attach_mappings = function(_, map)
        local actions = require('telescope.actions')
        local state   = require('telescope.actions.state')
        map('i', '<CR>', function(prompt_bufnr)
          local sel = state.get_selected_entry()
          actions.close(prompt_bufnr)
          if sel then
            context.add_file(sel[1])
            M.append_system('Attached: ' .. sel[1])
          end
        end)
        return true
      end,
    })
  else
    -- fallback: vim.fn.input
    local path = vim.fn.input('Attach file: ', '', 'file')
    if path ~= '' then
      context.add_file(path)
      M.append_system('Attached: ' .. path)
    end
  end
end

-- ── Input helpers ─────────────────────────────────────────────────────────
local function get_input_text()
  if not S.input_buf or not vim.api.nvim_buf_is_valid(S.input_buf) then return '' end
  local lines = vim.api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
  return vim.trim(table.concat(lines, '\n'))
end

local function clear_input()
  if not S.input_buf or not vim.api.nvim_buf_is_valid(S.input_buf) then return end
  pcall(vim.api.nvim_buf_set_option, S.input_buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(S.input_buf, 0, -1, false, { '' })
  if win_ok(S.input_win) then
    pcall(vim.api.nvim_win_set_cursor, S.input_win, { 1, 0 })
  end
end

-- Input bar (winbar on input window) — Gemini style:
--  left:  [+]  [Tools]  [model ▾]
--  right: [↑]
-- ── Footer status bar (OpenCode-style: working dir + context + tokens) ────
render_footer = function()
  if not win_ok(S.chat_win) then return end

  local ok_f, _ = pcall(function()
    local function chip(hl, text)
      return '%#' .. hl .. '#' .. text:gsub('%%', '%%%%') .. '%*'
    end

    local agent_name = (agents.active_name and agents.active_name()) or 'Code'
    local streaming  = S.is_streaming

    -- Left: cwd + project-instructions badge + tool-mode badge
    local cwd = vim.fn.fnamemodify(vim.fn.getcwd(), ':~')
    if #cwd > 35 then cwd = '…' .. cwd:sub(-33) end
    local left = chip('AiFooterBg', '  ')
      .. chip('AiFooterDir', cwd)

    -- Active buffer chip (editor state awareness — Cursor-style)
    local ed_state = S.editor_state
      or editor_m.capture({ origin_buf = S.origin_buf })
    local active_label = editor_m.short_label(ed_state)
    if active_label then
      left = left .. chip('AiFooterBg', '  ')
        .. chip('AiFooterCtx', active_label)
    end
    local sel_label = editor_m.selection_label(ed_state)
    if sel_label then
      left = left .. chip('AiFooterBg', '  ')
        .. chip('AiFooterCost', sel_label)
    end

    -- PANDAVIM.md / AGENTS.md / CLAUDE.md indicator
    local project_file = system_m.get_project_file()
    if project_file then
      left = left .. chip('AiFooterBg', '  ')
        .. chip('AiFooterCtx', project_file)
    end

    -- Tool-mode badge (only shown when non-default)
    local effective_mode = tool_support.effective_mode(
      config.get_provider(), config.get_model())
    if effective_mode == 'react' then
      left = left .. chip('AiFooterBg', '  ')
        .. chip('AiFooterCost', 'ReAct')
    elseif effective_mode == 'off' then
      -- Prominent warning — "Tools OFF" is a footgun users often hit
      -- accidentally via persisted config
      left = left .. chip('AiFooterBg', '  ')
        .. chip('AiFooterError', '⚠ Tools OFF')
    end

    -- Debug indicator
    if config.get_debug_mode() then
      left = left .. chip('AiFooterBg', '  ')
        .. chip('AiFooterCost', 'DEBUG')
    end

    left = left .. chip('AiFooterBg', '  ')

    -- Right: [spinner] + agent + @file + tokens
    local parts = {}

    if streaming then
      local frame = SPINNER_FRAMES[S.spinner_frame] or '⣾'
      table.insert(parts, chip('AiBarSpinner', frame))
    end

    table.insert(parts, chip('AiFooterCtx', agent_name))

    local ctx_n = context.count and context.count() or 0
    if ctx_n > 0 then
      local ctx_label = ctx_n == 1 and (ctx_n .. ' file') or (ctx_n .. ' files')
      table.insert(parts, chip('AiFooterCtx', ctx_label))
    end

    if S.token_total and S.token_total > 0 then
      local tok_str = S.token_total >= 1000
        and string.format('%.1fk', S.token_total / 1000)
        or tostring(S.token_total)
      table.insert(parts, chip('AiFooterToken', tok_str .. ' tokens'))
    end

    local right = table.concat(parts, chip('AiFooterBg', '  '))
      .. chip('AiFooterBg', '  ')

    vim.api.nvim_win_set_option(S.chat_win, 'statusline', left .. '%=' .. right)
  end)
end

render_input_bar = function()
  if not win_ok(S.input_win) then return end

  local model      = config.get_model()
  local provider   = config.get_provider()
  local short_m    = model:match('([^%-/]+)$') or model
  if #short_m > 20 then short_m = short_m:sub(1, 18) .. '…' end
  local agent_name = (agents.active_name and agents.active_name()) or 'Code'
  local streaming  = S.is_streaming

  local function chip(hl, text)
    return '%#' .. hl .. '#' .. text:gsub('%%', '%%%%') .. '%*'
  end

  -- Left: agent (colored) · model · provider — with padding
  local left = chip('AiBarBg', '  ')
    .. chip('AiBarAgent', agent_name)
    .. chip('AiBarBg', '  ')
    .. chip('AiBarModel', short_m)
    .. chip('AiBarBg', ' · ')
    .. chip('AiBarModel', provider)

  -- Right: spinner + esc during streaming, or send arrow
  local right
  if streaming then
    local frame = SPINNER_FRAMES[S.spinner_frame] or '⣾'
    right = chip('AiBarSpinner', frame)
      .. chip('AiBarBg', '  ')
      .. chip('AiBarModel', 'esc')
      .. chip('AiBarBg', ' ')
      .. chip('AiFooterToken', 'interrupt')
      .. chip('AiBarBg', '  ')
  else
    right = chip('AiBarSend', ' ↑ ')
      .. chip('AiBarBg', '  ')
  end

  pcall(vim.api.nvim_win_set_option, S.input_win, 'winbar', left .. '%=' .. right)
end

-- ── Session helpers ───────────────────────────────────────────────────────
session_save = function()
  if not S.session_id then
    S.session_id = sessions.new_id()
  end
  sessions.save(S.session_id, S.messages, agents.active_name())
end

local function session_new(keep_welcome)
  -- push current to undo stack before clearing
  if #S.messages > 0 then
    session_save()
  end
  S.messages    = {}
  S.undo_stack  = {}
  S.redo_stack  = {}
  S.session_id  = sessions.new_id()
  -- Reset staged attachments so a leftover pick from the prior session
  -- doesn't bleed into the first message of the new one.
  S.pending_attachments = {}
  -- Reset the rejection stop-flag so a lingering rejection from the prior
  -- session doesn't immediately short-circuit the first tool call.
  S.turn_had_rejection  = false
  -- Reset tool approvals for new session
  tools_m.reset_approvals()
  state_clear()
  ToolCard._reset()
  ButtonRow.hide()
  -- F4b: also wipe any stale button-row extmarks left behind in the chat
  -- buffer (hide() only clears the currently-active row). Without this,
  -- /new can leave ghost [Accept] [Reject] highlights from the prior session.
  ButtonRow.clear_buf(S.chat_buf)
  M._reset_turn_stats()
  clear_message_toolbars()
  bset(S.chat_buf, 0, -1, {})
  if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
  if keep_welcome ~= false then render_welcome() end
end

-- ── Undo/redo helpers ─────────────────────────────────────────────────────
local function redraw_chat_from_messages()
  -- Full redraw of chat buffer from S.messages
  bset(S.chat_buf, 0, -1, {})
  if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
  S.showing_welcome = false
  if #S.messages == 0 then render_welcome(); return end
  for _, msg in ipairs(S.messages) do
    append_message(msg.role, msg.content, msg.attachments)
  end
end

local function push_undo()
  -- Deep-copy current messages onto undo stack
  local snap = vim.deepcopy(S.messages)
  table.insert(S.undo_stack, snap)
  -- clear redo on new action
  S.redo_stack = {}
end

-- ── Slash commands ────────────────────────────────────────────────────────
-- Single source of truth: CMDS table.  Each entry:
--   name      (string)  — the command name typed after /
--   desc      (string)  — shown in /help and slash float
--   alias     (string)  — if set, delegates to the named command instead of fn
--   fn        (func)    — function(arg) called with the rest of the line (may be '')
--   key       (string?) — keybind hint shown in slash float (e.g. 'm  topbar')
--   suggested (bool?)   — if true, sorted to top of slash float
-- The slash autocomplete float and M.complete_slash both read cmd_entries() below.

local CMDS = nil  -- assigned immediately after the helper functions below

-- helper: focus the editor window so pickers have a valid non-nofile anchor
local function focus_for_picker()
  vim.cmd('stopinsert')
  local function try(wid)
    if not wid or is_sidebar_win(wid) then return false end
    local ok, cfg = pcall(vim.api.nvim_win_get_config, wid)
    if not ok or cfg.relative ~= '' then return false end
    local buf = vim.api.nvim_win_get_buf(wid)
    local ok2, bt = pcall(vim.api.nvim_buf_get_option, buf, 'buftype')
    if not ok2 or bt ~= '' then return false end
    vim.api.nvim_set_current_win(wid)
    S.last_editor_win = wid
    return true
  end
  if try(S.last_editor_win) then return end
  for _, wid in ipairs(vim.api.nvim_list_wins()) do
    if try(wid) then return end
  end
  -- last resort: any non-sidebar non-floating window
  for _, wid in ipairs(vim.api.nvim_list_wins()) do
    if not is_sidebar_win(wid) then
      local ok, cfg = pcall(vim.api.nvim_win_get_config, wid)
      if ok and cfg.relative == '' then
        vim.api.nvim_set_current_win(wid)
        return
      end
    end
  end
end

refocus_input = function()
  if win_ok(S.input_win) then
    vim.api.nvim_set_current_win(S.input_win)
    vim.cmd('startinsert')
  end
end

-- helper used by several commands to do a full redraw after state change
local function redraw_all()
  bset(S.chat_buf, 0, -1, {})
  if NS_CHAT then vim.api.nvim_buf_clear_namespace(S.chat_buf, NS_CHAT, 0, -1) end
  S.showing_welcome = false
  if #S.messages == 0 then render_welcome(); return end
  for _, msg in ipairs(S.messages) do append_message(msg.role, msg.content, msg.attachments) end
end

-- returns a flat list of primary command entries (no aliases) for autocomplete
-- Each entry: { name, desc, key, suggested, aliases }
local function cmd_entries()
  local entries = {}
  if CMDS then
    -- first pass: collect alias names per primary command
    local alias_map = {}
    for _, c in ipairs(CMDS) do
      if c.alias then
        alias_map[c.alias] = alias_map[c.alias] or {}
        table.insert(alias_map[c.alias], c.name)
      end
    end
    -- second pass: build entries for primary commands only
    for _, c in ipairs(CMDS) do
      if not c.alias then
        table.insert(entries, {
          name      = c.name,
          desc      = c.desc or '',
          key       = c.key,
          suggested = c.suggested,
          aliases   = alias_map[c.name] or {},
        })
      end
    end
  end
  return entries
end

-- backwards-compat: flat list of primary command names
local function cmd_names()
  local names = {}
  for _, e in ipairs(cmd_entries()) do
    table.insert(names, e.name)
  end
  return names
end

-- Build CMDS table — defined here so all helpers above are in scope
CMDS = {
  -- ── session ────────────────────────────────────────────────────────────
  { name = 'new',   desc = 'Start a new session', key = '+  topbar', suggested = true, fn = function(_)
      session_new()
  end },
  { name = 'clear', alias = 'new' },

  -- ── model ─────────────────────────────────────────────────────────────
  { name = 'model', desc = 'Switch model', key = 'm  topbar', suggested = true, fn = function(arg)
      if arg ~= '' then
        config.set_model(arg); render_topbar()
      else
        open_model_picker()
      end
  end },
  { name = 'models', alias = 'model' },

  -- ── provider ──────────────────────────────────────────────────────────
  { name = 'provider', desc = 'Switch provider', key = 'p  topbar', suggested = true, fn = function(arg)
      if arg ~= '' then
        config.set_provider(arg); render_topbar()
      else
        open_provider_picker()
      end
  end },
  { name = 'providers', alias = 'provider' },
  { name = 'connect',   alias = 'provider' },

  -- ── add provider (alias for /provider — same as OpenCode's /connect) ───
  { name = 'addprovider', alias = 'provider' },
  { name = 'addprov',     alias = 'provider' },

  -- ── agents ────────────────────────────────────────────────────────────
  { name = 'agents', desc = 'Pick / activate an agent preset', suggested = true, fn = function(arg)
      if arg ~= '' then
        agents.activate(arg)
        M.append_system('Agent activated: ' .. arg)
        render_topbar()
        render_input_bar()
        render_footer()
      else
        local all = agents.list()
        local items = {}
        -- "(none)" resets to no agent
        table.insert(items, { name = nil, label = '  (none) — no agent' })
        for _, a in ipairs(all) do
          table.insert(items, {
            name  = a.name,
            label = a.name .. '  —  ' .. (a.description or ''),
          })
        end
        open_picker({
          title  = 'Agents',
          items  = items,
          format = function(item)
            -- Strip the manual ● marker since we use current() now
            return item.label:gsub('^● ', ''):gsub('^  ', '')
          end,
          current = function(item)
            return item.name == agents.active_name()
          end,
          on_confirm = function(item)
            agents.activate(item.name)
            M.append_system('Agent: ' .. (item.name or '(default)'))
            render_topbar()
            render_input_bar()
            render_footer()
          end,
        })
      end
  end },
  { name = 'agent', alias = 'agents' },

  -- ── skills ────────────────────────────────────────────────────────────
  { name = 'skills', desc = 'Pick a skill to load', fn = function(arg)
      -- Direct-name invocation still supported: /skills refactor
      if arg ~= '' then
        local sk = skills_m.get_skill(arg)
        if sk then
          M.append_system('Skill loaded: ' .. arg .. '\n' .. sk.description)
        else
          M.append_system('Unknown skill: ' .. arg)
        end
        return
      end
      -- No arg → OpenCode-style picker with title, fuzzy search, descriptions,
      -- and a filetype footer column for each skill. Matches /agents, /sessions.
      local items = {}
      for _, name in ipairs(skills_m.list_skills()) do
        local sk = skills_m.get_skill(name)
        table.insert(items, {
          name        = name,
          description = sk and sk.description or '',
          ftypes      = sk and sk.context or {},
        })
      end
      if #items == 0 then
        M.append_system('No skills available.')
        return
      end
      open_picker({
        title         = 'Skills',
        items         = items,
        format        = function(it) return it.name end,
        format_desc   = function(it) return it.description end,
        format_footer = function(it)
          if it.ftypes and #it.ftypes > 0 then
            -- Show up to 3 filetypes; indicate overflow with an ellipsis
            local show = {}
            for i = 1, math.min(3, #it.ftypes) do show[i] = it.ftypes[i] end
            local s = table.concat(show, ', ')
            if #it.ftypes > 3 then s = s .. '…' end
            return s
          end
          return nil
        end,
        on_confirm = function(it)
          local sk = skills_m.get_skill(it.name)
          if sk then
            M.append_system('Skill loaded: ' .. it.name .. '\n' .. sk.description)
          else
            M.append_system('Skill: ' .. it.name)
          end
        end,
      })
  end },
  { name = 'skill', alias = 'skills' },

  -- ── sessions ──────────────────────────────────────────────────────────
  { name = 'sessions', desc = 'List & switch saved sessions', suggested = true, fn = function(_)
      local list = sessions.list()
      if #list == 0 then M.append_system('No saved sessions.'); return end
      local items = {}
      for _, s in ipairs(list) do
        local label = string.format('%s  %s(%s)',
          s.title,
          s.agent ~= '' and ('[' .. s.agent .. '] ') or '',
          sessions.fmt_time(s.updated_at))
        table.insert(items, { id = s.id, agent = s.agent, label = label })
      end
      open_picker({
        title  = 'Sessions',
        items  = items,
        format = function(item) return item.label end,
        on_confirm = function(item)
          local msgs, agent = sessions.load(item.id)
          S.messages    = msgs
          S.session_id  = item.id
          S.undo_stack  = {}
          S.redo_stack  = {}
          agents.activate(agent)
          redraw_all()
          render_topbar()
        end,
      })
  end },
  { name = 'resume',   alias = 'sessions' },
  { name = 'continue', alias = 'sessions' },

  -- ── undo / redo ───────────────────────────────────────────────────────
  { name = 'undo', desc = 'Undo last message exchange', fn = function(_)
      if #S.undo_stack == 0 then M.append_system('Nothing to undo.'); return end
      table.insert(S.redo_stack, vim.deepcopy(S.messages))
      S.messages = table.remove(S.undo_stack)
      redraw_all()
      vim.notify('Undid last message pair', vim.log.levels.INFO)
  end },
  { name = 'redo', desc = 'Redo after undo', fn = function(_)
      if #S.redo_stack == 0 then M.append_system('Nothing to redo.'); return end
      table.insert(S.undo_stack, vim.deepcopy(S.messages))
      S.messages = table.remove(S.redo_stack)
      redraw_all()
      vim.notify('Redid message pair', vim.log.levels.INFO)
  end },

  -- ── rename ─────────────────────────────────────────────────────────────
  { name = 'rename', desc = 'Rename current session', fn = function(arg)
      if arg ~= '' then
        local raw = sessions.load_raw(S.session_id)
        if raw then
          raw.title = arg
          local fp = vim.fn.stdpath('data') .. '/ai_sessions/' .. S.session_id .. '.json'
          local f = io.open(fp, 'w')
          if f then f:write(vim.fn.json_encode(raw)); f:close() end
        end
        toast('Session renamed: ' .. arg, 'success')
        render_topbar()
      else
        open_prompt({
          title       = 'Rename session',
          placeholder = 'New title',
          on_cancel   = function() end,
          on_confirm  = function(title)
            if title == '' then toast('Title required', 'warn'); return end
            local raw = sessions.load_raw(S.session_id)
            if raw then
              raw.title = title
              local fp = vim.fn.stdpath('data') .. '/ai_sessions/' .. S.session_id .. '.json'
              local f = io.open(fp, 'w')
              if f then f:write(vim.fn.json_encode(raw)); f:close() end
            end
            toast('Session renamed: ' .. title, 'success')
            render_topbar()
          end,
        })
      end
  end },

  -- ── copy transcript ───────────────────────────────────────────────────
  { name = 'copy', desc = 'Copy session transcript to clipboard', fn = function(_)
      if #S.messages == 0 then M.append_system('Nothing to copy.'); return end
      local parts = {}
      for _, m in ipairs(S.messages) do
        local role = m.role == 'user' and 'You' or 'Assistant'
        table.insert(parts, '## ' .. role .. '\n\n' .. m.content)
      end
      vim.fn.setreg('+', table.concat(parts, '\n\n---\n\n'))
      toast('Session transcript copied', 'success')
  end },

  -- ── timestamps toggle ─────────────────────────────────────────────────
  { name = 'timestamps', desc = 'Toggle message timestamps', fn = function(_)
      local new_val = not config.get_show_timestamps()
      config.set_show_timestamps(new_val)
      S.show_timestamps = new_val
      redraw_all()
      toast('Timestamps: ' .. (new_val and 'shown' or 'hidden'), 'info')
  end },

  -- ── compact ───────────────────────────────────────────────────────────
  { name = 'compact', desc = 'Summarise conversation in place', fn = function(_)
      if #S.messages == 0 then M.append_system('Nothing to compact.'); return end
      M.append_system('Compacting conversation…')
      local sp = 'Summarise the following conversation concisely in 3-5 bullet points, '
        .. 'capturing the key questions asked and decisions made:\n\n'
      for _, m in ipairs(S.messages) do
        sp = sp .. m.role:upper() .. ': ' .. m.content .. '\n\n'
      end
      local summary = ''
      client.chat_completion(
        { { role = 'user', content = sp } },
        { model = config.get_model(), tool_mode = 'off' },
        function(c) summary = summary .. c end,
        function()
          vim.schedule(function()
            S.messages = {
              { role = 'user',      content = '[Compacted conversation]' },
              { role = 'assistant', content = summary },
            }
            session_save(); redraw_all()
          end)
        end,
        function(err) vim.schedule(function()
          M.append_system('Compact error: ' .. tostring(err))
        end) end
      )
  end },
  { name = 'summarize', alias = 'compact' },
  { name = 'summarise', alias = 'compact' },

  -- ── export ────────────────────────────────────────────────────────────
  { name = 'export', desc = 'Save chat to a Markdown file', fn = function(arg)
      if #S.messages == 0 then M.append_system('Nothing to export.'); return end
      local function do_export(path)
        local f = io.open(path, 'w')
        if not f then M.append_system('Could not create: ' .. path); return end
        f:write('# AI Chat Export\n\n*' .. os.date('%Y-%m-%d %H:%M') .. '*\n\n---\n\n')
        for _, m in ipairs(S.messages) do
          f:write((m.role == 'user' and '**You**' or '**Assistant**')
            .. '\n\n' .. m.content .. '\n\n---\n\n')
        end
        f:close()
        toast('Exported to: ' .. path, 'success')
        M.append_system('Exported to: ' .. path)
      end
      -- /export <path> → write directly to that path
      local a = vim.trim(arg or '')
      if a ~= '' then
        do_export(vim.fn.expand(a))
        return
      end
      -- No arg → prompt for destination (pre-filled with a sensible default)
      local default_path = vim.fn.getcwd() .. '/ai-chat-'
                         .. os.date('%Y%m%d-%H%M') .. '.md'
      open_prompt({
        title       = 'Export chat',
        description = 'Markdown file path',
        placeholder = 'Destination path',
        initial     = default_path,
        on_confirm  = function(path)
          if path == '' then toast('Path required', 'warn'); return end
          do_export(vim.fn.expand(path))
        end,
      })
  end },

  -- ── editor ────────────────────────────────────────────────────────────
  -- Opens current input text in the left editor window as a scratch buffer.
  -- Write the buffer and close it to paste back; or just edit in place.
  { name = 'editor', desc = 'Edit prompt in a scratch buffer', fn = function(_)
      local cur = get_input_text()
      local scratch = vim.api.nvim_create_buf(false, true)
      pcall(vim.api.nvim_buf_set_name, scratch, 'AI:prompt-editor')
      vim.api.nvim_buf_set_option(scratch, 'buftype',   'nofile')
      vim.api.nvim_buf_set_option(scratch, 'bufhidden', 'wipe')
      vim.api.nvim_buf_set_option(scratch, 'swapfile',  false)
      vim.api.nvim_buf_set_option(scratch, 'filetype',  'markdown')
      if cur ~= '' then
        vim.api.nvim_buf_set_lines(scratch, 0, -1, false,
          vim.split(cur, '\n', { plain = true }))
      end
      -- Focus the editor side and open the scratch buffer there
      focus_for_picker()
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), scratch)
      vim.cmd('startinsert')
      -- When the scratch buffer is closed, paste its content into the input
      vim.api.nvim_create_autocmd('BufWipeout', {
        buffer = scratch,
        once   = true,
        callback = function()
          local lines = vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
          local text  = vim.trim(table.concat(lines, '\n'))
          if text ~= '' and S.input_buf and vim.api.nvim_buf_is_valid(S.input_buf) then
            pcall(vim.api.nvim_buf_set_option, S.input_buf, 'modifiable', true)
            vim.api.nvim_buf_set_lines(S.input_buf, 0, -1, false,
              vim.split(text, '\n', { plain = true }))
          end
          vim.schedule(refocus_input)
        end,
      })
  end },

  -- ── init ──────────────────────────────────────────────────────────────
  { name = 'init', desc = 'Generate / update AGENTS.md for cwd', fn = function(_)
      local cwd = vim.fn.getcwd()
      local agents_md = cwd .. '/AGENTS.md'
      local existing = ''
      local f = io.open(agents_md, 'r')
      if f then existing = f:read('*a'); f:close() end
      local prompt = 'Create or update an AGENTS.md file for this project. '
        .. 'The file should describe: project purpose, tech stack, coding conventions, '
        .. 'common commands (build/test/lint), and any special rules for AI assistants. '
        .. (existing ~= '' and ('Here is the current content:\n\n' .. existing)
            or 'There is no existing AGENTS.md.')
      table.insert(S.messages, { role = 'user', content = prompt })
      append_message('user', prompt)
      S.is_streaming = true; S.stream_text = ''; S.stream_line = stream_begin()
      render_topbar()
      -- /init intentionally bypasses tools: it just wants text output.
      client.chat_completion(
        context.build_messages(S.messages, system_m.build({
          model_id     = config.get_model(),
          agent_system = agents.active_system_prompt(),
          tool_mode    = 'off',
        })),
        { model = config.get_model(), tool_mode = 'off' },
        function(c) vim.schedule(function() stream_chunk(c) end) end,
        function()
          vim.schedule(function()
            stream_end()
            local out = io.open(agents_md, 'w')
            if out then
              out:write(S.messages[#S.messages].content or ''); out:close()
              M.append_system('Written to: ' .. agents_md)
            end
          end)
        end,
        function(err) vim.schedule(function()
          S.is_streaming = false; M.append_error(tostring(err))
          render_topbar()
        end) end
      )
  end },

  -- ── thinking ──────────────────────────────────────────────────────────
  { name = 'thinking', desc = 'Toggle chain-of-thought display', fn = function(_)
      S.thinking = not S.thinking
      M.append_system('Thinking mode: ' .. (S.thinking and 'ON' or 'OFF')
        .. (S.thinking and '\n  Chain-of-thought markers will be shown.' or ''))
  end },

  -- ── trust mode ────────────────────────────────────────────────────────
  { name = 'trust', desc = 'Toggle trust mode (auto-approve all tool calls)', fn = function(_)
      S.trust_mode = not S.trust_mode
      if S.trust_mode then
        toast('Trust mode: ON — all tools auto-approved', 'warn')
      else
        toast('Trust mode: OFF — write/edit/bash will ask permission', 'info')
      end
      M.append_system('Trust mode: ' .. (S.trust_mode and 'ON' or 'OFF'))
  end },

  -- ── tool mode ─────────────────────────────────────────────────────────
  { name = 'tools', desc = 'Tool mode: /tools [status|auto|native|react|off]', fn = function(arg)
      local a = vim.trim(arg or ''):lower()
      if a == '' or a == 'status' then
        local cfg_mode = config.get_tool_mode() or 'auto'
        local provider = config.get_provider()
        local model    = config.get_model()
        local effective = tool_support.effective_mode(provider, model)
        local msg = string.format(
          'Tool mode:\n  configured: %s\n  effective:  %s\n  provider:   %s\n  model:      %s',
          cfg_mode, effective, provider, model)
        -- Append actionable hint if tools are off — this is the #1 footgun
        if effective == 'off' then
          msg = msg .. '\n\n  ⚠  Tools are DISABLED. The AI cannot modify files.'
                    .. '\n  To re-enable: /tools auto   (or /tools react for local/proxy models)'
        elseif cfg_mode == 'auto' and effective == 'native' and not tool_support.NATIVE_PROVIDERS[provider] then
          msg = msg .. '\n\n  ℹ  Provider "' .. provider .. '" is not a known-native provider.'
                    .. '\n  If tools do not work, try: /tools react'
        end
        M.append_system(msg)
        return
      end
      if a ~= 'auto' and a ~= 'native' and a ~= 'react' and a ~= 'off' then
        M.append_system('Invalid mode. Use: auto | native | react | off')
        return
      end
      -- Extra guardrail: confirm before turning tools off
      if a == 'off' then
        toast('Tools DISABLED — the AI can only chat, not modify files', 'warn')
      end
      config.set_tool_mode(a)
      tool_support.force(a == 'auto' and nil or a)
      tool_support.reset_detection()
      toast('Tool mode: ' .. a, 'info')
      M.append_system('Tool mode set to: ' .. a)
      render_topbar(); render_input_bar(); pcall(render_footer)
  end },

  -- ── debug logging ─────────────────────────────────────────────────────
  { name = 'debug', desc = 'Toggle debug logging: /debug [on|off|path]', fn = function(arg)
      local a = vim.trim(arg or ''):lower()
      if a == 'path' then
        M.append_system('Debug log: ' .. client.debug_path())
        return
      end
      local new_val
      if a == 'on' then new_val = true
      elseif a == 'off' then new_val = false
      else new_val = not config.get_debug_mode() end
      config.set_debug_mode(new_val)
      client.set_debug(new_val)
      toast('Debug logging: ' .. (new_val and 'ON' or 'OFF'), 'info')
      if new_val then
        M.append_system('Debug logging ON. Writing to: ' .. client.debug_path())
      else
        M.append_system('Debug logging OFF.')
      end
  end },

  -- ── ctx ───────────────────────────────────────────────────────────────
  -- No arg  → picker showing currently-attached files; <CR> removes the
  --           selected file, 'c' clears all, Esc dismisses.
  -- "clear" → clear all (explicit shortcut without the picker).
  { name = 'ctx', desc = 'View or manage attached file context', fn = function(arg)
      local a = vim.trim(arg or ''):lower()
      if a == 'clear' then
        context.clear()
        M.append_system('Context cleared.')
        return
      end
      local files = context.get_files() or {}
      if #files == 0 then
        M.append_system('No files attached to context.')
        return
      end
      local items = {}
      for _, f in ipairs(files) do
        local abs   = f.path or ''
        local short = vim.fn.fnamemodify(abs, ':.')
        local ext   = (abs:match('%.([^%.]+)$') or ''):lower()
        local badge
        if ext == 'png' or ext == 'jpg' or ext == 'jpeg' or ext == 'gif'
           or ext == 'webp' or ext == 'svg' then badge = 'img'
        elseif ext == 'pdf' then badge = 'pdf'
        else                      badge = 'txt' end
        local line_count = f.lines and #f.lines or 0
        table.insert(items, {
          path       = abs,
          short      = short,
          badge      = badge,
          line_count = line_count,
        })
      end
      open_picker({
        title       = 'Attached context',
        items       = items,
        format      = function(it) return it.badge .. '  ' .. it.short end,
        format_desc = function(it) return it.line_count .. ' lines' end,
        footer_keys = {
          { key = 'c',   label = 'Clear all' },
          { key = 'd',   label = 'Remove' },
        },
        on_keypress = function(key, close_fn, sel_item)
          if key == 'c' then
            close_fn()
            context.clear()
            toast('Context cleared', 'info')
            return true
          end
          if key == 'd' and sel_item then
            close_fn()
            context.remove_file(sel_item.path)
            toast('Removed: ' .. sel_item.short, 'info')
            return true
          end
          return false
        end,
        on_confirm = function(it)
          -- Default action: remove the selected file (matches the 'd' key).
          context.remove_file(it.path)
          toast('Removed: ' .. it.short, 'info')
        end,
      })
  end },

  -- ── help ──────────────────────────────────────────────────────────────
  { name = 'help', desc = 'Show this help', fn = function(_)
      local lines = {
        '  Slash Commands',
        '  ' .. string.rep('─', 38),
      }
      for _, c in ipairs(CMDS) do
        if not c.alias then
          table.insert(lines, string.format('  /%-16s  %s', c.name, c.desc or ''))
        end
      end
      table.insert(lines, '')
      table.insert(lines, '  Keys')
      table.insert(lines, '  ' .. string.rep('─', 38))
      table.insert(lines, '  <CR>        send message')
      table.insert(lines, '  <M-CR>      insert newline')
      table.insert(lines, '  <Up>/<Down> prompt history (insert)')
      table.insert(lines, '  <C-k>       open command picker')
      table.insert(lines, '  @           attach file (fuzzy, insert)')
      table.insert(lines, '  <Tab>       cycle panes: input → chat')
      table.insert(lines, '  <Esc>       return to editor')
      table.insert(lines, '  <leader>ae  inline AI edit')
      table.insert(lines, '  <leader>ay  copy last response')
      table.insert(lines, '')
      table.insert(lines, '  Chat Keys')
      table.insert(lines, '  ' .. string.rep('─', 38))
      table.insert(lines, '  ]]          next message')
      table.insert(lines, '  [[          prev message')
      table.insert(lines, '  y           copy last response')
      table.insert(lines, '  d           message actions (revert/copy)')
      table.insert(lines, '  j/k         scroll (unpins auto-scroll)')
      table.insert(lines, '  G           scroll to bottom (re-pin)')
      table.insert(lines, '')
      table.insert(lines, '  Topbar Keys')
      table.insert(lines, '  ' .. string.rep('─', 38))
      table.insert(lines, '  m           model picker')
      table.insert(lines, '  p           provider picker')
      table.insert(lines, '  k           command picker')
      table.insert(lines, '  +           new session')
      table.insert(lines, '')
      table.insert(lines, '  Picker Keys')
      table.insert(lines, '  ' .. string.rep('─', 38))
      table.insert(lines, '  PgUp/PgDn   page navigation')
      table.insert(lines, '  Home/End    first/last item')
      table.insert(lines, '')
      table.insert(lines, '  Tool Use')
      table.insert(lines, '  ' .. string.rep('─', 38))
      table.insert(lines, '  /trust              toggle auto-approve for all tools')
      table.insert(lines, '  /tools [status|...]  auto|native|react|off')
      table.insert(lines, '  /debug [on|off]      log API requests to file')
      table.insert(lines, '  y/n/a                allow/deny/always (on permission)')
      table.insert(lines, '  Tools: read, write, edit, bash, glob, grep')
      table.insert(lines, '')
      table.insert(lines, '  Editor Context')
      table.insert(lines, '  ' .. string.rep('─', 38))
      table.insert(lines, '  Every message auto-includes the active buffer,')
      table.insert(lines, '  cursor line, open buffers, and any visual selection')
      table.insert(lines, '  captured when you opened the sidebar.')
      table.insert(lines, '')
      table.insert(lines, '  @current      active buffer path')
      table.insert(lines, '  @selection    your last visual selection')
      table.insert(lines, '  @buffers      all open buffer paths')
      table.insert(lines, '  @project      short tree of cwd')
      table.insert(lines, '  @cursor       file:line at cursor')
      table.insert(lines, '')
      table.insert(lines, '  Project Instructions')
      table.insert(lines, '  ' .. string.rep('─', 38))
      table.insert(lines, '  Place a PANDAVIM.md, AGENTS.md, or CLAUDE.md file')
      table.insert(lines, '  in your project root — it will be included in the')
      table.insert(lines, '  system prompt automatically.')
      M.append_system(table.concat(lines, '\n'))
  end },
  { name = '?', alias = 'help' },
}

-- ── Dispatcher ────────────────────────────────────────────────────────────
process_slash_command = function(cmd_str)
  local parts = vim.split(vim.trim(cmd_str:sub(2)), '%s+', { trimempty = true })
  local name  = parts[1] or ''
  local arg   = table.concat(parts, ' ', 2)

  -- Resolve aliases
  local entry
  for _, c in ipairs(CMDS) do
    if c.name == name then entry = c; break end
  end
  if entry and entry.alias then
    for _, c in ipairs(CMDS) do
      if c.name == entry.alias then entry = c; break end
    end
  end

  if entry and entry.fn then
    entry.fn(arg)
  else
    M.append_system('Unknown command: /' .. name .. '  —  try /help')
  end
end


-- ── Submit ────────────────────────────────────────────────────────────────
-- Returns true if a picker was opened (caller should NOT re-enter insert mode)
local function submit()
  local text = get_input_text()
  if text == '' then return false end

  -- Save to prompt history (deduplicate consecutive)
  if #S.input_history == 0 or S.input_history[#S.input_history] ~= text then
    table.insert(S.input_history, text)
  end
  S.history_idx   = 0
  S.history_draft = ''

  -- Re-engage sticky-scroll on every new turn. Without this, if the user
  -- ever pressed j/k/<C-u>/<C-d>/gg/[[/]] in the chat (even in a prior
  -- session), `scroll_pinned` stayed false and every subsequent AI stream
  -- silently failed to auto-scroll — the new content was just appended
  -- below the visible window and the user had to press G to find it.
  -- Pressing Enter is unambiguous intent: "I want to see what comes next."
  S.scroll_pinned = true

  -- slash command
  if text:sub(1,1) == '/' then
    clear_input()
    local ok, err = pcall(process_slash_command, text)
    if not ok then
      vim.notify('submit() ERROR: ' .. tostring(err), vim.log.levels.ERROR)
    end
    -- Picker commands (model/agent/provider/sessions) open their own float and call
    -- refocus_input() themselves when done. Instant commands (/new, /help, etc.) need
    -- focus returned now. We schedule with a short defer so pickers that open
    -- synchronously have already set the current win before we check.
    vim.schedule(function()
      if not S.is_open then return end
      -- Only reclaim focus if we're still inside a sidebar window
      -- (picker floats have relative='editor' so they won't be a sidebar win)
      local cw = vim.api.nvim_get_current_win()
      if is_sidebar_win(cw) and win_ok(S.input_win) then
        vim.api.nvim_set_current_win(S.input_win)
        vim.cmd('startinsert')
      end
    end)
    return true
  end

  clear_input()
  push_undo()

  -- Capture editor state + expand @tokens before building API content
  local editor_m = require('ai.editor')
  local ed_state = editor_m.capture({ origin_buf = S.origin_buf })
  S.editor_state = ed_state  -- keep latest for footer / scope checks
  local expanded_text, attach_files = editor_m.expand_tokens(text, ed_state)

  -- Build the unified list of attachments for THIS turn's bubble:
  --   1. Files the user picked via the @ picker (S.pending_attachments)
  --   2. Files auto-resolved from @current/@buffer/@cursor expansions
  -- Deduped in insertion order so the user sees the picked ones first.
  local turn_attachments = {}
  local seen = {}
  for _, p in ipairs(S.pending_attachments or {}) do
    if not seen[p] then
      table.insert(turn_attachments, p); seen[p] = true
    end
  end
  if attach_files and #attach_files > 0 then
    for _, f in ipairs(attach_files) do
      pcall(context.add_file, f)
      if not seen[f] then
        table.insert(turn_attachments, f); seen[f] = true
      end
    end
  end
  -- Reset staging for the next turn.
  S.pending_attachments = {}
  -- Clear the rejection stop-flag: a new user message means the user has
  -- (implicitly) given a fresh instruction. Any prior rejection is history.
  S.turn_had_rejection  = false

  local ed_block = editor_m.format_block(ed_state)
  local api_text = ed_block ~= ''
    and (ed_block .. '\n\n' .. expanded_text)
    or  expanded_text

  table.insert(S.messages, {
    role        = 'user',
    content     = expanded_text,  -- shown in the chat buffer (with tokens expanded)
    api_content = api_text,       -- sent to the API (with <editor_state> prepended)
    attachments = turn_attachments, -- paths rendered as chips inside the bubble
  })
  append_message('user', expanded_text, turn_attachments)

  -- Capture per-turn metadata for the response footer
  S.turn_start_time = os.time()
  S.turn_model      = config.get_model()
  S.turn_agent      = agents.active_name()
  -- Change 3: reset per-turn inline-apply stats so the summary card starts fresh
  M._reset_turn_stats()

  local wire_format = config.get_wire_format()
  local provider_id = config.get_provider()
  local model_id    = config.get_model()

  -- Resolve config.tool_mode → user intent, then compute effective mode from
  -- the tool_support registry + any auto-detection already in place.
  local cfg_mode = config.get_tool_mode() or 'auto'
  tool_support.force(cfg_mode == 'auto' and nil or cfg_mode)
  local tool_mode   = tool_support.effective_mode(provider_id, model_id)
  local use_tools   = tool_mode ~= 'off'

  -- Build system prompt (model-routed) with agent override + env + project
  -- instructions + ReAct instructions when in react mode.
  local sys_prompt = system_m.build({
    model_id     = model_id,
    agent_system = agents.active_system_prompt(),
    tool_mode    = tool_mode,
  })

  local msgs = context.build_messages(S.messages, sys_prompt)
  local tools_api = use_tools and tools_m.get_api_tools(wire_format) or nil

  S.is_streaming = true
  S.stream_text  = ''
  S.stream_line  = stream_begin()
  start_spinner()

  -- Track malformed-tool-call retries per turn (Phase 6).
  local MAX_RETRIES = 3
  local retries = 0
  -- Running copy of messages we'll send; we extend it on retry.
  local turn_msgs = vim.deepcopy(msgs)

  local function send_turn()
    S.stream_job = client.chat_completion(
      turn_msgs,
      {
        model                    = model_id,
        tools                    = tools_api,
        tool_mode                = tool_mode,
        provider                 = provider_id,
        on_thinking              = function(text)
          -- Change 4: render thinking as a collapsed card with a token-count
          -- header. <S-Tab> on the card expands to show full reasoning.
          if not text or text == '' then return end
          vim.schedule(function()
            local tid = 'think-' .. tostring(S.turn_start_time or os.time())
            local lines = vim.split(text, '\n', { plain = true })
            -- Rough token estimate: chars / 4 (good enough for display).
            local approx_tokens = math.max(1, math.floor(#text / 4))
            ToolCard.render(tid, {
              tool_name  = '🤔 Thinking · ' .. approx_tokens .. ' tokens',
              args       = {},
              state      = 'thinking',
              body_lines = lines,
              body_hl    = 'AiToolBody',
              footer     = '<S-Tab> to expand · ' .. #lines .. ' lines',
              -- expanded defaults to false in ToolCard, so this stays collapsed.
            })
          end)
        end,
        on_malformed_tool_calls  = function(errs, raw_text)
          vim.schedule(function()
            retries = retries + 1
            if retries > MAX_RETRIES then
              -- Give up and surface the error clearly
              stop_spinner()
              state_set('failed')
              M.append_error(string.format(
                'Model produced %d malformed tool call(s) across %d retries — aborted.',
                #errs, MAX_RETRIES))
              S.is_streaming = false
              S.stream_job   = nil
              render_topbar(); render_input_bar()
              return
            end
            -- Hide the stream placeholder (it only has partial XML we stripped)
            if S.stream_line and S.chat_buf and vim.api.nvim_buf_is_valid(S.chat_buf) then
              pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
              local lc = vim.api.nvim_buf_line_count(S.chat_buf)
              if lc > S.stream_line then
                pcall(vim.api.nvim_buf_set_lines, S.chat_buf, S.stream_line, lc, false, {})
              end
              pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
            end
            S.stream_line = nil
            S.stream_text = ''
            -- Feed the malformed output back as an assistant turn followed by
            -- a corrective user turn. The model sees its own bad output + the
            -- correction request.
            local react = require('ai.react')
            table.insert(turn_msgs, { role = 'assistant', content = raw_text })
            table.insert(turn_msgs, { role = 'user',
              content = react.format_parse_error_for_retry(errs, raw_text) })
            -- Show a subtle note to the user (not an error toast — this is
            -- recoverable and will happen silently most of the time).
            toast('Retrying tool call (' .. retries .. '/' .. MAX_RETRIES .. ')', 'info')
            -- Relaunch
            S.stream_line = stream_begin()
            send_turn()
          end)
        end,
      },
      -- on_chunk (text delta)
      function(chunk) vim.schedule(function() stream_chunk(chunk) end) end,
      -- on_complete (text-only response — no tool calls)
      function() vim.schedule(function() stream_end() end) end,
      -- on_error
      function(err)
        vim.schedule(function()
          S.is_streaming = false
          S.stream_job   = nil
          stop_spinner()
          state_set('failed')
          M.append_error(tostring(err))
          render_topbar()
          render_input_bar()
        end)
      end,
      -- on_usage
      function(usage)
        vim.schedule(function()
          S.token_last = usage
          if usage then S.token_total = S.token_total + (usage.total_tokens or 0) end
          render_topbar()
          render_footer()
        end)
      end,
      -- on_tool_calls (model wants to use tools — enter agentic loop)
      function(tool_calls) vim.schedule(function()
        -- Finalize any streamed text before tool execution
        if S.stream_text ~= '' then
          table.insert(S.messages, { role = 'assistant', content = S.stream_text })
          local md_start = S.stream_line
          S.stream_line = nil
          render_markdown_highlights(md_start, S.stream_text)
          S.stream_text = ''
        else
          -- No text, just tool calls — remove the empty stream placeholder
          if S.stream_line and S.chat_buf and vim.api.nvim_buf_is_valid(S.chat_buf) then
            pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', true)
            local lc = vim.api.nvim_buf_line_count(S.chat_buf)
            if lc > S.stream_line then
              pcall(vim.api.nvim_buf_set_lines, S.chat_buf, S.stream_line, lc, false, {})
            end
            pcall(vim.api.nvim_buf_set_option, S.chat_buf, 'modifiable', false)
          end
          S.stream_line = nil
        end

        local all_msgs = context.build_messages(S.messages, sys_prompt)
        run_tool_loop(tool_calls, all_msgs,
          function()
            S.is_streaming = false
            stop_spinner()
            session_save()
            render_topbar()
            render_input_bar()
            render_footer()
          end,
          function()
            S.is_streaming = false
            stop_spinner()
            render_topbar()
            render_input_bar()
          end
        )
      end) end
    )
  end

  send_turn()
  return false
end

-- ── Input keymaps ─────────────────────────────────────────────────────────
local function setup_input_keymaps(slash, at)
  local buf  = S.input_buf
  local bopt = { buffer = buf, noremap = true, silent = true }
  local e    = function(t) return vim.tbl_extend('force', bopt, t) end

  -- Unified <CR> handler: check slash/at float first, then submit
  local function cr_handler()
    if slash and slash.visible() then
      slash.select()
      return
    end
    if at and at.visible() then
      at.select()
      return
    end
    local text = get_input_text()
    -- Slash commands need normal mode for pickers
    if text:sub(1, 1) == '/' then
      vim.cmd('stopinsert')
    end
    submit()
    -- Stay in insert mode for regular messages (user can keep typing)
    if text:sub(1, 1) ~= '/' then
      vim.schedule(function()
        if win_ok(S.input_win) then
          vim.api.nvim_set_current_win(S.input_win)
          vim.cmd('startinsert')
        end
      end)
    end
  end

  -- Register <CR> manually via nvim_create_autocmd to ensure it wins over cmp
  local cr_augroup = vim.api.nvim_create_augroup('AiInputCR', { clear = true })
  vim.api.nvim_create_autocmd('InsertEnter', {
    group = cr_augroup,
    buffer = buf,
    callback = function()
      vim.schedule(function()
        vim.keymap.set('i', '<CR>', cr_handler, { buffer = buf, noremap = true, silent = true })
      end)
    end,
  })
  -- Initial registration
  vim.keymap.set('i', '<CR>', cr_handler, e{ desc = 'AI: send' })

  -- Alt-Enter or Shift-Enter inserts newline (for multi-line messages)
  vim.keymap.set('i', '<M-CR>', function()
    vim.api.nvim_feedkeys('\n', 'n', false)
  end, e{ desc = 'AI: newline' })
  vim.keymap.set('i', '<S-CR>', function()
    vim.api.nvim_feedkeys('\n', 'n', false)
  end, e{ desc = 'AI: newline' })

  -- Cancel streaming with C-c
  vim.keymap.set('i', '<C-c>', function()
    if S.is_streaming then
      M.cancel_stream()
    else
      vim.cmd('stopinsert')
    end
  end, e{ desc = 'AI: cancel' })

  -- C-k: global command picker (like OpenCode's command_list)
  vim.keymap.set('i', '<C-k>', function()
    vim.cmd('stopinsert')
    open_command_picker()
  end, e{ desc = 'AI: commands' })

  -- Cycle to chat — but ONLY when no floating picker is consuming Tab.
  -- Without this guard, the slash and @ float Tab handlers (which select the
  -- highlighted item) never fire because this binding overwrites them.
  vim.keymap.set({'i','n'}, '<Tab>', function()
    if slash and slash.visible() then slash.select(); return end
    if at    and at.visible()    then at.select();    return end
    vim.cmd('stopinsert')
    if win_ok(S.chat_win) then vim.api.nvim_set_current_win(S.chat_win) end
  end, e{ desc = 'AI: focus chat' })

  -- <Esc> behavior — split per mode so users can reach normal mode of the
  -- input buffer (and use their global <leader> keymaps from there) without
  -- having focus yanked to the editor.
  --   Insert mode → just stopinsert (default vim). InsertLeave autocmds
  --                  fire, closing any open slash/at float as a side effect.
  --   Normal mode → focus the editor (the previous "single Esc to leave"
  --                  behavior, now requires two presses from insert mode).
  -- This restores compatibility with global <leader>X normal-mode keymaps.
  vim.keymap.set('i', '<Esc>', function()
    vim.cmd('stopinsert')
  end, e{ desc = 'AI: to normal mode' })
  vim.keymap.set('n', '<Esc>', function()
    M.focus_editor()
  end, e{ desc = 'AI: focus editor' })

  -- ── Prompt history helpers (used by insert <Up>/<Down> when no float
  -- is open AND by normal-mode j/k) ────────────────────────────────────────
  local function history_back()
    if #S.input_history == 0 then return end
    if S.history_idx == 0 then
      S.history_draft = get_input_text()
      S.history_idx   = #S.input_history
    elseif S.history_idx > 1 then
      S.history_idx = S.history_idx - 1
    else
      return
    end
    local lines = vim.split(S.input_history[S.history_idx], '\n', { plain = true })
    pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    pcall(vim.api.nvim_win_set_cursor, S.input_win, { 1, #lines[1] })
  end
  local function history_forward()
    if S.history_idx == 0 then return end
    if S.history_idx >= #S.input_history then
      -- Restore the draft the user was typing before they entered history mode.
      S.history_idx = 0
      local lines = vim.split(S.history_draft or '', '\n', { plain = true })
      pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      pcall(vim.api.nvim_win_set_cursor, S.input_win,
        { #lines, lines[#lines] and #lines[#lines] or 0 })
    else
      S.history_idx = S.history_idx + 1
      local lines = vim.split(S.input_history[S.history_idx], '\n', { plain = true })
      pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', true)
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      pcall(vim.api.nvim_win_set_cursor, S.input_win, { 1, #lines[1] })
    end
  end

  -- ── Unified picker-nav dispatch ─────────────────────────────────────────
  -- Routes <Up>, <Down>, <C-n>, <C-p>, <C-j>, <C-k>, <S-Tab>,
  -- <ScrollWheel{Up,Down}> through a single decision tree:
  --   1. slash float visible → slash.up()/down()
  --   2. @-float visible      → at.up()/down()
  --   3. arrows               → prompt history navigation
  --   4. ctrl/wheel keys      → no-op (no semantic outside a picker)
  --
  -- This consolidation fixes a silent collision where setup_at_complete
  -- registered <Up>/<Down> after setup_slash_complete and overrode the
  -- slash-float arrows AND the prompt-history fallback.
  local function nav_up_dispatch()
    if slash and slash.visible() then slash.up(); return end
    if at    and at.visible()    then at.up();    return end
    history_back()
  end
  local function nav_down_dispatch()
    if slash and slash.visible() then slash.down(); return end
    if at    and at.visible()    then at.down();    return end
    history_forward()
  end
  local function nav_picker_only_up()
    if slash and slash.visible() then slash.up(); return end
    if at    and at.visible()    then at.up();    return end
    -- No fallback: <C-p>, <C-k>, <S-Tab>, ScrollWheelUp don't carry a
    -- meaningful action when no picker is up.
  end
  local function nav_picker_only_down()
    if slash and slash.visible() then slash.down(); return end
    if at    and at.visible()    then at.down();    return end
  end
  local function wheel_up_dispatch()
    if slash and slash.visible() then for _ = 1, 3 do slash.up() end; return end
    if at    and at.visible()    then for _ = 1, 3 do at.up()    end; return end
  end
  local function wheel_down_dispatch()
    if slash and slash.visible() then for _ = 1, 3 do slash.down() end; return end
    if at    and at.visible()    then for _ = 1, 3 do at.down()    end; return end
  end

  local nav_opts = vim.tbl_extend('force', bopt, { nowait = true })
  vim.keymap.set('i', '<Up>',             nav_up_dispatch,      nav_opts)
  vim.keymap.set('i', '<Down>',           nav_down_dispatch,    nav_opts)
  vim.keymap.set('i', '<C-p>',            nav_picker_only_up,   nav_opts)
  vim.keymap.set('i', '<C-n>',            nav_picker_only_down, nav_opts)
  vim.keymap.set('i', '<C-k>',            nav_picker_only_up,   nav_opts)
  vim.keymap.set('i', '<C-j>',            nav_picker_only_down, nav_opts)
  vim.keymap.set('i', '<S-Tab>',          nav_picker_only_up,   nav_opts)
  vim.keymap.set('i', '<ScrollWheelUp>',   wheel_up_dispatch,   nav_opts)
  vim.keymap.set('i', '<ScrollWheelDown>', wheel_down_dispatch, nav_opts)

  -- Normal-mode k/j browse the same history (unchanged behavior).
  vim.keymap.set('n', 'k', history_back,    e{ desc = 'AI: prev prompt' })
  vim.keymap.set('n', 'j', history_forward, e{ desc = 'AI: next prompt' })

  vim.api.nvim_buf_set_option(buf, 'omnifunc', '')

  -- Disable nvim-cmp in the AI input buffer entirely
  local ok_cmp, cmp = pcall(require, 'cmp')
  if ok_cmp then cmp.setup.buffer({ enabled = false }) end
end

function M.complete_slash(findstart, base)
  if findstart == 1 then
    local line = vim.api.nvim_get_current_line():sub(1, vim.fn.col('.') - 1)
    local slash_pos = line:find('/%S*$')
    if slash_pos then return slash_pos end
    return -3
  end
  local result = {}
  for _, c in ipairs(cmd_names()) do
    if c:sub(1, #base) == base then table.insert(result, c) end
  end
  return result
end

-- ── Slash command autocomplete float ────────────────────────────────────────
-- Shows above the input when user types /. Like OpenCode's autocomplete:
--   • Fuzzy search over name, description, aliases
--   • Suggested commands sorted to top (when no query)
--   • Keybind hints shown right-aligned and dimmed
--   • Up/Down or C-p/C-n navigate; Tab/Enter confirms highlighted item
--   • Selecting calls process_slash_command directly (no submit() race)
local function setup_slash_complete()
  local buf = S.input_buf

  local float = {
    win        = nil,
    buf        = nil,
    visible    = false,
    selection  = 1,
    scroll_top = 1,        -- first visible item (1-indexed)
    items      = {},       -- list of cmd_entry objects { name, desc, key, suggested, aliases }
  }
  local float_ns = vim.api.nvim_create_namespace('AiSlashFloat')
  local FLOAT_VIS = 12    -- max visible rows in the float
  local FLOAT_W = math.min(60, vim.o.columns - 4)

  -- fuzzy_score is now a module-level function (shared with @ file complete)

  -- ── matching: fuzzy search over name + desc + aliases ─────────────────────
  -- Returns sorted list of cmd_entry objects.
  local function matching(query)
    local entries = cmd_entries()
    if query == '' then
      -- No query: show suggested first, then the rest alphabetically
      local suggested, rest = {}, {}
      for _, e in ipairs(entries) do
        if e.suggested then
          table.insert(suggested, e)
        else
          table.insert(rest, e)
        end
      end
      local out = {}
      for _, e in ipairs(suggested) do table.insert(out, e) end
      for _, e in ipairs(rest)      do table.insert(out, e) end
      return out
    end

    -- Fuzzy match against name, desc, and all aliases
    local scored = {}
    for _, e in ipairs(entries) do
      local best = fuzzy_score(query, e.name)
      local ds   = fuzzy_score(query, e.desc)
      if ds and (not best or ds > best) then best = ds end
      for _, a in ipairs(e.aliases) do
        local as = fuzzy_score(query, a)
        if as and (not best or as > best) then best = as end
      end
      if best then
        table.insert(scored, { entry = e, score = best })
      end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    local out = {}
    for _, s in ipairs(scored) do table.insert(out, s.entry) end
    return out
  end

  -- ── scroll helpers ────────────────────────────────────────────────────────
  local function adjust_scroll()
    if float.selection < float.scroll_top then
      float.scroll_top = float.selection
    elseif float.selection > float.scroll_top + FLOAT_VIS - 1 then
      float.scroll_top = float.selection - FLOAT_VIS + 1
    end
    if float.scroll_top < 1 then float.scroll_top = 1 end
  end

  -- ── render (OpenCode-style: /name + desc, no keybind hints) ────────────────
  -- Find max command name width for column alignment (like OpenCode's padEnd)
  local max_name_w = 0
  for _, e in ipairs(cmd_entries()) do
    max_name_w = math.max(max_name_w, #e.name + 1)  -- +1 for leading /
  end

  local function render_float()
    if not float.visible or not float.buf then return end
    local items       = float.items
    local visible_end = math.min(#items, float.scroll_top + FLOAT_VIS - 1)

    pcall(vim.api.nvim_buf_set_option, float.buf, 'modifiable', true)

    local lines   = {}
    local extdata = {}

    for i = float.scroll_top, visible_end do
      local e    = items[i]
      local name = '/' .. e.name
      local desc = e.desc or ''

      -- Pad name to fixed width for column alignment (OpenCode's padEnd trick)
      local padded_name = ' ' .. name .. string.rep(' ', math.max(2, max_name_w + 3 - #name))
      local line = padded_name .. desc

      -- Pad to FLOAT_W
      if #line < FLOAT_W then line = line .. string.rep(' ', FLOAT_W - #line) end

      table.insert(lines, line)

      local desc_start = desc ~= '' and #padded_name or nil
      local desc_end   = desc_start and (#padded_name + #desc) or nil
      table.insert(extdata, { name_end = #padded_name, desc_start = desc_start, desc_end = desc_end })
    end

    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
    pcall(vim.api.nvim_buf_set_option, float.buf, 'modifiable', false)

    vim.api.nvim_buf_clear_namespace(float.buf, float_ns, 0, -1)
    for idx, ed in ipairs(extdata) do
      local buf_row = idx - 1
      local ii = float.scroll_top + idx - 1
      local is_sel = (ii == float.selection)

      local row_hl = is_sel and 'AiPickerSel' or 'AiPickerItem'
      pcall(vim.api.nvim_buf_add_highlight, float.buf, float_ns, row_hl, buf_row, 0, -1)

      if not is_sel and ed.desc_start then
        pcall(vim.api.nvim_buf_add_highlight, float.buf, float_ns, 'AiSlashDesc', buf_row, ed.desc_start, ed.desc_end)
      end
    end
  end

  local function close_float()
    if float.win and vim.api.nvim_win_is_valid(float.win) then
      pcall(vim.api.nvim_win_close, float.win, true)
    end
    float.visible    = false
    float.selection  = 1
    float.scroll_top = 1
    float.items      = {}
    float.win        = nil
    float.buf        = nil
  end

  local function open_float(items)
    if float.visible then return end
    if #items == 0 then return end
    float.items      = items
    float.selection  = 1
    float.scroll_top = 1

    local height = math.min(#items, FLOAT_VIS)
    float.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(float.buf, 'buftype',   'nofile')
    vim.api.nvim_buf_set_option(float.buf, 'bufhidden', 'wipe')
    vim.api.nvim_buf_set_option(float.buf, 'modifiable', false)

    float.win = vim.api.nvim_open_win(float.buf, false, {
      relative = 'win',
      win      = S.input_win,
      row      = -height,
      col      = 0,
      width    = FLOAT_W,
      height   = height,
      style    = 'minimal',
      border   = { '', '', '', '│', '', '', '', '│' },
      zindex   = 60,
    })
    vim.api.nvim_win_set_option(float.win, 'winhighlight',
      'Normal:AiPickerBg,NormalFloat:AiPickerBg,FloatBorder:AiTopSep')

    float.visible = true
    render_float()
  end

  local function update_float(items)
    if not float.visible then return end
    if #items == 0 then close_float(); return end
    float.items     = items
    float.selection = math.min(float.selection, #items)
    adjust_scroll()
    local height = math.min(#items, FLOAT_VIS)
    pcall(vim.api.nvim_win_set_config, float.win, {
      relative = 'win', win = S.input_win,
      row = -height, col = 0,
      width = FLOAT_W, height = height,
    })
    render_float()
  end

  -- ── select: confirm highlighted item, fire command directly ───────────────
  local function select_item()
    if not float.visible or #float.items == 0 then return end
    local entry = float.items[float.selection]
    close_float()
    clear_input()
    vim.schedule(function()
      local ok, err = pcall(process_slash_command, '/' .. entry.name)
      if not ok then
        vim.notify('slash cmd error: ' .. tostring(err), vim.log.levels.ERROR)
      end
    end)
  end

  local function up()
    if not float.visible or #float.items == 0 then return end
    if float.selection <= 1 then
      float.selection  = #float.items
      float.scroll_top = math.max(1, #float.items - FLOAT_VIS + 1)
    else
      float.selection = float.selection - 1
      adjust_scroll()
    end
    render_float()
  end

  local function down()
    if not float.visible or #float.items == 0 then return end
    if float.selection >= #float.items then
      float.selection  = 1
      float.scroll_top = 1
    else
      float.selection = float.selection + 1
      adjust_scroll()
    end
    render_float()
  end

  -- ── autocmds ──────────────────────────────────────────────────────────────
  local augroup = vim.api.nvim_create_augroup('AiSlashComplete', { clear = true })

  vim.api.nvim_create_autocmd('TextChangedI', {
    group  = augroup,
    buffer = buf,
    callback = function()
      local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
      if not line:match('^/') then close_float(); return end
      local query = line:match('^/(%S*)$') or ''
      local items = matching(query)
      if float.visible then
        update_float(items)
      else
        open_float(items)
      end
    end,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    group  = augroup,
    buffer = buf,
    callback = function() close_float() end,
  })

  vim.api.nvim_create_autocmd('BufLeave', {
    group  = augroup,
    buffer = buf,
    callback = function() close_float() end,
  })

  -- ── keymaps (insert mode on the input buffer) ──────────────────────────────
  -- IMPORTANT: this float used to register its own <Up>/<Down>/<S-Tab>/
  -- <C-n>/<C-p>/<C-j>/<C-k>/<ScrollWheel{Up,Down}> bindings here, but those
  -- collided with the @-float's identically-named bindings (whichever
  -- setup_*_complete ran SECOND silently won, breaking nav for the first).
  -- All shared nav keys are now dispatched from setup_input_keymaps via the
  -- exposed `up` / `down` functions on the returned table. We only keep the
  -- bindings that have NO equivalent in the @-float. Today that's nothing —
  -- everything moved out. Left as a single explanatory comment so future
  -- contributors don't re-add a binding here without considering the conflict.
  local bopt = { buffer = buf, noremap = true, silent = true, nowait = true }
  local _ = bopt  -- referenced by setup_input_keymaps via the return table

  -- C-n / C-p
  vim.keymap.set('i', '<C-n>', function()
    if float.visible then down() end
  end, bopt)
  vim.keymap.set('i', '<C-p>', function()
    if float.visible then up() end
  end, bopt)

  -- Esc: close float
  vim.keymap.set('i', '<Esc>', function()
    if float.visible then close_float() end
  end, bopt)

  return {
    visible = function() return float.visible end,
    select  = select_item,
    close   = close_float,
    -- Exposed so setup_input_keymaps can dispatch unified <Up>/<Down>/
    -- <C-n>/<C-p>/<S-Tab>/wheel handlers without conflicting with the
    -- @-float's bindings. The setup_*_complete functions used to bind
    -- these keys themselves, but whichever was registered LAST won —
    -- silently breaking nav for the other.
    up      = up,
    down    = down,
  }
end

-- ── @ file autocomplete float ─────────────────────────────────────────────
-- Triggered inline when user types '@' — shows a file picker float above input.
-- Uses git ls-files with fallback to find.
-- On selection: removes the @<prefix> token from the input (replaces with a space)
-- so TextChangedI no longer matches '@' and the float stays closed.
-- Files are deduplicated via context.add_file (no-op if already attached).
local function setup_at_complete()
  local buf = S.input_buf
  local float = {
    win         = nil,
    buf         = nil,
    visible     = false,
    selection   = 1,
    items       = {},     -- list of full relative paths
    trigger_col = 0,      -- 0-indexed column of the '@' that triggered the float
  }
  local AT_FLOAT_W = math.min(W - 2, 52)
  local AT_MAX_H   = 10

  -- ── File list helper ──────────────────────────────────────────────────────
  local project_files_cache = nil
  local function get_project_files()
    if project_files_cache then return project_files_cache end
    local git_out = vim.fn.systemlist('git ls-files 2>/dev/null')
    if vim.v.shell_error == 0 and #git_out > 0 then
      project_files_cache = git_out
      return project_files_cache
    end
    local find_out = vim.fn.systemlist(
      "find . -type f -not -path '*/.*' 2>/dev/null | sed 's|^./||' | head -500"
    )
    project_files_cache = find_out
    return project_files_cache
  end

  -- Special tokens that expand to dynamic editor state instead of a file
  -- path. When the user picks one of these, select_item() inserts the literal
  -- token (e.g. "@current ") into the input — ai/editor.lua expands it at
  -- submit time.
  local SPECIAL_TOKENS = {
    { name = '@current',   desc = 'active buffer path' },
    { name = '@selection', desc = 'current visual selection' },
    { name = '@cursor',    desc = 'file:line at cursor' },
    { name = '@buffers',   desc = 'all open buffer paths' },
    { name = '@project',   desc = 'short project file tree' },
  }

  local function is_special(item)
    return type(item) == 'string' and item:sub(1, 1) == '@'
  end

  local function filter_files(query)
    -- Load frecency data on first use
    if not S.file_frecency then S.file_frecency = load_frecency() end
    local all = get_project_files()

    -- Match special tokens first — either no query (show all) or fuzzy-match the name
    local matched_specials = {}
    local q_lower = query:lower()
    for _, st in ipairs(SPECIAL_TOKENS) do
      if query == '' or st.name:lower():find(q_lower, 1, true)
          or fuzzy_score(query, st.name) then
        table.insert(matched_specials, st.name)
      end
    end

    if query == '' then
      -- No query: specials first, then files sorted by frecency
      local scored = {}
      for _, f in ipairs(all) do
        local frec = S.file_frecency[f]
        local sc = frec and (frec.count * 10 + math.max(0, 100 - (os.time() - frec.last) / 3600))
          or 0
        table.insert(scored, { file = f, score = sc })
      end
      table.sort(scored, function(a, b)
        if a.score ~= b.score then return a.score > b.score end
        return a.file < b.file
      end)
      local result = {}
      for _, tok in ipairs(matched_specials) do table.insert(result, tok) end
      for i, s in ipairs(scored) do
        if #result >= 25 then break end
        table.insert(result, s.file)
      end
      return result
    end

    -- Fuzzy match with frecency boost, specials mixed in
    local scored = {}
    for _, f in ipairs(all) do
      local sc = fuzzy_score(query, f)
      if sc then
        local frec = S.file_frecency[f]
        if frec then sc = sc + math.min(frec.count, 10) * 2 end
        table.insert(scored, { file = f, score = sc })
      end
    end
    table.sort(scored, function(a, b) return a.score > b.score end)
    local result = {}
    for _, tok in ipairs(matched_specials) do table.insert(result, tok) end
    for i, s in ipairs(scored) do
      if #result >= 25 then break end
      table.insert(result, s.file)
    end
    return result
  end

  -- ── Display helpers ───────────────────────────────────────────────────────
  -- Split a path into (directory_with_slash, filename).
  -- e.g. "src/components/input.lua" → ("src/components/", "input.lua")
  -- e.g. "README.md"                → ("", "README.md")
  local function split_path(path)
    local dir  = vim.fn.fnamemodify(path, ':h')
    local file = vim.fn.fnamemodify(path, ':t')
    if dir == '.' or dir == '' then
      return '', file
    end
    return dir .. '/', file
  end

  -- Lookup: special token name → description (for render)
  local SPECIAL_DESC = {}
  for _, st in ipairs(SPECIAL_TOKENS) do SPECIAL_DESC[st.name] = st.desc end

  -- Render the float: file items as "dir/file", special tokens as "@name  — desc"
  local function render_float_buf()
    if not float.buf or not vim.api.nvim_buf_is_valid(float.buf) then return end
    local items = float.items
    local lines = {}
    for _, item in ipairs(items) do
      if is_special(item) then
        local desc = SPECIAL_DESC[item] or ''
        local pad  = math.max(1, 12 - #item)  -- align descriptions
        table.insert(lines, ' ' .. item .. string.rep(' ', pad) .. desc)
      else
        local dir, file = split_path(item)
        table.insert(lines, ' ' .. dir .. file)
      end
    end
    pcall(vim.api.nvim_buf_set_option, float.buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(float.buf, 0, -1, false, lines)
    pcall(vim.api.nvim_buf_set_option, float.buf, 'modifiable', false)

    if NS_AT then
      vim.api.nvim_buf_clear_namespace(float.buf, NS_AT, 0, -1)
      for i, item in ipairs(items) do
        local row = i - 1
        if i == float.selection then
          pcall(vim.api.nvim_buf_add_highlight, float.buf, NS_AT, 'AiPickerSel', row, 0, -1)
        elseif is_special(item) then
          -- Bright for "@name", dim for description
          local name_end = 1 + #item
          pcall(vim.api.nvim_buf_add_highlight, float.buf, NS_AT, 'AiAtFile', row, 1, name_end)
          pcall(vim.api.nvim_buf_add_highlight, float.buf, NS_AT, 'AiAtDir',  row, name_end, -1)
        else
          local dir, file = split_path(item)
          local dir_start  = 1
          local dir_end    = 1 + #dir
          local file_start = dir_end
          local file_end   = file_start + #file
          if #dir > 0 then
            pcall(vim.api.nvim_buf_add_highlight, float.buf, NS_AT, 'AiAtDir', row, dir_start, dir_end)
          end
          pcall(vim.api.nvim_buf_add_highlight, float.buf, NS_AT, 'AiAtFile', row, file_start, file_end)
        end
      end
    end
  end

  local function close_float()
    if float.visible and float.win and vim.api.nvim_win_is_valid(float.win) then
      pcall(vim.api.nvim_win_close, float.win, true)
    end
    float.visible     = false
    float.selection   = 1
    float.items       = {}
    float.trigger_col = 0
    float.win         = nil
    float.buf         = nil
  end

  local function open_float(items, height)
    if float.visible then return end
    float.items     = items
    float.selection = 1

    float.buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_option(float.buf, 'buftype',    'nofile')
    vim.api.nvim_buf_set_option(float.buf, 'bufhidden',  'wipe')
    vim.api.nvim_buf_set_option(float.buf, 'modifiable', false)

    float.win = vim.api.nvim_open_win(float.buf, false, {
      relative = 'win',
      win      = S.input_win,
      row      = -height,
      col      = 0,
      width    = AT_FLOAT_W,
      height   = height,
      style    = 'minimal',
      border   = { '', '', '', '│', '', '', '', '│' },
      zindex   = 56,
      noautocmd = true,
    })
    vim.api.nvim_win_set_option(float.win, 'winhighlight',
      'Normal:AiPickerBg,NormalFloat:AiPickerBg,FloatBorder:AiTopSep')

    float.visible = true
    render_float_buf()
  end

  local function update_float(items, height)
    if not float.visible then return end
    if #items == 0 then close_float(); return end
    float.items     = items
    float.selection = math.min(float.selection, #items)
    pcall(vim.api.nvim_win_set_config, float.win, {
      relative = 'win', win = S.input_win,
      row = -height, col = 0,
      width = AT_FLOAT_W, height = height,
    })
    render_float_buf()
  end

  -- ── select_item ───────────────────────────────────────────────────────────
  -- For files: inserts @filename at the cursor and attaches to context.
  -- For special tokens (@current, @selection, ...): inserts the literal token —
  -- ai/editor.lua expands it at submit time, no file attachment needed.
  local function select_item()
    if not float.visible then return end
    if float.selection < 1 or float.selection > #float.items then return end
    local selected = float.items[float.selection]
    local tc = float.trigger_col  -- 0-indexed column of '@'
    close_float()

    local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
    local before = line:sub(1, tc)  -- everything BEFORE the '@'
    local after  = line:match('@%S*(.*)', tc + 1) or ''

    local insert
    if is_special(selected) then
      -- Insert the literal special token (e.g. "@current ")
      insert = selected .. ' '
    else
      -- File path: insert @filename (short form) and auto-attach
      local display_name = selected:match('[^/]+$') or selected
      insert = '@' .. display_name .. ' '
    end

    local new_line = before .. insert .. vim.trim(after)
    pcall(vim.api.nvim_buf_set_option, buf, 'modifiable', true)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { new_line })
    pcall(vim.api.nvim_win_set_cursor, S.input_win, { 1, #before + #insert })

    -- Attach file to context only for real files. The chip visual lives
    -- inside the user bubble at submit time (see append_user), NOT as a
    -- separate system message — so we stage the path in S.pending_attachments
    -- and consume it in submit().
    if not is_special(selected) then
      local ok_ctx, ctx_m = pcall(require, 'ai.context')
      if ok_ctx then
        local ok2, err = ctx_m.add_file(selected)
        if ok2 then
          S.pending_attachments = S.pending_attachments or {}
          -- Dedup: don't double-stage if the user picks the same file twice.
          local already = false
          for _, p in ipairs(S.pending_attachments) do
            if p == selected then already = true; break end
          end
          if not already then
            table.insert(S.pending_attachments, selected)
          end
          update_frecency(selected)
        elseif err then
          -- Keep error reporting visible — attachment failures are rare and
          -- the user needs to know the file didn't land.
          append_message('system', 'Could not attach: ' .. err)
        end
      end
    end
  end

  local function up()
    if not float.visible or #float.items == 0 then return end
    if float.selection <= 1 then
      float.selection = #float.items
    else
      float.selection = float.selection - 1
    end
    render_float_buf()
  end

  local function down()
    if not float.visible or #float.items == 0 then return end
    if float.selection >= #float.items then
      float.selection = 1
    else
      float.selection = float.selection + 1
    end
    render_float_buf()
  end

  -- ── TextChangedI: scan line for '@' pattern ───────────────────────────────
  local augroup = vim.api.nvim_create_augroup('AiAtComplete', { clear = true })

  vim.api.nvim_create_autocmd('TextChangedI', {
    group  = augroup,
    buffer = buf,
    callback = function()
      local line   = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1] or ''
      -- Skip if this is a slash command (avoid expensive file scan)
      if line:match('^/') then
        if float.visible then close_float() end
        return
      end
      local cursor = vim.fn.col('.') - 1  -- 0-indexed

      -- Find the last '@' before cursor, stop at space
      local at_pos = nil
      for i = cursor, 1, -1 do
        local ch = line:sub(i, i)
        if ch == '@' then at_pos = i; break end
        if ch == ' ' then break end
      end

      if not at_pos then
        if float.visible then close_float() end
        return
      end

      local prefix = line:sub(at_pos + 1, cursor)
      local items  = filter_files(prefix)

      if #items == 0 then
        if float.visible then close_float() end
        return
      end

      local height = math.min(#items, AT_MAX_H)
      if not float.visible then
        float.trigger_col = at_pos - 1  -- 0-indexed column of '@'
        open_float(items, height)
      else
        update_float(items, height)
      end
    end,
  })

  vim.api.nvim_create_autocmd('InsertLeave', {
    group    = augroup,
    buffer   = buf,
    callback = function() close_float() end,
  })
  vim.api.nvim_create_autocmd('BufLeave', {
    group    = augroup,
    buffer   = buf,
    callback = function() close_float() end,
  })

  -- All shared nav keys (<Up>, <Down>, <C-n>, <C-p>, <C-j>, <C-k>,
  -- <Tab>, <S-Tab>, <ScrollWheel{Up,Down}>) are dispatched from
  -- setup_input_keymaps via the exposed `up` / `down` functions on the
  -- returned table — see the matching comment in setup_slash_complete for
  -- the rationale (whichever picker registered second silently overrode
  -- the other, breaking nav).

  return {
    visible = function() return float.visible end,
    select  = select_item,
    close   = close_float,
    -- See setup_slash_complete for why these are exposed; mirror pair so
    -- the unified nav dispatch in setup_input_keymaps can reach both
    -- floats from a single keymap.
    up      = up,
    down    = down,
  }
end

-- ── Chat keymaps ──────────────────────────────────────────────────────────
local function setup_chat_keymaps()
  local buf  = S.chat_buf
  local bopt = { buffer = buf, noremap = true, silent = true }
  local e    = function(t) return vim.tbl_extend('force', bopt, t) end

  vim.keymap.set('n', '<Tab>', function()
    if win_ok(S.input_win) then
      vim.api.nvim_set_current_win(S.input_win)
      vim.cmd('startinsert')
    end
  end, e{ desc = 'AI: focus input' })

  vim.keymap.set('n', '<Esc>', function() M.focus_editor() end, e{ desc = 'AI: editor' })

  vim.keymap.set('n', 'q', function() M.close() end, e{ desc = 'AI: close' })

  -- Phase 9: S-Tab toggles expand/collapse for the tool card under the cursor.
  vim.keymap.set('n', '<S-Tab>', function()
    local row = vim.api.nvim_win_get_cursor(S.chat_win)[1] - 1  -- 0-indexed
    local card_id = ToolCard.get_card_at(row)
    if not card_id then
      toast('No tool card under cursor', 'info')
      return
    end
    ToolCard.set_expanded(card_id, not ToolCard.is_expanded(card_id))
  end, e{ desc = 'AI: expand/collapse tool card' })

  -- Change A: per-message toolbar keymaps (dispatch to message under cursor).
  -- These only do anything when the cursor is on a row associated with an
  -- assistant message that has a toolbar; otherwise they fall through silently.
  local function msg_at_cursor()
    local row = vim.api.nvim_win_get_cursor(S.chat_win)[1] - 1
    return find_msg_at(row)
  end
  vim.keymap.set('n', 'y', function()
    local idx = msg_at_cursor()
    if idx then M._msg_copy(idx) else toast('No message here', 'warn') end
  end, e{ desc = 'AI: copy message at cursor' })
  vim.keymap.set('n', 'r', function()
    local idx = msg_at_cursor()
    if idx then M._msg_regenerate(idx) end
  end, e{ desc = 'AI: regenerate from cursor' })
  vim.keymap.set('n', 'u', function()
    local idx = msg_at_cursor()
    if idx then M._msg_feedback(idx, 'up') end
  end, e{ desc = 'AI: 👍 message' })
  vim.keymap.set('n', 'i', function()
    local idx = msg_at_cursor()
    if idx then M._msg_feedback(idx, 'down') end
  end, e{ desc = 'AI: 👎 message' })
  vim.keymap.set('n', 'o', function()
    local idx = msg_at_cursor()
    if idx then M._msg_open_scratch(idx) end
  end, e{ desc = 'AI: open message in scratch buffer' })

  -- scroll — j/k/gg unpin sticky-scroll; G repins and jumps to bottom
  vim.keymap.set('n', 'j', function()
    S.scroll_pinned = false
    vim.cmd('normal! j')
  end, e{})
  vim.keymap.set('n', 'k', function()
    S.scroll_pinned = false
    vim.cmd('normal! k')
  end, e{})
  vim.keymap.set('n', '<C-d>', function()
    S.scroll_pinned = false
    vim.cmd('normal! \x04')
  end, e{})
  vim.keymap.set('n', '<C-u>', function()
    S.scroll_pinned = false
    vim.cmd('normal! \x15')
  end, e{})
  vim.keymap.set('n', 'G', function()
    S.scroll_pinned = true
    scroll_bottom(S.chat_win, S.chat_buf)
  end, e{ desc = 'AI: scroll to bottom' })
  vim.keymap.set('n', 'gg', function()
    S.scroll_pinned = false
    vim.cmd('normal! gg')
  end, e{})

  -- ── [[ / ]] — jump between messages ───────────────────────────────────────
  -- Scans buffer for assistant sparkle lines ("  ✦") and user bubble starts
  -- (right-padded text after a blank line).
  local user_pad_threshold = math.floor(W / 3)

  local function find_message_starts()
    if not S.chat_buf or not vim.api.nvim_buf_is_valid(S.chat_buf) then return {} end
    local lines = vim.api.nvim_buf_get_lines(S.chat_buf, 0, -1, false)
    local starts = {}
    for i, line in ipairs(lines) do
      -- Assistant message: sparkle prefix
      if line:match('^  ✦') then
        table.insert(starts, i - 1)  -- 0-indexed
      elseif #line > 0 then
        -- User message: lots of leading whitespace after a blank or timestamp line
        local leading = #(line:match('^(%s*)') or '')
        if leading >= user_pad_threshold then
          local prev = (i > 1) and lines[i - 1] or ''
          if prev == '' or prev:match('^%s*$') then
            table.insert(starts, i - 1)
          end
        end
      end
    end
    return starts
  end

  vim.keymap.set('n', ']]', function()
    local starts = find_message_starts()
    local cur = vim.api.nvim_win_get_cursor(S.chat_win)[1] - 1
    for _, row in ipairs(starts) do
      if row > cur then
        pcall(vim.api.nvim_win_set_cursor, S.chat_win, { row + 1, 0 })
        S.scroll_pinned = false
        return
      end
    end
  end, e{ desc = 'AI: next message' })

  vim.keymap.set('n', '[[', function()
    local starts = find_message_starts()
    local cur = vim.api.nvim_win_get_cursor(S.chat_win)[1] - 1
    for i = #starts, 1, -1 do
      if starts[i] < cur then
        pcall(vim.api.nvim_win_set_cursor, S.chat_win, { starts[i] + 1, 0 })
        S.scroll_pinned = false
        return
      end
    end
  end, e{ desc = 'AI: prev message' })

  -- yank last assistant message from chat pane
  vim.keymap.set('n', 'y', function()
    local text = M.get_last_assistant_text()
    if text then
      vim.fn.setreg('+', text)
      toast('Copied response to clipboard', 'success')
    else
      toast('No assistant response to copy', 'warn')
    end
  end, e{ desc = 'AI: copy last response' })

  -- message actions dialog (OpenCode-style: revert/copy/fork)
  vim.keymap.set('n', 'd', function()
    if #S.messages == 0 then return end
    -- Find which message the cursor is on
    local cur_row = vim.api.nvim_win_get_cursor(S.chat_win)[1]
    local starts  = find_message_starts()
    local msg_idx = nil
    for si = #starts, 1, -1 do
      if starts[si] + 1 <= cur_row then
        -- count which message this is (user messages are odd indices in S.messages)
        local count = 0
        for sj = 1, si do
          local row = starts[sj]
          local line = vim.api.nvim_buf_get_lines(S.chat_buf, row, row + 1, false)[1] or ''
          if not line:match('^  ✦') then count = count + 1 end  -- user message
        end
        -- map count back to S.messages index (user messages)
        local user_count = 0
        for mi, m in ipairs(S.messages) do
          if m.role == 'user' then
            user_count = user_count + 1
            if user_count == count then msg_idx = mi; break end
          end
        end
        break
      end
    end

    local actions = {
      { label = 'Copy message',   value = 'copy' },
      { label = 'Revert to here', value = 'revert' },
    }
    open_picker({
      title  = 'Message actions',
      items  = actions,
      format = function(item) return item.label end,
      on_confirm = function(item)
        if item.value == 'copy' and msg_idx then
          vim.fn.setreg('+', S.messages[msg_idx].content)
          toast('Message copied', 'success')
        elseif item.value == 'revert' and msg_idx then
          table.insert(S.undo_stack, vim.deepcopy(S.messages))
          S.messages = { unpack(S.messages, 1, msg_idx) }
          redraw_all()
          toast('Reverted to message ' .. msg_idx, 'info')
        elseif not msg_idx then
          toast('Could not identify message', 'warn')
        end
      end,
    })
  end, e{ desc = 'AI: message actions' })
end

-- ── Window cosmetics ──────────────────────────────────────────────────────
local function apply_cosmetics(win)
  local opts = {
    number         = false, relativenumber = false,
    signcolumn     = 'no',  foldcolumn     = '0',
    wrap           = true,  linebreak      = true,
    cursorline     = false,
    statusline     = ' ',   -- blank statusline = invisible divider bar
    spell          = false,
    list           = false,
    showbreak      = '   ',
    fillchars      = 'eob: ',  -- hide ~ end-of-buffer markers
  }
  for k, v in pairs(opts) do
    pcall(vim.api.nvim_win_set_option, win, k, v)
  end
end


-- ── open_sidebar ──────────────────────────────────────────────────────────
-- Layout (all real splits, no floats):
--
--   ┌─────────────────────────┐
--   │  topbar  (TOPBAR_H=2)   │  ← winfixheight, no statusline
--   ├─────────────────────────┤
--   │                         │
--   │  chat                   │  ← scrollable, welcome / messages
--   │                         │
--   ├─────────────────────────┤
--   │  input   (INPUT_H)      │  ← winfixheight, editable
--   └─────────────────────────┘
--
local function open_sidebar()
  if vim.o.columns < MIN_COLS then
    vim.notify(
      string.format('PandaVim AI: terminal too narrow (%d < %d cols)', vim.o.columns, MIN_COLS),
      vim.log.levels.WARN)
    return
  end

  local cur = vim.api.nvim_get_current_win()
  if not is_sidebar_win(cur) then
    S.last_editor_win = cur
    -- Capture the user's origin buffer so <editor_state> can reference it.
    -- This is the buffer they were editing BEFORE they triggered <leader>ac.
    local cur_buf = vim.api.nvim_win_get_buf(cur)
    if vim.api.nvim_buf_is_valid(cur_buf) then
      S.origin_buf = cur_buf
      S.origin_win = cur
    end
  end

  local w = math.min(W, vim.o.columns - 24)

  -- ── 1. Chat split (right column, full height initially) ──────────────────
  S.chat_buf = make_buf('AI:chat', false)
  local ok_win, chat_win = pcall(vim.api.nvim_open_win, S.chat_buf, false, {
    split = 'right',
    width = w,
  })
  if not ok_win then
    vim.notify('PandaVim AI: failed to open sidebar window', vim.log.levels.ERROR)
    return
  end
  S.chat_win = chat_win

  -- Initialize the tool-card widget with our chat buffer + shared namespace.
  -- Must happen BEFORE any run_tool_loop call renders a card.
  ToolCard.setup({ bufnr = S.chat_buf, ns = NS_CHAT })
  apply_cosmetics(S.chat_win)
  vim.api.nvim_win_set_option(S.chat_win, 'winhighlight',
    'Normal:AiChatBg,NormalNC:AiChatBg,SignColumn:AiChatBg,EndOfBuffer:AiChatBg,StatusLine:AiChatBg,StatusLineNC:AiChatBg')
  vim.api.nvim_win_set_option(S.chat_win, 'scrolloff', 3)
  -- Smooth scrolling (Neovim 0.10+)
  pcall(vim.api.nvim_win_set_option, S.chat_win, 'smoothscroll', true)

  -- ── 2. Topbar split (above chat, fixed height) ────────────────────────────
  S.topbar_buf = make_buf('AI:topbar', false)
  S.topbar_win = vim.api.nvim_open_win(S.topbar_buf, false, {
    split  = 'above',
    win    = S.chat_win,
    height = TOPBAR_H,
  })
  vim.api.nvim_win_set_option(S.topbar_win, 'winfixheight', true)
  vim.api.nvim_win_set_option(S.topbar_win, 'winfixwidth',  true)
  apply_cosmetics(S.topbar_win)
  vim.api.nvim_win_set_option(S.topbar_win, 'winhighlight',
    'Normal:AiTopBg,NormalNC:AiTopBg,SignColumn:AiTopBg,EndOfBuffer:AiTopBg,StatusLine:AiTopBg,StatusLineNC:AiTopBg')

  -- ── 3. Input split (below chat, fixed height) ─────────────────────────────
  S.input_buf = make_buf('AI:input', true)
  S.input_win = vim.api.nvim_open_win(S.input_buf, false, {
    split  = 'below',
    win    = S.chat_win,
    height = INPUT_H,
  })
  vim.api.nvim_win_set_option(S.input_win, 'winfixheight', true)
  vim.api.nvim_win_set_option(S.input_win, 'winfixwidth',  true)
  apply_cosmetics(S.input_win)
  vim.api.nvim_win_set_option(S.input_win, 'winhighlight',
    'Normal:AiInputBg,NormalNC:AiInputBg,CursorLine:AiInputBg,EndOfBuffer:AiInputBg,StatusLine:AiInputBg,StatusLineNC:AiInputBg,SignColumn:AiInputBorder')
  -- Left colored border via signcolumn (OpenCode-style ┃ agent border)
  vim.api.nvim_win_set_option(S.input_win, 'signcolumn', 'yes:1')
  vim.fn.sign_define('AiInputBorderSign', { text = '┃', texthl = 'AiInputBorder' })
  -- Place sign on every line (will be refreshed as needed)
  for i = 1, INPUT_H do
    pcall(vim.fn.sign_place, 0, 'AiInputBorderGrp', 'AiInputBorderSign', S.input_buf, { lnum = i })
  end

  -- ── 4. Initial content ────────────────────────────────────────────────────
  render_topbar()
  vim.schedule(function()
    if S.is_open then render_welcome() end
  end)
  render_input_bar()
  render_footer()
  setup_topbar_keymaps()
  setup_chat_keymaps()
  setup_input_keymaps(setup_slash_complete(), setup_at_complete())

  -- Placeholder text in input (OpenCode: "Ask anything..." with rotating examples)
  local placeholder_ns = vim.api.nvim_create_namespace('AiInputPlaceholder')
  local placeholders = {
    'Fix a TODO in the codebase',
    'Explain how this function works',
    'Write a unit test',
    'Refactor this code',
    'Help me debug this error',
  }
  local placeholder_idx = math.random(1, #placeholders)
  local function update_input_placeholder()
    vim.api.nvim_buf_clear_namespace(S.input_buf, placeholder_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
    local text = table.concat(lines, '\n')
    if vim.trim(text) == '' then
      pcall(vim.api.nvim_buf_set_extmark, S.input_buf, placeholder_ns, 0, 0, {
        virt_text = { { 'Ask anything... "' .. placeholders[placeholder_idx] .. '"', 'AiInputPlaceholder' } },
        virt_text_pos = 'overlay',
      })
    end
  end
  update_input_placeholder()
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged', 'InsertLeave', 'InsertEnter' }, {
    buffer = S.input_buf,
    callback = update_input_placeholder,
  })

  -- Live highlight for @filename tokens in the input buffer.
  -- Gives the user visual feedback that the token will be attached on submit,
  -- matching OpenCode's accent-colored mention styling.
  local at_mention_ns = vim.api.nvim_create_namespace('AiInputAtMention')
  local function update_at_mentions()
    if not S.input_buf or not vim.api.nvim_buf_is_valid(S.input_buf) then return end
    vim.api.nvim_buf_clear_namespace(S.input_buf, at_mention_ns, 0, -1)
    local lines = vim.api.nvim_buf_get_lines(S.input_buf, 0, -1, false)
    for row, line in ipairs(lines) do
      -- Scan the line for `@<nonspace>+` tokens. The opening `@` must be
      -- either at line start or preceded by whitespace so we don't match
      -- mid-word substrings (e.g. `user@host` shouldn't highlight `@host`).
      local i = 1
      while i <= #line do
        local s, e = line:find('@%S+', i)
        if not s then break end
        local before = s > 1 and line:sub(s - 1, s - 1) or ''
        if before == '' or before == ' ' or before == '\t' then
          pcall(vim.api.nvim_buf_set_extmark, S.input_buf, at_mention_ns,
            row - 1, s - 1, {
              end_col  = e,
              hl_group = 'AiAtFile',  -- reuse the picker's accent color
            })
        end
        i = e + 1
      end
    end
  end
  update_at_mentions()
  vim.api.nvim_create_autocmd({ 'TextChangedI', 'TextChanged' }, {
    buffer   = S.input_buf,
    callback = update_at_mentions,
  })

  S.is_open = true

  -- ── 5. Focus input ────────────────────────────────────────────────────────
  vim.api.nvim_set_current_win(S.input_win)
  vim.cmd('startinsert')

  -- ── 6. Autocmds ───────────────────────────────────────────────────────────
  S.win_augroup = vim.api.nvim_create_augroup('AiSidebar', { clear = true })

  vim.api.nvim_create_autocmd('WinEnter', {
    group = S.win_augroup,
    callback = function()
      local ww = vim.api.nvim_get_current_win()
      if not is_sidebar_win(ww) then S.last_editor_win = ww end
    end,
  })

  vim.api.nvim_create_autocmd('WinClosed', {
    group = S.win_augroup,
    callback = function(ev)
      local closed = tonumber(ev.match)
      if closed == S.chat_win or closed == S.input_win or closed == S.topbar_win then
        vim.schedule(function() M.close() end)
      end
    end,
  })

  -- Sticky-scroll: re-pin when the user reaches the bottom. UN-pinning is
  -- handled exclusively by the explicit j/k/gg/<C-u>/<C-d> keymaps which
  -- set S.scroll_pinned=false directly. This separation fixes an auto-scroll
  -- bug where async buffer growth (tool card renders, stream chunks) would
  -- momentarily produce `last_visible < total` and flip scroll_pinned to
  -- false — then scroll_bottom would early-return and the chat would stop
  -- tracking new content during tool calls.
  vim.api.nvim_create_autocmd('WinScrolled', {
    group = S.win_augroup,
    callback = function(ev)
      if tonumber(ev.match) ~= S.chat_win then return end
      if not win_ok(S.chat_win) or not S.chat_buf then return end
      local last_visible = vim.fn.line('w$', S.chat_win)
      local total        = vim.api.nvim_buf_line_count(S.chat_buf)
      if last_visible >= total then
        S.scroll_pinned = true
      end
      -- NOTE: intentionally do NOT set to false here.
    end,
  })

  vim.api.nvim_create_autocmd('VimResized', {
    group = S.win_augroup,
    callback = function()
      if not S.is_open then return end
      local new_w = math.min(W, vim.o.columns - 24)
      pcall(vim.api.nvim_win_set_width, S.chat_win,   new_w)
      pcall(vim.api.nvim_win_set_width, S.topbar_win, new_w)
      pcall(vim.api.nvim_win_set_width, S.input_win,  new_w)
      render_topbar()
      render_input_bar()
      if S.showing_welcome then render_welcome() end
    end,
  })
end

-- ═══════════════════════════════════════════════════════════════════════════
-- Public API
-- ═══════════════════════════════════════════════════════════════════════════

function M.focus_editor()
  vim.cmd('stopinsert')
  local target = S.last_editor_win
  if win_ok(target) and not is_sidebar_win(target) then
    vim.api.nvim_set_current_win(target)
  else
    for _, wid in ipairs(vim.api.nvim_list_wins()) do
      if not is_sidebar_win(wid) then
        vim.api.nvim_set_current_win(wid)
        return
      end
    end
  end
end

function M.focus_input()
  if not S.is_open then M.open() end
  if win_ok(S.input_win) then
    vim.api.nvim_set_current_win(S.input_win)
    vim.cmd('startinsert')
  end
end

function M.get_last_assistant_text()
  for i = #S.messages, 1, -1 do
    if S.messages[i].role == 'assistant' then
      return S.messages[i].content
    end
  end
  return nil
end

M.toast = toast

function M.cancel_stream()
  if not S.is_streaming then return end
  if S.stream_job then
    pcall(vim.fn.jobstop, S.stream_job)
    S.stream_job = nil
  end
  S.is_streaming = false
  stop_spinner()
  local md_start = S.stream_line
  S.stream_line  = nil
  if S.stream_text ~= '' then
    render_markdown_highlights(md_start, S.stream_text)
    table.insert(S.messages, { role = 'assistant', content = S.stream_text .. '\n[ cancelled ]' })
  end
  S.stream_text = ''
  M.append_system('[ cancelled ]')
  render_topbar()
  render_input_bar()
end

function M.close()
  if not S.is_open then return end
  stop_spinner()
  if #S.messages > 0 then session_save() end
  S.is_open = false
  pcall(vim.api.nvim_del_augroup_by_name, 'AiSidebar')
  for _, wid in ipairs({ S.topbar_win, S.input_win, S.chat_win }) do
    if win_ok(wid) then pcall(vim.api.nvim_win_close, wid, true) end
  end
  for _, bid in ipairs({ S.topbar_buf, S.input_buf, S.chat_buf }) do
    if bid and vim.api.nvim_buf_is_valid(bid) then
      pcall(vim.api.nvim_buf_delete, bid, { force = true })
    end
  end
  S.chat_win   = nil; S.chat_buf   = nil
  S.input_win  = nil; S.input_buf  = nil
  S.topbar_win = nil; S.topbar_buf = nil
  S.stream_line = nil; S.is_streaming = false
end

function M.open()
  if S.is_open then return end
  open_sidebar()
end

function M.toggle()
  if S.is_open then
    M.close()
    M.focus_editor()
  else
    M.open()
  end
end

function M.process_command(cmd_str)
  if not S.is_open then M.open() end
  process_slash_command(cmd_str)
end

function M.setup()
  NS_CHAT   = vim.api.nvim_create_namespace('ai_chat')
  NS_TOPBAR = vim.api.nvim_create_namespace('ai_topbar')
  NS_AT     = vim.api.nvim_create_namespace('ai_at_complete')

  -- Load persistent preferences from config
  S.show_timestamps = config.get_show_timestamps()

  -- Apply tool_mode / debug_mode from persisted config
  local cfg_tool_mode = config.get_tool_mode() or 'auto'
  tool_support.force(cfg_tool_mode == 'auto' and nil or cfg_tool_mode)
  client.set_debug(config.get_debug_mode() or false)

  -- Warn loudly if tools are disabled — this is a common footgun when a
  -- persisted session ends up with tool_mode='off' and the user wonders why
  -- the AI just describes what it would do instead of doing it.
  if cfg_tool_mode == 'off' then
    vim.schedule(function()
      vim.notify(
        'PandaVim AI: tool_mode is OFF — the AI cannot modify files.\n'
          .. 'Run :lua require("ai.ui").process_command("/tools auto") to re-enable.',
        vim.log.levels.WARN)
    end)
  end

  setup_highlights()

  vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('AiSidebarHL', { clear = true }),
    callback = function()
      setup_highlights()
      if S.is_open then render_topbar(); render_input_bar() end
    end,
  })

  -- Track the user's most-recently-edited real buffer so <editor_state>
  -- reflects the current file even if they buffer-switch after opening
  -- the sidebar. Only update when the BufEnter target is a real file buffer.
  vim.api.nvim_create_autocmd('BufEnter', {
    group = vim.api.nvim_create_augroup('AiOriginBuf', { clear = true }),
    callback = function(ev)
      local buf = ev.buf
      if not buf or not vim.api.nvim_buf_is_valid(buf) then return end
      local ok_bt, bt = pcall(vim.api.nvim_buf_get_option, buf, 'buftype')
      if ok_bt and (bt == 'nofile' or bt == 'terminal' or bt == 'help'
        or bt == 'quickfix' or bt == 'prompt') then
        return
      end
      local ok_ft, ft = pcall(vim.api.nvim_buf_get_option, buf, 'filetype')
      if ok_ft and (ft == 'AiChat' or ft == 'AiTopbar' or ft == 'AiInput') then
        return
      end
      local name = vim.api.nvim_buf_get_name(buf)
      if not name or name == '' then return end
      S.origin_buf = buf
      if S.is_open then pcall(render_footer) end
    end,
  })

  config.add_listener(function()
    vim.schedule(function()
      if S.is_open then render_topbar(); render_input_bar() end
    end)
  end)
  context.add_listener(function()
    vim.schedule(function()
      if S.is_open then render_topbar(); render_input_bar() end
    end)
  end)
end

return M
