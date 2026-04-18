-- ai/diff.lua
-- Myers diff algorithm + virtual-text inline diff for the editor buffer.
--
-- Inline diff layout (shown directly in the real editor buffer):
--
--   sign │  original line 1          ← unchanged, no mark
--   -    │  old line being removed   ← strikethrough + red virt_line below
--   +    │  new line added           ← green highlight on real buffer line
--   sign │  original line 2          ← unchanged
--
-- The diff is non-destructive: deleted lines are shown as virt_lines
-- (virtual text above the cursor position), added lines are highlighted
-- in-place after the content is written into the buffer.

local M = {}

-- ── Highlight groups ─────────────────────────────────────────────────────────

function M.setup_highlights()
  local function hl(name, opts) vim.api.nvim_set_hl(0, name, opts) end

  -- Float preview (used if caller wants a popup diff)
  hl('AiDiffAdd',    { bg = '#1e3a2a', fg = '#86efac', bold = true })
  hl('AiDiffDel',    { bg = '#3a1e1e', fg = '#fca5a5', bold = true })
  hl('AiDiffCtx',    { fg = '#787c99' })
  hl('AiDiffHdr',    { fg = '#565f89', italic = true })

  -- In-buffer virtual text
  hl('AiDiffVirtDel', { bg = '#3a1e1e', fg = '#fca5a5' })          -- deleted line shown as virt_line
  hl('AiDiffVirtAdd', { bg = '#1e3a2a', fg = '#86efac' })          -- added line highlight
  hl('AiDiffVirtCtx', { fg = '#565f89' })                          -- context (unchanged) dim
  hl('AiDiffSignAdd', { fg = '#86efac', bold = true })             -- + sign col
  hl('AiDiffSignDel', { fg = '#fca5a5', bold = true })             -- - sign col
  hl('AiDiffLineNr',  { fg = '#565f89' })
end

-- ── Myers diff ────────────────────────────────────────────────────────────────
-- Returns a list of ops: { op = '=' | '+' | '-', line = string }
-- '=' = unchanged, '+' = added, '-' = deleted

function M.myers_diff(a, b)
  -- a, b are arrays of strings
  local N, M_len = #a, #b
  if N == 0 and M_len == 0 then return {} end

  -- Short-circuit trivial cases
  if N == 0 then
    local r = {}
    for _, l in ipairs(b) do table.insert(r, { op='+', line=l }) end
    return r
  end
  if M_len == 0 then
    local r = {}
    for _, l in ipairs(a) do table.insert(r, { op='-', line=l }) end
    return r
  end

  local MAX = N + M_len
  -- v[k] = furthest x reached on diagonal k  (1-indexed offset: v[k + MAX + 1])
  local v = {}
  local OFF = MAX + 1
  v[1 + OFF] = 0   -- k=1 starts at x=0 implicitly; k=0 diagonal x=0

  -- trace[d] = snapshot of v at edit distance d
  local trace = {}

  for d = 0, MAX do
    -- clone v for backtracking
    local snap = {}
    for kk = -d, d, 2 do
      snap[kk] = v[kk + OFF]
    end
    trace[d] = snap

    for k = -d, d, 2 do
      local x
      local down = v[(k-1) + OFF]
      local right = v[(k+1) + OFF]
      if k == -d or (k ~= d and (down or -1) < (right or -1)) then
        x = (right or 0)
      else
        x = (down or 0) + 1
      end
      local y = x - k
      while x < N and y < M_len and a[x+1] == b[y+1] do
        x = x + 1; y = y + 1
      end
      v[k + OFF] = x
      if x >= N and y >= M_len then
        -- found shortest edit — backtrack
        return M._backtrack(a, b, trace, d, OFF)
      end
    end
  end

  -- fallback: replace all
  local r = {}
  for _, l in ipairs(a) do table.insert(r, { op='-', line=l }) end
  for _, l in ipairs(b) do table.insert(r, { op='+', line=l }) end
  return r
end

function M._backtrack(a, b, trace, d_final, OFF)
  local ops = {}
  local x, y = #a, #b

  for d = d_final, 1, -1 do
    local snap = trace[d]
    local k    = x - y
    local prev_k
    local down  = snap[k-1]
    local right = snap[k+1]
    if k == -d or (k ~= d and (down or -1) < (right or -1)) then
      prev_k = k + 1
    else
      prev_k = k - 1
    end
    local prev_x = snap[prev_k] or 0
    local prev_y = prev_x - prev_k

    -- snake (diagonal moves = equal lines)
    while x > prev_x and y > prev_y do
      table.insert(ops, 1, { op='=', line=a[x] })
      x = x - 1; y = y - 1
    end
    if d > 0 then
      if x == prev_x then
        table.insert(ops, 1, { op='+', line=b[y] })
        y = y - 1
      else
        table.insert(ops, 1, { op='-', line=a[x] })
        x = x - 1
      end
    end
  end

  -- remaining snake at the start
  while x > 0 and y > 0 do
    table.insert(ops, 1, { op='=', line=a[x] })
    x = x - 1; y = y - 1
  end

  return ops
