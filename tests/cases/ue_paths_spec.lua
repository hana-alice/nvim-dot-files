-- tests/cases/ue_paths_spec.lua
-- utils.ue_paths 过滤行为回归。

local t = require("tests.harness")
t.bootstrap()

local up = require("utils.ue_paths")

t.describe("ue_paths: is_blocked", function()
  for _, p in ipairs({
    "C:/proj/Intermediate/foo.cpp",
    "/proj/Binaries/bar.cpp",
    "/proj/.git/config",
    "/proj/Saved/x.log",
  }) do
    t.it("阻断 " .. p, function()
      t.assert_true(up.is_blocked(p), p .. " 应被阻断")
    end)
  end
  t.it("不阻断普通源码", function()
    t.assert_false(up.is_blocked("/proj/Source/MyActor.cpp"))
  end)
end)

t.describe("ue_paths: is_searchable", function()
  t.it("foo.cpp 可搜索", function()
    t.assert_true(up.is_searchable("/proj/Source/foo.cpp"))
  end)
  t.it("foo.txt 不可搜索（非代码扩展）", function()
    t.assert_false(up.is_searchable("/proj/Source/foo.txt"))
  end)
  t.it("Intermediate 下的 .cpp 不可搜索", function()
    t.assert_false(up.is_searchable("/proj/Intermediate/foo.cpp"))
  end)
end)

t.describe("ue_paths: filter 保序", function()
  t.it("只保留可搜索项且保持顺序", function()
    local input = {
      "/proj/Source/a.cpp",
      "/proj/Intermediate/b.cpp",
      "/proj/Source/c.h",
      "/proj/Source/d.txt",
    }
    local out = up.filter(input)
    t.assert_eq(#out, 2)
    t.assert_eq(out[1], "/proj/Source/a.cpp")
    t.assert_eq(out[2], "/proj/Source/c.h")
  end)
end)
