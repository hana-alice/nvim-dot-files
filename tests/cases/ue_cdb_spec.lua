-- tests/cases/ue_cdb_spec.lua
-- ue.cdb 子模块契约：json / paths / shaders。
-- 迁移自 scripts/headless_smoke.lua 的对应断言。

local t = require("tests.harness")
t.bootstrap()

t.describe("ue.cdb.json", function()
  local json = require("ue.cdb.json")

  t.it("template_entry happy path", function()
    local e = json.template_entry({ { file = "x.cpp", arguments = { "clang++" } } })
    t.assert_eq(e.file, "x.cpp")
  end)
  t.it("program 来自 arguments", function()
    t.assert_eq(json.program({ arguments = { "clang++" } }), "clang++")
  end)
  t.it("program 来自 command", function()
    t.assert_eq(json.program({ command = '"clang.exe" -c x' }), "clang.exe")
  end)
  t.it("template_entry empty 返回 table", function()
    t.assert_type(json.template_entry({}), "table")
  end)
end)

t.describe("ue.cdb.paths", function()
  local paths = require("ue.cdb.paths")

  t.it("targets 形状正确", function()
    local tg = paths.targets({ engine_root = "/x" })
    t.assert_eq(#tg, 2)
    t.assert_eq(tg[1], "/x/compile_commands.json")
  end)
  t.it("candidates 不存在 root 返回 table", function()
    local c = paths.candidates({ engine_root = "/nonexistent_xyz_12345" }, {})
    t.assert_type(c, "table")
  end)
end)

t.describe("ue.cdb.shaders", function()
  local shaders = require("ue.cdb.shaders")

  t.it("augment 空列表返回 '[]'", function()
    t.assert_eq(shaders.augment("[]", {}, {}), "[]")
  end)
  t.it("make_entry 形状正确", function()
    local e = shaders.make_entry("/s/x.usf",
      { directory = "/d", arguments = { "clang++" } }, { "/inc" })
    t.assert_eq(e.file, "/s/x.usf")
    t.assert_eq(e.directory, "/d")
    t.assert_eq(e.arguments[1], "clang++")
    t.assert_eq(e.arguments[2], "-x")
  end)
end)
