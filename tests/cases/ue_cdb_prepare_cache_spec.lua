local t = require("tests.harness")
t.bootstrap()
local uv = vim.uv
local inputs = require("ue.cdb.prepare_inputs")
local cache = require("ue.cdb.prepare_cache")
local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local clangd = require("ue").clangd_cmd()[1]
local compiler
for _, candidate in ipairs(libclang.sibling_clang_candidates(clangd)) do
  compiler = libclang.resolve_executable(candidate)
  if compiler then break end
end
if not compiler then
  t.skip("prepare cache compiler input evidence", "真实 argv Clang 编译器不可用", { native = true })
  return
end

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
    arguments = { compiler, "-I", root .. "/Source", "-c", root .. "/Source/A.cpp" } } }
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
    "seal failed: " .. vim.inspect(cache.status()))
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
        arguments = { compiler, "@build.rsp" } } })
      local value = inputs.collect(request)
      t.assert_false(value.ok)
      t.assert_match(value.reason, "unexpanded response file")
      write(ctx.paths.active_cdb, "{invalid")
      t.assert_false(inputs.collect(request).ok)
    end)
  end)

  t.it("narrow tool evidence binds used files, directory members and missing identities", function()
    fixture(function(ctx, request, root)
      local external = vim.fs.normalize(vim.fn.tempname() .. "-used-tool-inputs")
      local used = external .. "/include/used.h"
      write(used, "// one\n")
      assert(uv.fs_utime(used, 1000000000, 1000000000))
      write(external .. "/share/unused.bin", "unrelated tool data\n")
      write(external .. "/resource/include/stddef.h", "// builtin\n")
      write(external .. "/resource/include/nested/used.h", "// nested\n")
      write(external .. "/resource/include/nested/unused.h", "// unrelated\n")
      vim.fn.mkdir(external .. "/sysroot", "p")
      local ok, err = xpcall(function()
        write(ctx.paths.active_cdb, {{ directory = root, file = root .. "/Source/A.cpp",
          arguments = { compiler, "--gcc-toolchain=" .. external, "-I", external .. "/include",
            "-include", used, "-include", external .. "/resource/include/nested/used.h",
            "-resource-dir", external .. "/resource", "--sysroot=" .. external .. "/sysroot" } }})
        local value = inputs.collect(request)
        t.assert_true(value.ok, value.reason)
        local bound = {}
        for _, item in ipairs(value.tools) do bound[item.path] = item end
        for _, path in ipairs({ used, external, external .. "/include", external .. "/resource",
          external .. "/resource/include", external .. "/resource/include/stddef.h",
          external .. "/resource/include/nested", external .. "/resource/include/nested/used.h",
          external .. "/sysroot" }) do
          t.assert_true(bound[path] ~= nil, "used tool input missing: " .. path)
        end
        t.assert_true(bound[external .. "/resource/include/nested/unused.h"] ~= nil,
          "unknown implicit header dependency retains conservative protection")
        t.assert_true(bound[external .. "/share/unused.bin"] ~= nil,
          "gcc-toolchain input subtree retains unknown dependency protection")
        local function verify(tools)
          local result
          inputs.verify_tools_async(tools, function(observed) result = observed end)
          t.assert_true(vim.wait(3000, function() return result ~= nil end, 5), "async identity timeout")
          return result
        end
        t.assert_true(verify(value.tools).ok)
        local before = assert(uv.fs_stat(used))
        write(used, "// two\n")
        assert(uv.fs_utime(used, before.atime.sec + before.atime.nsec / 1e9,
          before.mtime.sec + before.mtime.nsec / 1e9))
        t.assert_eq(uv.fs_stat(used).size, before.size)
        t.assert_true(vim.deep_equal(uv.fs_stat(used).mtime, before.mtime), "mtime restored exactly")
        t.assert_false(vim.deep_equal(uv.fs_stat(used).ctime, before.ctime), "native ctime detects the closed byte write")
        t.assert_false(verify({bound[used]}).ok, "same-size/restored-mtime used bytes revoke async proof")
        t.assert_false(inputs.verify_tools({bound[used]}).ok)
        value = inputs.collect(request)
        t.assert_true(value.ok, value.reason)
        write(external .. "/include/new.h", "// new member\n")
        t.assert_false(verify(value.tools).ok, "used directory membership revokes async proof")
        t.assert_false(verify({{path = used, identity = {}}}).ok, "missing identity fields fail closed")
        t.assert_false(verify({{path = used, identity = {ctime = {sec = 0}}}}).ok)
        t.assert_false(verify({}).ok)
        os.remove(used)
        t.assert_false(verify({bound[used]}).ok, "unavailable used file fails closed")
      end, debug.traceback)
      vim.fn.delete(external, "rf")
      if not ok then error(err) end
    end)
  end)

  t.it("collector covers external GCC toolchain paths and refuses unknown path options", function()
    fixture(function(ctx, request, root)
      local external = vim.fs.normalize(vim.fn.tempname() .. "-gcc-toolchain")
      write(external .. "/lib/runtime.h", "// one\n")
      local ok, err = xpcall(function()
        for _, args in ipairs({ { "--gcc-toolchain=" .. external }, { "-gcc-toolchain=" .. external },
          { "--gcc-install-dir=" .. external }, { "--gcc-toolchain", external }, { "-gcc-toolchain", external } }) do
          write(ctx.paths.active_cdb, { { directory = root, file = root .. "/Source/A.cpp",
            arguments = vim.list_extend({ compiler }, args) } })
          local value = inputs.collect(request)
          t.assert_true(value.ok, value.reason)
          t.assert_true(vim.iter(value.roots):any(function(item) return item.path == external end),
            "external toolchain needs a recursive observed root")
        end
        write(ctx.paths.active_cdb, { { directory = root, file = root .. "/Source/A.cpp",
          arguments = { compiler, "--unknown-toolchain=" .. external } } })
        t.assert_match(inputs.collect(request).reason, "unrecognized path argument")
      end, debug.traceback)
      vim.fn.delete(external, "rf")
      if not ok then error(err) end
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
        arguments = { compiler, "-ivfsoverlay", overlay, "-c", root .. "/Source/A.cpp" } } })
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

  t.it("reseal after writable tool markers preserves readonly evidence and later reuse", function()
    fixture(function(ctx)
      seal(ctx)
      t.assert_true(next(cache.status().readonly_tool_roots or {}) ~= nil)
      local original_system, completed, inventories = vim.system, false, 0
      vim.system = function(command, options, callback)
        local request_path = command[#command]
        local collector = type(request_path) == "string" and request_path:match("%-prepare%-inputs%.json$")
        if collector then
          local file = assert(io.open(request_path, "rb"))
          local request = vim.json.decode(file:read("*a")); file:close()
          if request.require_products then
            inventories = inventories + 1
            return original_system(command, options, function(result)
              callback(result)
              -- collect() schedules its production handling first. This seam
              -- then records that the new seal result has actually been handled;
              -- the ready value retained from seal(ctx) cannot satisfy the wait.
              vim.schedule(function() completed = true end)
            end)
          end
        end
        return original_system(command, options, callback)
      end
      local ok, err = xpcall(function()
        cache.complete(ctx)
        t.assert_true(vim.wait(15000, function() return completed end, 10), "new reseal worker callback missing")
        t.assert_eq(inventories, 1, "actual required-products inventory ran")
        t.assert_true(cache.status().ready, vim.inspect(cache.status()))
        t.assert_eq(cache.status().reason, "unchanged-inputs")
        t.assert_true(begin(ctx), "resealed capsule must remain reusable: " .. vim.inspect(cache.status()))
      end, debug.traceback)
      vim.system = original_system
      if not ok then error(err) end
    end)
  end)

  t.it("closed source write immediately before begin revokes reuse without a settling sleep", function()
    fixture(function(ctx, _, root)
      seal(ctx)
      t.assert_true(next(cache.status().readonly_tool_roots or {}) ~= nil,
        "default installed tools must exercise readonly identity reuse")
      t.assert_true((cache.status().tools_verified or 0) > 0, "reuse must carry verified readonly tools")
      io.write("TOOL_METRIC " .. vim.json.encode({ readonly_roots = cache.status().readonly_tool_roots,
        roots = cache.status().roots, toolchain = cache.status().toolchain, executables = cache.status().executables,
        files = cache.status().tool_files_verified, directories = cache.status().tool_directories_verified,
        identities = cache.status().tools_verified }) .. "\n")
      for i = 1, 5 do
        local started = uv.hrtime()
        t.assert_true(begin(ctx), "unchanged native barrier must reuse")
        t.assert_true((uv.hrtime() - started) / 1e6 < 300, "unchanged prepare must finish below 300 ms")
        t.assert_true(cache.status().last_barrier_ms ~= nil, "reuse must carry a native barrier timing")
        io.write(string.format("BARRIER_METRIC %.3f %.3f\n", cache.status().last_barrier_ms,
          (uv.hrtime() - started) / 1e6))
      end
      -- write() closes the actual source handle. No wait/defer is inserted
      -- between that close and the reuse decision.
      write(root .. "/Source/A.cpp", "// two\n")
      t.assert_false(begin(ctx), "a just-closed input mutation must revoke reuse")
      t.assert_eq(cache.status().last_miss_reason, "input-event")
    end)
  end)

  -- Only the denied marker response and delayed external event delivery are
  -- injected. Actual installed executables, inventories, grouped watches and
  -- metadata/write acknowledgements on every writable root remain native.
  for _, mutation in ipairs({"same-size-restored-mtime", "new-tool-directory-member", "unused-native-event",
    "implicit-nested-header"}) do
    t.it("readonly tool identity rejects " .. mutation .. " even before delayed native events", function()
      fixture(function(ctx, _, root)
        local external = vim.fs.normalize(vim.fn.tempname() .. "-readonly-tool-evidence")
        local path = external .. "/lib/runtime.h"
        write(path, "// one\n")
        assert(uv.fs_utime(path, 1000000000, 1000000000))
        local nested = external .. "/resource/include/nested/used.h"
        write(nested, "// one\n")
        assert(uv.fs_utime(nested, 1000000000, 1000000000))
        local driver = platform.driver()
        local marker = require("utils.platform.watch_barrier_marker")
        local original_create, original_watcher = marker.create, driver.input_event_watcher
        local withheld = 0
        marker.create = function(target, callback)
          if target:sub(1, #external + 1) == external .. "/" then
            callback(false, "CreateFileW failed (Win32 error 5)")
            return false
          end
          return original_create(target, callback)
        end
        driver.input_event_watcher = function(roots)
          local group, err = original_watcher(roots)
          if not group then return nil, err end
          local original_watch = group.watch
          function group:watch(directory, callback, options)
            return original_watch(self, directory, function(event_err, name, events)
              if mutation ~= "unused-native-event" and directory == external and not event_err and name
                and not (events and (events.unknown or events.overflow)) then
                withheld = withheld + 1
                return
              end
              callback(event_err, name, events)
            end, options)
          end
          return group
        end
        local ok, err = xpcall(function()
          write(ctx.paths.active_cdb, {{directory = root, file = root .. "/Source/A.cpp",
            arguments = {compiler, "--gcc-toolchain=" .. external, "-I", external .. "/lib",
              "-resource-dir=" .. external .. "/resource",
              "-include", path, "-c", root .. "/Source/A.cpp"}}})
          seal(ctx)
          t.assert_true(cache.status().readonly_tool_roots[external])
          t.assert_true((cache.status().tools_verified or 0) > 0)
          if mutation == "same-size-restored-mtime" or mutation == "implicit-nested-header" then
            if mutation == "implicit-nested-header" then path = nested end
            local before = assert(uv.fs_stat(path))
            write(path, "// two\n")
            assert(uv.fs_utime(path, before.atime.sec + before.atime.nsec / 1e9,
              before.mtime.sec + before.mtime.nsec / 1e9))
            t.assert_eq(uv.fs_stat(path).size, before.size)
            t.assert_true(vim.deep_equal(uv.fs_stat(path).mtime, before.mtime), "mtime restored exactly")
            t.assert_false(vim.deep_equal(uv.fs_stat(path).ctime, before.ctime), "used file ctime changed")
          elseif mutation == "new-tool-directory-member" then
            write(external .. "/lib/new-shadow-header.h", "// new\n")
          else
            write(external .. "/unrelated.txt", "// still observed\n")
          end
          t.assert_false(begin(ctx), "identity verification must reject before held input events")
          if mutation == "unused-native-event" then
            t.assert_eq(cache.status().last_miss_reason, "input-event", "every native readonly event revokes authority")
          else
            t.assert_contains(cache.status().last_miss_reason, "tool-changed:")
            t.assert_true(withheld > 0, "actual native tool event was withheld to model delayed delivery")
          end
        end, debug.traceback)
        cache.stop()
        marker.create, driver.input_event_watcher = original_create, original_watcher
        vim.fn.delete(external, "rf")
        if not ok then error(err) end
      end)
    end)
  end

  t.it("external toolchain bytes revoke native cache even with size and mtime restored", function()
    fixture(function(ctx, _, root)
      local external = vim.fs.normalize(vim.fn.tempname() .. "-gcc-toolchain")
      local path = external .. "/lib/runtime.h"
      write(path, "// one\n")
      local ok, err = xpcall(function()
        write(ctx.paths.active_cdb, { { directory = root, file = root .. "/Source/A.cpp",
          arguments = { compiler, "--gcc-toolchain=" .. external, "-c", root .. "/Source/A.cpp" } } })
        seal(ctx)
        local before = assert(uv.fs_stat(path))
        write(path, "// two\n")
        assert(uv.fs_utime(path, before.atime.sec + before.atime.nsec / 1e9,
          before.mtime.sec + before.mtime.nsec / 1e9))
        t.assert_eq(uv.fs_stat(path).size, before.size)
        t.assert_false(begin(ctx), "external toolchain mutation must select the complete path")
        t.assert_eq(cache.status().last_miss_reason, "input-event")
      end, debug.traceback)
      cache.stop()
      vim.fn.delete(external, "rf")
      if not ok then error(err) end
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

  t.it("generated Python cache directory events preserve reuse but tool source edits revoke it", function()
    fixture(function(ctx, _, root)
      seal(ctx)
      write(root .. "/tools/__pycache__/fixture.cpython.pyc", "derived cache\n")
      t.assert_true(begin(ctx), "generated cache directory and children are owned output noise")
      write(root .. "/tools/fixture.py", "VALUE = 3\n")
      t.assert_false(begin(ctx), "ignoring generated cache must not hide actual tool source changes")
    end)
  end)

  t.it("split native subscriptions retain input additions and artifact identity while excluding owned staging", function()
    fixture(function(ctx, request, root)
      write(root .. "/.cache/external-input/header.h", "// one\n")
      local value = inputs.collect(request)
      t.assert_true(value.ok, value.reason)
      t.assert_true(vim.iter(value.roots):any(function(item)
        return item.path == root and item.recursive == false
      end), "engine parent must observe new top-level inputs")
      t.assert_true(vim.iter(value.roots):any(function(item)
        return item.path == root .. "/.cache/external-input" and item.recursive == true
      end), "only owned nvim-ue outputs may be excluded")
      t.assert_false(vim.iter(value.roots):any(function(item)
        return item.recursive and (item.path == root or item.path == root .. "/.cache/nvim-ue")
      end), "owned output staging must not fill a recursive ancestor queue")
      seal(ctx)
      for i = 1, 300 do write(root .. "/.cache/nvim-ue/staging/" .. i .. ".tmp", "derived\n") end
      t.assert_true(begin(ctx), "owned staging cannot revoke unchanged inputs: " .. vim.inspect(cache.status()))
      write(root .. "/.cache/external-input/header.h", "// two\n")
      t.assert_false(begin(ctx), "other cache-tree inputs must still revoke reuse")
      seal(ctx)
      write(root .. "/NewInput/Source.h", "// new\n")
      t.assert_false(begin(ctx), "new top-level input subtrees must revoke reuse")
      seal(ctx)
      write(ctx.paths.index_full_cdb, "corrupt published artifact\n")
      t.assert_false(begin(ctx), "excluded outputs remain identity-bound")
    end)
  end)
end)
