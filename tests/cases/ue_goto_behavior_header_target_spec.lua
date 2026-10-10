local t = require("tests.harness")
t.bootstrap()

local function with_modules(replacements, body)
  local saved = {}
  for name, value in pairs(replacements) do saved[name], package.loaded[name] = package.loaded[name], value end
  local ok, err = xpcall(body, debug.traceback)
  for name in pairs(replacements) do package.loaded[name] = saved[name] end
  if not ok then error(err) end
end

local function loc(path)
  return { uri = vim.uri_from_fname(path), _position_encoding = "utf-8",
    range = { start = { line = 0, character = 4 } } }
end

local function run_case(case)
  local header, source = vim.fn.tempname() .. ".h", vim.fn.tempname() .. ".cpp"
  local call_line = "int caller(){return body();}"
  vim.fn.writefile({ "int body();", call_line }, header)
  vim.fn.writefile({ "int body(){return 1;}" }, source)
  local source_buf = vim.fn.bufadd(header)
  vim.fn.bufload(source_buf)
  local source_tick = vim.api.nvim_buf_get_changedtick(source_buf)
  local active_buf = vim.api.nvim_get_current_buf()
  local old_notify = vim.notify
  vim.notify = function() end
  local target = loc(source)
  local state = { jumps = 0, module = 0, symbol = 0, definition = 0, target = 0 }
  local owner = {}
  local ok, err = xpcall(function()
    with_modules({
      ["utils.probe"] = { record = function() end, observe = function() end },
      ["utils.ue_goto.semantic_client"] = {
        set_trace = function() end,
        begin_action = function() return { bufnr = source_buf,
          cursor = case.reference and { 2, assert(call_line:find("body", 1, true)) - 1 } or { 1, 4 },
          changedtick = source_tick } end,
        discover_toolchain = function() return { index = { readiness = "ready", complete = not case.partial } } end,
        snapshot_is_current = function()
          return vim.api.nvim_buf_get_changedtick(source_buf) == source_tick, "source-changed"
        end,
        resolve_header = function(_, callback)
          callback({ state = "resolved", usr = "usr:body",
            declaration = { path = header, line = 1, column = 5 }, metrics = { source = "libclang" } })
        end,
        lookup_definition = function(opts, callback)
          state.module = state.module + 1
          t.assert_eq(opts.usr, "usr:body")
          callback({ state = "unavailable", reason = case.module_reason or "no-proven-module-contexts" })
        end,
      },
      ["utils.ue_goto.provider"] = {
        async_clangd_symbol_info = function(buf, callback)
          t.assert_eq(state.module, 1, "先完成完整 module 门禁，再允许 clangd fallback")
          t.assert_eq(buf, source_buf)
          state.symbol = state.symbol + 1
          callback({ reason = "ok", usr = "usr:body", client_ids = { 9876 } })
        end,
        async_lsp_request = function(_, method, callback, opts)
          t.assert_eq(method, "textDocument/definition")
          t.assert_eq(opts.client_ids[1], 9876)
          state.definition = state.definition + 1
          callback({ reason = "ok", locations = case.raw_empty and {}
            or (case.raw_declaration and { loc(header) } or { target }), client_results = { { client_id = 9876 } } })
        end,
      },
      ["utils.ue_goto.clangd_adapter"] = {
        async_clangd_symbol_info = function(buf, callback, opts)
          state.target = state.target + 1
          t.assert_eq(opts.client_ids[1], 9876, "目标不能选择另一个 clangd client")
          t.assert_eq(opts.compile_command_source, source:gsub("\\", "/"))
          t.assert_eq(opts.snapshot.subject.line0, 0)
          t.assert_eq(opts.snapshot.subject.column0, 4)
          if case.edit_target then vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "int changed;" }) end
          if case.edit_source then vim.api.nvim_buf_set_lines(source_buf, 0, -1, false, { "int source_changed;" }) end
          callback({ reason = "ok", usr = case.target_usr or "usr:body", declarations = { target },
            definitions = case.declaration_only and {} or { target } })
        end,
      },
    }, function()
      local nav = require("utils.ue_goto.semantic_navigation").install(owner, {
        dtrace = function() end, format_jump_msg = function() return "" end,
        jump_to_location = function(value)
          t.assert_eq(value, target)
          state.jumps = state.jumps + 1
          return true
        end,
      })
      local inspected
      nav.cpp_definition("body", source_buf, header, "h", case.inspection and function(value)
        inspected = value
      end or nil)
      local result = owner._last_cpp_transaction.result
      t.assert_true(result ~= nil)
      t.assert_eq(state.module, 1)
      if case.module_reason then
        t.assert_eq(state.symbol, 0)
        t.assert_eq(state.definition, 0)
        t.assert_eq(state.target, 0)
      else
        t.assert_eq(state.symbol, 1)
        t.assert_eq(state.definition, 1)
        t.assert_eq(state.target, (case.raw_empty or case.raw_declaration) and 0 or 1)
      end
      t.assert_eq(state.jumps, case.success and 1 or 0)
      if case.inspection then
        t.assert_eq(inspected, result)
        t.assert_nil(result.state, "inspection proof 不应冒充 resolved gd terminal")
        t.assert_eq(result.kind, "proven-destination")
        t.assert_eq(result.destination_role, "declaration")
        t.assert_eq(result.subject_role, "reference")
        t.assert_eq(result.identity, "usr:body")
        t.assert_eq(require("utils.ue_goto.location").location_path(result.location), header:gsub("\\", "/"))
      else
        t.assert_eq(result.state, case.success and "resolved" or "unavailable")
      end
      if case.inspection then
        t.assert_eq(state.target, 0)
      elseif case.success then
        t.assert_eq(result.target_identity_result.usr, result.identity)
        t.assert_eq(result.target_identity_result.reason, "ok")
        t.assert_eq(#result.target_identity_result.definitions, 1)
      elseif case.edit_target or case.edit_source then
        t.assert_eq(result.reason, "stale-request")
      elseif case.module_reason == "multiple-definitions" then
        t.assert_eq(result.reason, "multiple-definitions")
      elseif case.raw_empty or case.raw_declaration then
        t.assert_eq(result.reason, "definition-absent-in-complete-index")
        t.assert_eq(result.subject_role, "reference", "调用点也不得降级跳到 native 声明")
      elseif not case.module_reason then
        t.assert_eq(result.reason, "definition-not-found")
        t.assert_eq(result.detail, case.target_usr and "identity-conflict" or "definition-not-found")
      end
      t.assert_eq(vim.api.nvim_get_current_buf(), active_buf, "目标 proof 不应切换活动 buffer")
    end)
  end, debug.traceback)
  vim.notify = old_notify
  for _, path in ipairs({ header, source }) do
    local buf = vim.fn.bufnr(path)
    if buf >= 0 then pcall(vim.api.nvim_buf_delete, buf, { force = true }) end
    vim.fn.delete(path)
  end
  if not ok then error(err) end
end

t.describe("header cross-TU fallback requires target body proof", function()
  for _, case in ipairs({
    { name = "target different USR does not jump", target_usr = "usr:other" },
    { name = "target declaration only does not jump", declaration_only = true },
    { name = "target changedtick invalidates in-flight proof", edit_target = true },
    { name = "source snapshot expires during target proof", edit_source = true },
    { name = "same-USR target body jumps after proof", success = true },
    { name = "reference with empty clangd result does not jump to native declaration", reference = true, raw_empty = true },
    { name = "reference with only clangd declaration does not jump to native declaration", reference = true, raw_declaration = true },
    { name = "explicit inspection retains native declaration proof under partial index without gd jump",
      reference = true, raw_empty = true, partial = true, inspection = true },
    { name = "module multiple definitions blocks clangd", module_reason = "multiple-definitions" },
    { name = "module incomplete lookup blocks clangd", module_reason = "lookup-definition-overflow" },
    { name = "module parse failure blocks clangd", module_reason = "tu-parse-failed" },
  }) do
    t.it(case.name, function() run_case(case) end)
  end
end)
