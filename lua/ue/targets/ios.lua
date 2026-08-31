local C = require("ue.targets._common")
local Device = require("ue.targets.ios_device")
local Install = require("ue.targets.ios_install")
local Launch = require("ue.targets.ios_launch")
local Signing = require("ue.targets.ios_signing")
local BuildEvidence = require("ue.targets.ios_build_evidence")
local M = {
  id = "IOS",
  host_operations = {
    macos = {
      build = true,
      semantic_cdb = true,
      signing = true,
      setup = true,
      package = true,
      symbols = true,
      device = true,
      install = true,
      launch = true,
      dap_attach = true, dap_launch = true,
    },
  },
  runtime = {
    launch = { strategy = "managed-device" },
    main_log = { strategy = "unavailable" },
    debug_log = { strategy = "unavailable" },
  },
}
local DAILY_SYMBOL_OVERRIDE =
  "-ini:Engine:[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:bGeneratedSYMFile=False,[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:bGeneratedSYMBundle=False"

local function iteration_script(context)
  local config_root = C.normalize_path(context and context.config_root)
  if config_root == "" then return nil end
  return C.join_path(config_root, "scripts", "ue_ios_cpp_iteration.zsh")
end

local function normalize_bundle_id(value)
  local bundle_id = C.trim(value)
  if bundle_id == "" then
    return nil, "bundle identifier is required"
  end
  if bundle_id:find("..", 1, true) then
    return nil, "bundle identifier cannot contain empty segments"
  end
  if bundle_id:sub(1, 1) == "." or bundle_id:sub(-1) == "." then
    return nil, "bundle identifier cannot start or end with a dot"
  end
  if not bundle_id:match("^[A-Za-z0-9%.%-]+$") then
    return nil, "bundle identifier contains unsupported characters"
  end
  for segment in bundle_id:gmatch("[^%.]+") do
    if not segment:match("^[A-Za-z0-9][A-Za-z0-9%-]*$") then
      return nil, "bundle identifier contains an invalid segment"
    end
  end
  return bundle_id
end

local function artifact_tuple(context)
  return {
    project = C.trim(context and (context.project or context.uproject)),
    target = C.context_target(context),
    platform = M.id,
    configuration = C.context_configuration(context),
  }
end

local function make_provenance(path, context, metadata)
  return {
    path = C.normalize_path(path),
    tuple = artifact_tuple(context),
    metadata = C.deepcopy(metadata or {}),
  }
end

local function select_candidate_app(candidates, context)
  local expected = artifact_tuple(context)
  local matches = {}
  local ipa_only = false

  for _, candidate in ipairs(candidates or {}) do
    local path = C.normalize_path(candidate.path or candidate.app_path or candidate.ipa_path)
    local tuple = candidate.tuple or {}
    local platform = C.trim(tuple.platform or candidate.platform)
    local target = C.trim(tuple.target or candidate.target)
    local configuration = C.trim(tuple.configuration or candidate.configuration)

    if path:sub(-4) == ".ipa" then
      ipa_only = true
    end

    if
      path:sub(-4) == ".app"
      and platform == expected.platform
      and (expected.target == "" or target == expected.target)
      and (expected.configuration == "" or configuration == expected.configuration)
    then
      matches[#matches + 1] = {
        path = path,
        tuple = {
          platform = platform,
          target = target,
          configuration = configuration,
        },
        metadata = C.deepcopy(candidate.metadata or {}),
      }
    end
  end

  if #matches == 1 then
    local selected = matches[1]
    return {
      ok = true,
      app_path = selected.path,
      provenance = make_provenance(selected.path, context, selected.metadata),
    }
  end

  if #matches > 1 then
    return C.unavailable(M.id, "install", "multiple staged apps match current tuple", {
      candidate_count = #matches,
    })
  end

  if ipa_only then
    return C.unavailable(M.id, "install", "staged .app missing for current tuple", {
      suggestion = "re-run stage/package to produce a staged .app",
    })
  end

  return C.unavailable(M.id, "install", "no staged app matches current tuple")
end

function M.capabilities()
  return C.default_capabilities(M.id, {
    build = true,
    package = true,
    symbols = true,
    device = true,
    install = true,
    launch = true,
  })
end

function M.dap_artifacts(context)
  local project_dir = C.normalize_path(context and context.project_dir)
  local target = C.context_target(context)
  if project_dir == "" or target == "" then
    return nil
  end
  local binary = C.join_path(project_dir, "Binaries", M.id, target)
  return {
    binary = binary,
    dsym = binary .. ".dSYM",
  }
