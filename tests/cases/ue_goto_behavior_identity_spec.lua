local t = require("tests.harness")
t.bootstrap()

local function with_modules(replacements, body)
  local saved = {}
  for name, value in pairs(replacements) do saved[name], package.loaded[name] = package.loaded[name], value end
  local ok, err = xpcall(body, debug.traceback)
  for name in pairs(replacements) do package.loaded[name] = saved[name] end
  if not ok then error(err) end
end

local function loc(path, line)
  return { uri = vim.uri_from_fname(path), _position_encoding = "utf-16",
    range = { start = { line = line, character = 4 }, ["end"] = { line = line, character = 12 } } }
end

t.describe("provider: all exact-cursor identities and destination roles", function()
  t.it("one client cannot turn different USRs into its first identity", function()
    local old_clients = vim.lsp.get_clients
    local replies = { { usr = "usr:int" }, { usr = "usr:double" } }
    vim.lsp.get_clients = function() return { {
      id = 31, name = "clangd", offset_encoding = "utf-16",
      request = function(_, _, _, cb) cb(nil, replies); return true end,
    } } end
    local ok, err = xpcall(function()
      with_modules({ ["ue.clangd_commands"] = { ensure = function(_, _, cb) cb(true) end },
        ["utils.ue_goto.provider"] = false }, function()
        local provider = require("utils.ue_goto.provider")
        local result
        provider.async_clangd_symbol_info(0, function(value) result = value end, { structured = true })
        t.assert_true(vim.wait(1000, function() return result ~= nil end))
        t.assert_eq(result.usr, nil)
        t.assert_eq(result.reason, "identity-conflict")
        t.assert_eq(#result.identities, 2)

        local declaration, definition = loc("/fixture/api.h", 0), loc("/fixture/api.cpp", 5)
        replies = { { usr = "usr:int", declarationRange = declaration, definitionRange = definition },
          { usr = "usr:int", declarationRange = declaration, definitionRange = definition } }
        result = nil
        provider.async_clangd_symbol_info(0, function(value) result = value end, { structured = true })
        t.assert_true(vim.wait(1000, function() return result ~= nil end))
        t.assert_eq(result.usr, "usr:int")
        t.assert_eq(#result.definitions, 1)
        t.assert_eq(#result.declarations, 1)
        t.assert_eq(result.definitions[1]._position_encoding, "utf-16")
      end)
    end, debug.traceback)
    vim.lsp.get_clients = old_clients
    if not ok then error(err) end
  end)
end)

t.describe("real clangd: source identity and destination roles", function()
  local platform = require("utils.platform")
  local tool = platform.resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
    config_candidates = require("utils.ue_goto.semantic_sidecar_libclang").discover_clangd_candidates(),
    driver_candidates = function(driver) return driver.default_clangd_candidates() end })
  if not tool.ok then
    t.skip("real clangd source roles", tool.reason, { native = true })
    return
  end

  t.it("rejects declaration-only and dependent calls while retaining type/field/enum/variable definitions", function()
    local source_buf = vim.api.nvim_get_current_buf()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    local path = root .. "/roles.cpp"
    local lines = { "int declared(int);", "int defined(){return 1;}", "struct Thing { int member; };",
      "enum class Mode { On };", "int value=0;", "void overloaded(int);", "void overloaded(double);",
      "template<class T> void dependent(T t){ overloaded(t); }",
      "void caller(){declared(1); defined(); Thing x; x.member=1; Mode m=Mode::On; int y=value; int local=1; int copy=local;}" }
    local command = { "clang++", "-std=c++17", "-c", path }
    vim.fn.writefile(lines, path)
    vim.fn.writefile({ vim.json.encode({ { directory = root, file = path, arguments = command } }) },
      root .. "/compile_commands.json")
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = "cpp"
    local client
    local old_notify = vim.notify
    vim.notify = function() end
    local ok, err = xpcall(function()
      -- The fixture's real CDB replaces UE project discovery/transport only.
      -- Every semantic response is produced by the actual clangd process.
      with_modules({
        ["ue.clangd_commands"] = { ensure = function(_, _, cb)
          cb(true, nil, { workingDirectory = root, compilationCommand = command })
        end },
        ["utils.ue_goto.provider"] = false,
        ["utils.ue_goto.semantic_client"] = {
          set_trace = function() end,
          begin_action = function() return { bufnr = bufnr, cursor = vim.api.nvim_win_get_cursor(0),
            winid = vim.api.nvim_get_current_win(), document_version = vim.api.nvim_buf_get_changedtick(bufnr) } end,
          discover_toolchain = function() return { index = { readiness = "ready", complete = true } } end,
          snapshot_is_current = function() return true end,
        },
        ["utils.probe"] = { record = function() end },
      }, function()
        local id = vim.lsp.start({ name = "clangd-review-fixture",
          cmd = { tool.path, "--background-index=false", "-j=1", "--log=error", "--compile-commands-dir=" .. root },
          root_dir = root }, { bufnr = bufnr, reuse_client = function() return false end })
        t.assert_true(id ~= nil)
        client = vim.lsp.get_client_by_id(id)
        t.assert_true(vim.wait(10000, function() return client.initialized end, 20))
        local owner = {}
        local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
          dtrace = function() end, format_jump_msg = function() return "" end,
          jump_to_location = require("utils.ue_goto.jumper").jump,
        })
        for _, symbol in ipairs({ "declared", "defined", "Thing", "member", "Mode", "On", "value", "local" }) do
          local start = symbol == "local" and (assert(lines[9]:find("=local", 1, true)) + 1)
            or assert(lines[9]:find(symbol, 1, true))
          local cursor = { 9, start - 1 }
          vim.api.nvim_win_set_cursor(0, cursor)
          nav.cpp_definition(symbol, bufnr, vim.api.nvim_buf_get_name(bufnr), "cpp")
          t.assert_true(vim.wait(10000, function() return owner._last_cpp_transaction.result ~= nil end, 20))
          local result = owner._last_cpp_transaction.result
          if symbol == "declared" then
            t.assert_eq(result.state, "unavailable")
            t.assert_eq(result.destination_role, "declaration")
            t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(0), cursor))
          else
            t.assert_eq(result.state, "resolved", symbol .. " definition must remain navigable")
            t.assert_eq(result.destination_role, "definition")
          end
        end
        vim.api.nvim_win_set_cursor(0, { 8, assert(lines[8]:find("overloaded", 1, true)) - 1 })
        nav.cpp_definition("overloaded", bufnr, vim.api.nvim_buf_get_name(bufnr), "cpp")
        t.assert_true(vim.wait(10000, function() return owner._last_cpp_transaction.result ~= nil end, 20))
        local result = owner._last_cpp_transaction.result
        t.assert_eq(result.reason, "identity-conflict")
        t.assert_eq(#result.provider_result.identities, 2)
      end)
    end, debug.traceback)
    if client then client:stop(true); vim.wait(1000, function() return client:is_stopped() end, 20) end
    vim.notify = old_notify
    vim.api.nvim_set_current_buf(source_buf)
    vim.api.nvim_buf_delete(bufnr, { force = true })
    vim.fn.delete(root, "rf")
    if not ok then error(err) end
  end)
