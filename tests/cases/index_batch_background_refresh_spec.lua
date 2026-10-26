local t = require("tests.harness")
t.bootstrap()

local function fixture(run)
  local queue = require("ue.index.batch_background")
  local original_start, original_schedule = queue.start, vim.schedule
  local root = vim.fs.normalize(vim.fn.tempname())
  vim.fn.mkdir(root, "p")
  vim.fn.writefile({ "[]" }, root .. "/full.json.semantic.json")
  local ctx = { engine_root = root, project_root = root, paths = {
    active_cdb = root .. "/active.json", semantic_cdb = root .. "/compile_commands.json",
    index_state = root .. "/state.json",
  } }
  local state = { queue = {}, index_artifacts = { full = { generation_id = "g", coverage_level = "full" } },
    index_selection = { generation_id = "g", coverage_level = "full", artifact_fingerprint = "full" } }
  local rt = { timers = {}, contexts = { [root] = ctx }, module_state = { [root] = state } }
  local f = { ctx = ctx, state = state, rt = rt, started = {}, restarts = {}, scheduled = {}, generation = "g",
    probes = {} }
  local core = { RT = rt, h = {
    unix_now = function() return 100 end,
    file_signature = function() return "base-v1" end,
    ensure_index_state = function() return state end,
    normalize_index_state = function() end,
    save_index_state = function() f.saved = (f.saved or 0) + 1 end,
    generation_for_context = function() return { generation_id = f.generation } end,
  }, deps = {
    status_root_key = function() return root end,
    invalidate_status_cache = function() end, refresh_statusline = function() end,
    probe = function(topic, key, data) f.probes[key] = data; t.assert_eq(topic, "index-priority-refresh") end,
  } }
  local M = {}
  require("ue.index._build")(M, core)
  require("ue.index._schedule")(M, core)
  M.base_compile_commands_path = function() return ctx.paths.active_cdb end
  M.maybe_restart_clangd_for_index = function(opts) f.restarts[#f.restarts + 1] = opts end
  M.admission_opts = function() return { enabled = false } end
  M.admit_background_phase = function() return f.allow ~= false, "host-cpu-busy" end
  M.build_phase_async = function(context, phase)
    t.assert_nil(rt.job, "后台刷新必须复用唯一 job")
    M.consume_index_phase(context, phase, state)
    f.started[#f.started + 1] = phase
    rt.job = { phase = phase }
    return true
  end
  queue.start = function(spec) f.spec = spec; return true end
  vim.schedule = function(callback) f.scheduled[#f.scheduled + 1] = callback end
  function f.flush()
    local callbacks = f.scheduled
    f.scheduled = {}
    for _, callback in ipairs(callbacks) do callback() end
  end
  function f.publish(publication)
    f.spec.publish({ activation = { ok = true, generation_id = "g",
      manifest = { generation_id = "g", coverage_level = "full", artifact_fingerprint = "new-full" },
      index_selection = { generation_id = "g", coverage_level = "full", artifact_fingerprint = "new-full" },
      publication = publication or { changed = true, original_changed = true },
    } })
  end
  function f.old_timer(phase)
    local timer = { stop = function(self) self.stopped = true end, close = function(self) self.closed = true end }
    rt.timers[root .. "::" .. phase] = timer
    return timer
  end
  f.m = M
  local ok, err = xpcall(function()
    require("ue.index._batch_background")(M, core)
    M.start_background_batches(ctx, { enabled = true, store = root .. "/verified_batches",
      background = root .. "/full.json", marker = root .. "/full.marker", python = "fixture", clangd = "fixture" })
    t.assert_true(f.spec ~= nil)
    run(f)
  end, debug.traceback)
  queue.start, vim.schedule = original_start, original_schedule
  for _, timer in pairs(rt.timers) do timer:stop(); timer:close() end
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("background publication refreshes priority phases", function()
  t.it("变化激活后异步按 current→hot 排队，保留 full 且不另建 full", function()
    fixture(function(f)
      local current, hot = f.old_timer("current"), f.old_timer("hot")
      f.state.queue.full = 50
      f.publish()
      t.assert_eq(#f.started, 0, "发布回调仍持 writer lease，不得立即构建")
      t.assert_true(current.closed and hot.closed, "旧 timer 不能抢先或重复启动")
      t.assert_eq(f.state.queue.current, 100)
      t.assert_eq(f.state.queue.hot, 100)
      t.assert_eq(f.state.queue.full, 50)
      t.assert_eq(f.state.index_selection.coverage_level, "full")
      t.assert_eq(f.state.index_artifacts.full.artifact_fingerprint, "new-full")
      f.flush()
      t.assert_eq(table.concat(f.started, ","), "current")
      f.rt.job = nil
      f.m.try_start_queued_build()
      t.assert_eq(table.concat(f.started, ","), "current,hot")
      t.assert_eq(#f.restarts, 1, "两个刷新阶段不得直接强制重启 reader")
    end)
  end)

  t.it("当前 job 完成前只合并队列，重复无变化激活不再重建或重启", function()
    fixture(function(f)
      local running = { phase = "full" }
      f.rt.job = running
      f.publish()
      f.flush()
      t.assert_eq(f.rt.job, running)
      t.assert_eq(#f.started, 0)
      f.publish({ changed = false, original_changed = false })
      t.assert_eq(#f.scheduled, 0)
      t.assert_eq(#f.restarts, 1)
      f.rt.job = nil
      f.m.try_start_queued_build()
      t.assert_eq(f.started[1], "current")
    end)
  end)

  t.it("current 被宿主准入推迟时 hot 不得抢先，放行后仍严格串行", function()
    fixture(function(f)
      f.allow = false
      local hot = f.old_timer("hot")
      f.publish()
      f.flush()
      t.assert_true(hot.closed)
      t.assert_eq(#f.started, 0)
      t.assert_eq(f.state.queue.current, 100)
      t.assert_eq(f.state.queue.hot, 100)
      f.allow = true
      f.m.try_start_queued_build()
      t.assert_eq(f.started[1], "current")
      f.rt.job = nil
      f.m.try_start_queued_build()
      t.assert_eq(f.started[2], "hot")
    end)
  end)

  t.it("无变化激活不增队列且不取消已有交付 timer", function()
    fixture(function(f)
      local timer = f.old_timer("hot")
      f.publish({ changed = false, original_changed = false })
      f.flush()
      t.assert_eq(#f.started, 0)
      t.assert_nil(next(f.state.queue))
      t.assert_nil(timer.closed)
      t.assert_eq(#f.restarts, 0)
    end)
  end)

  t.it("激活失败或 generation 变化不新增刷新", function()
    fixture(function(f)
      local ok = pcall(f.spec.publish, { activation = { ok = false } })
      t.assert_false(ok)
      f.generation = "g2"
      ok = pcall(f.publish)
      t.assert_false(ok)
      f.flush()
      t.assert_nil(next(f.state.queue))
      t.assert_eq(#f.started, 0)
      t.assert_eq(#f.restarts, 0)
    end)
  end)

  t.it("只有冻结元数据变化时不重建 current/hot", function()
    fixture(function(f)
      local timer = f.old_timer("hot")
      f.publish({ changed = true, original_changed = false })
      f.flush()
      t.assert_eq(#f.started, 0)
      t.assert_nil(next(f.state.queue))
      t.assert_nil(timer.closed)
    end)
  end)

  t.it("异步 drain 前 generation 再变化时不立即启动，保留普通待处理队列", function()
    fixture(function(f)
      f.publish()
      f.generation = "g2"
      f.flush()
      t.assert_eq(#f.started, 0)
      t.assert_eq(f.state.queue.current, 100)
      t.assert_eq(f.state.queue.hot, 100)
    end)
  end)
  t.it("探针：排队成功记 ok，推迟/激活失败/generation 变化记失败原因", function()
    fixture(function(f)
      f.publish()
      f.flush()
      t.assert_eq(f.probes["queued:current-hot"].state, "ok")
    end)
    fixture(function(f)
      f.allow = false
      f.publish()
      f.flush()
      t.assert_eq(f.probes["deferred:queue-not-started"].state, "failed")
    end)
    fixture(function(f)
      pcall(f.spec.publish, { activation = { ok = false, error = "boom" } })
      t.assert_eq(f.probes["failed:activation"].error, "boom")
      f.publish({ changed = false, original_changed = false })
      t.assert_eq(f.probes["noop:publication-unchanged"].state, "ok")
      f.publish()
      f.generation = "g2"
      f.flush()
      t.assert_eq(f.probes["skipped:generation-changed-before-drain"].state, "failed")
    end)
  end)
end)
