local t = require("tests.harness")
t.bootstrap()

t.describe("cross-TU destination proof", function()
  for _, case in ipairs({
    { name = "same USR and body", usr = "usr:expected", body = true, reason = "ok" },
    { name = "different overload", usr = "usr:other", body = true, reason = "identity-conflict" },
    { name = "declaration only", usr = "usr:expected", reason = "definition-not-found" },
    { name = "target edited in flight", usr = "usr:expected", body = true, edit = true, reason = "provider-cancelled" },
  }) do
    t.it(case.name, function()
      local path = vim.fn.tempname() .. ".cpp"
      vim.fn.writefile({ "int body(){return 1;}" }, path)
      local target = { uri = vim.uri_from_fname(path), _position_encoding = "utf-8",
        range = { start = { line = 0, character = 4 }, ["end"] = { line = 0, character = 8 } } }
      local old_adapter = package.loaded["utils.ue_goto.clangd_adapter"]
      local source = vim.api.nvim_get_current_buf()
      local result, target_buf
      package.loaded["utils.ue_goto.clangd_adapter"] = {
        async_clangd_symbol_info = function(bufnr, callback, opts)
          target_buf = bufnr
          t.assert_eq(opts.client_ids[1], 9876, "must restrict to source's verified client")
          t.assert_eq(opts.compile_command_source, path:gsub("\\", "/"))
          t.assert_eq(opts.snapshot.subject.line0, 0)
          t.assert_eq(opts.snapshot.subject.column0, 4)
          if case.edit then vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "int changed;" }) end
          callback({ reason = "ok", usr = case.usr, definitions = case.body and { target } or {} })
        end,
      }
      local ok, err = xpcall(function()
        require("utils.ue_goto.clangd_destination").verify(target, "usr:expected", { 9876 }, function(value)
          result = value
        end)
        t.assert_eq(result.reason, case.reason)
        t.assert_eq(vim.api.nvim_get_current_buf(), source, "proof must not change the active buffer")
        t.assert_eq(vim.api.nvim_buf_is_valid(target_buf), case.edit == true,
          "unused temporary target must be removed, but never discard edits")
      end, debug.traceback)
      package.loaded["utils.ue_goto.clangd_adapter"] = old_adapter
      if target_buf and vim.api.nvim_buf_is_valid(target_buf) then vim.api.nvim_buf_delete(target_buf, { force = true }) end
      vim.fn.delete(path)
      if not ok then error(err) end
    end)
  end

  local platform = require("utils.platform")
  local tool = platform.resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
    driver_candidates = function(driver) return driver.default_clangd_candidates() end })
  if not tool.ok then
    t.skip("real clangd cross-TU proof", tool.reason, { native = true })
    return
  end
  t.it("real clangd proves an out-of-line definition in its own TU", function()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    root = vim.uv.fs_realpath(root):gsub("\\", "/")
    local calls, body, header = root .. "/calls.cpp", root .. "/body.cpp", root .. "/api.h"
    vim.fn.writefile({ "int calculate(int);" }, header)
    vim.fn.writefile({ '#include "api.h"', "int caller(){return calculate(1);}" }, calls)
    vim.fn.writefile({ '#include "api.h"', "int calculate(int x){return x+1;}" }, body)
    local commands = {}
    for _, path in ipairs({ calls, body }) do
      commands[#commands + 1] = { file = path, directory = root, arguments = { "clang++", "-std=c++17", "-c", path } }
    end
    vim.fn.writefile({ vim.json.encode(commands) }, root .. "/compile_commands.json")
    local previous = vim.api.nvim_get_current_buf()
    local bufnr = vim.fn.bufadd(calls)
    vim.fn.bufload(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "cpp"
    local client
    local old_semantic, old_probe, old_notify = package.loaded["utils.ue_goto.semantic_client"], package.loaded["utils.probe"], vim.notify
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end,
      begin_action = function() return { bufnr = bufnr, cursor = vim.api.nvim_win_get_cursor(0), winid = 0 } end,
      discover_toolchain = function() return { index = { readiness = "ready", complete = true } } end,
      snapshot_is_current = function() return true end,
    }
    package.loaded["utils.probe"] = { record = function() end, observe = function() end }
    vim.notify = function() end
    local ok, err = xpcall(function()
      local id = vim.lsp.start({ name = "clangd-cross-tu-fixture",
        cmd = { tool.path, "--background-index", "-j=1", "--log=error", "--compile-commands-dir=" .. root },
        root_dir = root }, { bufnr = bufnr, reuse_client = function() return false end })
      client = vim.lsp.get_client_by_id(id)
      t.assert_true(vim.wait(10000, function() return client.initialized end, 20))
      -- Parse the target to seed compiler-authored index evidence, then close it.
      local seed = vim.fn.bufadd(body)
      vim.fn.bufload(seed)
      vim.bo[seed].filetype = "cpp"
      vim.lsp.buf_attach_client(seed, id)
      local ready
      client:request("textDocument/symbolInfo", { textDocument = { uri = vim.uri_from_fname(body) },
        position = { line = 1, character = 4 } }, function(e, r) ready = not e and r end, seed)
      t.assert_true(vim.wait(10000, function() return ready ~= nil end, 20))
      vim.api.nvim_buf_delete(seed, { force = true })
      local owner, jumps = {}, 0
      local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
        dtrace = function() end, format_jump_msg = function() return "" end,
        jump_to_location = function(target)
          jumps = jumps + 1
          t.assert_eq(vim.uri_to_fname(target.uri):gsub("\\", "/"), body)
          t.assert_eq(target.range.start.line, 1)
          return true
        end,
      })
      vim.api.nvim_win_set_cursor(0, { 2, 20 })
      nav.cpp_definition("calculate", bufnr, calls, "cpp")
      t.assert_true(vim.wait(10000, function() return owner._last_cpp_transaction.result ~= nil end, 20))
      local result = owner._last_cpp_transaction.result
      t.assert_eq(result.state, "resolved", vim.inspect(result))
      t.assert_eq(#result.identity_result.definitions, 0, "source AST cannot see out-of-line body")
      t.assert_eq(result.target_identity_result.usr, result.identity)
      t.assert_eq(#result.target_identity_result.definitions, 1)
      t.assert_eq(jumps, 1)
    end, debug.traceback)
    if client then client:stop(true); vim.wait(1000, function() return client:is_stopped() end, 20) end
    package.loaded["utils.ue_goto.semantic_client"], package.loaded["utils.probe"], vim.notify = old_semantic, old_probe, old_notify
    vim.api.nvim_set_current_buf(previous)
    for _, path in ipairs({ calls, body, header }) do
      local buf = vim.fn.bufnr(path)
      if buf >= 0 then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    end
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)
