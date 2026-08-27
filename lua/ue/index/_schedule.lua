-- ue/index/_schedule.lua — WHEN each controlled index phase runs.
--
-- WHY THIS IS ITS OWN MODULE
-- --------------------------
-- Scheduling is a policy with a delivery guarantee attached, and it was the
-- single point where "UEPrepare finished" silently failed to mean "the semantic
-- index exists". Splitting it out of _build.lua keeps that file under the
-- 800-line structure limit and gives the policy a name of its own.
--
-- THE DEFECT THIS FIXES (measured 2026-08-26)
-- ------------------------------------------
-- Every UEPrepare completion path called `schedule_index_refresh{full=true}`
-- WITHOUT `full_delay_ms`, so `full` fell back to `idle_cold_ms` = 120000ms.
-- Worse, `schedule_index_phase` stops and RECREATES the timer for a phase key,
-- so any later refresh restarts the countdown. Measured directly: two schedules
-- 300ms apart with a 1500ms delay fired at 1821ms — the deadline moved.
--
-- A `BufWritePost` on any C/C++ file reschedules current+hot (lua/ue.lua), and
-- two minutes of uninterrupted idling without a single C++ save is rare in a
-- real session. So `full` was not late, it was STARVED. Field evidence from this
-- machine: a 388s prepare completed, yet stats stayed
-- {full_runs:0, hot_runs:0, current_runs:0} and no index build log had ever been
-- written — the user ran the habitual flow three times and never got a usable
-- `gd`, with nothing on screen explaining why.
--
-- THE RULE
-- --------
-- Two distinct contracts, deliberately not merged:
--   * refresh  — opportunistic catch-up. Long, resettable deadlines are fine.
--   * delivery — prepare PROMISED a usable index. Short deadlines, and the
--                deadline MUST NOT be pushed out by unrelated editing.
--
-- Loader style per lua/ue/index/AGENTS.md; loaded after _build so
-- build_phase_async / base_compile_commands_path already exist.

