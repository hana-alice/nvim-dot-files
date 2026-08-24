local workflows = require("ue.workflows")

local M = {}
local registered = false

function M.register()
  if registered then
    return
  end
  workflows.register("Android", "build", require("ue.workflows.android.build"))
  workflows.register("Android", "so_build", require("ue.workflows.android.build"))
  workflows.register("Android", "install", require("ue.workflows.android.install"))
  workflows.register("Android", "so_deploy", require("ue.workflows.android.deploy"))
  workflows.register("Android", "launch", require("ue.workflows.android.launch"))
  workflows.register("Android", "log", require("ue.workflows.android.log"))
  registered = true
end

function M._reset_for_test()
  registered = false
end

return M
