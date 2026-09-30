local t = require("tests.harness")
t.bootstrap()
local transaction = require("ue.cdb.transaction")
local uv = vim.uv

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(type(value) == "string" and value or vim.json.encode(value)); file:close()
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a"); file:close()
  return bytes
end

local function snapshot(path)
  local stat = assert(uv.fs_stat(path))
  return { bytes = read(path), sec = stat.mtime.sec, nsec = stat.mtime.nsec }
end

local function fixture(body, target_platform)
  target_platform = target_platform or "Win64"
  local original_pipeline = package.loaded["ue.cdb.pipeline"]
  package.loaded["ue.cdb.pipeline"] = nil
  local pipeline = require("ue.cdb.pipeline")
  local root = vim.fs.normalize(vim.fn.tempname() .. "-prepare-transaction")
  vim.fn.mkdir(root .. "/include", "p")
  local ctx = { engine_root = root, paths = { active_cdb = root .. "/compile_commands.json",
    cdb_shards_dir = root .. "/shards", index_cdb_dir = root .. "/index" } }
  local original_options = vim.deepcopy(require("ue.config").options())
  require("ue.config").setup({ cdb = { steps = { "resolve_cdb_paths.py" } } })
  local restarts = 0
  pipeline.set_runtime({
    notify = function() end, log_error = function() end,
    restart_clangd = function() restarts = restarts + 1 end,
    jobstart = function(command, _, callbacks)
      local output = {}
      return vim.fn.jobstart(command, {
        stdout_buffered = true, stderr_buffered = true,
        on_stdout = function(_, lines) vim.list_extend(output, lines) end,
        on_stderr = function(_, lines) vim.list_extend(output, lines) end,
        on_exit = function(_, code)
          if code == 0 then callbacks.on_exit(0, output)
          else callbacks.on_fail(code, output, "fixture pipeline") end
        end,
      })
    end,
  })
  write(root .. "/A.cpp", '#include "value.h"\nint value() { return VALUE; }\n')
  write(root .. "/include/value.h", '#define VALUE 1\n')
  local build = "Intermediate/Build/" .. target_platform .. "/Fixture/Development"
  vim.fn.mkdir(root .. "/" .. build, "p")
  local unity = root .. "/Module.Fixture.cpp"
  write(unity, '#include "A.cpp"\n')
  local generation = 0
  local function run(value, overrides)
    local generated_raw, result
    local options = {
      _host_admitted = true,
      pipeline = pipeline.run,
      generate = function(working, _, done)
        t.assert_eq(working.engine_root, ctx.engine_root)
        t.assert_false(require("ue.core.fs").path_has_prefix(working.paths.active_cdb, root),
          "large staged writes must be outside live watch roots")
        t.assert_false(working.paths.active_cdb == ctx.paths.active_cdb)
        t.assert_false(working.paths.cdb_shards_dir == ctx.paths.cdb_shards_dir)
        t.assert_true(uv.fs_stat(ctx.paths.active_cdb .. ".writer.lock") ~= nil)
        local entries = { { directory = root, file = root .. "/A.cpp",
          arguments = { "clang++", "-Iinclude", "-I" .. build,
            "-DCHOICE=" .. tostring(value), "-c", root .. "/A.cpp" } } }
        if overrides and overrides.entry_flags then vim.list_extend(entries[1].arguments, overrides.entry_flags) end
        local origin = require("ue.cdb.unity_origin")
        local dependencies = {}; origin.add_dependency(dependencies, unity, read(unity))
        generated_raw = vim.json.encode(entries)
        write(working.paths.active_cdb, generated_raw)
        assert(origin.write(working.paths.active_cdb, origin.finalize({ {
          unity = unity, members = { root .. "/A.cpp" }, entries = entries, dependencies = dependencies,
        } }, entries)))
        generation = generation + 1
        local roots = generation % 2 == 1 and { root, root .. "/include" } or { root .. "/include", root }
        require("ue.cdb.shards").write_shard(working, target_platform, "Fixture", "Development", entries, roots)
        if overrides and overrides.burst then
          local python = require("utils.platform").resolve_tool({ name = "python",
            driver_candidates = function(driver) return driver.python_candidates() end })
          local result = vim.system({ python.path, "-B", "-I", "-c", [[
import pathlib,sys
root=pathlib.Path(sys.argv[1])
for i in range(1200):
    (root/(('burst-%04d-'%i)+'x'*64+'.tmp')).write_bytes(b'x'*1024)
]], vim.fs.dirname(working.paths.active_cdb) }, { text = true }):wait(10000)
          t.assert_eq(result.code, 0, result.stderr)
        end
        done(true)
      end,
    }
    for name, value_override in pairs(overrides or {}) do options[name] = value_override end
    transaction.run(ctx, function() end, function(ok, message, detail)
      result = { ok = ok, message = message, detail = detail }
    end, options)
    t.assert_true(vim.wait(30000, function() return result ~= nil end, 10), "transaction callback timed out")
    t.assert_nil(uv.fs_stat(ctx.paths.active_cdb .. ".writer.lock"), "completion must release the live lease")
    return result, generated_raw
  end
  local ok, err = xpcall(function() body(ctx, run, function() return restarts end) end, debug.traceback)
  package.loaded["ue.cdb.pipeline"] = original_pipeline
  require("ue.config").reset_for_test(); require("ue.config").setup(original_options)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

