-- Continuous private proof queue; production activation still belongs to batch_runtime.
local M = {}
local sessions = {}
local admission = require("utils.host_admission")
local locks = require("ue.file_lock")
local progress = require("ue.index.batch_progress")

local function snapshot(record)
  local value = progress.snapshot(record, record.progress_options)
  local state = record.scheduling
  if state then
    local suppressed = {}
    for id, status in pairs(state.states) do
      if status == "suppressed" then suppressed[#suppressed + 1] = id end
    end
    table.sort(suppressed)
    -- Current queue only; end-to-end experiments retain their own attempt logs.
    value.large_first = { suppressed_ids = suppressed, released_fallback_count = state.released_count,
      attempts = vim.deepcopy(state.attempts) }
  end
  return value
end

local function scheduling_plan(groups)
  local linked = false
  for _, group in ipairs(groups) do
    if group.schedule_role ~= nil or group.fallback_of ~= nil then linked = true end
  end
  if not linked then return nil end -- Keep the ordinary FIFO path unchanged.
  local state = { parents = {}, by_id = {}, states = {}, ready = {}, head = 1, attempts = {}, released_count = 0 }
  local parents = 0
  for _, group in ipairs(groups) do
    if type(group.id) ~= "string" or group.id == "" or state.by_id[group.id] then
      return nil, "invalid-proof-scheduling-id"
    end
    state.by_id[group.id] = group
    if group.schedule_role ~= nil then
      if group.schedule_role ~= "large-first" or group.fallback_of ~= nil then
        return nil, "invalid-proof-scheduling-parent"
      end
      parents = parents + 1
      state.parents[group.id] = { children = {} }
      state.states[group.id] = "ready"
      state.ready[#state.ready + 1] = group
    end
  end
  if parents == 0 or parents > 2 then return nil, "invalid-proof-scheduling-parent-count" end
  for _, group in ipairs(groups) do
    if group.fallback_of ~= nil then
      local parent = type(group.fallback_of) == "string" and state.parents[group.fallback_of]
      if not parent then return nil, "invalid-proof-scheduling-fallback" end
      parent.children[#parent.children + 1] = group
      state.states[group.id] = "deferred"
    elseif not state.parents[group.id] then
      state.states[group.id] = "ready"
      state.ready[#state.ready + 1] = group
    end
  end
  -- Full membership/packing/store validation remains in Python's plan loader.
  return state
end

local function read_json(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > 4194304 then return nil end
  local file = io.open(path, "rb")
  if not file then return nil end
  local raw = file:read("*a")
  file:close()
  local ok, value = pcall(vim.json.decode, raw)
  return ok and value or nil
end

local function signature(path)
  local stat = vim.uv.fs_stat(path)
  return stat and { size = stat.size, mtime = stat.mtime, ctime = stat.ctime } or nil
end

function M.status(scope)
  return sessions[scope]
end

function M.summary(scope)
  local record = sessions[scope]
  if not record then return progress.summary(scope) end
  return snapshot(record)
end

function M.stop(scope)
  local record = sessions[scope]
  if not record or record.stopped then return end
  record.stopped = true
  if record.timer then record.timer:stop(); record.timer:close(); record.timer = nil end
  local controls = {}
  for _, control in pairs(record.controls) do controls[#controls + 1] = control end
  for _, control in ipairs(controls) do control:cancel() end
  -- Worker Job Objects close their owned descendants when the worker exits.
  if record.running == 0 and record.finish then record.finish("stopped") end
end

--- Injectable queue: never reads the CDB on the main loop, only small metadata.
function M.start(spec, opts)
  opts = opts or {}
  local residual_limit = spec.residual_strict_limit
  if residual_limit ~= nil then
    if type(residual_limit) ~= "number" or (residual_limit ~= 1 and residual_limit ~= 2) then
      return nil, "invalid-residual-strict-limit"
    end
    if spec.auto_tier1_large or type(spec.env) ~= "table" or spec.env.NVIM_UE_BATCH_TIER ~= "strict" then
      return nil, "invalid-residual-strict-mode"
    end
    local environment_key = require("utils.platform").driver().environment_key
    local tier_key, tier_keys = environment_key("NVIM_UE_BATCH_TIER"), 0
    for name in pairs(spec.env) do
      if environment_key(name) == tier_key then tier_keys = tier_keys + 1 end
    end
    if tier_keys ~= 1 then return nil, "invalid-residual-strict-mode" end
  end
  local now = opts.now or function() return vim.uv.hrtime() / 1e6 end
  local schedule = opts.schedule or vim.schedule
  local read = opts.read_json or read_json
  local acquire, release = opts.acquire or locks.acquire, opts.release or locks.release
  local prior = sessions[spec.scope]
  local identity = { clangd = spec.clangd, profile = spec.profile, env = spec.env,
    auto_tier1_large = spec.auto_tier1_large, residual_strict_limit = residual_limit }
  if prior and not prior.stopped and not prior.finished_at and vim.deep_equal(prior.signature, spec.signature)
      and vim.deep_equal(prior.identity, identity) and prior.current() then return prior end
  if prior and (residual_limit or prior.identity.residual_strict_limit)
      and (not prior.finished_at or prior.running > 0) then return nil, "proof-queue-active" end
  if prior and prior.running > 0 then M.stop(spec.scope); return nil, "previous-proof-exiting" end
  local lease, err = acquire(spec.store .. ".background.lock")
  if not lease then return nil, err end
  local record = { scope = spec.scope, signature = spec.signature, identity = identity, lease = lease, controls = {},
    running = 0, next_group = 1, completed = {}, accepted = 0, rejected = 0,
    last_publish = now(), published_count = 0, started_at = os.time(), phase = "planning",
    owner_pid = vim.fn.getpid(), pending_accepted = {}, progress_options = { alive = opts.owner_alive } }
  local state_path = spec.state_path or progress.path(spec.scope)
  local previous = progress.read(state_path)
  record.last_proof, record.last_collect = previous and previous.last_proof, previous and previous.last_collect
  record.last_collect_success = previous and previous.last_collect_success
  local function persist()
    local ok, reason = (opts.write_summary or progress.write)(state_path, snapshot(record))
    if not ok then record.persistence_error = tostring(reason) end
  end
  sessions[spec.scope] = record
  local current = opts.current or function()
    return not record.stopped and vim.deep_equal(signature(spec.source), spec.signature)
      and (not spec.current or spec.current())
  end
  record.current = current
  local run = opts.run or function(command, callback)
    local handle = vim.system(command, { text = true, cwd = spec.cwd, env = spec.env, clear_env = true },
      function(result) schedule(function() callback(result) end) end)
    pcall(function() require("utils.task_registry").register({ name = "SuperUnity proof", group = "ue",
      kind = "system", handle = handle, started_at = os.time() }) end)
    return function() pcall(handle.kill, handle, 15) end
  end
  local function finish(reason)
    if record.finished_at then return end
    if record.stopped and record.scheduling then
      for id, attempt in pairs(record.scheduling.attempts) do
        if attempt.outcome == "running" then
          attempt.outcome, attempt.completed_at = "cancelled", os.time()
          record.scheduling.states[id] = "cancelled"
        end
      end
    end
    record.phase, record.reason = "finished", reason
    record.finished_at = os.time()
    persist()
    if record.timer then record.timer:stop(); record.timer:close(); record.timer = nil end
    release(lease)
    if record.publish_lease then release(record.publish_lease); record.publish_lease = nil end
    if opts.on_done then opts.on_done(record) end
  end
  record.finish = finish
  persist()
  local function log_error(reason)
    record.error = reason
    persist()
    pcall(function() require("utils.log").warn_ctx("ue.index", "background proof retained originals",
      { reason = reason, scope = spec.scope }) end)
  end
  local serial = 0
  local function launch(arguments, callback, before_start)
    serial = serial + 1
    local slot = serial
    record.running = record.running + 1
    local command = { spec.python, "-u", spec.script }
    vim.list_extend(command, arguments)
    vim.list_extend(command, { "--clangd", spec.clangd })
    if spec.profile then vim.list_extend(command, { "--server-profile", vim.json.encode(spec.profile) }) end
    local completed = false
    local function done(result)
      if completed then return end
      completed = true
      record.controls[slot] = nil
      record.running = record.running - 1
      if record.stopped then
        if record.running == 0 then finish("stopped") end
        return
      end
      callback(result)
    end
    local _, _, _, control = (opts.admit or admission.run_when_allowed)({ name = "SuperUnity proof",
      start = function()
        if not current() then schedule(function() done({ code = 1, stderr = "proof-input-changed" }) end); return end
        if before_start and not before_start() then
          schedule(function() done({ code = 1, stderr = "proof-publication-writer-busy" }) end); return
        end
        record.deferred_reason = nil
        return run(command, done)
      end,
      on_cancel = function() done({ code = 1, stderr = "proof-cancelled" }) end,
      on_error = function(reason) done({ code = 1, stderr = tostring(reason) }) end,
      on_defer = function(reason) record.deferred_reason = reason; persist() end,
    })
    if not completed then record.controls[slot] = control end
  end
  local pump, arm
  local publishing = false
  local groups = {}
  local max_workers = residual_limit and 1 or math.max(1, math.min(2, opts.max_workers or 2))
  local interval = opts.publish_interval_ms or 120000
  local function release_children(id)
    local state = record.scheduling
    for _, child in ipairs(state.parents[id].children) do
      local status = state.states[child.id]
      if status == "deferred" or status == "suppressed" then
        state.states[child.id] = "ready"
        state.ready[#state.ready + 1] = child
        state.released_count = state.released_count + 1
      end
    end
  end
  local function reconcile_scheduling(validated)
    local state = record.scheduling
    if not state then return end
    for id in pairs(validated) do
      if state.by_id[id] and not state.parents[id] then state.states[id] = "completed" end
    end
    for id in pairs(record.recovered or {}) do
      if not state.parents[id] and not validated[id] then
        local group = state.by_id[id]
        if group.fallback_of then state.states[id] = "deferred"
        else
          state.states[id] = "ready"
          state.ready[#state.ready + 1] = group
        end
      end
    end
    for id in pairs(state.parents) do
      local status = state.states[id]
      if validated[id] then
        state.states[id] = "admitted"
        if state.attempts[id] then
          state.attempts[id].outcome, state.attempts[id].collect_outcome = "admitted", "admitted"
          state.attempts[id].collected_at = os.time()
        end
        for _, child in ipairs(state.parents[id].children) do
          if state.states[child.id] == "deferred" or state.states[child.id] == "ready" then
            state.states[child.id] = "suppressed"
          end
        end
      elseif status == "awaiting-collect" or status == "admitted" then
        state.states[id] = "released"
        if state.attempts[id] then
          local outcome = status == "admitted" and "invalidated" or "not-selected"
          state.attempts[id].outcome, state.attempts[id].collect_outcome = outcome, outcome
          state.attempts[id].collected_at = os.time()
        end
        release_children(id)
      end
    end
    record.collect_needed = false
  end
  local function next_ready(take)
    local state = record.scheduling
    if not state then
      local group = groups[record.next_group]
      if group and take then record.next_group = record.next_group + 1 end
      return group
    end
    while state.head <= #state.ready do
      local group = state.ready[state.head]
      if state.states[group.id] == "ready" then
        if take then state.head = state.head + 1; state.states[group.id] = "running" end
        return group
      end
      state.head = state.head + 1
    end
  end
  local function publish()
    if publishing or record.running > 0 or #record.completed == record.published_count then return false end
    local phase_lease
    publishing, record.phase = true, "collecting"
    record.last_collect = { started_at = os.time(), outcome = "running" }
    persist()
    local arguments = { "--collect", spec.plan, "--completed", vim.json.encode(record.completed),
      "--background", spec.background, "--marker", spec.marker, "--out", spec.collect_result }
    if spec.publication_request then
      vim.list_extend(arguments, { "--publish-request", spec.publication_request_path,
        "--nvim", spec.nvim, "--publish-worker", spec.publication_worker })
    end
    launch(arguments, function(result)
      publishing = false
      local delivered, collected = false, nil
      if result.code == 0 and current() then
        collected = read(spec.collect_result)
        if collected and collected.ok then
          local ok, failure = pcall(spec.publish, collected)
          if not ok then log_error(tostring(failure)) else delivered = true end
        else log_error("invalid-proof-collection") end
      else log_error(result.stderr or "proof-collection-failed") end
      if delivered then
        record.error = nil
        record.collect_accepted = collected.metrics and (collected.metrics.collect_accepted_count or collected.metrics.batch_count) or 0
        record.published_count, record.last_publish = #record.completed, now()
        record.publications = (record.publications or 0) + 1
        record.pending_accepted = {}
        local validated = {}
        for _, id in ipairs(collected.revalidated_completed or {}) do validated[id] = true end
        reconcile_scheduling(validated)
        if record.recovered then
          for id in pairs(record.recovered) do
            if not validated[id] then record.recovered[id] = nil end
          end
        end
      end
      record.last_collect.finished_at = os.time()
      record.last_collect.outcome = delivered and "published" or "failed"
      record.last_collect.reason = delivered and nil or record.error
      if delivered then record.last_collect_success = vim.deepcopy(record.last_collect) end
      persist()
      if phase_lease then release(phase_lease) end
      record.publish_lease = nil
      if delivered then pump() else
        if record.scheduling then record.collect_needed = true end
        arm(5000)
      end
    end, function()
      phase_lease = acquire(spec.publish_lock)
      record.publish_lease = phase_lease
      if phase_lease and spec.publication_request then
        local payload = vim.deepcopy(spec.publication_request)
        payload.lease, payload.owner_pid, payload.source_sha256 = phase_lease, vim.fn.getpid(), record.input_sha256
        local file = io.open(spec.publication_request_path, "wb")
        if not file then return false end
        local wrote, closed = file:write(vim.json.encode(payload)), file:close()
        if not wrote or not closed then return false end
      end
      return phase_lease ~= nil
    end)
    return true
  end
  arm = function(delay)
    if record.timer or record.stopped then return end
    local timer = (opts.timer_factory or vim.uv.new_timer)()
    record.timer = timer
    timer:start(delay, 0, function()
      timer:stop(); timer:close(); record.timer = nil
      schedule(pump)
    end)
  end
  local function pump_once()
    if record.stopped or record.finished_at then return end
    if not current() then
      record.stopped = true
      local controls = {}
      for _, control in pairs(record.controls) do
        if not control.started then controls[#controls + 1] = control end
      end
      for _, control in ipairs(controls) do control:cancel() end
      if record.running == 0 then finish("proof-input-changed") end
      return
    end
    local all_done = next_ready(false) == nil
    if record.running == 0 and (all_done or record.collect_needed or now() - record.last_publish >= interval)
        and publish() then return end
    if all_done then
      if record.running == 0 then finish("queue-complete") end
      return
    end
    if publishing then return end
    record.phase = "proving"
    -- Drain running workers before publication; do not keep adding work beyond
    -- the coalescing deadline, which would otherwise starve publication.
    if #record.completed > record.published_count and (record.collect_needed or now() - record.last_publish >= interval) then return end
    while record.running < max_workers and not publishing and not record.collect_needed and not record.finished_at do
      local group = next_ready(true)
      if not group then break end
      if record.recovered and record.recovered[group.id] then
        -- This hint is handed only to the ordinary cache-only receipt collector.
        -- A rejected/stale receipt remains original UBT; no historical ok grants it.
      else
      local state = record.scheduling
      if state and state.parents[group.id] then
        state.attempts[group.id] = { started_at = os.time(), outcome = "running" }
      end
      local output = spec.control_dir .. "/result-" .. group.id .. ".json"
      launch({ "--worker", spec.plan, "--group", group.id, "--out", output }, function(result)
        local accepted_candidate, valid_result = false, false
        if result.code == 0 then
          local value = read(output)
          if value and value.ok and value.metrics then
            valid_result = true
            accepted_candidate = (value.metrics.batch_count or value.metrics.proof_accepted_count
              or value.metrics.new_batch_count or 0) > 0
            record.completed[#record.completed + 1] = group.id
            record.accepted = record.accepted + (value.metrics.new_batch_count or 0)
            record.rejected = record.rejected + (value.metrics.new_proof_count or 0) - (value.metrics.new_batch_count or 0)
            record.uncached = (record.uncached or 0) + (value.metrics.proof_uncached_count or 0)
            record.pending_accepted[group.id] = value.metrics.new_batch_count or 0
            record.last_proof = { group_id = group.id, completed_at = value.completed_at or os.time(),
              accepted = value.metrics.new_batch_count or 0, outcome = "completed" }
          else log_error("invalid-proof-result") end
        else
          log_error(result.stderr or "private-proof-failed")
          record.last_proof = { group_id = group.id, completed_at = os.time(), outcome = "failed", reason = record.error }
        end
        if state then
          state.states[group.id] = "completed"
          if state.parents[group.id] then
            state.attempts[group.id].completed_at = os.time()
            state.attempts[group.id].outcome = accepted_candidate and "awaiting-collect"
              or valid_result and "rejected" or "failed"
            state.attempts[group.id].proof_outcome = accepted_candidate and "accepted"
              or valid_result and "rejected" or "failed"
            state.attempts[group.id].reason = not valid_result and record.error or nil
            if accepted_candidate then
              state.states[group.id], record.collect_needed = "awaiting-collect", true
            else
              state.states[group.id] = "released"
              release_children(group.id)
            end
          end
        end
        persist()
        pump()
      end)
      end
    end
    if record.running == 0 and next_ready(false) == nil then
      if not publish() then finish("queue-complete") end
    end
  end
  local pumping, repump = false, false
  pump = function()
    if pumping then repump = true; return end
    pumping = true
    repeat
      repump = false
      pump_once()
    until not repump
    pumping = false
  end
  local plan_arguments = { "--plan", spec.source, "--store", spec.store, "--out", spec.plan }
  if spec.auto_tier1_large then plan_arguments[#plan_arguments + 1] = "--auto-tier1-large" end
  if residual_limit then vim.list_extend(plan_arguments, { "--residual-strict-limit", tostring(residual_limit) }) end
  launch(plan_arguments, function(result)
    local plan = result.code == 0 and read(spec.plan) or nil
    if not current() or not plan or plan.schema ~= 1 or type(plan.groups) ~= "table" then
      finish(result.stderr or "invalid-proof-plan"); return
    end
    if plan.residual_strict_limit ~= residual_limit or (residual_limit and plan.mode ~= "strict") then
      finish("residual-strict-plan-mismatch"); return
    end
    groups = plan.groups
    local scheduling, scheduling_error = scheduling_plan(groups)
    if scheduling_error then log_error(scheduling_error); finish(scheduling_error); return end
    record.scheduling = scheduling
    record.input_sha256 = plan.input_sha256
    record.group_count = plan.plan_candidate_count or #groups
    record.cached_accepted = plan.proof_accepted_count or plan.legacy_batch_count or 0
    record.cached_rejected = plan.proof_rejected_count or 0
    record.cached_uncached = plan.proof_uncached_count or 0
    record.selector_reuse = plan.selector_reuse_status
    record.recovered = {}
    local planned = {}
    for _, group in ipairs(groups) do planned[group.id] = true end
    for _, hint in ipairs(plan.recovered_completed or {}) do
      if planned[hint.id] and not record.recovered[hint.id] then
        record.recovered[hint.id] = true
        record.completed[#record.completed + 1] = hint.id
        record.pending_accepted[hint.id] = tonumber(hint.accepted_hint) or 0
        if scheduling then
          scheduling.states[hint.id] = scheduling.parents[hint.id] and "awaiting-collect" or "recovered"
          if scheduling.parents[hint.id] then record.collect_needed = true end
        end
      end
    end
    persist()
    if #record.completed > 0 and publish() then return end
    pump()
  end)
  return record
end

vim.api.nvim_create_autocmd("VimLeavePre", { callback = function()
  for scope in pairs(sessions) do M.stop(scope) end
end })

return M
