local t = require("tests.harness")
t.bootstrap()

t.describe("semantic client architecture", function()
  t.it("source capability does not require libclang; header and default still do", function()
    local platform = require("utils.platform")
    local tool = platform.resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
      config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates() })
    if not tool.ok then t.skip("real clangd executable unavailable", tool.reason, { native = true }); return end
    local keys = { "ue", "ue.cdb.paths", "ue.cdb.shards" }
    local saved = {}
    for _, key in ipairs(keys) do saved[key] = package.loaded[key] end
    local old_candidates = platform.libclang_candidates
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    vim.fn.writefile({ "[]" }, root .. "/compile_commands.json")
    package.loaded["ue"] = {
      resolve_context = function() return { engine_root = root, project_root = root, paths = {}, state = {} } end,
      clangd_cmd = function() return { tool.path } end,
    }
    package.loaded["ue.cdb.paths"] = { targets = function() return { root .. "/compile_commands.json" } end }
    package.loaded["ue.cdb.shards"] = {
      read_manifest = function() return nil end,
      shards_dir = function() return root .. "/shards" end,
      active_key = function() return nil end,
      shard_path = function() return nil end,
    }
    platform.libclang_candidates = function() return {} end
    local ok, err = xpcall(function()
      local environment = require("utils.ue_goto.semantic_environment")
      local source = assert(environment.read(0, { route = "source" }))
      t.assert_eq(source.clangd_path, vim.fs.normalize(tool.path))
      t.assert_nil(source.libclang_path)
      local header, why = environment.read(0, { route = "header" })
      t.assert_nil(header)
      t.assert_contains(why, "libclang")
      t.assert_nil(environment.read(0))
    end, debug.traceback)
    for _, key in ipairs(keys) do package.loaded[key] = saved[key] end
    platform.libclang_candidates = old_candidates
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)

  t.it("distinguishes environment generation changes from compiler replacements", function()
    local environment = require("utils.ue_goto.semantic_environment")
    local first = { clangd_path = "clangd-a", libclang_path = "libclang-a", build_fingerprint = "one" }
    t.assert_eq(environment.transition(first, vim.deepcopy(first)), "reuse")
    local generation = vim.tbl_extend("force", first, { build_fingerprint = "two" })
    t.assert_eq(environment.transition(first, generation), "evict")
    local compiler = vim.tbl_extend("force", generation, { clangd_path = "clangd-b" })
    t.assert_eq(environment.transition(generation, compiler), "restart")
  end)

  t.it("binds actual compiler identity and rejects a different handshake toolchain", function()
    local session = require("utils.ue_goto.semantic_session")
    local options = { clangd_path = "clangd-a", libclang_path = "libclang-a" }
    local actual = { clangd_path = "clangd-a", libclang_path = "libclang-a",
      clang_version = "fixture-version", toolchain_identity = "native-identity" }
    local bound = assert(session.bind(options, actual, 3))
    t.assert_eq(bound.generation, 3)
    t.assert_eq(bound.actual.toolchain_identity, "native-identity")
    actual.clangd_path = "clangd-b"
    local rejected, reason = session.bind(options, actual, 4)
    t.assert_nil(rejected)
    t.assert_eq(reason, "compiler-session-toolchain-mismatch")
  end)

  t.it("detects compiler replacement at the same path without rewriting the old snapshot", function()
    local session = require("utils.ue_goto.semantic_session")
    local environment = require("utils.ue_goto.semantic_environment")
    local path = vim.fn.tempname()
    local ok, err = xpcall(function()
      vim.fn.writefile({ "compiler metadata fixture" }, path)
      local before = session.requested({ clangd_path = path })
      before.build_fingerprint = "same-build"
      vim.fn.writefile({ "replacement compiler metadata fixture with different size" }, path)
      local after = session.requested({ clangd_path = path })
      after.build_fingerprint = "same-build"
      t.assert_eq(environment.transition(before, after), "restart")
      t.assert_true(before.compiler_files.clangd.size ~= after.compiler_files.clangd.size)
      local bound, reason = session.bind(before, { clangd_path = path, libclang_path = "libclang",
        toolchain_identity = "native", clang_version = "fixture" }, 1)
      t.assert_nil(bound)
      t.assert_eq(reason, "compiler-session-toolchain-changed")
    end, debug.traceback)
    vim.fn.delete(path)
    if not ok then error(err) end
  end)

  t.it("lets only the facade turn environment changes into eviction or restart", function()
    local runtime_helper = require("utils.ue_goto.semantic_client_runtime")
    local environment = require("utils.ue_goto.semantic_environment")
    local original_install, original_read = runtime_helper.install, environment.read
    local key = "utils.ue_goto.semantic_client"
    local original_client = package.loaded[key]
    local ok, err = xpcall(function()
      local operations = {}
      runtime_helper.install = function(transport)
        transport.status = function() return { running = true } end
        transport.request = function(op) operations[#operations + 1] = op end
        transport.restart = function() operations[#operations + 1] = "restart" end
        transport.cancel_queued_actions = function() end
        return { hash_text = vim.fn.sha256, emit_trace = function() end }
      end
      local current = { clangd_path = "tool-a", build_fingerprint = "gen-a" }
      environment.read = function() return vim.deepcopy(current) end
      package.loaded[key] = nil
      local isolated = require(key)
      isolated.discover_toolchain(0)
      t.assert_eq(#operations, 0)
      current.build_fingerprint = "gen-b"
      isolated.discover_toolchain(0)
      t.assert_eq(operations[1], "evict")
      current.clangd_path = "tool-b"
      isolated.discover_toolchain(0)
      t.assert_eq(operations[2], "restart")
      isolated.discover_toolchain(0)
      t.assert_eq(#operations, 2)
    end, debug.traceback)
    runtime_helper.install, environment.read = original_install, original_read
    package.loaded[key] = original_client
    if not ok then error(err) end
  end)

  t.it("disposes action cleanup exactly once and clears window lineage", function()
    local client = require("utils.ue_goto.semantic_client")
    client._reset_for_test()
    local snapshot = client.begin_action(0)
    local cleaned = 0
    client.set_action_cleanup(snapshot, function() cleaned = cleaned + 1 end)
    client.note_origin(snapshot.winid, { origin_tu = "source.cpp", subject_membership = { "header.h" } }, "build")
    client.dispose()
    client.dispose()
    t.assert_eq(cleaned, 1)
    t.assert_nil(client.window_origin(snapshot.winid, "build"))
    client._reset_for_test()
  end)
end)
