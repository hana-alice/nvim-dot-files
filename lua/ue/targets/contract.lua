local M = {}

local REQUIRED_FUNCTIONS = {
  "capabilities",
  "build_plan",
  "classify_rsp",
}

local OPTIONAL_FUNCTIONS = {
  "package_plan",
  "symbols_plan",
  "device_list_plan",
  "install_plan",
  "launch_plan",
  "preflight_descriptors",
  "preflight_plans",
  "validate_preflight",
  "artifact_candidates",
  "bundle_id_plan",
  "before_build",
  "so_build_plan",
  "so_deploy_plan",
  "log_plan",
  "semantic_cdb_plan",
  "validate_semantic_cdb",
}

function M.required_functions()
  return vim.deepcopy(REQUIRED_FUNCTIONS)
end

function M.optional_functions()
  return vim.deepcopy(OPTIONAL_FUNCTIONS)
end

function M.validate(driver)
  assert(type(driver) == "table", "target driver must be a table")
  assert(type(driver.id) == "string" and driver.id ~= "", "target driver id must be a non-empty string")
  assert(type(driver.host_operations) == "table", "target driver host_operations must be a table")
  assert(type(driver.runtime) == "table", "target driver runtime policy must be a table")

  for _, key in ipairs({ "launch", "main_log", "debug_log" }) do
    local policy = driver.runtime[key]
    assert(type(policy) == "table", "target runtime policy missing: " .. key)
    assert(
      type(policy.strategy) == "string" and policy.strategy ~= "",
      "target runtime strategy must be a non-empty string: " .. key
    )
  end

  for host_id, operations in pairs(driver.host_operations) do
    assert(type(host_id) == "string" and host_id ~= "", "target driver host id must be a non-empty string")
    assert(type(operations) == "table", "target driver host operations must be a table")
    for operation, supported in pairs(operations) do
      assert(type(operation) == "string" and operation ~= "", "target operation id must be a non-empty string")
      assert(supported == true, "declared target host operation must be true")
    end
  end

  for _, key in ipairs(REQUIRED_FUNCTIONS) do
    assert(type(driver[key]) == "function", "target driver missing required function: " .. key)
  end

  for _, key in ipairs(OPTIONAL_FUNCTIONS) do
    if driver[key] ~= nil then
      assert(type(driver[key]) == "function", "target driver optional member must be a function: " .. key)
    end
  end

  return driver
end

return M
