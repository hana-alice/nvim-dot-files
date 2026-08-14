local t = require("tests.harness")
t.bootstrap()

local client = require("utils.ue_goto.semantic_client")

local function write_file(path, content)
  local dir = vim.fs.dirname(path)
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  local fd = assert(io.open(path, "wb"))
  fd:write(content)
  fd:close()
end

t.describe("cpp semantic client: request snapshot", function()
  t.it("changedtick 变化后旧响应不能产生 UI side effect", function()
    client._reset_for_test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "call(value);" })
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local snapshot = client.begin_action(0)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "call(other);" })
    vim.bo.modified = false
    local current, reason = client.snapshot_is_current(snapshot, {
      document_version = snapshot.document_version,
    })
    t.assert_false(current)
    t.assert_eq(reason, "document-changed")
  end)

  t.it("光标移动后旧响应不能产生 UI side effect", function()
    client._reset_for_test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "call(value);", "next();" })
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local snapshot = client.begin_action(0)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local current, reason = client.snapshot_is_current(snapshot)
    t.assert_false(current)
    t.assert_eq(reason, "cursor-changed")
  end)

  t.it("后发请求 token 使前一响应 stale", function()
    client._reset_for_test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "call(value);" })
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local first = client.begin_action(0)
    client.begin_action(0)
    local current, reason = client.snapshot_is_current(first)
    t.assert_false(current)
    t.assert_eq(reason, "superseded")
  end)

  t.it("光标移开后再移回仍使旧 token 永久 stale", function()
    client._reset_for_test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "alpha", "beta" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local snapshot = client.begin_action(0)
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = 0 })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local current, reason = client.snapshot_is_current(snapshot)
    t.assert_false(current)
    t.assert_eq(reason, "superseded")
    vim.bo.modified = false
  end)
end)

