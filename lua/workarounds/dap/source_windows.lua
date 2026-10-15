-- WORKAROUND
-- name: dap.source_windows
-- scope: dap
-- issue: internal: dap-ui util.open_buf reuses existing target windows before select_window
-- symptom: Manual frame opening can move into a review pane or overwrite a debug panel before frame restoration is sampled.
-- introduced: 2026-10-12
-- removal_condition: dap-ui applies its select_window hook to existing targets and brackets the first manual source open.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local original, wrapper, get_state

function M.apply(state_for_tab)
  if type(state_for_tab) == "function" then get_state = state_for_tab end
  local util = package.loaded["dapui.util"]
  -- Registry discovery must not force-load a lazy debug UI.
  if not util then return true end
  if util.open_buf == wrapper then return true end
  original = util.open_buf
  wrapper = function(buf, line, column)
    local layout = require("ue.dap._layout")
    -- dap-ui's util uses a byte column directly; retain that convention.
    return layout.jump(get_state and get_state(), buf, line, (column or 0) + 1)
  end
  util.open_buf = wrapper
  return true
end

function M.disable()
  local util = package.loaded["dapui.util"]
  if util and util.open_buf == wrapper then util.open_buf = original end
end

return M
