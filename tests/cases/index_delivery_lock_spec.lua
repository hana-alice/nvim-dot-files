local t = require("tests.harness")
t.bootstrap()

local function fixture(callback)
  local lock = require("ue.file_lock")
  local platform = require("utils.platform")
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_delivery_lock"
  vim.fn.mkdir(root, "p")
  local function write(path, value)
    local file = assert(io.open(path, "wb")); file:write(value); file:close(); return true
  end
  local ctx = { engine_root = root, project_root = root, paths = {
    active_cdb = root .. "/active.json", index_state = root .. "/state.json",
    semantic_cdb = root .. "/compile_commands.json", semantic_full_cdb = root .. "/full.json",
    index_full_cdb = root .. "/full-input.json",
  } }
  write(ctx.paths.active_cdb, "[]")
  local state = { queue = {}, modules = {}, build = {} }
  local rt = { timers = {}, module_state = { fixture = state }, contexts = { fixture = ctx } }
  local f = { ctx = ctx, state = state, rt = rt, starts = {}, timers = {}, allow = true, admissions = 0 }
  local saved = { timer = vim.uv.new_timer, wrap = vim.schedule_wrap, system = vim.system,
    resolve = platform.resolve_tool, acquire = lock.acquire }
  local modules = {}
  for _, name in ipairs({ "ue", "ue.index.batch_runtime", "fidget.progress" }) do modules[name] = package.loaded[name] end
  package.loaded.ue = { clangd_cmd = function() return { "clangd" } end }
  package.loaded["ue.index.batch_runtime"] = {
    server_profile = function() return {} end, process_environment = function() return {} end,
  }
  package.loaded["fidget.progress"] = { handle = { create = function() return { finish = function() end } end } }
  vim.uv.new_timer = function()
    local timer = {}
    function timer:start(delay, repeat_ms, run)
      t.assert_eq(repeat_ms, 0); self.delay, self.run = delay, run
    end
    function timer:stop() self.stopped = true end
    function timer:close() self.closed = true end
    f.timers[#f.timers + 1] = timer
    return timer
  end
  vim.schedule_wrap = function(run) return run end
  vim.system = function(command)
    f.starts[#f.starts + 1] = command
    return {}
  end
  local core = { RT = rt, h = {
    unix_now = os.time, ensure_index_state = function() return state end,
    save_index_state = function() write(ctx.paths.index_state, vim.json.encode(state)) end,
    write_json_file = function(path, value) return write(path, vim.json.encode(value)) end,
  }, deps = { status_root_key = function() return "fixture" end,
    invalidate_status_cache = function() end, refresh_statusline = function() end } }
  local index = {}
  require("ue.index._build")(index, core)
  require("ue.index._schedule")(index, core)
  index.select_phase_module_keys = function() return {} end
  index.index_phase_paths = function() return root .. "/input.json", root .. "/full.idx" end
  index.admission_opts = function() return { enabled = false } end
  index.admit_background_phase = function()
    f.admissions = f.admissions + 1
    return f.allow, f.allow and "allowed" or "host-cpu-busy"
  end
  f.index, f.lock = index, lock
  function f.hold() f.lease = assert(lock.acquire(ctx.paths.index_state .. ".build.lock")) end
  function f.release() t.assert_true(lock.release(f.lease)); f.lease = nil end
  function f.fire()
    local timer = assert(rt.timers["fixture::full"], "phase retry timer missing")
    t.assert_false(timer.closed)
    timer.run()
    return timer
  end
  function f.persisted()
    return vim.json.decode(table.concat(vim.fn.readfile(ctx.paths.index_state), "\n"))
  end
  local ok, err = pcall(callback, f)
  vim.uv.new_timer, vim.schedule_wrap, vim.system = saved.timer, saved.wrap, saved.system
  platform.resolve_tool, lock.acquire = saved.resolve, saved.acquire
  for _, name in ipairs({ "ue", "ue.index.batch_runtime", "fidget.progress" }) do package.loaded[name] = modules[name] end
  local owner = lock.owner(ctx.paths.index_state .. ".build.lock")
  if owner then lock.release({ path = ctx.paths.index_state .. ".build.lock", token = owner.token }) end
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("index delivery survives temporary writer ownership", function()
  t.it("protected full deadlines retry the live writer without dropping the phase", function()
    fixture(function(f)
      f.hold()
      f.index.schedule_index_phase(f.ctx, "full", 1, { protect = true })
      f.fire()
      t.assert_true(f.state.queue.full ~= nil)
      t.assert_true(f.persisted().queue.full ~= nil)
      local retry = f.rt.timers["fixture::full"]
      t.assert_true(retry ~= nil, "lock contention must rearm delivery")
      t.assert_eq(retry.delay, f.index.ADMISSION_RETRY_MS)
      t.assert_true(retry.delay >= 1000, "busy writers must not cause a tight retry loop")
      t.assert_true(f.rt.protected_deadlines["fixture::full"])
      f.index.schedule_index_phase(f.ctx, "full", 120000)
      t.assert_eq(f.rt.timers["fixture::full"], retry, "editing must not postpone delivery retry")
      f.fire()
      t.assert_true(retry.closed)
      t.assert_eq(#f.starts, 0)
      t.assert_eq(f.lock.owner(f.lease.path).token, f.lease.token)
      f.release()
      f.fire()
      t.assert_eq(#f.starts, 1)
      t.assert_eq(f.rt.job.phase, "full")
      t.assert_nil(f.state.queue.full)
      t.assert_nil(f.rt.timers["fixture::full"])
    end)
  end)

  t.it("ordinary lock retries remain ordinary refresh deadlines", function()
    fixture(function(f)
      f.hold()
      f.index.schedule_index_phase(f.ctx, "full", 1)
      f.fire()
      local retry = f.rt.timers["fixture::full"]
      t.assert_true(retry ~= nil)
      t.assert_false(f.rt.protected_deadlines["fixture::full"] == true)
      f.index.schedule_index_phase(f.ctx, "full", 123)
      t.assert_true(retry.closed)
      t.assert_eq(f.rt.timers["fixture::full"].delay, 123)
      f.release()
      f.fire()
      t.assert_eq(#f.starts, 1)
    end)
  end)

  t.it("queue drain keeps a busy phase and consumes its retry when it starts early", function()
    fixture(function(f)
      f.hold()
      f.index.schedule_index_phase(f.ctx, "full", 1, { protect = true })
      t.assert_false(f.index.try_start_queued_build())
      t.assert_true(f.state.queue.full ~= nil, "transient writer contention must not delete queued full")
      local retry = f.rt.timers["fixture::full"]
      t.assert_true(retry ~= nil)
      t.assert_true(f.rt.protected_deadlines["fixture::full"])
      f.release()
      t.assert_true(f.index.try_start_queued_build())
      t.assert_eq(#f.starts, 1)
      t.assert_true(retry.closed, "early drain must cancel the pending retry")
      t.assert_nil(f.rt.timers["fixture::full"])
      t.assert_nil(f.rt.protected_deadlines["fixture::full"])
      t.assert_false(f.index.try_start_queued_build(), "an active job must exclude another build")
      t.assert_eq(#f.starts, 1)
    end)
  end)

  t.it("writer retries still wait for shared host admission", function()
    fixture(function(f)
      f.hold()
      f.index.schedule_index_phase(f.ctx, "full", 1, { protect = true })
      f.fire()
      f.release()
      f.allow = false
      f.fire()
      t.assert_eq(#f.starts, 0)
      t.assert_true(f.state.queue.full ~= nil)
      t.assert_true(f.rt.protected_deadlines["fixture::full"])
      f.allow = true
      f.fire()
      t.assert_eq(f.admissions, 3)
      t.assert_eq(#f.starts, 1)
    end)
  end)

  t.it("same-process active jobs retain their existing queued-drain behavior", function()
    fixture(function(f)
      f.rt.job = { phase = "current" }
      f.index.schedule_index_phase(f.ctx, "full", 1, { protect = true })
      f.fire()
      t.assert_true(f.state.queue.full ~= nil)
      t.assert_nil(f.rt.timers["fixture::full"])
      t.assert_eq(#f.starts, 0)
      f.rt.job = nil
      t.assert_true(f.index.try_start_queued_build())
      t.assert_eq(#f.starts, 1)
    end)
  end)

  for _, failure in ipairs({ "missing-base", "missing-python", "lock-permission" }) do
    t.it("does not perpetually retry terminal startup failure: " .. failure, function()
      fixture(function(f)
        if failure == "missing-base" then vim.fn.delete(f.ctx.paths.active_cdb)
        elseif failure == "missing-python" then
          require("utils.platform").resolve_tool = function() return { ok = false, reason = "tool-not-found" } end
        else
          f.lock.acquire = function() return nil, "EACCES: permission denied" end
        end
        f.state.queue.full = os.time()
        t.assert_false(f.index.try_start_queued_build())
        t.assert_nil(f.state.queue.full)
        t.assert_nil(f.persisted().queue.full)
        t.assert_nil(f.rt.timers["fixture::full"])
        t.assert_eq(#f.starts, 0)
      end)
    end)
  end
end)
