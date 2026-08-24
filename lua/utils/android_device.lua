-- Shared Android device selection for every adb-backed UE workflow.
-- The selected serial is intentionally Neovim-process-local (vim.g), not
-- persisted. `vim.g` is not shared between two Neovim OS processes.

local M = {}

M.global_key = "ue_android_device_serial"

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function adb_executable(adb)
  adb = trim(adb)
  if adb ~= "" then return adb end
  local resolved = vim.fn.exepath("adb")
  return resolved ~= "" and resolved or "adb"
end

local function normalize_lines(output)
  if type(output) == "table" then return output end
  local lines = {}
  for line in (tostring(output or "") .. "\n"):gmatch("([^\n]*)\n") do
    lines[#lines + 1] = line:gsub("\r$", "")
  end
  return lines
end

---Parse `adb devices -l` output.
---@param output string|string[]
---@return table[]
function M.parse_devices(output)
  local devices = {}
  for _, raw in ipairs(normalize_lines(output)) do
    local line = trim(raw)
    if line ~= "" and not line:match("^List of devices") and not line:match("^%* daemon") then
      local serial, status, rest = line:match("^(%S+)%s+(%S+)%s*(.*)$")
      if serial and status and serial ~= "List" then
        local attrs = {}
        for key, value in tostring(rest or ""):gmatch("([%w_]+):(%S+)") do
          attrs[key] = value
        end
        devices[#devices + 1] = {
          serial = serial,
          status = status,
          model = attrs.model,
          device = attrs.device,
          product = attrs.product,
          transport_id = attrs.transport_id,
        }
      end
    end
  end
  return devices
end

function M.ready_devices(devices)
  local ready = {}
  for _, device in ipairs(devices or {}) do
    if device.status == "device" then ready[#ready + 1] = device end
  end
  return ready
end

function M.device_name(device)
  local name = device and (device.model or device.device or device.product) or nil
  name = trim(name)
  if name == "" then name = "Android device" end
  return name:gsub("_", " ")
end

---Picker label: readable device name and serial are both mandatory.
function M.format_item(device)
  return ("%s  [%s]"):format(M.device_name(device), tostring(device and device.serial or "?"))
end

function M.get()
  local serial = trim(vim.g[M.global_key])
  return serial ~= "" and not serial:find("%s") and serial or nil
end

function M.set(serial)
  serial = trim(serial)
  if serial == "" or serial:find("%s") then
    return nil, "Android device serial must be a non-empty value without whitespace"
  end
  vim.g[M.global_key] = serial
  return serial
end

function M.clear()
  vim.g[M.global_key] = nil
end

---Build an argv for an operation directed at exactly one Android device.
---Discovery (`adb devices -l`) deliberately does not use this helper.
function M.adb_args(adb, serial, args)
  serial = trim(serial)
  if serial == "" then return nil, "Android device is not selected; run :UESetAndroidDevice" end
  if serial:find("%s") then return nil, "Android device serial must not contain whitespace" end
  local cmd = { adb_executable(adb), "-s", serial }
  vim.list_extend(cmd, args or {})
  return cmd
end

local function no_ready_message(devices)
  if not devices or #devices == 0 then
    return "No Android device found in `adb devices -l`. Connect a device with USB debugging enabled."
  end
  local lines = { "No ready Android device. Detected:" }
  for _, device in ipairs(devices) do
    local status = device.status or "unknown"
    if status == "unauthorized" then
      status = "unauthorized (tap 'Allow USB debugging' on the device)"
    elseif status == "offline" then
      status = "offline (try `adb kill-server` and reconnect)"
    end
    lines[#lines + 1] = ("  %s  %s"):format(device.serial or "?", status)
  end
  return table.concat(lines, "\n")
end

local function choose_rows(opts, devices, done)
  local notify = opts.notify or vim.notify
  local ready = M.ready_devices(devices)
  if #ready == 0 then
    local message = no_ready_message(devices)
    notify(message, vim.log.levels.WARN)
    done(nil, nil, message)
    return
  end

  local ui_select = opts.ui_select or vim.ui.select
  ui_select(ready, {
    prompt = opts.prompt or "Select Android device:",
    format_item = M.format_item,
  }, function(choice)
    if not choice then
      done(nil, nil, "cancelled")
      return
    end
    local serial, err = M.set(choice.serial)
    if not serial then
      notify(err, vim.log.levels.ERROR)
      done(nil, nil, err)
      return
    end
    done(serial, choice, nil)
  end)
end

---Always enumerate and show the picker, including when only one device is ready.
---`opts.devices` / `opts.ui_select` are deterministic headless test seams.
function M.select(opts, done)
  opts = opts or {}
  done = done or function() end
  local notify = opts.notify or vim.notify

  if type(opts.devices) == "table" then
    choose_rows(opts, opts.devices, done)
    return
  end
  if opts.output ~= nil then
    choose_rows(opts, M.parse_devices(opts.output), done)
    return
  end

  local adb = adb_executable(opts.adb)
  if vim.fn.executable(adb) ~= 1 and vim.fn.filereadable(adb) ~= 1 then
    local message = "adb not found in PATH"
    notify(message, vim.log.levels.ERROR)
    done(nil, nil, message)
    return
  end

  local ok_spawn, handle = pcall(vim.system,
    { adb, "devices", "-l" },
    { text = true },
    function(result)
      vim.schedule(function()
        if not result or result.code ~= 0 then
          local detail = trim(result and result.stderr or "")
          local message = "`adb devices -l` failed" .. (detail ~= "" and (": " .. detail) or "")
          notify(message, vim.log.levels.ERROR)
          done(nil, nil, message)
          return
        end
        choose_rows(opts, M.parse_devices(result.stdout or ""), done)
      end)
    end)
  if not ok_spawn then
    local message = "Failed to start `adb devices -l`: " .. tostring(handle)
    notify(message, vim.log.levels.ERROR)
    done(nil, nil, message)
    return
  end
  pcall(function()
    require("utils.task_registry").register({
      name = "List Android devices",
      group = "android",
      kind = "system",
      handle = handle,
      started_at = os.time(),
    })
  end)
end

---Use the explicit process-local selection, or ask once for this process.
function M.ensure(opts, done)
  opts = opts or {}
  done = done or function() end
  local serial = M.get()
  if serial then
    done(serial, nil, nil)
    return serial
  end
  M.select(opts, done)
  return nil
end

return M
