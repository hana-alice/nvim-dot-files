local t = require("tests.harness")
t.bootstrap()

local transaction = require("utils.ue_goto.semantic_transaction")

local function loc(path, line)
  return {
    uri = vim.uri_from_fname(path),
    range = { start = { line = line - 1, character = 0 } },
  }
end

t.describe("cpp semantic transaction", function()
  t.it("owns copied snapshot/build/context/entity/index tables", function()
    local snapshot = { bufnr = 0, cursor = { 3, 4 }, document_version = 9, changedtick = 9 }
    local build = { build_fingerprint = "before" }
    local context = { origin_tu = "A.cpp" }
    local entity = { usr = "usr:one" }
    local index = { generation = "g1" }
    local tx = transaction.create({
      snapshot = snapshot,
      build = build,
      context = context,
      entity = entity,
      index = index,
    })

    snapshot.cursor[1] = 99
    build.build_fingerprint = "after"
    context.origin_tu = "B.cpp"
    entity.usr = "usr:two"
    index.generation = "g2"

    t.assert_eq(tx.subject.line, 3)
    t.assert_eq(tx.build.build_fingerprint, "before")
    t.assert_eq(tx.context.origin_tu, "A.cpp")
    t.assert_eq(tx.entity.usr, "usr:one")
    t.assert_eq(tx.index.generation, "g1")
  end)

  t.it("subject role distinguishes declaration, definition, and reference", function()
    local tx = transaction.create({
      snapshot = {
        bufnr = 0,
        cursor = { 3, 4 },
        document_version = 1,
        changedtick = vim.api.nvim_buf_get_changedtick(0),
      },
    })
    local current_path = vim.api.nvim_buf_get_name(0)
    local declaration = loc(current_path, 3)
    local definition = loc(current_path, 8)

    t.assert_eq(transaction.subject_role(tx, declaration, definition), "declaration")
    t.assert_eq(transaction.subject_role(tx, declaration, declaration), "definition")
    t.assert_eq(transaction.subject_role(tx, loc(current_path, 1), definition), "reference")
  end)

  t.it("definition filtering removes current location and declaration but preserves body", function()
    local tx = transaction.create({
      snapshot = {
        bufnr = 0,
        cursor = { 5, 0 },
        document_version = 1,
        changedtick = vim.api.nvim_buf_get_changedtick(0),
      },
    })
    local current_path = vim.api.nvim_buf_get_name(0)
    local declaration = loc(current_path, 5)
    local definition = loc(current_path, 12)
    local filtered = transaction.filter_definition_locations(tx, {
      declaration,
      loc(current_path, 5),
      definition,
    }, declaration)
    t.assert_eq(#filtered, 1)
    t.assert_eq(filtered[1].uri, definition.uri)
    t.assert_eq(filtered[1].range.start.line, 11)
  end)

  t.it("terminal callback is delivered once even if finish is attempted twice", function()
    local tx = transaction.create({
      snapshot = {
        bufnr = 0,
        cursor = { 1, 0 },
        document_version = 1,
        changedtick = vim.api.nvim_buf_get_changedtick(0),
      },
    })
    local delivered = {}
    local first = transaction.finish_once(tx,
      transaction.terminal("unavailable", "provider", "identity-missing"),
      function(result) delivered[#delivered + 1] = result end)
    local second = transaction.finish_once(tx,
      transaction.terminal("resolved", "jump", "unknown"),
      function(result) delivered[#delivered + 1] = result end)

    t.assert_true(first)
    t.assert_false(second)
    t.assert_eq(#delivered, 1)
    t.assert_eq(delivered[1].reason, "identity-missing")
    t.assert_eq(tx.result.reason, "identity-missing")
  end)

  t.it("rejects unknown stage/reason and illegal stale/resolved combinations", function()
    local ok_stage = pcall(function()
      transaction.terminal("unavailable", "bogus", "identity-missing")
    end)
    local ok_reason = pcall(function()
      transaction.terminal("unavailable", "provider", "bogus")
    end)
    local ok_stale = pcall(function()
      transaction.terminal("unavailable", "stale", "identity-missing")
    end)
    local ok_resolved = pcall(function()
      transaction.terminal("resolved", "provider", "unknown")
    end)

    t.assert_false(ok_stage)
    t.assert_false(ok_reason)
    t.assert_false(ok_stale)
    t.assert_false(ok_resolved)

    local protected = transaction.terminal("unavailable", "provider", "provider-timeout", {
      state = "resolved",
      stage = "jump",
      reason = "definition-resolved",
    })
    t.assert_eq(protected.state, "unavailable", "extra evidence must not override protocol state")
    t.assert_eq(protected.stage, "provider")
    t.assert_eq(protected.reason, "provider-timeout")
  end)
end)
