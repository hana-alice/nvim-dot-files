-- tests/cases/platform_spec.lua
-- 平台驱动契约：四个驱动接口形状一致 + 向后兼容标志。

local t = require("tests.harness")
t.bootstrap()

local IFACE = {
  "shell", "open_path", "reveal_file", "cmd_quote",
  "default_clangd_candidates", "default_lldb_dap_paths",
  "default_lldb_server_paths",
}

t.describe("platform: 驱动接口契约", function()
  for _, id in ipairs({ "windows", "macos", "linux", "stub" }) do
    t.it("driver " .. id .. " 实现完整接口", function()
      local m = require("utils.platform." .. id)
      t.assert_eq(m.id, id, "id 不匹配")
      for _, k in ipairs(IFACE) do
        t.assert_type(m[k], "function", id .. "." .. k .. " 缺失")
      end
    end)
  end
end)

t.describe("platform: 顶层模块", function()
  local p = require("utils.platform")

  t.it("id 是非空 string", function()
    t.assert_type(p.id, "string")
    t.assert_true(p.id ~= "", "id 不应为空")
  end)
  t.it("is_windows 是 boolean", function()
    t.assert_type(p.is_windows, "boolean")
  end)
  t.it("is_mac 是 boolean", function()
    t.assert_type(p.is_mac, "boolean")
  end)
  t.it("is_linux 是 boolean", function()
    t.assert_type(p.is_linux, "boolean")
  end)
  t.it("driver().shell() 返回非空", function()
    local s = p.driver().shell()
    t.assert_true(s and s ~= "", "shell() 不应为空")
  end)
  t.it("driver().cmd_quote() 非 nil", function()
    t.assert_true(p.driver().cmd_quote("a b") ~= nil)
  end)
end)
