-- ai/ui_tool_card.lua
-- Boxed tool-call cards for PandaVim AI's chat sidebar.
-- Modeled after avante.nvim's `Render.tool_to_lines` (history/render.lua:415+).
--
-- A card always has this shape:
--   ╭─  <name>(<short_arg>)   <state>
--   │   ...body lines (output, diff, error, permission prompt)...
--   ╰─  <footer>              (e.g. "completed", "failed", "Allow? […]")
--
-- Each card is identified by a `card_id` (caller-supplied string, typically
-- the tool_call.id). The module maintains a table `state[card_id]` that
-- remembers the buffer row range so subsequent updates can REPLACE the card
-- in place (single redraw, no duplicates) instead of appending a new one.
--
-- Public API:
--   M.setup(opts)              -- one-time; pass { bufnr, ns }
--   M.render(card_id, spec)    -- create or update a card
--     spec = {
--       tool_name     = 'write',         -- required
--       args          = { filePath=..., ... },
--       state         = 'generating'|'permission'|'running'|'succeeded'|'failed',
--       body_lines    = { 'line1', ... } -- optional body text lines
--       body_hl       = 'AiToolBody' | 'AiToolError'  -- highlight group for body
--       diff          = { old_lines=..., new_lines=... }  -- optional; renders a mini-diff
--       permission    = { buttons = { {id,label}, ... } } -- renders a button row
--                                                         -- (Phase 3 wires this)
--       footer        = 'optional footer text'
--     }
--   M.remove(card_id)          -- delete a card from the buffer
--   M.get_card_at(row)         -> card_id|nil — find card covering a row
--   M.set_expanded(card_id, bool)
--   M.is_expanded(card_id)     -> bool

local M = {}

