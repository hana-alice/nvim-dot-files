-- utils/host_admission.lua — one host-resource policy shared by every workload.
--
-- cpu_load is the sensor; this module is the decision/controller boundary.
-- It owns pressure watermarks, foreground activity, bounded CPU deferral, and a
-- reusable one-shot retry queue. It never starts or stops external processes by
-- itself: callers retain workload ownership and completion semantics.

local uv = vim.uv or vim.loop

local M = {}

M.DEFAULTS = {
  enabled = true,
  high_pct = 85,
  low_pct = 70,
  max_deferrals = 20,
  retry_ms = 5000,
}

local foreground = {}
local foreground_sequence = 0
local pending_controls = setmetatable({}, { __mode = "k" })

local function env_number(primary, legacy, fallback)
  local value = tonumber(vim.env[primary] or "")
  if value == nil and legacy then
    value = tonumber(vim.env[legacy] or "")
  end
  return value or fallback
end

local function env_flag(primary, legacy, fallback)
  local value = vim.env[primary]
  if value == nil and legacy then value = vim.env[legacy] end
  if value == nil or value == "" then return fallback end
  return value ~= "0" and value:lower() ~= "false"
end

--- Resolve the single effective policy from general config plus legacy aliases.
--- @return table opts
function M.options()
  local resources, legacy = {}, {}
  local ok, config = pcall(require, "ue.config")
  if ok and config and config.get then
    resources = config.get("resources") or {}
    legacy = config.get("index") or {}
  end

  local function configured(key, legacy_key, fallback)
    local value = resources[key]
    if value == nil then value = legacy[legacy_key] end
    return tonumber(value) or fallback
  end

  local enabled = resources.cpu_admission
  if enabled == nil then enabled = legacy.cpu_admission end
  if enabled == nil then enabled = M.DEFAULTS.enabled end
  enabled = env_flag("NVIM_HOST_CPU_ADMISSION", "UE_INDEX_CPU_ADMISSION", enabled)

  return {
    enabled = enabled,
    high_pct = env_number(
      "NVIM_HOST_CPU_HIGH_PCT", "UE_INDEX_CPU_HIGH_PCT",
      configured("cpu_high_pct", "cpu_high_pct", M.DEFAULTS.high_pct)),
    low_pct = env_number(
      "NVIM_HOST_CPU_LOW_PCT", "UE_INDEX_CPU_LOW_PCT",
      configured("cpu_low_pct", "cpu_low_pct", M.DEFAULTS.low_pct)),
    max_deferrals = env_number(
      "NVIM_HOST_CPU_DEFER_MAX", "UE_INDEX_CPU_DEFER_MAX",
      configured("cpu_defer_max", "cpu_defer_max", M.DEFAULTS.max_deferrals)),
    retry_ms = env_number(
      "NVIM_HOST_CPU_RETRY_MS", nil,
      configured("cpu_retry_ms", "cpu_retry_ms", M.DEFAULTS.retry_ms)),
    foreground_active = M.foreground_active(),
  }
end

--- Pure admission decision.
--- @param load number|table|nil cached cpu_load reading (or legacy busy%)
--- @param deferrals integer prior CPU-pressure deferrals
--- @param opts table explicit policy input
--- @return boolean allow
--- @return string reason stable machine-readable reason
function M.admit(load, deferrals, opts)
  opts = opts or {}

  -- User-foreground ownership is independent of the CPU sensor toggle. Turning
  -- off pressure admission must not make background work race an active build.
  if opts.foreground_active == true then
    return false, "foreground-work-active"
  end
  if opts.enabled == false then
    return true, "admission-disabled"
  end

  local max_deferrals = tonumber(opts.max_deferrals) or M.DEFAULTS.max_deferrals
  if (tonumber(deferrals) or 0) >= max_deferrals then
    return true, "defer-cap-reached"
  end

  local reading = type(load) == "table" and load or nil
  local busy = reading and reading.host_pct or load
  if reading and reading.status == "warming" then
    return false, "load-awareness-warming"
  end
  if type(busy) ~= "number" then
    return true, "load-unknown"
  end

  local high = tonumber(opts.high_pct) or M.DEFAULTS.high_pct
  local low = tonumber(opts.low_pct) or M.DEFAULTS.low_pct
  if low > high then low = high end

  if busy >= high then
    return false, "host-cpu-above-high-watermark"
  end
  if busy <= low then
    return true, "host-cpu-below-low-watermark"
  end
  if opts.was_deferring then
    return false, "host-cpu-in-hysteresis-band"
  end
  return true, "host-cpu-in-hysteresis-band"
