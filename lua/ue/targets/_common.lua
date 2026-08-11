local shards = require("ue.cdb.shards")

local M = {}

local function deepcopy(value)
  if type(value) ~= "table" then
    return value
  end
  local out = {}
  for key, item in pairs(value) do
    out[key] = deepcopy(item)
  end
  return out
end

function M.trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

function M.normalize_path(path)
  path = M.trim(path)
  if path == "" then
    return ""
  end
  path = path:gsub("\\", "/")
  path = path:gsub("/+", "/")
  return path
end

function M.join_path(...)
  local parts = { ... }
  local out = ""
  for _, part in ipairs(parts) do
    part = M.normalize_path(part):gsub("^/+", ""):gsub("/+$", "")
    if part ~= "" then
      out = out == "" and part or (out .. "/" .. part)
    end
  end
  if M.normalize_path(parts[1]):sub(1, 1) == "/" then
    out = "/" .. out
  end
  return out
end

function M.host_path(host_driver, path)
  if type(host_driver) == "table" and type(host_driver.host_path) == "function" then
    local ok, value = pcall(host_driver.host_path, path)
    if ok and type(value) == "string" and value ~= "" then
      return value
    end
  end
  return tostring(path or "")
end

function M.normalize_id(id)
  return M.trim(id):lower()
end

function M.context_platform(context)
  local value = context and (context.platform or context.target_platform)
  return M.trim(value)
end

function M.context_target(context)
  return M.trim(context and context.target)
end

function M.context_configuration(context)
  return M.trim(context and context.configuration)
end

function M.copy_list(values)
  local out = {}
  for index, value in ipairs(values or {}) do
    out[index] = tostring(value)
  end
  return out
end

function M.deepcopy(value)
  return deepcopy(value)
end

function M.unavailable(driver_id, operation, reason, extra)
  local payload = {
    ok = false,
    status = "unavailable",
    driver_id = driver_id,
    operation = operation,
    reason = reason,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      payload[key] = deepcopy(value)
    end
  end
  return payload
end

function M.plan(executable, args, cwd, metadata)
  executable = M.trim(executable)
  assert(executable ~= "", "plan executable must be a non-empty string")

  local argv = {}
  for index, value in ipairs(args or {}) do
    local item = tostring(value)
    assert(item ~= "", "plan args[" .. index .. "] must be non-empty")
    argv[index] = item
  end

  return {
    executable = executable,
    args = argv,
    cwd = cwd and tostring(cwd) or nil,
    metadata = deepcopy(metadata or {}),
  }
end

function M.with_appended_args(base_plan, args, metadata)
  assert(type(base_plan) == "table", "base_plan must be a table")
  local merged =
    M.plan(base_plan.executable, M.copy_list(base_plan.args), base_plan.cwd, deepcopy(base_plan.metadata or {}))
  for _, value in ipairs(args or {}) do
    merged.args[#merged.args + 1] = tostring(value)
  end
  if type(metadata) == "table" then
    for key, value in pairs(metadata) do
      merged.metadata[key] = deepcopy(value)
    end
  end
  return merged
end

function M.resolve_host_entry(host_driver, method_name, context, driver_id, operation)
  if type(host_driver) ~= "table" then
    return nil,
      M.unavailable(driver_id, operation, "host driver missing", {
        missing_capability = method_name,
      })
  end

  local method = host_driver[method_name]
  if type(method) ~= "function" then
    return nil,
      M.unavailable(driver_id, operation, "host capability missing", {
        missing_capability = method_name,
        host_id = host_driver.id,
      })
  end

  local host_arg
  if method_name == "ue_build_entry" or method_name == "ue_uat_entry" then
    host_arg = context and context.engine_root or nil
  end
  local ok, result, alt = pcall(method, host_arg)
  if not ok then
    return nil,
      M.unavailable(driver_id, operation, "host capability errored", {
        missing_capability = method_name,
        host_id = host_driver.id,
        detail = result,
      })
  end

  if type(result) == "table" and result.status == "unavailable" then
    return nil, result
  end

  if result == nil or result == false then
    return nil,
      M.unavailable(driver_id, operation, "host capability returned no entry", {
        missing_capability = method_name,
        host_id = host_driver.id,
        detail = alt,
      })
  end

  if type(result) == "string" then
    return M.plan(result, {}, context and context.cwd or nil, {
      host_capability = method_name,
      host_id = host_driver.id,
    })
  end

  if type(result) ~= "table" then
    return nil,
      M.unavailable(driver_id, operation, "host capability returned invalid entry", {
        missing_capability = method_name,
        host_id = host_driver.id,
        detail = type(result),
      })
  end

  local metadata = deepcopy(result.metadata or {})
  metadata.host_capability = metadata.host_capability or method_name
  metadata.host_id = metadata.host_id or host_driver.id

  return M.plan(result.executable, result.args or {}, result.cwd or (context and context.cwd), metadata)
end

function M.classify_candidate(candidate)
  local path
  local explicit = {}

  if type(candidate) == "string" then
    path = candidate
  elseif type(candidate) == "table" then
    path = candidate.path or candidate.rsp_path or candidate.file
    explicit.platform = candidate.platform
    explicit.target = candidate.target
    explicit.configuration = candidate.configuration or candidate.config
  end

  path = M.normalize_path(path)
  local platform, target, configuration = shards.classify_rsp_path(path)

  if not platform or platform == "" then
    platform = M.trim(explicit.platform)
  end
  if not target or target == "" then
    target = M.trim(explicit.target)
  end
  if not configuration or configuration == "" then
    configuration = M.trim(explicit.configuration)
  end

  return {
    path = path,
    platform = platform,
    target = target,
    configuration = configuration,
  }
end

function M.classify_for_platform(driver_id, platform_id, candidate, context)
  local info = M.classify_candidate(candidate)
  local expected_target = M.context_target(context)
  local expected_configuration = M.context_configuration(context)

  local result = {
    driver_id = driver_id,
    candidate = info.path,
    platform = info.platform,
    target = info.target,
    configuration = info.configuration,
    expected = {
      platform = platform_id,
      target = expected_target,
      configuration = expected_configuration,
    },
    match = false,
  }

  if info.platform == "" then
    result.reason = "missing-platform"
    return result
  end
  if info.platform ~= platform_id then
    result.reason = "foreign-platform"
    return result
  end
  if expected_target ~= "" and info.target ~= "" and info.target ~= expected_target then
    result.reason = "foreign-target"
    return result
  end
  if expected_configuration ~= "" and info.configuration ~= "" and info.configuration ~= expected_configuration then
    result.reason = "foreign-configuration"
    return result
  end

  result.match = true
  result.reason = "matched"
  return result
end

function M.default_capabilities(id, supported)
  local support = {}
  for key, value in pairs(supported or {}) do
    support[key] = value == true
  end
  return {
    driver_id = id,
    build = support.build == true,
    package = support.package == true,
    device = support.device == true,
    install = support.install == true,
    launch = support.launch == true,
  }
end

function M.unsupported_operation(id, operation)
  return function()
    return M.unavailable(id, operation, operation .. " is not supported by this target")
  end
end

return M
