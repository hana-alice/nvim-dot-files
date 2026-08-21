local C = require("ue.targets._common")

local TARGET = "IOS"
local M = {}

function M.plan(context, host_driver, bundle_id, bundle_err)
  local device_id = C.trim(context and context.device_id)
  if device_id == "" then
    return C.unavailable(TARGET, "launch", "device_id is required for launch", {
      required = { "device_id" },
    })
  end
  if not bundle_id then
    return C.unavailable(TARGET, "launch", bundle_err, {
      required = { "bundle_id" },
    })
  end

  local output = C.trim(context and context.json_output)
  if output == "" then
    return C.unavailable(TARGET, "launch", "json_output is required for IOS launch", {
      required = { "json_output" },
    })
  end

  local device_backend = C.trim(context and context.device_backend)
  if device_backend == "legacy-mobiledevice" then
    local device_transport = C.trim(context and context.device_transport)
    if device_transport == "" then
      device_transport = "usb"
    end
    if device_transport ~= "usb" and device_transport ~= "network" then
      return C.unavailable(TARGET, "launch", "legacy IOS device transport must be usb or network", {
        device_transport = device_transport,
      })
    end
    local script = C.normalize_path(context and context.legacy_launch_script)
    local signing = type(context and context.legacy_signing) == "table" and context.legacy_signing or {}
    local app = C.normalize_path(signing.prepared_app)
    if script == "" or app == "" then
      return C.unavailable(TARGET, "launch", "prepared legacy IOS launch evidence is incomplete", {
        required = { "legacy_launch_script", "legacy_signing.prepared_app" },
      })
    end
    local ios_deploy, unavailable = C.resolve_host_entry(host_driver, "ios_deploy_entry", context, TARGET, "launch")
    if not ios_deploy then
      return unavailable
    end
    local shell, shell_unavailable = C.resolve_host_shell(host_driver, "posix", context, TARGET, "launch")
    if not shell then
      return shell_unavailable
    end
    return C.with_appended_args(shell, {
      script,
      "--ios-deploy",
      ios_deploy.executable,
      "--device",
      device_id,
      "--transport",
      device_transport,
      "--bundle-id",
      bundle_id,
      "--app",
      app,
      "--json-output",
      output,
    }, {
      backend = device_backend,
      transport = device_transport,
      device_id = device_id,
      bundle_id = bundle_id,
      app_path = app,
      parser = "parse_launch_result",
      json_output = output,
    })
  end
  if device_backend ~= "" and device_backend ~= "coredevice" then
    return C.unavailable(TARGET, "launch", "selected IOS device backend is unsupported", {
      device_backend = device_backend,
    })
  end

  local entry, unavailable = C.resolve_host_entry(host_driver, "xcrun_entry", context, TARGET, "launch")
  if not entry then
    return unavailable
  end
  return C.with_appended_args(entry, {
    "devicectl",
    "device",
    "process",
    "launch",
    "--device",
    device_id,
    bundle_id,
    "--json-output",
    output,
  }, {
    device_id = device_id,
    bundle_id = bundle_id,
    parser = "parse_launch_result",
    json_output = output,
  })
end

function M.parse_result(payload, expected)
  local decoded = payload
  if type(payload) == "string" then
    local ok, parsed = pcall(vim.json.decode, payload)
    if not ok then
      return C.unavailable(TARGET, "launch", "failed to parse IOS launch json", {
        detail = parsed,
      })
    end
    decoded = parsed
  end

  local result = decoded and (decoded.result or decoded)
  local process = result and (result.process or result.launchedProcess or result.applicationProcess) or nil
  local device_id = C.trim(result and (result.deviceIdentifier or result.device or result.targetDeviceIdentifier))
  local bundle_id = C.trim(
    result
      and (
        result.bundleIdentifier
        or result.bundleID
        or process and (process.bundleIdentifier or process.bundleID or process.applicationIdentifier)
      )
  )
  local process_id = result
    and (result.processIdentifier or result.pid or process and (process.processIdentifier or process.pid))

  if device_id == "" or bundle_id == "" or process_id == nil then
    return C.unavailable(TARGET, "launch", "IOS launch result missing process identity")
  end
  if expected and expected.device_id and device_id ~= expected.device_id then
    return C.unavailable(TARGET, "launch", "IOS launch result device mismatch", {
      expected_device_id = expected.device_id,
      actual_device_id = device_id,
    })
  end
  if expected and expected.bundle_id and bundle_id ~= expected.bundle_id then
    return C.unavailable(TARGET, "launch", "IOS launch result bundle mismatch", {
      expected_bundle_id = expected.bundle_id,
      actual_bundle_id = bundle_id,
    })
  end

  return {
    ok = true,
    device_id = device_id,
    bundle_id = bundle_id,
    process_id = process_id,
  }
end

return M