end

function M.current_reading()
  local ok, cpu_load = pcall(require, "utils.cpu_load")
  if not ok or type(cpu_load.reading) ~= "function" then return nil end
  return cpu_load.reading()
end

--- Register user-foreground work. The opaque token must be released exactly once.
--- @param label string|nil
--- @return string token
function M.foreground_begin(label)
  foreground_sequence = foreground_sequence + 1
  local token = ("foreground-%d"):format(foreground_sequence)
  foreground[token] = { label = tostring(label or "foreground work"), started_at = os.time() }
  return token
end

local function wake_pending()
  for control in pairs(pending_controls) do
    if control.pending and not control.cancelled and type(control.wake) == "function" then
      control:wake()
    end
  end
end

--- Release a foreground token; queued batches re-check immediately after the last.
--- @param token string|nil
--- @return boolean released
function M.foreground_done(token)
  if type(token) ~= "string" or foreground[token] == nil then return false end
  foreground[token] = nil
  if not M.foreground_active() then wake_pending() end
  return true
end

function M.foreground_active()
  return next(foreground) ~= nil
end

local FOREGROUND_OPERATIONS = {
  build = true,
  so_build = true,
  install = true,
  deploy = true,
  so_deploy = true,
  package = true,
}

--- Pure operation classification for generic target-task runners.
function M.is_foreground_operation(operation)
  return FOREGROUND_OPERATIONS[tostring(operation or ""):lower()] == true
end

