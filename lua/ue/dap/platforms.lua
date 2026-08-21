-- ue.dap.platforms — registry of per-platform DAP attach/launch handlers.
--
-- Phase F.2 lays down the dispatch shape WITHOUT moving the existing
-- Android implementation. ue.lua registers the android handler at
-- setup() time so this module imports cleanly with no `require("ue")`
-- back-reference.
--
-- Adding a new platform is "register a function under its key" — see
-- M.register / M.handler / M.handlers.

local M = {}

local _attach   = {}
local _launch   = {}

local function normalize(id)
  return tostring(id or ""):lower()
end

--- Register the attach handler for a platform.
function M.register_attach(id, fn)
  assert(type(fn) == "function", "attach handler must be a function")
  _attach[normalize(id)] = fn
end

--- Register the launch handler for a platform.
function M.register_launch(id, fn)
  assert(type(fn) == "function", "launch handler must be a function")
  _launch[normalize(id)] = fn
end

--- Look up the attach handler for `id`. Returns nil if none registered.
function M.attach_handler(id)
  return _attach[normalize(id)]
end

--- Look up the launch handler for `id`. Returns nil if none registered.
function M.launch_handler(id)
  return _launch[normalize(id)]
end

--- Sorted list of every platform that has at least one handler.
function M.known_platforms()
  local seen, out = {}, {}
  for k in pairs(_attach) do seen[k] = true end
  for k in pairs(_launch) do seen[k] = true end
  for k in pairs(seen) do table.insert(out, k) end
  table.sort(out)
  return out
end

--- Register only DAP handlers supported by the current host-target matrix.
--- Importability is not compatibility: the iOS device handler is available on
--- macOS only because the IOS target explicitly owns both DAP operations.
---@param host_driver table
---@param ue_api table
function M.register_supported(host_driver, ue_api)
  local targets = require("ue.targets")
  local specs = {
    { target = "Android", module = "android" },
    { target = "Win64", module = "win64" },
    { target = "Mac", module = "mac" },
    { target = "Linux", module = "linux" },
    { target = "IOS", module = "ios" },
  }

  -- Re-resolving must remove stale built-in handlers from a previous host
  -- fixture/setup pass while preserving unrelated user registrations.
  for _, spec in ipairs(specs) do
    _attach[spec.module] = nil
    _launch[spec.module] = nil
  end

  for _, spec in ipairs(specs) do
    local attach = targets.supports(spec.target, "dap_attach", host_driver)
    local launch = targets.supports(spec.target, "dap_launch", host_driver)
    if attach or launch then
      local handlers
      if spec.target == "Android" then
        handlers = {
          attach = function() ue_api.android_dap_attach() end,
          launch = function() ue_api.android_dap_launch() end,
        }
      else
        local ok, module = pcall(require, "ue.dap." .. spec.module)
        if ok and type(module) == "table" then handlers = module end
      end
      if handlers then
        if attach and type(handlers.attach) == "function" then
          M.register_attach(spec.module, handlers.attach)
        end
        if launch and type(handlers.launch) == "function" then
          M.register_launch(spec.module, handlers.launch)
        end
      end
    end
  end
end

--- Test seam.
function M._reset_for_test()
  _attach = {}
  _launch = {}
end

return M
