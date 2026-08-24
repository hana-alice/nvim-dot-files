local android_device = require("utils.android_device")

local M = {
  owner = "android.log",
  operation = "log",
}

local function package_name(env, ctx)
  local value = env.trim((ctx.state or {}).android_package or "")
  if value == "" then
    value = env.trim(vim.fn.input("Android package name: ", ""))
  end
  if value == "" then
    return nil, "Android package name is required"
  end

  if ctx.engine_root and value ~= env.trim((ctx.state or {}).android_package or "") then
    env.update_state_field(ctx.engine_root, "android_package", value)
  end
  return value
end

function M.resolve(env, ctx, deps)
  deps = deps or {}
  local device = deps.android_device or android_device
  local package, package_err = package_name(env, ctx)
  if not package then
    return nil, package_err
  end

  local adb = device.adb_executable()
  if vim.fn.executable(adb) ~= 1 and not env.is_file(adb) then
    return nil, "adb not found in PATH"
  end

  local serial = device.get()
  if not serial then
    return nil, "Android device is not selected; run :UESetAndroidDevice"
  end
  local host_driver = env.host_driver or require("utils.platform").driver()
  local plan = require("ue.targets").plan("Android", "log", {
    cwd = vim.fn.getcwd(),
    adb = adb,
    device_id = serial,
    package_name = package,
  }, host_driver)
  local cmd, command_err = require("ue.target_tasks").command(plan)
  if not cmd then
    return nil, command_err
  end

  return {
    kind = "android_logcat",
    source_id = serial .. ":" .. package,
    title = "Android Logcat",
    summary = ("%s on %s"):format(package, serial),
    cmd = cmd,
    cwd = plan.cwd or vim.fn.getcwd(),
  }
end

function M.run(request)
  local payload = request.payload or {}
  local spec, err = M.resolve(payload.env, payload.context, payload)
  if not spec and err == "Android device is not selected; run :UESetAndroidDevice" then
    local device = payload.android_device or android_device
    device.ensure({ prompt = "Select Android device for UE logcat:" }, function(serial)
      if serial and type(payload.reinvoke) == "function" then
        payload.reinvoke()
      end
    end)
    return nil, nil
  end
  return spec, err
end

M.api = {
  resolve = M.resolve,
}

return M
