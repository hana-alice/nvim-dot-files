local runtime = require("ue.workflows._runtime")
local targets = require("ue.targets")

local M = {}

local REGISTRY = {}
local DEFAULTS_REGISTERED = false

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function normalize(value)
  return trim(value):lower()
end

local function ensure_defaults_registered()
  if DEFAULTS_REGISTERED then
    return
  end
  require("ue.workflows.bootstrap").ensure_registered()
  DEFAULTS_REGISTERED = true
end

local function unavailable(target_id, operation, reason, extra)
  local payload = {
    ok = false,
    status = "unavailable",
    target_id = target_id,
    operation = operation,
    reason = reason,
  }
  if type(extra) == "table" then
    for key, value in pairs(extra) do
      payload[key] = vim.deepcopy(value)
    end
  end
  return payload
end

local function bucket(target_id)
  local key = normalize(target_id)
  if key == "" then
    return nil, "workflow target is required"
  end
  REGISTRY[key] = REGISTRY[key] or {}
  return REGISTRY[key]
end

function M.register(target_id, operation, workflow)
  assert(type(workflow) == "table", "workflow owner must be a table")
  assert(trim(workflow.owner) ~= "", "workflow owner id is required")
  assert(type(workflow.run) == "function", "workflow owner must expose run(request)")

  local per_target, target_err = bucket(target_id)
  assert(per_target, target_err)
  operation = normalize(operation)
  assert(operation ~= "", "workflow operation is required")
  per_target[operation] = workflow
  return workflow
end

function M.lookup(target_id, operation)
  ensure_defaults_registered()
  local per_target = REGISTRY[normalize(target_id)]
  if type(per_target) ~= "table" then
    return nil
  end
  return per_target[normalize(operation)]
end

function M.snapshot(spec)
  return runtime.snapshot(spec)
end

function M.resolve(target_id, operation, host_driver)
  ensure_defaults_registered()
  local driver, target_err = targets.resolve(target_id, operation, host_driver)
  if not driver then
    return nil, target_err
  end
  local workflow = M.lookup(driver.id, operation)
  if workflow then
    return workflow, driver
  end
  return nil,
    unavailable(driver.id, trim(operation), "workflow owner missing", {
      host_id = type(host_driver) == "table" and host_driver.id or nil,
    })
end

function M.dispatch(target_id, operation, opts)
  opts = opts or {}
  local workflow, second = M.resolve(target_id, operation, opts.host_driver)
  if not workflow then
    return nil, second
  end

  return workflow.run({
    runtime = opts.runtime or runtime,
    snapshot = opts.snapshot,
    driver = second,
    host_driver = opts.host_driver,
    context = opts.context,
    payload = opts.payload,
    deps = opts.deps,
    target_id = second.id,
    operation = trim(operation),
    owner = workflow.owner,
    workflow = workflow,
  })
end

---Invoke a target-owned compatibility seam through the same matrix-filtered
---registry used by normal dispatch. This keeps `ue.lua` thin without making it
---import a concrete workflow module just to preserve a public test/API seam.
function M.invoke(target_id, operation, method, args, host_driver)
  local workflow, second = M.resolve(target_id, operation, host_driver)
  if not workflow then
    return nil, second
  end
  local fn = type(workflow.api) == "table" and workflow.api[method] or nil
  if type(fn) ~= "function" then
    return nil,
      unavailable(second.id, trim(operation), "workflow API method missing", {
        method = tostring(method or ""),
        owner = workflow.owner,
      })
  end
  return fn(unpack(args or {}))
end

function M._reset_for_test()
  DEFAULTS_REGISTERED = false
  for key in pairs(REGISTRY) do
    REGISTRY[key] = nil
  end
end

function M._registry_for_test()
  return REGISTRY
end

return M
