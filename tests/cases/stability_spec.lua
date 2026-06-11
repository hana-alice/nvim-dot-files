-- tests/cases/stability_spec.lua
-- 稳定性 / 幂等回归：重复加载、重复 setup、多轮 reset 无泄漏。

local t = require("tests.harness")
t.bootstrap()

t.describe("stability: 模块重复 require 幂等", function()
  for _, name in ipairs({ "ue", "ue.config", "utils.platform", "utils.ue_paths" }) do
    t.it(name .. " 两次 require 同一引用", function()
      local a = require(name)
      local b = require(name)
      t.assert_true(a == b, name .. " 两次 require 返回不同引用")
    end)
  end
end)

t.describe("stability: ue.setup 可重复调用", function()
  t.it("两次 setup 无异常且命令仍注册", function()
    require("ue").setup()
    require("ue").setup()
    t.assert_eq(vim.fn.exists(":UEBuild"), 2)
    t.assert_eq(vim.fn.exists(":UEDAPAttach"), 2)
  end)
end)

t.describe("stability: ue.config 多轮 override/reset 无泄漏", function()
  local cfg = require("ue.config")
  t.it("三轮 setup→reset 后恢复默认", function()
    for i = 1, 3 do
      cfg.setup({ index = { idle_cold_ms = 100 + i }, dap = { lldb_dap_path = "/tmp/x" } })
      cfg.reset_for_test()
      t.assert_eq(cfg.get("index.idle_cold_ms"), 120000, "第 " .. i .. " 轮未恢复")
    end
    t.assert_nil(cfg.get("dap.lldb_dap_path"))
  end)
end)

t.describe("stability: DAP 平台注册可重复清空", function()
  local p = require("ue.dap.platforms")
  t.it("两次 _reset_for_test 后注册/查询正常", function()
    p._reset_for_test()
    p._reset_for_test()
    local hit = false
    p.register_attach("stab_test", function() hit = true end)
    local h = p.attach_handler("stab_test")
    t.assert_type(h, "function")
    h()
    t.assert_true(hit, "handler 未触发")
    t.assert_nil(p.launch_handler("stab_test"))
    p._reset_for_test()
    t.assert_nil(p.attach_handler("stab_test"))
  end)
end)
