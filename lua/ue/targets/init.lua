local contract = require("ue.targets.contract")

local M = {}

local REGISTRY = {
  Android = require("ue.targets.android"),
  IOS = require("ue.targets.ios"),
  Mac = require("ue.targets.mac"),
  Win64 = require("ue.targets.win64"),
  Linux = require("ue.targets.linux"),
}

for key, driver in pairs(REGISTRY) do
  contract.validate(driver)
  assert(driver.id == key, "target driver id mismatch for registry key " .. key)
end

function M.driver(id)
  return REGISTRY[id]
end

function M.must_get(id)
  local driver = REGISTRY[id]
  assert(driver, "unknown target driver: " .. tostring(id))
  return driver
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
  return M.must_get(id).build_plan(context, host_driver)
end

function M.classify_rsp(id, candidate, context)
  return M.must_get(id).classify_rsp(candidate, context)
end

function M._registry_for_test()
  return REGISTRY
end

return M
