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
    -- Phase I additions ────────────────────────────────────────────────
    clangd = {
      -- Extra candidate paths tried BEFORE the platform driver defaults
      -- and before the env-var override. Highest priority. Empty means
      -- ue.lua's existing clangd_candidates() runs unchanged.
      candidates_extra = {},
      -- Extra args appended to the clangd command line. Empty means
      -- behaviour unchanged.
      extra_args = {},
    },
    dap = {
      -- Concrete lldb-dap adapter. nil => probe via driver + PATH.
      -- Consumed by ue.dap._common.find_lldb_dap.
      lldb_dap_path = nil,
      -- Optional PYTHONHOME/PYTHONPATH overrides for lldb-dap's embedded
      -- Python. Usually leave nil; set only if lldb-dap cannot import its
      -- bundled `lldb` Python module.
      lldb_dap_python_dir = nil,
      lldb_dap_pythonpath = nil,
      -- Backward-compatible alias accepted by older local configs. New
      -- Android code should use android_lldb_server.
      lldb_server_path = nil,

      -- Path to an arm64 lldb-server binary used for Android remote-debugging.
      -- Pushed to /data/local/tmp on the device by the preflight script.
      android_lldb_server = nil,
      -- Path to a JDK `jdb` executable used by the Android wait-for-debugger
      -- launch (releases the app's "Waiting for debugger" JDWP gate after the
      -- native lldb attach). nil => probe PATH, then JAVA_HOME/bin.
      jdb_path = nil,
      -- Default Android package name. nil => prompt on first use, then
      -- persist via update_state_field("android_package", ...).
      android_package = nil,
    },
    cdb = {
      -- Directory holding the python pipeline scripts. Lazy so the user
      -- can override stdpath via XDG_CONFIG_HOME and still get the right
      -- path on the first read.
      tools_dir = function() return vim.fn.stdpath("config") .. "/tools" end,
      -- Ordered pipeline. Removing or renaming a step lets the user skip
      -- slow ones (e.g. drop `prune_include_dirs.py` on a small project).
      steps = {
        "expand_response_cdb.py",
        "prebuild_pch_v2.py",
        "resolve_cdb_paths.py",
        "unify_include_dirs.py",
        "prune_include_dirs.py",
      },
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