return function(M, core)
  local fs = require("ue.core.fs") -- luacheck: ignore 211
  local RT = core.RT
  local ensure_index_state = core.h.ensure_index_state
  local save_index_state = core.h.save_index_state
  local unix_now = core.h.unix_now

  --- Should this schedule request be allowed to (re)arm the phase timer?
  ---
  --- Pure, so the anti-starvation rule is provable headless. A protected deadline
  --- belongs to a delivery promise (prepare) and MUST NOT be pushed out by later
  --- opportunistic refreshes; only another protected request may re-arm it.
  --- @param protected boolean whether a protected deadline is already pending
  --- @param wants_protect boolean whether this request is itself protected
  --- @return boolean allow
  M._may_rearm = function(protected, wants_protect)
    if protected and not wants_protect then
      return false
    end
    return true
  end

  --- Shared start gate for timer deadlines AND queued-drain starts.
  M.admit_index_phase_start = function(ctx, phase, opts)
    opts = opts or {}
    if not M.admit_background_phase then return true end
    local policy = M.admission_opts()
    local load
    if policy.enabled ~= false then
      local ok_load, cpu_load = pcall(require, "utils.cpu_load")
      if ok_load then load = cpu_load.reading and cpu_load.reading() or cpu_load.busy() end
    end
    local timer_key = core.deps.status_root_key(ctx) .. "::" .. phase
    RT.admission_deferrals = RT.admission_deferrals or {}
    local deferred = RT.admission_deferrals[timer_key] or 0
    policy.was_deferring = deferred > 0
    local allow, reason = M.admit_background_phase(load, deferred, policy)
    if allow then RT.admission_deferrals[timer_key] = nil; return true end

    -- Foreground ownership is not CPU pressure; a long build must not consume
    -- the CPU starvation cap and force queued phases through on exit.
    local next_deferred = reason == "foreground-work-active" and deferred or deferred + 1
    RT.admission_deferrals[timer_key] = next_deferred
    pcall(function()
      local reading = type(load) == "table" and load or {}
      local busy = reading.host_pct or (type(load) == "number" and load or nil)
      require("utils.log").debug_ctx("ue.index", "deferred index phase under host CPU pressure", {
        phase = phase,
        awareness_status = reading.status,
        busy_pct = busy and math.floor(busy + 0.5) or nil,
        editor_pct = reading.editor_pct and math.floor(reading.editor_pct + 0.5) or nil,
        host_trend = reading.host_trend,
        sample_age_ms = reading.age_ms and math.floor(reading.age_ms + 0.5) or nil,
        high_pct = policy.high_pct,
        deferrals = next_deferred,
        reason = reason,
      })
    end)
    M.schedule_index_phase(ctx, phase, M.ADMISSION_RETRY_MS, { protect = opts.protect == true })
    return false
  end

  M.schedule_index_phase = function(ctx, phase, delay_ms, opts)
    if not ctx then
      return
    end
    opts = opts or {}
    local timer_key = core.deps.status_root_key(ctx) .. "::" .. phase
    -- A deferred re-arm must keep the SAME protection level, or a protected
    -- delivery deadline would silently lose its anti-starvation guarantee the
    -- first time the host was busy.
    local protect_again = opts.protect and true or false

    -- Decide BEFORE mutating persisted state: a rejected reschedule must not
    -- rewrite the queue or touch the state file at all.
    RT.protected_deadlines = RT.protected_deadlines or {}
    if not M._may_rearm(RT.protected_deadlines[timer_key] and true or false, opts.protect and true or false) then
      return
    end
    if opts.protect then
      RT.protected_deadlines[timer_key] = true
    end

    local state = ensure_index_state(ctx)
    state.queue[phase] = unix_now()
    save_index_state(ctx, state)

    if RT.timers[timer_key] then
      RT.timers[timer_key]:stop()
      RT.timers[timer_key]:close()
      RT.timers[timer_key] = nil
    end
    local timer = vim.uv.new_timer()
    RT.timers[timer_key] = timer
    timer:start(delay_ms, 0, vim.schedule_wrap(function()
      if RT.timers[timer_key] then
        RT.timers[timer_key]:stop()
        RT.timers[timer_key]:close()
        RT.timers[timer_key] = nil
      end
      if RT.protected_deadlines then
        RT.protected_deadlines[timer_key] = nil
      end

      -- The deadline answers WHEN; the shared gate answers WHETHER. Queued
      -- drain uses this same function, so no second start path can bypass it.
      if not M.admit_index_phase_start(ctx, phase, { protect = protect_again }) then return end
      M.build_phase_async(ctx, phase)
    end))
  end

  M.schedule_index_refresh = function(ctx, opts)
    opts = opts or {}
    if not ctx or not M.base_compile_commands_path(ctx) then
      return
    end
    if opts.current ~= false then
      M.schedule_index_phase(ctx, "current", opts.current_delay_ms or RT.debounce_current_ms)
    end
    if opts.hot then
      M.schedule_index_phase(ctx, "hot", opts.hot_delay_ms or RT.debounce_hot_ms)
    end
    if opts.full then
      M.schedule_index_phase(ctx, "full", opts.full_delay_ms or RT.idle_cold_ms)
    end
  end

  --- Delay for a phase whose deadline must SURVIVE ordinary editing.
  ---
  --- MEASURED DEFECT (2026-08-26): every UEPrepare completion path scheduled the
  --- `full` phase without `full_delay_ms`, so it fell back to `idle_cold_ms`
  --- (120000ms). And `schedule_index_phase` stops and RECREATES the timer for the
  --- same phase key, so every later refresh restarts the countdown -- verified
  --- empirically: two schedules 300ms apart with a 1500ms delay fired at 1821ms,
  --- i.e. the deadline moved.
  ---
  --- A `BufWritePost` on any C/C++ file calls schedule_index_refresh again
  --- (lua/ue.lua). Two minutes of *uninterrupted* idling with no C++ save is rare
  --- in a real session, so `full` was not merely late -- it was STARVED. Field
  --- evidence: a 388s prepare completed today, yet stats stayed
  --- {full_runs:0, hot_runs:0, current_runs:0} and no index build log had ever
  --- been written on this machine.
  ---
  --- Fix: when prepare explicitly asks for delivery, the deadline is short and
  --- MUST NOT be pushed out by unrelated editing. `idle_cold_ms` keeps its meaning
  --- for opportunistic background refreshes.
  M.PREPARE_FULL_DELAY_MS = 1500

-- How long to wait before re-checking host load after a deferral. Short enough
-- that the index starts promptly once the machine calms down, long enough that we
-- are not re-sampling CPU in a tight loop.
M.ADMISSION_RETRY_MS = 5000

  --- Schedule the phases UEPrepare is responsible for delivering.
  ---
  --- Separate from schedule_index_refresh because the two have different
  --- contracts: a refresh is opportunistic ("catch up when idle"), whereas prepare
  --- has promised the user a usable semantic index. Prepare's schedule therefore
  --- uses short deadlines and is protected from deadline-restart starvation.
  --- @param ctx table
  M.schedule_prepare_delivery = function(ctx)
    if not ctx or not M.base_compile_commands_path(ctx) then
      return
    end
    M.schedule_index_phase(ctx, "current", 50)
    M.schedule_index_phase(ctx, "hot", 2500)
    M.schedule_index_phase(ctx, "full", M.PREPARE_FULL_DELAY_MS, { protect = true })
  end
end
