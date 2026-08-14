local contract = require("ue.targets.contract")
local C = require("ue.targets._common")

local M = {}

local REGISTRY = {
  Android = require("ue.targets.android"),
  IOS = require("ue.targets.ios"),
  Mac = require("ue.targets.mac"),
  Win64 = require("ue.targets.win64"),
  Linux = require("ue.targets.linux"),
}

local NORMALIZED_IDS = {}

for key, driver in pairs(REGISTRY) do
  contract.validate(driver)
  assert(driver.id == key, "target driver id mismatch for registry key " .. key)
  NORMALIZED_IDS[key:lower()] = key
end

local function target_id(id)
  return NORMALIZED_IDS[tostring(id or ""):lower()]
end

function M.driver(id)
  return REGISTRY[target_id(id)]
end

function M.must_get(id)
  local driver = M.driver(id)
  assert(driver, "unknown target driver: " .. tostring(id))
  return driver
end


function M.resolve(id, operation, host_driver)
  local driver = M.driver(id)
  operation = C.trim(operation)
  local host_id = type(host_driver) == "table" and C.normalize_id(host_driver.id) or ""
  if not driver then
    return nil, C.unavailable(tostring(id), operation, "unknown target driver", {
      host_id = host_id,
    })
  end
  if operation == "" then
    return nil, C.unavailable(driver.id, operation, "target operation is required", {
      host_id = host_id,
    })
  end

  local operations = driver.host_operations[host_id]
  if type(operations) == "table" and operations[operation] == true then
    return driver
  end

  local supported_hosts = {}
  for candidate, declared in pairs(driver.host_operations) do
    if declared[operation] == true then
      supported_hosts[#supported_hosts + 1] = candidate
    end
  end
  table.sort(supported_hosts)
  return nil, C.unavailable(driver.id, operation, "unsupported host-target operation", {
    host_id = host_id,
    supported_hosts = supported_hosts,
  })
end

function M.supports(id, operation, host_driver)
  return M.resolve(id, operation, host_driver) ~= nil
end

function M.plan(id, operation, context, host_driver)
  local driver, unavailable = M.resolve(id, operation, host_driver)
  if not driver then
    return unavailable
  end
  local planner = driver[operation .. "_plan"]
  if type(planner) ~= "function" then
    return C.unavailable(driver.id, operation, "target operation has no planner", {
      host_id = host_driver and host_driver.id,
    })
  end
  return planner(context, host_driver)
end

function M.known_ids()
  local out = {}
  for id in pairs(REGISTRY) do
    out[#out + 1] = id
  end
  table.sort(out)
  return out
end

function M.build_plan(id, context, host_driver)
  return M.plan(id, "build", context, host_driver)
end

function M.classify_rsp(id, candidate, context)
  return M.must_get(id).classify_rsp(candidate, context)
end

function M._registry_for_test()
  return REGISTRY
end

return M
