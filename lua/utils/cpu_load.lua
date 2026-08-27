-- utils/cpu_load.lua — continuous, lightweight CPU awareness.
--
-- This module is a SENSOR, not a controller. It reports cached host/editor
-- process signals; admission watermarks and process actions belong elsewhere.
-- It never spawns a process. uv.loadavg is deliberately unusable on Windows.
--
-- COST MODEL (measured on the affected 24-core host, 2026-08-26):
--   uv.cpu_info()   ~0.515ms and 24 core tables per call
--   uv.getrusage()  ~0.0019ms per call
-- One 250ms timer therefore reads rusage every tick and cpu_info every fourth
-- tick (1Hz): the expensive steady-state cost is about 0.515ms/second.

local uv = vim.uv or vim.loop

local M = {}

M.PROCESS_INTERVAL_MS = 250
M.HOST_INTERVAL_MS = 1000
-- Compatibility name retained for callers/tests of the former passive sampler.
M.MIN_SAMPLE_INTERVAL_MS = M.HOST_INTERVAL_MS
M.SMOOTHING = 0.25
M.TREND_EPSILON_PCT = 0.1

local function clamp(value, lo, hi)
  return math.max(lo, math.min(hi, value))
end

--- Snapshot cumulative host CPU counters, summed across all logical cores.
--- @return table|nil snapshot { idle = number, total = number, cpus = integer }
function M.snapshot()
  local ok, info = pcall(function()
    return uv.cpu_info and uv.cpu_info() or nil
  end)
  if not ok or type(info) ~= "table" or #info == 0 then
    return nil
  end

  local idle, total = 0, 0
  for _, core in ipairs(info) do
    local times = core.times or {}
    local core_idle = tonumber(times.idle) or 0
    idle = idle + core_idle
    total = total + core_idle
      + (tonumber(times.user) or 0)
      + (tonumber(times.nice) or 0)
      + (tonumber(times.sys) or 0)
      + (tonumber(times.irq) or 0)
  end
  if total <= 0 then
    return nil
  end
  return { idle = idle, total = total, cpus = #info }
end

--- Total CPU milliseconds consumed by the Neovim process.
--- uv.getrusage does NOT include live child processes such as clangd.
--- @return number|nil cpu_ms
function M.rusage_cpu_ms()
  local ok, usage = pcall(function()
    return uv.getrusage and uv.getrusage() or nil
  end)
  if not ok or type(usage) ~= "table" then
    return nil
  end

  local function time_ms(value)
    if type(value) ~= "table" then
      return nil
    end
    local sec, usec = tonumber(value.sec), tonumber(value.usec)
    if sec == nil or usec == nil then
      return nil
    end
    return sec * 1000 + usec / 1000
  end

  local user_ms, system_ms = time_ms(usage.utime), time_ms(usage.stime)
  if user_ms == nil or system_ms == nil then
    return nil
  end
  return user_ms + system_ms
end

--- Host busy percentage between two cumulative snapshots.
--- Pure; invalid, stationary, or regressed counters return nil.
--- @param prev table|nil
--- @param cur table|nil
--- @return number|nil busy_pct 0..100
function M.busy_from_samples(prev, cur)
  if type(prev) ~= "table" or type(cur) ~= "table" then
    return nil
  end
  local total_delta = (tonumber(cur.total) or 0) - (tonumber(prev.total) or 0)
  local idle_delta = (tonumber(cur.idle) or 0) - (tonumber(prev.idle) or 0)
  if total_delta <= 0 or idle_delta < 0 then
    return nil
  end
  return clamp((1 - idle_delta / total_delta) * 100, 0, 100)
end

--- Neovim process CPU between two samples.
--- `machine_pct` is comparable to host_pct; `core_pct` is relative to one core.
--- Pure; invalid, stationary, or regressed counters return nil.
--- @param prev table|nil { cpu_ms, at_ns, cpus }
--- @param cur table|nil { cpu_ms, at_ns, cpus }
--- @return table|nil { machine_pct, core_pct }
function M.process_busy_from_samples(prev, cur)
  if type(prev) ~= "table" or type(cur) ~= "table" then
    return nil
  end
  local elapsed_ms = ((tonumber(cur.at_ns) or 0) - (tonumber(prev.at_ns) or 0)) / 1e6
  local cpu_delta = (tonumber(cur.cpu_ms) or 0) - (tonumber(prev.cpu_ms) or 0)
  local cpus = tonumber(cur.cpus) or tonumber(prev.cpus) or 0
  if elapsed_ms <= 0 or cpu_delta < 0 or cpus <= 0 then
    return nil
  end
  local core_pct = clamp(cpu_delta / elapsed_ms * 100, 0, cpus * 100)
  return { core_pct = core_pct, machine_pct = core_pct / cpus }
end

--- Apply EMA and derive a direction from the previous smoothed value.
--- Signal processing only: no host-pressure policy lives here.
--- @param previous number|nil
--- @param raw number
--- @param alpha number|nil
--- @param epsilon number|nil
--- @return table { raw_pct, smoothed_pct, delta_pct, trend }
function M.update_signal(previous, raw, alpha, epsilon)
  raw = tonumber(raw)
  if raw == nil then
    return { raw_pct = nil, smoothed_pct = nil, delta_pct = nil, trend = "unknown" }
  end
  alpha = clamp(tonumber(alpha) or M.SMOOTHING, 0, 1)
  epsilon = math.max(tonumber(epsilon) or M.TREND_EPSILON_PCT, 0)
  local smoothed
  if previous == nil then
    smoothed = raw
  else
    smoothed = previous + alpha * (raw - previous)
  end
  local delta = previous ~= nil and (smoothed - previous) or nil
  local trend = "unknown"
  if delta ~= nil then
    if delta > epsilon then
      trend = "rising"
    elseif delta < -epsilon then
      trend = "falling"
    else
      trend = "steady"
    end
  end
  return { raw_pct = raw, smoothed_pct = smoothed, delta_pct = delta, trend = trend }
end

local function empty_channel()
  return {
    raw_pct = nil,
    smoothed_pct = nil,
    delta_pct = nil,
    trend = "unknown",
    sampled_at_ns = nil,
  }
end

local function initial_state()
  return {
    started = false,
    phase = "stopped",
    timer = nil,
    opts = nil,
    cpus = nil,
    host_previous = nil,
    editor_previous = nil,
    host = empty_channel(),
    editor = empty_channel(),
    editor_core = empty_channel(),
    last_host_at_ns = nil,
    last_error = nil,
    stats = { ticks = 0, host_samples = 0, editor_samples = 0, work_ns = 0 },
  }
end

local state = initial_state()
local listeners = {}
local listener_sequence = 0
local publish_pending = false

local function publish_reading()
  if publish_pending or next(listeners) == nil then return end
  publish_pending = true
  vim.schedule(function()
    publish_pending = false
    local reading = M.reading()
    for _, listener in pairs(listeners) do pcall(listener, reading) end
  end)
end

local function call_reader(reader)
  local ok, value = pcall(reader)
  if ok then
    return value
  end
  state.last_error = tostring(value)
  return nil
end

local function apply_signal(channel, raw, now_ns)
  local next_signal = M.update_signal(channel.smoothed_pct, raw)
  next_signal.sampled_at_ns = now_ns
  return next_signal
end

local function sample_host(now_ns)
  local current = call_reader(state.opts.host_reader)
  state.stats.host_samples = state.stats.host_samples + 1
  state.last_host_at_ns = now_ns
  if type(current) ~= "table" then
    state.host = empty_channel()
    state.phase = "unknown"
    publish_reading()
    return
  end

  state.cpus = tonumber(current.cpus) or state.cpus
  local previous = state.host_previous
  local raw = M.busy_from_samples(previous, current)
  state.host_previous = current
  if raw == nil then
    state.host = empty_channel()
    state.phase = previous == nil and "warming" or "unknown"
    publish_reading()
    return
  end

  state.host = apply_signal(state.host, raw, now_ns)
  state.phase = "ready"
  publish_reading()
end

local function sample_editor(now_ns)
  local cpu_ms = call_reader(state.opts.editor_reader)
  state.stats.editor_samples = state.stats.editor_samples + 1
  if type(cpu_ms) ~= "number" or type(state.cpus) ~= "number" then
    state.editor = empty_channel()
    state.editor_core = empty_channel()
    state.editor_previous = type(cpu_ms) == "number" and {
      cpu_ms = cpu_ms,
      at_ns = now_ns,
      cpus = state.cpus,
    } or nil
    return
  end

  local current = { cpu_ms = cpu_ms, at_ns = now_ns, cpus = state.cpus }
  local raw = M.process_busy_from_samples(state.editor_previous, current)
  state.editor_previous = current
  if raw == nil then
    state.editor = empty_channel()
    state.editor_core = empty_channel()
    return
  end
  state.editor = apply_signal(state.editor, raw.machine_pct, now_ns)
  state.editor_core = apply_signal(state.editor_core, raw.core_pct, now_ns)
end

--- Advance one sampler tick. Exposed for deterministic injected tests.
--- @param force_host boolean|nil
function M._tick(force_host)
  if not state.started or type(state.opts) ~= "table" then
    return false
  end
  local work_started = uv.hrtime()
  local now_ns = call_reader(state.opts.now)
  if type(now_ns) ~= "number" then
    state.phase = "unknown"
    return false
  end

  local host_due = force_host == true
    or state.last_host_at_ns == nil
    or (now_ns - state.last_host_at_ns) / 1e6 >= state.opts.host_interval_ms
  if host_due then
    sample_host(now_ns)
  end
  sample_editor(now_ns)

  state.stats.ticks = state.stats.ticks + 1
  state.stats.work_ns = state.stats.work_ns + math.max(uv.hrtime() - work_started, 0)
  return true
end

--- Start continuous awareness. Production callers invoke this from UIEnter.
--- Tests may pass force/manual plus injected readers and clock.
--- @param opts table|nil
--- @return boolean started
--- @return string|nil reason
function M.setup(opts)
  opts = opts or {}
  if state.started then
    return true, "already-started"
  end
  if opts.force ~= true and #vim.api.nvim_list_uis() == 0 then
    return false, "no-ui"
  end

  state = initial_state()
  state.started = true
  state.phase = "warming"
  state.opts = {
    process_interval_ms = tonumber(opts.process_interval_ms) or M.PROCESS_INTERVAL_MS,
    host_interval_ms = tonumber(opts.host_interval_ms) or M.HOST_INTERVAL_MS,
    host_reader = opts.host_reader or M.snapshot,
    editor_reader = opts.editor_reader or M.rusage_cpu_ms,
    now = opts.now or uv.hrtime,
    timer_factory = opts.timer_factory or uv.new_timer,
  }

  -- Establish cumulative-counter baselines immediately, but never wait for a
  -- second sample. Until the first interval completes, reading() says warming.
  M._tick(true)
  if opts.manual == true then
    return true
  end

  local ok, timer = pcall(state.opts.timer_factory)
  if not ok or not timer then
    state.started = false
    state.phase = "unknown"
    state.last_error = ok and "timer-unavailable" or tostring(timer)
    return false, "timer-unavailable"
  end
  state.timer = timer
  local interval = math.max(math.floor(state.opts.process_interval_ms), 50)
  local started, err = pcall(function()
    timer:start(interval, interval, function()
      local tick_ok, tick_err = pcall(M._tick, false)
      if not tick_ok then
        state.phase = "unknown"
        state.last_error = tostring(tick_err)
      end
    end)
  end)
  if not started then
    pcall(timer.close, timer)
    state.timer = nil
    state.started = false
    state.phase = "unknown"
    state.last_error = tostring(err)
    return false, "timer-start-failed"
  end
  return true
end

--- Return an O(1) copy of the cached reading; this never samples the host.
--- @return table
function M.reading()
  local now_ns = uv.hrtime()
  local host_pct = state.phase == "ready" and state.host.smoothed_pct or nil
  local editor_pct = state.editor.smoothed_pct
  return {
    status = state.phase,
    host_pct = host_pct,
    host_raw_pct = state.host.raw_pct,
    host_delta_pct = state.host.delta_pct,
    host_trend = state.host.trend,
    editor_pct = editor_pct,
    editor_raw_pct = state.editor.raw_pct,
    editor_core_pct = state.editor_core.smoothed_pct,
    editor_trend = state.editor.trend,
    unattributed_pct = host_pct and editor_pct and math.max(host_pct - editor_pct, 0) or nil,
    cpus = state.cpus,
    sampled_at_ns = state.host.sampled_at_ns,
    age_ms = state.host.sampled_at_ns and math.max((now_ns - state.host.sampled_at_ns) / 1e6, 0) or nil,
  }
end

--- Compatibility API: current smoothed host percentage, or nil unless ready.
function M.busy()
  return M.reading().host_pct
end

--- Subscribe to the existing 1Hz host-sample stream; no new timer is created.
function M.subscribe(listener)
  assert(type(listener) == "function", "cpu_load subscriber must be a function")
  listener_sequence = listener_sequence + 1
  local token = ("cpu-listener-%d"):format(listener_sequence)
  listeners[token] = listener
  return token
end

function M.unsubscribe(token)
  if type(token) ~= "string" or listeners[token] == nil then return false end
  listeners[token] = nil
  return true
end

function M._clear_subscribers_for_test()
  listeners = {}
  listener_sequence = 0
  publish_pending = false
end

function M.stop()
  if state.timer then
    pcall(state.timer.stop, state.timer)
    pcall(state.timer.close, state.timer)
    state.timer = nil
  end
  state.started = false
  state.phase = "stopped"
end

--- Drop all sampling history (primarily tests and suspend/resume recovery).
function M.reset()
  M.stop()
  state = initial_state()
end

--- Diagnostics without forcing a sample.
function M.status()
  local result = M.reading()
  result.started = state.started
  result.process_interval_ms = state.opts and state.opts.process_interval_ms or M.PROCESS_INTERVAL_MS
  result.host_interval_ms = state.opts and state.opts.host_interval_ms or M.HOST_INTERVAL_MS
  result.smoothing = M.SMOOTHING
  result.last_error = state.last_error
  result.stats = {
    ticks = state.stats.ticks,
    host_samples = state.stats.host_samples,
    editor_samples = state.stats.editor_samples,
    work_ms = state.stats.work_ns / 1e6,
    average_tick_ms = state.stats.ticks > 0 and state.stats.work_ns / 1e6 / state.stats.ticks or 0,
  }
  return result
end

return M