t.describe("cpp semantic client: context lifecycle", function()
  t.it("窗口选择仅在 build fingerprint 未变化且 header membership 仍成立时复用", function()
    client._reset_for_test()
    local win = vim.api.nvim_get_current_win()
    client.note_origin(win, {
      origin_tu = "D:/fixture/one.cpp",
      context_id = "ctx-a",
      subject_membership = { "D:/fixture/header_a.hpp" },
    }, "build-a")
    t.assert_eq(client.window_origin(win, "build-a", "D:/fixture/header_a.hpp").context_id, "ctx-a")
    t.assert_nil(client.window_origin(win, "build-a", "D:/fixture/header_b.hpp"))
    client.note_origin(win, {
      origin_tu = "D:/fixture/one.cpp",
      context_id = "ctx-a",
    }, "build-a")
    t.assert_nil(client.window_origin(win, "build-a", "D:/fixture/header_b.hpp"))
    t.assert_nil(client.window_origin(win, "build-b"))
  end)

  t.it("source proof binds the exact TU before returning canonical entity identity", function()
    client._reset_for_test()
    local old_request = client.request
    local response
    local ops = {}
    client.request = function(op, fields, callback)
      ops[#ops + 1] = op
      if op == "prove" then
        t.assert_eq(fields.active_cdb_path, "D:/fixture/active.json")
        t.assert_eq(fields.active_manifest_path, "D:/fixture/manifest.json")
        callback({
          state = "resolved",
          context_id = "ctx-source",
          origin_tu = "D:/fixture/source.cpp",
          compile = {
            directory = "D:/fixture",
            file = "D:/fixture/source.cpp",
            argv = { "clang++", "-c", "D:/fixture/source.cpp" },
          },
        })
      else
        t.assert_eq(op, "query")
        t.assert_eq(fields.contexts[1].origin_tu, "D:/fixture/source.cpp")
        callback({
          state = "resolved",
          usr = "usr:source-call",
          declaration = { path = "D:/fixture/api.hpp", line = 4, column = 3 },
        })
      end
    end
    local ok, err = xpcall(function()
      client.prove_source({
        source = "D:/fixture/source.cpp",
        environment = {
          build_fingerprint = "build-a",
          cdb_dir = "D:/fixture",
          cdb_path = "D:/fixture/compile_commands.json",
          active_cdb_path = "D:/fixture/active.json",
          active_manifest_path = "D:/fixture/manifest.json",
        },
        snapshot = { document_version = 7 },
        line = 12,
        column = 8,
      }, function(value) response = value end)
      t.assert_eq(ops[1], "prove")
      t.assert_eq(ops[2], "query")
      t.assert_eq(response.usr, "usr:source-call")
      t.assert_eq(response.origin_context.origin_tu, "D:/fixture/source.cpp")
      t.assert_eq(response.origin_context.context_id, "ctx-source")
      t.assert_eq(response.origin_context.compile.argv[1], "clang++")
    end, debug.traceback)
    client.request = old_request
    if not ok then error(err) end
  end)

  t.it("definition lookup forwards canonical USR to same-generation controlled CDBs in phase order", function()
    client._reset_for_test()
    local old_request = client.request
    local captured
    client.request = function(op, fields, callback)
      captured = { op = op, fields = fields }
      callback({ state = "unavailable", reason = "definition-not-found" })
    end
    local ok, err = xpcall(function()
      client.lookup_definition({
        usr = "c:@F@pick#",
        path = "D:/fixture/Source/Runtime/Sample/Private/caller.cpp",
        snapshot = { document_version = 9 },
        environment = {
          controlled_candidates = {
            { phase = "current", background_cdb_path = "D:/cache/current/compile_commands.json" },
            { phase = "hot", background_cdb_path = "D:/cache/hot/compile_commands.json" },
            { phase = "full", background_cdb_path = "D:/cache/full/compile_commands.json" },
          },
        },
      }, function() end)
      t.assert_eq(captured.op, "lookup-definition")
      t.assert_eq(captured.fields.usr, "c:@F@pick#")
      t.assert_eq(captured.fields.subject,
        "D:/fixture/Source/Runtime/Sample/Private/caller.cpp")
      t.assert_eq(captured.fields.document_version, 9)
      t.assert_eq(#captured.fields.cdb_paths, 3)
      t.assert_contains(captured.fields.cdb_paths[1], "/current/")
      t.assert_contains(captured.fields.cdb_paths[2], "/hot/")
      t.assert_contains(captured.fields.cdb_paths[3], "/full/")
    end, debug.traceback)
    client.request = old_request
    if not ok then error(err) end
  end)

  t.it("header lineage mismatch skips inherited query and re-catalogs directly", function()
    client._reset_for_test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "#include \"header_b.hpp\"" })
    vim.bo.filetype = "cpp"
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local snapshot = client.begin_action(0)
    local ops = {}
    local old_request = client.request
    local ok, err = xpcall(function()
      client.note_origin(vim.api.nvim_get_current_win(), {
        origin_tu = "D:/fixture/source_a.cpp",
        context_id = "ctx-a",
        subject_membership = { "D:/fixture/header_a.hpp" },
      }, "build-a")
      client.request = function(op, fields, callback)
        ops[#ops + 1] = op
        if op == "catalog" then
          callback({
            v = 1,
            id = 1,
            op = "catalog",
            ok = true,
            state = "resolved",
            contexts = {
              {
                id = "ctx-b",
                context_id = "ctx-b",
                origin_tu = "D:/fixture/source_b.cpp",
                cdb_dir = "D:/fixture",
                subject_membership = { "D:/fixture/header_b.hpp" },
              },
            },
          })
        elseif op == "query" then
          t.assert_eq(fields.contexts[1].context_id, "ctx-b")
          callback({
            v = 1,
            id = 2,
            op = "query",
            ok = true,
            state = "resolved",
            context_id = "ctx-b",
            usr = "usr-b",
            declaration = { path = "D:/fixture/header_b.hpp", line = 1, column = 1 },
            definition = { path = "D:/fixture/source_b.cpp", line = 8, column = 1 },
            document_version = snapshot.document_version,
            metrics = {},
          })
        else
          error("unexpected op " .. tostring(op))
        end
      end
      local response
      client.resolve_header({
        path = "D:/fixture/header_b.hpp",
        line = 1,
        column = 1,
        snapshot = snapshot,
        environment = {
          build_fingerprint = "build-a",
          cdb_dir = "D:/fixture",
          active_cdb_path = "D:/fixture/active.json",
          active_manifest_path = "D:/fixture/manifest.json",
          project_root = "D:/fixture",
          engine_root = "D:/fixture",
          active_build_key = "build-a",
          active_build = {},
          evidence_roots = { "D:/fixture/Intermediate/Build" },
        },
      }, function(value) response = value end)
      t.assert_eq(response.state, "resolved")
      t.assert_eq(table.concat(ops, ","), "catalog,query")
    end, debug.traceback)
    client.request = old_request
    if not ok then error(err) end
  end)

  t.it("query-file-not-in-tu revokes inherited lineage and catalogs once", function()
    client._reset_for_test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "#include \"header_a.hpp\"" })
    vim.bo.filetype = "cpp"
    vim.bo.modified = false
    vim.api.nvim_win_set_cursor(0, { 1, 1 })
    local snapshot = client.begin_action(0)
    local ops = {}
    local old_request = client.request
    local ok, err = xpcall(function()
      client.note_origin(vim.api.nvim_get_current_win(), {
        origin_tu = "D:/fixture/source_a.cpp",
        context_id = "ctx-stale",
        subject_membership = { "D:/fixture/header_a.hpp" },
      }, "build-a")
      client.request = function(op, fields, callback)
        ops[#ops + 1] = op .. ":" .. tostring(fields.contexts and fields.contexts[1]
          and fields.contexts[1].context_id or "-")
        if op == "query" and fields.contexts[1].context_id == "ctx-stale" then
          callback({
            v = 1,
            id = 3,
            op = "query",
            ok = true,
            state = "invalid-semantic-context",
            context_id = "ctx-stale",
            reason = "invalid-query-file-not-in-tu",
            diagnostics = { "fixture stale" },
            document_version = snapshot.document_version,
            metrics = {},
          })
        elseif op == "catalog" then
          callback({
            v = 1,
            id = 4,
            op = "catalog",
            ok = true,
            state = "resolved",
            contexts = {
              {
                id = "ctx-fresh",
                context_id = "ctx-fresh",
                origin_tu = "D:/fixture/source_fresh.cpp",
                cdb_dir = "D:/fixture",
                subject_membership = { "D:/fixture/header_a.hpp" },
              },
            },
          })
        elseif op == "query" and fields.contexts[1].context_id == "ctx-fresh" then
          callback({
            v = 1,
            id = 5,
            op = "query",
            ok = true,
            state = "resolved",
            context_id = "ctx-fresh",
            usr = "usr-fresh",
            declaration = { path = "D:/fixture/header_a.hpp", line = 1, column = 1 },
            definition = { path = "D:/fixture/source_fresh.cpp", line = 12, column = 1 },
            document_version = snapshot.document_version,
            metrics = {},
          })
        else
          error("unexpected op " .. tostring(op))
        end
      end
      local response
      client.resolve_header({
        path = "D:/fixture/header_a.hpp",
        line = 1,
        column = 1,
        snapshot = snapshot,
        environment = {
          build_fingerprint = "build-a",
          cdb_dir = "D:/fixture",
          active_cdb_path = "D:/fixture/active.json",
          active_manifest_path = "D:/fixture/manifest.json",
          project_root = "D:/fixture",
          engine_root = "D:/fixture",
          active_build_key = "build-a",
          active_build = {},
          evidence_roots = { "D:/fixture/Intermediate/Build" },
        },
      }, function(value) response = value end)
      t.assert_eq(response.state, "resolved")
      t.assert_eq(table.concat(ops, ","), "query:ctx-stale,catalog:-,query:ctx-fresh")
      t.assert_eq(client.window_origin(vim.api.nvim_get_current_win(), "build-a",
        "D:/fixture/header_a.hpp").context_id, "ctx-fresh")
    end, debug.traceback)
    client.request = old_request
    if not ok then error(err) end
  end)
