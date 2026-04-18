-- ai/system.lua
-- Assembles the final system message sent to the model.
--
-- Layers (joined with blank lines):
--   1. Base prompt         — agent override OR model-routed prompt (prompts.lua)
--   2. Environment block   — cwd, git, platform, editor, date
--   3. Project instructions — PANDAVIM.md | AGENTS.md | CLAUDE.md (first match)
--   4. ReAct instructions  — appended when tool_mode == 'react'
--
-- Mirrors OpenCode's system.ts build logic but adapted for our environment.

local M = {}

local prompts = require('ai.prompts')

-- Supported project instruction files (first existing one wins).
local PROJECT_FILES = { 'PANDAVIM.md', 'AGENTS.md', 'CLAUDE.md' }

-- Max bytes of a project instruction file to include (truncated with warning).
local MAX_PROJECT_BYTES = 51200  -- 50 KB

-- ── Environment block ─────────────────────────────────────────────────────

--- Build the dynamic <env> block that describes the user's environment.
-- OpenCode injects the same kind of block on every request so the model
-- knows cwd, git status, platform, and date.
-- @param model_id string — the model being used (displayed in the block)
-- @return string
function M.env_block(model_id)
  local cwd     = vim.fn.getcwd()
  local is_git  = vim.fn.isdirectory(cwd .. '/.git') == 1
  local uname   = vim.loop.os_uname() or {}
  local plat    = (uname.sysname or 'unknown'):lower()
  local nvim_v  = vim.version()
  local nvim_s  = nvim_v and (nvim_v.major .. '.' .. nvim_v.minor .. '.' .. (nvim_v.patch or 0))
                         or 'unknown'

  return string.format([[
You are powered by the model: %s

Here is some useful information about the environment you are running in:
<env>
  Working directory: %s
  Is git repo: %s
  Platform: %s
  Editor: Neovim %s
  Today's date: %s
</env>]],
    model_id or 'unknown',
    cwd,
    is_git and 'yes' or 'no',
    plat,
    nvim_s,
    os.date('%a %b %d %Y'))
end

-- ── Project instructions ──────────────────────────────────────────────────

--- Load project-level instructions from PANDAVIM.md / AGENTS.md / CLAUDE.md.
-- First existing file wins (in the order above). Returns nil if none exist.
-- @return string|nil content, string|nil filename
function M.load_project_instructions()
  local cwd = vim.fn.getcwd()
  for _, name in ipairs(PROJECT_FILES) do
    local path = cwd .. '/' .. name
    local stat = vim.loop.fs_stat(path)
    if stat and stat.type == 'file' then
      local f = io.open(path, 'r')
      if f then
        local content = f:read('*a') or ''
        f:close()
        if #content > MAX_PROJECT_BYTES then
          content = content:sub(1, MAX_PROJECT_BYTES)
            .. '\n\n... (truncated at ' .. MAX_PROJECT_BYTES .. ' bytes)'
        end
        if content ~= '' then
          return content, name
        end
      end
    end
  end
  return nil, nil
end

--- Return just the project file name (for UI footer badge), nil if none.
function M.get_project_file()
  local _, name = M.load_project_instructions()
  return name
end

-- ── Build ─────────────────────────────────────────────────────────────────

--- Build the full system message.
-- @param opts table:
--   model_id      string  — the model being used (required for routing)
--   agent_system  string? — agent override prompt (replaces base)
--   tool_mode     string? — 'native' | 'react' | 'off' | 'auto' (default 'native')
-- @return string
function M.build(opts)
  opts = opts or {}
  local model_id     = opts.model_id or ''
  local agent_system = opts.agent_system
  local tool_mode    = opts.tool_mode or 'native'

  local parts = {}

  -- 1. Base prompt: agent override OR model-routed
  if agent_system and agent_system ~= '' then
    table.insert(parts, agent_system)
  else
    table.insert(parts, prompts.get(model_id))
  end

  -- 2. Environment block
  table.insert(parts, M.env_block(model_id))

  -- 3. Project instructions
  local instructions, name = M.load_project_instructions()
  if instructions then
    table.insert(parts, string.format(
      '# Project instructions (from %s)\n\n%s', name, instructions))
  end

  -- 4. ReAct instructions (only when in ReAct fallback mode)
  if tool_mode == 'react' then
    local ok, react = pcall(require, 'ai.react')
    if ok and react.INSTRUCTIONS then
      table.insert(parts, react.INSTRUCTIONS)
    end
  elseif tool_mode == 'off' then
    -- When tools are off, explicitly tell the model not to call them
    table.insert(parts,
      '# Tool Use\n\nTools are currently DISABLED. Do not emit tool calls. '
      .. 'Answer in plain text only.')
  end

  return table.concat(parts, '\n\n')
end

return M