end)

t.describe("source coordinator: declaration is not a proven definition", function()
  t.it("rejects declaration-only results and accepts compiler-proven bodies", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local path = vim.api.nvim_buf_get_name(bufnr)
    local target = loc("/fixture/api.cpp", 0)
    local symbol_info = { usr = "usr:int", client_ids = { 31 }, reason = "ok", declarations = { target }, definitions = {} }
    local old_clients, old_notify = vim.lsp.get_clients, vim.notify
    vim.lsp.get_clients = function() return { { id = 31, name = "clangd" } } end
    vim.notify = function() end
    local ok, err = xpcall(function()
      with_modules({
        ["utils.ue_goto.provider"] = {
          async_clangd_symbol_info = function(_, cb) cb(symbol_info) end,
          async_lsp_request = function(_, _, cb) cb({ locations = { target } }) end,
        },
        ["utils.ue_goto.semantic_client"] = {
          set_trace = function() end,
          begin_action = function() return { bufnr = bufnr, cursor = vim.api.nvim_win_get_cursor(0) } end,
          discover_toolchain = function() return { index = { readiness = "ready", complete = true } } end,
          snapshot_is_current = function() return true end,
        },
        ["utils.probe"] = { record = function() end },
      }, function()
        local owner, jumps = {}, 0
        local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
          dtrace = function() end, format_jump_msg = function() return "" end,
          jump_to_location = function() jumps = jumps + 1; return true end,
        })
        nav.cpp_definition("declared", bufnr, path, "cpp")
        t.assert_eq(jumps, 0)
        t.assert_eq(owner._last_cpp_transaction.result.state, "unavailable")
        t.assert_eq(owner._last_cpp_transaction.result.destination_role, "declaration")
        symbol_info.definitions = { target }
        nav.cpp_definition("declared", bufnr, path, "cpp")
        t.assert_eq(jumps, 1)
        t.assert_eq(owner._last_cpp_transaction.result.reason, "definition-resolved")
      end)
    end, debug.traceback)
    vim.lsp.get_clients, vim.notify = old_clients, old_notify
    if not ok then error(err) end
  end)
