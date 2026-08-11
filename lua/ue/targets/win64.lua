local C = require("ue.targets._common")

local M = {
  id = "Win64",
}

function M.capabilities()
  return C.default_capabilities(M.id, {
    build = true,
  })
end

function M.build_plan(context, host_driver)
  local entry, unavailable = C.resolve_host_entry(host_driver, "ue_build_entry", context, M.id, "build")
  if not entry then
    return unavailable
  end

  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  return C.with_appended_args(entry, {
    target_name,
    M.id,
    configuration,
    "-Project=" .. C.trim(context.uproject),
    "-WaitMutex",
    "-FromMsBuild",
  }, {
    target = target_name,
    platform = M.id,
    configuration = configuration,
  })
end

function M.classify_rsp(candidate, context)
  return C.classify_for_platform(M.id, M.id, candidate, context)
end

M.package_plan = C.unsupported_operation(M.id, "package")
M.device_list_plan = C.unsupported_operation(M.id, "device")
M.install_plan = C.unsupported_operation(M.id, "install")
M.launch_plan = C.unsupported_operation(M.id, "launch")

function M.preflight_descriptors()
  return {
    {
      stage = "build",
      requires = {
        { host_capability = "ue_build_entry" },
      },
    },
  }
end

return M
