local runtime = require("ue.workflows._runtime")

local M = {
  owner = "android.launch",
}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function dependencies(request)
  local deps = request.deps or request.context or {}
  local logger = deps.logger or require("utils.log")
  return {
    resolve_context = deps.resolve_context,
    read_state = deps.read_state,
    update_state_field = deps.update_state_field,
    android_device = deps.android_device or require("utils.android_device"),
    targets = deps.targets or require("ue.targets"),
    target_tasks = deps.target_tasks or require("ue.target_tasks"),
    resolve_tool = deps.resolve_tool or require("utils.platform").resolve_tool,
    host_driver = request.host_driver or deps.host_driver or require("utils.platform").driver(),
    input = deps.input or vim.fn.input,
    is_file = deps.is_file or require("ue.core.fs").is_file,
    config_root = deps.config_root or vim.fn.stdpath("config"),
    cwd = deps.cwd or vim.fn.getcwd(),
    jobstart = deps.jobstart or vim.fn.jobstart,
    schedule = deps.schedule or vim.schedule,
    task_registry = deps.task_registry
      or (pcall(require, "utils.task_registry") and require("utils.task_registry") or nil),
    notify = deps.notify or function(scope, message, level)
      logger.notify(scope, message, level)
    end,
    notify_error = deps.notify_error or function(scope, message)
      logger.notify_error(scope, message)
    end,
    reinvoke = deps.reinvoke,
  }
end

local function read_package(ctx, deps)
  local state = type(deps.read_state) == "function" and deps.read_state(ctx.engine_root) or ctx.state or {}
  local package_name = trim(state and state.android_package)
  if package_name == "" then
    package_name = trim(deps.input("Android package name: ", ""))
  end
  if package_name == "" then
    return nil, "Android package name is required"
  end
  if trim(state and state.android_package) ~= package_name and type(deps.update_state_field) == "function" then
    local ok, err = deps.update_state_field(ctx.engine_root, "android_package", package_name)
    if ok == false or ok == nil then
      return nil, err or "failed to persist Android package name"
    end
  end
  return package_name
end

local function resolve_adb(deps)
  local result = deps.resolve_tool({
    name = "adb",
    env = { "UE_ADB" },
    driver = deps.host_driver,
    driver_candidates = { "adb" },
  })
  if not result or result.ok ~= true then
    return nil, "adb not found in PATH"
  end
  return result.path
end

local function make_snapshot(request, ctx, serial, package_name, adb, host_driver)
  return request.snapshot
    or runtime.snapshot({
      operation = "launch",
      owner = M.owner,
      project = { canonical = trim(ctx.project_root or ctx.engine_root) },
      target = { id = request.target_id or "Android" },
      configuration = trim(ctx.configuration),
      host = { id = host_driver and host_driver.id or "" },
      device = { serial = serial },
      runtime = { package_name = package_name, adb = adb },
      context = {
        engine_root = trim(ctx.engine_root),
        project_root = trim(ctx.project_root),
        uproject = trim(ctx.uproject),
      },
    })
end

function M.prepare(request, opts)
  opts = opts or {}
  local deps = dependencies(request)
  if type(deps.resolve_context) ~= "function" then
    return nil, "Android launch workflow requires resolve_context"
  end
  local ctx, context_err = deps.resolve_context()
  if not ctx then
    return nil, context_err
  end

  local serial = deps.android_device.get()
  if not serial then
    if opts.prompt_device == false then
      return nil, "Android device is not selected; run :UESetAndroidDevice"
    end
    deps.android_device.ensure({ prompt = "Select Android device for UE launch:" }, function(selected)
      if selected and type(deps.reinvoke) == "function" then
        deps.reinvoke()
      end
    end)
    return nil, "device-selection-pending"
  end

  local package_name, package_err = read_package(ctx, deps)
  if not package_name then
    return nil, package_err
  end
  local adb, adb_err = resolve_adb(deps)
  if not adb then
    return nil, adb_err
  end
  local snapshot = make_snapshot(request, ctx, serial, package_name, adb, deps.host_driver)
  local plan = deps.targets.plan(request.target_id or "Android", "launch", {
    config_root = deps.config_root,
    cwd = deps.cwd,
    adb = snapshot.runtime.adb,
    device_id = snapshot.device.serial,
    package_name = snapshot.runtime.package_name,
  }, deps.host_driver)
  local command, command_err = deps.target_tasks.command(plan)
  if not command then
    return nil, command_err
  end
  return {
    snapshot = snapshot,
    plan = plan,
    command = command,
    dependencies = deps,
  }
end

function M.run(request)
  local prepared, prepare_err = M.prepare(request)
  if not prepared then
    if prepare_err ~= "device-selection-pending" then
      dependencies(request).notify_error("ue_launch", prepare_err)
    end
    return nil, prepare_err
  end
  local snapshot = prepared.snapshot
  local deps = prepared.dependencies
  local output = {}
  local function append(data)
    for _, line in ipairs(data or {}) do
      line = trim(line)
      if line ~= "" then
        output[#output + 1] = line
      end
    end
  end

  local ok, jobid = pcall(deps.jobstart, prepared.command, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      append(data)
    end,
    on_stderr = function(_, data)
      append(data)
    end,
    on_exit = function(_, code)
      deps.schedule(function()
        if code == 0 then
          deps.notify(
            "ue_launch",
            ("Android app launched: %s on %s"):format(snapshot.runtime.package_name, snapshot.device.serial),
            vim.log.levels.INFO
          )
          return
        end
        local detail = #output > 0 and ("\n" .. table.concat(output, "\n")) or ""
        deps.notify_error("ue_launch", ("Android launch failed (exit %d)%s"):format(code, detail))
      end)
    end,
  })
  if not ok or not jobid or jobid <= 0 then
    local message = "Failed to start Android launch job"
    deps.notify_error("ue_launch", message)
    return nil, message, snapshot
  end
  if deps.task_registry and type(deps.task_registry.register) == "function" then
    pcall(deps.task_registry.register, {
      name = "UELaunch (" .. snapshot.runtime.package_name .. ")",
      group = "android",
      kind = "job",
      handle = jobid,
      started_at = os.time(),
    })
  end
  return jobid, nil, snapshot
end

function M._command_for_test(adb, serial, package_name, host_driver)
  local plan = require("ue.targets").plan("Android", "launch", {
    config_root = vim.fn.stdpath("config"),
    cwd = vim.fn.getcwd(),
    adb = adb,
    device_id = serial,
    package_name = package_name,
  }, host_driver or require("utils.platform.windows"))
  return require("ue.target_tasks").command(plan)
end

M.api = {
  command = M._command_for_test,
}

return M
