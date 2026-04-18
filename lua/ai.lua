-- PandaVim AI - Main entry point
-- AI-powered coding assistant for Neovim

local M = {}

local config      = require('ai.config')
local ui          = require('ai.ui')
local inline_edit = require('ai.inline_edit')
local diff        = require('ai.diff')

--- Setup PandaVim AI
-- @param user_config table|nil: optional config overrides (see ai/config.lua)
function M.setup(user_config)
  -- 1. Config first — everything reads from it
  config.setup(user_config)

  -- 2. Diff highlight groups
  diff.setup_highlights()

  -- 3. UI (registers AIOpen/AIClose/AIToggle commands internally)
  ui.setup()

  -- 4. Inline edit (registers AIEdit command + <leader>ae keymap)
  inline_edit.setup()

  -- ── Extra commands ──────────────────────────────────────────────────────

  vim.api.nvim_create_user_command('AISwitchModel', function(args)
    if args.args ~= '' then
      config.set_model(args.args)
    else
      vim.notify('Usage: :AISwitchModel <model>', vim.log.levels.WARN)
    end
  end, { nargs = '?', desc = 'AI: switch model' })

  vim.api.nvim_create_user_command('AIProvider', function(args)
    if args.args ~= '' then
      config.set_provider(args.args)
    else
      vim.notify('Current provider: ' .. config.get_provider(), vim.log.levels.INFO)
    end
  end, { nargs = '?', desc = 'AI: get/set provider' })

  vim.api.nvim_create_user_command('AISkills', function()
    ui.process_command('/skills')
  end, { desc = 'AI: list skills in chat' })

  -- ── Global keymaps ──────────────────────────────────────────────────────

  local kmap = function(modes, lhs, rhs, desc)
    vim.keymap.set(modes, lhs, rhs, { noremap = true, silent = true, desc = desc })
  end

  -- Toggle sidebar (open + focus, or close)
  kmap('n', '<leader>ac', function() ui.toggle() end, 'AI: toggle sidebar')

  -- Focus navigation
  kmap({ 'n', 'i', 'v' }, '<C-Right>', function() ui.focus_input() end,  'AI: focus sidebar input')
  kmap({ 'n', 'i', 'v' }, '<C-Left>',  function() ui.focus_editor() end, 'AI: focus editor')

  -- Quick model/provider pickers (work without opening sidebar)
  kmap('n', '<leader>am', function()
    local models = config.get_models()
    vim.ui.select(models, { prompt = 'Select AI model:' }, function(choice)
      if choice then config.set_model(choice) end
    end)
  end, 'AI: pick model')

  kmap('n', '<leader>ap', function()
    require('ai.ui').process_command('/providers')
  end, 'AI: pick provider')

  -- Copy last assistant response to clipboard
  kmap('n', '<leader>ay', function()
    local text = ui.get_last_assistant_text()
    if text then
      vim.fn.setreg('+', text)
      ui.toast('Copied response to clipboard', 'success')
    else
      ui.toast('No assistant response to copy', 'warn')
    end
  end, 'AI: copy last response')

  -- Inline edit (visual selection or current line)
  -- (also registered by inline_edit.setup() as <leader>ae)

  vim.notify('PandaVim AI ready  (<leader>ac to open)', vim.log.levels.INFO)
end

return M
