-- ue.config — central schema for tunables that previously lived inline in
-- `lua/ue.lua` (INDEX_RT.* timing constants, context TTL, paths derived
-- from `vim.fn.stdpath`, planned multi-platform defaults).
--
-- Phase C scope: introduce the schema and migrate the smallest possible
-- set of constants (the index timing block) so the schema is exercised
-- by real code without forcing a wide-ranging rewrite. Subsequent ADRs
-- migrate more keys.
--
-- Public API:
--   M.setup(user_opts)   -- merges user_opts on top of defaults
--   M.get(dotted_path)   -- e.g. "index.idle_cold_ms"; nil on miss
--   M.options()          -- returns the merged table (read-only intent)
--   M.reset_for_test()   -- restore factory defaults
--
-- Design notes:
-- * No `require("ue")` at the top level — this module must be safe to
--   load before `ue.lua` finishes evaluation (avoids a circular require
--   the first time `ue.lua` reads a default).
-- * Defaults are LITERAL VALUES, not derived from runtime state, so the
--   module is cheap to load and trivially testable.

local M = {}

local function defaults()
  return {
    index = {
      idle_cold_ms       = 120000,
      debounce_current_ms = 1200,
      debounce_hot_ms    = 8000,
      restart_debounce_s = 45,
      status_ttl_s       = 30,
    },
    context = {
      ttl_s = 30,
    },
    paths = {
      -- Lazy-evaluated so callers always see the current `stdpath` result
      -- (XDG vars / nvim startup quirks make eager eval unsafe).
      state_dir = function() return vim.fn.stdpath("state") .. "/ue" end,
      cache_dir = function() return vim.fn.stdpath("cache") .. "/ue" end,
    },
    platforms = {
      enabled = { "Win64", "Android", "Mac", "IOS", "Linux" },
      default = nil,  -- nil = auto-detect from current_platform()
    },
  }
end

local _opts = defaults()

--- Merge user options into the defaults. Idempotent and safe to call
--- multiple times; later calls replace earlier ones rather than stacking.
---@param user_opts? table
function M.setup(user_opts)
  _opts = vim.tbl_deep_extend("force", defaults(), user_opts or {})
end

--- Read a single value by dotted path. Returns nil for unknown paths.
--- Functions stored in the schema are auto-invoked so callers always get
--- a final value (used by `paths.state_dir` etc.).
---@param dotted string
---@return any
function M.get(dotted)
  if type(dotted) ~= "string" or dotted == "" then return nil end
  local node = _opts
  for segment in dotted:gmatch("[^.]+") do
    if type(node) ~= "table" then return nil end
    node = node[segment]
    if node == nil then return nil end
  end
  if type(node) == "function" then
    local ok, value = pcall(node)
    if ok then return value end
    return nil
  end
  return node
end

--- Read-only view of the current merged options. Mutating the returned
--- table is undefined behaviour — use `setup()` to apply changes.
function M.options()
  return _opts
end

--- Test seam: restore factory defaults.
function M.reset_for_test()
  _opts = defaults()
end

return M
