-- tests/cases/platform_spec.lua
-- 平台驱动契约：共享接口一致；宿主专属工具只由对应驱动暴露。

local t = require("tests.harness")
t.bootstrap()

local IFACE = {
  "shell", "open_path", "reveal_file", "cmd_quote", "host_path",
  "default_clangd_candidates", "default_lldb_dap_paths",
  "default_lldb_server_paths", "ue_build_entry", "ue_uat_entry",
}

local function assert_entry(driver, fn_name, expected_path, expected_reason)
  local path, reason = driver[fn_name]("/EngineRoot")
  t.assert_eq(path, expected_path, driver.id .. "." .. fn_name .. " path mismatch")
  t.assert_eq(reason, expected_reason, driver.id .. "." .. fn_name .. " reason mismatch")
end

local function assert_plan_entry(driver, fn_name, expected_executable, expected_script)
  local plan, reason = driver[fn_name]("C:/Engine Root")
  t.assert_eq(reason, nil)
  t.assert_eq(plan.executable, expected_executable)
  t.assert_contains(plan.metadata.script, expected_script)
end

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

t.describe("platform: host tool 解析", function()
  t.it("Windows 只暴露 bat 与 PowerShell 宿主能力", function()
    local m = require("utils.platform.windows")
    assert_plan_entry(m, "ue_build_entry", "cmd.exe", "Build.bat")
    assert_plan_entry(m, "ue_uat_entry", "cmd.exe", "RunUAT.bat")
    assert_entry(m, "powershell_entry", "powershell.exe", nil)
    t.assert_eq(m.xcrun_entry, nil)
    t.assert_eq(m.security_entry, nil)
    t.assert_eq(m.plutil_entry, nil)
  end)

  t.it("macOS 只暴露 shell 与 Apple 原生工具，不暴露 PowerShell", function()
    local m = require("utils.platform.macos")
    assert_entry(m, "ue_build_entry", "/EngineRoot/Engine/Build/BatchFiles/Mac/Build.sh", nil)
    assert_entry(m, "ue_uat_entry", "/EngineRoot/Engine/Build/BatchFiles/RunUAT.sh", nil)
    assert_entry(m, "xcrun_entry", "/usr/bin/xcrun", nil)
    assert_entry(m, "security_entry", "/usr/bin/security", nil)
    assert_entry(m, "plutil_entry", "/usr/bin/plutil", nil)
    t.assert_eq(m.powershell_entry, nil)
  end)

  t.it("Linux 不伪装 Apple 或 Windows 宿主能力", function()
    local m = require("utils.platform.linux")
    assert_entry(m, "ue_build_entry", "/EngineRoot/Engine/Build/BatchFiles/Linux/Build.sh", nil)
    assert_entry(m, "ue_uat_entry", "/EngineRoot/Engine/Build/BatchFiles/RunUAT.sh", nil)
    t.assert_eq(m.xcrun_entry, nil)
    t.assert_eq(m.security_entry, nil)
    t.assert_eq(m.plutil_entry, nil)
    t.assert_eq(m.powershell_entry, nil)
  end)

  t.it("stub 只保留共享接口", function()
    local m = require("utils.platform.stub")
    assert_entry(m, "ue_build_entry", nil, "unavailable")
    assert_entry(m, "ue_uat_entry", nil, "unavailable")
    t.assert_eq(m.xcrun_entry, nil)
    t.assert_eq(m.security_entry, nil)
    t.assert_eq(m.plutil_entry, nil)
    t.assert_eq(m.powershell_entry, nil)
  end)
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