t.describe("prepare CDB transaction", function()
  t.it("real raw-to-processed repeat preserves live bytes, mtime, receipts and watch epoch; changes commit once", function()
    fixture(function(ctx, run, restarts)
      local first, raw = run(1)
      t.assert_true(first.ok, first.message)
      t.assert_true(first.detail.changed)
      t.assert_false(read(ctx.paths.active_cdb) == raw, "real resolver must transform the raw input")
      local receipt = vim.json.decode(read(ctx.paths.active_cdb .. ".unity-receipt.json"))
      t.assert_eq(#receipt.groups, 1, "stage path must retain original Unity compiler evidence")
      t.assert_eq(receipt.groups[1].members[1], ctx.engine_root .. "/A.cpp")
      t.assert_eq(restarts(), 1, "staged pipeline never restarts before commit")
      local paths = { ctx.paths.active_cdb, ctx.paths.active_cdb .. ".unity-origin.json",
        ctx.paths.active_cdb .. ".unity-receipt.json", ctx.paths.active_cdb .. ".pipeline-result.json",
        ctx.engine_root .. "/compile_commands.partition.json", ctx.paths.cdb_shards_dir .. "/manifest.json",
        ctx.paths.cdb_shards_dir .. "/Win64-Fixture-Development.json",
        ctx.engine_root .. "/.cache/nvim-ue/cdb/active/compile_commands.Win64-Development.json" }
      local before, tracked = {}, {}
      local function path_key(path)
        return require("utils.platform").driver().path_key(vim.fs.normalize(path))
      end
      for _, path in ipairs(paths) do
        before[path] = snapshot(path)
        tracked[path_key(path)] = true
      end
      local invalidations, events = 0, 0
      local guard = require("ue.index.batch_guard").start(ctx, nil, {
        roots = { ctx.engine_root }, receipts = { ctx.paths.active_cdb .. ".unity-receipt.json" },
        watch_factory = function(root, callback)
          local watch = assert(uv.new_fs_event())
          assert(watch:start(root, { recursive = true }, function(err, filename, flags)
            -- libuv may coalesce a burst into an event without a filename.
            -- Match the production runtime's fail-closed handling of that case.
            if err or not filename then callback(err or "watch-event-without-path"); return end
            if filename and tracked[path_key(root .. "/" .. filename)] then
              events = events + 1; callback(nil, filename, flags)
            end
          end))
          return watch, { recursive = true }
        end,
        verify_async = function(_, done) done({ ok = true }) end,
        on_invalidated = function() invalidations = invalidations + 1 end,
      })
      t.assert_true(vim.wait(1000, function() return guard:status().state == "ready" end))
      local repeated = run(1, { burst = true })
      t.assert_true(repeated.ok, repeated.message)
      t.assert_false(repeated.detail.changed)
      t.assert_eq(#repeated.detail.published, 0, "all final artifacts are unchanged")
      for _, path in ipairs(paths) do t.assert_true(vim.deep_equal(snapshot(path), before[path]), path) end
      vim.wait(150, function() return false end, 10)
      t.assert_eq(events, 0)
      t.assert_eq(invalidations, 0)
      t.assert_eq(guard:status().state, "ready")
      t.assert_eq(restarts(), 1)
      local changed = run(2)
      t.assert_true(changed.ok, changed.message)
      t.assert_true(changed.detail.changed)
      local active_commits = 0
      for _, path in ipairs(changed.detail.published) do
        if vim.fs.normalize(path) == ctx.paths.active_cdb then active_commits = active_commits + 1 end
      end
      t.assert_eq(active_commits, 1)
      t.assert_eq(restarts(), 2)
      local invalidated = vim.wait(3000, function() return invalidations == 1 end)
      local status = guard:status()
      guard:stop()
      t.assert_true(invalidated, vim.inspect({ status = status, events = events }))
      t.assert_eq(status.state, "invalidated")
    end)
  end)

  t.it("failed pipeline, partition or malformed final CDB preserves the last successful live pair", function()
    fixture(function(ctx, run, restarts)
      t.assert_true(run(1).ok)
      local active = snapshot(ctx.paths.active_cdb)
      local receipt = snapshot(ctx.paths.active_cdb .. ".unity-receipt.json")
      for _, overrides in ipairs({
        { generate = function() error("fixture generation failed to start") end },
        { pipeline = function(_, _, done) done(false, "fixture pipeline failure") end },
        { partition = function(_, _, done) done(false, "fixture partition failure") end },
        { partition = function(working, _, done) write(working.paths.active_cdb, "{}"); done(true) end },
      }) do
        local failed = run(2, overrides)
        t.assert_false(failed.ok)
        t.assert_true(vim.deep_equal(snapshot(ctx.paths.active_cdb), active))
        t.assert_true(vim.deep_equal(snapshot(ctx.paths.active_cdb .. ".unity-receipt.json"), receipt))
        t.assert_eq(restarts(), 1)
      end
    end)
  end)

  t.it("rejects another live writer before staging or spawning", function()
    fixture(function(ctx)
      local locks = require("ue.file_lock")
      local lease = assert(locks.acquire(ctx.paths.active_cdb .. ".writer.lock"))
      local result
      transaction.run(ctx, function() end, function(ok) result = ok end, {
        _host_admitted = true, helper = function() error("must not spawn") end,
      })
      t.assert_false(result)
      locks.release(lease)
    end)
  end)

  t.it("manual sync and async partition cannot bypass the active prepare writer lease", function()
    fixture(function(ctx, run)
      t.assert_true(run(1).ok)
      local locks = require("ue.file_lock")
      local index = require("ue.index")
      local lease = assert(locks.acquire(ctx.paths.active_cdb .. ".writer.lock"))
      local before = snapshot(ctx.paths.active_cdb)
      local ok, reason = index.partition_base_cdb(ctx)
      t.assert_false(ok)
      t.assert_contains(reason, "owned by another Neovim")
      local completed
      index.partition_base_cdb_async(ctx, {}, function(success, message)
        completed = { success, message }
      end)
      t.assert_true(vim.wait(30000, function() return completed ~= nil end, 10))
      t.assert_false(completed[1])
      t.assert_contains(completed[2], "owned by another Neovim")
      t.assert_true(vim.deep_equal(snapshot(ctx.paths.active_cdb), before))
      t.assert_true(locks.release(lease), "rejected partition must not remove the actual owner's lease")
    end)
  end)

  if type(require("utils.platform").driver().pch_build_plan) == "function" then
    t.it("stages PCH recipes with logical published paths and preserves identical live recipe bytes and mtime", function()
      fixture(function(ctx, run)
        require("ue.config").setup({ cdb = { steps = { "prebuild_pch_v2.py", "resolve_cdb_paths.py" } } })
        local header = ctx.engine_root .. "/SharedPCH.Sample.h"
        write(header, "typedef int Sample;\n")
        local options = { entry_flags = { "-include", header } }
        local first = run(1, options)
        t.assert_true(first.ok, first.message)
        local pch = ctx.engine_root .. "/.cache/nvim-ue/clangd/pch"
        local before = { rsp = snapshot(pch .. "/SharedPCH.Sample.rsp"), bat = snapshot(pch .. "/build_pch.bat") }
        t.assert_contains(before.rsp.bytes, pch .. "/SharedPCH.Sample.pch")
        t.assert_contains(before.bat.bytes, pch .. "/SharedPCH.Sample.rsp")
        t.assert_nil(before.rsp.bytes:find("-ue-cdb-prepare", 1, true))
        t.assert_nil(before.bat.bytes:find("-ue-cdb-prepare", 1, true))
        local repeated = run(1, options)
        t.assert_true(repeated.ok, repeated.message)
        t.assert_eq(#repeated.detail.published, 0)
        t.assert_true(vim.deep_equal(snapshot(pch .. "/SharedPCH.Sample.rsp"), before.rsp))
        t.assert_true(vim.deep_equal(snapshot(pch .. "/build_pch.bat"), before.bat))
      end)
    end)
  else
    t.skip("transaction PCH integration", "host does not schedule PCH recipe steps")
  end

  t.it("failed promotion restores live pairs; a second rollback failure retains recovery bytes and paths", function()
    fixture(function(ctx, run)
      t.assert_true(run(1).ok)
      local script = ctx.engine_root .. "/rollback_probe.py"
      write(script, [=[
import json, os, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import cdb_transaction as tx
root = Path(sys.argv[2])
active = root / 'compile_commands.json'
stage = root / '.prepare-fault.json'
receipt = Path(str(active) + '.unity-receipt.json')
before = {path: (path.read_bytes(), path.stat().st_mtime_ns)
          for path in (active, receipt, Path(str(active) + '.pipeline-result.json'))}
entries = json.loads(active.read_text())
entries[0]['arguments'].append('-DNEW=1')
stage.write_text(json.dumps(entries))
evidence = json.loads(receipt.read_text())
evidence['fixture_version'] = 2
Path(str(stage) + '.unity-receipt.json').write_text(json.dumps(evidence))
config = dict(stage=str(stage), active=str(active), targets=[str(active)],
              stage_shards=str(root / '.prepare-shards'), shards=str(root / 'shards'),
              stage_manifest=str(root / '.prepare-manifest.json'))
replace = os.replace
recovery_count = 0
for double_failure in (False, True):
    attempts = []
    def fail(source, destination):
        attempts.append((str(source), str(destination)))
        if Path(destination) == active:
            raise OSError('fixture active publication denied')
        if (double_failure and Path(destination) == receipt
                and Path(source).name.startswith('.cdb-rollback-')):
            raise OSError('fixture rollback denied')
        return replace(source, destination)
    os.replace = fail
    try:
        tx.commit(config)
        raise AssertionError('publication must fail')
    except tx.RecoveryRequired as error:
        assert double_failure
        assert len(error.recovery) == 1
        item = error.recovery[0]
        backup = Path(item['backup'])
        assert str(backup) in str(error), 'UI failure must expose the recovery path'
        assert Path(item['destination']) == receipt
        assert backup.is_file() and backup.read_bytes() == before[receipt][0]
        assert backup.stat().st_mtime_ns == before[receipt][1]
        recovery_count += 1
        replace(backup, receipt)
    except OSError:
        assert not double_failure
    finally:
        os.replace = replace
    assert any(Path(dst) == active for _, dst in attempts)
    assert all((path.read_bytes(), path.stat().st_mtime_ns) == saved for path, saved in before.items())
assert recovery_count == 1
print(json.dumps(dict(ok=True, rollback_verified=True, retained_backup_verified=True)))
]=])
      local python = require("utils.platform").resolve_tool({ name = "python", env = { "UE_PYTHON" },
        driver_candidates = function(driver) return driver.python_candidates() end })
      t.assert_true(python.ok)
      local result = vim.system({ python.path, "-B", "-I", script,
        vim.fn.stdpath("config") .. "/tools", ctx.engine_root }, { text = true }):wait()
      t.assert_eq(result.code, 0, result.stderr)
      t.assert_true(vim.json.decode(result.stdout).retained_backup_verified)
    end)
  end)
end)

t.describe("prepare diagnostic compatibility transaction", function()
  local platform = require("utils.platform")
  local selected = require("ue").clangd_cmd()[1]
  local resolved = platform.resolve_tool({ name = "clangd", config_candidates = { selected } })
  local probed, version = false, nil
  if resolved.ok then
    probed, version = pcall(function()
      return vim.system({ resolved.path, "--version" }, { text = true }):wait(5000)
    end)
  end
  local output = probed and ((version.stdout or "") .. (version.stderr or "")) or ""
  if not probed or version.code ~= 0 or not output:match("clangd version 22%.1%.%d+") then
    t.skip("real selected clangd compatibility prepare repeat", "selected clangd 22.1.x unavailable", { native = true })
    return
  end

  t.it("seals one diagnostic option and preserves all published bytes and mtimes on repeat", function()
    fixture(function(ctx, run, restarts)
      require("ue.config").setup({ cdb = { steps = { "clangd_diagnostic_compat.py", "resolve_cdb_paths.py" } } })
      require("ue.cdb.pipeline").set_runtime({ clangd_path = function() return resolved.path end })
      local options = { entry_flags = { "--target=aarch64-none-linux-android23", "-std=c++17", "-Werror" } }
      local source = ctx.engine_root .. "/A.cpp"
      local unity = ctx.engine_root .. "/Module.Fixture.cpp"
      local source_before, unity_before = snapshot(source), snapshot(unity)
      local first, raw = run(1, options)
      t.assert_true(first.ok, first.message)
      t.assert_true(first.detail.changed)
      t.assert_eq(restarts(), 1)
      local flag = "-Wno-error=missing-template-arg-list-after-template-kw"
      local active = vim.json.decode(read(ctx.paths.active_cdb))
      t.assert_eq(#active, 1)
      t.assert_eq(active[1].file, source)
      t.assert_eq(active[1].arguments[2], flag)
      t.assert_true(vim.tbl_contains(active[1].arguments, "-Werror"))
      local original = vim.json.decode(raw)[1]
      t.assert_false(vim.tbl_contains(original.arguments, flag))
      local origin = vim.json.decode(read(ctx.paths.active_cdb .. ".unity-origin.json"))
      local receipt = vim.json.decode(read(ctx.paths.active_cdb .. ".unity-receipt.json"))
      local hash = require("ue.cdb.unity_origin").entry_hash
      t.assert_eq(origin.groups[1].commands[source], hash(original))
      t.assert_eq(receipt.groups[1].commands[source], hash(active[1]))
      t.assert_true(vim.deep_equal(origin.groups[1].dependencies, receipt.groups[1].dependencies))
      t.assert_eq(origin.groups[1].dependencies[unity], vim.fn.sha256(unity_before.bytes))
      local paths = { ctx.paths.active_cdb, ctx.paths.active_cdb .. ".unity-origin.json",
        ctx.paths.active_cdb .. ".unity-receipt.json", ctx.paths.active_cdb .. ".pipeline-result.json",
        ctx.engine_root .. "/compile_commands.partition.json", ctx.paths.cdb_shards_dir .. "/manifest.json",
        ctx.paths.cdb_shards_dir .. "/Android-Fixture-Development.json",
        ctx.engine_root .. "/.cache/nvim-ue/cdb/active/compile_commands.Android-Development.json" }
      local before = {}
      for _, path in ipairs(paths) do before[path] = snapshot(path) end
      local repeated, repeated_raw = run(1, options)
      t.assert_true(repeated.ok, repeated.message)
      t.assert_false(repeated.detail.changed)
      t.assert_eq(#repeated.detail.published, 0)
      t.assert_eq(restarts(), 1, "same compatibility policy must not restart clangd again")
      t.assert_eq(repeated_raw, raw)
      for _, path in ipairs(paths) do t.assert_true(vim.deep_equal(snapshot(path), before[path]), path) end
      t.assert_true(vim.deep_equal(snapshot(source), source_before))
      t.assert_true(vim.deep_equal(snapshot(unity), unity_before))
    end, "Android")
  end)
end)
