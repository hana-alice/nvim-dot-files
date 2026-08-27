-- ue/index/_admission.lua — compatibility seam for the shared host policy.
--
-- Thresholds and decision logic MUST live only in utils.host_admission. The
-- index scheduler keeps its historical public names so callers do not change,
-- but this loader is deliberately a thin delegate (K54 drift guard).

return function(M, core) -- luacheck: ignore 212/core
  local admission = require("utils.host_admission")

  M.admit_background_phase = admission.admit
  M.admission_opts = admission.options
end