local P              = 3            -- left padding (matches chat's global P)
local DECO_PREFIX    = '│   '       -- body line prefix
local HEADER_TOP     = '╭─  '
local FOOTER_BOTTOM  = '╰─  '
local MAX_COLLAPSED_BODY_LINES = 10 -- collapse threshold (Phase 9 toggles)

-- Internal module state (per bufnr)
-- state[card_id] = {
--   bufnr      = int,
--   start_row  = int,        -- 0-indexed, first row of card (header)
--   line_count = int,
--   extmark_id = int,        -- one extmark per card for invalidation tracking
--   expanded   = bool,
--   spec       = table,
-- }
local cards = {}

-- Set-once config
local cfg = {
  bufnr = nil,
  ns    = nil,  -- namespace for extmarks
}

local function bufnr() return cfg.bufnr end
local function ns()    return cfg.ns    end

--- Initialize the card registry. Must be called once after the chat buffer
-- is created and the namespace is allocated.
function M.setup(opts)
  cfg.bufnr = opts.bufnr
  cfg.ns    = opts.ns
  cards = {}
end

-- ── Tool name formatting (avante-style: name("short arg")) ────────────────

local function tool_header_label(tool_name, args)
  args = args or {}
  local param
  if type(args.filePath) == 'string' then
    param = vim.fn.fnamemodify(args.filePath, ':.')  -- prefer cwd-relative
    if #param > 50 then param = '…' .. param:sub(-48) end
  elseif type(args.path) == 'string' then
    param = args.path
  elseif type(args.pattern) == 'string' then
    param = args.pattern
  elseif type(args.query) == 'string' then
    param = args.query
  elseif type(args.command) == 'string' then
    param = args.command
    local first_line = param:match('([^\n]+)')
    if first_line and first_line ~= param then
      param = first_line .. ' …'
    end
    if #param > 50 then param = param:sub(1, 47) .. '…' end
  end
  if param then
    return string.format('%s("%s")', tool_name, param)
  end
  return tool_name
end

-- State → (icon, hl_group)
local STATE_STYLE = {
  generating = { icon = '⋯',  hl = 'AiToolStateGenerating',  label = 'preparing'   },
  permission = { icon = '🟡', hl = 'AiToolStatePermission',  label = 'waiting for confirmation' },
  running    = { icon = '⟳',  hl = 'AiToolStateRunning',     label = 'running'     },
  succeeded  = { icon = '✓',  hl = 'AiToolStateSuccess',     label = 'succeeded'   },
  failed     = { icon = '✗',  hl = 'AiToolStateFailed',      label = 'failed'      },
  thinking   = { icon = '🤔', hl = 'AiToolStatePermission',  label = 'reasoning'   },
  -- R1: passive state used when inline-apply owns the accept/reject UX.
  -- The chat shows only a one-liner; the editor owns interaction.
  proposing  = { icon = '📝', hl = 'AiToolStateRunning',     label = 'see editor' },
}

-- ── Diff helpers (vim.diff histogram) ─────────────────────────────────────

--- Compute a mini-diff between `old_str` and `new_str`.
-- Returns a list of { type='add'|'del'|'ctx', text } items.
-- `max_ctx` lines are kept around each hunk; if the total exceeds
-- `max_lines`, the rest is replaced by a single marker entry.
function M.compute_diff(old_str, new_str, max_lines, max_ctx)
  max_lines = max_lines or 40
  max_ctx   = max_ctx or 2
  local old_lines = vim.split(old_str or '', '\n', { plain = true })
  local new_lines = vim.split(new_str or '', '\n', { plain = true })

  local out = {}
  local ok, indices = pcall(vim.diff, old_str or '', new_str or '', {
    algorithm   = 'histogram',
    result_type = 'indices',
    ctxlen      = max_ctx,
  })
  if not ok or type(indices) ~= 'table' then
    -- Fallback: dump new verbatim
    for _, l in ipairs(new_lines) do
      table.insert(out, { type = 'add', text = l })
    end
    return out
  end

  for _, hunk in ipairs(indices) do
    local start_a, count_a, start_b, count_b = hunk[1], hunk[2], hunk[3], hunk[4]
    if count_a > 0 then
      for i = start_a, start_a + count_a - 1 do
        table.insert(out, { type = 'del', text = old_lines[i] or '' })
      end
    end
    if count_b > 0 then
      for i = start_b, start_b + count_b - 1 do
        table.insert(out, { type = 'add', text = new_lines[i] or '' })
      end
    end
    if #out >= max_lines then
      table.insert(out, { type = 'trunc', text = '(diff truncated)' })
      break
    end
  end

  return out
end

-- ── Core renderer ──────────────────────────────────────────────────────────

local function trunc(text, max)
  if vim.fn.strdisplaywidth(text) <= max then return text end
  return text:sub(1, max - 1) .. '…'
end

-- ── Cursor-style inline (one-liner) rendering ─────────────────────────────
--
-- When a tool is in a "terminal" state (succeeded/failed) we collapse the
-- whole boxed card into a single line, like Cursor's "→ Read README.md" or
-- "✓ README.md +1 -1". The user can <S-Tab> to expand back to a full card.
--
-- Per-tool / per-state inline policy. nil = always render as full card.
local INLINE_FOR_STATE = {
  read    = { succeeded = true, failed = true },
  glob    = { succeeded = true, failed = true },
  grep    = { succeeded = true, failed = true },
  -- R1: write/edit also collapse in the new 'proposing' state (chat passive,
  -- editor owns the diff). Pending/permission states still render full card.
  write   = { succeeded = true, failed = true, proposing = true },
  edit    = { succeeded = true, failed = true, proposing = true },
  bash    = { succeeded = true, failed = true },
}
-- Special: thinking cards always collapse by default, regardless of tool name
-- (the tool_name field is the display title like "🤔 Thinking · N tokens").
local function is_thinking_card(spec)
  return spec.state == 'thinking'
end

-- Special: turn-summary cards (Change B) render as a single compact line
-- with buttons below, not as a boxed card. Opt in via spec.summary = true.
local function is_summary_card(spec)
  return spec.summary == true
end

-- Glyph used as the "leading marker" on inline rows
local INLINE_MARKER = {
  succeeded = '✓',
  failed    = '✗',
  default   = '→',
}

-- Cursor-style per-tool icons (Change C). Replaces the generic ✓ marker with
-- a verb-appropriate glyph for each tool. `failed` still uses ✗ via
-- build_inline's hl_state branch.
local TOOL_ICON = {
  read  = '📄',
  write = '📝',
  edit  = 'ⓘ',
  glob  = '🔎',
  grep  = '🔍',
  bash  = '$',
}

-- Build a one-line inline rendering of a tool card.
-- Returns the same shape as build_card: (lines, line_hls, badge_range, stat_extra_hls).
-- For inline cards, `lines` has 1 row, line_hls is { 'AiToolHeader' }, no badge.
local function build_inline(spec)
  -- Special case: thinking cards render as their tool_name (already includes
  -- token count) plus "<S-Tab> to expand" hint.
  if is_thinking_card(spec) then
    local title = spec.tool_name or '🤔 Thinking'
    local line = string.rep(' ', P) .. title .. '   <S-Tab> to expand'
    return { line }, { 'AiToolHeader' }, nil, {}
  end

  -- Special case: turn summary. Single-line passive status bar; no buttons.
  -- (Editor owns accept/reject for inline-apply sessions.)
  if is_summary_card(spec) then
    local title = spec.tool_name or 'summary'
    local suffix = spec.footer and spec.footer ~= '' and ('  ' .. spec.footer) or ''
    local line = string.rep(' ', P) .. title .. suffix
    return { line }, { 'AiToolHeader' }, nil, {}
  end

  local args = spec.args or {}
  local tool = spec.tool_name
  -- Cursor-style: failed = ✗, succeeded/proposing = tool icon, else → fallback
  local marker
  if spec.state == 'failed' then
    marker = INLINE_MARKER.failed
  elseif (spec.state == 'succeeded' or spec.state == 'proposing')
      and TOOL_ICON[tool] then
    marker = TOOL_ICON[tool]
  else
    marker = INLINE_MARKER[spec.state] or INLINE_MARKER.default
  end
  local hl_state = (spec.state == 'failed') and 'AiToolStateFailed' or nil

  -- Compute +N -M from diff if present (for write/edit)
  local stat_str = ''
  if spec.diff and spec.diff.old_str ~= nil and spec.diff.new_str ~= nil then
    local d = M.compute_diff(spec.diff.old_str, spec.diff.new_str, 9999, 0)
    local adds, dels = 0, 0
    for _, item in ipairs(d) do
      if item.type == 'add' then adds = adds + 1 end
      if item.type == 'del' then dels = dels + 1 end
    end
    if adds > 0 or dels > 0 then
      stat_str = string.format('  +%d -%d', adds, dels)
    end
  end

  -- Verb + summary based on tool. R1: 'proposing' state uses present tense
  -- + "see editor" hint to make it clear the user acts in the editor pane.
  local summary
  if tool == 'read' then
    summary = string.format('Read %s', vim.fn.fnamemodify(args.filePath or '?', ':.'))
  elseif tool == 'write' then
    if spec.state == 'proposing' then
      summary = string.format('Proposing write to %s — see editor',
        vim.fn.fnamemodify(args.filePath or '?', ':.'))
    else
      summary = string.format('Wrote %s', vim.fn.fnamemodify(args.filePath or '?', ':.'))
    end
  elseif tool == 'edit' then
    if spec.state == 'proposing' then
      summary = string.format('Proposing edit to %s — see editor',
        vim.fn.fnamemodify(args.filePath or '?', ':.'))
    else
      summary = string.format('Edited %s', vim.fn.fnamemodify(args.filePath or '?', ':.'))
    end
  elseif tool == 'glob' then
    local match_count = 0
    if spec.body_lines then
      for _, l in ipairs(spec.body_lines) do
        if l ~= '' and not l:match('no matches') then match_count = match_count + 1 end
      end
    end
    summary = string.format('Found %d matches for %s', match_count, args.pattern or '?')
  elseif tool == 'grep' then
    local match_count = 0
    if spec.body_lines then
      for _, l in ipairs(spec.body_lines) do
        if l ~= '' and not l:match('no matches') then match_count = match_count + 1 end
      end
    end
    summary = string.format('Found %d matches for "%s"', match_count, args.pattern or '?')
  elseif tool == 'bash' then
    local cmd_short = (args.command or ''):match('^([^\n]+)') or args.command or '?'
    if #cmd_short > 40 then cmd_short = cmd_short:sub(1, 37) .. '…' end
    summary = string.format('Ran `%s`', cmd_short)
  else
    summary = tool
  end

  -- Build the line:  "    ✓ Edited test.py  +3 -2"  (with hint if failed)
  local prefix = string.rep(' ', P) .. marker .. ' '
  local line = prefix .. summary .. stat_str
  local hint = ''
  if spec.state == 'failed' and spec.body_lines and spec.body_lines[1] then
    local err = spec.body_lines[1]
    if #err > 80 then err = err:sub(1, 77) .. '…' end
    hint = ' — ' .. err
    line = line .. hint
  end
  if vim.fn.strdisplaywidth(line) > 100 then line = line:sub(1, 99) .. '…' end

  -- Per-segment highlights (returned via stat_extra_hls)
  local extras = {}
  -- Marker: green for success, red for failure
  local mhl = (spec.state == 'failed') and 'AiToolStateFailed' or 'AiToolStateSuccess'
  table.insert(extras, { col_start = #string.rep(' ', P), col_end = #string.rep(' ', P) + #marker, hl = mhl })

  if stat_str ~= '' then
    local stat_byte_start = #prefix + #summary + 2  -- +2 for "  "
    local plus_s, plus_e = stat_str:find('%+%d+', 1)
    local minus_s, minus_e = stat_str:find('%-%d+', 1)
    if plus_s then
      table.insert(extras, {
        col_start = stat_byte_start + plus_s - 3,
        col_end   = stat_byte_start + plus_e - 2,
        hl        = 'AiToolStatAdd',
      })
    end
    if minus_s then
      table.insert(extras, {
        col_start = stat_byte_start + minus_s - 3,
        col_end   = stat_byte_start + minus_e - 2,
        hl        = 'AiToolStatDel',
      })
    end
  end

  if hint ~= '' then
    local hint_start = #line - #hint
    table.insert(extras, { col_start = hint_start, col_end = #line, hl = 'AiToolError' })
  end

  return { line }, { 'AiToolHeader' }, nil, extras
end

-- True if this spec should render as a one-liner (Cursor style).
local function should_render_inline(spec)
  if spec.expanded then return false end       -- user toggled to full card via <S-Tab>
  -- Summary and thinking cards always inline, regardless of permission/state
  if is_summary_card(spec) then return true end
  if is_thinking_card(spec) then return true end
  if spec.permission then return false end     -- never collapse a permission prompt for tool calls
  local map = INLINE_FOR_STATE[spec.tool_name]
  if not map then return false end
  if not map[spec.state] then return false end
  return true
end

-- Build the array of buffer lines + per-line highlight metadata for a card.
-- Returns: lines (array of strings), line_hls (array of { hl_group } or nil),
-- and `badge_col_range = {start, end}` to color the state badge on the header.
local function build_card(spec)
  -- Cursor-style inline mode: collapse completed read/glob/grep/write/edit/bash
  -- into one-liner unless the user expanded it.
  if should_render_inline(spec) then
    return build_inline(spec)
  end
  local state_style = STATE_STYLE[spec.state] or STATE_STYLE.generating
  local label       = tool_header_label(spec.tool_name, spec.args)

  -- Feature 4: compute +N / -M counts from the diff (when present) for the
  -- "+3 -2" badge in the header, like Cursor's chat-side file mention.
  local stat_str = ''
  local stat_off_in_line = nil  -- byte offset where +N -M starts inside the line, for highlighting
  if spec.diff and spec.diff.old_str ~= nil and spec.diff.new_str ~= nil then
    local d = M.compute_diff(spec.diff.old_str, spec.diff.new_str, 9999, 0)
    local adds, dels = 0, 0
    for _, item in ipairs(d) do
      if item.type == 'add' then adds = adds + 1 end
      if item.type == 'del' then dels = dels + 1 end
    end
    if adds > 0 or dels > 0 then
      stat_str = string.format('  +%d -%d', adds, dels)
    end
  end

  local header_body = label .. stat_str
    .. string.format('  %s %s', state_style.icon, state_style.label)
  header_body = trunc(header_body, 100)
  local header_line = string.rep(' ', P - 1) .. HEADER_TOP .. header_body

  local lines   = { header_line }
  local line_hl = { 'AiToolHeader' }

  -- Compute badge ranges in the rendered line (we'll color +N green and -M red)
  local prefix_len = #string.rep(' ', P - 1) + #HEADER_TOP
  local stat_extra_hls = {}
  if stat_str ~= '' then
    -- stat_str is "  +N -M" — find both halves
    local stat_byte_start = prefix_len + #label + 2  -- +2 for the leading "  "
    local plus_match_start, plus_match_end = stat_str:find('%+%d+', 1)
    local minus_match_start, minus_match_end = stat_str:find('%-%d+', 1)
    if plus_match_start then
      table.insert(stat_extra_hls, {
        col_start = stat_byte_start + plus_match_start - 3,  -- -2 leading spaces
        col_end   = stat_byte_start + plus_match_end - 2,
        hl        = 'AiToolStatAdd',
      })
    end
    if minus_match_start then
      table.insert(stat_extra_hls, {
        col_start = stat_byte_start + minus_match_start - 3,
        col_end   = stat_byte_start + minus_match_end - 2,
        hl        = 'AiToolStatDel',
      })
    end
  end

  -- Badge column range (for colored background over `icon + label`)
  local badge_start = prefix_len + #label + #stat_str + 2
  local badge_end   = badge_start + #state_style.icon + 1 + #state_style.label

  -- Body: diff, permission placeholder, or body_lines
  local body_prefix = string.rep(' ', P - 1) .. DECO_PREFIX

  local function push_body(text, hl)
    table.insert(lines, body_prefix .. text)
    table.insert(line_hl, hl or 'AiToolBody')
  end

  if spec.diff and spec.diff.old_str ~= nil and spec.diff.new_str ~= nil then
    local max_lines = spec.expanded and 999 or MAX_COLLAPSED_BODY_LINES
    local d = M.compute_diff(spec.diff.old_str, spec.diff.new_str, max_lines)
    if #d == 0 then
      push_body('(no changes)', 'AiToolBody')
    else
      for _, item in ipairs(d) do
        if item.type == 'add' then
          push_body('+ ' .. item.text, 'AiToolDiffAdd')
        elseif item.type == 'del' then
          push_body('- ' .. item.text, 'AiToolDiffDel')
        elseif item.type == 'trunc' then
          push_body(item.text, 'AiToolBody')
        else
          push_body('  ' .. item.text, 'AiToolBody')
        end
      end
    end
  elseif spec.body_lines and #spec.body_lines > 0 then
    local max_lines = spec.expanded and 999 or MAX_COLLAPSED_BODY_LINES
    local hl = spec.body_hl or 'AiToolBody'
    local shown = 0
    for _, l in ipairs(spec.body_lines) do
      shown = shown + 1
      if shown > max_lines then
        push_body(string.format('… (%d more lines — <S-Tab> to expand)',
          #spec.body_lines - max_lines), 'AiToolBody')
        break
      end
      push_body(l, hl)
    end
  elseif spec.state == 'generating' then
    push_body('…', 'AiToolBody')
  end

  -- Permission buttons (Phase 3 will make these real widget lines; for now
  -- we render a single text line that's replaced by ui_button_row later).
  if spec.permission and spec.permission.buttons then
    -- Blank spacer line
    push_body('', 'AiToolBody')
    -- Marker row — Phase 3's button widget will overwrite this row with its
    -- own rendering (extmarks).
    local btn_labels = {}
    for _, b in ipairs(spec.permission.buttons) do
      table.insert(btn_labels, '[ ' .. b.label .. ' ]')
    end
    push_body(table.concat(btn_labels, '   '), 'AiToolButtonsPlaceholder')
  end

  -- Footer
  -- When permission buttons are rendered, the title bar already carries the
  -- "🟡 waiting for confirmation" label; repeating it in the footer below
  -- the buttons looks doubled-up (the buttons themselves convey the action).
  -- Suppress the default state-label in that case unless an explicit
  -- spec.footer was supplied.
  local has_buttons = spec.permission and spec.permission.buttons
                       and #spec.permission.buttons > 0
  local default_label = has_buttons and '' or state_style.label
  local footer_text = spec.footer or default_label
  table.insert(lines, string.rep(' ', P - 1) .. FOOTER_BOTTOM .. footer_text)
  table.insert(line_hl, 'AiToolHeader')

  return lines, line_hl, { badge_start, badge_end }, stat_extra_hls
end

-- ── Render API ────────────────────────────────────────────────────────────

--- Create or replace a card for `card_id`.
-- Returns { start_row, end_row } (0-indexed inclusive, exclusive end) of
-- the rendered card so the caller can e.g. attach button widgets at a
-- specific row.
function M.render(card_id, spec)
  if not bufnr() or not vim.api.nvim_buf_is_valid(bufnr()) then return nil end
  local existing = cards[card_id]

  -- Preserve expanded flag if the caller didn't explicitly set it
  if existing and spec.expanded == nil then
    spec.expanded = existing.expanded
  end
  spec.expanded = spec.expanded == true

  local lines, line_hls, badge_range, stat_extra_hls = build_card(spec)

  -- Visual breathing room: sandwich the card with one blank line above and
  -- one below so tool cards don't collide with adjacent assistant text.
  -- The padding lines have no highlight. All highlight row indices below
  -- are shifted by PAD_TOP accordingly.
  local PAD_TOP, PAD_BOT = 1, 1
  -- Summary cards render as a single inline bar; skip padding for those to
  -- keep the per-turn summary visually attached to the tool activity above.
  if spec.summary == true then PAD_TOP, PAD_BOT = 0, 0 end
  local padded_lines, padded_hls = {}, {}
  for _ = 1, PAD_TOP do
    table.insert(padded_lines, '')
    table.insert(padded_hls, nil)
  end
  for i, l in ipairs(lines) do
    table.insert(padded_lines, l)
    table.insert(padded_hls, line_hls[i])
  end
  for _ = 1, PAD_BOT do
    table.insert(padded_lines, '')
    table.insert(padded_hls, nil)
  end

  pcall(vim.api.nvim_buf_set_option, bufnr(), 'modifiable', true)

  local start_row, end_row
  if existing and vim.api.nvim_buf_is_valid(bufnr()) then
    -- In-place replacement
    start_row = existing.start_row
    local old_end = existing.start_row + existing.line_count
    pcall(vim.api.nvim_buf_set_lines, bufnr(), start_row, old_end, false, padded_lines)
    end_row = start_row + #padded_lines
  else
    -- Fresh card appended at end of buffer
    start_row = vim.api.nvim_buf_line_count(bufnr())
    pcall(vim.api.nvim_buf_set_lines, bufnr(), start_row, start_row, false, padded_lines)
    end_row = start_row + #padded_lines
  end

  -- The header sits PAD_TOP rows below start_row.
  local header_row = start_row + PAD_TOP

  -- Clear any prior highlights in this range, then reapply
  if ns() then
    pcall(vim.api.nvim_buf_clear_namespace, bufnr(), ns(), start_row, end_row)
    for i, hl in ipairs(padded_hls) do
      if hl then
        pcall(vim.api.nvim_buf_add_highlight, bufnr(), ns(), hl, start_row + i - 1, 0, -1)
      end
    end
    -- Badge highlight (colored segment of header)
    if badge_range then
      local style = STATE_STYLE[spec.state] or STATE_STYLE.generating
      pcall(vim.api.nvim_buf_add_highlight, bufnr(), ns(), style.hl,
        header_row, badge_range[1], badge_range[2])
    end
    -- Feature 4: +N -M stat highlights on the header line
    if stat_extra_hls then
      for _, stat in ipairs(stat_extra_hls) do
        pcall(vim.api.nvim_buf_add_highlight, bufnr(), ns(), stat.hl,
          header_row, stat.col_start, stat.col_end)
      end
    end
  end

  pcall(vim.api.nvim_buf_set_option, bufnr(), 'modifiable', false)

  cards[card_id] = {
    bufnr      = bufnr(),
    start_row  = start_row,
    line_count = #padded_lines,
    expanded   = spec.expanded,
    spec       = spec,
  }
  -- Compute the button-placeholder row (if any) so the caller doesn't have
  -- to reason about padding. The placeholder is `lines[#lines - 1]` inside
  -- build_card (spacer is #lines - 2, footer is #lines). Shift by PAD_TOP.
  local button_row = nil
  if spec.permission and spec.permission.buttons and #spec.permission.buttons > 0 then
    button_row = header_row + (#lines - 2)  -- 0-indexed button placeholder row
  end
  return {
    start_row  = start_row,
    end_row    = end_row,
    header_row = header_row,
    button_row = button_row,
    lines      = padded_lines,
  }
end

--- Remove a card entirely.
function M.remove(card_id)
  local card = cards[card_id]
  if not card or not bufnr() or not vim.api.nvim_buf_is_valid(bufnr()) then return end
  pcall(vim.api.nvim_buf_set_option, bufnr(), 'modifiable', true)
  pcall(vim.api.nvim_buf_set_lines, bufnr(),
    card.start_row, card.start_row + card.line_count, false, {})
  pcall(vim.api.nvim_buf_set_option, bufnr(), 'modifiable', false)
  cards[card_id] = nil
  -- Adjust start_row of cards after the removed one
  local delta = -card.line_count
  for _, c in pairs(cards) do
    if c.start_row > card.start_row then
      c.start_row = c.start_row + delta
    end
  end
end

--- Return the card_id whose rendered range covers buffer row `row`
-- (0-indexed). nil if `row` isn't inside any card.
function M.get_card_at(row)
  for id, c in pairs(cards) do
    if row >= c.start_row and row < c.start_row + c.line_count then
      return id
    end
  end
  return nil
end

function M.set_expanded(card_id, expanded)
  local c = cards[card_id]
  if not c then return end
  c.expanded = expanded and true or false
  -- Re-render with the updated flag
  local spec = vim.tbl_extend('force', c.spec, { expanded = c.expanded })
  M.render(card_id, spec)
end

function M.is_expanded(card_id)
  local c = cards[card_id]
  return c and c.expanded or false
end

--- Return { start_row, line_count } for a card, or nil.
function M.get_range(card_id)
  local c = cards[card_id]
  if not c then return nil end
  return { start_row = c.start_row, line_count = c.line_count }
end

--- For testing: reset the whole registry.
function M._reset()
  cards = {}
end

return M
