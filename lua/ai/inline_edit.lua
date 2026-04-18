-- ai/inline_edit.lua
-- Inline AI edits with virtual-text diff preview and non-blocking confirm float.
--
-- Flow:
--   1. User selects lines (visual) or places cursor on a line (normal)
--   2. <leader>ae  →  edit_async() fires
--   3. AI returns new content
--   4. diff.show_inline_diff() writes new content into buffer + shows virt diff
--   5. Confirm float appears:
--        ╭─ AI Edit ─────────────────────╮
--        │  [y] Apply   [n] Reject        │
--        │  [e] Edit response             │
--        ╰────────────────────────────────╯
--   6a. y  →  diff marks cleared, content stays, done
--   6b. n  →  original lines restored, diff marks cleared
--   6c. e  →  response opened in a scratch split for manual tweaking,
--             then re-confirm ([y] apply edited / [n] cancel)

local M = {}

local config = require('ai.config')
local client = require('ai.client')
local skills = require('ai.skills')
local diff   = require('ai.diff')

-- ── Confirm float ─────────────────────────────────────────────────────────────

local CONFIRM_LINES = {
  '  [y] Apply    [n] Reject    [e] Edit  ',
}
local CONFIRM_W = vim.fn.strdisplaywidth(CONFIRM_LINES[1]) + 2
local CONFIRM_H = 3   -- top border + content + bottom border

local function hl(name, opts) vim.api.nvim_set_hl(0, name, opts) end

local function setup_hl()
  hl('AiEditFloat',       { bg = '#1e1f20', fg = '#c4c7c5' })
  hl('AiEditFloatBorder', { bg = '#1e1f20', fg = '#3c4043' })
  hl('AiEditKey',         { bg = '#1e1f20', fg = '#8ab4f8', bold = true })
  hl('AiEditStreaming',   { bg = '#131314', fg = '#8ab4f8', italic = true })
end

-- Open the confirm float anchored just below line `anchor_line` (1-indexed)
-- in `anchor_win`. Returns { win, buf }.
local function open_confirm_float(anchor_win, anchor_line)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_option(buf, 'buftype',   'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Position: below anchor line in anchor_win
  local win_row = vim.fn.win_screenpos(anchor_win)[1]  -- 1-indexed screen row of win top
  local cursor  = vim.api.nvim_win_get_cursor(anchor_win)
  local vis_row = cursor[1]  -- buffer line  (won't be perfect but good enough)
  -- Place the float relative to cursor
  local screen_h = vim.o.lines
  local row = math.min(win_row + vis_row, screen_h - CONFIRM_H - 2)

  local win_col  = vim.fn.win_screenpos(anchor_win)[2]
  local win_w    = vim.api.nvim_win_get_width(anchor_win)
  local col      = win_col + math.max(0, math.floor((win_w - CONFIRM_W) / 2))

  local float_win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    row      = row,
    col      = col,
    width    = CONFIRM_W,
    height   = 1,
    style    = 'minimal',
    border   = 'rounded',
    title    = ' AI Edit ',
    title_pos = 'center',
    zindex   = 60,
  })

  vim.api.nvim_win_set_option(float_win, 'winhighlight',
    'Normal:AiEditFloat,FloatBorder:AiEditFloatBorder')

  -- Write content
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, { CONFIRM_LINES[1] })
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Highlight the key letters
  local ns = vim.api.nvim_create_namespace('ai_edit_confirm')
  for _, col_range in ipairs({ {3,4}, {16,17}, {29,30} }) do
    vim.api.nvim_buf_add_highlight(buf, ns, 'AiEditKey', 0, col_range[1], col_range[2])
  end

  return { win = float_win, buf = buf }
end

local function close_float(f)
  if f and f.win and vim.api.nvim_win_is_valid(f.win) then
    pcall(vim.api.nvim_win_close, f.win, true)
  end
end

-- ── Edit scratch split ────────────────────────────────────────────────────────
-- Opens the AI response in a horizontal scratch split so the user can edit it.
-- Returns the scratch bufnr. Caller should wait for BufWipeout / manual confirm.

