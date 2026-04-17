-- Verify clangd workspace/symbol does NOT depend on the current TU's AST.
--
-- Run with: nvim NaniteCullRaster.cpp -c 'luafile scripts/verify_workspace_symbol_no_ast.lua'
--
-- IMPORTANT: clangd should be cold for this TU. To guarantee that:
--   1. Close any nvim that has clangd running.
--   2. `pkill -f clangd` (or kill all clangd.exe in Task Manager).
--   3. Then run the command above.
--
-- The point is to compare workspace/symbol response time vs textDocument/definition
-- response time, NOT absolute speed. We expect:
--   - workspace/symbol: 50-500ms (uses SymbolIndex, no AST)
--   - textDocument/definition: 30000-60000ms (waits for ParsedAST)
--
-- If workspace/symbol does NOT respond fast (> 5s), the entire instant-goto
-- plan must be revised. STOP and report back.

local sym = "AddDefaulted_GetRef"
local clients = vim.lsp.get_clients({ bufnr = 0, name = "clangd" })
if vim.tbl_isempty(clients) then
  vim.notify("[verify] no clangd attached to current buffer", vim.log.levels.ERROR)
  return
end
local c = clients[1]
local function now_ms() return vim.loop.hrtime() / 1e6 end

vim.notify(string.format("[verify] sending requests for symbol=%q ...", sym),
  vim.log.levels.INFO)

local t_ws = now_ms()
c:request("workspace/symbol", { query = sym }, function(err, result)
  vim.notify(string.format(
    "[verify] ws/symbol: %d results in %.0f ms (err=%s)",
    result and #result or 0, now_ms() - t_ws, tostring(err)),
    vim.log.levels.INFO)
end)

local pos = vim.lsp.util.make_position_params(0, c.offset_encoding or "utf-16")
local t_def = now_ms()
c:request("textDocument/definition", pos, function(err, result)
  local n = 0
  if result then
    if vim.islist(result) then n = #result else n = 1 end
  end
  vim.notify(string.format(
    "[verify] td/definition: %d results in %.0f ms (err=%s)",
    n, now_ms() - t_def, tostring(err)),
    vim.log.levels.INFO)
end)
