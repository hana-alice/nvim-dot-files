-- tests/cases/ue_api_spec.lua
-- ue 公共 API 冻结：PUBLIC_TABLES 非空 table、PUBLIC_FUNCTIONS 为 function。
-- 迁移自 scripts/headless_smoke.lua 的对应断言。

local t = require("tests.harness")
t.bootstrap()

local PUBLIC_TABLES = {
  "FT_CPP", "FT_SHADER", "FT_CODE", "FT_CONFIG", "FT_ALL",
  "FT_GTAGS", "GLOBS_CODE", "GLOBS_ALL",
}

local PUBLIC_FUNCTIONS = {
  "clangd_cmd", "clangd_root", "clangd_start_root", "current_platform", "platform_path_priorities",
  "android_build_command", "picker_options", "picker_project_options",
  "current_scope_picker_options", "cached_grep_file_list", "cached_code_file_list",
  "cached_files", "cached_grep", "statusline_status", "index_status", "semantic_index_snapshot", "index_now",
  "index_hot", "index_full", "ue_roots", "gtags_rebuild_shaders",
  "gtags_references", "gtags_definition", "launch_app", "toggle_log",
  "toggle_debug_log", "prepare_headless", "ai_context",
}

t.describe("ue: 公共表冻结", function()
  local ue = require("ue")
  for _, k in ipairs(PUBLIC_TABLES) do
    t.it("ue." .. k .. " 是非空 table", function()
      local v = ue[k]
      t.assert_type(v, "table", "ue." .. k)
      t.assert_true(#v > 0, "ue." .. k .. " 应非空")
    end)
  end
end)

t.describe("ue: 公共函数冻结", function()
  local ue = require("ue")
  for _, fn in ipairs(PUBLIC_FUNCTIONS) do
    t.it("ue." .. fn .. " 是 function", function()
      t.assert_type(ue[fn], "function", "ue." .. fn)
    end)
  end
end)

t.describe("ue.clangd_cmd", function()
  local ue = require("ue")

  t.it("function-arg-placeholders 对 clangd 22 使用显式布尔值", function()
    local cmd = ue.clangd_cmd()
    local has_explicit = false
    local has_bare = false

    for _, arg in ipairs(cmd) do
      if arg == "--function-arg-placeholders=true" then
        has_explicit = true
      elseif arg == "--function-arg-placeholders" then
        has_bare = true
      end
    end

    t.assert_true(has_explicit, "clangd 22 需要 --function-arg-placeholders=true")
    t.assert_false(has_bare, "clangd 22 不接受裸 --function-arg-placeholders")
  end)

  t.it("禁用外部 idx/config，索引仅由 nvim 管理的 CDB 与 LSP command 驱动", function()
    local cmd = ue.clangd_cmd()
    t.assert_true(vim.tbl_contains(cmd, "--enable-config=false"))
    for _, arg in ipairs(cmd) do
      t.assert_false(arg:find("--index-file=", 1, true) == 1,
        "monolithic External.File/index-file cannot prove source definitions")
    end
  end)
end)

t.describe("ue.android_build_command（SO-only）", function()
  local ue = require("ue")

  t.it("SO 命令走两阶段 action 脚本，普通 UEBuild 保持原状", function()
    local old_platform = vim.env.UE_TARGET_PLATFORM
    local old_configuration = vim.env.UE_TARGET_CONFIGURATION
    local old_target = vim.env.UE_BUILD_TARGET
    vim.env.UE_TARGET_PLATFORM = "Android"
    vim.env.UE_TARGET_CONFIGURATION = "Test"
    vim.env.UE_BUILD_TARGET = "SampleGame"

    local ctx = {
      engine_root = "C:/FakeUE",
      project_root = "C:/FakeProject",
      uproject = "C:/FakeProject/SampleGame.uproject",
    }
    local windows_host = require("utils.platform.windows")
    local normal_cmd, normal_err = ue._android_build_command_for_test(ctx, { host_driver = windows_host })
    local so_cmd, so_err = ue._android_build_command_for_test(ctx, {
      skip_deploy = true,
      host_driver = windows_host,
    })

    vim.env.UE_TARGET_PLATFORM = old_platform
    vim.env.UE_TARGET_CONFIGURATION = old_configuration
    vim.env.UE_BUILD_TARGET = old_target

    t.assert_true(normal_cmd ~= nil, tostring(normal_err))
    t.assert_true(so_cmd ~= nil, tostring(so_err))
    local normal_text = table.concat(normal_cmd, " ")
    local so_text = table.concat(so_cmd, " ")
    t.assert_contains(normal_text, "Build.bat")
    t.assert_contains(normal_text, "SampleGame Android Test")
    t.assert_false(normal_text:find("ue_android_so_build.ps1", 1, true) ~= nil)
    t.assert_contains(so_text, "ue_android_so_build.ps1")
    t.assert_contains(so_text, "-Target SampleGame")
    t.assert_contains(so_text, "-Platform Android")
    t.assert_contains(so_text, "-Configuration Test")
    t.assert_false(so_text:find("-SkipDeploy", 1, true) ~= nil)
  end)

  t.it("SO 脚本导出并执行 action graph，不使用失效的 -SkipDeploy", function()
    local script = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/scripts/ue_android_so_build.ps1"), "\n")
    t.assert_contains(script, "-WriteOutdatedActions=")
    t.assert_contains(script, '"-Mode=Execute"')
    t.assert_contains(script, "completed without Android deploy/APK packaging")
    t.assert_false(script:find('"-SkipDeploy"', 1, true) ~= nil)
  end)

  t.it("运行中的 build terminal 可隐藏，任务退出后才恢复 wipe", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local section = source:match(
      "local function open_terminal_command%b().-\nend\n\n%-%- =========================================================================="
    )
    t.assert_true(section ~= nil, "未找到 open_terminal_command 实现")
    local hide_at = section:find('vim.bo[buf].bufhidden = "hide"', 1, true)
    local termopen_at = section:find("vim.fn.termopen", 1, true)
    local wipe_at = section:find('vim.bo[buf].bufhidden = "wipe"', 1, true)
    t.assert_true(hide_at ~= nil and termopen_at ~= nil and hide_at < termopen_at,
      "任务启动前 terminal 必须使用 bufhidden=hide，关窗不得终止 build")
    t.assert_true(wipe_at ~= nil and wipe_at > termopen_at,
      "任务退出后 terminal 必须恢复 bufhidden=wipe")
  end)

  t.it("项目和 SO 发现不固定 Client 项目路径", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    t.assert_false(source:find("Source/SampleGame", 1, true) ~= nil,
      "项目发现必须从 .uproject 派生，不能固定 Source/SampleGame")
    t.assert_false(source:find("SampleGame-arm64.so", 1, true) ~= nil,
      "SO 发现必须从动态 Target 派生")
  end)

  t.it("SO deploy 命令锁定 serial/package/当前配置产物", function()
    local root = vim.fn.tempname()
    local project_dir = root .. "/Source/SampleGame"
    local so = project_dir .. "/Binaries/Android/SampleGame-Android-Test-arm64.so"
    vim.fn.mkdir(vim.fs.dirname(so), "p")
    vim.fn.writefile({ "so" }, so)
    vim.fn.writefile({ "{}" }, project_dir .. "/SampleGame.uproject")

    local old_platform = vim.env.UE_TARGET_PLATFORM
    local old_configuration = vim.env.UE_TARGET_CONFIGURATION
    local old_target = vim.env.UE_BUILD_TARGET
    vim.env.UE_TARGET_PLATFORM = "Android"
    vim.env.UE_TARGET_CONFIGURATION = "Test"
    vim.env.UE_BUILD_TARGET = "SampleGame"
    local cmd, err = ue._android_so_deploy_command_for_test({
      engine_root = "C:/FakeUE",
      project_root = root,
      uproject = project_dir .. "/SampleGame.uproject",
    }, "SERIAL-USB", "com.example.samplegame")
    vim.env.UE_TARGET_PLATFORM = old_platform
    vim.env.UE_TARGET_CONFIGURATION = old_configuration
    vim.env.UE_BUILD_TARGET = old_target
    vim.fn.delete(root, "rf")

    t.assert_true(cmd ~= nil, tostring(err))
    local text = table.concat(cmd, " ")
    t.assert_contains(text, "ue_android_so_deploy.ps1")
    t.assert_contains(text, "-Serial SERIAL-USB")
    t.assert_contains(text, "-Package com.example.samplegame")
    t.assert_contains(text, "SampleGame-Android-Test-arm64.so")
  end)

  t.it("SO deploy 从匹配配置的 UBT receipt 解析真实通用文件名", function()
    local root = vim.fn.tempname()
    local project_dir = root .. "/Source/SampleGame"
    local binaries_dir = project_dir .. "/Binaries/Android"
    local generic_so = binaries_dir .. "/SampleGame-arm64.so"
    vim.fn.mkdir(binaries_dir, "p")
    vim.fn.writefile({ "so" }, generic_so)
    vim.fn.writefile({ "{}" }, project_dir .. "/SampleGame.uproject")
    vim.fn.writefile({ vim.json.encode({
      TargetName = "SampleGame",
      Platform = "Android",
      Configuration = "Test",
      Launch = "$(ProjectDir)/Binaries/Android/SampleGame-arm64.so",
      BuildProducts = {
        { Path = "$(ProjectDir)/Binaries/Android/SampleGame-arm64.so", Type = "Executable" },
      },
    }) }, binaries_dir .. "/SampleGame.target")

    local old_platform = vim.env.UE_TARGET_PLATFORM
    local old_configuration = vim.env.UE_TARGET_CONFIGURATION
    local old_target = vim.env.UE_BUILD_TARGET
    vim.env.UE_TARGET_PLATFORM = "Android"
    vim.env.UE_TARGET_CONFIGURATION = "Test"
    vim.env.UE_BUILD_TARGET = "SampleGame"
    local cmd, err = ue._android_so_deploy_command_for_test({
      engine_root = "C:/FakeUE",
      project_root = root,
      uproject = project_dir .. "/SampleGame.uproject",
    }, "SERIAL-USB", "com.example.samplegame")
    vim.env.UE_TARGET_PLATFORM = old_platform
    vim.env.UE_TARGET_CONFIGURATION = old_configuration
    vim.env.UE_BUILD_TARGET = old_target
    vim.fn.delete(root, "rf")

    t.assert_true(cmd ~= nil, tostring(err))
    t.assert_contains(table.concat(cmd, " "), "SampleGame-arm64.so")
  end)

  t.it("SO deploy 不把 receipt 中的插件 SO 当成主目标", function()
    local root = vim.fn.tempname()
    local project_dir = root .. "/Source/SampleGame"
    local binaries_dir = project_dir .. "/Binaries/Android"
    local target_so = binaries_dir .. "/SampleGame-arm64.so"
    local plugin_so = binaries_dir .. "/libTelemetryPlugin.so"
    vim.fn.mkdir(binaries_dir, "p")
    vim.fn.writefile({ "target" }, target_so)
    vim.fn.writefile({ "plugin" }, plugin_so)
    vim.fn.writefile({ "{}" }, project_dir .. "/SampleGame.uproject")
    vim.fn.writefile({ vim.json.encode({
      TargetName = "SampleGame",
      Platform = "Android",
      Configuration = "Test",
      BuildProducts = {
        { Path = "$(ProjectDir)/Binaries/Android/libTelemetryPlugin.so", Type = "DynamicLibrary" },
        { Path = "$(ProjectDir)/Binaries/Android/SampleGame-arm64.so", Type = "Executable" },
      },
    }) }, binaries_dir .. "/SampleGame.target")

    local old_platform = vim.env.UE_TARGET_PLATFORM
    local old_configuration = vim.env.UE_TARGET_CONFIGURATION
    local old_target = vim.env.UE_BUILD_TARGET
    vim.env.UE_TARGET_PLATFORM = "Android"
    vim.env.UE_TARGET_CONFIGURATION = "Test"
    vim.env.UE_BUILD_TARGET = "SampleGame"
    local cmd, err = ue._android_so_deploy_command_for_test({
      engine_root = "C:/FakeUE",
      project_root = root,
      uproject = project_dir .. "/SampleGame.uproject",
    }, "SERIAL-USB", "com.example.samplegame")
    vim.env.UE_TARGET_PLATFORM = old_platform
    vim.env.UE_TARGET_CONFIGURATION = old_configuration
    vim.env.UE_BUILD_TARGET = old_target
    vim.fn.delete(root, "rf")

    t.assert_true(cmd ~= nil, tostring(err))
    local text = table.concat(cmd, " ")
    t.assert_contains(text, "SampleGame-arm64.so")
    t.assert_false(text:find("libTelemetryPlugin.so", 1, true) ~= nil,
      "receipt fallback 不得按 BuildProducts 顺序误选插件 SO")
  end)

  t.it("SO deploy 遇到多个主产物候选时拒绝猜测", function()
    local root = vim.fn.tempname()
    local project_dir = root .. "/Source/SampleGame"
    local binaries_dir = project_dir .. "/Binaries/Android"
    vim.fn.mkdir(binaries_dir, "p")
    vim.fn.writefile({ "generic" }, binaries_dir .. "/SampleGame-arm64.so")
    vim.fn.writefile({ "configured" }, binaries_dir .. "/SampleGame-Android-Test-arm64.so")
    vim.fn.writefile({ "{}" }, project_dir .. "/SampleGame.uproject")
    vim.fn.writefile({ vim.json.encode({
      TargetName = "SampleGame",
      Platform = "Android",
      Configuration = "Test",
      BuildProducts = {
        { Path = "$(ProjectDir)/Binaries/Android/SampleGame-arm64.so", Type = "Executable" },
        { Path = "$(ProjectDir)/Binaries/Android/SampleGame-Android-Test-arm64.so", Type = "Executable" },
      },
    }) }, binaries_dir .. "/SampleGame.target")

    local old_platform = vim.env.UE_TARGET_PLATFORM
    local old_configuration = vim.env.UE_TARGET_CONFIGURATION
    local old_target = vim.env.UE_BUILD_TARGET
    vim.env.UE_TARGET_PLATFORM = "Android"
    vim.env.UE_TARGET_CONFIGURATION = "Test"
    vim.env.UE_BUILD_TARGET = "SampleGame"
    local cmd, err = ue._android_so_deploy_command_for_test({
      engine_root = "C:/FakeUE",
      project_root = root,
      uproject = project_dir .. "/SampleGame.uproject",
    }, "SERIAL-USB", "com.example.samplegame")
    vim.env.UE_TARGET_PLATFORM = old_platform
    vim.env.UE_TARGET_CONFIGURATION = old_configuration
    vim.env.UE_BUILD_TARGET = old_target
    vim.fn.delete(root, "rf")

    t.assert_nil(cmd, "多个匹配主产物时不得按 receipt 顺序猜测")
    t.assert_contains(tostring(err), "Android SO not found")
  end)

  t.it("SO deploy 不降级使用其他配置或通用文件名产物", function()
    local root = vim.fn.tempname()
    local project_dir = root .. "/Source/SampleGame"
    local generic_so = project_dir .. "/Binaries/Android/SampleGame-arm64.so"
    vim.fn.mkdir(vim.fs.dirname(generic_so), "p")
    vim.fn.writefile({ "wrong configuration" }, generic_so)
    vim.fn.writefile({ "{}" }, project_dir .. "/SampleGame.uproject")
    vim.fn.writefile({ vim.json.encode({
      TargetName = "SampleGame",
      Platform = "Android",
      Configuration = "Development",
      Launch = "$(ProjectDir)/Binaries/Android/SampleGame-arm64.so",
      BuildProducts = {
        { Path = "$(ProjectDir)/Binaries/Android/SampleGame-arm64.so", Type = "Executable" },
      },
    }) }, project_dir .. "/Binaries/Android/SampleGame.target")

    local old_platform = vim.env.UE_TARGET_PLATFORM
    local old_configuration = vim.env.UE_TARGET_CONFIGURATION
    local old_target = vim.env.UE_BUILD_TARGET
    vim.env.UE_TARGET_PLATFORM = "Android"
    vim.env.UE_TARGET_CONFIGURATION = "Test"
    vim.env.UE_BUILD_TARGET = "SampleGame"
    local cmd, err = ue._android_so_deploy_command_for_test({
      engine_root = "C:/FakeUE",
      project_root = root,
      uproject = project_dir .. "/SampleGame.uproject",
    }, "SERIAL-USB", "com.example.samplegame")
    vim.env.UE_TARGET_PLATFORM = old_platform
    vim.env.UE_TARGET_CONFIGURATION = old_configuration
    vim.env.UE_BUILD_TARGET = old_target
    vim.fn.delete(root, "rf")

    t.assert_true(cmd == nil, "仅有通用 SO 时必须拒绝部署")
    t.assert_contains(tostring(err), "Android SO not found")
  end)

  t.it("SO deploy 捕获并精确恢复已安装文件 metadata", function()
    local script = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/scripts/ue_android_so_deploy.ps1"), "\n")
    t.assert_contains(script, "packageInfo.txt")
    t.assert_contains(script, "Installed APK baseline mismatch")
    t.assert_contains(script, "versionCode=")
    t.assert_contains(script, "function Get-Sha256Hex")
    t.assert_contains(script, "$sha256.ComputeHash($stream)")
    t.assert_false(script:find("Get-FileHash", 1, true) ~= nil,
      "部署脚本不得依赖可能未加载的 Microsoft.PowerShell.Utility cmdlet")
    t.assert_contains(script, '"stat", "-c", "%u"')
    t.assert_contains(script, '"stat", "-c", "%g"')
    t.assert_contains(script, '"stat", "-c", "%a"')
    t.assert_contains(script, '"stat", "-c", "%C"')
    t.assert_contains(script, '"chcon", $Metadata.Context')
    t.assert_contains(script, "Assert-RemoteLibraryMetadata")
    t.assert_contains(script, "function Resolve-RootTransport")
    t.assert_contains(script, "function Invoke-AdbRoot")
    local _, rawSuCount = script:gsub('"shell", "su", "0"', "")
    t.assert_eq(rawSuCount, 2,
      "su 0 只允许出现在能力探测和统一 root wrapper 中")
    t.assert_contains(script, "function Wait-PackageStopped")
    t.assert_contains(script, "replacement verified; package remains stopped")
    t.assert_false(script:find("function Start-Package", 1, true) ~= nil,
      "SO deploy 不得拥有隐式启动入口")
    t.assert_false(script:find('"shell", "monkey"', 1, true) ~= nil,
      "SO deploy 完成或回滚后不得自动启动应用")
    t.assert_false(script:find("Wait-ForMappedLibrary", 1, true) ~= nil,
      "启动与部署分离后不得保留运行时 maps 验证")
    t.assert_false(script:find('"/proc/', 1, true) ~= nil,
      "SO deploy 不得通过读取运行进程来隐式耦合启动")
    t.assert_false(script:find("system:system", 1, true) ~= nil,
      "不得假设设备安装目录固定属于 system:system")
  end)

  t.it("SO deploy 替换前等待旧 PID 消失且等待有界", function()
    if vim.fn.executable("powershell.exe") ~= 1 then return end
    local config = vim.fn.stdpath("config")
    local result = vim.system({
      "powershell.exe",
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      config .. "/tests/fixtures/android_so_deploy/process_wait_spec.ps1",
      "-DeployScript",
      config .. "/scripts/ue_android_so_deploy.ps1",
    }, { text = true }):wait()
    t.assert_eq(result.code, 0, result.stderr or result.stdout)
    t.assert_contains(result.stdout or "", "PASS package stop polling + bounded timeout")
  end)

  t.it("SO deploy 按设备实测能力选择 root transport", function()
    if vim.fn.executable("powershell.exe") ~= 1 then return end
    local config = vim.fn.stdpath("config")
    local result = vim.system({
      "powershell.exe",
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      config .. "/tests/fixtures/android_so_deploy/root_transport_spec.ps1",
      "-DeployScript",
      config .. "/scripts/ue_android_so_deploy.ps1",
    }, { text = true }):wait()
    t.assert_eq(result.code, 0, result.stderr or result.stdout)
    t.assert_contains(result.stdout or "", "PASS root transport capability selection")
  end)

  t.it("SO deploy 在 debuggable 无 root 设备走 run-as startup-agent transport", function()
    if vim.fn.executable("powershell.exe") ~= 1 then return end
    local config = vim.fn.stdpath("config")
    local result = vim.system({
      "powershell.exe",
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      config .. "/tests/fixtures/android_so_deploy/run_as_transport_spec.ps1",
      "-DeployScript",
      config .. "/scripts/ue_android_so_deploy.ps1",
    }, { text = true }):wait()
    t.assert_eq(result.code, 0, result.stderr or result.stdout)
    t.assert_contains(result.stdout or "", "PASS debuggable run-as transport")
  end)

  t.it("SO startup agent 保持 APK identity 不变并在应用类执行前重定向 ClassLoader", function()
    if vim.fn.executable("powershell.exe") ~= 1 then return end
    local config = vim.fn.stdpath("config")
    local result = vim.system({
      "powershell.exe",
      "-NoLogo",
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      config .. "/tests/fixtures/android_so_deploy/startup_agent_spec.ps1",
      "-DeployScript",
      config .. "/scripts/ue_android_so_deploy.ps1",
      "-LaunchScript",
      config .. "/scripts/ue_android_so_launch.ps1",
      "-AgentSource",
      config .. "/scripts/ue_android_so_agent.c",
    }, { text = true }):wait()
    t.assert_eq(result.code, 0, result.stderr or result.stdout)
    t.assert_contains(result.stdout or "", "PASS app-private startup agent contract")
  end)
end)

t.describe("ue.project_index_dirs（nested project scan scope）", function()
  local ue = require("ue")

  local function mkdir(path)
    vim.fn.mkdir(path, "p")
  end

  local function write_file(path, content)
    local f = assert(io.open(path, "wb"))
    f:write(content or "")
    f:close()
  end

  local function contains(xs, want)
    for _, value in ipairs(xs or {}) do
      if value == want then return true end
    end
    return false
  end

  t.it("nested uproject 默认只扫描项目锚点，不吞掉 project_root/Source 旁支", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_nested_project"
    mkdir(root .. "/Source/SampleGame/Source")
    mkdir(root .. "/Source/SampleGame/Plugins")
    mkdir(root .. "/Source/SampleGame/TypeScript")
    mkdir(root .. "/Source/SampleGame/typescript")
    mkdir(root .. "/Source/Config/Raw/Tables")
    write_file(root .. "/Source/SampleGame/SampleGame.uproject", "{}")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(contains(dirs, "Source/SampleGame/Source"),
      "应扫描 nested 项目的 Source，实际=" .. vim.inspect(dirs))
    t.assert_true(contains(dirs, "Source/SampleGame/Plugins"), "应扫描 nested 项目的 Plugins")
    t.assert_false(contains(dirs, "Source"),
      "不得退回扫描整个 project_root/Source（会把 Config/SDK/生成数据吞进 cindex）")
    t.assert_false(ue._project_scan_roots_match_for_test({ project_root = root }, nil),
      "旧缓存没有 scan roots 身份时必须失效")
    t.assert_true(ue._project_scan_roots_match_for_test({ project_root = root }, dirs),
      "相同 scan roots 才能复用缓存")
    local case_dirs = ue._existing_relative_dirs_for_test(root, {
      "Source/SampleGame/TypeScript",
      "Source/SampleGame/typescript",
    })
    t.assert_eq(#case_dirs, vim.fn.has("win32") == 1 and 1 or 2,
      "Windows 上大小写等价的扫描根不得让 fd 重复遍历同一棵树")

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("standard layout 仍保留原有根级默认目录", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_standard_project"
    mkdir(root .. "/Source")
    mkdir(root .. "/Plugins")
    write_file(root .. "/Game.uproject", "{}")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(contains(dirs, "Source"))
    t.assert_true(contains(dirs, "Plugins"))

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("nested layout 有多个 uproject 时保守回退根级目录", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_ambiguous_nested_project"
    mkdir(root .. "/Source/SampleGame/Source")
    write_file(root .. "/Source/SampleGame/A.uproject", "{}")
    write_file(root .. "/Source/SampleGame/B.uproject", "{}")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(contains(dirs, "Source"), "多个 .uproject 时不得擅自选择项目锚点")
    t.assert_false(contains(dirs, "Source/SampleGame/Source"))

    pcall(vim.fn.delete, root, "rf")
  end)
end)
