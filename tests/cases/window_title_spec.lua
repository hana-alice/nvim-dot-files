-- 当前 Neovim/Neovide 系统窗口标题命名回归。

local t = require("tests.harness")
t.bootstrap()

local title = require("utils.window_title")

t.describe("window_title: literal title 与安全清理", function()
  t.it("百分号按字面显示，不被 titlestring 当 statusline 表达式", function()
    title.set("Render 50% %{danger}")
    t.assert_true(vim.o.title, "设置自定义标题后 title 必须启用")
    t.assert_eq(title.current(), "Render 50% %{danger}")
    t.assert_eq(vim.api.nvim_eval_statusline(vim.o.titlestring, {}).str, "Render 50% %{danger}")
  end)

  t.it("控制字符被清理并限制为单行", function()
    title.set("  Build\27]0;bad\7\nWindow  ")
    t.assert_eq(title.current(), "Build ]0;bad Window")
    t.assert_false(title.current():find("[\1-\31\127]") ~= nil, "标题不得含控制字符")
  end)

  t.it("超长 Unicode 标题按字符截断，不切坏 UTF-8", function()
    title.set(string.rep("窗", 100))
    t.assert_eq(vim.fn.strchars(title.current()), 80)
    t.assert_true(vim.str_utfindex(title.current()) ~= nil, "截断后必须仍是合法 UTF-8")
  end)
end)

t.describe("window_title: 自动标题恢复与命令", function()
  t.it("reset 清除自定义名并恢复 Neovim 自动 titlestring", function()
    title.set("Gameplay")
    title.reset()
    t.assert_eq(title.current(), nil)
    t.assert_true(vim.o.title, "自动标题仍需启用 title")
    t.assert_eq(vim.o.titlestring, "")
  end)

  t.it("setup 幂等注册 WindowTitle 与 WindowTitleReset", function()
    title.setup()
    title.setup()
    t.assert_eq(vim.fn.exists(":WindowTitle"), 2)
    t.assert_eq(vim.fn.exists(":WindowTitleReset"), 2)
  end)

  t.it("WindowTitle 接受含空格名字，bang 恢复自动标题", function()
    vim.cmd("WindowTitle Shader Compile")
    t.assert_eq(title.current(), "Shader Compile")
    vim.cmd("WindowTitle!")
    t.assert_eq(title.current(), nil)
    t.assert_eq(vim.o.titlestring, "")
  end)

  t.it("输入框取消不改变标题，空确认恢复自动标题", function()
    title.set("Keep Me")
    local original_input = vim.ui.input
    vim.ui.input = function(_, callback) callback(nil) end
    title.prompt()
    t.assert_eq(title.current(), "Keep Me")

    vim.ui.input = function(_, callback) callback("") end
    title.prompt()
    t.assert_eq(title.current(), nil)
    vim.ui.input = original_input
  end)
end)

title.reset()
