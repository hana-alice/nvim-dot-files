local TargetTasks = require("ue.target_tasks")

local M = {}

function M.error_message(result)
  return TargetTasks.error_message(result)
end

function M.device_unavailable(device_id, result)
  return ("selected iOS device %s is unavailable over legacy USB: %s"):format(
    tostring(device_id or "?"),
    M.error_message(result)
  )
end

return M
