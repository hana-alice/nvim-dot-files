local C = require("ue.targets._common")

local M = {
  id = "windows",
}

local function powershell_plan(context, operation, script, args, metadata)
  local entry, unavailable =
    C.resolve_host_entry(context.host_driver, "powershell_entry", context, "Android", operation)
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

return M
