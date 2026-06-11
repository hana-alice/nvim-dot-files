-- tests/cases/autocmds_spec.lua
-- filetype 映射与 FileType autocmd 行为回归。

local t = require("tests.harness")
local cfg = t.bootstrap()

-- options.lua 注册 filetype 映射 + cindent / commentstring autocmd。
pcall(dofile, cfg .. "/lua/config/options.lua")

t.describe("filetype: usf/ush → hlsl", function()
  t.it("x.usf 解析为 hlsl", function()
    t.assert_eq(vim.filetype.match({ filename = "x.usf" }), "hlsl")
  end)
  t.it("x.ush 解析为 hlsl", function()
    t.assert_eq(vim.filetype.match({ filename = "x.ush" }), "hlsl")
  end)
end)

t.describe("autocmd: C 家族缩进切换为 cindent", function()
  local b = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(b)
  vim.bo[b].filetype = "cpp" -- 触发 FileType autocmd

  t.it("cindent = true", function() t.assert_eq(vim.bo[b].cindent, true) end)
  t.it("smartindent = false", function() t.assert_eq(vim.bo[b].smartindent, false) end)
  t.it("cinoptions 为预期值", function()
    t.assert_eq(vim.bo[b].cinoptions, "g0,:0,l1,(0,W4,t0,j1,J1")
  end)
end)

t.describe("autocmd: commentstring 回退", function()
  local h = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(h)
  vim.bo[h].filetype = "hlsl"
  vim.api.nvim_exec_autocmds("FileType", { buffer = h })
  vim.api.nvim_exec_autocmds("BufEnter", { buffer = h })

  t.it("hlsl commentstring = // %s", function()
    local cs = vim.bo[h].commentstring
    t.assert_contains(cs, "%s")
    t.assert_eq(cs, "// %s")
  end)
end)
