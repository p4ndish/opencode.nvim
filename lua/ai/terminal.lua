local M = {}

local state = {
  winid = nil,
  bufnr = nil,
  origin_win = nil,
  setup_done = false,
}

local function default_opts()
  return {
    split = 'right',
    width = math.floor(vim.o.columns * 0.35),
  }
end

local function valid_win(winid)
  return winid and vim.api.nvim_win_is_valid(winid)
end

local function valid_buf(bufnr)
  return bufnr and vim.api.nvim_buf_is_valid(bufnr)
end

local function command()
  local cmd = require('ai.config').get_terminal_command()
  if vim.fn.executable(cmd) ~= 1 then
    vim.notify('PandaVim AI terminal mode: command not found: ' .. cmd, vim.log.levels.ERROR)
    return nil
  end
  return cmd
end

local function focus_editor()
  local win = state.origin_win
  if valid_win(win) then
    vim.api.nvim_set_current_win(win)
    return
  end
  for _, wid in ipairs(vim.api.nvim_list_wins()) do
    if wid ~= state.winid then
      vim.api.nvim_set_current_win(wid)
      return
    end
  end
end

local function apply_keymaps(buf)
  local opts = { buffer = buf, silent = true, noremap = true }
  vim.keymap.set('t', '<Esc>', [[<C-\><C-n>]], vim.tbl_extend('force', opts, { desc = 'AI terminal: normal mode' }))
  vim.keymap.set('n', '<Esc>', function()
    local job_id = vim.b[buf] and vim.b[buf].terminal_job_id
    if job_id then
      pcall(vim.fn.chansend, job_id, '\003')
    end
  end, vim.tbl_extend('force', opts, { desc = 'AI terminal: interrupt' }))
  vim.keymap.set('n', '<C-u>', '<C-u>', opts)
  vim.keymap.set('n', '<C-d>', '<C-d>', opts)
  vim.keymap.set('n', 'gg', 'gg', opts)
  vim.keymap.set('n', 'G', 'G', opts)
  vim.keymap.set('n', '<C-Left>', function()
    focus_editor()
  end, vim.tbl_extend('force', opts, { desc = 'AI terminal: focus editor' }))
end

local function setup(win)
  local buf = vim.api.nvim_win_get_buf(win)
  local pid

  vim.api.nvim_create_autocmd('TermOpen', {
    buffer = buf,
    once = true,
    callback = function(event)
      apply_keymaps(event.buf)
      _, pid = pcall(vim.fn.jobpid, vim.b[event.buf].terminal_job_id)
    end,
  })

  local redraw_auid
  redraw_auid = vim.api.nvim_create_autocmd('TermRequest', {
    buffer = buf,
    callback = function(ev)
      if ev.data and ev.data.cursor and ev.data.cursor[1] and ev.data.cursor[1] > 1 then
        pcall(vim.api.nvim_del_autocmd, redraw_auid)
        if valid_win(state.winid) then
          vim.api.nvim_set_current_win(state.winid)
          vim.cmd([[startinsert | call feedkeys("\<C-\\>\<C-n>\<C-w>p", "n")]])
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd('TermClose', {
    buffer = buf,
    once = true,
    callback = function()
      if pid and vim.fn.has('unix') == 1 then
        os.execute('kill -TERM -' .. pid .. ' 2>/dev/null')
      elseif pid then
        pcall(vim.uv.kill, pid, 'SIGTERM')
      end
    end,
  })
end

function M.is_open()
  return valid_win(state.winid)
end

function M.open(opts)
  local cmd = command()
  if not cmd then return end

  opts = opts or default_opts()
  state.origin_win = vim.api.nvim_get_current_win()
  if valid_buf(state.bufnr) then
    if not valid_win(state.winid) then
      state.winid = vim.api.nvim_open_win(state.bufnr, true, opts)
      vim.cmd('startinsert')
    end
    return
  end

  state.bufnr = vim.api.nvim_create_buf(false, false)
  state.winid = vim.api.nvim_open_win(state.bufnr, true, opts)

  vim.api.nvim_create_autocmd('ExitPre', {
    once = true,
    callback = function()
      M.close()
    end,
  })

  vim.bo[state.bufnr].bufhidden = 'wipe'
  vim.bo[state.bufnr].filetype = 'opencode-terminal'
  if not state.setup_done then
    setup(state.winid)
    state.setup_done = true
  end

  vim.fn.jobstart(cmd, {
    term = true,
    cwd = vim.fn.getcwd(),
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 or code == 143 then
          M.close()
        else
          vim.notify(
            'PandaVim AI terminal exited with code ' .. tostring(code),
            vim.log.levels.ERROR
          )
        end
      end)
    end,
  })
  vim.cmd('startinsert')
end

function M.toggle(opts)
  if valid_win(state.winid) then
    vim.api.nvim_win_hide(state.winid)
    state.winid = nil
    return
  end
  M.open(opts)
end

function M.focus()
  if valid_win(state.winid) then
    vim.api.nvim_set_current_win(state.winid)
    vim.cmd('startinsert')
  else
    M.open()
  end
end

function M.close()
  local job_id = state.bufnr and vim.b[state.bufnr] and vim.b[state.bufnr].terminal_job_id
  if job_id then
    pcall(vim.fn.jobstop, job_id)
  end
  if valid_win(state.winid) then
    pcall(vim.api.nvim_win_close, state.winid, true)
  end
  if valid_buf(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  state.winid = nil
  state.bufnr = nil
  state.origin_win = nil
  state.setup_done = false
end

return M
