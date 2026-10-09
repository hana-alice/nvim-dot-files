local t = require("tests.harness")
t.bootstrap()
local uv = vim.uv
local inputs = require("ue.cdb.prepare_inputs")
local cache = require("ue.cdb.prepare_cache")

local function write(path, value)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local file = assert(io.open(path, "wb"))
  file:write(type(value) == "string" and value or vim.json.encode(value))
  file:close()
end

local function fixture(body)
  local root = vim.fs.normalize(vim.fn.tempname() .. "-prepare-cache")
  local directory = root .. "/.cache/nvim-ue/cdb"
  local ctx = { engine_root = root, state = { target_platform = "Win64", target = "Fixture",
    target_configuration = "Development" }, paths = { active_cdb = directory .. "/compile_commands.json",
    cdb_shards_dir = directory .. "/shards", index_cdb_dir = directory } }
  local entries = { { directory = root, file = root .. "/Source/A.cpp",
    arguments = { vim.v.progpath, "-I", root .. "/Source", "-c", root .. "/Source/A.cpp" } } }
  write(root .. "/Source/A.cpp", "// one\n")
  write(root .. "/tools/fixture.py", "VALUE = 1\n")
  write(ctx.paths.active_cdb, entries)
  for _, suffix in ipairs({ ".unity-origin.json", ".unity-receipt.json", ".pipeline-result.json" }) do
    write(ctx.paths.active_cdb .. suffix, {})
  end
  write(directory .. "/compile_commands.partition.json", { groups = {} })
  for _, name in ipairs({ "index_current_cdb", "index_hot_cdb", "index_full_cdb", "semantic_cdb" }) do
    ctx.paths[name] = directory .. "/" .. name .. ".json"
    write(ctx.paths[name], entries)
  end
  local config = require("ue.config")
  local previous = vim.deepcopy(config.options())
  config.setup({ cdb = { tools_dir = root .. "/tools" } })
  local request = { ctx = ctx, active = ctx.paths.active_cdb, targets = { ctx.paths.active_cdb },
    require_products = true, tools_dir = root .. "/tools", tools_executables = { vim.v.progpath } }
  local index = require("ue.index")
  local old_summary, old_rt = index.index_status_summary, index._rt
  -- This seam states that fixture generators have finished; input inventory and
  -- native watcher capabilities still run unchanged against real files/tools.
  index.index_status_summary = function() return { status = "idle", queue_count = 0 } end
  index._rt = { timers = {} }
  local ok, err = xpcall(function() body(ctx, request, root) end, debug.traceback)
  cache.stop()
  index.index_status_summary, index._rt = old_summary, old_rt
  config.reset_for_test(); config.setup(previous)
  vim.fn.delete(root, "rf")
  if not ok then error(err) end
end

local function begin(ctx, opts)
  local result
  cache.begin(ctx, opts or { cache_ready = function() return true end }, function(hit) result = hit end)
  t.assert_true(vim.wait(15000, function() return result ~= nil end, 10), "begin timeout")
  return result
end

local function seal(ctx)
  t.assert_false(begin(ctx))
  cache.complete(ctx)
  t.assert_true(vim.wait(15000, function() return cache.status().ready end, 10),
    "seal failed: " .. tostring(cache.status().reason))
  t.assert_true(begin(ctx), "unchanged products must reuse: " .. vim.inspect(cache.status()))
end

