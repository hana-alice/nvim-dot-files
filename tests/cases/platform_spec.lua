-- tests/cases/platform_spec.lua
-- 平台驱动契约：共享接口一致；宿主专属工具只由对应驱动暴露。

local t = require("tests.harness")
t.bootstrap()

local IFACE = {
  "shell", "shell_entry", "open_path", "reveal_file", "cmd_quote", "host_path",
  "launch_process_plan", "follow_file_plan", "default_target",
  "default_clangd_candidates", "default_lldb_dap_paths",
  "default_lldb_server_paths", "python_candidates", "ue_build_entry", "ue_uat_entry",
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
    local powershell, powershell_err = m.shell_entry("powershell")
    t.assert_eq(powershell, nil)
    t.assert_contains(powershell_err, "unsupported shell")
    t.assert_eq(#m.default_lldb_server_paths(), 0)
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

t.describe("platform: shell 是独立执行维度", function()
  local shell = require("utils.platform.shell")

  t.it("Windows host 区分 cmd 与 PowerShell", function()
    local m = require("utils.platform.windows")
    local cmd = m.shell_entry("cmd")
    local powershell = m.shell_entry("powershell")
    t.assert_eq(cmd, "cmd.exe")
    t.assert_true(powershell == "pwsh" or powershell == "powershell.exe")
  end)

  t.it("Windows process plan 只转换 host path，不改写 UE 参数", function()
    local plan = require("utils.platform.windows").launch_process_plan({
      executable = "C:/UE/UnrealEditor.exe",
      cwd = "C:/UE",
      args = { "C:/Project/Game.uproject", "/Game/Maps/Main", "-log" },
    })
    local script = table.concat(plan.args, " ")
    t.assert_contains(script, "C:\\Project\\Game.uproject")
    t.assert_contains(script, "/Game/Maps/Main")
    t.assert_false(script:find("\\Game\\Maps\\Main", 1, true) ~= nil)
  end)

  t.it("Windows file follow 在转换分隔符前解析 cwd", function()
    local plan = require("utils.platform.windows").follow_file_plan("C:/Project/Saved/Logs/Game.log")
    t.assert_eq(plan.cwd, "C:\\Project\\Saved\\Logs")
  end)

  t.it("macOS host 的默认与 posix shell 一致", function()
    local m = require("utils.platform.macos")
    t.assert_eq(m.shell_entry("default"), m.shell_entry("posix"))
    t.assert_true(m.shell_entry("posix"):match("zsh$") ~= nil)
  end)

  t.it("macOS 原生目录选择只由 host driver 规划", function()
    local plan = require("utils.platform.macos").folder_picker_plan('Open "Workspace"')
    t.assert_eq(plan.executable, "/usr/bin/osascript")
    t.assert_eq(plan.metadata.operation, "choose-folder")
    t.assert_contains(plan.args[2], "choose folder")
    t.assert_contains(plan.args[2], 'Open \\"Workspace\\"')
    t.assert_eq(require("utils.platform.windows").folder_picker_plan, nil)
    t.assert_eq(require("utils.platform.linux").folder_picker_plan, nil)
  end)

  t.it("macOS 独占构建进程快照能力", function()
    local plan = require("utils.platform.macos").build_process_snapshot_plan()
    t.assert_eq(plan.executable, "/bin/ps")
    t.assert_contains(plan.args, "pid=,ppid=,state=,etime=,%cpu=,%mem=,command=")
    t.assert_eq(plan.metadata.operation, "build-process-snapshot")
    t.assert_eq(require("utils.platform.windows").build_process_snapshot_plan, nil)
    t.assert_eq(require("utils.platform.linux").build_process_snapshot_plan, nil)
    t.assert_eq(require("utils.platform.stub").build_process_snapshot_plan, nil)
  end)

  t.it("未声明 Android DAP 的 host 不暴露 NDK server", function()
    t.assert_eq(#require("utils.platform.macos").default_lldb_server_paths(), 0)
    t.assert_eq(#require("utils.platform.linux").default_lldb_server_paths(), 0)
  end)

  t.it("shell command builder 只负责 shell argv，不选择 host", function()
    local posix = shell.command("posix", "/bin/zsh", "printf ok")
    local pwsh = shell.command("powershell", "pwsh", "Write-Output ok")
    local cmd = shell.command("cmd", "cmd.exe", "call Build.bat")
    t.assert_eq(posix.executable, "/bin/zsh")
    t.assert_contains(posix.args, "printf ok")
    t.assert_eq(pwsh.executable, "pwsh")
    t.assert_contains(pwsh.args, "Write-Output ok")
    t.assert_eq(cmd.executable, "cmd.exe")
    t.assert_contains(cmd.args, "call Build.bat")
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
