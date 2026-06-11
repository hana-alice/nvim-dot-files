-- tests/cases/options_spec.lua
-- 编辑器 options 回归。

local t = require("tests.harness")
local cfg = t.bootstrap()

pcall(dofile, cfg .. "/lua/config/options.lua")

t.describe("options: 缩进与行号", function()
  t.it("expandtab = true", function() t.assert_eq(vim.opt.expandtab:get(), true) end)
  t.it("shiftwidth = 4", function() t.assert_eq(vim.opt.shiftwidth:get(), 4) end)
  t.it("softtabstop = 4", function() t.assert_eq(vim.opt.softtabstop:get(), 4) end)
  t.it("tabstop = 4", function() t.assert_eq(vim.opt.tabstop:get(), 4) end)
  t.it("number = true", function() t.assert_eq(vim.opt.number:get(), true) end)
  t.it("relativenumber = false", function() t.assert_eq(vim.opt.relativenumber:get(), false) end)
end)

t.describe("options: session 与 list", function()
  t.it("list = false", function() t.assert_eq(vim.opt.list:get(), false) end)
  local so = vim.opt.sessionoptions:get()
  for _, key in ipairs({ "buffers", "tabpages", "winsize", "skiprtp" }) do
    t.it("sessionoptions 含 " .. key, function()
      t.assert_contains(so, key)
    end)
  end
end)