end)

t.describe("cpp semantic client: runtime controlled manifests", function()
  t.it("discovers same-generation controlled manifests in current/hot/full order", function()
    client._reset_for_test()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_semantic_runtime"
    local ok, err = xpcall(function()
      local ctx = {
        paths = {
          current_index = root .. "/current.idx",
          hot_index = root .. "/hot.idx",
          full_index = root .. "/full.idx",
        },
      }
      write_file(ctx.paths.current_index, "current")
      write_file(ctx.paths.hot_index, "hot")
      write_file(ctx.paths.full_index, "full")
      write_file(root .. "/current.cdb.json", "[]")
      write_file(root .. "/full.cdb.json", "[]")

      write_file(ctx.paths.current_index .. ".manifest.json", vim.json.encode({
        generation_id = "gen-a",
        index_kind = "controlled-background",
        phase = "current",
        coverage_level = "current",
        index_path = ctx.paths.current_index,
        background_cdb_path = root .. "/current.cdb.json",
      }))
      write_file(ctx.paths.hot_index .. ".manifest.json", vim.json.encode({
        generation_id = "gen-a",
        index_kind = "wrong-kind",
        phase = "hot",
        coverage_level = "hot",
        index_path = ctx.paths.hot_index,
        background_cdb_path = root .. "/hot.cdb.json",
      }))
      write_file(ctx.paths.full_index .. ".manifest.json", vim.json.encode({
        generation_id = "gen-a",
        index_kind = "controlled-background",
        phase = "full",
        coverage_level = "full",
        index_path = ctx.paths.full_index,
        background_cdb_path = root .. "/full.cdb.json",
      }))

      local manifests = client._discover_controlled_phase_manifests_for_test(ctx, "gen-a")
      t.assert_eq(#manifests, 2)
      t.assert_eq(manifests[1].phase, "current")
      t.assert_eq(manifests[1].background_cdb_path, vim.fs.normalize(root .. "/current.cdb.json"))
      t.assert_eq(manifests[2].phase, "full")
      t.assert_eq(manifests[2].background_cdb_path, vim.fs.normalize(root .. "/full.cdb.json"))
    end, debug.traceback)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t.it("build fingerprint changes when controlled manifest or cdb signature changes", function()
    client._reset_for_test()
    local saved = {
      ue = package.loaded["ue"],
      cdb_paths = package.loaded["ue.cdb.paths"],
      cdb_shards = package.loaded["ue.cdb.shards"],
    }
    local root = vim.fn.tempname():gsub("\\", "/") .. "_semantic_runtime_fp"
    local ok, err = xpcall(function()
      local clangd = root .. "/llvm/bin/clangd.exe"
      local libclang = root .. "/llvm/bin/libclang.dll"
      local compile_commands = root .. "/engine/compile_commands.json"
      local state_json = root .. "/state/state.json"
      local current_index = root .. "/indices/current.idx"
      local current_background = root .. "/indices/current.background.json"
      write_file(clangd, "")
      write_file(libclang, "")
      write_file(compile_commands, "[]")
      write_file(state_json, "{}")
      write_file(current_index, "current-index")
      write_file(current_background, "[]")
      write_file(current_index .. ".manifest.json", vim.json.encode({
        generation_id = "gen-a",
        index_kind = "controlled-background",
        phase = "current",
        coverage_level = "current",
        index_path = current_index,
        background_cdb_path = current_background,
      }))

      package.loaded["ue"] = {
        resolve_context = function()
          return {
            engine_root = root .. "/engine",
            project_root = root .. "/project",
            state = {
              target_platform = "Win64",
              target_configuration = "Development",
              target = "Editor",
            },
            paths = {
              state = state_json,
              current_index = current_index,
              hot_index = root .. "/indices/hot.idx",
              full_index = root .. "/indices/full.idx",
            },
          }
        end,
        clangd_cmd = function() return { clangd } end,
        semantic_index_snapshot = function()
          return {
            generation_id = "gen-a",
            artifact_fingerprint = "artifact-a",
            coverage_level = "current",
            readiness = "ready",
            freshness = "fresh",
            partial = true,
            complete = false,
          }
        end,
      }
      package.loaded["ue.cdb.paths"] = {
        targets = function() return { compile_commands } end,
      }
      package.loaded["ue.cdb.shards"] = {
        shards_dir = function() return root .. "/shards" end,
        read_manifest = function() return nil end,
        active_key = function() return nil end,
        shard_path = function() return nil end,
      }

      local first = assert(client.discover_toolchain(0))
      t.assert_eq(first.controlled_cdb_path, vim.fs.normalize(current_background))
      t.assert_eq(first.controlled_manifest_path, vim.fs.normalize(current_index .. ".manifest.json"))

      vim.wait(1100, function() return false end, 1100)
      write_file(current_background, '[{"file":"changed.cpp"}]')
      local second = assert(client.discover_toolchain(0))
      t.assert_true(first.build_fingerprint ~= second.build_fingerprint,
        "controlled background cdb size/mtime must affect build fingerprint")

      vim.wait(1100, function() return false end, 1100)
      write_file(current_index .. ".manifest.json", vim.json.encode({
        generation_id = "gen-a",
        index_kind = "controlled-background",
        phase = "current",
        coverage_level = "current",
        index_path = current_index,
        background_cdb_path = current_background,
        tag = "m2",
      }))
      local third = assert(client.discover_toolchain(0))
      t.assert_true(second.build_fingerprint ~= third.build_fingerprint,
        "controlled manifest path/mtime/size must affect build fingerprint")
    end, debug.traceback)
    package.loaded["ue"] = saved.ue
    package.loaded["ue.cdb.paths"] = saved.cdb_paths
    package.loaded["ue.cdb.shards"] = saved.cdb_shards
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)
end)

t.describe("cpp semantic client: unsaved overlays", function()
  t.it("收集 active roots 内 modified C++ buffer 的内容与 document version", function()
    local cfg = vim.fn.stdpath("config")
    local bufnr = vim.api.nvim_create_buf(true, false)
    vim.api.nvim_buf_set_name(bufnr, cfg .. "/tests/fixtures/semantic_overlay.cpp")
    vim.bo[bufnr].filetype = "cpp"
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "void changed();" })
    local version = vim.api.nvim_buf_get_changedtick(bufnr)
    local overlays = client.collect_unsaved_overlays({
      engine_root = cfg,
      project_root = nil,
    })
    local found
    for _, overlay in ipairs(overlays) do
      if overlay.path:match("semantic_overlay%.cpp$") then found = overlay; break end
    end
    t.assert_true(found ~= nil, "modified C++ buffer 应进入 overlay")
    t.assert_eq(found.contents, "void changed();\n")
    t.assert_eq(found.version, version)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)
end)

