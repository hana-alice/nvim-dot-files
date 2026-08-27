local workflows = require("ue.workflows")

local semantic = require("ue.workflows.ios.semantic")
local signing = require("ue.workflows.ios.signing")
local device = require("ue.workflows.ios.device")
local setup = require("ue.workflows.ios.setup")
local install = require("ue.workflows.ios.install")
local launch = require("ue.workflows.ios.launch")
local common = require("ue.workflows.ios.common")

local modules = { semantic, signing, device, setup, install, launch }

local M = {}
local registered = false

local function api_with_common(mod)
  local api = {}
  for key, value in pairs(common) do
    api[key] = value
  end
  for key, value in pairs(mod) do
    api[key] = value
  end
  return api
end

function M.ensure_registered()
  if registered then
    return M
  end
  for _, mod in ipairs(modules) do
    workflows.register("IOS", mod.operation, {
      owner = mod.owner,
      run = mod.run,
      api = (mod == install or mod == launch) and api_with_common(mod) or mod,
    })
  end
  registered = true
  return M
end

function M.owner_for(operation)
  M.ensure_registered()
  local workflow = workflows.lookup("IOS", operation)
  return workflow and workflow.owner or nil
end

function M.ios_setup_is_ready(...)
  return semantic.ios_setup_is_ready(...)
end

function M.apple_build_evidence_matches(...)
  return semantic.apple_build_evidence_matches(...)
end

function M.prepare_semantic(...)
  return semantic.prepare(...)
end

function M.select_signing(...)
  return signing.select(...)
end

function M.select_device(...)
  return device.select(...)
end

function M.setup(...)
  return setup.setup(...)
end

function M.with_target_bundle_id(...)
  return common.with_target_bundle_id(...)
end

function M.resolve_legacy_install_script(...)
  return common.resolve_legacy_install_script(...)
end

function M.install(...)
  return install.install(...)
end

function M.launch(...)
  return launch.launch(...)
end

function M._reset_for_test()
  registered = false
end

return M
