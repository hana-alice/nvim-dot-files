-- diagnose_instant_goto.lua
-- 三路赛跑全部卡住时跑这个 — 不动光标，只观察。
-- 用法：把光标放到出问题的 symbol 上（比如 line 5367 AddDefaulted_GetRef），
--      然后 :luafile <这个文件路径>
--      看 :messages 或 snacks history。

local bufnr = vim.api.nvim_get_current_buf()
local cur = vim.api.nvim_win_get_cursor(0)
local symbol = vim.fn.expand("<cword>")

print("=========================================================")
print(string.format("[diag] buf=%d  line=%d  symbol=%q", bufnr, cur[1], symbol))
print(string.format("[diag] file=%s", vim.api.nvim_buf_get_name(bufnr)))

-- 1) 哪些 LSP client attached + 它们的 server_capabilities
local clients = vim.lsp.get_clients({ bufnr = bufnr })
print(string.format("[diag] %d LSP client(s) attached:", #clients))
for _, c in ipairs(clients) do
  local caps = c.server_capabilities or {}
  print(string.format("  - %s (id=%d)  ws/symbol=%s  td/definition=%s",
    c.name, c.id,
    tostring(caps.workspaceSymbolProvider ~= nil and caps.workspaceSymbolProvider ~= false),
    tostring(caps.definitionProvider ~= nil and caps.definitionProvider ~= false)))
end

-- 2) 直接打 workspace/symbol — 不经过我们的 helper，看 raw 行为
print(string.format("[diag] firing workspace/symbol query=%q ...", symbol))
local t0 = vim.uv.hrtime()
local cancelled = false
local req_ids = {}
for _, c in ipairs(clients) do
  if c.server_capabilities and c.server_capabilities.workspaceSymbolProvider then
    local ok, req_id = c:request("workspace/symbol", { query = symbol }, function(err, result, ctx)
      local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
      if cancelled then
        print(string.format("[diag] %s late reply after cancel (%.0fms)", c.name, elapsed_ms))
        return
      end
      if err then
        print(string.format("[diag] %s ERROR (%.0fms): %s", c.name, elapsed_ms, vim.inspect(err)))
        return
      end
      local n = result and #result or 0
      print(string.format("[diag] %s returned %d hit(s) in %.0fms", c.name, n, elapsed_ms))
      if result and #result > 0 then
        local exact = 0
        for _, sym in ipairs(result) do
          if sym.name == symbol then exact = exact + 1 end
        end
        print(string.format("[diag]   exact-name matches: %d / %d", exact, n))
        for i = 1, math.min(5, #result) do
          local sym = result[i]
          local loc = sym.location or sym
          local uri = loc.uri or loc.targetUri or "?"
          local line = loc.range and loc.range.start and loc.range.start.line or "?"
          print(string.format("[diag]   #%d name=%q kind=%s @ %s:%s",
            i, sym.name or "?", tostring(sym.kind), uri:sub(-60), tostring(line)))
        end
      end
    end, bufnr)
    if ok then
      table.insert(req_ids, { client = c, id = req_id })
      print(string.format("[diag] %s request fired (id=%s)", c.name, tostring(req_id)))
    else
      print(string.format("[diag] %s request FAILED to fire", c.name))
    end
  end
end

-- 10s 后强制 cancel + 报告状态
vim.defer_fn(function()
  cancelled = true
  for _, r in ipairs(req_ids) do
    pcall(function() r.client:cancel_request(r.id) end)
  end
  local elapsed_ms = (vim.uv.hrtime() - t0) / 1e6
  print(string.format("[diag] === 10s deadline reached, cancelled all (elapsed=%.0fms) ===", elapsed_ms))
  print("[diag] 如果上面没看到 'returned N hit(s)' 说明 workspace/symbol 真的没回。")
end, 10000)
