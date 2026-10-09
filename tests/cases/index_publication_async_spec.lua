local t = require("tests.harness")
t.bootstrap()
require("ue")
local index = require("ue.index")
local locks = require("ue.file_lock")

local function write(path, bytes)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  assert(file:write(bytes)); assert(file:close())
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a"); file:close()
  return bytes
end

local function snapshot(path)
  return { bytes = read(path), mtime = assert(vim.uv.fs_stat(path)).mtime }
end

t.describe("ordinary publication worker admission", function()
  t.it("small base cannot keep large phase or published CDB reads on the editor loop", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local base, background, published = root .. "/base.json", root .. "/phase.json", root .. "/published.json"
    write(base, "[]"); write(background, "[]"); write(published, "[]")
    local ctx, state = { paths = { semantic_cdb = published } }, { index_artifacts = {} }
    t.assert_false(index.publication_needs_worker(ctx, state, base, background, nil))
    write(background, "[]" .. string.rep(" ", 1100000))
    t.assert_true(index.publication_needs_worker(ctx, state, base, background, nil))
    write(background, "[]")
    write(published, "[]" .. string.rep(" ", 1100000))
    t.assert_true(index.publication_needs_worker(ctx, state, base, background, nil))
    write(published, "[]")
    state.index_artifacts.hot = { semantic_cdb_path = background }
    write(background, "[]" .. string.rep(" ", 1100000))
    t.assert_true(index.publication_needs_worker(ctx, state, base, nil, nil))
    vim.fn.delete(root, "rf")
  end)
end)

local function fixture()
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_ordinary_publication"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root))
  local engine = root .. "/EngineRoot"
  local stage = engine .. "/.cache/nvim-ue/clangd/background-cdb"
  local ctx = { _root = root, engine_root = engine, project_root = root .. "/ProjectRoot", paths = {
    platform_key = "Win64-Ordinary-Publication-Test", index_dir = engine .. "/.cache/nvim-ue/cdb",
    index_state = engine .. "/.cache/nvim-ue/cdb/modules.json", index_queue = engine .. "/.cache/nvim-ue/cdb/queue.json",
    active_index_dir = stage .. "/index", active_index = stage .. "/index/active.idx",
    current_index = stage .. "/index/current.idx", hot_index = stage .. "/index/hot.idx", full_index = stage .. "/index/full.idx",
    semantic_cdb_dir = stage, semantic_cdb = stage .. "/compile_commands.json",
    semantic_current_cdb = stage .. "/current/compile_commands.json",
    semantic_hot_cdb = stage .. "/hot/compile_commands.json", semantic_full_cdb = stage .. "/full/compile_commands.json",
  } }
  vim.fn.mkdir(ctx.project_root, "p")
  local entries = { { directory = root, file = root .. "/A.cpp", arguments = { "clang++", "-c", root .. "/A.cpp" },
    nvim_ue_module_root = root .. "/Module", nvim_ue_members = { root .. "/A.cpp" } } }
  local base, background, marker = engine .. "/compile_commands.json", ctx.paths.semantic_full_cdb, ctx.paths.full_index
  write(root .. "/A.cpp", "int ordinary_publication_fixture;\n")
  write(base, vim.json.encode(entries)); write(background, vim.json.encode(entries))
  write(marker, vim.json.encode({ schema = 1, index_kind = "controlled-background", entry_count = 1 }))
  local state = index.ensure_index_state(ctx)
  state.modules = { ["module:/A"] = { key = "module:/A", name = "A", tier = "core", kind = "module", dirty = false } }
  state.queue, state.index_artifacts, state.index_selection = {}, {}, nil
  local lease = assert(locks.acquire(root .. "/publication.lock"))
  local env = { ctx = ctx, state = state, entries = entries, marker = marker, lease = lease, opts = {
    base_cdb_path = base, background_cdb_path = background, index_kind = "controlled-background",
    completed_at = os.time() - 20, lease = lease, owner_pid = vim.fn.getpid(),
  } }
  function env:run(module)
    local called, reason, result = false, nil, nil
    local started, err = (module or index).finish_publication_async(self.ctx, self.state, "full", self.marker,
      { "module:/A" }, self.opts, function(failure, value)
        called, reason, result = true, failure, value
      end)
    t.assert_true(started, err)
    t.assert_true(vim.wait(20000, function() return called end, 10), "publication callback timed out")
    return reason, result
  end
  function env:cleanup()
    locks.release(self.lease)
    local key = self.ctx.engine_root .. "\31" .. self.ctx.project_root .. "\31" .. self.ctx.paths.platform_key
    index._rt.module_state[key], index._rt.contexts[key] = nil, nil
    vim.fn.delete(self.ctx._root, "rf")
  end
  return env
