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
local _lifecycle = {}
local _pending_owner = nil
local _active_owner = nil
local _last_owner = nil

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

--- Register lifecycle handlers owned by one target DAP implementation.
--- Supported keys: stop/status/reattach/cleanup. Missing keys remain
--- unavailable; callers must not guess another target implementation.
function M.register_lifecycle(id, handlers)
  assert(type(handlers) == "table", "lifecycle handlers must be a table")
  local normalized = normalize(id)
  local registered = {}
  for _, kind in ipairs({ "stop", "status", "reattach", "cleanup" }) do
    local fn = handlers[kind]
    if fn ~= nil then
      assert(type(fn) == "function", kind .. " handler must be a function")
      registered[kind] = fn
    end
  end
  _lifecycle[normalized] = registered
end

--- Look up the attach handler for `id`. Returns nil if none registered.
function M.attach_handler(id)
  return _attach[normalize(id)]
end

--- Look up the launch handler for `id`. Returns nil if none registered.
function M.launch_handler(id)
  return _launch[normalize(id)]
end

local function unavailable(kind, reason, owner)
  return {
    ok = false,
    kind = kind,
    owner = owner,
    reason = reason,
  }
end

local function completed_owner(record)
  if type(record) ~= "table" then return nil end
  return {
    owner = record.owner,
    operation = record.operation,
    adapter = record.adapter,
    device_id = record.device_id,
    process_id = record.process_id,
    context = type(record.context) == "table" and vim.deepcopy(record.context) or record.context,
  }
end

--- Start attach/launch dispatch and freeze the requested owner until the DAP
--- session object exists. event_initialized later binds this pending record to
--- the concrete session; live UI target changes never rewrite it.
function M.begin(kind, id, context)
  local owner = normalize(id)
  local handler = kind == "attach" and _attach[owner]
    or kind == "launch" and _launch[owner]
    or nil
  if not handler then
    return nil, unavailable(kind, "registered handler is unavailable", owner)
  end
  _pending_owner = {
    owner = owner,
    operation = kind,
    context = type(context) == "table" and vim.deepcopy(context) or context,
  }
  local ok, result = pcall(handler, context)
  if not ok then
    _pending_owner = nil
    return nil, unavailable(kind, tostring(result), owner)
  end
  return true, result
end

--- Bind a real nvim-dap session to the owner captured by begin(). Per-target
--- configs may also provide `_ue_session_owner` for programmatic starts that
--- bypass the public dispatch entry.
function M.bind_session(session, metadata)
  metadata = type(metadata) == "table" and metadata or {}
  local config = session and session.config or {}
  local owner = normalize(
    metadata.owner
      or config._ue_session_owner
  )
  if owner == "" then
    return nil, unavailable("bind", "session owner metadata is missing")
  end
  if not (_attach[owner] or _launch[owner] or _lifecycle[owner]) then
    return nil, unavailable("bind", "session owner is not registered", owner)
  end
  local record = {
    owner = owner,
    operation = metadata.operation
      or config._ue_session_operation
      or (_pending_owner and _pending_owner.owner == owner and _pending_owner.operation),
    adapter = metadata.adapter or config.type,
    device_id = metadata.device_id
      or config._ue_device_id
      or config._ue_android_serial,
    process_id = metadata.process_id or config._ue_process_id or config.pid,
    context = metadata.context
      or (_pending_owner and _pending_owner.owner == owner and _pending_owner.context),
    session = session,
  }
  if session then session._ue_session_owner_record = record end
  _active_owner = record
  _last_owner = completed_owner(record)
  _pending_owner = nil
  return record
end

function M.session_owner(session)
  if session and type(session._ue_session_owner_record) == "table" then
    return session._ue_session_owner_record
  end
  if _active_owner and (session == nil or _active_owner.session == session) then
    return _active_owner
  end
  return nil
end

function M.end_session(session)
  local record = M.session_owner(session)
  if record then _last_owner = completed_owner(record) end
  if session then session._ue_session_owner_record = nil end
  if _active_owner and (session == nil or _active_owner.session == session) then
    _active_owner = nil
  end
  return record
end

local function lifecycle_record(kind, session)
  local record = M.session_owner(session)
  if record then return record end
  if kind == "reattach" or kind == "status" then return _last_owner end
  if _pending_owner then return _pending_owner end
  return nil
end

--- Dispatch a lifecycle operation only through frozen owner metadata.
function M.dispatch_lifecycle(kind, opts)
  opts = type(opts) == "table" and opts or {}
  local record = lifecycle_record(kind, opts.session)
  if not record or normalize(record.owner) == "" then
    return nil, unavailable(kind, "session owner metadata is missing")
  end
  local owner = normalize(record.owner)
  local handler = _lifecycle[owner] and _lifecycle[owner][kind] or nil
  if not handler then
    return nil, unavailable(kind, "owner does not provide this lifecycle operation", owner)
  end
  local call_opts = vim.tbl_extend("force", opts, { owner = record })
  local ok, result = pcall(handler, call_opts)
  if not ok then
    return nil, unavailable(kind, tostring(result), owner)
  end
  return true, result
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
    {
      target = "Android",
      module = "android",
      facade = {
        attach = "android_dap_attach",
        launch = "android_dap_launch",
        stop = "stop_android_debugger",
        status = "android_dap_status",
        reattach = "android_dap_reattach",
      },
      cleanup_arg = "session_state",
    },
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
    _lifecycle[spec.module] = nil
  end

  for _, spec in ipairs(specs) do
    local attach = targets.supports(spec.target, "dap_attach", host_driver)
    local launch = targets.supports(spec.target, "dap_launch", host_driver)
    if attach or launch then
      local ok, handlers = pcall(require, "ue.dap." .. spec.module)
      if not ok or type(handlers) ~= "table" then handlers = nil end
      if handlers then
        local function facade_handler(operation, fallback)
          local name = spec.facade and spec.facade[operation]
          if name and type(ue_api[name]) == "function" then
            return function(opts) return ue_api[name](opts) end
          end
          return fallback
        end
        local attach_handler = facade_handler("attach", handlers.attach)
        local launch_handler = facade_handler("launch", handlers.launch)
        local cleanup_handler = handlers.cleanup
        if type(cleanup_handler) == "function" and spec.cleanup_arg then
          local owned_cleanup = cleanup_handler
          cleanup_handler = function(opts)
            return owned_cleanup(type(opts) == "table" and opts[spec.cleanup_arg] or nil)
          end
        end
        if attach and type(attach_handler) == "function" then
          M.register_attach(spec.module, attach_handler)
        end
        if launch and type(launch_handler) == "function" then
          M.register_launch(spec.module, launch_handler)
        end
        M.register_lifecycle(spec.module, {
          stop = facade_handler("stop", handlers.stop) or ue_api.dap_stop_session,
          status = facade_handler("status", handlers.status) or ue_api.dap_status_session,
          reattach = facade_handler("reattach", handlers.reattach),
          cleanup = cleanup_handler,
        })
      end
    end
  end
end

--- Test seam.
function M._reset_for_test()
  _attach = {}
  _launch = {}
  _lifecycle = {}
  _pending_owner = nil
  _active_owner = nil
  _last_owner = nil
end

return M
