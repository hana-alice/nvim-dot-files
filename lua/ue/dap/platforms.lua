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

--- Test seam.
function M._reset_for_test()
  _attach = {}
  _launch = {}
end

return M
