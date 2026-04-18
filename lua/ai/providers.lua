-- ai/providers.lua
-- Generic provider registry: builtin + user-registered, persisted to JSON.
--
-- Each provider spec:
--   name         string  — unique identifier (e.g. "groq", "ollama")
--   display_name string  — human-readable label (e.g. "Groq")
--   base_url     string  — e.g. "https://api.groq.com/openai/v1"
--   api_key_env  string  — env var name (e.g. "GROQ_API_KEY") — OR nil if secrets_file used
--   secrets_file string  — path to file containing the raw API key (chmod 0o600) — OR nil
--   wire_format  string  — "openai" | "anthropic"
--   models       table   — list of {id=string, name=string} OR plain strings (back-compat)
--   builtin      bool    — true = cannot be deleted

local M = {}

-- ── Persistence ───────────────────────────────────────────────────────────────

local DATA_DIR     = vim.fn.stdpath('data') .. '/ai_providers'
local DATA_FILE    = DATA_DIR .. '/providers.json'
local SECRETS_DIR  = vim.fn.stdpath('data') .. '/ai_secrets'

local function ensure_dir()
  if vim.fn.isdirectory(DATA_DIR) == 0 then
    vim.fn.mkdir(DATA_DIR, 'p')
  end
end

local function ensure_secrets_dir()
  if vim.fn.isdirectory(SECRETS_DIR) == 0 then
    vim.fn.mkdir(SECRETS_DIR, 'p')
    -- chmod 700 so only the owner can list/enter the directory
    vim.fn.system('chmod 700 ' .. vim.fn.shellescape(SECRETS_DIR))
  end
end

-- ── Built-in providers (immutable) ───────────────────────────────────────────
-- Source: OpenCode's models.dev registry (~111 providers)
-- Popular providers have models pre-configured; others are OpenAI-compatible
-- with empty model lists (users enter model IDs via /model or config).

-- Helper to define an OpenAI-compatible provider concisely
local function oai(id, name, url, env, models)
  return { name = id, display_name = name, base_url = url, api_key_env = env,
           wire_format = 'openai', models = models or {}, builtin = true }
end
local function anth(id, name, url, env, models)
  return { name = id, display_name = name, base_url = url, api_key_env = env,
           wire_format = 'anthropic', models = models or {}, builtin = true }
end

