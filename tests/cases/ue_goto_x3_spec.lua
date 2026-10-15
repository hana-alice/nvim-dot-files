local t = require("tests.harness")
t.bootstrap()

local function isolated(names, body)
  local loaded = {}
  for _, name in ipairs(names) do loaded[name] = package.loaded[name] end
  local clients, notify = vim.lsp.get_clients, vim.notify
  local ok, err = xpcall(body, debug.traceback)
  for _, name in ipairs(names) do package.loaded[name] = loaded[name] end
  vim.lsp.get_clients, vim.notify = clients, notify
  if not ok then error(err) end
end

local function reading_fixture(body)
  isolated({ "ue", "utils.ue_goto.reading", "utils.ue_goto.reading_owner", "utils.ue_goto.reading_results",
    "utils.ue_goto.symbol", "utils.ue_goto.provider" }, function()
    local owner = { path = "source-a.cpp", buf = 0, cursor = { 1, 3 }, tick = 7, context = {} }
    local f = { owner = owner, current = true, callbacks = {}, cleanup = {}, notices = {}, locations = {} }
    vim.notify = function(message) f.notices[#f.notices + 1] = message end
    package.loaded["utils.ue_goto.reading_owner"] = {
      begin = function() return owner end,
      current = function() return f.current end,
      add_cleanup = function(_, callback) f.cleanup[#f.cleanup + 1] = callback; return function() end end,
    }
    package.loaded["utils.ue_goto.reading_results"] = {
      items = function(rows) return rows, false end,
      open = function(_, rows) f.locations = rows; return true end,
    }
    package.loaded["utils.ue_goto.symbol"] = { current_symbol = function() return f.symbol or "selected" end }
    package.loaded["utils.ue_goto.provider"] = { async_lsp_request = function(_, _, callback)
      f.callbacks[#f.callbacks + 1] = callback
    end }
    package.loaded.ue = { gtags_references_async = function(_, callback) f.fallback = callback end }
    package.loaded["utils.ue_goto.reading"] = nil
    f.reading = require("utils.ue_goto.reading")
    body(f)
  end)
end

t.describe("X3 references records", function()
  t.it("B1 records the current source immediately and updates failed GTAGS fallback", function()
    reading_fixture(function(f)
      f.reading.references()
      f.callbacks[1]({ locations = { { uri = "file:///fixture/A.cpp", range = { start = { line = 0, character = 0 } } } } })
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "subject=source-a.cpp state=resolved")
      f.owner.path = "source-b.cpp"
      f.reading.references()
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "subject=source-b.cpp state=preparing")
      f.callbacks[2]({ reason = "provider-error", locations = {}, client_results = {
        { client_id = 3, method = "textDocument/references", status = "error", error = { code = -32602, message = "document unavailable" } },
      } })
      f.fallback(false, {}, { error = "backend-unavailable", coverage = "unknown" })
      local explain = table.concat(f.reading.explain_lines(), "\n")
      t.assert_contains(explain, "subject=source-b.cpp state=unavailable")
      t.assert_contains(explain, "backend=GTAGS coverage=unknown provider_reason=provider-error")
      t.assert_contains(explain, "error_code=-32602 error_message=document unavailable")
      t.assert_contains(explain, "backend-unavailable")
      f.reading.references(); f.callbacks[3]({ reason = "token=secret" })
      f.fallback(false, {}, { error = "password=hidden Bearer credential '/private/owner/data'" })
      explain = table.concat(f.reading.explain_lines(), "\n")
      for _, secret in ipairs({ "secret", "hidden", "credential", "/private/owner" }) do
        t.assert_false(explain:find(secret, 1, true))
      end
    end)
  end)

  t.it("B1 records successful fallback, unavailable backend, thrown backend, and missing symbol", function()
    reading_fixture(function(f)
      f.reading.references(); f.callbacks[1]({ reason = "empty" })
      f.fallback(true, { { filename = "fixture/A.cpp", lnum = 2 } })
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "reason=gtags-locations")
      package.loaded.ue = {}
      f.reading.references(); f.callbacks[2]({ reason = "provider-unavailable" })
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "reason=gtags-unavailable")
      package.loaded.ue = { gtags_references_async = function() error("backend failed") end }
      f.reading.references(); f.callbacks[3]({ reason = "empty" })
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "reason=gtags-error")
      f.symbol = ""
      t.assert_false(f.reading.references())
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "reason=symbol-missing")
    end)
  end)

  t.it("B1 stale callbacks cannot overwrite the newer request", function()
    reading_fixture(function(f)
      f.reading.references()
      f.current = false
      f.callbacks[1]({ reason = "provider-error" })
      f.cleanup[1]()
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "reason=stale-request")
      f.current = true; f.owner.path = "new.cpp"
      f.reading.references()
      f.current = false
      f.callbacks[1]({ locations = { {} } })
      t.assert_contains(table.concat(f.reading.explain_lines(), "\n"), "subject=new.cpp state=preparing")
    end)
  end)
