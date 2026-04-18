-- ai/sessions.lua
-- Persist chat sessions to ~/.local/share/nvim/ai_sessions/<id>.json
-- Each file: { id, title, created_at, updated_at, messages, agent }

local M = {}

local SESSIONS_DIR = vim.fn.stdpath('data') .. '/ai_sessions'

-- ── helpers ──────────────────────────────────────────────────────────────────

local function ensure_dir()
  if vim.fn.isdirectory(SESSIONS_DIR) == 0 then
    vim.fn.mkdir(SESSIONS_DIR, 'p')
  end
end

local function session_path(id)
  return SESSIONS_DIR .. '/' .. id .. '.json'
end

-- Tiny JSON encoder (only needs to handle our message schema:
-- arrays of {role=string, content=string} plus top-level string/number fields).
local function json_encode(val, indent)
  indent = indent or 0
  local t = type(val)
  if t == 'nil' then
    return 'null'
  elseif t == 'boolean' then
    return tostring(val)
  elseif t == 'number' then
    return tostring(val)
  elseif t == 'string' then
    -- escape special chars
    local s = val
      :gsub('\\', '\\\\')
      :gsub('"',  '\\"')
      :gsub('\n', '\\n')
      :gsub('\r', '\\r')
      :gsub('\t', '\\t')
    return '"' .. s .. '"'
  elseif t == 'table' then
    -- array?
    local is_arr = (#val > 0)
    if is_arr then
      local items = {}
      for _, v in ipairs(val) do
        table.insert(items, json_encode(v, indent + 2))
      end
      return '[\n' .. string.rep(' ', indent+2)
        .. table.concat(items, ',\n' .. string.rep(' ', indent+2))
        .. '\n' .. string.rep(' ', indent) .. ']'
    else
      local parts = {}
      for k, v in pairs(val) do
        table.insert(parts,
          string.rep(' ', indent+2) .. '"' .. tostring(k) .. '": ' .. json_encode(v, indent+2))
      end
      table.sort(parts)
      return '{\n' .. table.concat(parts, ',\n')
        .. '\n' .. string.rep(' ', indent) .. '}'
    end
  end
  return 'null'
end

-- Minimal JSON decoder (handles our own output only).
-- We use vim.json.decode which ships with nvim 0.9+.
local function json_decode(s)
  local ok, val = pcall(vim.json.decode, s)
  if ok then return val end
  return nil
end

-- Derive a short title from the first user message.
local function derive_title(messages)
  for _, m in ipairs(messages) do
    if m.role == 'user' then
      local t = vim.trim(m.content or '')
      t = t:gsub('\n.*', '')          -- first line only
      if #t > 40 then t = t:sub(1,37) .. '…' end
      if t ~= '' then return t end
    end
  end
  return 'Untitled'
end

-- ── Public API ────────────────────────────────────────────────────────────────

--- Generate a new unique session ID (timestamp-based).
function M.new_id()
  return tostring(os.time()) .. '_' .. tostring(math.random(1000, 9999))
end

--- Save a session to disk.
-- @param id       string:   session ID
-- @param messages table:    array of {role,content}
-- @param agent    string|nil: active agent name
function M.save(id, messages, agent)
  ensure_dir()
  if not id or id == '' then return end
  local path = session_path(id)

  -- read existing to preserve created_at
  local created_at = os.time()
  local existing = M.load_raw(id)
  if existing then created_at = existing.created_at or created_at end

  local data = {
    id         = id,
    title      = derive_title(messages),
    created_at = created_at,
    updated_at = os.time(),
    agent      = agent or '',
    messages   = messages,
  }

  local f = io.open(path, 'w')
  if f then
    f:write(json_encode(data))
    f:close()
  end
end

--- Load raw session table from disk (or nil if not found).
function M.load_raw(id)
  local path = session_path(id)
  local f = io.open(path, 'r')
  if not f then return nil end
  local s = f:read('*a')
  f:close()
  return json_decode(s)
end

--- Load session messages (and agent) from disk.
-- @return messages table, agent string
function M.load(id)
  local data = M.load_raw(id)
  if not data then return {}, '' end
  return data.messages or {}, data.agent or ''
end

--- List all sessions, sorted newest-first.
-- @return table: array of { id, title, created_at, updated_at, agent }
function M.list()
  ensure_dir()
  local result = {}
  local files = vim.fn.glob(SESSIONS_DIR .. '/*.json', false, true)
  for _, path in ipairs(files) do
    local f = io.open(path, 'r')
    if f then
      local s = f:read('*a')
      f:close()
      local data = json_decode(s)
      if data and data.id then
        table.insert(result, {
          id         = data.id,
          title      = data.title or 'Untitled',
          created_at = data.created_at or 0,
          updated_at = data.updated_at or 0,
          agent      = data.agent or '',
        })
      end
    end
  end
  -- newest first
  table.sort(result, function(a, b) return a.updated_at > b.updated_at end)
  return result
end

--- Delete a session from disk.
function M.delete(id)
  local path = session_path(id)
  os.remove(path)
end

--- Format a timestamp as "Apr 14 15:23"
function M.fmt_time(ts)
  return os.date('%b %d %H:%M', ts)
end

return M
