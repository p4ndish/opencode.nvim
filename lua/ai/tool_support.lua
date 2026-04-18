-- ai/tool_support.lua
-- Tracks which providers / models support native OpenAI-style function calling
-- vs. need the ReAct XML fallback.
--
-- Decision flow (effective_mode):
--   1. If /tools off       → 'off'      (no tools sent at all)
--   2. If /tools native    → 'native'   (always native)
--   3. If /tools react     → 'react'    (always ReAct fallback)
--   4. If /tools auto (default):
--      a. Model matches REACT_ONLY_MODELS → 'react'
--      b. Provider in NATIVE_PROVIDERS    → 'native'
--      c. Provider auto-detected 'none'   → 'react'
--      d. Otherwise                        → 'native' (optimistic, falls back
--         to 'react' if detect_from_response sees a non-tool response)

local M = {}

-- ── Known-good providers (support OpenAI tools[] natively) ────────────────
M.NATIVE_PROVIDERS = {
  openai     = true,
  anthropic  = true,
  google     = true,
  groq       = true,
  mistral    = true,
  deepseek   = true,
  xai        = true,
  fireworks  = true,
  cohere     = true,
  openrouter = true,  -- varies by underlying model but usually OK
  together   = true,
  cerebras   = true,
  perplexity = true,
  nvidia     = true,
  ['github-copilot'] = true,
  ['github-models']  = true,
}

-- ── Models known to NOT support native tool calling ───────────────────────
-- Lua patterns. Checked against the lowercased model ID.
M.REACT_ONLY_MODELS = {
  'llama%-2',           -- Llama 2 series
  'llama%-3%-8b',       -- Small Llama 3 often struggles
  'qwen%-chat$',        -- Some older Qwen chat variants
  'gemma%-2b',          -- Tiny Gemma
  'phi%-2',             -- Phi-2
}

-- ── Forced mode (from /tools command or config.lua) ───────────────────────
-- nil / 'auto' = auto-detect, otherwise one of: 'native', 'react', 'off'.
local forced_mode = nil

-- ── Auto-detected cache: per-provider override ────────────────────────────
-- When we detect a provider silently ignores tools[], mark it here so we
-- switch to ReAct on subsequent calls. Keyed by provider_id.
local auto_detected = {}  -- { [provider_id] = 'react' | 'native' }

-- ── API ───────────────────────────────────────────────────────────────────

--- Set or clear the forced tool mode.
-- @param mode 'native'|'react'|'off'|'auto'|nil
function M.force(mode)
  if mode == 'auto' or mode == nil then
    forced_mode = nil
  else
    forced_mode = mode
  end
end

--- Return the current forced mode or 'auto' if unset.
function M.get_forced()
  return forced_mode or 'auto'
end

--- Mark a provider as definitely NOT supporting native tools.
-- Triggers fallback to ReAct on subsequent calls.
function M.mark_no_tools(provider_id)
  if provider_id then auto_detected[provider_id] = 'react' end
end

--- Mark a provider as definitely supporting native tools (clears any prior
-- no-tools detection). Called after we see a working tool_calls response.
function M.mark_native(provider_id)
  if provider_id then auto_detected[provider_id] = 'native' end
end

--- Clear all auto-detection. Called e.g. when user switches providers.
function M.reset_detection()
  auto_detected = {}
end

--- Compute the effective tool mode for a given provider + model.
-- Consults forced_mode, auto_detected cache, and static registries.
-- @param provider_id string
-- @param model_id    string
-- @return 'native'|'react'|'off'
function M.effective_mode(provider_id, model_id)
  -- Forced mode wins
  if forced_mode == 'off' or forced_mode == 'native' or forced_mode == 'react' then
    return forced_mode
  end

  -- Auto-detection from a previous request
  if provider_id and auto_detected[provider_id] then
    return auto_detected[provider_id]
  end

  -- Model-level blocklist (matches on model ID patterns)
  local mid = (model_id or ''):lower()
  for _, pat in ipairs(M.REACT_ONLY_MODELS) do
    if mid:match(pat) then return 'react' end
  end

  -- Known-good provider → native
  if provider_id and M.NATIVE_PROVIDERS[provider_id] then
    return 'native'
  end

  -- Unknown provider (custom endpoints) → optimistic native.
  -- If it fails, detect_from_response will flip it to 'react' next turn.
  return 'native'
end

--- Heuristic called after a turn completes to decide whether a provider
-- silently ignored the tools[] parameter. If the model produced lots of
-- text output (including code blocks suggesting file ops) but no tool_calls
-- and no ReAct blocks, we switch that provider to 'react' mode.
-- @param provider_id  string
-- @param response_text string
-- @param had_tool_calls boolean — whether the turn produced any tool calls
--        (either native OR ReAct)
function M.detect_from_response(provider_id, response_text, had_tool_calls)
  if not provider_id then return end

  if had_tool_calls then
    -- Clear any prior bad-state
    auto_detected[provider_id] = 'native'
    return
  end

  -- Only auto-switch if we haven't already decided
  if auto_detected[provider_id] then return end

  -- Heuristic: response contains a triple-backtick code block AND words
  -- that strongly imply the model was asked to do file/shell work.
  local t = (response_text or ''):lower()
  if not t:match('```') then return end

  -- Words that suggest the user asked for action and the model described
  -- it instead of doing it
  local action_hints = {
    'create a', 'create the', 'write the', 'write a',
    'save this', 'save the', 'save it', 'save into',
    'you can create', 'you can run', 'you can write',
    "here's how", 'here is how',
    'open your editor', 'open a terminal', 'in your terminal',
    'copy this', 'paste this',
    'run the following', 'execute the following',
  }
  for _, hint in ipairs(action_hints) do
    if t:find(hint, 1, true) then
      auto_detected[provider_id] = 'react'
      return
    end
  end
end

--- For UI badge / debugging: return a human-friendly label for the current
-- effective mode.
function M.label(provider_id, model_id)
  local m = M.effective_mode(provider_id, model_id)
  if m == 'off'    then return 'Tools: OFF' end
  if m == 'react'  then return 'Tools: ReAct' end
  if forced_mode == 'native' then return 'Tools: Native (forced)' end
  return 'Tools: Native'
end

return M
