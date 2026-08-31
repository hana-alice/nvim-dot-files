local TargetTasks = require("ue.target_tasks")

local M = {}

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function decode(payload, label)
  if type(payload) == "table" then
    return payload
  end
  local ok, decoded = pcall(vim.json.decode, tostring(payload or ""))
  if not ok or type(decoded) ~= "table" then
    return nil, "failed to decode " .. label .. " JSON"
  end
  return decoded
end

local function result_table(decoded)
  return type(decoded.result) == "table" and decoded.result or decoded
end

local function positive_pid(value)
  local pid = tonumber(value)
  if not pid or pid <= 0 or pid % 1 ~= 0 then
    return nil
  end
  return pid
end

local function normalize_file_url(value)
  local normalized = trim(value)
  if normalized == "" then
    return ""
  end
  normalized = normalized:gsub("/+$", "")
  return normalized
end

local function executable_in_app(executable, app_url)
  executable = normalize_file_url(executable)
  app_url = normalize_file_url(app_url)
  if executable == "" or app_url == "" then
    return false
  end
  return executable:sub(1, #app_url + 1) == app_url .. "/"
end

function M.error_message(result)
  return TargetTasks.error_message(result)
end

function M.device_unavailable(device_id, result)
  return ("selected iOS device %s is unavailable over legacy USB: %s"):format(
    tostring(device_id or "?"),
    M.error_message(result)
  )
end

function M.parse_coredevice_apps(payload, expected)
  expected = expected or {}
  local decoded, decode_err = decode(payload, "CoreDevice app list")
  if not decoded then
    return nil, decode_err
  end
  local result = result_table(decoded)
  local device_id = trim(result.deviceIdentifier or result.device or result.targetDeviceIdentifier)
  if device_id == "" then
    return nil, "CoreDevice app list is missing device identity"
  end
  if trim(expected.canonical_device_id) ~= "" and device_id ~= trim(expected.canonical_device_id) then
    return nil, "CoreDevice app list device identity mismatch"
  end
  local bundle_id = trim(expected.bundle_id)
  if bundle_id == "" then
    return nil, "CoreDevice app query requires an exact bundle id"
  end
  local apps = result.apps or result.applications or result.installedApplications
  if type(apps) ~= "table" then
    return nil, "CoreDevice app list schema is missing apps"
  end
  local matches = {}
  for _, app in ipairs(apps) do
    local actual_bundle = type(app) == "table"
        and trim(app.bundleIdentifier or app.bundleID or app.applicationIdentifier)
      or ""
    if actual_bundle == bundle_id then
      matches[#matches + 1] = app
    end
  end
  if #matches ~= 1 then
    return nil, ("CoreDevice bundle matched %d installed apps"):format(#matches)
  end
  local app = matches[1]
  local app_url = normalize_file_url(app.url or app.path or app.bundleURL)
  if app_url == "" then
    return nil, "CoreDevice installed app is missing its URL"
  end
  return {
    app_url = app_url,
    bundle_id = bundle_id,
    device_id = device_id,
  }
end

function M.parse_coredevice_processes(payload, expected)
  expected = expected or {}
  local decoded, decode_err = decode(payload, "CoreDevice process list")
  if not decoded then
    return nil, decode_err
  end
  local result = result_table(decoded)
  local device_id = trim(result.deviceIdentifier or result.device or result.targetDeviceIdentifier)
  if device_id == "" then
    return nil, "CoreDevice process list is missing device identity"
  end
  local expected_device = trim(expected.canonical_device_id or expected.device_id)
  if expected_device ~= "" and device_id ~= expected_device then
    return nil, "CoreDevice process list device identity mismatch"
  end
  local processes = result.runningProcesses or result.processes
  if type(processes) ~= "table" then
    return nil, "CoreDevice process list schema is missing runningProcesses"
  end

  local expected_pid = positive_pid(expected.pid)
  if expected.pid ~= nil and not expected_pid then
    return nil, "CoreDevice process query requires a positive PID"
  end
  if trim(expected.app_url) == "" then
    return nil, "CoreDevice process query requires the installed app URL"
  end

  if expected_pid then
    local found
    for _, process in ipairs(processes) do
      if type(process) == "table" and positive_pid(process.processIdentifier or process.pid) == expected_pid then
        if found then
          return nil, "CoreDevice process list contains a duplicate PID"
        end
        found = process
      end
    end
    if not found then
      return { absent = true, device_id = device_id, process_id = expected_pid }
    end
    local executable = trim(found.executable or found.executableURL or found.path)
    if not executable_in_app(executable, expected.app_url) then
      return {
        absent = true,
        device_id = device_id,
        process_id = expected_pid,
        reused = true,
      }
    end
    return {
      absent = false,
      device_id = device_id,
      executable = executable,
      process_id = expected_pid,
    }
  end

  local matches = {}
  for _, process in ipairs(processes) do
    local pid = type(process) == "table" and positive_pid(process.processIdentifier or process.pid) or nil
    local executable = type(process) == "table" and trim(process.executable or process.executableURL or process.path)
      or ""
    if pid and executable_in_app(executable, expected.app_url) then
      matches[#matches + 1] = { executable = executable, process_id = pid }
    end
  end
  if #matches == 0 then
    return { absent = true, device_id = device_id }
  end
  if #matches ~= 1 then
    return nil, ("CoreDevice bundle matched %d running processes"):format(#matches)
  end
  return {
    absent = false,
    device_id = device_id,
    executable = matches[1].executable,
    process_id = matches[1].process_id,
  }
end

function M.parse_coredevice_launch(payload, expected)
  expected = expected or {}
  local decoded, decode_err = decode(payload, "CoreDevice launch result")
  if not decoded then
    return nil, decode_err
  end
  local result = result_table(decoded)
  local process = type(result.process) == "table" and result.process
    or type(result.launchedProcess) == "table" and result.launchedProcess
    or type(result.applicationProcess) == "table" and result.applicationProcess
    or {}
  local device_id = trim(result.deviceIdentifier or result.device or result.targetDeviceIdentifier)
  local pid = positive_pid(result.processIdentifier or result.pid or process.processIdentifier or process.pid)
  if device_id == "" or not pid then
    return nil, "CoreDevice launch result is missing device identity or positive PID"
  end
  local expected_device = trim(expected.canonical_device_id or expected.device_id)
  if expected_device ~= "" and device_id ~= expected_device then
    return nil, "CoreDevice launch result device identity mismatch"
  end
  local actual_bundle = trim(
    result.bundleIdentifier
      or result.bundleID
      or process.bundleIdentifier
      or process.bundleID
      or process.applicationIdentifier
  )
  if actual_bundle ~= "" and trim(expected.bundle_id) ~= "" and actual_bundle ~= trim(expected.bundle_id) then
    return nil, "CoreDevice launch result bundle identity mismatch"
  end
  return {
    bundle_id = trim(expected.bundle_id) ~= "" and trim(expected.bundle_id) or actual_bundle,
    device_id = device_id,
    process_id = pid,
  }
end

function M.parse_uuid_output(output)
  local uuids = {}
  local seen = {}
  for uuid in tostring(output or ""):gmatch("UUID:%s*([0-9A-Fa-f%-]+)") do
    uuid = uuid:upper()
    if uuid ~= "" and not seen[uuid] then
      seen[uuid] = true
      uuids[#uuids + 1] = uuid
    end
  end
  table.sort(uuids)
  if #uuids == 0 then
    return nil, "dwarfdump returned no UUID"
  end
  return uuids
end

function M.uuid_sets_equal(left, right)
  if type(left) ~= "table" or type(right) ~= "table" or #left == 0 or #left ~= #right then
    return false
  end
  for index, value in ipairs(left) do
    if value ~= right[index] then
      return false
    end
  end
  return true
end

return M