function M.foreground_status()
  local items = {}
  for token, item in pairs(foreground) do
    items[#items + 1] = { token = token, label = item.label, started_at = item.started_at }
  end
  table.sort(items, function(a, b) return a.token < b.token end)
  return { active = #items > 0, count = #items, items = items }
end

local function close_timer(control)
  local timer = control.timer
  control.timer = nil
  if not timer then return end
  pcall(timer.stop, timer)
  pcall(timer.close, timer)
end

--- Run `spec.start` once admission allows it; otherwise retry via one-shot timer.
---
--- The returned control owns only the pending timer. If start returns a cancel
--- function, an explicit caller control:cancel() after start is forwarded to it;
--- admission itself never cancels running work.
---
--- Tests may inject reading/options/timer_factory/schedule.
--- @param spec table { name, start, on_defer?, on_error?, reading?, options?,
---   timer_factory?, schedule?, retry_ms? }
--- @return boolean started_immediately
--- @return any first_result
--- @return any second_result
--- @return table control
function M.run_when_allowed(spec)
  assert(type(spec) == "table" and type(spec.start) == "function",
    "host admission requires spec.start")

  local control = {
    name = tostring(spec.name or "background work"),
    pending = false,
    started = false,
    finished = false,
    cancelled = false,
    deferrals = tonumber(spec.deferrals) or 0,
    attempts = 0,
    reason = nil,
    timer = nil,
    generation = 0,
    child_cancel = nil,
    result = nil,
    error = nil,
  }

  local attempt

  function control:cancel()
    if self.cancelled or self.finished then return false end
    local was_started = self.started
    self.cancelled = true
    self.pending = false
    self.generation = self.generation + 1
    close_timer(self)
    pending_controls[self] = nil
    if self.started and type(self.child_cancel) == "function" then
      pcall(self.child_cancel)
    elseif not was_started and type(spec.on_cancel) == "function" then
      pcall(spec.on_cancel, self)
    end
    return true
  end

  function control:wake()
    if self.cancelled or self.finished or self.started then return false end
    close_timer(self)
    self.pending = false
    self.generation = self.generation + 1
    local generation = self.generation
    local schedule = spec.schedule or vim.schedule
    schedule(function()
      if self.generation == generation then attempt() end
    end)
    return true
  end

  local function arm_retry(opts)
    close_timer(control)
    local factory = spec.timer_factory or uv.new_timer
    local ok, timer = pcall(factory)
    if not ok or not timer then
      control.finished = true
      control.pending = false
      control.error = ok and "timer-unavailable" or tostring(timer)
      pending_controls[control] = nil
      if type(spec.on_error) == "function" then spec.on_error(control.error, control) end
      return
    end
    control.timer = timer
    control.generation = control.generation + 1
    local generation = control.generation
    local retry_ms = math.max(tonumber(spec.retry_ms) or tonumber(opts.retry_ms)
      or M.DEFAULTS.retry_ms, 50)
    local started, start_err = pcall(timer.start, timer, retry_ms, 0, function()
      local schedule = spec.schedule or vim.schedule
      schedule(function()
        if control.generation ~= generation
            or control.cancelled or control.finished or control.started then return end
        close_timer(control)
        control.pending = false
        attempt()
      end)
    end)
    if not started then
      close_timer(control)
      control.finished = true
      control.pending = false
      control.error = tostring(start_err)
      pending_controls[control] = nil
      if type(spec.on_error) == "function" then spec.on_error(control.error, control) end
    end
  end

  attempt = function()
    if control.cancelled or control.finished or control.started then return false end
    local opts = vim.tbl_extend("force", M.options(), spec.options or {})
    if spec.foreground_active ~= nil then
      opts.foreground_active = spec.foreground_active
    else
      opts.foreground_active = M.foreground_active()
    end
    opts.was_deferring = control.deferrals > 0
    local reading = type(spec.reading) == "function" and spec.reading() or M.current_reading()
    local allow, reason = M.admit(reading, control.deferrals, opts)
    control.reason = reason

    if not allow then
      control.pending = true
      control.attempts = control.attempts + 1
      -- Foreground ownership is not CPU pressure and must not consume the CPU
      -- starvation cap; otherwise a long build would force-start every queued
      -- batch immediately when it exits, even if the host is still saturated.
      if reason ~= "foreground-work-active" then
        control.deferrals = control.deferrals + 1
      end
      pending_controls[control] = true
      if type(spec.on_defer) == "function" then
        pcall(spec.on_defer, reason, reading, control.deferrals, control)
      else
        pcall(function()
          require("utils.log").debug_ctx("host.admission", "deferred background work", {
            workload = control.name,
            reason = reason,
            deferrals = control.deferrals,
            host_pct = reading and reading.host_pct or nil,
          })
        end)
      end
      arm_retry(opts)
      return false
    end

    control.pending = false
    control.started = true
    pending_controls[control] = nil
    close_timer(control)
    local ok, first, second = pcall(spec.start, reading, reason, control)
    if not ok then
      control.error = tostring(first)
      control.finished = true
      if type(spec.on_error) == "function" then spec.on_error(control.error, control) end
      return true, nil, control.error
    end
    control.result = first
    if type(first) == "function" then control.child_cancel = first end
    return true, first, second
  end

  local started, first, second = attempt()
  return started, first, second, control
end

--- Test-only cleanup: cancel queued controls and clear foreground ownership.
function M._reset_for_test()
  for control in pairs(pending_controls) do control:cancel() end
  foreground = {}
  foreground_sequence = 0
  pending_controls = setmetatable({}, { __mode = "k" })
end

return M
