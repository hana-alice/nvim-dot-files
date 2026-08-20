local C = require("ue.targets._common")

local M = {}

function M.fallback_device_list_plan(context, host_driver)
  local entry, unavailable = C.resolve_host_entry(host_driver, "xcrun_entry", context, "IOS", "device")
  if not entry then
    return unavailable
  end

  return C.with_appended_args(entry, {
    "xcdevice",
    "list",
    "--timeout",
    "5",
  }, {
    parser = "parse_fallback_device_list",
    result_source = "stdout",
    backend = "legacy-mobiledevice",
  })
end

function M.parse_fallback_device_list(payload)
  local decoded = payload
  if type(payload) == "string" then
    local ok, parsed = pcall(vim.json.decode, payload)
    if not ok then
      return C.unavailable("IOS", "device", "failed to parse xcdevice device list json", {
        detail = parsed,
      })
    end
    decoded = parsed
  end

  local devices = decoded and (decoded.devices or decoded.result and decoded.result.devices or decoded)
  if type(devices) ~= "table" then
    return C.unavailable("IOS", "device", "xcdevice device list schema missing devices")
  end

  local available = {}
  for _, item in ipairs(devices) do
    local platform = C.trim(item.platform)
    local interface = C.trim(item.interface):lower()
    local version = C.trim(item.operatingSystemVersion or item.osVersion)
    local os_version = version:match("^(%d+[%d%.]*)") or version
    local os_major = tonumber(os_version:match("^(%d+)"))
    local device_id = C.trim(item.identifier or item.udid)
    local physical_ios = item.simulator == false and platform == "com.apple.platform.iphoneos"
    if
      item.available == true
      and physical_ios
      and interface == "usb"
      and os_major ~= nil
      and os_major < 17
      and device_id ~= ""
    then
      available[#available + 1] = {
        id = device_id,
        name = item.name or item.modelName or device_id,
        platform = "iOS",
        os_version = os_version,
        backend = "legacy-mobiledevice",
      }
    end
  end

  return {
    ok = true,
    devices = available,
  }
end

return M