local function open_edit_split(content)
  vim.cmd('split')
  local split_win = vim.api.nvim_get_current_win()
  local split_buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_win_set_buf(split_win, split_buf)
  vim.api.nvim_buf_set_option(split_buf, 'buftype', 'acwrite')
  vim.api.nvim_buf_set_option(split_buf, 'filetype', 'markdown')
  vim.api.nvim_buf_set_name(split_buf, 'AI Edit Response')
  vim.api.nvim_buf_set_lines(split_buf, 0, -1, false,
    vim.split(content, '\n', { plain = true }))
  vim.api.nvim_buf_set_option(split_buf, 'modified', false)
  vim.notify('[AI Edit]  Edit the response, then :w to apply, :q! to cancel', vim.log.levels.INFO)
  return split_buf, split_win
end

-- ── Core confirm loop (non-blocking via on_key) ───────────────────────────────

-- State for the pending inline diff session
local pending = {
  active      = false,
  bufnr       = nil,
  start_line  = nil,
  end_line    = nil,
  orig_lines  = nil,
  new_content = nil,
  float       = nil,
  anchor_win  = nil,
}

local function clear_pending()
  if pending.float then close_float(pending.float) end
  pending.active      = false
  pending.float       = nil
  -- caller is responsible for clearing diff marks if needed
end

local function do_apply()
  -- diff marks remain in buffer (they are now just the content)
  diff.clear(pending.bufnr)
  vim.notify('  AI edit applied', vim.log.levels.INFO)
  clear_pending()
end

local function do_reject()
  -- Restore original lines
  if pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr) then
    vim.api.nvim_buf_set_option(pending.bufnr, 'modifiable', true)
    vim.api.nvim_buf_set_lines(pending.bufnr,
      pending.start_line - 1,
      pending.start_line - 1 + #vim.split(pending.new_content, '\n', { plain = true }),
      false, pending.orig_lines)
    diff.clear(pending.bufnr)
  end
  vim.notify('  AI edit rejected', vim.log.levels.INFO)
  clear_pending()
end

local function do_edit()
  close_float(pending.float)
  pending.float = nil

  local split_buf, split_win = open_edit_split(pending.new_content)

  -- When user writes (:w), apply the edited content
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = split_buf,
    once   = true,
    callback = function()
      local edited_lines = vim.api.nvim_buf_get_lines(split_buf, 0, -1, false)
      local edited = table.concat(edited_lines, '\n')
      -- Re-run show_inline_diff with edited content
      if pending.bufnr and vim.api.nvim_buf_is_valid(pending.bufnr) then
        diff.show_inline_diff(pending.bufnr, pending.orig_lines,
          edited_lines, pending.start_line)
        pending.new_content = edited
      end
      pcall(vim.api.nvim_win_close, split_win, true)
      -- Reopen the confirm float
      pending.float = open_confirm_float(pending.anchor_win, pending.start_line)
    end,
  })

  vim.api.nvim_create_autocmd({'BufWipeout', 'BufDelete'}, {
    buffer = split_buf,
    once   = true,
    callback = function()
      -- User closed without saving — treat as reject
      if pending.active then do_reject() end
    end,
  })
end

-- Register a one-shot on_key handler that listens for y/n/e while the float is open
local _on_key_id = nil

local function start_confirm(anchor_win, anchor_line)
  pending.anchor_win = anchor_win
  pending.float      = open_confirm_float(anchor_win, anchor_line)

  -- Go back to the editor window (float is non-focussed after key)
  vim.api.nvim_set_current_win(anchor_win)

  if _on_key_id then
    vim.on_key(nil, _on_key_id)
    _on_key_id = nil
  end

  _on_key_id = vim.on_key(function(key)
    if not pending.active then
      vim.on_key(nil, _on_key_id); _on_key_id = nil
      return
    end
    local ch = key:lower()
    if ch == 'y' then
      vim.on_key(nil, _on_key_id); _on_key_id = nil
      vim.schedule(do_apply)
    elseif ch == 'n' then
      vim.on_key(nil, _on_key_id); _on_key_id = nil
      vim.schedule(do_reject)
    elseif ch == 'e' then
      vim.on_key(nil, _on_key_id); _on_key_id = nil
      vim.schedule(do_edit)
    end
  end)
end

-- ── Selection helpers ─────────────────────────────────────────────────────────

function M.get_selection()
  local bufnr = vim.api.nvim_get_current_buf()
  local mode  = vim.fn.mode()
  if mode:match('[vV\x16]') then
    local s = vim.fn.line("'<")
    local e = vim.fn.line("'>")
    local lines = vim.api.nvim_buf_get_lines(bufnr, s-1, e, false)
    return table.concat(lines, '\n'), s, e
  else
    local vs = vim.fn.line("'<")
    local ve = vim.fn.line("'>")
    if vs > 0 and ve >= vs then
      local lines = vim.api.nvim_buf_get_lines(bufnr, vs-1, ve, false)
      return table.concat(lines, '\n'), vs, ve
    end
    local lnum = vim.fn.line('.')
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum-1, lnum, false)[1] or ''
    return line, lnum, lnum
  end
