-- tests/cases/utils_spec.lua
-- 工具函数加载：utils 下关键模块可 require 且核心导出存在。
-- 注意：utils.ue_goto 是子模块命名空间（无 init.lua），因此测试其具体子模块。

local t = require("tests.harness")
t.bootstrap()

t.describe("utils.code_search", function()
  local cs = require("utils.code_search")
  t.it("返回 table", function() t.assert_type(cs, "table") end)
  t.it("stream 是 function", function() t.assert_type(cs.stream, "function") end)
  t.it("is_indexed 是 function", function() t.assert_type(cs.is_indexed, "function") end)
  t.it("current_backend 是 function", function() t.assert_type(cs.current_backend, "function") end)
end)

t.describe("utils.log", function()
  local log = require("utils.log")
  t.it("返回 table", function() t.assert_type(log, "table") end)
  for _, fn in ipairs({ "info", "warn", "error", "debug", "install_commands" }) do
    t.it(fn .. " 是 function", function() t.assert_type(log[fn], "function") end)
  end
end)

t.describe("utils.ue_paths", function()
  local up = require("utils.ue_paths")
  t.it("返回 table", function() t.assert_type(up, "table") end)
  t.it("is_blocked 是 function", function() t.assert_type(up.is_blocked, "function") end)
  t.it("is_searchable 是 function", function() t.assert_type(up.is_searchable, "function") end)
  t.it("filter 是 function", function() t.assert_type(up.filter, "function") end)
  t.it("BLOCKLIST_FRAGMENTS 是非空 table", function()
    t.assert_type(up.BLOCKLIST_FRAGMENTS, "table")
    t.assert_true(#up.BLOCKLIST_FRAGMENTS > 0)
  end)
end)

t.describe("utils.ue_goto 子模块", function()
  for _, sub in ipairs({ "jumper", "provider", "location", "symbol", "cache" }) do
    t.it("utils.ue_goto." .. sub .. " 返回 table", function()
      t.assert_type(require("utils.ue_goto." .. sub), "table")
    end)
  end
  t.it("jumper.jump 是 function", function()
    t.assert_type(require("utils.ue_goto.jumper").jump, "function")
  end)
  t.it("provider.sync_locations 是 function", function()
    t.assert_type(require("utils.ue_goto.provider").sync_locations, "function")
  end)
end)