t.describe("cpp semantic client: NDJSON framing", function()
  t.it("分片 stdout 只在完整行到达后解码", function()
    client._reset_for_test()
    local delivered
    client._inject_pending_for_test(7, function(response) delivered = response end)
    client._consume_stdout_for_test({
      '{"v":1,"id":7,"op":"query","ok":true,"state":"unavail',
    })
    t.assert_nil(delivered)
    client._consume_stdout_for_test({
      'able","reason":"x","metrics":{}}', "",
    })
    vim.wait(1000, function() return delivered ~= nil end)
    t.assert_eq(delivered.state, "unavailable")
  end)
end)

t.describe("cpp semantic client: real process manager", function()
  local discovery = require("utils.ue_goto.semantic_sidecar")._discover_toolchain_for_test()
  if not discovery.ok then
    t.it("SKIP sidecar process handshake when LLVM is unavailable", function()
      io.write("SKIP cpp_semantic_client process: " .. tostring(discovery.reason) .. "\n")
      t.assert_true(true)
    end)
    return
  end

  t.it("starts once, handshakes over NDJSON, and serves a queued request", function()
    client._reset_for_test()
    local response
    client.request("stats", {}, function(value) response = value end, {
      clangd_path = discovery.clangd_path,
      libclang_path = discovery.libclang_path,
      toolchain_identity = discovery.toolchain_identity,
    })
    t.assert_true(vim.wait(10000, function() return response ~= nil end, 10),
      "queued request should complete after handshake")
    t.assert_eq(response.op, "stats")
    t.assert_true(response.ok)
    client.stop()
    t.assert_true(vim.wait(2000, function() return not client.status().running end, 10),
      "stop should wait for the real sidecar exit")
  end)

  t.it("stop during startup drains requests without restarting the sidecar", function()
    client._reset_for_test()
    local response
    client.request("stats", {}, function(value) response = value end, {
      clangd_path = discovery.clangd_path,
      libclang_path = discovery.libclang_path,
      toolchain_identity = discovery.toolchain_identity,
    })
    client.stop()
    t.assert_true(vim.wait(3000, function() return not client.status().running end, 10),
      "stop during startup must terminate the sidecar")
    local status = client.status()
    t.assert_false(status.stopping)
    t.assert_eq(status.pending, 0)
    t.assert_eq(status.queued, 0)
    if response then t.assert_eq(response.state, "unavailable") end
  end)
end)
