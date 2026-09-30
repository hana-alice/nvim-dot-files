local t = require("tests.harness")
t.bootstrap()

-- Protocol ownership checks complement the real-clangd entity matrix: an AST,
-- identity and destination must come from the same responding compiler client.
t.describe("clangd referent evidence ownership", function()
  local transport = require("utils.ue_goto.lsp_transport")
  local referent = require("utils.ue_goto.clangd_referent")

  local function at(line)
    return {
      uri = "file:///fixture/referents.h",
      _position_encoding = "utf-8",
      range = {
        start = { line = line, character = 6 },
        ["end"] = { line = line, character = 12 },
      },
    }
  end
  local alias_a, alias_b, underlying = at(1), at(2), at(3)

  local function identity(usr, declaration)
    return { usr = usr, declarations = declaration and { declaration } or {}, definitions = {} }
  end

  local function symbol_info(rows)
    local result =
      { reason = "identity-conflict", client_results = {}, identities = {}, declarations = {}, definitions = {} }
    local clients_by_usr = {}
    for _, row in ipairs(rows) do
      result.client_results[#result.client_results + 1] = { client_id = row[1], identities = row[2] }
      for _, item in ipairs(row[2]) do
        clients_by_usr[item.usr] = clients_by_usr[item.usr] or {}
        clients_by_usr[item.usr][#clients_by_usr[item.usr] + 1] = row[1]
      end
    end
    for usr, ids in pairs(clients_by_usr) do
      result.identities[#result.identities + 1] = { usr = usr, client_ids = ids }
    end
    return result
  end

  local function ast_for(ids)
    local result = { reason = "ok", client_results = {} }
    for _, id in ipairs(ids) do
      result.client_results[#result.client_results + 1] = {
        client_id = id,
        result = { kind = "Typedef", role = "type" },
      }
    end
    return result
  end

  local function definition(rows, aggregate)
    local result = { reason = "ok", locations = aggregate or { alias_a }, client_results = {} }
    for _, row in ipairs(rows) do
      result.client_results[#result.client_results + 1] = { client_id = row[1], locations = row[2] }
    end
    return result
  end

  local function resolve(input, ast_result, definition_result)
    local old_request, old_definition = transport.request, transport.async_lsp_request
    local calls, output, callbacks = {}, nil, 0
    local current = function()
      return true
    end
    transport.request = function(_, method, callback, opts)
      calls[#calls + 1] = method
      t.assert_eq(method, "textDocument/ast")
      t.assert_eq(opts.is_current, current, "freshness must reach AST transport")
      t.assert_true(ast_result ~= nil, "macro selection must not need AST evidence")
      callback(vim.deepcopy(ast_result))
    end
    transport.async_lsp_request = function(_, method, callback, opts)
      calls[#calls + 1] = method
      t.assert_eq(method, "textDocument/definition")
      t.assert_eq(opts.is_current, current, "freshness must reach destination transport")
      t.assert_true(definition_result ~= nil, "cancelled or invalid AST must not request a destination")
      callback(vim.deepcopy(definition_result))
    end
    local ok, err = xpcall(function()
      referent.resolve(1, vim.deepcopy(input), function(value)
        callbacks = callbacks + 1
        output = value
      end, { structured = true, is_current = current })
      t.assert_eq(callbacks, 1, "each evidence resolution must settle once")
    end, debug.traceback)
    transport.request, transport.async_lsp_request = old_request, old_definition
    if not ok then
      error(err)
    end
    return output, calls
  end

  local function assert_conflict(result)
    t.assert_eq(result.reason, "identity-conflict", vim.inspect(result))
    t.assert_nil(result.usr, "conflicting providers must not acquire one authoritative identity")
    t.assert_nil(result.entity_kind, "unproven referent role must not be promoted")
  end

  t.it("one client's alias identity joins its own unique declaration destination", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a), identity("usr:record", underlying) } },
      }),
      ast_for({ 71 }),
      definition({ { 71, { alias_a } } })
    )
    t.assert_eq(result.reason, "ok")
    t.assert_eq(result.usr, "usr:alias-a")
    t.assert_eq(result.entity_kind, "type-alias")
    t.assert_true(vim.deep_equal(result.client_ids, { 71 }))
    t.assert_eq(#result.definitions, 0, "an alias declaration must not be labelled as a body")
    t.assert_eq(result.declarations[1].range.start.line, 1)
  end)

  t.it("two clients independently proving the same alias may agree", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a), identity("usr:record", underlying) } },
        { 72, { identity("usr:alias-a", alias_a), identity("usr:record", underlying) } },
      }),
      ast_for({ 71, 72 }),
      definition({ { 71, { alias_a } }, { 72, { alias_a } } })
    )
    t.assert_eq(result.reason, "ok")
    t.assert_eq(result.usr, "usr:alias-a")
    t.assert_eq(result.entity_kind, "type-alias")
    t.assert_true(vim.deep_equal(result.client_ids, { 71, 72 }))
  end)

  t.it("one client's identity cannot combine with another client's destination", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a) } },
        { 72, { identity("usr:alias-b", alias_b) } },
      }),
      ast_for({ 71, 72 }),
      definition({ { 71, {} }, { 72, { alias_a } } })
    )
    assert_conflict(result)
  end)

  t.it("different compiler identities at the same declaration position still conflict", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a) } },
        { 72, { identity("usr:alias-b", alias_a) } },
      }),
      ast_for({ 71, 72 }),
      definition({ { 71, { alias_a } }, { 72, { alias_a } } })
    )
    assert_conflict(result)
  end)

  t.it("different destination locations cannot be collapsed into one alias", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a) } },
        { 72, { identity("usr:alias-b", alias_b) } },
      }),
      ast_for({ 71, 72 }),
      definition({ { 71, { alias_a } }, { 72, { alias_b } } }, { alias_a, alias_b })
    )
    assert_conflict(result)
  end)

  t.it("a missing client's definition response does not prove unanimous identity", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a) } },
        { 72, { identity("usr:alias-b", alias_b) } },
      }),
      ast_for({ 71, 72 }),
      definition({ { 71, { alias_a } } })
    )
    assert_conflict(result)
  end)

  t.it("AST evidence from an unrelated client cannot classify the written referent", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a), identity("usr:record", underlying) } },
      }),
      ast_for({ 72 }),
      definition({ { 71, { alias_a } } })
    )
    assert_conflict(result)
  end)

  t.it("a client that disagrees with macro identity prevents macro promotion", function()
    local result, calls = resolve(symbol_info({
      { 71, { identity("c:fixture.h@10@macro@VALUE") } },
      { 72, { identity("usr:ordinary", alias_a) } },
    }))
    assert_conflict(result)
    t.assert_eq(#calls, 0)
  end)

  t.it("different macro identities cannot be resolved by response order", function()
    local result, calls = resolve(symbol_info({
      { 71, { identity("c:first.h@10@macro@VALUE") } },
      { 72, { identity("c:second.h@20@macro@VALUE") } },
    }))
    assert_conflict(result)
    t.assert_eq(#calls, 0)
  end)

  t.it("unanimous macro identity survives extra expansion identities", function()
    local result, calls = resolve(symbol_info({
      { 71, { identity("c:fixture.h@10@macro@VALUE"), identity("usr:record", underlying) } },
      { 72, { identity("c:fixture.h@10@macro@VALUE"), identity("usr:record", underlying) } },
    }))
    t.assert_eq(result.reason, "ok")
    t.assert_eq(result.usr, "c:fixture.h@10@macro@VALUE")
    t.assert_eq(result.entity_kind, "macro")
    t.assert_true(vim.deep_equal(result.client_ids, { 71, 72 }))
    t.assert_eq(#calls, 0)
  end)

  t.it("cancelled AST cannot trigger a definition request or successful selection", function()
    local result, calls = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a), identity("usr:record", underlying) } },
      }),
      { reason = "provider-cancelled", client_results = {} }
    )
    t.assert_eq(result.reason, "provider-cancelled")
    t.assert_nil(result.usr)
    t.assert_true(vim.deep_equal(calls, { "textDocument/ast" }))
  end)

  t.it("cancelled destination cannot turn previously valid AST evidence into success", function()
    local result = resolve(
      symbol_info({
        { 71, { identity("usr:alias-a", alias_a), identity("usr:record", underlying) } },
      }),
      ast_for({ 71 }),
      { reason = "provider-cancelled", client_results = {} }
    )
    t.assert_eq(result.reason, "provider-cancelled")
    t.assert_nil(result.usr)
  end)
end)