local BUILTIN = {
  -- ── Popular (shown first in "Popular" category) ─────────────────────────
  {
    name = 'openai', display_name = 'OpenAI',
    base_url = 'https://api.openai.com/v1', api_key_env = 'OPENAI_API_KEY',
    wire_format = 'openai', builtin = true,
    models = {
      { id = 'gpt-4o',        name = 'GPT-4o' },
      { id = 'gpt-4o-mini',   name = 'GPT-4o Mini' },
      { id = 'o3-mini',       name = 'o3-mini' },
      { id = 'gpt-4-turbo',   name = 'GPT-4 Turbo' },
      { id = 'gpt-3.5-turbo', name = 'GPT-3.5 Turbo' },
    },
  },
  {
    name = 'anthropic', display_name = 'Anthropic',
    base_url = 'https://api.anthropic.com/v1', api_key_env = 'ANTHROPIC_API_KEY',
    wire_format = 'anthropic', builtin = true,
    models = {
      { id = 'claude-opus-4-5',            name = 'Claude Opus 4.5' },
      { id = 'claude-sonnet-4-5',          name = 'Claude Sonnet 4.5' },
      { id = 'claude-3-5-haiku-20241022',  name = 'Claude Haiku 3.5' },
      { id = 'claude-3-5-sonnet-20241022', name = 'Claude Sonnet 3.5' },
      { id = 'claude-3-opus-20240229',     name = 'Claude Opus 3' },
    },
  },
  {
    name = 'google', display_name = 'Google',
    base_url = 'https://generativelanguage.googleapis.com/v1beta', api_key_env = 'GEMINI_API_KEY',
    wire_format = 'openai', builtin = true,
    models = {
      { id = 'gemini-2.5-pro',   name = 'Gemini 2.5 Pro' },
      { id = 'gemini-2.5-flash', name = 'Gemini 2.5 Flash' },
      { id = 'gemini-2.0-flash', name = 'Gemini 2.0 Flash' },
    },
  },
  {
    name = 'groq', display_name = 'Groq',
    base_url = 'https://api.groq.com/openai/v1', api_key_env = 'GROQ_API_KEY',
    wire_format = 'openai', builtin = true,
    models = {
      { id = 'llama-3.3-70b-versatile', name = 'Llama 3.3 70B' },
      { id = 'llama-3.1-8b-instant',    name = 'Llama 3.1 8B' },
      { id = 'mixtral-8x7b-32768',      name = 'Mixtral 8x7B' },
    },
  },
  {
    name = 'mistral', display_name = 'Mistral',
    base_url = 'https://api.mistral.ai/v1', api_key_env = 'MISTRAL_API_KEY',
    wire_format = 'openai', builtin = true,
    models = {
      { id = 'mistral-large-latest', name = 'Mistral Large' },
      { id = 'mistral-small-latest', name = 'Mistral Small' },
      { id = 'codestral-latest',     name = 'Codestral' },
    },
  },
  {
    name = 'deepseek', display_name = 'DeepSeek',
    base_url = 'https://api.deepseek.com', api_key_env = 'DEEPSEEK_API_KEY',
    wire_format = 'openai', builtin = true,
    models = {
      { id = 'deepseek-chat',     name = 'DeepSeek V3' },
      { id = 'deepseek-reasoner', name = 'DeepSeek R1' },
    },
  },

  -- ── Other providers (A-Z, from OpenCode's models.dev registry) ──────────
  oai('302ai',          '302.AI',                  'https://api.302.ai/v1',                                     '302AI_API_KEY'),
  oai('abacus',         'Abacus',                  'https://routellm.abacus.ai/v1',                             'ABACUS_API_KEY'),
  oai('alibaba',        'Alibaba',                 'https://dashscope-intl.aliyuncs.com/compatible-mode/v1',     'DASHSCOPE_API_KEY'),
  oai('alibaba-cn',     'Alibaba (China)',          'https://dashscope.aliyuncs.com/compatible-mode/v1',          'DASHSCOPE_API_KEY'),
  oai('amazon-bedrock', 'Amazon Bedrock',           'https://bedrock-runtime.us-east-1.amazonaws.com/v1',         'AWS_ACCESS_KEY_ID'),
  oai('azure',          'Azure OpenAI',             'https://YOUR_RESOURCE.openai.azure.com/v1',                  'AZURE_API_KEY'),
  oai('baseten',        'Baseten',                  'https://inference.baseten.co/v1',                            'BASETEN_API_KEY'),
  oai('berget',         'Berget.AI',                'https://api.berget.ai/v1',                                  'BERGET_API_KEY'),
  oai('cerebras',       'Cerebras',                 'https://api.cerebras.ai/v1',                                'CEREBRAS_API_KEY'),
  oai('chutes',         'Chutes',                   'https://llm.chutes.ai/v1',                                  'CHUTES_API_KEY'),
  oai('clarifai',       'Clarifai',                 'https://api.clarifai.com/v2/ext/openai/v1',                 'CLARIFAI_PAT'),
  oai('cohere',         'Cohere',                   'https://api.cohere.com/v2',                                 'COHERE_API_KEY',
    { { id = 'command-r-plus', name = 'Command R+' }, { id = 'command-r', name = 'Command R' } }),
  oai('cortecs',        'Cortecs',                  'https://api.cortecs.ai/v1',                                 'CORTECS_API_KEY'),
  oai('deepinfra',      'Deep Infra',               'https://api.deepinfra.com/v1/openai',                       'DEEPINFRA_API_KEY'),
  oai('dinference',     'DInference',               'https://api.dinference.com/v1',                             'DINFERENCE_API_KEY'),
  oai('evroc',          'evroc',                    'https://models.think.evroc.com/v1',                         'EVROC_API_KEY'),
  oai('fastrouter',     'FastRouter',               'https://go.fastrouter.ai/api/v1',                           'FASTROUTER_API_KEY'),
  oai('fireworks',      'Fireworks AI',             'https://api.fireworks.ai/inference/v1',                      'FIREWORKS_API_KEY',
    { { id = 'accounts/fireworks/models/llama-v3p3-70b-instruct', name = 'Llama 3.3 70B' } }),
  oai('friendli',       'Friendli',                 'https://api.friendli.ai/serverless/v1',                     'FRIENDLI_TOKEN'),
  oai('github-copilot', 'GitHub Copilot',           'https://api.githubcopilot.com',                             'GITHUB_TOKEN'),
  oai('github-models',  'GitHub Models',            'https://models.github.ai/inference',                        'GITHUB_TOKEN'),
  oai('google-vertex',  'Google Vertex',            'https://us-central1-aiplatform.googleapis.com/v1',          'GOOGLE_APPLICATION_CREDENTIALS'),
  oai('helicone',       'Helicone',                 'https://ai-gateway.helicone.ai/v1',                         'HELICONE_API_KEY'),
  oai('hpc-ai',         'HPC-AI',                   'https://api.hpc-ai.com/inference/v1',                       'HPC_AI_API_KEY'),
  oai('huggingface',    'Hugging Face',             'https://router.huggingface.co/v1',                          'HF_TOKEN'),
  oai('inception',      'Inception',                'https://api.inceptionlabs.ai/v1',                           'INCEPTION_API_KEY'),
  oai('inference',      'Inference',                'https://inference.net/v1',                                   'INFERENCE_API_KEY'),
  oai('io-net',         'IO.NET',                   'https://api.intelligence.io.solutions/api/v1',              'IOINTELLIGENCE_API_KEY'),
  oai('kilo',           'Kilo Gateway',             'https://api.kilo.ai/api/gateway',                           'KILO_API_KEY'),
  anth('kimi',          'Kimi For Coding',          'https://api.kimi.com/coding/v1',                            'KIMI_API_KEY'),
  oai('llama',          'Llama',                    'https://api.llama.com/compat/v1',                           'LLAMA_API_KEY'),
  oai('lmstudio',       'LM Studio',               'http://127.0.0.1:1234/v1',                                  'LMSTUDIO_API_KEY'),
  oai('meganova',       'Meganova',                 'https://api.meganova.ai/v1',                                'MEGANOVA_API_KEY'),
  anth('minimax',       'MiniMax',                  'https://api.minimax.io/anthropic/v1',                       'MINIMAX_API_KEY'),
  oai('mixlayer',       'Mixlayer',                 'https://models.mixlayer.ai/v1',                             'MIXLAYER_API_KEY'),
  oai('modelscope',     'ModelScope',               'https://api-inference.modelscope.cn/v1',                    'MODELSCOPE_API_KEY'),
  oai('moonshotai',     'Moonshot AI',              'https://api.moonshot.ai/v1',                                'MOONSHOT_API_KEY'),
  oai('morph',          'Morph',                    'https://api.morphllm.com/v1',                               'MORPH_API_KEY'),
  oai('nano-gpt',       'NanoGPT',                  'https://nano-gpt.com/api/v1',                               'NANO_GPT_API_KEY'),
  oai('nebius',         'Nebius',                   'https://api.tokenfactory.nebius.com/v1',                    'NEBIUS_API_KEY'),
  oai('novita-ai',      'NovitaAI',                'https://api.novita.ai/openai',                              'NOVITA_API_KEY'),
  oai('nvidia',         'Nvidia',                   'https://integrate.api.nvidia.com/v1',                       'NVIDIA_API_KEY'),
  oai('ollama',         'Ollama',                   'http://localhost:11434/v1',                                  'OLLAMA_API_KEY',
    { { id = 'llama3.3', name = 'Llama 3.3' }, { id = 'qwen2.5', name = 'Qwen 2.5' }, { id = 'codellama', name = 'Code Llama' } }),
  oai('ollama-cloud',   'Ollama Cloud',             'https://ollama.com/v1',                                     'OLLAMA_API_KEY'),
  oai('openrouter',     'OpenRouter',               'https://openrouter.ai/api/v1',                              'OPENROUTER_API_KEY',
    { { id = 'anthropic/claude-sonnet-4', name = 'Claude Sonnet 4' }, { id = 'openai/gpt-4o', name = 'GPT-4o' },
      { id = 'google/gemini-2.5-pro', name = 'Gemini 2.5 Pro' } }),
  oai('ovhcloud',       'OVHcloud',                 'https://oai.endpoints.kepler.ai.cloud.ovh.net/v1',          'OVHCLOUD_API_KEY'),
  oai('perplexity',     'Perplexity',               'https://api.perplexity.ai',                                 'PERPLEXITY_API_KEY',
    { { id = 'sonar-pro', name = 'Sonar Pro' }, { id = 'sonar', name = 'Sonar' } }),
  oai('poe',            'Poe',                      'https://api.poe.com/v1',                                    'POE_API_KEY'),
  oai('requesty',       'Requesty',                 'https://router.requesty.ai/v1',                             'REQUESTY_API_KEY'),
  oai('scaleway',       'Scaleway',                 'https://api.scaleway.ai/v1',                                'SCALEWAY_API_KEY'),
  oai('siliconflow',    'SiliconFlow',              'https://api.siliconflow.com/v1',                            'SILICONFLOW_API_KEY'),
  oai('siliconflow-cn', 'SiliconFlow (China)',       'https://api.siliconflow.cn/v1',                             'SILICONFLOW_CN_API_KEY'),
  oai('stepfun',        'StepFun',                  'https://api.stepfun.com/v1',                                'STEPFUN_API_KEY'),
  oai('synthetic',      'Synthetic',                'https://api.synthetic.new/openai/v1',                       'SYNTHETIC_API_KEY'),
  oai('together',       'Together AI',              'https://api.together.xyz/v1',                               'TOGETHER_API_KEY',
    { { id = 'meta-llama/Llama-3.3-70B-Instruct-Turbo', name = 'Llama 3.3 70B' }, { id = 'deepseek-ai/DeepSeek-R1', name = 'DeepSeek R1' } }),
  oai('upstage',        'Upstage',                  'https://api.upstage.ai/v1/solar',                          'UPSTAGE_API_KEY'),
  oai('venice',         'Venice AI',                'https://api.venice.ai/api/v1',                              'VENICE_API_KEY'),
  oai('vivgrid',        'Vivgrid',                  'https://api.vivgrid.com/v1',                                'VIVGRID_API_KEY'),
  oai('vultr',          'Vultr',                    'https://api.vultrinference.com/v1',                         'VULTR_API_KEY'),
  oai('wandb',          'Weights & Biases',         'https://api.inference.wandb.ai/v1',                         'WANDB_API_KEY'),
  oai('xai',            'xAI',                      'https://api.x.ai/v1',                                      'XAI_API_KEY',
    { { id = 'grok-3', name = 'Grok 3' }, { id = 'grok-3-mini', name = 'Grok 3 Mini' } }),
  oai('zhipuai',        'Zhipu AI',                 'https://open.bigmodel.cn/api/paas/v4',                      'ZHIPU_API_KEY'),
}

-- ── Runtime state ─────────────────────────────────────────────────────────────

local custom    = {}  -- custom providers keyed by name
local listeners = {}  -- change callbacks

-- ── Helpers ───────────────────────────────────────────────────────────────────

local function notify_listeners()
  for _, fn in ipairs(listeners) do pcall(fn) end
end

--- Minimal JSON encoder (handles nested tables/strings/booleans/numbers/nil)
local function json_encode(val)
  local t = type(val)
  if val == nil       then return 'null' end
  if t == 'boolean'   then return tostring(val) end
  if t == 'number'    then return tostring(val) end
  if t == 'string'    then
    return '"' .. val
      :gsub('\\', '\\\\'):gsub('"', '\\"')
      :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t') .. '"'
  end
  if t == 'table' then
    if #val > 0 then
      local items = {}
      for _, v in ipairs(val) do table.insert(items, json_encode(v)) end
      return '[' .. table.concat(items, ',') .. ']'
    else
      local pairs_out = {}
      for k, v in pairs(val) do
        if type(k) == 'string' then
          table.insert(pairs_out, json_encode(k) .. ':' .. json_encode(v))
        end
      end
      return '{' .. table.concat(pairs_out, ',') .. '}'
    end
  end
  return 'null'
end

-- ── Model normalisation ───────────────────────────────────────────────────────
-- Internally models are always {id=string, name=string}.
-- For backward compat we accept plain strings too (id == name in that case).

local function norm_model(m)
  if type(m) == 'string' then return { id = m, name = m } end
  return { id = m.id or m.name or '', name = m.name or m.id or '' }
end

--- Return a flat list of model ID strings for a provider spec (used by config.get_models).
function M.model_ids(spec)
  if not spec or not spec.models then return {} end
  local ids = {}
  for _, m in ipairs(spec.models) do
    local nm = norm_model(m)
    if nm.id ~= '' then table.insert(ids, nm.id) end
  end
  return ids
end

--- Return the human-readable display name for a model id within a provider.
-- Falls back to the id itself if not found.
function M.model_name(spec, model_id)
  if not spec or not spec.models then return model_id end
  for _, m in ipairs(spec.models) do
    local nm = norm_model(m)
    if nm.id == model_id then return nm.name end
  end
  return model_id
end

-- ── Secrets file helpers ──────────────────────────────────────────────────────

--- Write a raw API key to a per-provider secrets file (chmod 0o600).
-- Returns the file path on success, or nil + error string.
function M.write_secret(provider_id, key)
  ensure_secrets_dir()
  local path = SECRETS_DIR .. '/' .. provider_id .. '.key'
  local f = io.open(path, 'w')
  if not f then return nil, 'Cannot write secrets file: ' .. path end
  f:write(key)
  f:close()
  vim.fn.system('chmod 600 ' .. vim.fn.shellescape(path))
  return path, nil
end

--- Read a raw API key from a secrets file. Returns key string or nil.
function M.read_secret(path)
  if not path or path == '' then return nil end
  local f = io.open(path, 'r')
  if not f then return nil end
  local key = f:read('*a'); f:close()
  return vim.trim(key or '')
end

--- Check the standard secrets path for a provider ID.
-- Returns the key if found, nil otherwise.
-- Used as a fallback for builtin providers that got a key via the short flow.
function M.check_secret(provider_id)
  if not provider_id or provider_id == '' then return nil end
  local path = SECRETS_DIR .. '/' .. provider_id .. '.key'
  return M.read_secret(path)
end

-- ── Persistence ───────────────────────────────────────────────────────────────

local function save()
  ensure_dir()
  local list = {}
  for _, p in pairs(custom) do
    -- Normalise models to {id, name} objects before saving
    local saved = vim.deepcopy(p)
    local norm_models = {}
    for _, m in ipairs(saved.models or {}) do
      table.insert(norm_models, norm_model(m))
    end
    saved.models = norm_models
    table.insert(list, saved)
  end
  local f = io.open(DATA_FILE, 'w')
  if not f then return end
  f:write(json_encode(list))
  f:close()
end

local function load()
  custom = {}
  local f = io.open(DATA_FILE, 'r')
  if not f then return end
  local raw = f:read('*a'); f:close()
  if not raw or raw == '' then return end
  local ok, data = pcall(vim.json.decode, raw)
  if not ok or type(data) ~= 'table' then return end
  for _, p in ipairs(data) do
    if type(p) == 'table' and type(p.name) == 'string' and p.name ~= '' then
      p.builtin = nil
      -- Normalise models on load
      local norm_models = {}
      for _, m in ipairs(p.models or {}) do
        table.insert(norm_models, norm_model(m))
      end
      p.models = norm_models
      custom[p.name] = p
    end
  end
end

-- ── Public API ────────────────────────────────────────────────────────────────

function M.add_listener(fn)
  table.insert(listeners, fn)
end

--- Return ordered list of all providers: builtins first, then custom alphabetically.
function M.list()
  local out = {}
  for _, p in ipairs(BUILTIN) do table.insert(out, p) end
  local names = {}
  for name in pairs(custom) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do table.insert(out, custom[name]) end
  return out
end

--- Get a provider spec by name, or nil.
function M.get(name)
  if not name then return nil end
  for _, p in ipairs(BUILTIN) do
    if p.name == name then return p end
  end
  return custom[name]
end

--- Register (add or update) a custom provider.
-- spec fields: name, display_name?, base_url, wire_format,
--              api_key_env? OR secrets_file?, models? (list of {id,name} or strings)
function M.register(spec)
  assert(type(spec.name) == 'string' and spec.name ~= '',         'provider needs .name')
  assert(type(spec.base_url) == 'string' and spec.base_url ~= '', 'provider needs .base_url')
  assert(spec.wire_format == 'openai' or spec.wire_format == 'anthropic',
    'wire_format must be "openai" or "anthropic"')
  for _, p in ipairs(BUILTIN) do
    if p.name == spec.name then
      vim.notify('AI: cannot overwrite builtin provider "' .. spec.name .. '"', vim.log.levels.WARN)
      return
    end
  end
  spec.builtin      = nil
  spec.display_name = spec.display_name or spec.name
  -- Normalise models
  local norm_models = {}
  for _, m in ipairs(spec.models or {}) do
    table.insert(norm_models, norm_model(m))
  end
  spec.models = norm_models
  custom[spec.name] = spec
  save()
  notify_listeners()
end

--- Delete a custom provider by name. Builtins are protected.
function M.delete(name)
  for _, p in ipairs(BUILTIN) do
    if p.name == name then
      vim.notify('AI: cannot delete builtin provider "' .. name .. '"', vim.log.levels.WARN)
      return
    end
  end
  if not custom[name] then
    vim.notify('AI: provider not found: ' .. name, vim.log.levels.WARN)
    return
  end
  custom[name] = nil
  save()
  notify_listeners()
end

--- Initialise: load persisted custom providers. Call once at startup.
function M.setup()
  load()
end

return M
