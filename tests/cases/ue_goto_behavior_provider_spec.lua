local t = require("tests.harness")
t.bootstrap()

t.describe("provider absence and capability evidence", function()
  t.it("attached clients retain unsupported capability evidence", function()
    local old_clients = vim.lsp.get_clients
    local client = {
      id = 71, name = "clangd", supports_method = function() return false end,
      request = function() error("unsupported method must not be dispatched") end,
    }
    vim.lsp.get_clients = function(opts)
      return opts.method and {} or { client }
    end
    local ok, err = xpcall(function()
      local result
      require("utils.ue_goto.provider").async_clangd_symbol_info(0, function(value)
        result = value
      end, { structured = true })
      t.assert_true(vim.wait(1000, function() return result ~= nil end))
      t.assert_eq(result.reason, "provider-method-unsupported")
      t.assert_eq(#result.client_results, 1)
      t.assert_eq(result.client_results[1].client_id, 71)
      t.assert_eq(result.client_results[1].supported, false)
      t.assert_eq(result.client_results[1].status, "unsupported")
    end, debug.traceback)
    vim.lsp.get_clients = old_clients
    if not ok then error(err) end
  end)

  t.it("a client outside the verified identity set cannot hide provider absence", function()
    local old_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function() return { {
      id = 72, name = "clangd", request = function() error("unverified client") end,
    } } end
    local ok, err = xpcall(function()
      local result
      require("utils.ue_goto.provider").async_lsp_request(0, "textDocument/definition", function(value)
        result = value
      end, { structured = true, client_ids = { 71 } })
      t.assert_true(vim.wait(1000, function() return result ~= nil end))
      t.assert_eq(result.reason, "provider-unavailable")
      t.assert_eq(#result.client_results, 0)
      t.assert_eq(#result.locations, 0)
    end, debug.traceback)
    vim.lsp.get_clients = old_clients
    if not ok then error(err) end
  end)

  for _, case in ipairs({
    { name = "missing index", index = {}, reason = "index-provider-not-ready", stage = "index" },
    { name = "stale index", index = { readiness = "stale", freshness = "stale-for-module" },
      reason = "index-stale-for-module", stage = "index" },
    { name = "ready index", index = { readiness = "ready", complete = true },
      reason = "provider-unavailable", stage = "provider" },
    { name = "unsupported capability with missing index", index = {}, unsupported = true,
      reason = "provider-method-unsupported", stage = "provider" },
  }) do
    t.it("source navigation distinguishes " .. case.name, function()
      local old_semantic, old_probe = package.loaded["utils.ue_goto.semantic_client"], package.loaded["utils.probe"]
      local old_clients, old_notify = vim.lsp.get_clients, vim.notify
      local bufnr = vim.api.nvim_get_current_buf()
      local notices, jumps = {}, 0
      package.loaded["utils.ue_goto.semantic_client"] = {
        set_trace = function() end,
        begin_action = function() return { bufnr = bufnr, cursor = vim.api.nvim_win_get_cursor(0), winid = 0 } end,
        discover_toolchain = function() return { index = case.index } end,
        snapshot_is_current = function() return true end,
      }
      package.loaded["utils.probe"] = { record = function() end, observe = function() end }
      vim.lsp.get_clients = function(opts)
        if not case.unsupported or opts.method then return {} end
        return { { id = 71, name = "clangd", supports_method = function() return false end } }
      end
      vim.notify = function(message) notices[#notices + 1] = message end
      local ok, err = xpcall(function()
        local owner = {}
        local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
          dtrace = function() end, format_jump_msg = function() return "" end,
          jump_to_location = function() jumps = jumps + 1; return true end,
        })
        nav.cpp_definition("AllocUniformBuffer", bufnr, "/fixture/source.cpp", "cpp")
        t.assert_true(vim.wait(1000, function() return owner._last_cpp_transaction.result ~= nil end))
        local result = owner._last_cpp_transaction.result
        t.assert_eq(result.state, "unavailable")
        t.assert_eq(result.stage, case.stage)
        t.assert_eq(result.reason, case.reason)
        t.assert_eq(result.provider_result.reason,
          case.unsupported and "provider-method-unsupported" or "provider-unavailable")
        local explanation = table.concat(owner.explain_lines(), "\n")
        t.assert_contains(explanation, "provider_method: textDocument/symbolInfo")
        t.assert_contains(explanation, "provider_reason: " .. result.provider_result.reason)
        t.assert_eq(jumps, 0)
        t.assert_eq(#notices, 1)
        if case.reason == "provider-unavailable" then
          t.assert_contains(notices[1], "clangd is not attached")
          t.assert_contains(notices[1], ":UEDefExplain")
        elseif case.stage == "index" then
          t.assert_contains(notices[1], ":UEPrepare")
        end
      end, debug.traceback)
      package.loaded["utils.ue_goto.semantic_client"], package.loaded["utils.probe"] = old_semantic, old_probe
      vim.lsp.get_clients, vim.notify = old_clients, old_notify
      if not ok then error(err) end
    end)
  end
end)