t.describe("prepare cache real input evidence", function()
  t.it("collector covers real source, tool, products and detects missing output", function()
    fixture(function(ctx, request)
      local value = inputs.collect(request)
      t.assert_true(value.ok, value.reason)
      t.assert_eq(value.entries, 1)
      t.assert_true(#value.roots > 0)
      t.assert_true(#value.artifacts >= 9)
      for _, artifact in ipairs(value.artifacts) do
        t.assert_true(vim.deep_equal(artifact.identity, vim.json.decode(vim.json.encode(artifact.identity))),
          "identity JSON roundtrip: " .. vim.inspect(artifact))
      end
      os.remove(ctx.paths.index_full_cdb)
      value = inputs.collect(request)
      t.assert_false(value.ok)
      t.assert_match(value.reason, "required product missing")
    end)
  end)

  t.it("collector refuses unexpanded response files and malformed CDB", function()
    fixture(function(ctx, request, root)
      write(ctx.paths.active_cdb, { { directory = root, file = root .. "/Source/A.cpp",
        arguments = { vim.v.progpath, "@build.rsp" } } })
      local value = inputs.collect(request)
      t.assert_false(value.ok)
      t.assert_match(value.reason, "unexpanded response file")
      write(ctx.paths.active_cdb, "{invalid")
      t.assert_false(inputs.collect(request).ok)
    end)
  end)

  t.it("collector watches VFS external contents and refuses unsupported overlays or root budgets", function()
    fixture(function(ctx, request, root)
      local external = vim.fs.normalize(vim.fn.tempname() .. "-prepare-vfs")
      write(external .. "/External.h", "// external\n")
      local overlay = root .. "/overlay.json"
      write(overlay, { roots = { { type = "file", name = "/virtual/External.h",
        ["external-contents"] = external .. "/External.h" } } })
      write(ctx.paths.active_cdb, { { directory = root, file = root .. "/Source/A.cpp",
        arguments = { vim.v.progpath, "-ivfsoverlay", overlay, "-c", root .. "/Source/A.cpp" } } })
      local value = inputs.collect(request)
      vim.fn.delete(external, "rf")
      t.assert_true(value.ok, value.reason)
      t.assert_true(vim.iter(value.roots):any(function(item) return item.path == external end),
        "VFS external contents require their own observed root")
      request.max_roots = 1
      t.assert_match(inputs.collect(request).reason, "watch root budget exceeded")
      request.max_roots = nil
      write(overlay, "version: 0\nroots: []\n")
      t.assert_false(inputs.collect(request).ok, "unproven YAML overlay must fail closed")
    end)
  end)

  local platform = require("utils.platform")
  local python = platform.resolve_tool({ name = "python", env = { "UE_PYTHON" },
    driver_candidates = function(driver) return driver.python_candidates() end })
  local clangd = require("ue").clangd_cmd()[1]
  if not python.ok or vim.fn.executable(clangd) ~= 1 or type(platform.driver().input_event_watcher) ~= "function" then
    t.skip("native cache invalidation", "真实 Python/clangd/input_event_watcher 能力不可用", { native = true })
    return
  end

  t.it("native watcher detects source bytes even with size and mtime restored", function()
    fixture(function(ctx, _, root)
      seal(ctx)
      local path = root .. "/Source/A.cpp"
      local before = assert(uv.fs_stat(path))
      write(path, "// two\n")
      assert(uv.fs_utime(path, before.atime.sec + before.atime.nsec / 1e9,
        before.mtime.sec + before.mtime.nsec / 1e9))
      t.assert_eq(uv.fs_stat(path).size, before.size)
      t.assert_false(begin(ctx), "same-size source mutation must revoke cache")
    end)
  end)

  t.it("configuration changes revoke reuse", function()
    fixture(function(ctx)
      seal(ctx)
      ctx.state.target_configuration = "Debug"
      t.assert_false(begin(ctx))
    end)
  end)

  t.it("stopped observation revokes reuse", function()
    fixture(function(ctx)
      seal(ctx)
      cache.stop()
      t.assert_false(begin(ctx))
    end)
  end)

  t.it("overflow notifications revoke reuse", function()
    fixture(function(ctx)
      seal(ctx)
      -- Native overflow cannot be manufactured reliably without stressing the
      -- host; use the public notification entrypoint, never a fake watcher.
      cache.invalidate("watch-overflow")
      t.assert_false(begin(ctx))
    end)
  end)

  t.it("missing and corrupted published artifacts revoke reuse", function()
    fixture(function(ctx)
      seal(ctx)
      os.remove(ctx.paths.index_full_cdb)
      t.assert_false(begin(ctx))
    end)
    fixture(function(ctx)
      seal(ctx)
      write(ctx.paths.index_hot_cdb, "{broken")
      t.assert_false(begin(ctx))
    end)
  end)

  t.it("real tool source edits revoke input evidence", function()
    fixture(function(ctx, _, root)
      seal(ctx)
      write(root .. "/tools/fixture.py", "VALUE = 2\n")
      t.assert_false(begin(ctx))
    end)
  end)
end)
