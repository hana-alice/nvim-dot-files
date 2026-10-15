local t = require("tests.harness")
t.bootstrap()
local switch = require("ue.index.switch_reindex")

local function fixture()
  switch._reset_for_test()
  local calls, restarts, killed, registered, samples = {}, 0, 0, {}, {}
  local deps = {
    admit = function() return true end,
    request = function() return { "injected-helper" }, {} end,
    lock_paths = function() return { "build.lock", "writer.lock" } end,
    acquire = function(path) return { path = path } end,
    release = function() return true end,
    schedule = function(fn) fn() end,
    system = function(argv, options, callback)
      calls[#calls + 1] = { argv = argv, options = options, callback = callback }
      return { kill = function() killed = killed + 1 end }
    end,
    register = function(record) registered[#registered + 1] = record end,
    probe = function(_, _, data) samples[#samples + 1] = data end,
    notify = function() end,
  }
  local function resume() restarts = restarts + 1 end
  local function counts() return restarts, killed end
  return deps, calls, resume, counts, registered, samples
end

t.describe("private source switch reindex", function()
  t.it("runs asynchronously and resumes exactly once after successful final JSON", function()
    local deps, calls, resume, counts, registered, samples = fixture()
    switch.before({}, "scope", resume, deps)
    t.assert_eq(counts(), 0)
    t.assert_eq(#registered, 1)
    t.assert_eq(registered[1].kind, "system")
    local result = { code = 0, stdout = 'diagnostic\n{"ok":true,"action":"reindex","changed":9,"cover_tus":3,"seconds":1.2}\n' }
    calls[1].callback(result)
    calls[1].callback(result)
    t.assert_eq(counts(), 1)
    t.assert_true(samples[1].ok)
    t.assert_eq(samples[1].changed, 9)
    t.assert_eq(samples[1].cover_tus, 3)
    t.assert_eq(samples[1].seconds, 1.2)
  end)

  t.it("baseline, none, failure, malformed output and nonzero exit keep the existing restart", function()
    for _, result in ipairs({
      { code = 0, stdout = '{"ok":true,"action":"baseline"}' },
      { code = 0, stdout = '{"ok":true,"action":"none"}' },
      { code = 0, stdout = '{"ok":false,"reason":"worker-failed"}' },
      { code = 0, stdout = "invalid JSON" },
      { code = 1, stdout = '{"ok":true}' },
    }) do
      local deps, calls, resume, counts = fixture()
      switch.before({}, "scope", resume, deps)
      calls[1].callback(result)
      calls[1].callback(result)
      t.assert_eq(counts(), 1)
    end
  end)

  t.it("deduplicates a running scope while allowing independent scopes", function()
    local deps, calls, resume, counts = fixture()
    switch.before({}, "one", resume, deps)
    switch.before({}, "one", resume, deps)
    switch.before({}, "two", resume, deps)
    t.assert_eq(#calls, 2)
    calls[1].callback({ code = 0, stdout = '{"ok":true}' })
    calls[2].callback({ code = 0, stdout = '{"ok":true}' })
    t.assert_eq(counts(), 2)
    switch.before({}, "one", resume, deps)
    t.assert_eq(#calls, 3)
    switch._reset_for_test()
  end)

  t.it("thrown launch, unavailable paths and admission refusal fall back once", function()
    for _, override in ipairs({
      { system = function() error("spawn failure") end },
      { request = function() return nil, "missing-paths" end },
      { admit = function() return false, "foreground-work-active" end },
    }) do
      local deps, _, resume, counts = fixture()
      switch.before({}, "scope", resume, vim.tbl_extend("force", deps, override))
      t.assert_eq(counts(), 1)
    end
  end)

  t.it("editor shutdown kills owned children and rejects late restart callbacks", function()
    local deps, calls, resume, counts = fixture()
    switch.before({}, "scope", resume, deps)
    switch.shutdown()
    local restarts, killed = counts()
    t.assert_eq(restarts, 0)
    t.assert_eq(killed, 1)
    calls[1].callback({ code = 0, stdout = '{"ok":true}' })
    switch.before({}, "scope", resume, deps)
    t.assert_eq(counts(), 0)
    t.assert_eq(#calls, 1)
    switch._reset_for_test()
  end)

  t.it("uses semantic CDB, its shard directory and the matching client compiler profile", function()
    local deps, calls, resume = fixture()
    deps.request = nil
    local ctx = { paths = { semantic_cdb = "C:/private/cdb/compile_commands.json", clangd_dir = "C:/private/clangd" } }
    local config = { _ue_resolved_cmd = { "clangd", "--compile-commands-dir=C:/private/cdb" },
      cmd_cwd = "C:/private", cmd_env = { INCLUDE = "compiler-environment" } }
    deps.get_clients = function() return {
      { config = { cmd = { "foreign", "--compile-commands-dir=C:/foreign" } } }, { config = config },
    } end
    deps.resolve_python = function() return { ok = true, path = "python" } end
    deps.server_profile = function(command, selected)
      t.assert_eq(command[1], "clangd")
      t.assert_eq(selected, config)
      return { query_driver = "compiler", launch_cwd = "C:/private", enable_config = false }
    end
    switch.before(ctx, "scope", resume, deps)
    local args = {}
    for i, arg in ipairs(calls[1].argv) do args[arg] = calls[1].argv[i + 1] end
    t.assert_eq(args["--cdb"], ctx.paths.semantic_cdb)
    t.assert_eq(args["--index-dir"], "C:/private/cdb/.cache/clangd/index")
    t.assert_eq(args["--work-root"], "C:/private/clangd/switch-reindex")
    t.assert_eq(args["--workers"], "2")
    t.assert_eq(args["--jobs"], "8")
    t.assert_eq(vim.json.decode(args["--server-profile"]).query_driver, "compiler")
    t.assert_eq(calls[1].options.env, config.cmd_env)
    t.assert_eq(calls[1].options.cwd, config.cmd_cwd)
    switch._reset_for_test()
  end)

  t.it("source delivery waits for helper then existing attachment acknowledgement", function()
    local deps, calls = fixture()
    local state = { source_revision = 1, source_delivered = 0 }
    local m, restarts, attached = {}, 0, nil
    require("ue.index._source")(m, { RT = {}, h = {
      ensure_index_state = function() return state end, save_index_state = function() end,
    }, deps = { status_root_key = function() return "scope" end } })
    m.schedule_index_phase, m.clear_module_dirty_flags = function() end, function() end
    local options = { switch_reindex = deps, restart = function(_, callback)
      restarts = restarts + 1; attached = callback; return true
    end }
    m.deliver_source_refresh({}, {}, options)
    m.deliver_source_refresh({}, {}, options)
    t.assert_eq(#calls, 1)
    t.assert_eq(restarts, 0)
    calls[1].callback({ code = 0, stdout = '{"ok":true}' })
    t.assert_eq(restarts, 1)
    t.assert_true(m.source_refresh_pending({}))
    attached(true)
    attached(true)
    t.assert_false(m.source_refresh_pending({}))
    m.deliver_source_refresh({}, {}, options)
    t.assert_eq(restarts, 1)
  end)

  t.it("accepts only runtime-authorized frozen-to-original mappings and keeps the actual process profile", function()
    local deps, calls, resume = fixture()
    deps.request = nil
    local ctx = { paths = { semantic_cdb = "C:/original/cdb/compile_commands.json", clangd_dir = "C:/original/clangd" } }
    local config = { _ue_resolved_cmd = { "frozen-clangd", "--compile-commands-dir=C:/frozen/verified", "--enable-config=false" },
      cmd_cwd = "C:/original", cmd_env = { INCLUDE = "certified-compiler-env", LOCALAPPDATA = "frozen-cache" } }
    local client = { id = 601, config = config }
    deps.get_clients = function() return { client } end
    deps.original_cdb_dir = function(directory, selected)
      t.assert_eq(directory, "C:/frozen/verified")
      t.assert_eq(selected, client)
      return "C:/original/cdb"
    end
    deps.resolve_python = function() return { ok = true, path = "python" } end
    deps.server_profile = function(command, selected)
      t.assert_eq(command, config._ue_resolved_cmd)
      t.assert_eq(selected, config)
      return { query_driver = "certified-driver", launch_cwd = "C:/original", enable_config = false }
    end
    switch.before(ctx, "authorized-frozen", resume, deps)
    local argv = calls[1].argv
    local args = {}; for i, arg in ipairs(argv) do args[arg] = argv[i + 1] end
    t.assert_eq(args["--cdb"], ctx.paths.semantic_cdb)
    t.assert_eq(args["--index-dir"], "C:/original/cdb/.cache/clangd/index")
    t.assert_eq(args["--clangd"], "frozen-clangd")
    t.assert_eq(calls[1].options.env, config.cmd_env)
    calls[1].callback({ code = 0, stdout = '{"ok":true,"action":"none"}' })
    deps.server_profile = function() return nil, "uncertified-clangd-query-driver" end
    local refused
    switch.before(ctx, "refused-profile", function(result) refused = result end, deps)
    t.assert_eq(refused.reason, "uncertified-clangd-query-driver")
    t.assert_eq(#calls, 1)
  end)

  t.it("rejects foreign and unregistered verified directories even with claimed owner metadata", function()
    local deps, calls = fixture()
    deps.request = nil
    local ctx = { paths = { semantic_cdb = "C:/original/cdb/compile_commands.json", clangd_dir = "C:/original/clangd" } }
    deps.get_clients = function() return { { config = { _ue_resolved_cmd = {
      "clangd", "--compile-commands-dir=C:/unregistered/verified" }, _ue_batch_scope = "claimed", _ue_batch_stamp = "claimed" } } } end
    local result
    switch.before(ctx, "unregistered", function(value) result = value end, deps)
    t.assert_eq(result.reason, "no-matching-source-reader")
    t.assert_eq(#calls, 0)
    deps.original_cdb_dir = function() return "C:/foreign/cdb" end
    switch.before(ctx, "foreign-owner", function(value) result = value end, deps)
    t.assert_eq(result.reason, "no-matching-source-reader")
    t.assert_eq(#calls, 0)
  end)

  t.it("defers acquisition until the caller returns and holds both leases until helper exit", function()
    local deps, calls, resume, counts = fixture()
    local queued, acquired, released = {}, {}, {}
    deps.schedule = function(fn) queued[#queued + 1] = fn end
    deps.acquire = function(path) acquired[#acquired + 1] = path; return { path = path } end
    deps.release = function(lease) released[#released + 1] = lease.path end
    switch.before({}, "scope", resume, deps)
    t.assert_eq(#acquired, 0)
    t.assert_eq(#calls, 0)
    queued[1]()
    t.assert_eq(#acquired, 2)
    t.assert_eq(#released, 0)
    calls[1].callback({ code = 0, stdout = '{"ok":true}' })
    t.assert_eq(#released, 0)
    queued[2]()
    t.assert_eq(#released, 2)
    t.assert_eq(counts(), 1)
  end)

  t.it("partial acquisition and thrown spawn release leases before fallback", function()
    for _, thrown in ipairs({ false, true }) do
      local deps, calls, _, counts = fixture()
      local acquired, released = 0, 0
      deps.acquire = function(path)
        acquired = acquired + 1
        if acquired == 2 and not thrown then return nil, "prepare-owner" end
        return { path = path }
      end
      deps.release = function() released = released + 1 end
      if thrown then deps.system = function() error("spawn-error") end end
      switch.before({}, "scope", function()
        t.assert_eq(released, thrown and 2 or 1)
      end, deps)
      t.assert_eq(#calls, 0)
      t.assert_eq(counts(), 0)
    end
  end)

  t.it("shutdown retains leases for a running child and releases them on its late exit", function()
    local deps, calls, resume, counts = fixture()
    local released = 0
    deps.release = function() released = released + 1 end
    switch.before({}, "scope", resume, deps)
    switch.shutdown()
    t.assert_eq(released, 0)
    calls[1].callback({ code = 143, stdout = "" })
    t.assert_eq(released, 2)
    t.assert_eq(counts(), 0)
    switch._reset_for_test()
  end)

  t.it("native existing build and prepare leases each block the helper and released locks allow reentry", function()
    local lock = require("ue.file_lock")
    local root = vim.fn.tempname():gsub("\\", "/") .. "_switch_locks"
    vim.fn.mkdir(root, "p")
    local ctx = { paths = { index_state = root .. "/index.json", active_cdb = root .. "/compile_commands.json" } }
    local deps, calls, resume, counts = fixture()
    deps.lock_paths, deps.acquire, deps.release = nil, nil, nil
    local build, writer = ctx.paths.index_state .. ".build.lock", ctx.paths.active_cdb .. ".writer.lock"
    local owner
    local ok, err = xpcall(function()
      for _, path in ipairs({ build, writer }) do
        owner = assert(lock.acquire(path))
        switch.before(ctx, "scope", resume, deps)
        t.assert_eq(#calls, 0)
        t.assert_true(lock.release(owner))
        owner = nil
      end
      t.assert_eq(counts(), 2)
      switch.before(ctx, "scope", resume, deps)
      t.assert_eq(#calls, 1)
      t.assert_nil(lock.acquire(build))
      t.assert_nil(lock.acquire(writer))
      calls[1].callback({ code = 0, stdout = '{"ok":true}' })
      t.assert_nil(lock.owner(build))
      t.assert_nil(lock.owner(writer))
      t.assert_eq(counts(), 3)
    end, debug.traceback)
    if owner then lock.release(owner) end
    switch._reset_for_test()
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)

t.describe("explicit switch index command", function()
  local commands = require("ue.index.switch_commands")
  local function explicit(result, prepare_ok, baseline_ok, attached_ok)
    local notices, calls = {}, {}
    local deps = {
      resolve = function() return { paths = {} } end,
      scope = function() return "explicit-fixture" end,
      notify = function(message) notices[#notices + 1] = message end,
      switch = {
        summary = switch.summary,
        before = function(_, _, done, options)
          t.assert_true(options.suppress_notify)
          calls[#calls + 1] = "helper"; done(vim.deepcopy(result))
        end,
        baseline = function(_, _, done)
          calls[#calls + 1] = "baseline"; done({ ok = baseline_ok ~= false, action = "baseline", seconds = 0.2 })
        end,
      },
      prepare = function(_, done) calls[#calls + 1] = "prepare"; done(prepare_ok ~= false, "prepare-result"); return true end,
      restart = function(_, done) calls[#calls + 1] = "restart"; done(attached_ok ~= false); return true end,
    }
    t.assert_true(commands.run(deps))
    t.assert_eq(#notices, 2)
    return notices, calls
  end

  t.it("reports baseline/no-op and TU results with start/final notifications", function()
    for _, action in ipairs({ "baseline", "none", "reindex" }) do
      local notices, calls = explicit({ ok = true, action = action, changed = 4, cover_tus = 2, seconds = 1.5 })
      t.assert_eq(table.concat(calls, ","), action == "reindex" and "helper,restart" or "helper")
      t.assert_contains(notices[2], action)
      t.assert_contains(notices[2], "TU=2")
      t.assert_contains(notices[2], "1.500s")
      t.assert_contains(notices[2], action == "reindex" and "none:attached" or "fallback=none")
    end
  end)

  t.it("delegates uncovered inputs to prepare, establishes baseline and waits for attachment", function()
    local notices, calls = explicit({ ok = false, action = "needs-prepare", needs_prepare = true,
      reason = "uncovered-changed-files", changed = 3 })
    t.assert_eq(table.concat(calls, ","), "helper,prepare,baseline,restart")
    t.assert_contains(notices[2], "prepare-completed:attached")
    t.assert_contains(notices[2], "changed=3")
    t.assert_contains(notices[2], "uncovered-changed-files")
  end)

  t.it("reports prepare and reader attachment failures once", function()
    local notices, calls = explicit({ ok = false, needs_prepare = true, reason = "stale-baseline" }, false)
    t.assert_eq(table.concat(calls, ","), "helper,prepare")
    t.assert_contains(notices[2], "prepare-failed")
    notices = explicit({ ok = false, reason = "worker-failed" }, true, true, false)
    t.assert_contains(notices[2], "attachment-failed")
  end)

  t.it("TEMP entry invokes only read-only Python inventory and reports its output", function()
    local notices, argv, completed = {}, nil, nil
    local output
    local deps = {
      resolve = function() return { paths = {} } end,
      resolve_python = function() return { ok = true, path = "fixture-python" } end,
      work_root = "fixture-work",
      inventory_roots = function() return { "receipt-root", "graph-root" } end,
      active_roots = function() return { "active-work" } end,
      notify = function(message) notices[#notices + 1] = message end,
      schedule = function(fn) fn() end,
      register = function() end,
      system = function(args, _, done)
        argv, completed = args, done
        for i, arg in ipairs(args) do if arg == "--out" then output = args[i + 1] end end
        return { kill = function() end }
      end,
    }
    t.assert_true(commands.inventory(deps))
    t.assert_false(commands.inventory(deps))
    t.assert_contains(table.concat(argv, " "), "cdb_batch_work_inventory.py")
    t.assert_contains(output, "/.tmp/review-gd/n4/")
    t.assert_contains(table.concat(argv, " "), "--reference-root receipt-root --reference-root graph-root")
    t.assert_false(table.concat(argv, " "):find("delete", 1, true) ~= nil)
    completed({ code = 0 })
    t.assert_eq(#notices, 2)
    t.assert_contains(notices[2], "Dry-run inventory written")
  end)

  t.it("final notification waits for real prepare and reader attachment callbacks", function()
    local notices, prepared, attached = {}, nil, nil
    local deps = {
      resolve = function() return {} end, scope = function() return "deferred-fixture" end,
      notify = function(message) notices[#notices + 1] = message end,
      prepare = function(_, done) prepared = done; return true end,
      restart = function(_, done) attached = done; return true end,
      switch = {
        summary = switch.summary,
        before = function(_, _, done) done({ ok = false, needs_prepare = true, reason = "missing-baseline" }) end,
        baseline = function(_, _, done) done({ ok = true, action = "baseline" }) end,
      },
    }
    commands.run(deps)
    t.assert_eq(#notices, 1)
    t.assert_false(commands.run(deps))
    prepared(true)
    t.assert_eq(#notices, 1)
    attached(true); attached(true)
    t.assert_eq(#notices, 2)
  end)

  t.it("explicit request rejected by an active automatic helper terminates honestly", function()
    local notices = {}
    commands.run({ resolve = function() return {} end, scope = function() return "already-active-fixture" end,
      notify = function(message) notices[#notices + 1] = message end,
      switch = { summary = switch.summary, before = function() return false end } })
    t.assert_eq(#notices, 2)
    t.assert_contains(notices[2], "already-running-or-exiting")
  end)

  t.it("completion hook releases automatic pending after a failed prepare exactly once", function()
    local notices, completed, preparation = {}, 0, nil
    commands.run({ resolve = function() return {} end, scope = function() return "failed-prepare-hook" end,
      notify = function(message) notices[#notices + 1] = message end,
      switch = { summary = switch.summary,
        before = function(_, _, done) done({ ok = false, needs_prepare = true, reason = "missing-baseline" }) end },
      prepare = function(_, done) preparation = done; return true end,
      completed = function(result)
        completed = completed + 1
        t.assert_eq(#notices, 2)
        t.assert_false(result.ok)
        t.assert_eq(result.fallback, "prepare-failed")
      end })
    t.assert_eq(completed, 0)
    preparation(false, "real prepare failed"); preparation(false, "duplicate")
    t.assert_eq(completed, 1)
  end)
end)
