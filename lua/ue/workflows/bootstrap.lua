local M = {}
local defaults_registered = false

function M.setup_commands()
  require("ue.workflows.android.distributed").setup()
end

--- Inner-loop commands whose steps are provided by the ue.lua facade.
function M.setup_loop_commands(steps)
  require("ue.workflows.android.iterate").setup(steps)
end

function M.ensure_registered()
  if defaults_registered then
    return
  end
  require("ue.workflows.android").register()
  require("ue.workflows.ios").ensure_registered()
  defaults_registered = true
end

function M._reset_for_test()
  defaults_registered = false
  require("ue.workflows.android")._reset_for_test()
  require("ue.workflows.ios")._reset_for_test()
end

return M
