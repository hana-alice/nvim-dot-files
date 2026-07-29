-- tests/cases/smoke_spec.lua
-- 配置加载冒烟：关键模块可 require、ue.setup() 注册命令不报错。

local t = require("tests.harness")
t.bootstrap()

t.describe("smoke: 核心模块加载", function()
  t.it("require('ue') 返回 table", function()
    t.assert_type(require("ue"), "table")
  end)
  t.it("require('ue.config') 返回 table", function()
    t.assert_type(require("ue.config"), "table")
  end)
  t.it("require('utils.platform') 返回 table", function()
    t.assert_type(require("utils.platform"), "table")
  end)
  t.it("require('utils.android_device') 返回 table", function()
    t.assert_type(require("utils.android_device"), "table")
  end)
  t.it("require('utils.log') 返回 table", function()
    t.assert_type(require("utils.log"), "table")
  end)
end)

t.describe("smoke: ue.setup() 注册命令", function()
  t.it("ue.setup() 无异常", function()
    require("ue").setup()
  end)

  local cmds = {
    "UEDAPAttach", "UEDAPLaunch", "UEDAPContinue", "UEDAPPause",
    "UEDAPToggleBreakpoint", "UEDAPStepOver", "UEDAPStepIn",
    "UEDAPStepOut", "UEDAPToggleUI", "UEDAPREPL", "UEDAPDiag",
  }
  for _, c in ipairs(cmds) do
    t.it("命令 :" .. c .. " 已注册", function()
      require("ue").setup()
      t.assert_eq(vim.fn.exists(":" .. c), 2, c .. " 未注册")
    end)
  end
end)
