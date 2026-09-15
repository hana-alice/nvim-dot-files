local t = require("tests.harness")
t.bootstrap()

t.describe("navigation architecture boundaries", function()
  t.it("a superseded completion cannot replace the latest action report", function()
    local old_semantic, old_notify = package.loaded["utils.ue_goto.semantic_client"], vim.notify
    local callbacks, token = {}, 0
    local bufnr = vim.api.nvim_get_current_buf()
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end,
      begin_action = function()
        token = token + 1
        return { token = token, bufnr = bufnr, cursor = vim.api.nvim_win_get_cursor(0), winid = 0 }
      end,
      discover_toolchain = function() return { index = {} } end,
      snapshot_is_current = function(snapshot) return snapshot.token == token end,
      resolve_header = function(_, cb) callbacks[#callbacks + 1] = cb end,
    }
    vim.notify = function() end
    local ok, err = xpcall(function()
      local owner = {}
      local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
        dtrace = function() end, format_jump_msg = function() return "" end,
        jump_to_location = function() return true end,
      })
      nav.cpp_definition("older", bufnr, "/fixture/api.h", "h")
      nav.cpp_definition("newer", bufnr, "/fixture/api.h", "h")
      local latest = owner._last_cpp_transaction
      callbacks[2]({ state = "resolved", usr = "usr:newer", definition = { path = "/fixture/body.cpp", line = 4, column = 1 } })
      callbacks[1](nil, "superseded")
      t.assert_true(owner._last_cpp_transaction == latest)
      t.assert_eq(latest.result.state, "resolved")
    end, debug.traceback)
    vim.notify, package.loaded["utils.ue_goto.semantic_client"] = old_notify, old_semantic
    if not ok then error(err) end
  end)

  t.it("generic LSP transport needs no UE preparation and preserves references context", function()
    local old_clients = vim.lsp.get_clients
    local old_commands = package.loaded["ue.clangd_commands"]
    local preparations, requests = 0, 0
    package.loaded["ue.clangd_commands"] = { ensure = function() preparations = preparations + 1 end }
    vim.lsp.get_clients = function() return { {
      id = 51, name = "independent-lsp", offset_encoding = "utf-16",
      request = function(_, method, params, cb)
        requests = requests + 1
        t.assert_eq(method, "textDocument/references")
        t.assert_true(params.context.includeDeclaration)
        cb(nil, { { uri = "file:///fixture/ref.cpp", range = { start = { line = 1, character = 2 } } } })
        return true
      end,
    } } end
    local ok, err = xpcall(function()
      local result
      require("utils.ue_goto.lsp_transport").async_lsp_request(0, "textDocument/references", function(value)
        result = value
      end, { structured = true })
      t.assert_true(vim.wait(1000, function() return result ~= nil end))
      t.assert_eq(preparations, 0)
      t.assert_eq(requests, 1)
      t.assert_eq(#result.locations, 1)
    end, debug.traceback)
    vim.lsp.get_clients = old_clients
    package.loaded["ue.clangd_commands"] = old_commands
    if not ok then error(err) end
  end)

  t.it("report formatting creates data without notifying or recording probes", function()
    local report = require("utils.ue_goto.semantic_report")
    local old_notify, old_probe = vim.notify, package.loaded["utils.probe"]
    local effects = 0
    vim.notify = function() effects = effects + 1 end
    package.loaded["utils.probe"] = { record = function() effects = effects + 1 end }
    local ok, err = xpcall(function()
      local result = { state = "unavailable", stage = "entity", reason = "identity-missing" }
      t.assert_contains(report.terminal_notice("f", result), "semantic identity missing")
      t.assert_eq(#report.probes(result, { index = {} }), 2)
      t.assert_eq(effects, 0)
    end, debug.traceback)
    vim.notify, package.loaded["utils.probe"] = old_notify, old_probe
    if not ok then error(err) end
  end)

  t.it("header lineage commits only after a successful destination jump", function()
    local old_semantic = package.loaded["utils.ue_goto.semantic_client"]
    local old_notify = vim.notify
    local bufnr = vim.api.nvim_get_current_buf()
    local commits, jumped = 0, false
    local origin = { origin_tu = "/fixture/origin.cpp", subject_membership = { ["/fixture/api.h"] = true } }
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end,
      begin_action = function() return { bufnr = bufnr, cursor = vim.api.nvim_win_get_cursor(0), winid = 0 } end,
      discover_toolchain = function() return { build_fingerprint = "fixture", index = {} } end,
      snapshot_is_current = function() return true end,
      resolve_header = function(_, cb) cb({ state = "resolved", usr = "usr:f",
        definition = { path = "/fixture/definition.cpp", line = 4, column = 1 }, origin_context = origin }) end,
      note_origin = function(_, context)
        t.assert_true(jumped)
        commits = commits + 1
        t.assert_eq(context.origin_tu, origin.origin_tu)
      end,
    }
    vim.notify = function() end
    local ok, err = xpcall(function()
      local owner, allow = {}, false
      local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
        dtrace = function() end, format_jump_msg = function() return "" end,
        jump_to_location = function() jumped = allow; return allow end,
      })
      nav.cpp_definition("f", bufnr, "/fixture/api.h", "h")
      t.assert_eq(commits, 0)
      t.assert_eq(owner._last_cpp_transaction.result.reason, "jump-failed")
      allow = true
      nav.cpp_definition("f", bufnr, "/fixture/api.h", "h")
      t.assert_eq(commits, 1)
    end, debug.traceback)
    vim.notify, package.loaded["utils.ue_goto.semantic_client"] = old_notify, old_semantic
    if not ok then error(err) end
  end)

  t.it("reload disposes the old client before module eviction", function()
    local path = vim.fn.tempname() .. ".lua"
    vim.fn.writefile({
      'vim.opt.rtp:prepend(vim.fn.getcwd())',
      'local old = {}',
      'local disposed = false',
      'old.dispose = function() assert(package.loaded["utils.ue_goto.semantic_client"] == old); disposed = true end',
      'package.loaded["utils.ue_goto.semantic_client"] = old',
      'require("utils.lsp_fallback")',
      'vim.cmd("UEDefReload")',
      'assert(disposed, "old client was not disposed")',
      'assert(package.loaded["utils.ue_goto.semantic_client"] ~= old)',
      'vim.cmd("qa!")',
    }, path)
    local result = vim.system({ vim.v.progpath, "--headless", "-u", "NONE", "-l", path },
      { cwd = vim.fn.stdpath("config"), text = true }):wait(10000)
    vim.fn.delete(path)
    t.assert_eq(result.code, 0, result.stderr)
  end)

  t.it("disposed references cannot populate quickfix or launch a new GTAGS fallback", function()
    local old_provider, old_symbol = package.loaded["utils.ue_goto.provider"], package.loaded["utils.ue_goto.symbol"]
    local old_ue = package.loaded["ue"]
    local location = require("utils.ue_goto.location")
    local old_quickfix = location.populate_quickfix
    local callbacks, quickfix, gtags = {}, 0, 0
    package.loaded["utils.ue_goto.provider"] = { async_lsp_request = function(_, _, cb) callbacks[#callbacks + 1] = cb end }
    package.loaded["utils.ue_goto.symbol"] = { current_symbol = function() return "f" end }
    package.loaded["ue"] = { gtags_references_async = function() gtags = gtags + 1 end }
    location.populate_quickfix = function() quickfix = quickfix + 1; return true end
    local ok, err = xpcall(function()
      local compat = require("utils.ue_goto.compat_navigation").install({})
      compat.references()
      compat.references()
      compat.dispose()
      callbacks[1]({ { uri = "file:///fixture/f.cpp" } })
      callbacks[2](nil)
      t.assert_eq(quickfix, 0)
      t.assert_eq(gtags, 0)
      compat.references()
      callbacks[3]({ { uri = "file:///fixture/f.cpp" } })
      t.assert_eq(quickfix, 1, "new references retain the existing result behavior")
    end, debug.traceback)
    package.loaded["utils.ue_goto.provider"], package.loaded["utils.ue_goto.symbol"] = old_provider, old_symbol
    package.loaded["ue"], location.populate_quickfix = old_ue, old_quickfix
    if not ok then error(err) end
  end)
end)
