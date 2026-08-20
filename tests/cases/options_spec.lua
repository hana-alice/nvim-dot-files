-- tests/cases/options_spec.lua
-- 编辑器 options 回归。

local t = require("tests.harness")
local cfg = t.bootstrap()
local clipboard = require("config.clipboard")

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

t.describe("options: SSH/Zellij OSC 52 clipboard", function()
  local terminal_host = { is_windows = false, is_neovide = false }

  t.it("Zellij 没有 SSH_TTY 时仍强制启用", function()
    t.assert_true(clipboard.should_use_osc52({ ZELLIJ = "/run/user/1000/zellij" }, terminal_host))
    t.assert_true(clipboard.should_use_osc52({ SSH_TTY = "/dev/pts/2" }, terminal_host))
    t.assert_false(clipboard.should_use_osc52({}, terminal_host))
  end)

  t.it("不覆盖 Windows 或 Neovide 的原生剪贴板", function()
    t.assert_false(clipboard.should_use_osc52({ ZELLIJ = "1" }, {
      is_windows = true,
      is_neovide = false,
    }))
    t.assert_false(clipboard.should_use_osc52({ SSH_TTY = "/dev/pts/2" }, {
      is_windows = false,
      is_neovide = true,
    }))
  end)

  t.it("只用 OSC 52 copy，paste 从 unnamed register 立即返回", function()
    local old_clipboard = vim.o.clipboard
    local old_provider = vim.g.clipboard
    local old_register = vim.fn.getreginfo('"')
    vim.fn.setreg('"', { "line one", "line two" }, "V")

    local enabled = clipboard.setup({ ZELLIJ = "1" }, terminal_host)
    local provider = vim.g.clipboard
    local pasted = provider.paste["+"]()

    t.assert_true(enabled)
    t.assert_contains(vim.opt.clipboard:get(), "unnamedplus")
    t.assert_eq(provider.name, "OSC 52")
    t.assert_eq(type(provider.copy["+"]), "function")
    t.assert_eq(type(provider.copy["*"]), "function")
    t.assert_eq(pasted[1][1], "line one")
    t.assert_eq(pasted[1][2], "line two")
    t.assert_eq(pasted[2], "V")

    vim.o.clipboard = old_clipboard
    vim.g.clipboard = old_provider
    vim.fn.setreg('"', old_register)
  end)
end)
