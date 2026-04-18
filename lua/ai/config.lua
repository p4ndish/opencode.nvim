-- ai/config.lua
-- Persistent configuration at ~/.config/pandavim/config.json (like OpenCode's opencode.json).
-- Provider metadata (base_url, models, wire_format) is delegated to ai.providers.

local M = {}

local providers = require('ai.providers')

-- ── Persistent config file ───────────────────────────────────────────────────
local CONFIG_DIR  = vim.fn.expand('~/.config/pandavim')
local CONFIG_PATH = CONFIG_DIR .. '/config.json'

local function ensure_config_dir()
  if vim.fn.isdirectory(CONFIG_DIR) == 0 then
    vim.fn.mkdir(CONFIG_DIR, 'p')
  end
end

--- Load persistent config from disk. Returns table or empty table.
local function load_config_file()
  local f = io.open(CONFIG_PATH, 'r')
  if not f then return {} end
  local data = f:read('*a'); f:close()
  local ok, tbl = pcall(vim.fn.json_decode, data)
  if ok and type(tbl) == 'table' then return tbl end
  return {}
end

--- Save persistent config to disk.
local function save_config_file(data)
  ensure_config_dir()
  local f = io.open(CONFIG_PATH, 'w')
  if f then
    f:write(vim.fn.json_encode(data))
    f:close()
  end
end

-- ── Default configuration ──────────────────────────────────────────────────

local default_config = {
  provider        = 'openai',
  default_model   = 'gpt-4o',
  temperature     = 0.7,
  max_tokens      = 4096,
  -- system_prompt is now sourced from ai/prompts.lua (model-routed).
  -- Set this field only if you want to override the model-routed prompt entirely.
  system_prompt   = nil,
  show_timestamps = true,
  debug_mode      = false,  -- /debug toggle — writes API traffic to log
  tool_mode       = 'auto', -- 'auto' | 'native' | 'react' | 'off' — /tools
  theme           = {},     -- user color overrides
}

-- ── Runtime state ──────────────────────────────────────────────────────────

local user_config   = {}
local file_config   = {}  -- loaded from config.json
local listeners     = {}

-- ── Listener API ───────────────────────────────────────────────────────────

--- Register a callback fired whenever model or provider changes.
function M.add_listener(fn)
  table.insert(listeners, fn)
end

--- Fire all registered listeners.
function M.notify_listeners()
  for _, fn in ipairs(listeners) do
    local ok, err = pcall(fn)
    if not ok then
      vim.notify('ai.config listener error: ' .. tostring(err), vim.log.levels.WARN)
    end
  end
end

-- ── Persist helpers ────────────────────────────────────────────────────────

--- Save current runtime state to the config file.
local function persist()
  local data = {
    provider        = user_config.provider,
    model           = user_config.model,
    temperature     = user_config.temperature,
    system_prompt   = user_config.system_prompt,
    show_timestamps = user_config.show_timestamps,
    debug_mode      = user_config.debug_mode,
    tool_mode       = user_config.tool_mode,
    theme           = user_config.theme,
  }
  -- Only persist non-default values
  local out = {}
  for k, v in pairs(data) do
    if v ~= nil and v ~= default_config[k] then
      out[k] = v
    end
  end
  -- Always persist provider and model (even if default)
  out.provider = data.provider
  out.model    = data.model
  save_config_file(out)
end

-- ── Accessors ──────────────────────────────────────────────────────────────

--- Get the API key for a provider.
-- Priority: 1) secrets_file on the provider spec, 2) standard secrets path
-- (for builtins using the short API key flow), 3) env var named in api_key_env,
-- 4) fallback env var AI_<PROVIDER>_API_KEY.
function M.get_api_key(provider)
  provider = provider or M.get_provider()
  local spec = providers.get(provider)
  -- 1. secrets file (set when user enters a literal key via "Add provider")
  if spec and spec.secrets_file and spec.secrets_file ~= '' then
    local key = providers.read_secret(spec.secrets_file)
    if key and key ~= '' then return key end
  end
  -- 2. standard secrets path (for builtins that got a key via short flow)
  local secret = providers.check_secret(provider)
  if secret and secret ~= '' then return secret end
  -- 3. env var from spec
  local env_var = (spec and spec.api_key_env) or ('AI_' .. provider:upper() .. '_API_KEY')
  return os.getenv(env_var)