end)

local function navigation_fixture(body)
  isolated({ "utils.ue_goto.semantic_client", "ue.clangd_commands", "utils.ue_goto.provider" }, function()
    local buf = vim.api.nvim_create_buf(false, true)
    local path = vim.fs.normalize((vim.env.NVIM_TEST_RUN_ROOT or vim.fn.tempname()) .. "/navigation-x3.cpp")
    vim.api.nvim_buf_set_name(buf, path)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "int selected;" })
    local f = { requests = {}, notices = {}, buf = buf, path = path }
    vim.notify = function(message) f.notices[#f.notices + 1] = message end
    package.loaded["utils.ue_goto.semantic_client"] = {
      set_trace = function() end,
      begin_action = function() return { bufnr = buf, cursor = { 1, 5 }, token = 1 } end,
      discover_toolchain = function() return { project_root = vim.fs.dirname(path), engine_root = vim.fs.dirname(path),
        active_build = { platform = "Android", target = "Client", configuration = "Test" },
        index = { readiness = "ready", complete = true } } end,
      snapshot_is_current = function() return true end,
    }
    package.loaded["ue.clangd_commands"] = { ensure = function(_, _, callback)
      local preparation = f.preparation or (#f.requests > 0 and f.ast_preparation)
      callback(not preparation, preparation)
    end }
    local client = { id = 711, name = "clangd", offset_encoding = "utf-8", supports_method = function() return true end,
      request = function(_, method, _, callback)
        f.requests[#f.requests + 1] = method
        callback(nil, method == "textDocument/ast" and f.ast or {})
        return true
      end }
    vim.lsp.get_clients = function() return { client } end
    package.loaded["utils.ue_goto.provider"] = nil
    local owner = {}
    f.navigation = require("utils.ue_goto.semantic_navigation").install(owner, {
      dtrace = function() end, jump_to_location = function() error("unproven identity must never jump") end,
      format_jump_msg = function() return "" end,
    })
    f.query = function()
      f.navigation.cpp_definition("selected", buf, path, "cpp")
      t.assert_true(vim.wait(1000, function() return owner._last_cpp_transaction.result ~= nil end, 10))
      return owner._last_cpp_transaction.result, table.concat(owner.explain_lines(), "\n")
    end
    local ok, err = xpcall(function() body(f) end, debug.traceback)
    vim.api.nvim_buf_delete(buf, { force = true })
    if not ok then error(err) end
  end)
end

t.describe("X3 preparation and compiler limitations", function()
  t.it("B2 every preparation-error stays unavailable/context with zero compiler requests", function()
    navigation_fixture(function(f)
      for _, reason in ipairs({ "base-compile-database-missing", "compile-command-ambiguous", "frozen-cdb-unverified",
        "compile-command-tool-missing", "header-command-compiler-session-stale", "new-preparation-failure" }) do
        f.preparation = reason
        local result, explain = f.query()
        t.assert_eq(result.state, "unavailable"); t.assert_eq(result.stage, "context")
        t.assert_eq(result.reason, "context-resolution-failed")
        t.assert_eq(result.preparation_reason, reason); t.assert_eq(#f.requests, 0)
        t.assert_contains(explain, "status=preparation-error")
        t.assert_contains(explain, "preparation reason: " .. reason)
        t.assert_contains(f.notices[#f.notices], "编译命令准备失败")
      end
    end)
  end)

  t.it("B3 empty compiler identity keeps semantic refusal but reports dependent AST evidence", function()
    navigation_fixture(function(f)
      f.ast = { kind = "FunctionTemplate", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 30 } },
        children = { { kind = "CXXDependentScopeMember", role = "expression", range = {
          start = { line = 0, character = 3 }, ["end"] = { line = 0, character = 12 },
        } } } }
      local result, explain = f.query()
      t.assert_eq(result.state, "invalid-semantic-context"); t.assert_eq(result.reason, "identity-missing")
      t.assert_eq(result.provider_result.compiler_evidence.kind, "dependent-name")
      t.assert_contains(f.notices[1], "尚未实例化的依赖名")
      t.assert_contains(f.notices[1], "platform=Android target=Client config=Test")
      t.assert_contains(explain, "referent AST client: id=711 method=textDocument/ast status=ok")
      t.assert_eq(f.requests[1], "textDocument/symbolInfo"); t.assert_eq(f.requests[2], "textDocument/ast")
    end)
  end)

  t.it("B2 preparation failure during diagnostic AST remains a context failure", function()
    navigation_fixture(function(f)
      f.ast_preparation = "frozen-cdb-unverified"
      local result, explain = f.query()
      t.assert_eq(result.state, "unavailable"); t.assert_eq(result.stage, "context")
      t.assert_eq(result.preparation_reason, "frozen-cdb-unverified")
      t.assert_eq(#f.requests, 1, "AST must not be sent after failed preparation")
      t.assert_contains(explain, "referent AST client: id=711 method=textDocument/ast status=preparation-error")
    end)
  end)

  t.it("B3 absent AST gives neutral wording and no index rebuild advice", function()
    navigation_fixture(function(f)
      f.query()
      local message = f.notices[1]
      t.assert_contains(message, "可能是未启用分支、宏消去或未实例化的依赖名")
      t.assert_contains(message, ":UEDefExplain")
      t.assert_false(message:find("UEPrepare", 1, true))
    end)
  end)

  t.it("B3 an unrelated dependent child is not evidence for this cursor", function()
    navigation_fixture(function(f)
      f.ast = { kind = "FunctionTemplate", range = { start = { line = 0, character = 0 }, ["end"] = { line = 0, character = 30 } },
        children = { { kind = "CXXDependentScopeMember", range = { start = { line = 0, character = 15 }, ["end"] = { line = 0, character = 25 } } } } }
      local result = f.query()
      t.assert_nil(result.provider_result.compiler_evidence)
      t.assert_contains(f.notices[1], "可能是未启用分支")
    end)
  end)
end)

t.describe("X3 presentation privacy and stable reasons", function()
  local report = require("utils.ue_goto.semantic_report")
  t.it("B4 every participating client exposes bounded sanitized error and preparation details", function()
    local lines = report.provider_lines({ method = "textDocument/symbolInfo", client_results = {
      { client_id = 1, status = "error", error = { code = -32602,
        message = "document failure token=secret Bearer credential 'C:/private/work/file.cpp'\n" .. string.rep("x", 400) } },
      { client_id = 2, method = "textDocument/ast", status = "preparation-error", error = "frozen-cdb-unverified" },
    } })
    local text = table.concat(lines, "\n")
    t.assert_contains(text, "id=1 method=textDocument/symbolInfo status=error error_code=-32602")
    t.assert_contains(text, "id=2 method=textDocument/ast status=preparation-error")
    t.assert_contains(text, "preparation reason: frozen-cdb-unverified")
    t.assert_false(text:find("C:/private", 1, true)); t.assert_false(text:find("secret", 1, true))
    t.assert_false(text:find("credential", 1, true)); t.assert_true(#lines[1] < 500)
  end)

  t.it("B3 specific limitation wording requires structured compiler evidence", function()
    for kind, fragment in pairs({ ["inactive-branch"] = "未启用的分支", ["dependent-name"] = "依赖名",
      ["macro-argument-elided"] = "宏参数已被" }) do
      local message = report.terminal_notice("selected", { state = "invalid-semantic-context", stage = "entity",
        reason = "identity-missing", compiler_evidence = { kind = kind } })
      t.assert_contains(message, fragment)
    end
  end)

  t.it("B4 destination proof client failures are preserved by Explain", function()
    local transaction = require("utils.ue_goto.semantic_transaction")
    local tx = transaction.create({ bufnr = 0, symbol = "selected" })
    transaction.finish_once(tx, transaction.terminal("unavailable", "destination", "definition-not-found", {
      target_identity_result = { reason = "provider-error", method = "textDocument/symbolInfo", client_results = {
        { client_id = 9, status = "error", error = { code = -32602, message = "destination not added" } },
      } },
    }))
    local explain = table.concat(report.explain_lines(tx), "\n")
    t.assert_contains(explain, "destination client: id=9 method=textDocument/symbolInfo status=error error_code=-32602 error_message=destination not added")
  end)

  t.it("all 27 stable reasons use the report-b presentation vocabulary", function()
    local terminal = require("utils.ue_goto.semantic_transaction").terminal
    local reasons
    for i = 1, 40 do
      local name, value = debug.getupvalue(terminal, i)
      if name == "REASONS" then reasons = value; break end
      if not name then break end
    end
    t.assert_eq(vim.tbl_count(reasons), 27)
    for reason in pairs(reasons) do
      local message = report.terminal_notice("selected", { state = "unavailable",
        stage = reason == "stale-request" and "stale" or "entity", reason = reason })
      if reason == "stale-request" then t.assert_nil(message)
      else t.assert_true(type(message) == "string"); t.assert_false(message:find(": " .. reason, 1, true)) end
    end
  end)
end)
