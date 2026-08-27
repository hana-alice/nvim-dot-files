-- ue.index — clangd offline-index subsystem (former ue.lua INDEX_FN/INDEX_RT).
--
-- F1 split phase-1 (health-check 2026-07): mechanical extraction of the
-- 2005-3302 index block out of the 10k-line ue.lua. Public API is unchanged —
-- ue.lua binds `local INDEX_FN = require("ue.index")` and every historical
-- `INDEX_FN.*` call site keeps working. Runtime state lives on `M._rt`
-- (`local INDEX_RT = INDEX_FN._rt` in ue.lua).
--
-- Wiring contract:
--   * `M.setup(deps)` MUST be called (ue.lua does, right where the old block
--     lived) before any index operation runs. deps carries closures over
--     ue.lua-local functions that intentionally stayed behind:
--     plugin/project/engine scope resolvers / status_root_key /
--     clear_index_dirty / mark_index_dirty / invalidate_status_cache /
--     refresh_statusline / read_all / write_all,
--     plus `core_rt` (the CORE_RT table reference).
--   * Submodules are loader-style `return function(M, core)` so they share
--     one internal namespace without globals: core.h = shared helpers
--     (defined in _state, consumed by _build/_clangd), core.RT = runtime.
local M = {}

local _ue_cfg = require("ue.config")

-- Runtime state (former ue.lua INDEX_RT). Tunables mirror ue.config with the
-- same literal fallbacks as before the split.
local RT = {
  job = nil,
  module_state = {},
  contexts = {},
  timers = {},
  idle_cold_ms        = _ue_cfg.get("index.idle_cold_ms")        or 120000,
  debounce_current_ms = _ue_cfg.get("index.debounce_current_ms") or 1200,
  debounce_hot_ms     = _ue_cfg.get("index.debounce_hot_ms")     or 8000,
  restart_debounce_s  = _ue_cfg.get("index.restart_debounce_s")  or 45,
  last_restart_at = 0,
  status_cache = {},
  status_ttl          = _ue_cfg.get("index.status_ttl_s")        or 30,
}
M._rt = RT

local core = { RT = RT, h = {}, deps = nil }

function M.setup(deps)
  core.deps = deps
end

require("ue.index._state")(M, core)
require("ue.index._generation")(M, core)
-- After _generation: recovery consumes its manifest/generation/file_signature
-- helpers to rebuild readiness from persisted artifacts.
require("ue.index._recover")(M, core)
-- After _generation: index_delivery_line/prepare_delivery_suffix read
-- M.index_status_summary defined there.
require("ue.index._delivery")(M, core)
require("ue.index._clangd")(M, core)
require("ue.index._build")(M, core)
-- After _build: admission policy gates build_phase_async starts.
require("ue.index._admission")(M, core)
-- After _build: scheduling drives build_phase_async / base_compile_commands_path.
require("ue.index._schedule")(M, core)

return M
