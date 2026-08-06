local t = require("tests.harness")
t.bootstrap()

local client = require("utils.ue_goto.semantic_client")

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
  t.it("窗口选择仅在 build fingerprint 未变化时复用", function()
    client._reset_for_test()
    local win = vim.api.nvim_get_current_win()
    client.note_origin(win, "D:/fixture/one.cpp", "build-a", "ctx-a")
    t.assert_eq(client.window_origin(win, "build-a").context_id, "ctx-a")
    t.assert_nil(client.window_origin(win, "build-b"))
  end)

  t.it("source proof directly carries the origin TU context", function()
    client._reset_for_test()
    local old_request = client.request
    local response
    client.request = function(op, fields, callback)
      t.assert_eq(op, "prove")
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
      }, function(value) response = value end)
      t.assert_eq(response.origin_context.origin_tu, "D:/fixture/source.cpp")
      t.assert_eq(response.origin_context.context_id, "ctx-source")
      t.assert_eq(response.origin_context.compile.argv[1], "clang++")
    end, debug.traceback)
    client.request = old_request
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
