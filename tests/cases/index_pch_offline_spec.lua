local t = require("tests.harness")
t.bootstrap()

local config = require("ue.config")
require("ue")
local index = require("ue.index")

local function write(path, content)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local handle = assert(io.open(path, "wb"))
  handle:write(content)
  handle:close()
end

local function isolated_loader()
  local module = {}
  require("ue.index.pch_offline")(module, { RT = {}, h = {}, deps = {} })
  return module
end

local function with_options(value, run)
  local saved = vim.deepcopy(config.options())
  config.setup(vim.tbl_deep_extend("force", saved, { index = { pch_offline = value } }))
  local ok, err = xpcall(run, debug.traceback)
  config.setup(saved)
  if not ok then error(err, 0) end
end

local function await_probe(module)
  local report
  module.probe_pch_offline(function(value) report = value end)
  t.assert_true(vim.wait(6000, function() return report ~= nil end, 10), "version probe completion")
  return report
end

local real_bin = vim.fn.expand("~/.cache/clangd-pch-22.1.5/metadata-v24c/bin")
local function native_capability(directory)
  local report
  local ok, err = pcall(function()
    with_options({ enabled = true, bin_dir = directory }, function()
      report = await_probe(isolated_loader())
    end)
  end)
  return ok and report and report.ok == true,
    ok and report and report.error or tostring(err)
end

-- Existence alone does not prove the current host can load the executable
-- (for example, a copied installation may lack runtime DLLs).
local native_available, native_reason = native_capability(real_bin)

