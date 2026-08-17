local C = require("ue.targets._common")

local M = {}
local TARGET = "IOS"
local SIGNING_CERTIFICATE_OVERRIDE = "-ini:Engine:[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:SigningCertificate="

function M.validate(value)
  if type(value) ~= "table" then
    return nil, "IOS signing certificate is not configured; run :UESetIOSSigningCertificate"
  end
  local fingerprint = C.trim(value.fingerprint):upper()
  local name = C.trim(value.name)
  if #fingerprint ~= 40 or not fingerprint:match("^%x+$") then
    return nil, "IOS signing certificate fingerprint is invalid; run :UESetIOSSigningCertificate"
  end
  if name == "" or name:find("[%z\r\n]") then
    return nil, "IOS signing certificate name is invalid; run :UESetIOSSigningCertificate"
  end
  if name:find(",", 1, true) then
    return nil, "IOS signing certificate names containing commas cannot be represented by Unreal ini overrides"
  end
  return {
    fingerprint = fingerprint,
    name = name,
  }
end

function M.override(context, required)
  local configured = context and context.signing_identity
  if configured == nil and not required then
    return nil
  end
  local identity, err = M.validate(configured)
  if not identity then
    return nil, C.unavailable(TARGET, "signing", err, {
      required = { "signing_identity" },
    })
  end
  return SIGNING_CERTIFICATE_OVERRIDE .. identity.name, nil, identity
end

function M.parse(output)
  output = tostring(output or "")
  local identities = {}
  local seen = {}
  for line in output:gmatch("[^\r\n]+") do
    local fingerprint, name = line:match('^%s*%d+%)%s+(%x+)%s+"(.-)"%s*$')
    if fingerprint and #fingerprint == 40 and name ~= "" then
      fingerprint = fingerprint:upper()
      if seen[fingerprint] and seen[fingerprint] ~= name then
        return C.unavailable(TARGET, "signing", "code-sign identity output contained a duplicate fingerprint")
      end
      if not seen[fingerprint] then
        seen[fingerprint] = name
        identities[#identities + 1] = {
          fingerprint = fingerprint,
          name = name,
        }
      end
    end
  end

  local reported = tonumber(output:match("(%d+)%s+valid identities found"))
  if reported == nil then
    return C.unavailable(TARGET, "signing", "code-sign identity output was missing its valid identity count")
  end
  if reported ~= #identities then
    return C.unavailable(TARGET, "signing", "code-sign identity output count did not match parsed identities", {
      reported_count = reported,
      parsed_count = #identities,
    })
  end
  return {
    ok = true,
    identities = identities,
  }
end