end

-- ── Sign column ───────────────────────────────────────────────────────────────

local SIGN_GROUP = 'ai_diff_signs'

local function define_signs()
  -- idempotent: pcall in case already defined
  pcall(vim.fn.sign_define, 'AiDiffAdd', { text='▎+', texthl='AiDiffSignAdd', numhl='' })
  pcall(vim.fn.sign_define, 'AiDiffDel', { text='▎-', texthl='AiDiffSignDel', numhl='' })
end

-- ── Namespace ─────────────────────────────────────────────────────────────────

local NS = vim.api.nvim_create_namespace('ai_diff_virt')

-- ── Main: show inline diff in a real editor buffer ────────────────────────────
--
-- orig_lines: string[]  — the lines BEFORE the edit (what the AI was given)
-- new_lines:  string[]  — the lines AFTER  the edit (what the AI returned)
-- bufnr:      number    — the editor buffer
-- start_line: number    — 1-indexed first line that was selected/edited
--
-- Strategy:
--   1. Write new_lines into the buffer at start_line (replacing orig_lines)
--   2. Compute diff(orig_lines, new_lines)
--   3. For '+' ops: green highlight on the corresponding new buffer line
--   4. For '-' ops: show as a red virt_line ABOVE the nearest '+' or context line
--      (so the reader sees "what was removed" right next to what replaced it)
--
-- Returns: ns (the extmark namespace), so caller can clear it with
--          vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

function M.show_inline_diff(bufnr, orig_lines, new_lines, start_line)
  define_signs()
  M.setup_highlights()

  -- Clear previous diff marks on this buffer
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })

  -- Write new content into buffer (this is the "applied" state we preview)
  vim.api.nvim_buf_set_option(bufnr, 'modifiable', true)
  vim.api.nvim_buf_set_lines(bufnr, start_line - 1,
    start_line - 1 + #orig_lines, false, new_lines)

  -- Compute diff
  local ops = M.myers_diff(orig_lines, new_lines)

  -- Walk ops, track cursor into new_lines (for buffer line positions)
  local new_row = start_line   -- 1-indexed buffer line for current '+' or '='
  local pending_dels = {}      -- accumulate '-' ops to show as virt_lines

  local function flush_dels(target_row)
    if #pending_dels == 0 then return end
    local virt = {}
    for _, dl in ipairs(pending_dels) do
      table.insert(virt, { { '- ' .. dl, 'AiDiffVirtDel' } })
    end
    -- show above target_row (0-indexed)
    local row0 = math.max(0, target_row - 1)
    vim.api.nvim_buf_set_extmark(bufnr, NS, row0, 0, {
      virt_lines       = virt,
      virt_lines_above = true,
    })
    pending_dels = {}
  end

  for _, op in ipairs(ops) do
    if op.op == '-' then
      table.insert(pending_dels, op.line)

    elseif op.op == '+' then
      flush_dels(new_row)
      -- green highlight on this new buffer line
      vim.api.nvim_buf_add_highlight(bufnr, NS, 'AiDiffVirtAdd',
        new_row - 1, 0, -1)
      pcall(vim.fn.sign_place, 0, SIGN_GROUP, 'AiDiffAdd', bufnr,
        { lnum = new_row, priority = 100 })
      new_row = new_row + 1

    else -- '='
      flush_dels(new_row)
      new_row = new_row + 1
    end
  end
  -- any trailing deletions after last '=' or '+'
  flush_dels(new_row)

  return NS
end

--- Clear all diff marks from a buffer.
function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  pcall(vim.fn.sign_unplace, SIGN_GROUP, { buffer = bufnr })
end

-- ── apply_highlights (legacy, used by old float preview) ─────────────────────
function M.apply_highlights(bufnr)
  M.setup_highlights()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local ns = vim.api.nvim_create_namespace('ai_diff_hl')
  for i, line in ipairs(lines) do
    local ch = line:sub(1,1)
    if ch == '+' then
      vim.api.nvim_buf_add_highlight(bufnr, ns, 'AiDiffAdd', i-1, 0, -1)
    elseif ch == '-' then
      vim.api.nvim_buf_add_highlight(bufnr, ns, 'AiDiffDel', i-1, 0, -1)
    else
      vim.api.nvim_buf_add_highlight(bufnr, ns, 'AiDiffCtx', i-1, 0, -1)
    end
  end
end

return M
