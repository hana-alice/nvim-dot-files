local C = require("ue.targets._common")
local shell = require("utils.platform.shell")

local M = {
  id = "windows",
}

local function powershell_plan(context, operation, script, args, metadata)
  local entry, unavailable = C.resolve_host_shell(
    context.host_driver, "powershell", context, "Android", operation
  )
  if not entry then
    return unavailable
  end

  local script_args = {
    "-NoLogo",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-File",
    C.host_path(context.host_driver, script),
  }
  vim.list_extend(script_args, args)
  return C.with_appended_args(entry, script_args, metadata)
end

local function powershell_command_plan(context, operation, script, metadata)
  local entry, unavailable = C.resolve_host_shell(
    context.host_driver, "powershell", context, "Android", operation
  )
  if not entry then
    return unavailable
  end
  local plan = shell.command("powershell", entry.executable, script, {
    cwd = context.cwd,
    no_logo = false,
    metadata = metadata,
  })
  plan.metadata.host_id = context.host_driver.id
  plan.metadata.shell_kind = "powershell"
  return plan
end

function M.so_build_plan(context)
  local script = C.trim(context.android_so_script or context.so_script)
  if script == "" and C.trim(context.config_root) ~= "" then
    script = C.join_path(context.config_root, "scripts", "ue_android_so_build.ps1")
  end
  if script == "" then
    return C.unavailable("Android", "so-build", "Android SO build requires android_so_script", {
      required = { "android_so_script" },
    })
  end

  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  return powershell_plan(context, "so-build", script, {
    "-EngineRoot",
    C.host_path(context.host_driver, context.engine_root),
    "-Project",
    C.host_path(context.host_driver, context.uproject),
    "-Target",
    target_name,
    "-Platform",
    "Android",
    "-Configuration",
    configuration,
    "-WaitMutex",
    "-FromMsBuild",
  }, {
    target = target_name,
    platform = "Android",
    configuration = configuration,
    workflow = "android-so-only",
    host_adapter = M.id,
  })
end

function M.so_deploy_plan(context)
  local script = C.join_path(context.config_root, "scripts", "ue_android_so_deploy.ps1")
  if not context.is_file(script) then
    return C.unavailable("Android", "so-deploy", "Android SO deploy script not found: " .. script)
  end

  return powershell_plan(context, "so-deploy", script, {
    "-Adb",
    "adb",
    "-Serial",
    context.device_id,
    "-Package",
    context.package_name,
    "-SourceSo",
    C.host_path(context.host_driver, context.source_so),
  }, {
    platform = "Android",
    target = C.context_target(context),
    configuration = C.context_configuration(context),
    workflow = "android-so-deploy",
    host_adapter = M.id,
  })
end

function M.launch_plan(context)
  local script = C.join_path(context.config_root, "scripts", "ue_android_so_launch.ps1")
  if type(context.is_file) == "function" and not context.is_file(script) then
    return C.unavailable("Android", "launch", "Android launch script not found: " .. script)
  end
  return powershell_plan(context, "launch", script, {
    "-Adb",
    C.host_path(context.host_driver, context.adb or "adb"),
    "-Serial",
    context.device_id,
    "-Package",
    context.package_name,
  }, {
    platform = "Android",
    workflow = "android-launch",
    host_adapter = M.id,
  })
end

function M.log_plan(context)
  local quote = function(value)
    return shell.quote("powershell", value)
  end
  local script = ([[$ErrorActionPreference = 'Stop'
$adb = %s
$serial = %s
$pkg = %s
$uidLine = ((& $adb -s $serial shell cmd package list packages -U $pkg 2>$null) | Out-String)
$uidMatch = [regex]::Match($uidLine, 'uid:(\d+)')
if (-not $uidMatch.Success) {
  $dump = ((& $adb -s $serial shell dumpsys package $pkg 2>$null) | Out-String)
  $uidMatch = [regex]::Match($dump, 'userId=(\d+)')
}
if (-not $uidMatch.Success) {
  throw ('Failed to resolve app uid for ' + $pkg)
}
$uid = $uidMatch.Groups[1].Value
Write-Output ('Following Android logcat for ' + $pkg + ' (uid=' + $uid + ', serial=' + $serial + ')')
& $adb -s $serial logcat --uid=$uid -v time
exit $LASTEXITCODE]]):format(
    quote(C.host_path(context.host_driver, context.adb or "adb")),
    quote(context.device_id),
    quote(context.package_name)
  )
  return powershell_command_plan(context, "log", script, {
    platform = "Android",
    workflow = "android-logcat",
    host_adapter = M.id,
  })
end

function M.install_plan(context)
  local adb = C.host_path(context.host_driver, context.adb or "adb")
  local apk = C.host_path(context.host_driver, context.apk)
  return C.plan(adb, {
    "-s",
    context.device_id,
    "install",
    "-r",
    apk,
  }, context.cwd, {
    platform = "Android",
    workflow = "android-install",
    host_adapter = M.id,
    artifact = apk,
  })
end

return M