function M.resolve(identities, query)
  query = C.trim(query)
  if query == "" then
    return C.unavailable(TARGET, "signing", "a code-sign identity name or fingerprint is required")
  end
  local fingerprint_query = query:match("^%x+$") and #query == 40 and query:upper() or nil
  local matches = {}
  for _, candidate in ipairs(identities or {}) do
    local identity = M.validate(candidate)
    if
      identity
      and (
        (fingerprint_query and identity.fingerprint == fingerprint_query)
        or (not fingerprint_query and identity.name == query)
      )
    then
      matches[#matches + 1] = identity
    end
  end
  if #matches ~= 1 then
    return C.unavailable(
      TARGET,
      "signing",
      #matches == 0 and "selected code-sign identity is not currently valid"
        or "selected code-sign identity is ambiguous"
    )
  end
  return {
    ok = true,
    identity = matches[1],
  }
end

function M.list_plan(context, host_driver)
  local security, unavailable = C.resolve_host_entry(host_driver, "security_entry", context or {}, TARGET, "signing")
  if not security then
    return unavailable
  end
  return C.with_appended_args(security, {
    "find-identity",
    "-v",
    "-p",
    "codesigning",
  }, {
    parser = "parse_signing_identities",
  })
end

function M.load_prepared_config(project_root)
  project_root = C.normalize_path(project_root)
  if project_root == "" then
    return C.unavailable(TARGET, "signing", "project root is required to load prepared signing metadata")
  end

  local roots = { project_root }
  for _ = 1, 2 do
    local parent = C.normalize_path(vim.fs.dirname(roots[#roots]))
    if parent == "" or parent == roots[#roots] then
      break
    end
    roots[#roots + 1] = parent
  end

  local candidates = {}
  for _, root in ipairs(roots) do
    local candidate = C.join_path(root, "Saved", "IOSQADebug", "signing.json")
    if vim.uv.fs_stat(candidate) then
      candidates[#candidates + 1] = candidate
    end
  end
  local default_path = C.join_path(project_root, "Saved", "IOSQADebug", "signing.json")
  if #candidates == 0 then
    return { ok = true, found = false, path = default_path }
  end
  if #candidates > 1 then
    return C.unavailable(TARGET, "signing", "multiple prepared signing metadata files match the project", {
      candidate_count = #candidates,
    })
  end

  local path = candidates[1]
  local stat = vim.uv.fs_stat(path)
  if stat.type ~= "file" or stat.size > 64 * 1024 then
    return C.unavailable(TARGET, "signing", "prepared signing metadata is not a small regular file", {
      path = path,
    })
  end

  local handle, open_err = io.open(path, "rb")
  if not handle then
    return C.unavailable(TARGET, "signing", "prepared signing metadata could not be read", {
      path = path,
      detail = open_err,
    })
  end
  local content = handle:read("*a")
  handle:close()
  local decoded_ok, decoded = pcall(vim.json.decode, content or "")
  if not decoded_ok or type(decoded) ~= "table" or tonumber(decoded.formatVersion) ~= 1 then
    return C.unavailable(TARGET, "signing", "prepared signing metadata has an unsupported format", {
      path = path,
    })
  end

  local identity, identity_err = M.validate({
    fingerprint = decoded.identitySha1,
    name = decoded.identityName,
  })
  if not identity then
    return C.unavailable(TARGET, "signing", "prepared signing metadata identity is invalid: " .. identity_err, {
      path = path,
    })
  end
  if decoded.getTaskAllow ~= true then
    return C.unavailable(TARGET, "signing", "prepared signing metadata must require get-task-allow=true", {
      path = path,
    })
  end

  local provision = C.normalize_path(decoded.provision)
  local bundle_identifier = C.trim(decoded.bundleIdentifier)
  local team_identifier = C.trim(decoded.teamIdentifier)
  if provision == "" or bundle_identifier == "" or team_identifier == "" then
    return C.unavailable(TARGET, "signing", "prepared signing metadata is missing profile or application identity", {
      path = path,
    })
  end
  local provision_stat = vim.uv.fs_stat(provision)
  if not provision_stat or provision_stat.type ~= "file" then
    return C.unavailable(TARGET, "signing", "prepared signing profile is no longer available", {
      path = path,
    })
  end

  return {
    ok = true,
    found = true,
    path = path,
    identity = identity,
    provision = provision,
    bundle_identifier = bundle_identifier,
    team_identifier = team_identifier,
  }
end

function M.preflight_plans(stage, context, host_driver)
  local signing_identity
  if context and context.signing_identity ~= nil then
    local signing_err
    signing_identity, signing_err = M.validate(context.signing_identity)
    if not signing_identity then
      return C.unavailable(TARGET, stage, signing_err, {
        required = { "signing_identity" },
      })
    end
  elseif stage == "package" or stage == "install" then
    return C.unavailable(
      TARGET,
      stage,
      "IOS signing certificate is not configured; run :UESetIOSSigningCertificate",
      { required = { "signing_identity" } }
    )
  end

  local plans = {}
  local xcrun, xcrun_unavailable = C.resolve_host_entry(host_driver, "xcrun_entry", context, TARGET, stage)
  if not xcrun then
    return xcrun_unavailable
  end
  plans[#plans + 1] = C.with_appended_args(xcrun, {
    "--sdk",
    "iphoneos",
    "--show-sdk-path",
  }, { preflight = "iphoneos-sdk" })

  if signing_identity then
    local security, unavailable = C.resolve_host_entry(host_driver, "security_entry", context, TARGET, stage)
    if not security then
      return unavailable
    end
    plans[#plans + 1] = C.with_appended_args(security, {
      "find-identity",
      "-v",
      "-p",
      "codesigning",
    }, { preflight = "codesign-identity" })
  end

  return { ok = true, plans = plans }
end

function M.validate_preflight(stage, results, context)
  for _, result in ipairs(results or {}) do
    if tonumber(result.code) ~= 0 then
      return C.unavailable(TARGET, stage, "toolchain preflight command failed", {
        preflight = result.plan and result.plan.metadata and result.plan.metadata.preflight,
        exit_code = result.code,
      })
    end
    local kind = result.plan and result.plan.metadata and result.plan.metadata.preflight
    if kind == "iphoneos-sdk" and C.trim(result.stdout) == "" then
      return C.unavailable(TARGET, stage, "iPhoneOS SDK path was empty")
    end
    if kind == "codesign-identity" then
      local output = tostring(result.stdout or "") .. "\n" .. tostring(result.stderr or "")
      local parsed = M.parse(output)
      if not parsed.ok then
        return C.unavailable(TARGET, stage, parsed.reason)
      end
      local expected, identity_err = M.validate(context and context.signing_identity)
      if not expected then
        return C.unavailable(TARGET, stage, identity_err)
      end
      local resolved = M.resolve(parsed.identities, expected.fingerprint)
      if not resolved.ok or resolved.identity.name ~= expected.name then
        return C.unavailable(TARGET, stage, "selected code-sign identity is not currently valid")
      end
    end
  end
  return { ok = true, stage = stage }
end

return M
