-- tests/cases/fs_proc_spec.lua
-- ue.core.fs / ue.core.proc 纯函数行为回归。

local t = require("tests.harness")
t.bootstrap()

t.describe("ue.core.fs: 路径函数", function()
  local fs = require("ue.core.fs")

  t.it("norm 折叠反斜杠与尾斜杠", function()
    t.assert_eq(fs.norm("a\\b\\"), "a/b")
  end)
  t.it("join 用 / 连接", function()
    t.assert_eq(fs.join("a", "b"), "a/b")
  end)
  t.it("is_absolute_path(/a) = true", function()
    t.assert_true(fs.is_absolute_path("/a"))
  end)
  t.it("is_absolute_path(C:/a) = true", function()
    t.assert_true(fs.is_absolute_path("C:/a"))
  end)
  t.it("is_absolute_path(a/b) = false", function()
    t.assert_false(fs.is_absolute_path("a/b"))
  end)
  t.it("relative_to(/a, /a/b) = b", function()
    t.assert_eq(fs.relative_to("/a", "/a/b"), "b")
  end)
  t.it("common_ancestor({/a/b,/a/c}) = /a", function()
    t.assert_eq(fs.common_ancestor({ "/a/b", "/a/c" }), "/a")
  end)
end)

t.describe("ue.core.proc: first_executable", function()
  local proc = require("ue.core.proc")

  t.it("空候选列表返回 nil", function()
    t.assert_nil(proc.first_executable({}))
  end)
  t.it("全不可执行候选返回 nil", function()
    t.assert_nil(proc.first_executable({
      "/nonexistent/xyz_12345",
      "C:/nonexistent/xyz_12345.exe",
    }))
  end)
end)
