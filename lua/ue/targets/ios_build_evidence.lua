local C = require("ue.targets._common")

local M = {}

-- Recover proof for builds completed before Nvim started recording its own
-- tuple-scoped success marker. A UBT .target receipt is only published after
-- a successful target build; still require an exact tuple and its declared
-- launch product so a stale/foreign receipt cannot satisfy UEPrepare.
function M.from_receipt(context)
  local project_dir = C.normalize_path(context and context.project_dir)
  local target = C.context_target(context)
  local configuration = C.context_configuration(context)
  if project_dir == "" or target == "" or configuration == "" then
    return nil, "incomplete IOS build tuple"
  end

  local receipt_path = C.join_path(project_dir, "Binaries", "IOS", target .. ".target")
  local receipt_stat = vim.uv.fs_stat(receipt_path)
  if not receipt_stat or receipt_stat.type ~= "file" then
    return nil, "UBT receipt missing for current IOS tuple"
  end

  local file, open_err = io.open(receipt_path, "rb")
  if not file then return nil, tostring(open_err) end
  local payload = file:read("*a")
  file:close()
  local decoded, receipt = pcall(vim.json.decode, payload or "")
  if not decoded or type(receipt) ~= "table" then
    return nil, "UBT receipt is not valid JSON"
  end
  if receipt.TargetName ~= target
      or receipt.Platform ~= "IOS"
      or receipt.Configuration ~= configuration then
    return nil, "UBT receipt does not match current IOS tuple"
  end

  local launch = C.trim(receipt.Launch)
  if launch == "" then return nil, "UBT receipt has no launch product" end
  launch = launch:gsub("%$%(ProjectDir%)", project_dir)
  local launch_path = C.normalize_path(launch)
  local launch_stat = vim.uv.fs_stat(launch_path)
  if not launch_stat or launch_stat.type ~= "file" then
    return nil, "UBT receipt launch product is missing"
  end

  local mtime = type(receipt_stat.mtime) == "table" and receipt_stat.mtime.sec or receipt_stat.mtime
  return {
    target = target,
    platform = "IOS",
    configuration = configuration,
    completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ", tonumber(mtime) or os.time()),
    receipt_path = receipt_path,
    launch_path = launch_path,
    source = "ubt-receipt",
  }
end

return M
