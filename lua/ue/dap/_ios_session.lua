-- ue.dap._ios_session — nvim-dap event proof for physical-device iOS sessions.
local C = require("ue.dap._common")

local M = {}
local installed = false
local LOADED_UUID_OK = "__UE_IOS_LOADED_UUID_OK__"
local LOADED_UUID_MISMATCH = "__UE_IOS_LOADED_UUID_MISMATCH__"

local function trim(value)
  return vim.trim(tostring(value or ""))
end

function M.is_owned(session)
  local config = session and session.config or nil
  return config
    and config._ue_session_owner == "ios"
    and (config._ue_ios_session_owner == "legacy-mobiledevice" or config._ue_ios_session_owner == "coredevice")
end

local function reject_loaded_uuid(session, message, deps)
  if session._ue_ios_loaded_uuid_failed then
    return
  end
  session._ue_ios_loaded_uuid_failed = true
  deps.progress("error", message)
  deps.notify(message, vim.log.levels.ERROR)
  vim.schedule(function()
    local dap = C.require_dap()
    local active = dap and dap.session and dap.session() or nil
    if active == session and pcall(dap.disconnect, { terminateDebuggee = false }) then
      vim.defer_fn(function()
        deps.on_unexpected_end(session)
      end, deps.cleanup_fallback_ms or 2000)
      return
    end
    deps.on_unexpected_end(session)
  end)
end

local function uuid_verified(session)
  return session.config._ue_ios_backend ~= "coredevice" or session._ue_ios_loaded_uuid_verified == true
end

local function announce_initialized(session, deps)
  if session._ue_ios_initialized_announced or not uuid_verified(session) then
    return
  end
  session._ue_ios_initialized_announced = true
  deps.progress("step", "iOS transport attached; arming source breakpoints …")
  deps.notify("iOS transport attached; waiting for resolved source-breakpoint proof")
end

local function announce_breakpoint(session, deps)
  if session._ue_ios_breakpoint_announced or not uuid_verified(session) then
    return
  end
  session._ue_ios_breakpoint_announced = true
  deps.progress("step", "iOS source breakpoint resolved; waiting for the stop …")
end

function M.install(deps)
  if installed then
    return
  end
  local dap = C.require_dap()
  if not dap then
    return
  end
  local key = "ue_ios_lifecycle"
  dap.listeners.after.event_output[key] = function(session, body)
    if not M.is_owned(session) or session.config._ue_ios_backend ~= "coredevice" then
      return
    end
    local output = trim(body and body.output)
    if output == LOADED_UUID_OK then
      session._ue_ios_loaded_uuid_verified = true
      session._ue_ios_uuid_grace = nil
      deps.progress("step", "loaded iOS executable UUID verified; arming source breakpoints …")
      announce_initialized(session, deps)
      if session._ue_ios_has_verified_breakpoint then
        announce_breakpoint(session, deps)
      end
    elseif output == LOADED_UUID_MISMATCH then
      reject_loaded_uuid(session, "loaded iOS executable UUID does not match the local debug artifact", deps)
    end
  end
  dap.listeners.after.event_initialized[key] = function(session)
    if not M.is_owned(session) then
      return
    end
    session._ue_ios_initialized = true
    if not uuid_verified(session) then
      local grace = {}
      session._ue_ios_uuid_grace = grace
      vim.defer_fn(function()
        if session._ue_ios_uuid_grace == grace and not uuid_verified(session) then
          reject_loaded_uuid(session, "lldb-dap did not verify the loaded iOS executable UUID", deps)
        end
      end, deps.uuid_marker_grace_ms or 5000)
      return
    end
    announce_initialized(session, deps)
  end
  dap.listeners.after.setBreakpoints[key] = function(session, err, response, request)
    if not M.is_owned(session) or err or type(response) ~= "table" then
      return
    end
    for _, breakpoint in ipairs(response.breakpoints or {}) do
      if breakpoint.verified == true then
        session._ue_ios_has_verified_breakpoint = true
        local arguments = request and (request.arguments or request) or nil
        local source = arguments and arguments.source or nil
        local path = source and trim(source.path) or ""
        if path ~= "" then
          session._ue_ios_verified_sources = session._ue_ios_verified_sources or {}
          session._ue_ios_verified_sources[path] = true
        end
        announce_breakpoint(session, deps)
        break
      end
    end
  end
  dap.listeners.after.event_stopped[key] = function(session, body)
    if not M.is_owned(session) or type(body) ~= "table" then
      return
    end
    if body.reason ~= "breakpoint" or session._ue_ios_has_verified_breakpoint ~= true or not uuid_verified(session) then
      return
    end
    local thread_id = tonumber(body.threadId)
    if not thread_id or type(session.request) ~= "function" then
      return
    end
    session:request("stackTrace", { threadId = thread_id, startFrame = 0, levels = 12 }, function(err, response)
      if err or type(response) ~= "table" then
        return
      end
      local frames = response.stackFrames or {}
      local frame = frames[1]
      for _, candidate in ipairs(frames) do
        local candidate_path = candidate.source and trim(candidate.source.path) or ""
        if session._ue_ios_verified_sources and session._ue_ios_verified_sources[candidate_path] then
          frame = candidate
          break
        end
      end
      local source = frame and frame.source or nil
      local path = source and trim(source.path) or ""
      local line = frame and tonumber(frame.line) or nil
      if path == "" or not line or line < 1 then
        return
      end
      vim.schedule(function()
        deps.progress("done", ("iOS breakpoint proven at %s:%d"):format(vim.fs.basename(path), line))
        deps.notify(("iOS source breakpoint proven: %s:%d; :UEDAPEval is ready"):format(path, line))
      end)
    end)
  end
  dap.listeners.before.event_terminated[key] = deps.on_unexpected_end
  dap.listeners.before.event_exited[key] = deps.on_unexpected_end
  dap.listeners.after.disconnect[key] = deps.on_unexpected_end
  installed = true
end

return M
