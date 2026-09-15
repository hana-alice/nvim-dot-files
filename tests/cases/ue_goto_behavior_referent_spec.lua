local t = require("tests.harness")
t.bootstrap()

-- Exercise the public source coordinator with real compiler answers. Only the
-- surrounding UE environment and final window jump are isolated by this fixture.
t.describe("real clangd source referent matrix", function()
  local tool = require("utils.platform").resolve_tool({
    name = "clangd",
    env = { "UE_CLANGD" },
    driver_candidates = function(driver)
      return driver.default_clangd_candidates()
    end,
  })
  if not tool.ok then
    t.skip("compiler-owned entity roles", tool.reason, { native = true })
    return
  end

  local header_lines = {
    "#pragma once",
    '#define VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME "VK_EXT_validation_features"',
    "#define APPLY_VALUE(value) ((value) + 1)",
    "#define RECORD_TYPE Widget",
    "struct Widget { int field; };",
    "typedef int Scalar;",
    "using WidgetAlias = Widget;",
    "namespace space { inline int inline_value() { return 8; } }",
    "namespace alias = space;",
    "enum EnumValue { ValueOne = 1 };",
    "int ordinary(int);",
    "int only_declared(int);",
    "class Forward;",
    "extern int external_value;",
    "int ambiguous(int);",
    "int ambiguous(long);",
    "namespace macro { extern int value; int declared(); }",
    "namespace record_scope { struct macro { static int value; static int declared(); }; }",
  }
  local source_lines = {
    '#include "referents.h"',
    "int ordinary(int parameter) { return parameter; }",
    "const char *extension_name = VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME;",
    "int macro_call() { return APPLY_VALUE(4); }",
    "RECORD_TYPE expanded_record;",
    "Scalar scalar_value = 0;",
    "WidgetAlias alias_value;",
    "int namespace_call() { return space::inline_value(); }",
    "int namespace_alias_call() { return alias::inline_value(); }",
    "int field_use(Widget &widget) { return widget.field; }",
    "int enum_use() { return ValueOne; }",
    "Widget complete_record;",
    "int function_call() { return ordinary(1); }",
    "int declaration_use() { return only_declared(1); }",
    "Forward *forward_use;",
    "int external_use() { return external_value; }",
    "int ambiguous_use() { return ambiguous(0.5); }",
    "int namespace_macro_value() { return macro::value; }",
    "int namespace_macro_call() { return macro::declared(); }",
    "int record_macro_value() { return record_scope::macro::value; }",
    "int record_macro_call() { return record_scope::macro::declared(); }",
    "int builtin_line = __LINE__;",
  }

  local root = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(root, "p")
  root = vim.uv.fs_realpath(root):gsub("\\", "/")
  local source, header = root .. "/referents.cpp", root .. "/referents.h"
  vim.fn.writefile(source_lines, source)
  vim.fn.writefile(header_lines, header)
  vim.fn.writefile({
    vim.json.encode({
      {
        file = source,
        directory = root,
        arguments = { "clang++", "-std=c++17", "-c", source },
      },
    }),
  }, root .. "/compile_commands.json")

  local previous = vim.api.nvim_get_current_buf()
  local bufnr = vim.fn.bufadd(source)
  vim.fn.bufload(bufnr)
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = "cpp"
  local client, action = nil, 0
  local old_semantic = package.loaded["utils.ue_goto.semantic_client"]
  local old_probe, old_notify = package.loaded["utils.probe"], vim.notify
  package.loaded["utils.ue_goto.semantic_client"] = {
    set_trace = function() end,
    begin_action = function()
      action = action + 1
      return {
        id = action,
        bufnr = bufnr,
        winid = vim.api.nvim_get_current_win(),
        cursor = vim.api.nvim_win_get_cursor(0),
        changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
      }
    end,
    discover_toolchain = function()
      return { index = { readiness = "ready", complete = true } }
    end,
    snapshot_is_current = function(snapshot)
      return snapshot.id == action
        and snapshot.changedtick == vim.api.nvim_buf_get_changedtick(bufnr)
        and vim.deep_equal(snapshot.cursor, vim.api.nvim_win_get_cursor(0))
    end,
    note_origin = function() end,
  }
  package.loaded["utils.probe"] = { record = function() end, observe = function() end }
  vim.notify = function() end

  local function column(lines, line, token, occurrence)
    local first, last = 0, 0
    for _ = 1, occurrence or 1 do
      first, last = lines[line]:find("%f[%w_]" .. token .. "%f[^%w_]", last + 1)
      assert(first, "fixture token missing: " .. token)
    end
    return first - 1
  end

  local ok, err = xpcall(function()
    local id = vim.lsp.start({
      name = "clangd-referent-fixture",
      cmd = { tool.path, "--background-index", "-j=1", "--log=error", "--compile-commands-dir=" .. root },
      root_dir = root,
    }, {
      bufnr = bufnr,
      reuse_client = function()
        return false
      end,
    })
    client = vim.lsp.get_client_by_id(id)
    t.assert_true(client ~= nil, "clangd must start")
    t.assert_true(
      vim.wait(10000, function()
        return client.initialized
      end, 20),
      "clangd must initialize"
    )

    local owner, jumps = {}, {}
    local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
      dtrace = function() end,
      format_jump_msg = function()
        return ""
      end,
      jump_to_location = function(target)
        jumps[#jumps + 1] = vim.deepcopy(target)
        return true
      end,
    })
    local function navigate(line, token, occurrence)
      jumps = {}
      -- Query inside the token rather than relying on an exact first-byte cursor.
      vim.api.nvim_win_set_cursor(0, { line, column(source_lines, line, token, occurrence) + 1 })
      nav.cpp_definition(token, bufnr, source, "cpp")
      t.assert_true(
        vim.wait(10000, function()
          return owner._last_cpp_transaction and owner._last_cpp_transaction.result ~= nil
        end, 20),
        "navigation must complete: " .. token
      )
      return owner._last_cpp_transaction.result
    end

    for _, case in ipairs({
      { "object-like extension macro", 3, "VK_EXT_VALIDATION_FEATURES_EXTENSION_NAME", 2 },
      { "function-like macro", 4, "APPLY_VALUE", 3 },
      { "macro expanding to a record type", 5, "RECORD_TYPE", 4 },
      { "typedef of a builtin type", 6, "Scalar", 6, "declaration" },
      { "using alias of a record type", 7, "WidgetAlias", 7, "declaration" },
      { "namespace qualifier", 8, "space", 8, "declaration" },
      { "namespace alias qualifier", 9, "alias", 9, "declaration" },
      { "field reference", 10, "field", 5 },
      { "enum constant reference", 11, "ValueOne", 10 },
      { "complete class reference", 12, "Widget", 5 },
      { "inline function reference", 8, "inline_value", 8 },
      { "ordinary function call", 13, "ordinary", 2, target_source = true },
      { "parameter reference", 2, "parameter", 2, target_source = true, occurrence = 2 },
    }) do
      t.it(case[1], function()
        local result = navigate(case[2], case[3], case.occurrence)
        local details = vim.inspect(result)
        t.assert_eq(result.state, "resolved", details)
        local role = case[5] or "definition"
        t.assert_eq(result.destination_role, role, details)
        t.assert_eq(result.reason, role .. "-resolved", details)
        t.assert_eq(#jumps, 1, "exactly one proven destination")
        local expected_path = case.target_source and source or header
        local expected_lines = case.target_source and source_lines or header_lines
        local target = jumps[1]
        t.assert_eq(vim.uri_to_fname(target.uri):gsub("\\", "/"), expected_path, details)
        t.assert_eq(target.range.start.line, case[4] - 1, details)
        t.assert_eq(target.range.start.character, column(expected_lines, case[4], case[3]), details)
        t.assert_true(type(result.identity) == "string" and result.identity ~= "", "canonical identity required")
        t.assert_eq(result.provider, "clangd")
        t.assert_eq(vim.api.nvim_get_current_buf(), bufnr, "only the final jump hook may change the view")
      end)
    end

    t.it("definition under the cursor does not self-jump", function()
      local before = { 2, column(source_lines, 2, "ordinary") + 1 }
      local result = navigate(2, "ordinary")
      t.assert_eq(result.state, "unavailable", vim.inspect(result))
      t.assert_eq(result.reason, "already-at-definition", vim.inspect(result))
      t.assert_eq(#jumps, 0)
      t.assert_true(vim.deep_equal(vim.api.nvim_win_get_cursor(0), before))
    end)

    for _, case in ipairs({
      { "function declaration has no definition", 14, "only_declared", "definition-not-found" },
      { "forward class has no definition", 15, "Forward", "definition-not-found" },
      { "extern variable has no definition", 16, "external_value", "definition-not-found" },
      { "same-arity ambiguous overload is not guessed", 17, "ambiguous", "identity-conflict" },
      { "extern in namespace named macro is not a macro", 18, "value", "definition-not-found", macro_fragment = true },
      {
        "function in namespace named macro is not a macro",
        19,
        "declared",
        "definition-not-found",
        macro_fragment = true,
      },
      {
        "static member of struct named macro is not a macro",
        20,
        "value",
        "definition-not-found",
        macro_fragment = true,
      },
      { "method of struct named macro is not a macro", 21, "declared", "definition-not-found", macro_fragment = true },
      { "builtin macro without source has no fabricated destination", 22, "__LINE__", "macro-no-source-definition" },
    }) do
      t.it(case[1], function()
        local result = navigate(case[2], case[3])
        t.assert_true(result.state == "unavailable" or result.state == "invalid-semantic-context", vim.inspect(result))
        t.assert_eq(result.reason, case[4], vim.inspect(result))
        t.assert_eq(result.provider, "clangd")
        if case.macro_fragment then
          t.assert_contains(result.identity, "@macro@", "fixture must exercise the ambiguous USR substring")
        end
        t.assert_eq(#jumps, 0, "a declaration or ambiguous overload must not masquerade as a definition")
      end)
    end
  end, debug.traceback)

  action = action + 1
  if client then
    client:stop(true)
    vim.wait(1000, function()
      return client:is_stopped()
    end, 20)
  end
  package.loaded["utils.ue_goto.semantic_client"] = old_semantic
  package.loaded["utils.probe"], vim.notify = old_probe, old_notify
  vim.api.nvim_set_current_buf(previous)
  for _, path in ipairs({ source, header }) do
    local buf = vim.fn.bufnr(path)
    if buf >= 0 then
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
    end
  end
  vim.fn.delete(root, "rf")
  if not ok then
    error(err)
  end
end)