end)

t.describe("explain: bounded diagnostic evidence", function()
  t.it("retains raw reasons and timings without exposing absolute paths", function()
    local txmod = require("utils.ue_goto.semantic_transaction")
    local owner = {}
    require("utils.ue_goto.semantic_navigation").install(owner, {
      dtrace = function() end, jump_to_location = function() end, format_jump_msg = function() end,
    })
    local tx = txmod.create({ build = { project_root = "/fixture", engine_root = "/engine" } })
    local diagnostics, contexts = {}, {}
    for i = 1, 30 do
      diagnostics[i] = "missing include: C:\\Private User\\Secrets\\api.h"
      contexts[i] = { context_id = "ctx-" .. i, origin_tu = "/fixture/Source/body.cpp",
        reason = "tu-parse-failed", definition_count = 0 }
    end
    diagnostics[2] = "C:/Private User/Secrets/api.h:12:3: error: unknown type name Foo"
    diagnostics[3] = "fatal: '/private/work/api.hpp' not found"
    diagnostics[4] = 'fatal: "//server/share/api.hpp" not found'
    txmod.finish_once(tx, txmod.terminal("unavailable", "destination", "semantic-tu-unavailable", {
      detail = "lookup-definition-overflow", diagnostics = diagnostics, context_evidence = contexts,
      metrics = { cold_parse_ms = 14, reparse_ms = 3, tu_count = 2 },
    }))
    owner._last_cpp_transaction = tx
    local lines = owner.explain_lines()
    local text = table.concat(lines, "\n")
    t.assert_contains(text, "lookup-definition-overflow")
    t.assert_contains(text, "missing include")
    t.assert_contains(text, "project/Source/body.cpp")
    t.assert_contains(text, "tu-parse-failed")
    t.assert_contains(text, "cold_parse_ms=14")
    t.assert_contains(text, "error: unknown type name Foo")
    t.assert_contains(text, "not found")
    t.assert_true(not text:find("Private User", 1, true))
    t.assert_true(not text:find("/private/work", 1, true))
    t.assert_true(not text:find("server/share", 1, true))
    t.assert_true(not text:find("/fixture/", 1, true))
    t.assert_true(#lines <= 64)
    t.assert_contains(text, "omitted")
  end)
end)