end

--- Get the base URL for a provider.
function M.get_base_url(provider)
  provider = provider or M.get_provider()
  local spec = providers.get(provider)
  return spec and spec.base_url or ''
end

--- Get the wire format for a provider: "openai" | "anthropic".
function M.get_wire_format(provider)
  provider = provider or M.get_provider()
  local spec = providers.get(provider)
  return (spec and spec.wire_format) or 'openai'
end

--- Get available model IDs for a provider as a flat list of strings.
function M.get_models(provider)
  provider = provider or M.get_provider()
  local spec = providers.get(provider)
  return providers.model_ids(spec)
end

--- Get the human-readable display name for the current model.
function M.get_model_display_name(model_id, provider)
  model_id = model_id or M.get_model()
  provider = provider or M.get_provider()
  local spec = providers.get(provider)
  return providers.model_name(spec, model_id)
end

--- Get current model name.
function M.get_model()
  return user_config.model or user_config.default_model or default_config.default_model
end

--- Set current model and notify listeners. Persists to config file.
function M.set_model(model)
  user_config.model = model
  persist()
  vim.notify('AI model: ' .. model, vim.log.levels.INFO)
  M.notify_listeners()
end

--- Get current provider name.
function M.get_provider()
  return user_config.provider or default_config.provider
end

--- Set current provider and notify listeners. Persists to config file.
function M.set_provider(provider)
  user_config.provider = provider
  persist()
  vim.notify('AI provider: ' .. provider, vim.log.levels.INFO)
  M.notify_listeners()
end

--- Get system prompt override (usually nil — prompts.lua handles the default).
function M.get_system_prompt()
  return user_config.system_prompt  -- nil is OK — UI falls through to prompts.lua
end

--- Get debug mode toggle.
function M.get_debug_mode()
  if user_config.debug_mode ~= nil then return user_config.debug_mode end
  return default_config.debug_mode
end

function M.set_debug_mode(val)
  user_config.debug_mode = val and true or false
  persist()
end

--- Get tool mode: 'auto' | 'native' | 'react' | 'off'.
function M.get_tool_mode()
  return user_config.tool_mode or default_config.tool_mode
end

function M.set_tool_mode(mode)
  if mode ~= 'auto' and mode ~= 'native' and mode ~= 'react' and mode ~= 'off' then
    mode = 'auto'
  end
  user_config.tool_mode = mode
  persist()
end

--- Get show_timestamps preference.
function M.get_show_timestamps()
  if user_config.show_timestamps ~= nil then return user_config.show_timestamps end
  return default_config.show_timestamps
end

--- Set show_timestamps preference. Persists to config file.
function M.set_show_timestamps(val)
  user_config.show_timestamps = val
  persist()
end

--- Get theme overrides table.
function M.get_theme()
  return user_config.theme or {}
end

--- Get full merged configuration table.
function M.get_config()
  return user_config
end

-- ── Setup ──────────────────────────────────────────────────────────────────

--- Merge config: defaults → config.json → user-supplied opts.
-- @param cfg table|nil: user-supplied config from lazy.nvim setup()
function M.setup(cfg)
  providers.setup()  -- load persisted custom providers first

  -- Load persistent config file
  file_config = load_config_file()

  -- Merge: defaults → file config → user opts
  user_config = vim.tbl_deep_extend('force', default_config, file_config, cfg or {})

  -- Allow user config to register extra providers inline:
  if cfg and cfg.providers then
    for _, spec in ipairs(cfg.providers) do
      providers.register(spec)
    end
  end

  local provider = M.get_provider()
  local api_key  = M.get_api_key(provider)
  if not api_key then
    vim.notify(
      'PandaVim AI: No API key for "' .. provider .. '".'
        .. ' Set ' .. ((providers.get(provider) and providers.get(provider).api_key_env)
            or ('AI_' .. provider:upper() .. '_API_KEY')) .. '.',
      vim.log.levels.WARN
    )
  end
end

return M
