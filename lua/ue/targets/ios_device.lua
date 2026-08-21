local C = require("ue.targets._common")

local M = {}

function M.mobiledevice_device_list_plans(context, host_driver)
  local entry, unavailable = C.resolve_host_entry(host_driver, "idevice_id_entry", context, "IOS", "device")
  if not entry then
    return unavailable
  end

  return {
    C.with_appended_args(entry, { "-l" }, {
      parser = "parse_mobiledevice_device_list",
      result_source = "stdout",
      backend = "legacy-mobiledevice",
      transport = "usb",
    }),
    C.with_appended_args(entry, { "--network" }, {
      parser = "parse_mobiledevice_device_list",
      result_source = "stdout",
      backend = "legacy-mobiledevice",
      transport = "network",
    }),
  }
end

function M.parse_mobiledevice_device_list(payload, transport)
  transport = C.trim(transport):lower()
  if transport ~= "usb" and transport ~= "network" then
    return C.unavailable("IOS", "device", "MobileDevice transport must be usb or network")
  end

  local devices = {}
  local seen = {}
  for line in tostring(payload or ""):gmatch("[^\r\n]+") do
    local device_id = C.trim(line)
    if device_id:match("^[A-Fa-f0-9%-]+$") and not seen[device_id] then
      seen[device_id] = true
      devices[#devices + 1] = {
        id = device_id,
        name = device_id,
        platform = "iOS",
        backend = "legacy-mobiledevice",
        transport = transport,
        available = true,
      }
    end
  end

  return {
    ok = true,
    devices = devices,
  }
end

function M.mobiledevice_info_plan(device, context, host_driver)
  local entry, unavailable = C.resolve_host_entry(host_driver, "ideviceinfo_entry", context, "IOS", "device")
  if not entry then
    return unavailable
  end
  local device_id = C.trim(device and device.id)
  local transport = C.trim(device and device.transport):lower()
  if device_id == "" or (transport ~= "usb" and transport ~= "network") then
    return C.unavailable("IOS", "device", "MobileDevice info requires an id and transport")
  end
  local args = {}
  if transport == "network" then
    args[#args + 1] = "--network"
  end
  vim.list_extend(args, { "--udid", device_id })
  return C.with_appended_args(entry, args, {
    parser = "parse_mobiledevice_info",
    result_source = "stdout",
    device_id = device_id,
    transport = transport,
  })
end

function M.parse_mobiledevice_info(payload, device)
  local fields = {}
  for line in tostring(payload or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key then
      fields[C.trim(key)] = C.trim(value)
    end
  end
  local resolved = vim.deepcopy(device or {})
  resolved.name = fields.DeviceName ~= "" and fields.DeviceName or resolved.name
  resolved.os_version = fields.ProductVersion ~= "" and fields.ProductVersion or resolved.os_version
  resolved.model = fields.ProductType ~= "" and fields.ProductType or resolved.model
  return {
    ok = true,
    device = resolved,
  }
end

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
