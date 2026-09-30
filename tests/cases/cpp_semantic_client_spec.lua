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
  for _, change in ipairs({ "edit", "save", "new-overlay", "edit-and-save" }) do
    t.it("rejects a changed dependency overlay: " .. change, function()
      client._reset_for_test()
      local root = vim.fn.tempname():gsub("\\", "/")
      local source = vim.api.nvim_get_current_buf()
      local header = vim.api.nvim_create_buf(true, false)
      local old_name, old_ft = vim.api.nvim_buf_get_name(source), vim.bo[source].filetype
      local ok, err = xpcall(function()
        vim.api.nvim_buf_set_name(source, root .. "/source.cpp")
        vim.bo[source].filetype = "cpp"
        vim.api.nvim_buf_set_name(header, root .. "/dependency.h")
        vim.bo[header].filetype = "cpp"
        vim.api.nvim_buf_set_lines(header, 0, -1, false, { "int value();" })
        vim.bo[header].modified = change ~= "new-overlay" and change ~= "edit-and-save"
        local snapshot = client.begin_action(source)
        client.capture_overlays(snapshot, { project_root = root })
        t.assert_true(client.snapshot_is_current(snapshot))
        if change == "save" then
          vim.bo[header].modified = false
        else
          vim.api.nvim_buf_set_lines(header, 0, -1, false, { "long value();" })
          if change == "edit-and-save" then vim.bo[header].modified = false end
        end
        local current, reason = client.snapshot_is_current(snapshot)
        t.assert_false(current)
        t.assert_eq(reason, "overlays-changed")
      end, debug.traceback)
      client._reset_for_test()
      vim.api.nvim_buf_delete(header, { force = true })
      vim.api.nvim_buf_set_name(source, old_name)
      vim.bo[source].filetype = old_ft
      if not ok then error(err) end
    end)
  end

  t.it("direct header definitions reject an index generation changed during resolution", function()
    local old_discover, old_resolve = client.discover_toolchain, client.resolve_header
    local old_index, old_notify = client.index_snapshot_is_current, vim.notify
    local ok, err = xpcall(function()
      client._reset_for_test()
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { "header" })
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local pending, generation_current = nil, true
      client.discover_toolchain = function()
        return { build_fingerprint = "build", index = { generation_id = "old" } }
      end
      client.index_snapshot_is_current = function() return generation_current, "index-generation-changed" end
      client.resolve_header = function(_, callback) pending = callback end
      vim.notify = function() end
      local owner, jumps = {}, 0
      local navigation = require("utils.ue_goto.semantic_navigation").install(owner, {
        dtrace = function() end, format_jump_msg = function() return "jump" end,
        jump_to_location = function() jumps = jumps + 1; return true end,
      })
      navigation.cpp_definition("header", vim.api.nvim_get_current_buf(), "D:/fixture/header.h", "h")
      generation_current = false
      pending({ state = "resolved", definition = { path = "D:/fixture/body.cpp", line = 4, column = 1 } })
      t.assert_eq(jumps, 0)
      t.assert_eq(owner._last_cpp_transaction.result.stage, "stale")
    end, debug.traceback)
    client.discover_toolchain, client.resolve_header = old_discover, old_resolve
    client.index_snapshot_is_current, vim.notify = old_index, old_notify
    client._reset_for_test()
    vim.bo.modified = false
    if not ok then error(err) end
  end)

  t.it("stale header completion cannot replace newer window lineage", function()
    client._reset_for_test()
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { "header" })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    local snapshot = client.begin_action(0)
    local old_request = client.request
    local ok, err = xpcall(function()
      local pending
      client.request = function(_, _, callback) pending = callback end
      client.note_origin(snapshot.winid, {
        origin_tu = "D:/fixture/old.cpp", subject_membership = { "D:/fixture/header.h" },
      }, "build")
      local stale_reason
      client.resolve_header({
        snapshot = snapshot, path = "D:/fixture/header.h", line = 1, column = 1,
        environment = { build_fingerprint = "build", evidence_roots = {} },
      }, function(_, reason) stale_reason = reason end)
      client.cancel_action()
      client.note_origin(snapshot.winid, {
        origin_tu = "D:/fixture/new.cpp", subject_membership = { "D:/fixture/header.h" },
      }, "build")
      pending({ state = "resolved", document_version = snapshot.document_version })
      t.assert_eq(stale_reason, "superseded")
      t.assert_eq(client.window_origin(snapshot.winid, "build").origin_tu, "D:/fixture/new.cpp")
    end, debug.traceback)
    client.request = old_request
    client._reset_for_test()
    vim.bo.modified = false
    if not ok then error(err) end
  end)

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
    client.request = function(op, fields, callback, _, snapshot)
      t.assert_eq(snapshot.document_version, 7)
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
    client.request = function(op, fields, callback, _, snapshot)
      captured = { op = op, fields = fields, snapshot = snapshot }
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
      t.assert_eq(captured.snapshot.document_version, 9)
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
      client.request = function(op, fields, callback, _, request_snapshot)
        t.assert_eq(request_snapshot, snapshot)
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
      t.assert_eq(response.origin_context.origin_tu, "D:/fixture/source_b.cpp")
      t.assert_nil(client.window_origin(snapshot.winid, "build-a", "D:/fixture/header_b.hpp"),
        "resolution must not commit lineage before the coordinator jumps")
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
      t.assert_nil(client.window_origin(vim.api.nvim_get_current_win(), "build-a", "D:/fixture/header_a.hpp"))
      t.assert_eq(response.origin_context.context_id, "ctx-fresh")
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
      t.assert_eq(manifests[1].semantic_cdb_path, manifests[1].background_cdb_path)
      t.assert_true(vim.deep_equal(manifests[1].semantic_identity, manifests[1].background_identity))
      t.assert_eq(manifests[2].phase, "full")
      t.assert_eq(manifests[2].background_cdb_path, vim.fs.normalize(root .. "/full.cdb.json"))
    end, debug.traceback)
    pcall(vim.fn.delete, root, "rf")
    if not ok then error(err) end
  end)

  t.it("rejects a missing or modified split semantic CDB without falling back to background", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_semantic_runtime_split"
    local original_open = io.open
    local ok, err = xpcall(function()
      local ctx = { paths = { current_index = root .. "/current.idx" } }
      local background = root .. "/background.json"
      local semantic = root .. "/native.json"
      local original = '[{"file":"Module.A.cpp"}]'
      local manifest = {
        generation_id = "gen-a", index_kind = "controlled-background",
        phase = "current", coverage_level = "current", index_path = ctx.paths.current_index,
        background_cdb_path = background, semantic_cdb_path = semantic,
        semantic_cdb_hash = vim.fn.sha256(original),
      }
      write_file(ctx.paths.current_index, "current")
      write_file(background, "[]")
      write_file(semantic, original)
      write_file(ctx.paths.current_index .. ".manifest.json", vim.json.encode(manifest))
      local semantic_reads = 0
      io.open = function(path, mode)
        if vim.fs.normalize(path) == vim.fs.normalize(semantic) then semantic_reads = semantic_reads + 1 end
        return original_open(path, mode)
      end
      local discover = client._discover_controlled_phase_manifests_for_test
      local candidates = discover(ctx, "gen-a")
      t.assert_eq(#candidates, 1)
      t.assert_eq(candidates[1].background_cdb_path, vim.fs.normalize(background))
      t.assert_eq(candidates[1].semantic_cdb_path, vim.fs.normalize(semantic))
      t.assert_eq(candidates[1].semantic_identity.hash, manifest.semantic_cdb_hash)
      t.assert_eq(#discover(ctx, "gen-a"), 1)
      t.assert_eq(semantic_reads, 1, "unchanged phase must reuse only the validated signature, not reread the CDB")

      local stat = vim.uv.fs_stat(semantic)
      write_file(semantic, '[{"file":"Module.B.cpp"}]')
      assert(vim.uv.fs_utime(semantic, stat.atime.sec, stat.mtime.sec))
      t.assert_eq(#discover(ctx, "gen-a"), 0, "same-size semantic byte tampering must reject the phase")
      write_file(semantic, original)
      manifest.semantic_cdb_hash = nil
      write_file(ctx.paths.current_index .. ".manifest.json", vim.json.encode(manifest))
      t.assert_eq(#discover(ctx, "gen-a"), 0, "declared semantic path requires a matching hash")
      manifest.semantic_cdb_hash = vim.fn.sha256(original)
      write_file(ctx.paths.current_index .. ".manifest.json", vim.json.encode(manifest))
      assert(vim.uv.fs_unlink(semantic))
      t.assert_eq(#discover(ctx, "gen-a"), 0, "missing native CDB must not use the merged background CDB")
    end, debug.traceback)
    io.open = original_open
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
      local host_driver = require("utils.platform").driver()
      local clangd = root .. "/llvm/bin/clangd" .. tostring(host_driver.exe_suffix or "")
      local libclang = root .. "/llvm/bin/libclang" .. host_driver.shared_library_extension()
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

      local first = assert(require("utils.ue_goto.semantic_environment").read(0))
      t.assert_nil(client.status().build_fingerprint, "reading an environment must not mutate client lifecycle")
      client.discover_toolchain(0)
      t.assert_eq(first.controlled_cdb_path, vim.fs.normalize(current_background))
      t.assert_eq(first.controlled_manifest_path, vim.fs.normalize(current_index .. ".manifest.json"))

      vim.wait(1100, function() return false end, 1100)
      write_file(current_background, '[{"file":"changed.cpp"}]')
      local pure_changed = assert(require("utils.ue_goto.semantic_environment").read(0))
      t.assert_eq(client.status().build_fingerprint, first.build_fingerprint)
      t.assert_true(pure_changed.build_fingerprint ~= first.build_fingerprint)
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

      local semantic_path = root .. "/indices/current.native.json"
      local semantic_content = '[{"file":"Module.A.cpp"}]'
      local split_manifest = {
        generation_id = "gen-a", index_kind = "controlled-background",
        phase = "current", coverage_level = "current", index_path = current_index,
        background_cdb_path = current_background, semantic_cdb_path = semantic_path,
        semantic_cdb_hash = vim.fn.sha256(semantic_content),
      }
      write_file(semantic_path, semantic_content)
      write_file(current_index .. ".manifest.json", vim.json.encode(split_manifest))
      local split = assert(require("utils.ue_goto.semantic_environment").read(0))
      t.assert_eq(split.controlled_cdb_path, vim.fs.normalize(semantic_path))
      t.assert_eq(#split.semantic_cdb_paths, 1)
      t.assert_eq(split.semantic_cdb_paths[1], vim.fs.normalize(semantic_path))
      t.assert_eq(split.controlled_candidates[1].background_cdb_path, vim.fs.normalize(current_background))

      local native_stat = vim.uv.fs_stat(semantic_path)
      local manifest_stat = vim.uv.fs_stat(current_index .. ".manifest.json")
      semantic_content = '[{"file":"Module.B.cpp"}]'
      write_file(semantic_path, semantic_content)
      split_manifest.semantic_cdb_hash = vim.fn.sha256(semantic_content)
      write_file(current_index .. ".manifest.json", vim.json.encode(split_manifest))
      assert(vim.uv.fs_utime(semantic_path, native_stat.atime.sec, native_stat.mtime.sec))
      assert(vim.uv.fs_utime(current_index .. ".manifest.json", manifest_stat.atime.sec, manifest_stat.mtime.sec))
      local changed_split = assert(require("utils.ue_goto.semantic_environment").read(0))
      t.assert_true(split.build_fingerprint ~= changed_split.build_fingerprint,
        "native semantic identity must invalidate caches even with unchanged file sizes and mtime seconds")
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

-- These are protocol state-machine tests. Child startup/IPC is covered separately
-- by real process manager tests; virtual events keep 400ms deadline assertions exact.
local function with_dispatch_events(body)
  local saved = { jobstart = vim.fn.jobstart, chansend = vim.fn.chansend, jobstop = vim.fn.jobstop,
    schedule = vim.schedule, defer = vim.defer_fn, registry = package.loaded["utils.task_registry"] }
  local events = { jobs = {}, writes = {}, timers = {}, scheduled = {}, time = 0, launches = 0 }
  local state = { pending = {}, queued = {}, stdout_tail = "", next_request_id = 0 }
  local isolated, runtime = {}, nil
  vim.schedule = function(callback) events.scheduled[#events.scheduled + 1] = callback end
  vim.defer_fn = function(callback, delay)
    local timer = { callback = callback, deadline = events.time + delay, closed = false }
    function timer:is_closing() return self.closed end
    function timer:stop() self.closed = true end
    function timer:close() self.closed = true end
    events.timers[#events.timers + 1] = timer
    return timer
  end
  package.loaded["utils.task_registry"] = { register = function() end }
  vim.fn.jobstart = function(_, options)
    events.launches = events.launches + 1
    if events.reject_restart and events.launches > 1 then return -1 end
    events.jobs[events.launches] = options
    return events.launches
  end
  vim.fn.chansend = function(job, encoded)
    events.writes[#events.writes + 1] = { job = job, payload = vim.json.decode(encoded) }
    return #encoded
  end
  vim.fn.jobstop = function(job)
    vim.schedule(function() events.jobs[job].on_exit(job, 0) end)
    return 1
  end
  function events.drain()
    local steps = 0
    while #events.scheduled > 0 do
      steps = steps + 1
      assert(steps < 100, "unexpected scheduling loop")
      table.remove(events.scheduled, 1)()
    end
  end
  function events.respond()
    local sent = events.writes[#events.writes]
    local payload, job = sent.payload, sent.job
    events.jobs[job].on_stdout(job, { vim.json.encode({ v = 1, id = payload.id,
      op = payload.op, ok = true, metrics = {}, toolchain = {
        clangd_path = events.jobs[job].env.UE_CLANGD, libclang_path = "protocol-fixture",
        toolchain_identity = "protocol-fixture", clang_version = "protocol-fixture",
      } }), "" })
    events.drain()
  end
  function events.advance(ms)
    events.time = events.time + ms
    for _, timer in ipairs(events.timers) do
      if not timer.closed and timer.deadline <= events.time then
        timer.closed = true
        timer.callback()
      end
    end
    events.drain()
  end
  local ok, err = xpcall(function()
    runtime = require("utils.ue_goto.semantic_client_runtime").install(isolated, {
      protocol = require("utils.ue_goto.semantic_protocol"), state = state,
      uv = setmetatable({ hrtime = function() return events.time * 1000000 end }, { __index = vim.uv }),
      SIDECAR_NAME = "semantic-event-test", REQUEST_TIMEOUT_MS = 400, IDLE_EVICT_MS = 10000,
    })
    body(isolated, events, state)
  end, debug.traceback)
  if runtime then runtime.reset() end
  vim.fn.jobstart, vim.fn.chansend, vim.fn.jobstop = saved.jobstart, saved.chansend, saved.jobstop
  vim.schedule, vim.defer_fn = saved.schedule, saved.defer
  package.loaded["utils.task_registry"] = saved.registry
  if not ok then error(err) end
end

t.describe("cpp semantic client: serialized dispatch", function()
  t.it("a handshake deadline expires without entering the crash-retry path", function()
    with_dispatch_events(function(isolated, events)
      local responses = {}
      for i = 1, 2 do
        isolated.request("stats", {}, function(value) responses[i] = value end,
          { clangd_path = vim.v.progpath })
      end
      events.advance(400) -- no handshake reply has arrived
      t.assert_eq(events.launches, 1)
      t.assert_eq(responses[1].state, "unavailable")
      t.assert_eq(responses[2].state, "unavailable")
      t.assert_false(isolated.status().running)
    end)
  end)

  t.it("drains all requests exactly once when a crashed process cannot restart", function()
    with_dispatch_events(function(isolated, events)
      events.reject_restart = true
      local counts, responses = { 0, 0 }, {}
      for i = 1, 2 do
        isolated.request("stats", {}, function(response)
          counts[i] = counts[i] + 1; responses[i] = response
        end, { clangd_path = vim.v.progpath })
      end
      events.respond() -- handshake dispatches the first queued request
      events.jobs[1].on_exit(1, 7)
      events.drain()
      t.assert_eq(events.launches, 2)
      for i = 1, 2 do
        t.assert_eq(counts[i], 1)
        t.assert_eq(responses[i].state, "unavailable")
      end
      t.assert_eq(isolated.status().pending, 0)
      t.assert_eq(isolated.status().queued, 0)
      t.assert_false(isolated.status().running)
    end)
  end)

  t.it("gives each dispatched request its own deadline and cancels stale queued actions", function()
    with_dispatch_events(function(isolated, events, state)
      local responses, stale_response = {}, nil
      local options = { clangd_path = vim.v.progpath }
      for i = 1, 2 do
        isolated.request("stats", {}, function(response) responses[i] = response end, options)
      end
      local current = true
      isolated.request("stats", {}, function(response) stale_response = response end, options,
        function() return current, "superseded" end)
      current = false
      isolated.cancel_queued_actions()
      events.respond() -- handshake
      local first_pending = next(state.pending)
      events.advance(250)
      events.respond() -- first stats
      t.assert_true(responses[1].ok)
      t.assert_nil(responses[2])
      t.assert_eq(stale_response.reason, "superseded")
      local second_pending = next(state.pending)
      t.assert_true(first_pending ~= second_pending)
      t.assert_eq(state.pending[second_pending].timeout.deadline, 650)
      events.advance(250) -- total queue+execution=500ms, dispatched age=250ms
      t.assert_nil(responses[2])
      events.respond()
      t.assert_true(responses[2].ok)

      local restarted, behind_restart
      isolated.request("stats", {}, function(value) restarted = value end, options)
      isolated.request("stats", {}, function(value) behind_restart = value end, options)
      events.jobs[1].on_exit(1, 7)
      events.drain()
      events.respond() -- restarted handshake
      events.respond() -- retried request
      events.respond() -- request behind retry
      t.assert_true(restarted.ok)
      t.assert_true(behind_restart.ok)

      local old_session = isolated.status().session
      local old_work, new_work
      isolated.request("stats", {}, function(value) old_work = value end, options)
      local replacement = { clangd_path = "protocol-fixture-second-compiler" }
      isolated.restart(replacement)
      isolated.request("stats", {}, function(value) new_work = value end, replacement)
      -- Graceful shutdown was sent after invalidating the old request.
      local old_job = state.job
      events.jobs[old_job].on_exit(old_job, 0)
      events.drain()
      events.respond() -- replacement handshake
      events.respond()
      t.assert_eq(old_work.state, "unavailable")
      t.assert_true(new_work.ok)
      t.assert_true(isolated.status().session.generation > old_session.generation)
      t.assert_eq(isolated.status().session.actual.clangd_path, replacement.clangd_path)
      local wrong_session
      isolated.request("stats", {}, function(value) wrong_session = value end, options)
      events.drain()
      t.assert_eq(wrong_session.reason, "compiler-session-toolchain-mismatch")

      local stopped, queued_at_stop
      isolated.request("stats", {}, function(value) stopped = value end, replacement)
      isolated.request("stats", {}, function(value) queued_at_stop = value end, replacement)
      isolated.stop()
      events.drain()
      t.assert_eq(stopped.state, "unavailable")
      t.assert_eq(queued_at_stop.state, "unavailable")
      t.assert_eq(isolated.status().pending, 0)
      t.assert_eq(isolated.status().queued, 0)
    end)
  end)
end)

t.describe("cpp semantic client: request timeout", function()
  t.it("aborts an unresponsive sidecar instead of leaving future requests queued", function()
    client._reset_for_test()
    t.assert_eq(client.REQUEST_TIMEOUT_MS, 32000,
      "documented 31s cold lookups need 1s of slack without exceeding the 32s live-health budget")
    local job = vim.fn.jobstart({
      vim.v.progpath, "--headless", "-u", "NONE", "-c", "sleep 10", "-c", "qa",
    })
    t.assert_true(job > 0, "fixture sidecar must start")
    client._set_process_for_test(job, true)
    local response
    client._inject_pending_for_test(11, function(value) response = value end)

    t.assert_true(client._expire_pending_for_test(11))
    t.assert_eq(response.state, "unavailable")
    t.assert_eq(response.reason, "semantic sidecar request timed out")
    t.assert_eq(client.status().pending, 0)
    local exit = vim.fn.jobwait({ job }, 1000)[1]
    t.assert_true(exit ~= -1, "timed-out sidecar must be terminated immediately")
    client._reset_for_test()
  end)
end)

t.describe("cpp semantic client: real process manager", function()
  local discovery = require("utils.ue_goto.semantic_sidecar")._discover_toolchain_for_test()
  if not discovery.ok then
    t.skip("sidecar process handshake", discovery.reason, { native = true })
    return
  end

  t.it("rejects an oversized outbound frame promptly and keeps the session usable", function()
    client._reset_for_test()
    local options = { clangd_path = discovery.clangd_path, libclang_path = discovery.libclang_path,
      toolchain_identity = discovery.toolchain_identity }
    local response
    client.request("stats", { padding = string.rep("x", require("utils.ue_goto.semantic_protocol").MAX_LINE_BYTES) },
      function(value) response = value end, options)
    t.assert_true(vim.wait(10000, function() return response ~= nil end, 10), "oversized request must fail before request timeout")
    t.assert_eq(response.reason, "request-too-large")
    local next_response
    client.request("stats", {}, function(value) next_response = value end, options)
    t.assert_true(vim.wait(10000, function() return next_response ~= nil end, 10))
    t.assert_true(next_response.ok)
    client.stop()
    t.assert_true(vim.wait(2000, function() return not client.status().running end, 10))
  end)

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
    t.assert_eq(response.compiler_session.actual.toolchain_identity, discovery.toolchain_identity)
    t.assert_eq(client.status().session.actual.toolchain_identity, discovery.toolchain_identity)
    t.assert_eq(client.status().session.requested.clangd_path, discovery.clangd_path)
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