end

-- ── edit_async ────────────────────────────────────────────────────────────────

function M.edit_async(content, start_line, end_line, prompt, target_buf)
  if not content or content == '' then
    vim.notify('No content to edit', vim.log.levels.WARN)
    return
  end
  if pending.active then
    vim.notify('AI edit already in progress (press n to cancel)', vim.log.levels.WARN)
    return
  end

  local ft         = vim.bo[target_buf].filetype
  local skill_obj  = skills.get_default_skill and skills.get_default_skill(ft)
  local skill_name = (skill_obj and skill_obj.name) or 'fix'
  local full_prompt = skills.build_prompt(skill_name, content)
  if prompt and prompt ~= '' then
    full_prompt = full_prompt .. '\n\nAdditional instructions: ' .. prompt
  end

  -- Show a streaming indicator via extmark
  setup_hl()
  diff.setup_highlights()
  local ns_stream = vim.api.nvim_create_namespace('ai_edit_stream')
  vim.api.nvim_buf_set_extmark(target_buf, ns_stream, start_line - 1, 0, {
    virt_text       = { { ' ✦ AI editing… ', 'AiEditStreaming' } },
    virt_text_pos   = 'eol',
  })

  local response = ''

  client.chat_completion(
    { { role = 'user', content = full_prompt } },
    { model = config.get_model() },
    function(chunk) response = response .. chunk end,
    function()
      vim.schedule(function()
        -- Clear streaming indicator
        vim.api.nvim_buf_clear_namespace(target_buf, ns_stream, 0, -1)

        if response == '' then
          vim.notify('No response from AI', vim.log.levels.WARN)
          return
        end

        local orig_lines = vim.split(content, '\n', { plain = true })
        local new_lines  = vim.split(response, '\n', { plain = true })

        -- Store state
        pending.active      = true
        pending.bufnr       = target_buf
        pending.start_line  = start_line
        pending.end_line    = end_line
        pending.orig_lines  = orig_lines
        pending.new_content = response

        -- Show inline diff (writes new content into buffer)
        diff.show_inline_diff(target_buf, orig_lines, new_lines, start_line)

        -- Open confirm float
        local cur_win = vim.api.nvim_get_current_win()
        start_confirm(cur_win, start_line)
      end)
    end,
    function(err)
      vim.schedule(function()
        vim.api.nvim_buf_clear_namespace(target_buf, ns_stream, 0, -1)
        vim.notify('AI error: ' .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  )
end

-- ── Public entry points ───────────────────────────────────────────────────────

function M.edit(prompt)
  local target_buf             = vim.api.nvim_get_current_buf()
  local content, start_line, end_line = M.get_selection()
  M.edit_async(content, start_line, end_line, prompt or '', target_buf)
end

function M.handle_command(args)
  M.edit(args)
end

-- Cancel any pending diff
function M.cancel()
  if pending.active then do_reject() end
end

function M.setup()
  setup_hl()

  vim.api.nvim_create_user_command('AIEdit', function(args)
    M.handle_command(args.args)
  end, { nargs = '*', desc = 'AI inline edit' })

  vim.api.nvim_create_user_command('AIEditCancel', function()
    M.cancel()
  end, { desc = 'Cancel pending AI inline edit' })

  -- Visual mode
  vim.keymap.set('v', '<leader>ae', function()
    local target_buf             = vim.api.nvim_get_current_buf()
    local content, start_line, end_line = M.get_selection()
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
    if content == '' then vim.notify('No selection', vim.log.levels.WARN); return end
    M.edit_async(content, start_line, end_line, '', target_buf)
  end, { noremap = true, silent = true, desc = 'AI Edit selection' })

  -- Normal mode
  vim.keymap.set('n', '<leader>ae', function()
    M.edit('')
  end, { noremap = true, silent = true, desc = 'AI Edit current line' })

  -- Cancel shortcut
  vim.keymap.set('n', '<leader>ax', function()
    M.cancel()
  end, { noremap = true, silent = true, desc = 'AI Edit cancel' })
end

return M
