local C = require("ue.targets._common")

local M = {}

function M.failure_reason(result)
  local detail = tostring(result and result.stderr or "")
    .. "\n"
    .. tostring(result and result.stdout or "")
  if detail:find("physically connected over USB but unavailable to usbmuxd/MobileDevice", 1, true)
      or detail:find("matched 0 usable legacy USB devices", 1, true) then
    return "IOS device is physically connected, but the MobileDevice route is blocked; "
      .. "unlock the iPhone, allow USB accessories, confirm Trust This Computer if prompted, "
      .. "reconnect the cable, then retry <leader>ui"
  end
  if detail:find("errSecInternalComponent", 1, true) then
    return "IOS signing private key is locked or unavailable to codesign; "
      .. "unlock the login keychain in Keychain Access and allow /usr/bin/codesign, "
      .. "then retry <leader>ui"
  end
end

function M.progress_tracker(report)
  report = type(report) == "function" and report or function() end
  local pending = ""

  local function consume(line)
    line = tostring(line or ""):gsub("\27%[[0-9;]*m", "")
    if line:find("==> Select iOS device", 1, true) then
      report("Selecting iOS device", 5)
    elseif line:find("==> Recover legacy USB MobileDevice route", 1, true) then
      report("Recovering USB MobileDevice route", 10)
    elseif line:find("==> Clone and sign code app", 1, true) then
      report("Signing iOS app", 20)
    elseif line:find("==> Direct legacy update install", 1, true) then
      report("Preparing container-preserving update", 45)
    elseif line:find("Copying ", 1, true) and line:find(" to device", 1, true) then
      report("Uploading iOS app", 50)
    else
      local stage, raw_percentage = line:match("Upgrade:%s*(.-)%s*%((%d+)%%%)")
      if stage and raw_percentage then
        local percentage = 50 + math.floor(tonumber(raw_percentage) * 0.45)
        report("Installing on iPhone: " .. stage, math.min(percentage, 95))
      elseif line:find("Upgrade: Complete", 1, true) then
        report("Finalizing iOS installation", 96)
      elseif line:find("Legacy app update installed without uninstall", 1, true) then
        report("iOS app installed", 100)
      end
    end
  end

  return function(chunk)
    pending = (pending .. tostring(chunk or "")):gsub("\r", "\n")
    while true do
      local newline = pending:find("\n", 1, true)
      if not newline then break end
      consume(pending:sub(1, newline - 1))
      pending = pending:sub(newline + 1)
    end
    if #pending > 8192 then
      consume(pending)
      pending = ""
    end
  end
end

function M.legacy_plan(context, selected, validators)
  context = context or {}
  validators = validators or {}

  local script = C.normalize_path(context.legacy_install_script)
  if script == "" then
    return C.unavailable("IOS", "install", "legacy InstallIOSClient.sh is not configured", {
      required = { "legacy_install_script" },
    })
  end

  local signing = context.legacy_signing
  if type(signing) ~= "table" or type(signing.identity) ~= "table" then
    return C.unavailable("IOS", "install", "prepared signing evidence is required for legacy install", {
      required = { "legacy_signing" },
    })
  end

  local identity, identity_err = validators.validate_signing(signing.identity)
  if not identity then
    return C.unavailable("IOS", "install", "prepared signing identity is invalid: " .. tostring(identity_err))
  end
  local bundle_id, bundle_err = validators.validate_bundle_id(signing.bundle_identifier)
  if not bundle_id then
    return C.unavailable("IOS", "install", "prepared signing bundle identifier is invalid: " .. tostring(bundle_err))
  end
  local provision = C.normalize_path(signing.provision)
  if provision == "" then
    return C.unavailable("IOS", "install", "prepared signing profile is required for legacy install", {
      required = { "legacy_signing.provision" },
    })
  end

  local device_id = C.trim(context.device_id)
  if device_id == "" then
    return C.unavailable("IOS", "install", "device_id is required for install", {
      required = { "device_id" },
    })
  end
  local project_dir = C.normalize_path(context.project_dir)
  if project_dir == "" then
    return C.unavailable("IOS", "install", "project_dir is required for legacy install", {
      required = { "project_dir" },
    })
  end
  local app_path = C.normalize_path(selected and selected.app_path)
  if app_path == "" then
    return C.unavailable("IOS", "install", "tuple-scoped app path is required for legacy install", {
      required = { "app_path" },
    })
  end

  return C.plan(script, {
    "--device",
    device_id,
    "--device-backend",
    "legacy",
    "--signing-mode",
    "own",
    "--package-root",
    project_dir,
    "--app",
    app_path,
    "--identity",
    identity.fingerprint,
    "--provision",
    provision,
    "--bundle-id",
    bundle_id,
  }, project_dir, {
    backend = "legacy-mobiledevice",
    result_source = "verified-exit-code",
    device_id = device_id,
    app_path = app_path,
    bundle_id = bundle_id,
    provenance = selected.provenance,
  })
end

return M
