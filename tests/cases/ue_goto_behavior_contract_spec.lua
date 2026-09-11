local t = require("tests.harness")
t.bootstrap()

t.describe("semantic action contracts", function()
  t.it("cleanup registrations compose and completed work can unregister", function()
    local client = require("utils.ue_goto.semantic_client")
    client._reset_for_test()
    local snapshot = client.begin_action(0)
    local progress, request, completed = 0, 0, 0
    client.set_action_cleanup(snapshot, function() progress = progress + 1 end)
    client.add_action_cleanup(snapshot, function() request = request + 1 end)
    local remove = client.add_action_cleanup(snapshot, function() completed = completed + 1 end)
    remove()
    client.cancel_action()
    client.cancel_action()
    t.assert_eq(progress, 1)
    t.assert_eq(request, 1)
    t.assert_eq(completed, 0)
    client._reset_for_test()
  end)

  t.it("lineage reads cannot mutate stored compiler provenance", function()
    local client = require("utils.ue_goto.semantic_client")
    client._reset_for_test()
    client.note_origin(1, { origin_tu = "/fixture/a.cpp", subject_membership = { ["/fixture/a.h"] = true } }, "build")
    local copy = client.window_origin(1, "build")
    copy.origin_tu = "/fixture/other.cpp"
    copy.subject_membership["/fixture/unproven.h"] = true
    local stored = client.window_origin(1, "build")
    t.assert_eq(stored.origin_tu, "/fixture/a.cpp")
    t.assert_nil(stored.subject_membership["/fixture/unproven.h"])
    client._reset_for_test()
  end)

  t.it("navigation installations do not replace each other's owner", function()
    local old_client, old_notify = package.loaded["utils.ue_goto.semantic_client"], vim.notify
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end, begin_action = function() return { cursor = { 1, 0 } } end,
      discover_toolchain = function() return nil, "fixture environment missing" end,
    }
    vim.notify = function() end
    local ok, err = xpcall(function()
      local module = require("utils.ue_goto.semantic_navigation")
      local a, b = {}, {}
      local deps = { dtrace = function() end, jump_to_location = function() end, format_jump_msg = function() end }
      local first, second = module.install(a, deps), module.install(b, deps)
      first.cpp_definition("a", 0, "/fixture/a.cpp", "cpp")
      t.assert_true(first ~= second)
      t.assert_true(a._last_cpp_transaction ~= nil)
      t.assert_nil(b._last_cpp_transaction)
    end, debug.traceback)
    package.loaded["utils.ue_goto.semantic_client"], vim.notify = old_client, old_notify
    if not ok then error(err) end
  end)

  t.it("resolved results require identity, destination, provider, and metric provenance", function()
    local tx = require("utils.ue_goto.semantic_transaction")
    local evidence = { identity = "usr:f", provider = "libclang", destination_role = "definition",
      location = { uri = "file:///fixture/f.cpp", range = { start = { line = 0, character = 4 } } },
      metrics = { source = "libclang", cold_parse_ms = 5 } }
    for _, key in ipairs({ "identity", "location", "provider", "metrics" }) do
      local missing = vim.deepcopy(evidence)
      missing[key] = nil
      t.assert_false(pcall(tx.terminal, "resolved", "jump", "definition-resolved", missing), key)
    end
    t.assert_eq(tx.terminal("resolved", "jump", "definition-resolved", evidence).identity, "usr:f")
    evidence.destination_role = "declaration"
    t.assert_eq(tx.terminal("resolved", "jump", "index-incomplete", evidence).destination_role, "declaration")
  end)
end)

t.describe("LSP cancellation ownership", function()
  t.it("partial destinations cannot overwrite cancellation with success", function()
    local old_clients = vim.lsp.get_clients
    vim.lsp.get_clients = function() return {
      { id = 1, request = function(_, _, _, cb)
        cb(nil, { uri = "file:///fixture.cpp", range = { start = { line = 0, character = 0 } } })
        return true, 100
      end },
      { id = 2, request = function() return true, 200 end, cancel_request = function() end },
    } end
    local ok, err = xpcall(function()
      local result
      local handle = require("utils.ue_goto.lsp_transport").async_lsp_request(0, "textDocument/definition",
        function(value) result = value end, { structured = true })
      handle.cancel()
      t.assert_true(vim.wait(1000, function() return result ~= nil end))
      t.assert_eq(result.reason, "provider-cancelled")
      t.assert_eq(#result.locations, 0)
    end, debug.traceback)
    vim.lsp.get_clients = old_clients
    if not ok then error(err) end
  end)

  for _, stage in ipairs({ "preparation", "request", "timeout" }) do
    t.it("cancels owned work during " .. stage, function()
      local old_clients, old_defer = vim.lsp.get_clients, vim.defer_fn
      local prepared, timeout, reply, result, unregister = nil, nil, nil, nil, nil
      local sent, cancelled, callbacks = 0, {}, 0
      local current = true
      vim.defer_fn = function(cb)
        timeout = cb
        return { is_closing = function() return false end, stop = function() end, close = function() end }
      end
      vim.lsp.get_clients = function() return { {
        id = 45, name = "fixture", offset_encoding = "utf-16",
        request = function(_, _, _, cb) sent = sent + 1; reply = cb; return true, 731 end,
        cancel_request = function(_, id) cancelled[#cancelled + 1] = id end,
      } } end
      local ok, err = xpcall(function()
        local cancel
        local handle = require("utils.ue_goto.lsp_transport").request(0, "textDocument/definition", function(value)
          callbacks = callbacks + 1; result = value
        end, {
          is_current = function() return current end,
          prepare_client = function(_, _, cb) prepared = cb end,
          register_cancel = function(fn) cancel = fn; return function() unregister = true end end,
        })
        t.assert_type(handle, "table")
        if stage == "preparation" then
          current = false
          prepared(true)
          t.assert_eq(sent, 0)
        else
          prepared(true)
          if stage == "timeout" then timeout() else current = false; cancel() end
          t.assert_eq(cancelled[1], 731)
          reply(nil, {})
        end
        t.assert_true(vim.wait(1000, function() return result ~= nil end))
        t.assert_eq(callbacks, 1)
        t.assert_true(unregister)
        handle.cancel()
        t.assert_true(#cancelled <= 1)
      end, debug.traceback)
      vim.lsp.get_clients, vim.defer_fn = old_clients, old_defer
      if not ok then error(err) end
    end)
  end
end)