end

local function with_fixture(fn)
  local env = fixture()
  local ok, err = xpcall(function() fn(env) end, debug.traceback)
  env:cleanup()
  if not ok then error(err) end
end

local function publication_factory()
  local module = {}
  require("ue.index._publication_async")(module, { h = {
    write_json_file = function(path, value) write(path, vim.json.encode(value)); return true end,
    read_json_file = function(path)
      return vim.uv.fs_stat(path) and vim.json.decode(read(path)) or nil
    end,
  } })
  return module
end

local function intercepted(env, act)
  local module = publication_factory()
  local original = vim.system
  vim.system = function(cmd, _, done)
    local request = vim.json.decode(read(cmd[#cmd]))
    t.assert_eq(cmd[1], vim.v.progpath)
    t.assert_contains(table.concat(cmd, " "), "publication_worker.lua")
    act(request, done)
    return { pid = vim.fn.getpid() }
  end
  local ok, reason, result = pcall(function() return env:run(module) end)
  vim.system = original
  if not ok then error(reason) end
  return reason, result
end

t.describe("ordinary publication 独立 worker", function()
  t.it("真实 nvim worker 持有 parent lease 发布，重复 prepare 保持 bytes 与 mtime", function()
    with_fixture(function(env)
      local reason, result = env:run()
      t.assert_eq(reason, nil)
      t.assert_true(result.ok)
      t.assert_true(result.promoted)
      t.assert_true(result.publication.changed)
      t.assert_eq(result.selection.coverage_level, "full")
      t.assert_eq(result.manifest.generation_id, result.generation.generation_id)
      local commands = vim.json.decode(read(env.ctx.paths.semantic_cdb))
      t.assert_eq(#commands, 1)
      t.assert_eq(commands[1].file, env.entries[1].file)
      t.assert_true(vim.deep_equal(commands[1].arguments, env.entries[1].arguments))
      t.assert_eq(commands[1].nvim_ue_members, nil)
      t.assert_eq(locks.owner(env.lease.path).token, env.lease.token)
      local cdb_before, manifest_before = snapshot(env.ctx.paths.semantic_cdb), snapshot(env.marker .. ".manifest.json")
      env.state.index_artifacts.full = result.manifest
      env.opts.completed_at = env.opts.completed_at + 10
      local repeated_reason, repeated = env:run()
      t.assert_eq(repeated_reason, nil)
      t.assert_false(repeated.publication.changed)
      t.assert_true(vim.deep_equal(cdb_before, snapshot(env.ctx.paths.semantic_cdb)))
      t.assert_true(vim.deep_equal(manifest_before, snapshot(env.marker .. ".manifest.json")))
    end)
  end)

  t.it("坏 phase CDB 明确失败且不覆盖 active CDB", function()
    with_fixture(function(env)
      local reason = env:run()
      t.assert_eq(reason, nil)
      local before = snapshot(env.ctx.paths.semantic_cdb)
      write(env.opts.background_cdb_path, "{ invalid CDB")
      local failure, result = env:run()
      t.assert_contains(failure, "controlled background CDB is unreadable")
      t.assert_eq(result, nil)
      t.assert_true(vim.deep_equal(before, snapshot(env.ctx.paths.semantic_cdb)))
    end)
  end)

  t.it("损坏的旧 manifest 可由有效输入修复，后续 prepare 不重写", function()
    with_fixture(function(env)
      write(env.marker .. ".manifest.json", "{ damaged old manifest")
      local reason, result = env:run()
      t.assert_eq(reason, nil)
      t.assert_true(result.ok)
      local manifest = vim.json.decode(read(env.marker .. ".manifest.json"))
      t.assert_eq(manifest.generation_id, result.generation.generation_id)
      local cdb_before, manifest_before = snapshot(env.ctx.paths.semantic_cdb), snapshot(env.marker .. ".manifest.json")
      env.state.index_artifacts.full = result.manifest
      env.opts.completed_at = env.opts.completed_at + 10
      local repeated_reason, repeated = env:run()
      t.assert_eq(repeated_reason, nil)
      t.assert_false(repeated.publication.changed)
      t.assert_true(vim.deep_equal(cdb_before, snapshot(env.ctx.paths.semantic_cdb)))
      t.assert_true(vim.deep_equal(manifest_before, snapshot(env.marker .. ".manifest.json")))
    end)
  end)

  t.it("已有 phase manifest 错 hash 拒绝发布且不返回成功 selection", function()
    with_fixture(function(env)
      local reason, result = env:run()
      t.assert_eq(reason, nil)
      local before = snapshot(env.ctx.paths.semantic_cdb)
      local hot = vim.deepcopy(result.manifest)
      hot.phase, hot.coverage_level, hot.background_cdb_hash = "hot", "hot", string.rep("0", 64)
      env.state.index_artifacts.hot = hot
      local failure, stale = env:run()
      t.assert_contains(failure, "no longer matches its successful manifest")
      t.assert_eq(stale, nil)
      t.assert_true(vim.deep_equal(before, snapshot(env.ctx.paths.semantic_cdb)))
    end)
  end)

  t.it("真实 lease 被替换后 worker 拒绝写 manifest 和 active CDB", function()
    with_fixture(function(env)
      local reason = env:run()
      t.assert_eq(reason, nil)
      local cdb_before, manifest_before = snapshot(env.ctx.paths.semantic_cdb), snapshot(env.marker .. ".manifest.json")
      t.assert_true(locks.release(env.lease))
      env.lease = assert(locks.acquire(env.opts.lease.path))
      local failure, stale = env:run()
      t.assert_contains(failure, "publication lease changed")
      t.assert_eq(stale, nil)
      t.assert_true(vim.deep_equal(cdb_before, snapshot(env.ctx.paths.semantic_cdb)))
      t.assert_true(vim.deep_equal(manifest_before, snapshot(env.marker .. ".manifest.json")))
    end)
  end)

  t.it("没有 writer lease 的真实 worker 不创建发布产物", function()
    with_fixture(function(env)
      env.opts.lease = nil
      local failure, stale = env:run()
      t.assert_contains(failure, "publication lease changed")
      t.assert_eq(stale, nil)
      t.assert_eq(vim.uv.fs_stat(env.ctx.paths.semantic_cdb), nil)
      t.assert_eq(vim.uv.fs_stat(env.marker .. ".manifest.json"), nil)
    end)
  end)

  t.it("parent 收到 worker 成功时重新核对已被替换的 base 输入", function()
    with_fixture(function(env)
      local reason, stale = intercepted(env, function(request, done)
        write(request.output, vim.json.encode({ ok = true, generation = { generation_id = "stale-generation" } }))
        local replacement = env.opts.base_cdb_path .. ".replacement"
        write(replacement, vim.json.encode({ { directory = env.ctx._root, file = "Replaced.cpp", arguments = { "clang++", "-DNEW=1" } } }))
        assert(vim.uv.fs_rename(replacement, env.opts.base_cdb_path))
        done({ code = 0, stderr = "" })
      end)
      t.assert_contains(reason, "publication input changed")
      t.assert_eq(stale, nil)
      t.assert_eq(vim.uv.fs_stat(env.ctx.paths.semantic_cdb), nil)
    end)
  end)

  t.it("worker 成功后 lease 被替换，parent 拒绝交付旧结果", function()
    with_fixture(function(env)
      local failure, stale = intercepted(env, function(request, done)
        write(request.output, vim.json.encode({ ok = true, generation = { generation_id = "stale-generation" } }))
        t.assert_true(locks.release(env.lease))
        env.lease = assert(locks.acquire(env.opts.lease.path))
        done({ code = 0, stderr = "" })
      end)
      t.assert_contains(failure, "publication lease changed before delivery")
      t.assert_eq(stale, nil)
      t.assert_eq(vim.uv.fs_stat(env.ctx.paths.semantic_cdb), nil)
    end)
  end)

  t.it("worker 成功后 lease 被释放，parent 拒绝交付结果", function()
    with_fixture(function(env)
      local failure, stale = intercepted(env, function(request, done)
        write(request.output, vim.json.encode({ ok = true }))
        t.assert_true(locks.release(env.lease))
        done({ code = 0, stderr = "" })
      end)
      t.assert_contains(failure, "publication lease changed before delivery")
      t.assert_eq(stale, nil)
      t.assert_eq(vim.uv.fs_stat(env.ctx.paths.semantic_cdb), nil)
    end)
  end)

  t.it("worker 非零退出明确回调失败而不复用旧发布结果", function()
    with_fixture(function(env)
      local reason, result = env:run()
      t.assert_eq(reason, nil)
      t.assert_true(result.ok)
      local before = snapshot(env.ctx.paths.semantic_cdb)
      local failure, stale = intercepted(env, function(request, done)
        write(request.output, vim.json.encode({ ok = true, generation = { generation_id = "old-generation" } }))
        done({ code = 17, stderr = "synthetic worker process failure" })
      end)
      t.assert_contains(failure, "publication worker failed")
      t.assert_eq(stale, nil)
      t.assert_true(vim.deep_equal(before, snapshot(env.ctx.paths.semantic_cdb)))
    end)
  end)

  t.it("worker 未产出 result 文件仍明确回调失败", function()
    with_fixture(function(env)
      local failure, stale = intercepted(env, function(_, done)
        done({ code = 18, stderr = "worker exited before result" })
      end)
      t.assert_contains(failure, "worker exited before result")
      t.assert_eq(stale, nil)
      t.assert_eq(vim.uv.fs_stat(env.ctx.paths.semantic_cdb), nil)
    end)
  end)

  t.it("取消只终止本 factory 的 worker 并清理文件，迟到回调不交付", function()
    with_fixture(function(env)
      local owned, other = publication_factory(), publication_factory()
      local records, delivered = {}, 0
      local original = vim.system
      vim.system = function(cmd, _, done)
        local path = cmd[#cmd]
        local request = vim.json.decode(read(path))
        local record = { path = path, request = request, done = done, kills = 0 }
        records[#records + 1] = record
        write(request.output, vim.json.encode({ ok = true }))
        return { kill = function(_, signal)
          t.assert_eq(signal, 15)
          record.kills = record.kills + 1
        end }
      end
      local ok, failure = xpcall(function()
        local function start(module, marker)
          local started, err = module.finish_publication_async(env.ctx, env.state, "full", marker,
            { "module:/A" }, env.opts, function() delivered = delivered + 1 end)
          t.assert_true(started, err)
        end
        start(owned, env.marker)
        start(other, env.marker .. ".other")
        owned.cancel_publication_workers()
        t.assert_eq(records[1].kills, 1)
        t.assert_eq(records[2].kills, 0, "其它 factory 的进程不应被终止")
        t.assert_eq(vim.uv.fs_stat(records[1].path), nil)
        t.assert_eq(vim.uv.fs_stat(records[1].request.output), nil)
        t.assert_true(vim.uv.fs_stat(records[2].path) ~= nil)
        t.assert_true(vim.uv.fs_stat(records[2].request.output) ~= nil)
        records[1].done({ code = 0, stderr = "" })
        local drained = false
        vim.schedule(function() drained = true end)
        t.assert_true(vim.wait(1000, function() return drained end, 10))
        t.assert_eq(delivered, 0)
        owned.cancel_publication_workers()
        t.assert_eq(records[1].kills, 1, "重复取消应无副作用")
      end, debug.traceback)
      vim.system = original
      owned.cancel_publication_workers()
      other.cancel_publication_workers()
      if not ok then error(failure) end
    end)
  end)
end)
