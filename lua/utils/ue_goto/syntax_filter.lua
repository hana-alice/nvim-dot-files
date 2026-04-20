-- ue_goto.syntax_filter — drop ws/symbol candidates that cannot match the
-- cursor's call signature.
--
-- This is the deterministic, syntax-driven replacement for
-- ranking.clear_winner's "guess by score margin" logic. Overload resolution
-- is a syntactic question (call arity vs. parameter arity); ranking is left
-- only as a quickfix-sort tiebreaker for the few candidates surviving the
-- filter.

local symbol = require("utils.ue_goto.symbol")
local location = require("utils.ue_goto.location")

local M = {}

-- Returns true if a candidate with arity (P, D, variadic) can plausibly
-- accept K arguments. Conservative: when any field is nil/unknown, accept.
local function arity_compatible(K, P, D, variadic)
  if K == nil then return true end           -- caller arity unknown — never reject
  if P == nil then return true end           -- candidate arity unknown — never reject
  if variadic then return K >= P end         -- variadic accepts at-least-P
  local minP = P - (D or 0)
  return K >= minP and K <= P
end

-- filter_by_call_signature(locations, bufnr, dtrace?)
--   locations : array of normalized Location candidates (from ws/symbol)
--   bufnr     : the buffer cursor lives in
--   dtrace    : optional log callback (printf-style)
--
-- Returns (filtered_locations, info_table).
--
-- info_table = {
--   applied    = bool,    -- true if filter ran (cursor was in a call_expression)
--   call_arity = int|nil, -- the K it computed
--   callee     = string|nil,
--   before     = int,
--   after      = int,
--   skipped    = int,     -- how many candidates we couldn't probe (kept anyway)
-- }
--
-- Contract: NEVER returns an empty list when input was non-empty unless
-- filter eliminated by-confident-mismatch. If parsing the cursor fails or
-- arity is unknowable, returns the input unchanged with applied=false.
function M.filter_by_call_signature(locations, bufnr, dtrace)
  local info = { applied = false, call_arity = nil, callee = nil,
                 before = locations and #locations or 0, after = 0, skipped = 0 }
  if not locations or #locations == 0 then
    info.after = 0; return locations or {}, info
  end

  -- Activate cursor's buffer for AST parse if needed.
  local prev_buf = vim.api.nvim_get_current_buf()
  if bufnr and bufnr ~= prev_buf then
    -- We don't switch buffers — the cursor API needs the actual current buffer.
    -- Caller (M.definition) already runs in the user's current buffer.
  end

  local K, callee = symbol.call_arity_at_cursor()
  if K == nil then
    info.after = #locations
    if dtrace then pcall(dtrace, "syntax_filter: cursor not in call_expression — pass-through (n=%d)", #locations) end
    return locations, info
  end
  info.applied = true
  info.call_arity = K
  info.callee = callee

  if dtrace then pcall(dtrace, "syntax_filter: K=%d callee=%q candidates=%d", K, tostring(callee), #locations) end

  local out = {}
  for i, loc in ipairs(locations) do
    local path = location.location_path(loc)
    local line = location.location_line(loc)
    local P, D, V = symbol.declarator_arity_at(path, line)
    if P == nil then
      info.skipped = info.skipped + 1
      out[#out + 1] = loc  -- conservative keep
      if dtrace then pcall(dtrace, "syntax_filter: cand[%d] %s:%d → unknown (kept)", i, vim.fn.fnamemodify(path, ":t"), line) end
    elseif arity_compatible(K, P, D, V) then
      out[#out + 1] = loc
      if dtrace then pcall(dtrace, "syntax_filter: cand[%d] %s:%d → P=%d D=%d V=%s KEEP", i, vim.fn.fnamemodify(path, ":t"), line, P, D or 0, tostring(V)) end
    else
      if dtrace then pcall(dtrace, "syntax_filter: cand[%d] %s:%d → P=%d D=%d V=%s DROP (K=%d)", i, vim.fn.fnamemodify(path, ":t"), line, P, D or 0, tostring(V), K) end
    end
  end

  -- Safety: if filter eliminated everything (should be rare — usually means
  -- arity is unknowable for all candidates), fall back to original list to
  -- avoid breaking gd entirely.
  if #out == 0 then
    if dtrace then pcall(dtrace, "syntax_filter: ALL eliminated → fallback to unfiltered (%d)", #locations) end
    info.after = #locations
    return locations, info
  end

  info.after = #out
  return out, info
end

return M
