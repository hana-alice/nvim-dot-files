local t = require("tests.harness")
t.bootstrap()

local function fixture(count, settings)
  settings = settings or {}
  local module = dofile(vim.fn.getcwd() .. "/lua/ue/index/batch_background.lua")
  local env = { jobs = {}, timers = {}, released = {}, acquired = {}, published = 0, time = 0, valid = true, cancellations = 0 }
  local groups = {}
  for index = 1, count do groups[index] = { id = "group-" .. index } end
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
    if settings.synchronous then callback({ code = 0 }) end
    return function() env.cancellations = env.cancellations + 1 end
  end
  local opts = {
    now = function() return env.time end,
    current = function() return env.valid end,
    schedule = function(callback) callback() end,
    timer_factory = timer,
    acquire = function(path) env.acquired[#env.acquired + 1] = path; return { path = path } end,
    release = function(lease) env.released[#env.released + 1] = lease.path end,
    run = run,
    read_json = function(path)
      if path == "plan.json" then return { schema = 1, groups = groups } end
      if path == "collect.json" then return { ok = not env.bad_collect, changed = true } end
      return { ok = true, metrics = { new_batch_count = 1, new_proof_count = 1 } }
    end,
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
    plan = "plan.json", python = "python", script = "tool.py", clangd = "clangd", control_dir = "control",
    publish_lock = "publication.lock", background = "background.json", marker = "marker.json", collect_result = "collect.json",
    publish = function()
      if env.publish_error then error("fixture-publication-rejected") end
      env.published = env.published + 1
    end }
  env.module, env.spec, env.opts = module, spec, opts
  env.record = module.start(spec, opts)
  function env:complete(index, code)
    self.jobs[index].callback({ code = code or 0, stderr = code and "cancelled" or nil })
  end
  function env:count(action)
    local total = 0
    for _, job in ipairs(self.jobs) do if job.action == action then total = total + 1 end end
    return total
  end
  return env
end

t.describe("连续后台二次证明队列", function()
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
