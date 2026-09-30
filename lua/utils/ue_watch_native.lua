-- Optional host-owned transport for ue_watch.
--
-- The Windows driver supplies a parent-bound ReadDirectoryChangesW helper.
-- This module owns transport discovery and normalizes its lifecycle messages;
-- source ownership and generation guards remain in ue_watch.lua.

local M = {}
local override_set = false
local override = nil
local native_status = {
  watch_mode = nil,
  ready = false,
  error = nil,
  unknown_coverage = false,
  unknown_coverage_reason = nil,
  unknown_coverage_key = nil,
}

local function log_debug(msg)
  local ok, log = pcall(require, "utils.log")
  if ok and log.debug then log.debug("ue.watch", msg) end
end

local function log_warn(msg)
  local ok, log = pcall(require, "utils.log")
  if ok and log.notify_warn then
    log.notify_warn("ue.watch", msg)
  else
    vim.notify("[ue.watch] " .. msg, vim.log.levels.WARN)
  end
end

local function report_unknown(reason, key, callback)
  reason, key = tostring(reason), tostring(key or reason)
  native_status.unknown_coverage = true
  native_status.unknown_coverage_reason = reason
  if native_status.unknown_coverage_key == key then return end
  native_status.unknown_coverage_key = key
  log_warn(reason)
  if type(callback) == "function" then
    local ok, err = pcall(callback, reason)
    if not ok then log_debug("on_source_unknown failed: " .. tostring(err)) end
  end
end

local function resolve()
  if override_set then
    if override == false then return nil, nil, false end
    if type(override) == "function" then
      local ok, watcher, err = pcall(override)
      if not ok then return nil, tostring(watcher), true end
      return watcher, err, true
    end
    return override, nil, true
  end

  local ok, platform = pcall(require, "utils.platform")
  if not ok then return nil, "platform registry unavailable: " .. tostring(platform), false end
  local driver = platform.driver()
  local factory = driver and driver.content_event_watcher
  if type(factory) ~= "function" then return nil, nil, false end
  local called, watcher, err = pcall(factory)
  if not called then return nil, tostring(watcher), true end
  return watcher, err, true
end

-- Return the native handle on success. A nil handle with supported=true means
-- the host declared the capability but could not start it; this module reports
-- the gap and the caller chooses libuv as a fallback.
function M.start(root, opts, callback)
  opts = opts or {}
  local watcher, resolve_err, supported = resolve()
  if not watcher then
    if supported and resolve_err then
      native_status.error = tostring(resolve_err)
      report_unknown("native content watcher unavailable: " .. tostring(resolve_err),
        "native-unavailable", opts.on_source_unknown)
    end
    return nil, resolve_err, supported
  end
  native_status.ready, native_status.error = false, nil
  native_status.watch_mode = "native"

  local function forward(err, filename, events)
    if events and events.ready then
      native_status.ready = true
      native_status.unknown_coverage_key = nil
      return
    end
    if events and events.unknown then
      local reason = err
      if not reason and events.overflow then reason = "native watcher overflow" end
      reason = reason or "native watcher coverage lost"
      native_status.error = tostring(reason)
      local key = events.overflow and "overflow" or "native-gap"
      report_unknown(reason, key, opts.on_source_unknown)
      return
    end
    if err then
      native_status.ready = false
      native_status.error = tostring(err)
      report_unknown(err, "native-error", opts.on_source_unknown)
      return
    end
    native_status.unknown_coverage_key = nil
    if events and events.directory then return end
    if events then events.native = true end
    callback(nil, filename, events)
  end

  local ok, started, start_err = pcall(watcher.start, watcher, root, opts, forward)
  if ok and started ~= nil then return watcher, nil, true end
  local err = start_err or (ok and started) or "native watcher start failed"
  native_status.ready, native_status.error = false, tostring(err)
  report_unknown("native content watcher unavailable: " .. tostring(err),
    "native-unavailable", opts.on_source_unknown)
  pcall(watcher.stop, watcher)
  pcall(watcher.close, watcher)
  return nil, tostring(err), true
end

function M.reset()
  native_status.watch_mode = nil
  native_status.ready = false
  native_status.error = nil
  native_status.unknown_coverage = false
  native_status.unknown_coverage_reason = nil
  native_status.unknown_coverage_key = nil
end

function M.stop()
  native_status.watch_mode = nil
  native_status.ready = false
  native_status.unknown_coverage_key = nil
end

function M.status()
  return {
    watch_mode = native_status.watch_mode,
    native_ready = native_status.ready,
    native_error = native_status.error,
    unknown_coverage = native_status.unknown_coverage,
    unknown_coverage_reason = native_status.unknown_coverage_reason,
  }
end

function M.set_fallback()
  native_status.watch_mode = "libuv"
end

function M.set_for_test(value)
  if value == nil then
    override_set, override = false, nil
  else
    override_set, override = true, value
  end
end

return M