t.describe("optional PCH offline loader", function()
  t.it("false and enabled=false return before capability or child process work", function()
    for _, value in ipairs({ false, { enabled = false } }) do
      with_options(value, function()
        local module, saved_system, calls, probes = isolated_loader(), vim.system, 0, 0
        local original_probe = module.probe_pch_offline
        module.probe_pch_offline = function(callback)
          probes = probes + 1
          original_probe(callback)
        end
        vim.system = function() calls = calls + 1; error("disabled feature spawned") end
        local report
        local ok, err = pcall(function()
          module.run_pch_offline({}, {}, function(result) report = result end)
          t.assert_true(report.disabled)
          t.assert_false(report.ok)
          t.assert_eq(calls, 0)
          t.assert_eq(probes, 0, "disabled run must return before calling the capability probe")
        end)
        vim.system = saved_system
        if not ok then error(err) end
      end)
    end
  end)

  t.it("an actually absent private directory fails closed without a process", function()
    with_options({ enabled = true, bin_dir = vim.fn.tempname() .. "_missing_private_bin" }, function()
      local module, saved_system, calls = isolated_loader(), vim.system, 0
      vim.system = function() calls = calls + 1; error("missing binary spawned") end
      local ok, err = pcall(function()
        local result = await_probe(module)
        t.assert_false(result.ok)
        t.assert_contains(result.error, "missing")
        t.assert_eq(calls, 0)
      end)
      vim.system = saved_system
      if not ok then error(err) end
    end)
  end)

  if not native_available then
    t.skip("real private binaries support version probing and identity cache invalidation",
      native_reason or "private clangd/probe unavailable", { native = true })
    t.skip("tool failure records probe and inherits the last clangd -j",
      native_reason or "private clangd/probe unavailable", { native = true })
    t.skip("version failure and producer timeout/spawn/malformed output return to fallback",
      native_reason or "private clangd/probe unavailable", { native = true })
  else
    -- Copy genuine installed executables; never manufacture an executable or
    -- modify an installed binary to make a host capability assertion pass.
    local root = vim.fs.normalize(vim.fn.tempname()) .. "_pch_binary_identity"
    local copied, copy_reason = pcall(function()
      vim.fn.mkdir(root, "p")
      for _, name in ipairs({ "clangd.exe", "clangd-pch-probe.exe" }) do
        assert(vim.uv.fs_copyfile(real_bin .. "/" .. name, root .. "/" .. name))
      end
    end)
    local copy_available
    if copied then copy_available, copy_reason = native_capability(root) end
    if not copy_available then
      t.skip("real executable copies cache version probes and invalidate on mtime change",
        copy_reason or "copied binaries cannot run on this host", { native = true })
    else
      t.it("real executable copies cache version probes and invalidate on mtime change", function()
        with_options({ enabled = true, bin_dir = root }, function()
          local module, saved_system, versions = isolated_loader(), vim.system, 0
          vim.system = function(command, options, callback)
            if command[2] == "--version" then versions = versions + 1 end
            return saved_system(command, options, callback)
          end
          local ok, err = pcall(function()
            local first = await_probe(module)
            t.assert_true(first.ok, first.error)
            t.assert_true(await_probe(module).ok)
            t.assert_eq(versions, 1, "unchanged binary identities must reuse the result")
            assert(vim.uv.fs_utime(root .. "/clangd-pch-probe.exe", 1000000000, 1000000000))
            t.assert_true(await_probe(module).ok)
            t.assert_eq(versions, 2, "either binary's identity change invalidates capability")
          end)
          vim.system = saved_system
          if not ok then error(err) end
        end)
      end)
    end
    -- t.it records errors without unwinding the containing describe body.
    -- Cleanup therefore runs after both PASS and FAIL, as well as host SKIP.
    vim.fn.delete(root, "rf")

    t.it("tool failure is observable and the last configured -j is retained", function()
      with_options({ enabled = true, bin_dir = real_bin, timeout_s = 7 }, function()
        local module = isolated_loader()
        t.assert_true(await_probe(module).ok, "requires the real private version capability")
        local saved_system = vim.system
        local probe, saved_record = require("utils.probe"), require("utils.probe").record
        local log, saved_log = require("utils.log"), require("utils.log").warn_ctx
        local command, options, pending, records, result, warnings
        records = {}
        warnings = 0
        log.warn_ctx = function() warnings = warnings + 1 end
        probe.record = function(topic, key, data)
          records[#records + 1] = { topic = topic, key = key, data = data }
        end
        -- Async subprocess boundary unit test. Native admission above is real;
        -- only the producer response is injected, and no compiler is launched.
        vim.system = function(argv, opts, callback)
          command, options, pending = argv, opts, callback
          return {}
        end
        local ok, err = pcall(function()
          local ctx = { engine_root = vim.fn.tempname(), paths = { semantic_cdb = "/fixture/background/compile_commands.json" } }
          module.run_pch_offline(ctx, {
            python = vim.v.progpath, jobs = 1, command = { "clangd", "-j", "2", "-j=6" }, env = { TEST = "yes" },
          }, function(report) result = report end)
          t.assert_nil(result, "tool completion must remain asynchronous")
          t.assert_type(pending, "function")
          local jobs, index_dir
          for n, arg in ipairs(command) do
            if arg == "-j" then jobs = command[n + 1] end
            if arg == "--index-dir" then index_dir = command[n + 1] end
          end
          t.assert_eq(jobs, "6", "production jobs are no longer limited to the experimental 1/2")
          t.assert_eq(vim.fs.normalize(index_dir), "/fixture/background/.cache/clangd/index")
          t.assert_eq(options.timeout, 7000)
          t.assert_eq(options.env.TEST, "yes")
          pending({ code = 9, stdout = "", stderr = "injected producer failure" })
          t.assert_true(vim.wait(1000, function() return result ~= nil end, 10))
          t.assert_false(result.ok)
          t.assert_true(#records > 0)
          t.assert_eq(records[#records].topic, "index-pch-offline")
          t.assert_eq(records[#records].data.state, "failed")
          t.assert_eq(warnings, 1, "fallback must be visible in utils.log")
        end)
        vim.system, probe.record, log.warn_ctx = saved_system, saved_record, saved_log
        if not ok then error(err) end
      end)
    end)


    t.it("version errors, timeout, spawn errors and malformed output fail closed", function()
      with_options({ enabled = true, bin_dir = real_bin }, function()
        local saved_system = vim.system
        local ok, err = xpcall(function()
          -- Unit tests of process failure boundaries, using genuine files for
          -- existence checks. These injected results do not certify native work.
          for _, spawn_error in ipairs({ false, true }) do
            local module, pending, report = isolated_loader(), nil, nil
            vim.system = function(_, _, callback)
              if spawn_error then error("unit version spawn error") end
              pending = callback
              return {}
            end
            module.probe_pch_offline(function(value) report = value end)
            if pending then pending({ code = 7, stdout = "", stderr = "unit version failed" }) end
            t.assert_true(vim.wait(1000, function() return report ~= nil end, 10))
            t.assert_false(report.ok)
            t.assert_contains(report.error, spawn_error and "version-spawn" or "version-failed")
          end

          vim.system = saved_system
          local module = isolated_loader()
          t.assert_true(await_probe(module).ok, "producer unit tests require real capability first")
          for _, failure in ipairs({
            { code = 124, signal = 15, stdout = "", stderr = "unit timeout" },
            { code = 0, stdout = "not json", stderr = "" },
            { spawn = true },
          }) do
            local report, pending
            vim.system = function(_, _, callback)
              if failure.spawn then error("unit producer spawn error") end
              pending = callback
              return {}
            end
            module.run_pch_offline({ engine_root = "/fixture", paths = { semantic_cdb = "/fixture/compile_commands.json" } },
              { python = vim.v.progpath, jobs = 1 }, function(value) report = value end)
            if pending then pending(failure) end
            t.assert_true(vim.wait(1000, function() return report ~= nil end, 10))
            t.assert_false(report.ok)
            t.assert_contains(report.error, failure.spawn and "offline-tool-spawn" or "offline-tool-failed")
          end
        end, debug.traceback)
        vim.system = saved_system
        if not ok then error(err, 0) end
      end)
    end)
  end
end)

-- Async subprocess boundary unit tests of the Tier 1 absorption wiring. The
-- capability probe and child processes are injected; no compiler is launched
-- and these tests certify only argument/ordering contracts, not native work.
local function tier1_fixture(run)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_pch_tier1"
  local background = root .. "/bg/compile_commands.json"
  write(background .. ".semantic.json", "[]")
  local applied, signature = {}, "1:2.3"
  local core = { RT = {}, deps = {}, h = {
    generation_for_context = function() return { generation_id = "gen-1" } end,
    file_signature = function() return signature end,
  } }
  local module = {}
  require("ue.index.pch_offline")(module, core)
  module.probe_pch_offline = function(callback) callback({ ok = true, bin_dir = root .. "/bin" }) end
  module.base_compile_commands_path = function() return root .. "/base.json" end
  module.apply_background_activation = function(_, generation, activation, opts)
    applied[#applied + 1] = { generation = generation, activation = activation, opts = opts }
    return { changed = true }
  end
  local ctx = { engine_root = root, project_root = root, paths = { semantic_cdb = background } }
  local request = { python = vim.v.progpath, jobs = 1, tier1 = {
    clangd = "reader-clangd", profile = { name = "p" }, store = root .. "/bg/verified_batches",
    background = background, marker = root .. "/bg/marker", lease = { path = "L", token = "T" } } }
  local saved = vim.system
  local ok, err = xpcall(function()
    run({ module = module, ctx = ctx, request = request, applied = applied, root = root,
      set_signature = function(value) signature = value end })
  end, debug.traceback)
  vim.system = saved
  vim.fn.delete(root, "rf")
  if not ok then error(err, 0) end
end

local function arg_after(command, flag)
  for n, arg in ipairs(command) do if arg == flag then return command[n + 1] end end
end

local function scripted_system(handlers, calls)
  return function(command, _, callback)
    calls[#calls + 1] = command
    local handler = handlers[#calls]
    local result = handler and handler(command) or { code = 0, stdout = "", stderr = "" }
    vim.schedule(function() callback(result) end)
    return {}
  end
end

local function plan_ok(command)
  write(arg_after(command, "--out"), vim.json.encode({ schema = 1, input_sha256 = "sha-in" }))
  return { code = 0, stdout = "", stderr = "" }
end

t.describe("PCH offline Tier 1 absorption wiring (async boundary unit tests)", function()
  t.it("plans, passes the plan to the producer, then collects accepted ids under the lease", function()
    tier1_fixture(function(f)
      local calls, report = {}, nil
      vim.system = scripted_system({ plan_ok,
        function() return { code = 0, stdout = vim.json.encode({ ok = true, tier1_accepted_ids = { 3, 5 } }) } end,
        function(command)
          write(arg_after(command, "--out"), vim.json.encode({ ok = true, activation = { ok = true },
            revalidated_completed = { 3 }, metrics = { collect_accepted_count = 2 } }))
          return { code = 0, stdout = "", stderr = "" }
        end }, calls)
      f.module.run_pch_offline(f.ctx, f.request, function(value) report = value end)
      t.assert_true(vim.wait(2000, function() return report ~= nil end, 10))
      t.assert_eq(#calls, 3)
      t.assert_contains(calls[1][3], "cdb_background_batch.py")
      t.assert_eq(arg_after(calls[1], "--plan"), f.request.tier1.background .. ".semantic.json")
      t.assert_true(vim.tbl_contains(calls[1], "--auto-tier1-large"))
      t.assert_eq(arg_after(calls[1], "--clangd"), "reader-clangd")
      t.assert_contains(calls[2][3], "clangd_pch_offline.py")
      t.assert_eq(arg_after(calls[2], "--tier1-plan"), arg_after(calls[1], "--out"))
      t.assert_eq(arg_after(calls[2], "--tier1-clangd"), "reader-clangd")
      t.assert_eq(vim.json.decode(arg_after(calls[2], "--server-profile")).name, "p")
      t.assert_eq(arg_after(calls[3], "--collect"), arg_after(calls[1], "--out"))
      t.assert_true(vim.deep_equal(vim.json.decode(arg_after(calls[3], "--completed")), { 3, 5 }))
      local published = vim.json.decode(table.concat(vim.fn.readfile(arg_after(calls[3], "--publish-request")), "\n"))
      t.assert_eq(published.lease.token, "T")
      t.assert_eq(published.owner_pid, vim.fn.getpid())
      t.assert_eq(published.source_sha256, "sha-in")
      t.assert_eq(published.generation_id, "gen-1")
      t.assert_eq(#f.applied, 1)
      t.assert_false(f.applied[1].opts.drain)
      t.assert_false(f.applied[1].opts.restart)
      t.assert_true(report.ok)
      t.assert_true(report.tier1_activation.ok)
      t.assert_eq(report.tier1_activation.accepted, 2)
    end)
  end)

  t.it("plan failure still runs the producer without Tier 1 arguments", function()
    tier1_fixture(function(f)
      local calls, report = {}, nil
      vim.system = scripted_system({ function() return { code = 3, stdout = "", stderr = "plan broke" } end,
        function() return { code = 0, stdout = vim.json.encode({ ok = true }) } end }, calls)
      f.module.run_pch_offline(f.ctx, f.request, function(value) report = value end)
      t.assert_true(vim.wait(2000, function() return report ~= nil end, 10))
      t.assert_eq(#calls, 2)
      t.assert_nil(arg_after(calls[2], "--tier1-plan"))
      t.assert_true(report.ok)
      t.assert_nil(report.tier1_activation)
      t.assert_eq(#f.applied, 0)
    end)
  end)

  t.it("no accepted groups skip collect; base change after collect refuses activation", function()
    tier1_fixture(function(f)
      local calls, report = {}, nil
      vim.system = scripted_system({ plan_ok,
        function() return { code = 0, stdout = vim.json.encode({ ok = true, tier1_accepted_ids = {} }) } end }, calls)
      f.module.run_pch_offline(f.ctx, f.request, function(value) report = value end)
      t.assert_true(vim.wait(2000, function() return report ~= nil end, 10))
      t.assert_eq(#calls, 2)
      t.assert_true(report.tier1_activation.skipped)

      calls, report = {}, nil
      vim.system = scripted_system({ plan_ok,
        function() return { code = 0, stdout = vim.json.encode({ ok = true, tier1_error = "plan-broke" }) } end }, calls)
      f.module.run_pch_offline(f.ctx, f.request, function(value) report = value end)
      t.assert_true(vim.wait(2000, function() return report ~= nil end, 10))
      t.assert_eq(#calls, 2, "a producer-side Tier 1 setup error never collects")
      t.assert_false(report.tier1_activation.ok)
      t.assert_contains(report.tier1_activation.reason, "tier1-prepare:plan-broke")

      calls, report = {}, nil
      vim.system = scripted_system({ plan_ok,
        function() return { code = 0, stdout = vim.json.encode({ ok = true, tier1_accepted_ids = { 1 } }) } end,
        function(command)
          write(arg_after(command, "--out"), vim.json.encode({ ok = true, activation = { ok = true } }))
          f.set_signature("changed")
          return { code = 0, stdout = "", stderr = "" }
        end }, calls)
      f.module.run_pch_offline(f.ctx, f.request, function(value) report = value end)
      t.assert_true(vim.wait(2000, function() return report ~= nil end, 10))
      t.assert_eq(#calls, 3)
      t.assert_false(report.tier1_activation.ok)
      t.assert_eq(report.tier1_activation.reason, "tier1-base-changed")
      t.assert_eq(#f.applied, 0)
      t.assert_true(report.ok, "Tier 1 refusal never fails the producer report")
    end)
  end)
end)

local function with_full_build(run)
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_pch_full_build"
  local ctx = {
    engine_root = root, project_root = root, _headless_index_fixture = true,
    paths = {
      platform_key = "test", active_cdb = root .. "/active.json",
      index_dir = root, index_cdb_dir = root, active_index_dir = root,
      index_state = root .. "/state.json", index_queue = root .. "/queue.json",
      index_full_cdb = root .. "/full-input.json", full_index = root .. "/full.idx",
      current_index = root .. "/current.idx", semantic_cdb = root .. "/published/compile_commands.json",
      semantic_full_cdb = root .. "/full.json",
    },
  }
  local entry = { file = root .. "/A.cpp", directory = root, arguments = { "clang++", "-c", root .. "/A.cpp" } }
  write(ctx.paths.active_cdb, vim.json.encode({ entry }))
  local saved = {
    system = vim.system, restart = index.maybe_restart_clangd_for_index,
    queued = index.try_start_queued_build, pending = index.phase_barrier_pending,
    offline = index.run_pch_offline, publish = index.publish_semantic_cdb,
    source = index.source_refresh_pending, delivery = index.deliver_source_refresh,
    job = index._rt.job, toolchain = index._rt.toolchain_identity_override,
  }
  local controls = { restarts = 0, commands = {}, deliveries = 0 }
  local root_key = root .. "\31" .. root .. "\31test"
  local ok, err = xpcall(function()
    index._rt.job, index._rt.toolchain_identity_override = nil, "pch-fixture-compiler"
    index.phase_barrier_pending = function() return false end
    index.try_start_queued_build = function() end
    index.source_refresh_pending = function() return controls.source_pending == true end
    index.deliver_source_refresh = function() controls.deliveries = controls.deliveries + 1 end
    index.maybe_restart_clangd_for_index = function() controls.restarts = controls.restarts + 1 end
    local state = index.ensure_index_state(ctx)
    state.modules = { A = { key = "A", name = "A", tier = "core" } }
    vim.system = function(command, _, callback)
      controls.commands[#controls.commands + 1] = command
      t.assert_contains(command[2], "build_full_cdb.py")
      write(ctx.paths.full_index, "full-marker")
      write(ctx.paths.semantic_full_cdb, vim.json.encode({ entry }))
      controls.generator_done = callback
      return {}
    end
    controls.start = function()
      t.assert_true(index.build_phase_async(ctx, "full"))
      controls.generator_done({ code = 0, stdout = "", stderr = "" })
    end
    controls.wait = function()
      t.assert_true(vim.wait(1500, function() return index._rt.job == nil end, 10))
      t.assert_eq(state.build.status, "ready")
    end
    run(ctx, controls, state)
  end, debug.traceback)
  vim.system = saved.system
  index.maybe_restart_clangd_for_index, index.try_start_queued_build = saved.restart, saved.queued
  index.phase_barrier_pending, index.run_pch_offline = saved.pending, saved.offline
  index.publish_semantic_cdb = saved.publish
  index.source_refresh_pending, index.deliver_source_refresh = saved.source, saved.delivery
  index._rt.job, index._rt.toolchain_identity_override = saved.job, saved.toolchain
  index._rt.module_state[root_key], index._rt.contexts[root_key] = nil, nil
  vim.fn.delete(root, "rf")
  if not ok then error(err, 0) end
end

t.describe("full phase PCH completion seam (async boundary unit tests)", function()
  t.it("missing private binaries preserve the existing full command and restart sequence", function()
    with_options({ enabled = true, bin_dir = vim.fn.tempname() .. "_absent" }, function()
      with_full_build(function(_, controls)
        controls.start(); controls.wait()
        t.assert_eq(#controls.commands, 1)
        t.assert_contains(controls.commands[1][2], "build_full_cdb.py")
        t.assert_eq(controls.restarts, 1)
      end)
    end)
  end)

  t.it("false preserves the full generator and original restart", function()
    with_options(false, function()
      with_full_build(function(_, controls)
        controls.start(); controls.wait()
        t.assert_eq(#controls.commands, 1)
        t.assert_eq(controls.restarts, 1)
      end)
    end)
  end)

  t.it("completion retains writer ownership, then success or failure restarts exactly once", function()
    for _, result in ipairs({ { ok = true, skipped = false }, { ok = false, error = "unit producer failure" } }) do
      with_full_build(function(ctx, controls)
        local complete
        index.run_pch_offline = function(context, request, callback)
          t.assert_eq(context, ctx)
          t.assert_true(vim.uv.fs_stat(ctx.paths.semantic_cdb) ~= nil, "offline starts after publication")
          t.assert_type(request.python, "string")
          t.assert_eq(request.env.PYTHONHOME, "")
          complete = callback
        end
        controls.start()
        t.assert_true(vim.wait(1000, function() return complete ~= nil end, 10))
        t.assert_eq(controls.restarts, 0, "restart must wait for the producer")
        t.assert_type(index._rt.job, "table")
        t.assert_true(vim.uv.fs_stat(ctx.paths.index_state .. ".build.lock") ~= nil)
        complete(result)
        controls.wait()
        t.assert_eq(controls.restarts, 1, "producer failure keeps the original reader path")
        t.assert_nil(vim.uv.fs_stat(ctx.paths.index_state .. ".build.lock"))
      end)
    end
  end)

  t.it("skipped plus unchanged CDB preserves reader; source refresh still owns delivery", function()
    with_full_build(function(_, controls)
      index.run_pch_offline = function(_, _, callback) callback({ ok = true, skipped = true }) end
      index.publish_semantic_cdb = function() return true, { changed = false } end
      controls.start(); controls.wait()
      t.assert_eq(controls.restarts, 0)
      controls.source_pending = true
      controls.start(); controls.wait()
      t.assert_eq(controls.deliveries, 1)
      t.assert_eq(controls.restarts, 0)
    end)
  end)
end)
