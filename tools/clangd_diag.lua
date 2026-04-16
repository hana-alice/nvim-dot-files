-- 在 Neovim 中执行此脚本来诊断 clangd 状态
-- :luafile C:/Users/hana-alice/AppData/Local/nvim/tools/clangd_diag.lua

local lines = {}
local function log(s) lines[#lines+1] = s end

-- 1. 检查 clangd 客户端
local clients = vim.lsp.get_clients({ name = "clangd" })
if #clients == 0 then
  log("❌ clangd 未运行")
  vim.notify(table.concat(lines, "\n"), vim.log.levels.WARN)
  return
end

for _, c in ipairs(clients) do
  log("== clangd #" .. c.id .. " ==")
  log("root: " .. (c.config.root_dir or "nil"))

  local cmd = c.config.cmd or {}
  -- 提取关键参数
  for _, arg in ipairs(cmd) do
    if arg:match("^%-j") then log("  " .. arg) end
    if arg:match("pch") then log("  " .. arg) end
    if arg:match("compile%-commands") then log("  " .. arg) end
    if arg:match("background%-index") then log("  " .. arg) end
    if arg:match("clang%-tidy") then log("  ⚠️ " .. arg) end
  end

  -- 2. 检查 server capabilities
  if c.server_capabilities then
    log("  capabilities OK")
  end
end

-- 3. 检查当前buffer的LSP状态
local bufnr = vim.api.nvim_get_current_buf()
local fname = vim.api.nvim_buf_get_name(bufnr)
log("")
log("当前文件: " .. fname)

local diag = vim.diagnostic.get(bufnr)
log("诊断数: " .. #diag)

-- 4. 显示结果
local result = table.concat(lines, "\n")
vim.notify(result, vim.log.levels.INFO)
-- 也写到消息历史
print(result)