end

function M.dap_tool_names(backend)
  if backend == "coredevice" then
    return { xcrun = "xcrun" }
  end
  if backend == "legacy-mobiledevice" then
    return {
      ios_deploy = "ios-deploy",
      ideviceinfo = "ideviceinfo",
      ideviceinstaller = "ideviceinstaller",
      plutil = "plutil",
      xcrun = "xcrun",
    }
  end
  return nil
end

function M.build_plan(context, host_driver)
  local entry, unavailable = C.resolve_host_entry(host_driver, "ue_build_entry", context, M.id, "build")
  if not entry then
    return unavailable
  end

  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  local signing_arg, signing_unavailable, signing_identity = Signing.override(context, false)
  if signing_unavailable then return signing_unavailable end
  local native_args = {
    target_name,
    M.id,
    configuration,
    "-Project=" .. C.trim(context.uproject),
    "-WaitMutex",
    "-FromMsBuild",
    "-disablev8pointercompression",
    DAILY_SYMBOL_OVERRIDE,
  }
  if signing_arg then native_args[#native_args + 1] = signing_arg end
  local native_plan = C.with_appended_args(entry, native_args, {
    target = target_name,
    platform = M.id,
    configuration = configuration,
    signing_identity_configured = signing_identity ~= nil,
  })

  local script = iteration_script(context)
  if not script then return native_plan end

  local shell_entry, shell_unavailable = C.resolve_host_shell(host_driver, "posix", context, M.id, "build")
  if not shell_entry then return shell_unavailable end
  local xcrun, xcrun_unavailable = C.resolve_host_entry(host_driver, "xcrun_entry", context, M.id, "build")
  if not xcrun then return xcrun_unavailable end

  local args = {
    script,
    "build",
    "--project-dir",
    C.normalize_path(context.project_dir),
    "--cache-dir",
    C.join_path(C.normalize_path(context.engine_root), ".cache", "nvim-ue", "ios-aot"),
    "--target",
    target_name,
    "--configuration",
    configuration,
    "--xcrun",
    xcrun.executable,
    "--",
    native_plan.executable,
  }
  vim.list_extend(args, native_plan.args)
  return C.with_appended_args(shell_entry, args, {
    target = target_name,
    platform = M.id,
    configuration = configuration,
    optimization = "cpp-iteration",
    underlying = {
      executable = native_plan.executable,
      args = native_plan.args,
    },
  })
end

M.build_receipt_evidence = BuildEvidence.from_receipt
function M.semantic_cdb_plan(context, host_driver)
  local entry, unavailable = C.resolve_host_entry(
    host_driver, "ue_build_entry", context, M.id, "semantic_cdb"
  )
  if not entry then return unavailable end

  local output_dir = C.normalize_path(context and context.semantic_cdb_output_dir)
  local output_filename = C.trim(context and context.semantic_cdb_output_filename)
  if output_dir == "" or output_filename == "" then
    return C.unavailable(M.id, "semantic_cdb", "semantic CDB output path is required", {
      required = { "semantic_cdb_output_dir", "semantic_cdb_output_filename" },
    })
  end

  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  local plan = C.with_appended_args(entry, {
    target_name,
    M.id,
    configuration,
    "-Project=" .. C.trim(context.uproject),
    "-Mode=GenerateClangDatabase",
    "-OutputDir=" .. output_dir,
    "-OutputFilename=" .. output_filename,
    "-NoExecCodeGenActions",
    "-UsePCH",
  }, {
    operation = "semantic_cdb",
    target = target_name,
    platform = M.id,
    configuration = configuration,
    output = C.join_path(output_dir, output_filename),
    compiles = false,
    cooks = false,
    packages = false,
  })
  -- Sharphereal.build.cs performs AOT directly while UBT constructs its
  -- action graph. GenerateClangDatabase needs the module graph, never the AOT
  -- outputs, so suppress that project hook only for this semantic subprocess.
  plan.env = { bSkipAOTProcess = "true" }
  return plan
end

function M.validate_semantic_cdb(entries, context)
  local target = C.context_target(context)
  local configuration = C.context_configuration(context)
  local tuple_marker = target ~= "" and configuration ~= ""
    and ("/Intermediate/Build/IOS/" .. target .. "/" .. configuration .. "/")
    or nil
  local matched = 0
  for _, entry in ipairs(entries or {}) do
    local command = entry.command
    if not command and type(entry.arguments) == "table" then
      command = table.concat(entry.arguments, " ")
    end
    local evidence = table.concat({
      tostring(entry.file or ""),
      tostring(entry.output or ""),
      tostring(command or ""),
    }, " "):gsub("\\", "/")
    local has_ios_evidence = evidence:find("/Intermediate/Build/IOS/", 1, true)
      or evidence:find("iPhoneOS.platform", 1, true)
      or evidence:find("-miphoneos-version-min=", 1, true)
    local has_tuple_evidence = tuple_marker == nil or evidence:find(tuple_marker, 1, true)
    if has_ios_evidence and has_tuple_evidence then
      matched = matched + 1
    end
  end

  if matched == 0 then
    local expected = tuple_marker and (target .. "/" .. configuration) or "IOS"
    return {
      ok = false,
      reason = "missing IOS compiler tuple evidence for " .. expected,
      matched = 0,
    }
  end
  if matched ~= #(entries or {}) then
    local expected = tuple_marker and (target .. "/" .. configuration) or "IOS"
    return {
      ok = false,
      reason = ("mixed or unproven IOS compiler evidence for %s (%d/%d entries)"):format(
        expected, matched, #(entries or {})
      ),
      matched = matched,
    }
  end
  return { ok = true, matched = matched }
end

function M.package_plan(context, host_driver)
  local entry, unavailable = C.resolve_host_entry(host_driver, "ue_uat_entry", context, M.id, "package")
  if not entry then
    return unavailable
  end

  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  local signing_arg, signing_unavailable = Signing.override(context, true)
  if not signing_arg then return signing_unavailable end
  return C.with_appended_args(entry, {
    "-ScriptsForProject=" .. C.trim(context.uproject),
    "BuildCookRun",
    "-nop4",
    "-project=" .. C.trim(context.uproject),
    "-target=" .. target_name,
    "-targetplatform=" .. M.id,
    "-clientconfig=" .. configuration,
    "-skipbuild",
    "-skipcook",
    "-stage",
    "-nocleanstage",
    "-package",
    "-nodebuginfo",
    signing_arg,
    "-utf8output",
  }, {
    target = target_name,
    platform = M.id,
    configuration = configuration,
    stages = { "stage", "package" },
    reuses_cooked_data = true,
  })
end

function M.parse_signing_identities(output)
  return Signing.parse(output)
end

function M.validate_signing_identity(value)
  local identity, err = Signing.validate(value)
  if not identity then return C.unavailable(M.id, "signing", err) end
  return { ok = true, identity = identity }
end

function M.resolve_signing_identity(identities, query)
  return Signing.resolve(identities, query)
end

function M.signing_identity_list_plan(context, host_driver)
  return Signing.list_plan(context, host_driver)
end

function M.prepared_signing_identity(project_root)
  return Signing.load_prepared_config(project_root)
end

function M.symbols_plan(context, host_driver)
  local script = iteration_script(context)
  if not script then
    return C.unavailable(M.id, "symbols", "config_root is required for the iOS symbol helper", {
      required = { "config_root" },
    })
  end
  local shell_entry, shell_unavailable = C.resolve_host_shell(host_driver, "posix", context, M.id, "symbols")
  if not shell_entry then return shell_unavailable end
  local xcrun, xcrun_unavailable = C.resolve_host_entry(host_driver, "xcrun_entry", context, M.id, "symbols")
  if not xcrun then return xcrun_unavailable end

  local target_name = C.context_target(context)
  local binary = C.join_path(C.normalize_path(context.project_dir), "Binaries", M.id, target_name)
  return C.with_appended_args(shell_entry, {
    script,
    "symbols",
    "--xcrun",
    xcrun.executable,
    "--binary",
    binary,
  }, {
    target = target_name,
    platform = M.id,
    configuration = C.context_configuration(context),
    binary = binary,
    output = binary .. ".dSYM",
  })
end

function M.device_list_plan(context, host_driver)
  local entry, unavailable = C.resolve_host_entry(host_driver, "xcrun_entry", context, M.id, "device")
  if not entry then
    return unavailable
  end

  local output = C.trim((context or {}).json_output or (context or {}).output_path)
  if output == "" then
    return C.unavailable(M.id, "device", "json_output is required for devicectl list", {
      required = { "json_output" },
    })
  end

  return C.with_appended_args(entry, {
    "devicectl",
    "list",
    "devices",
    "--json-output",
    output,
  }, {
    json_output = output,
    parser = "parse_device_list",
  })
end

M.fallback_device_list_plan = Device.fallback_device_list_plan
M.mobiledevice_device_list_plans = Device.mobiledevice_device_list_plans
M.parse_mobiledevice_device_list = Device.parse_mobiledevice_device_list
M.mobiledevice_info_plan = Device.mobiledevice_info_plan
M.parse_mobiledevice_info = Device.parse_mobiledevice_info
M.install_progress_tracker = Install.progress_tracker

function M.install_failure_reason(result, plan)
  if plan and plan.metadata and plan.metadata.backend == "legacy-mobiledevice" then
    return Install.failure_reason(result)
  end
end

function M.bundle_id_plan(app_path, host_driver, context)
  local plist_entry, unavailable = C.resolve_host_entry(host_driver, "plutil_entry", context or {}, M.id, "launch")
  if not plist_entry then
    return unavailable
  end

  local plist_path = C.normalize_path(app_path) .. "/Info.plist"
  return C.with_appended_args(plist_entry, {
    "-extract",
    "CFBundleIdentifier",
    "raw",
    "-o",
    "-",
    plist_path,
  }, {
    app_path = C.normalize_path(app_path),
    plist_path = plist_path,
    parser = "validate_bundle_id",
  })
end

function M.install_plan(context, host_driver)
  local selected = M.select_staged_artifact(context and context.artifacts or {}, context)
  if not selected.ok then
    return selected
  end

  local device_id = C.trim(context and context.device_id)
  if device_id == "" then
    return C.unavailable(M.id, "install", "device_id is required for install", {
      required = { "device_id" },
    })
  end
  local device_backend = C.trim(context and context.device_backend)
  if device_backend == "legacy-mobiledevice" then
    return Install.legacy_plan(context, selected, {
      validate_signing = Signing.validate,
      validate_bundle_id = normalize_bundle_id,
    })
  end
  if device_backend ~= "" and device_backend ~= "coredevice" then
    return C.unavailable(M.id, "install", "selected IOS device backend is unsupported", {
      device_backend = device_backend,
    })
  end

  local entry, unavailable = C.resolve_host_entry(host_driver, "xcrun_entry", context, M.id, "install")
  if not entry then
    return unavailable
  end

  local output = C.trim(context and context.json_output)
  if output == "" then
    return C.unavailable(M.id, "install", "json_output is required for devicectl install", {
      required = { "json_output" },
    })
  end

  return C.with_appended_args(entry, {
    "devicectl",
    "device",
    "install",
    "app",
    "--device",
    device_id,
    selected.app_path,
    "--json-output",
    output,
  }, {
    device_id = device_id,
    app_path = selected.app_path,
    provenance = selected.provenance,
    parser = "parse_install_result",
    json_output = output,
  })
end

function M.launch_plan(context, host_driver)
  local bundle_id, err = normalize_bundle_id(context and context.bundle_id)
  return Launch.plan(context, host_driver, bundle_id, err)
end

function M.classify_rsp(candidate, context)
  return C.classify_for_platform(M.id, M.id, candidate, context)
end

function M.validate_bundle_id(value)
  local bundle_id, err = normalize_bundle_id(value)
  if not bundle_id then
    return C.unavailable(M.id, "launch", err, {
      input = value,
    })
  end
  return {
    ok = true,
    bundle_id = bundle_id,
  }
end

function M.select_staged_artifact(candidates, context)
  return select_candidate_app(candidates, context or {})
end

function M.artifact_candidates(context)
  context = context or {}
  local project_dir = C.normalize_path(context.project_dir)
  local target_name = C.context_target(context)
  local configuration = C.context_configuration(context)
  if project_dir == "" or target_name == "" then
    return C.unavailable(M.id, "artifact", "project_dir and target are required", {
      required = { "project_dir", "target" },
    })
  end

  local tuple = {
    platform = M.id,
    target = target_name,
    configuration = configuration,
  }
  local candidates = {
    {
      path = C.join_path(project_dir, "Binaries", M.id, "Payload", target_name .. ".app"),
      tuple = tuple,
      metadata = { kind = "staged-app", source = "uat-package-payload" },
    },
    {
      path = C.join_path(project_dir, "Binaries", M.id, target_name .. ".ipa"),
      tuple = tuple,
      metadata = { kind = "ipa", source = "project-binaries" },
    },
  }
  return { ok = true, candidates = candidates }
end

function M.parse_device_list(payload)
  local decoded = payload
  if type(payload) == "string" then
    local ok, parsed = pcall(vim.json.decode, payload)
    if not ok then
      return C.unavailable(M.id, "device", "failed to parse devicectl device list json", {
        detail = parsed,
      })
    end
    decoded = parsed
  end

  local devices = decoded and (decoded.devices or decoded.result and decoded.result.devices)
  if type(devices) ~= "table" then
    return C.unavailable(M.id, "device", "devicectl device list schema missing devices")
  end

  local available = {}
  for _, item in ipairs(devices) do
    local hardware = item.hardwareProperties or {}
    local connection = item.connectionProperties or {}
    local properties = item.deviceProperties or {}
    local platform = C.trim(item.platform or item.operatingSystem or item.runtimePlatform or hardware.platform or "")
    local tunnel = C.trim(connection.tunnelState):lower()
    local available_now = item.available == true
      or C.trim(item.availability):lower() == "available"
      or (connection.pairingState == "paired" and tunnel == "connected")
    local physical = item.physical == true
      or hardware.reality == "physical"
      or hardware.deviceType == "iPhone"
      or hardware.deviceType == "iPad"
    if available_now and physical and platform:match("^iOS") then
      available[#available + 1] = {
        id = item.identifier or item.udid,
        name = item.name or item.displayName or properties.name or hardware.marketingName,
        platform = platform,
        os_version = properties.osVersionNumber,
        backend = "coredevice",
      }
    end
  end

  return {
    ok = true,
    devices = available,
  }
end

M.parse_fallback_device_list = Device.parse_fallback_device_list

function M.parse_install_result(payload, expected)
  local decoded = payload
  if type(payload) == "string" then
    local ok, parsed = pcall(vim.json.decode, payload)
    if not ok then
      return C.unavailable(M.id, "install", "failed to parse devicectl install json", {
        detail = parsed,
      })
    end
    decoded = parsed
  end

  local result = decoded and (decoded.result or decoded)
  local installed = result
      and (result.installedApplication or result.application or type(result.installedApplications) == "table" and result.installedApplications[1])
    or nil
  local device_id = C.trim(result and (result.deviceIdentifier or result.device or result.targetDeviceIdentifier))
  local bundle_id = C.trim(
    result
      and (
        result.bundleIdentifier
        or result.bundleID
        or result.installedBundleIdentifier
        or installed and (installed.bundleIdentifier or installed.bundleID or installed.applicationIdentifier)
      )
  )

  if device_id == "" or bundle_id == "" then
    return C.unavailable(M.id, "install", "devicectl install result missing identity")
  end
  if expected and expected.device_id and device_id ~= expected.device_id then
    return C.unavailable(M.id, "install", "devicectl install result device mismatch", {
      expected_device_id = expected.device_id,
      actual_device_id = device_id,
    })
  end
  if expected and expected.bundle_id and bundle_id ~= expected.bundle_id then
    return C.unavailable(M.id, "install", "devicectl install result bundle mismatch", {
      expected_bundle_id = expected.bundle_id,
      actual_bundle_id = bundle_id,
    })
  end

  return {
    ok = true,
    device_id = device_id,
    bundle_id = bundle_id,
  }
end

function M.parse_launch_result(payload, expected)
  return Launch.parse_result(payload, expected)
end

function M.preflight_descriptors()
  return {
    {
      stage = "build",
      requires = {
        { host_capability = "ue_build_entry", reason = "native UBT entry" },
        { host_capability = "xcrun_entry", reason = "Xcode / SDK discovery" },
      },
    },
    {
      stage = "package",
      requires = {
        { host_capability = "ue_uat_entry", reason = "BuildCookRun entry" },
        { host_capability = "xcrun_entry", reason = "Xcode / SDK discovery" },
        { host_capability = "security_entry", reason = "code-sign identity probe" },
      },
    },
    {
      stage = "symbols",
      requires = {
        { host_capability = "xcrun_entry", reason = "dsymutil and dwarfdump discovery" },
      },
    },
    {
      stage = "install",
      requires = {
        { host_capability = "xcrun_entry", reason = "devicectl install" },
        { host_capability = "plutil_entry", reason = "Info.plist bundle id probe" },
        { host_capability = "security_entry", reason = "signed artifact preflight" },
      },
    },
    {
      stage = "launch",
      requires = {
        { host_capability = "xcrun_entry", reason = "devicectl launch" },
        { host_capability = "plutil_entry", reason = "Info.plist bundle id probe" },
      },
    },
  }
end

function M.preflight_plans(stage, context, host_driver)
  return Signing.preflight_plans(stage, context, host_driver)
end

function M.validate_preflight(stage, results, context)
  return Signing.validate_preflight(stage, results, context)
end

return M
