local runtime = require("ue.workflows._runtime")

local M = {}

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function deps(request)
  local context = request.context or {}
  local logger = context.logger or require("utils.log")
  return {
    resolve_context = context.resolve_context,
    read_state = context.read_state,
    target_context = context.target_context,
    android_device = context.android_device or require("utils.android_device"),
    host_driver = request.host_driver or require("utils.platform").driver(),
    targets = context.targets or require("ue.targets"),
    target_tasks = context.target_tasks or require("ue.target_tasks"),
    stop_android_debugger = context.stop_android_debugger or require("ue.dap").stop_android_debugger,
    open_terminal_command = context.open_terminal_command,
    workspace_root = context.workspace_root,
    notify_error = context.notify_error or function(scope, message)
      logger.notify_error(scope, message)
    end,
    logger = logger,
    reinvoke = context.reinvoke,
  }
end

local function build_snapshot(ctx, host_driver, serial, package_name, target_ctx)
  return runtime.snapshot({
    operation = "so_deploy",
    owner = "android.so_deploy",
    project = { canonical = trim(ctx and ctx.project_root or ctx and ctx.engine_root) },
    target = { id = "Android" },
    configuration = trim(target_ctx and target_ctx.configuration),
    host = { id = type(host_driver) == "table" and host_driver.id or "" },
    device = { serial = serial },
    runtime = { package_name = trim(package_name) },
    context = {
      engine_root = trim(ctx and ctx.engine_root),
      project_root = trim(ctx and ctx.project_root),
      uproject = trim(ctx and ctx.uproject),
      target = trim(target_ctx and target_ctx.target),
    },
  })
end

function M.command(ctx, serial, package_name, host_driver, injected)
  injected = injected or {}
  local target_context = injected.target_context
  if type(target_context) ~= "function" then
    return nil, "Android deploy workflow requires target_context"
  end
  local target_ctx, context_err = target_context(ctx, "Android")
  if not target_ctx then
    return nil, context_err
  end
  local snapshot = build_snapshot(ctx, host_driver, serial, package_name, target_ctx)
  target_ctx.device_id = snapshot.device.serial
  target_ctx.package_name = snapshot.runtime.package_name
  local plan = (injected.targets or require("ue.targets")).plan("Android", "so_deploy", target_ctx, host_driver)
  local command, command_err = (injected.target_tasks or require("ue.target_tasks")).command(plan)
  return command, command_err, plan, snapshot
end

function M.run(request)
  local d = deps(request)
  local ctx, err = d.resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return nil, err
  end

  local serial = d.android_device.get()
  if not serial then
    d.android_device.ensure({ prompt = "Select Android device for SO deploy:" }, function(selected)
      if selected and type(d.reinvoke) == "function" then
        d.reinvoke()
      end
    end)
    return nil, "device-selection-pending"
  end

  local state = d.read_state(ctx.engine_root)
  local target_ctx, context_err = d.target_context(ctx, "Android")
  if not target_ctx then
    d.notify_error("ue.android", context_err)
    return nil, context_err
  end
  local snapshot = request.snapshot or build_snapshot(ctx, d.host_driver, serial, state.android_package, target_ctx)
  target_ctx.device_id = snapshot.device.serial
  target_ctx.package_name = snapshot.runtime.package_name
  local plan = d.targets.plan("Android", "so_deploy", target_ctx, d.host_driver)
  local command, command_err = d.target_tasks.command(plan)
  if not command then
    d.notify_error("ue.android", command_err)
    return nil, command_err
  end

  d.stop_android_debugger({ kill_orphans = true })
  d.open_terminal_command(command, {
    cwd = plan.cwd or ctx.engine_root,
    quickfix_title = "UEDeployAndroidSO",
    quickfix_root = d.workspace_root(ctx),
    tail_limit = 20,
  })
  return command, nil, snapshot
end

return {
  owner = "android.so_deploy",
  run = M.run,
  api = { command = M.command },
}
