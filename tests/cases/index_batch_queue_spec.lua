local t = require("tests.harness")
t.bootstrap()

local function fixture(count, settings)
  settings = settings or {}
  local module = dofile(vim.fn.getcwd() .. "/lua/ue/index/batch_background.lua")
  local env = { jobs = {}, timers = {}, released = {}, acquired = {}, published = 0, time = 0, valid = true, cancellations = 0 }
  local groups = {}
  for index = 1, count do groups[index] = { id = "group-" .. index } end
  groups = settings.groups or groups
  env.validated, env.worker_results = settings.validated, settings.worker_results or {}
  local function argument(command, name)
    for index, value in ipairs(command) do if value == name then return command[index + 1] end end
  end
  env.argument = argument
  local function timer()
    local value = {}
    function value:start(delay, _, callback) self.delay, self.callback = delay, callback end
    function value:stop() self.stopped = true end
    function value:close() self.closed = true end
    env.timers[#env.timers + 1] = value
    return value
  end
  local function run(command, callback)
    local job = { command = command, callback = callback, action = argument(command, "--worker") and "worker"
      or argument(command, "--collect") and "collect" or "plan" }
    env.jobs[#env.jobs + 1] = job
    if settings.synchronous then job.done = true; callback({ code = 0 }) end
    return function() env.cancellations = env.cancellations + 1 end
  end
  local opts = {
    max_workers = settings.max_workers,
    now = function() return env.time end,
    current = function() return env.valid end,
    schedule = function(callback) callback() end,
    timer_factory = timer,
    acquire = function(path)
      env.acquired[#env.acquired + 1] = path
      if settings.lock_busy then return nil, "fixture-store-busy" end
      return { path = path }
    end,
    release = function(lease) env.released[#env.released + 1] = lease.path end,
    run = run,
    read_json = function(path)
      if path == "plan.json" then return settings.plan or { schema = 1, groups = groups, proof_accepted_count = 3,
        mode = settings.residual_strict_limit and "strict" or "1", residual_strict_limit = settings.residual_strict_limit,
        proof_rejected_count = 2, proof_uncached_count = 8, selector_reuse_status = "accepted",
        recovered_completed = settings.recovered, plan_candidate_count = settings.plan_candidate_count } end
      if path == "collect.json" then return { ok = not env.bad_collect, changed = true, metrics = { collect_accepted_count = 4 },
        revalidated_completed = env.validated } end
      local id = path:match("/result%-(.+)%.json$")
      if id and env.worker_results[id] then return env.worker_results[id] end
      return { ok = true, metrics = { new_batch_count = 1, new_proof_count = 1 } }
    end,
    write_summary = function(_, value) env.summary = vim.deepcopy(value); return true end,
    admit = function(spec)
      local cancel = spec.start()
      return true, cancel, nil, { cancel = function() if cancel then cancel() else spec.on_cancel() end end }
    end,
  }
  if settings.shared_admission then
    local admission = require("utils.host_admission")
    opts.admit = function(spec)
      spec.options = { enabled = false }
      spec.schedule, spec.timer_factory = opts.schedule, timer
      spec.reading = function() return { host_pct = 0 } end
      return admission.run_when_allowed(spec)
    end
  end
  local spec = { scope = "queue-fixture", signature = "input-a", source = "semantic.json", store = "proofs",
    auto_tier1_large = settings.auto_tier1_large,
    residual_strict_limit = settings.residual_strict_limit,
    env = settings.env or (settings.residual_strict_limit ~= nil and { NVIM_UE_BATCH_TIER = "strict" } or nil),
    plan = "plan.json", python = "python", script = "tool.py", clangd = "clangd", control_dir = "control",
    publish_lock = "publication.lock", background = "background.json", marker = "marker.json", collect_result = "collect.json",
    publish = function()
      if env.publish_error then error("fixture-publication-rejected") end
      env.published = env.published + 1
    end }
  env.module, env.spec, env.opts = module, spec, opts
  env.record, env.reason = module.start(spec, opts)
  function env:complete(index, code)
    self.jobs[index].done = true
    self.jobs[index].callback({ code = code or 0, stderr = code and "cancelled" or nil })
  end
  function env:complete_next(action, code)
    for index, job in ipairs(self.jobs) do
      if job.action == action and not job.done then self:complete(index, code); return index end
    end
    error("no pending " .. action .. " job")
  end
  function env:count(action)
    local total = 0
    for _, job in ipairs(self.jobs) do if job.action == action then total = total + 1 end end
    return total
  end
  return env
end

local function family(extra)
  local groups = { { id = "large", schedule_role = "large-first" },
    { id = "small-1", fallback_of = "large" }, { id = "small-2", fallback_of = "large" } }
  for index = 1, extra or 0 do groups[#groups + 1] = { id = "other-" .. index } end
  return groups
end

local function worker_ids(env)
  local ids = {}
  for _, job in ipairs(env.jobs) do
    if job.action == "worker" then ids[#ids + 1] = env.argument(job.command, "--group") end
  end
  return ids
end

local function assert_list(actual, expected, message)
  t.assert_true(vim.deep_equal(actual, expected), (message or "list equality")
    .. ": expected " .. vim.inspect(expected) .. ", got " .. vim.inspect(actual))
end

t.describe("连续后台二次证明队列", function()
  t.it("residual limit rejects malformed requests before acquiring a lease", function()
    for _, limit in ipairs({ 0, 3, 1.5, "1", true, false }) do
      local env = fixture(0, { residual_strict_limit = limit })
      t.assert_eq(env.record, nil)
      t.assert_eq(env.reason, "invalid-residual-strict-limit")
      t.assert_eq(#env.acquired, 0)
      t.assert_eq(#env.jobs, 0)
    end
    for _, settings in ipairs({ { residual_strict_limit = 1, auto_tier1_large = true },
      { residual_strict_limit = 1, env = { NVIM_UE_BATCH_TIER = "1" } } }) do
      local env = fixture(0, settings)
      t.assert_eq(env.record, nil)
      t.assert_eq(env.reason, "invalid-residual-strict-mode")
      t.assert_eq(#env.acquired, 0)
      t.assert_eq(#env.jobs, 0)
    end
  end)

  t.it("residual requests force one worker and pass the limit only to planning", function()
    local env = fixture(2, { residual_strict_limit = 2, max_workers = 2 })
    t.assert_eq(env.argument(env.jobs[1].command, "--residual-strict-limit"), "2")
    t.assert_false(vim.tbl_contains(env.jobs[1].command, "--auto-tier1-large"))
    env:complete_next("plan")
    t.assert_eq(env:count("worker"), 1)
    t.assert_eq(env.module.start(env.spec, env.opts), env.record)
    env:complete_next("worker")
    t.assert_eq(env:count("worker"), 2)
    t.assert_eq(env.record.running, 1)
    env:complete_next("worker"); env:complete_next("collect")
    for index = 2, #env.jobs do
      t.assert_eq(env.argument(env.jobs[index].command, "--residual-strict-limit"), nil)
    end
    t.assert_eq(env.record.phase, "finished")
    local previous = env.record
    env.record = env.module.start(env.spec, env.opts)
    t.assert_true(env.record ~= previous, "finished requests revalidate even with the same CDB signature")
    t.assert_eq(env:count("plan"), 2)
    env.module.stop(env.spec.scope)
    env:complete_next("plan", 1)
  end)

  t.it("residual mode keys follow the actual host environment alias contract", function()
    local environment_key = require("utils.platform").driver().environment_key
    local aliases = environment_key("NVIM_UE_BATCH_TIER") == environment_key("nvim_ue_batch_tier")
    for _, value in ipairs({ "strict", "1" }) do
      local child_env = { NVIM_UE_BATCH_TIER = "strict", nvim_ue_batch_tier = value, PATH = "unchanged" }
      local before = vim.deepcopy(child_env)
      local env = fixture(0, { residual_strict_limit = 1, env = child_env })
      t.assert_true(vim.deep_equal(child_env, before), "validation must not rewrite caller environment")
      if aliases then
        t.assert_eq(env.record, nil)
        t.assert_eq(env.reason, "invalid-residual-strict-mode")
        t.assert_eq(#env.acquired, 0)
        t.assert_eq(#env.jobs, 0)
      else
        t.assert_true(env.record ~= nil, "case-distinct POSIX keys are not aliases")
        t.assert_eq(env:count("plan"), 1)
        env.module.stop(env.spec.scope)
        env:complete_next("plan", 1)
      end
    end
  end)

  t.it("residual plan mode and exact limit must match before workers start", function()
    for _, plan in ipairs({ { schema = 1, mode = "1", residual_strict_limit = 1, groups = { { id = "x" } } },
      { schema = 1, mode = "strict", groups = { { id = "x" } } },
      { schema = 1, mode = "strict", residual_strict_limit = 2, groups = { { id = "x" } } } }) do
      local env = fixture(1, { residual_strict_limit = 1, plan = plan })
      env:complete_next("plan")
      t.assert_eq(env:count("worker"), 0)
      t.assert_eq(env.record.reason, "residual-strict-plan-mismatch")
      t.assert_eq(#env.released, 1)
    end
    local env = fixture(1, { plan = { schema = 1, mode = "strict", residual_strict_limit = 1,
      groups = { { id = "x" } } } })
    env:complete_next("plan")
    t.assert_eq(env:count("worker"), 0, "an ordinary request cannot consume a residual plan")
    t.assert_eq(env.record.reason, "residual-strict-plan-mismatch")
  end)

  t.it("active mode or limit switches involving residual refuse without stopping the owner", function()
    for _, limits in ipairs({ { false, 1 }, { 1, false }, { 1, 2 } }) do
      local env = fixture(1, { residual_strict_limit = limits[1] or nil })
      local changed = vim.deepcopy(env.spec)
      changed.residual_strict_limit = limits[2] or nil
      changed.env = { NVIM_UE_BATCH_TIER = limits[2] and "strict" or "1" }
      local value, reason = env.module.start(changed, env.opts)
      t.assert_eq(value, nil)
      t.assert_eq(reason, "proof-queue-active")
      t.assert_eq(env.cancellations, 0)
      t.assert_eq(#env.acquired, 1)
      t.assert_eq(env.module.status(env.spec.scope), env.record)
      env.module.stop(env.spec.scope)
      env:complete_next("plan", 1)
    end
  end)

  t.it("a residual collect retry timer also owns the queue with no running child", function()
    local env = fixture(1, { residual_strict_limit = 1 })
    env:complete_next("plan"); env:complete_next("worker")
    env.bad_collect = true
    env:complete_next("collect")
    t.assert_eq(env.record.running, 0)
    t.assert_true(env.record.timer ~= nil)
    local changed = vim.deepcopy(env.spec)
    changed.residual_strict_limit = nil
    changed.env = { NVIM_UE_BATCH_TIER = "1" }
    local value, reason = env.module.start(changed, env.opts)
    t.assert_eq(value, nil)
    t.assert_eq(reason, "proof-queue-active")
    t.assert_eq(#env.acquired, 2, "only existing store and collect leases were acquired")
    t.assert_false(env.record.stopped == true)
    env.module.stop(env.spec.scope)
  end)

  t.it("host-deferred residual work rejects mode changes without cancelling its pending admission", function()
    local admission = require("utils.host_admission")
    admission._reset_for_test()
    local token = admission.foreground_begin("fixture foreground")
    local env = fixture(1, { residual_strict_limit = 1, shared_admission = true })
    local ok, err = xpcall(function()
      t.assert_eq(#env.jobs, 0)
      t.assert_eq(env.record.deferred_reason, "foreground-work-active")
      local changed = vim.deepcopy(env.spec)
      changed.residual_strict_limit = nil
      changed.env = { NVIM_UE_BATCH_TIER = "1" }
      local value, reason = env.module.start(changed, env.opts)
      t.assert_eq(value, nil)
      t.assert_eq(reason, "proof-queue-active")
      t.assert_false(env.record.stopped == true)
      t.assert_eq(#env.released, 0)
      admission.foreground_done(token)
      t.assert_eq(env:count("plan"), 1)
    end, debug.traceback)
    env.module.stop(env.spec.scope)
    for index, job in ipairs(env.jobs) do if not job.done then env:complete(index, 1) end end
    admission._reset_for_test()
    if not ok then error(err) end
  end)

  t.it("residual requests honor the existing cross-process store lease", function()
    local env = fixture(1, { residual_strict_limit = 1, lock_busy = true })
    t.assert_eq(env.record, nil)
    t.assert_eq(env.reason, "fixture-store-busy")
    assert_list(env.acquired, { "proofs.background.lock" })
    t.assert_eq(#env.jobs, 0)
    t.assert_eq(#env.released, 0)
  end)

  t.it("large-first policy is explicit and delivered parent suppresses untouched children", function()
    local env = fixture(0, { groups = family(), auto_tier1_large = true, validated = { "large" } })
    t.assert_true(vim.tbl_contains(env.jobs[1].command, "--auto-tier1-large"))
    env:complete_next("plan")
    assert_list(worker_ids(env), { "large" })
    env:complete_next("worker")
    t.assert_eq(env:count("collect"), 1, "successful parent collects immediately before 120 seconds")
    t.assert_eq(env.record.scheduling.states["small-1"], "deferred", "worker ok alone grants no suppression")
    env:complete_next("collect")
    assert_list(worker_ids(env), { "large" })
    t.assert_eq(env.record.phase, "finished")
    assert_list(env.summary.large_first.suppressed_ids, { "small-1", "small-2" })
    t.assert_eq(env.summary.proof_accepted, 1, "suppressed small groups are not accepted proofs")
    t.assert_eq(env.summary.large_first.attempts.large.proof_outcome, "accepted")
    t.assert_eq(env.summary.large_first.attempts.large.collect_outcome, "admitted")
    local ordinary = fixture(1)
    t.assert_false(vim.tbl_contains(ordinary.jobs[1].command, "--auto-tier1-large"))
    ordinary.module.stop(ordinary.spec.scope); ordinary:complete_next("plan", 1)
  end)

  t.it("changing auto-large policy does not reuse an already running queue", function()
    local env = fixture(1, { auto_tier1_large = true })
    local changed = vim.deepcopy(env.spec)
    changed.auto_tier1_large = false
    local value, reason = env.module.start(changed, env.opts)
    t.assert_eq(value, nil)
    t.assert_eq(reason, "previous-proof-exiting")
    env:complete_next("plan", 1)
    env.record = env.module.start(changed, env.opts)
    t.assert_false(vim.tbl_contains(env.jobs[#env.jobs].command, "--auto-tier1-large"))
    env:complete_next("plan"); env:complete_next("worker"); env:complete_next("collect")
    t.assert_eq(env.record.phase, "finished")
  end)

  t.it("cache hit and warm parent without children still force delivered collect", function()
    local env = fixture(0, { groups = { { id = "large", schedule_role = "large-first" }, { id = "other" } },
      max_workers = 1, validated = { "large" }, worker_results = {
        large = { ok = true, metrics = { batch_count = 1, new_batch_count = 0, new_proof_count = 0 } } } })
    env:complete_next("plan"); env:complete_next("worker")
    t.assert_eq(env:count("worker"), 1)
    t.assert_eq(env:count("collect"), 1)
    env:complete_next("collect")
    assert_list(worker_ids(env), { "large", "other" })
    env:complete_next("worker"); env:complete_next("collect")
    t.assert_eq(env.record.phase, "finished")
  end)

  t.it("two workers drain disjoint work before parent publication and never start dependent children", function()
    local groups = family()
    groups[#groups + 1] = { id = "large-2", schedule_role = "large-first" }
    groups[#groups + 1] = { id = "small-3", fallback_of = "large-2" }
    local env = fixture(0, { groups = groups, validated = { "large", "large-2" } })
    env:complete_next("plan")
    assert_list(worker_ids(env), { "large", "large-2" })
    env:complete_next("worker")
    t.assert_eq(env:count("collect"), 0)
    t.assert_eq(#worker_ids(env), 2)
    t.assert_eq(#env.acquired, 1, "publication lease waits for both parent workers to drain")
    env:complete_next("worker")
    t.assert_eq(env:count("collect"), 1)
    t.assert_eq(#env.acquired, 2)
    env:complete_next("collect")
    t.assert_eq(#worker_ids(env), 2)
    assert_list(env.summary.large_first.suppressed_ids, { "small-1", "small-2", "small-3" })
  end)

  t.it("rejected timeout and invalid worker results each release original children exactly once", function()
    for _, failure in ipairs({ "rejected", "timeout", "invalid" }) do
      local value = failure == "invalid" and { ok = false } or
        { ok = true, metrics = { batch_count = 0, new_batch_count = 0, new_proof_count = 1 } }
      local env = fixture(0, { groups = family(), worker_results = { large = value }, validated = {} })
      env:complete_next("plan")
      local parent_job = env:complete_next("worker", failure == "timeout" and 1 or 0)
      assert_list(worker_ids(env), { "large", "small-1", "small-2" })
      env:complete(parent_job, 1)
      t.assert_eq(env:count("worker"), 3, "duplicate parent callback cannot release twice")
      env:complete_next("worker"); env:complete_next("worker"); env:complete_next("collect")
      t.assert_eq(env.record.phase, "finished")
      t.assert_eq(env.summary.large_first.released_fallback_count, 2)
      t.assert_eq(env.summary.large_first.attempts.large.outcome, failure == "rejected" and "rejected" or "failed")
    end
  end)

  t.it("accepted proof not adopted by collector releases children without repeating the parent", function()
    local env = fixture(0, { groups = family(), validated = {} })
    env:complete_next("plan"); env:complete_next("worker"); env:complete_next("collect")
    assert_list(worker_ids(env), { "large", "small-1", "small-2" })
    env:complete_next("worker"); env:complete_next("worker"); env:complete_next("collect")
    t.assert_eq(env.record.phase, "finished")
    assert_list(env.summary.large_first.suppressed_ids, {})
    t.assert_eq(env.summary.large_first.attempts.large.collect_outcome, "not-selected")
  end)

  t.it("collection and activation failures keep fallback unresolved until a delivered retry", function()
    for _, failure in ipairs({ "bad_collect", "publish_error" }) do
      local env = fixture(0, { groups = family(), validated = { "large" } })
      env:complete_next("plan"); env:complete_next("worker")
      env[failure] = true
      env:complete_next("collect")
      t.assert_eq(env.record.published_count, 0)
      t.assert_eq(env.record.scheduling.states["small-1"], "deferred")
      t.assert_eq(env:count("worker"), 1)
      env[failure] = false
      env.timers[#env.timers].callback()
      env:complete_next("collect")
      t.assert_eq(env.record.phase, "finished")
      assert_list(worker_ids(env), { "large" })
    end
  end)

  t.it("later delivered collect can invalidate a parent and release preserved suppressed children", function()
    local env = fixture(0, { groups = family(2), validated = { "large", "other-1" } })
    env:complete_next("plan")
    assert_list(worker_ids(env), { "large", "other-1" })
    env:complete_next("worker"); env:complete_next("worker"); env:complete_next("collect")
    t.assert_eq(env.record.scheduling.states["small-1"], "suppressed")
    assert_list(worker_ids(env), { "large", "other-1", "other-2" })
    env.validated = { "other-1", "other-2" }
    env:complete_next("worker"); env:complete_next("collect")
    assert_list(worker_ids(env), { "large", "other-1", "other-2", "small-1", "small-2" })
    env:complete_next("worker"); env:complete_next("worker"); env:complete_next("collect")
    t.assert_eq(env.record.phase, "finished")
    t.assert_eq(env.summary.large_first.released_fallback_count, 2)
    t.assert_eq(env.summary.large_first.attempts.large.collect_outcome, "invalidated")
  end)

  t.it("generation changes during collect cannot acknowledge a parent or lose its fallback definitions", function()
    local env = fixture(0, { groups = family(), validated = { "large" } })
    env:complete_next("plan"); env:complete_next("worker")
    env.valid = false
    env:complete_next("collect")
    t.assert_eq(env.published, 0)
    t.assert_eq(env.record.scheduling.states["small-1"], "deferred")
    env.timers[#env.timers].callback()
    t.assert_eq(env.record.phase, "finished")
    t.assert_eq(env:count("worker"), 1)
    assert_list(env.summary.large_first.suppressed_ids, {})
  end)

  t.it("a later collector-restored child receipt does not get a redundant worker", function()
    local env = fixture(0, { groups = family(1), validated = { "large" }, recovered = {
      { id = "large", accepted_hint = 1 }, { id = "small-1", accepted_hint = 1 } } })
    env:complete_next("plan"); env:complete_next("collect")
    assert_list(worker_ids(env), { "other-1" })
    t.assert_eq(env.record.recovered["small-1"], nil)
    t.assert_eq(env.record.scheduling.states["small-1"], "suppressed")
    env.validated = { "small-1", "other-1" }
    env:complete_next("worker"); env:complete_next("collect")
    assert_list(worker_ids(env), { "other-1", "small-2" }, "only fresh delivered child ack skips qualification")
    t.assert_eq(env.record.scheduling.states["small-1"], "completed")
    env:complete_next("worker"); env:complete_next("collect")
    t.assert_eq(env.record.phase, "finished")
    t.assert_eq(env.summary.large_first.released_fallback_count, 1)
  end)

  t.it("recovery collects parent hints first and stale parents release small fallback", function()
    for _, valid in ipairs({ true, false }) do
      local env = fixture(0, { groups = family(), recovered = { { id = "large", accepted_hint = 1 } },
        validated = valid and { "large" } or {} })
      env:complete_next("plan")
      t.assert_eq(env:count("worker"), 0)
      t.assert_eq(env:count("collect"), 1)
      env:complete_next("collect")
      if valid then
        t.assert_eq(env:count("worker"), 0)
      else
        assert_list(worker_ids(env), { "small-1", "small-2" })
        env:complete_next("worker"); env:complete_next("worker"); env:complete_next("collect")
      end
      t.assert_eq(env.record.phase, "finished")
    end
  end)

  t.it("cancellation keeps fallback definitions and a new generation can retry them", function()
    local env = fixture(0, { groups = family(), validated = {} })
    env:complete_next("plan")
    env.module.stop(env.spec.scope)
    t.assert_eq(env.record.scheduling.states["small-1"], "deferred")
    env:complete_next("worker", 1)
    t.assert_eq(env.summary.large_first.attempts.large.outcome, "cancelled")
    t.assert_eq(env:count("worker"), 1)
    env.record = env.module.start(env.spec, env.opts)
    env:complete_next("plan"); env:complete_next("worker", 1)
    assert_list(worker_ids(env), { "large", "large", "small-1", "small-2" })
    env:complete_next("worker"); env:complete_next("worker"); env:complete_next("collect")
    t.assert_eq(env.record.phase, "finished")
  end)

  t.it("linked synchronous callbacks neither launch skipped children nor double release leases", function()
    local env = fixture(0, { groups = family(3), validated = { "large" }, synchronous = true })
    assert_list(worker_ids(env), { "large", "other-1", "other-2", "other-3" })
    t.assert_eq(env:count("collect"), 2)
    t.assert_eq(env.record.running, 0)
    t.assert_eq(env.record.phase, "finished")
    local releases = 0
    for _, path in ipairs(env.released) do if path == "proofs.background.lock" then releases = releases + 1 end end
    t.assert_eq(releases, 1)
  end)

  t.it("malformed scheduling metadata fails closed before any worker", function()
    local cases = {
      { { id = "a", fallback_of = "missing" } },
      { { id = "a", schedule_role = "large-first", fallback_of = "a" } },
      { { id = "a", schedule_role = "unknown" } },
      { { id = "a", schedule_role = "large-first" }, { id = "a", fallback_of = "a" } },
      { { id = "a", schedule_role = "large-first" }, { id = "b", schedule_role = "large-first" },
        { id = "c", schedule_role = "large-first" } },
    }
    for _, groups in ipairs(cases) do
      local env = fixture(0, { groups = groups })
      env:complete_next("plan")
      t.assert_eq(env:count("worker"), 0)
      t.assert_eq(env.record.phase, "finished")
      t.assert_true(env.record.reason:find("invalid-proof-scheduling", 1, true) ~= nil)
    end
  end)

  t.it("restart collects hints under both leases and keeps only revalidated groups", function()
    local env = fixture(2, { recovered = { { id = "group-1", accepted_hint = 1 } }, validated = { "group-1" }, plan_candidate_count = 1 })
    env:complete(1)
    t.assert_eq(env:count("worker"), 0)
    t.assert_eq(env:count("collect"), 1)
    t.assert_eq(env.module.summary(env.spec.scope).pending_accepted_count, 1)
    t.assert_eq(env.module.summary(env.spec.scope).planned_candidates, 1, "recovery hints are not new work candidates")
    t.assert_eq(#env.acquired, 2)
    env:complete(2)
    t.assert_eq(env:count("worker"), 1)
    t.assert_eq(env.module.summary(env.spec.scope).pending_accepted_count, 0)
    t.assert_eq(env.module.summary(env.spec.scope).last_collect_success.outcome, "published")
    t.assert_eq(env.argument(env.jobs[3].command, "--group"), "group-2")
    env:complete(3); env:complete(4)
    t.assert_eq(env.record.phase, "finished")
  end)

  t.it("stale historical ok must be reproved instead of bypassing admission", function()
    local env = fixture(1, { recovered = { { id = "group-1", accepted_hint = 1 } }, validated = {} })
    env:complete(1); env:complete(2)
    t.assert_eq(env:count("worker"), 1)
    t.assert_eq(env.argument(env.jobs[3].command, "--group"), "group-1")
    env:complete(3); env:complete(4)
    t.assert_eq(env.record.phase, "finished")
  end)
  t.it("observes plan, cached proofs, new proofs and collected batches independently", function()
    local env = fixture(1)
    env:complete(1)
    local summary = env.module.summary(env.spec.scope)
    t.assert_eq(summary.planned_candidates, 1); t.assert_eq(summary.cached_accepted, 3)
    t.assert_eq(summary.cached_rejected, 2); t.assert_eq(summary.cached_uncached, 8)
    t.assert_eq(summary.proof_accepted, 0); t.assert_eq(summary.collect_accepted, 0)
    summary.planned_candidates = 99
    t.assert_eq(env.module.summary(env.spec.scope).planned_candidates, 1)
    env:complete(2); env:complete(3)
    summary = env.module.summary(env.spec.scope)
    t.assert_eq(summary.proof_accepted, 1); t.assert_eq(summary.proof_rejected, 0)
    t.assert_eq(summary.collect_accepted, 4)
    t.assert_eq(summary.selector_reuse, "accepted")
  end)

  t.it("最多两个worker，重复start复用队列", function()
    local env = fixture(5)
    t.assert_eq(env:count("worker"), 0)
    env:complete(1)
    t.assert_eq(env:count("worker"), 2)
    t.assert_eq(env.record.running, 2)
    t.assert_eq(env.module.start(env.spec, env.opts), env.record)
    t.assert_eq(env:count("worker"), 2)
    env.module.stop(env.spec.scope)
    t.assert_eq(#env.released, 0, "停止请求不能提前释放仍有worker的lease")
    env:complete(2, 1)
    t.assert_eq(#env.released, 0)
    env:complete(3, 1)
    t.assert_eq(#env.released, 1)
    env:complete(3, 1)
    t.assert_eq(#env.released, 1, "重复回调不能重复release")
  end)

  t.it("120秒攒批，到期先drain全部worker再collect", function()
    local env = fixture(5)
    env:complete(1)
    env.time = 60000
    env:complete(2)
    t.assert_eq(env:count("worker"), 3)
    t.assert_eq(env:count("collect"), 0)
    env.time = 120000
    env:complete(3)
    t.assert_eq(env:count("worker"), 3, "到期不能继续补worker导致发布饥饿")
    t.assert_eq(env:count("collect"), 0, "仍有worker时不能collect")
    env:complete(4)
    t.assert_eq(env:count("collect"), 1)
    t.assert_eq(env.record.running, 1)
    env:complete(5)
    t.assert_eq(env.published, 1)
    t.assert_eq(env:count("worker"), 5)
    env:complete(6)
    env:complete(7)
    t.assert_eq(env:count("collect"), 2, "队列结束可立即发布尾批")
    env:complete(8)
    t.assert_eq(env.record.phase, "finished")
    t.assert_eq(env.record.accepted, 5)
  end)

  t.it("共享foreground token阻止新任务且释放后恢复", function()
    local admission = require("utils.host_admission")
    admission._reset_for_test()
    local token = admission.foreground_begin("fixture foreground")
    local env = fixture(2, { shared_admission = true })
    t.assert_eq(#env.jobs, 0)
    t.assert_eq(env.record.deferred_reason, "foreground-work-active")
    admission.foreground_done(token)
    t.assert_eq(#env.jobs, 1)
    env:complete(1)
    t.assert_eq(env:count("worker"), 2)
    env.module.stop(env.spec.scope)
    env:complete(2, 1)
    env:complete(3, 1)
    admission._reset_for_test()
  end)

  t.it("input失效撤销旧callback且取消剩余owned任务", function()
    local env = fixture(4)
    env:complete(1)
    env.valid = false
    env:complete(2)
    t.assert_eq(env:count("collect"), 0)
    t.assert_true(env.cancellations >= 1, "失效后必须取消尚未完成或尚在准入队列中的任务")
    t.assert_eq(#env.released, 0)
    env:complete(3, 1)
    t.assert_eq(#env.released, 1)
    t.assert_eq(env.published, 0)
  end)

  t.it("collection失败不能标记已发布，保留重试", function()
    local env = fixture(2)
    env:complete(1)
    env:complete(2)
    env:complete(3)
    env.bad_collect = true
    env:complete(4)
    t.assert_eq(env.record.published_count, 0)
    t.assert_eq(env.published, 0)
    t.assert_true(#env.timers > 0, "收集失败应有有界重试")
  end)

  t.it("激活异常不能标记已发布，保留重试", function()
    local env = fixture(2)
    env:complete(1)
    env:complete(2)
    env:complete(3)
    env.publish_error = true
    env:complete(4)
    t.assert_eq(env.record.published_count, 0)
    t.assert_eq(env.published, 0)
    t.assert_true(#env.timers > 0)
  end)

  t.it("尚在前台准入队列中的取消只释放一次lease", function()
    local admission = require("utils.host_admission")
    admission._reset_for_test()
    local token = admission.foreground_begin("fixture pending foreground")
    local env = fixture(2, { shared_admission = true })
    t.assert_eq(#env.jobs, 0)
    env.module.stop(env.spec.scope)
    t.assert_eq(#env.released, 1)
    admission.foreground_done(token)
    t.assert_eq(#env.jobs, 0)
    t.assert_eq(#env.released, 1)
    admission._reset_for_test()
  end)

  t.it("同signature已完成队列允许再次启动", function()
    local env = fixture(1)
    env:complete(1)
    env:complete(2)
    env:complete(3)
    local previous = env.record
    t.assert_eq(previous.phase, "finished")
    local restarted = env.module.start(env.spec, env.opts)
    t.assert_true(restarted ~= previous)
    t.assert_eq(restarted.phase, "planning")
    t.assert_eq(env:count("plan"), 2)
    env:complete(4)
    env:complete(5)
    env:complete(6)
    t.assert_eq(restarted.phase, "finished")
    t.assert_eq(env:count("worker"), 2)
  end)

  t.it("collector等待foreground时尚未取得publication lease", function()
    local admission = require("utils.host_admission")
    admission._reset_for_test()
    local env = fixture(2, { shared_admission = true })
    env:complete(1)
    local token = admission.foreground_begin("fixture foreground before collect")
    env:complete(2)
    env:complete(3)
    t.assert_eq(env:count("collect"), 0)
    t.assert_eq(env.record.phase, "collecting")
    t.assert_eq(#env.acquired, 1, "等待前台不能占用phase writer lease")
    t.assert_eq(env.record.publish_lease, nil)
    admission.foreground_done(token)
    t.assert_eq(env:count("collect"), 1)
    t.assert_eq(#env.acquired, 2)
    t.assert_eq(env.acquired[2], "publication.lock")
    env:complete(4)
    t.assert_eq(env.record.phase, "finished")
    admission._reset_for_test()
  end)

  t.it("同步fixture回调不重复放行或释放锁", function()
    local env = fixture(304, { synchronous = true })
    t.assert_eq(env:count("worker"), 304)
    t.assert_eq(env:count("collect"), 1)
    t.assert_eq(env.record.running, 0)
    t.assert_eq(env.record.phase, "finished")
    local releases = 0
    for _, path in ipairs(env.released) do if path == "proofs.background.lock" then releases = releases + 1 end end
    t.assert_eq(releases, 1)
  end)
end)
