local t = require("tests.harness")
t.bootstrap()
require("ue")
local index = require("ue.index")
local locks = require("ue.file_lock")

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  assert(file:write(value)); assert(file:close())
end

local function read(path)
  local file = assert(io.open(path, "rb"))
  local bytes = file:read("*a"); file:close()
  return bytes
end

local function fixture()
  local root = vim.fs.normalize(vim.fn.tempname()) .. "_publication"
  vim.fn.mkdir(root, "p")
  root = vim.fs.normalize(vim.uv.fs_realpath(root))
  local engine = root .. "/EngineRoot"
  local stage = engine .. "/.cache/nvim-ue/clangd/background-cdb"
  local ctx = { _root = root, engine_root = engine, project_root = root .. "/ProjectRoot", paths = {
    platform_key = "Win64-Publication-Test", index_dir = engine .. "/.cache/nvim-ue/cdb",
    index_state = engine .. "/.cache/nvim-ue/cdb/modules.json", index_queue = engine .. "/.cache/nvim-ue/cdb/queue.json",
    active_index_dir = stage .. "/index", active_index = stage .. "/index/active.idx",
    current_index = stage .. "/index/current.idx", hot_index = stage .. "/index/hot.idx", full_index = stage .. "/index/full.idx",
    semantic_cdb_dir = stage, semantic_cdb = stage .. "/compile_commands.json",
    semantic_current_cdb = stage .. "/current/compile_commands.json",
    semantic_hot_cdb = stage .. "/hot/compile_commands.json", semantic_full_cdb = stage .. "/full/compile_commands.json",
  } }
  vim.fn.mkdir(ctx.project_root, "p")
  local base, source, background, marker = engine .. "/compile_commands.json",
    ctx.paths.semantic_full_cdb .. ".semantic.json", ctx.paths.semantic_full_cdb, ctx.paths.full_index
  local entries = { { directory = root, file = root .. "/A.cpp", arguments = { "clang++", "-c", root .. "/A.cpp" },
    nvim_ue_module_root = root .. "/Module", nvim_ue_members = { root .. "/A.cpp" } } }
  write(root .. "/A.cpp", "int fixture_value;\n")
  write(base, vim.json.encode(entries))
  write(source, vim.json.encode(entries)); write(background, vim.json.encode(entries))
  write(marker, vim.json.encode({ schema = 1, index_kind = "controlled-background", entry_count = 1 }))
  local state = index.ensure_index_state(ctx)
  state.modules = { ["module:/A"] = { key = "module:/A", name = "A", tier = "core", kind = "module", dirty = false } }
  state.queue, state.index_artifacts, state.index_selection = {}, {}, nil
  local generation = index.generation_for_context(ctx, { base_cdb_path = base })
  state.index_artifacts.full = index.make_index_manifest(ctx, state, "full", marker, { "module:/A" }, {
    base_cdb_path = base, background_cdb_path = background, semantic_cdb_path = source,
    index_kind = "controlled-background", completed_at = os.time() - 10,
  })
  index.save_index_state(ctx, state)
  write(marker .. ".manifest.json", vim.json.encode(state.index_artifacts.full))
  local lease = assert(locks.acquire(root .. "/publication.lock"))
  local stat = assert(vim.uv.fs_stat(base))
  local request = { schema = 1, ctx = ctx, base = base,
    base_signature = table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":"),
    generation_id = generation.generation_id, source = source, source_sha256 = vim.fn.sha256(read(source)),
    marker = marker, background = background, publication_result = root .. "/publication-result.json",
    lease = lease, owner_pid = vim.fn.getpid() }
  local env = { ctx = ctx, request = request, lease = lease, entries = entries, path = root .. "/request.json" }
  function env:run()
    write(self.path, vim.json.encode(self.request))
    local child = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l",
      vim.fn.getcwd() .. "/lua/ue/index/batch_publish_worker.lua", self.path }, { text = true }):wait(20000)
    local result = vim.json.decode(read(self.request.publication_result))
    return child, result
  end
  function env:cleanup()
    locks.release(self.lease)
    local key = self.ctx.engine_root .. "\31" .. self.ctx.project_root .. "\31" .. self.ctx.paths.platform_key
    index._rt.module_state[key], index._rt.contexts[key] = nil, nil
    vim.fn.delete(self.ctx._root, "rf")
  end
  return env
end

t.describe("真实隔离后台publication worker", function()
  t.it("真实toolchain generation与parent lease下发布标准original CDB", function()
    local env = fixture()
    local ok, failure = xpcall(function()
      local child, result = env:run()
      t.assert_eq(child.code, 0, child.stderr)
      t.assert_true(result.ok, result.reason)
      t.assert_eq(result.generation_id, env.request.generation_id)
      t.assert_eq(result.scope, env.ctx.paths.semantic_cdb)
      t.assert_eq(result.index_selection.coverage_level, "full")
      t.assert_eq(result.manifest.generation_id, env.request.generation_id)
      t.assert_true(result.publication.changed)
      t.assert_eq(vim.json.decode(read(env.request.marker .. ".manifest.json")).generation_id, env.request.generation_id)
      local commands = vim.json.decode(read(env.ctx.paths.semantic_cdb))
      t.assert_eq(#commands, 1)
      t.assert_eq(commands[1].file, env.entries[1].file)
      t.assert_true(vim.deep_equal(commands[1].arguments, env.entries[1].arguments))
      t.assert_eq(commands[1].nvim_ue_members, nil, "标准CDB不泄露metadata")
      t.assert_eq(vim.fn.sha256(read(env.request.source)), env.request.source_sha256)
      t.assert_eq(locks.owner(env.lease.path).token, env.lease.token)
    end, debug.traceback)
    env:cleanup()
    if not ok then error(failure) end
  end)

  t.it("semantic sha mismatch拒绝且已发布bytes不变", function()
    local env = fixture()
    local ok, failure = xpcall(function()
      local child = env:run()
      t.assert_eq(child.code, 0, child.stderr)
      local before = { read(env.ctx.paths.semantic_cdb), read(env.request.marker .. ".manifest.json") }
      env.request.source_sha256 = string.rep("0", 64)
      local rejected, result = env:run()
      t.assert_true(rejected.code ~= 0)
      t.assert_false(result.ok)
      t.assert_true(result.reason:find("publication semantic input changed", 1, true) ~= nil)
      t.assert_true(vim.deep_equal(before, { read(env.ctx.paths.semantic_cdb), read(env.request.marker .. ".manifest.json") }))
    end, debug.traceback)
    env:cleanup()
    if not ok then error(failure) end
  end)

  t.it("lease被替换拒绝且已发布bytes不变", function()
    local env = fixture()
    local ok, failure = xpcall(function()
      local child = env:run()
      t.assert_eq(child.code, 0, child.stderr)
      local before = { read(env.ctx.paths.semantic_cdb), read(env.request.marker .. ".manifest.json") }
      locks.release(env.lease)
      env.lease = assert(locks.acquire(env.request.lease.path))
      local rejected, result = env:run()
      t.assert_true(rejected.code ~= 0)
      t.assert_false(result.ok)
      t.assert_true(result.reason:find("publication lease changed", 1, true) ~= nil)
      t.assert_true(vim.deep_equal(before, { read(env.ctx.paths.semantic_cdb), read(env.request.marker .. ".manifest.json") }))
    end, debug.traceback)
    env:cleanup()
    if not ok then error(failure) end
  end)
end)
