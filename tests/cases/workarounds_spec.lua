-- tests/cases/workarounds_spec.lua
-- workarounds 注册表完整性回归。

local t = require("tests.harness")
local cfg = t.bootstrap()

local w = require("workarounds")
w.setup({ auto_apply = false })

local list = w.list()
local files = vim.fn.glob(cfg .. "/lua/workarounds/*/*.lua", true, true)

t.describe("workarounds: 发现与无错误", function()
  t.it("发现条目数 >= 文件数", function()
    t.assert_true(#list >= #files,
      string.format("list=%d files=%d", #list, #files))
  end)
  t.it("注册表无 error 项", function()
    local errs = {}
    for _, e in ipairs(list) do
      if e.error then errs[#errs + 1] = (e.name or "?") .. ": " .. e.error end
    end
    t.assert_eq(#errs, 0, "存在错误条目:\n" .. table.concat(errs, "\n"))
  end)
end)

t.describe("workarounds: frontmatter 必填字段", function()
  -- list() 暴露 name/scope/enabled/symptom/introduced/removal_condition。
  for _, e in ipairs(list) do
    if not e.error then
      t.it(e.name .. " 字段齐全", function()
        t.assert_type(e.name, "string")
        t.assert_type(e.scope, "string")
        t.assert_type(e.symptom, "string")
        t.assert_type(e.introduced, "string")
        t.assert_type(e.removal_condition, "string")
        t.assert_type(e.enabled, "boolean")
      end)
    end
  end
end)

t.describe("workarounds: status 查询", function()
  local first = list[1] and list[1].name
  t.it("已注册项 status 形状正确", function()
    t.assert_true(first ~= nil, "注册表为空")
    local s = w.status(first)
    t.assert_type(s, "table")
    t.assert_type(s.name, "string")
    t.assert_type(s.scope, "string")
    t.assert_type(s.applied, "boolean")
  end)
  t.it("未知名称 status 返回 nil", function()
    t.assert_nil(w.status("nonexistent.nonexistent"))
  end)
end)
