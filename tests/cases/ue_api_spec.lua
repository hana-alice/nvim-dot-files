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
    -- 不变量是「**代码**不得固定项目路径」。文档注释里把 `Source/SampleGame/Source`
    -- 当作 `.ueprepare-scan-paths` 的**用法示例**是合法的，全文 find 分不清代码与注释，
    -- 所以只扫非注释行（跳过以 -- 开头的行）。
    local offenders = {}
    local lineno = 0
    for line in (source .. "\n"):gmatch("([^\n]*)\n") do
      lineno = lineno + 1
      if not line:match("^%s*%-%-") then
        if line:find("Source/SampleGame", 1, true) or line:find("SampleGame-arm64.so", 1, true) then
          offenders[#offenders + 1] = lineno .. ": " .. line:gsub("^%s+", "")
        end
      end
    end
    t.assert_eq(#offenders, 0,
      "项目/SO 发现必须从 .uproject / 动态 Target 派生，不能在代码里固定:\n  "
        .. table.concat(offenders, "\n  "))
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
  -- 扫描根推导的 owner 是 ue.core.scan_roots（契约：
  -- openspec/specs/project-scan-root-discovery）；直接针对该模块断言，
  -- 不经 ue.lua 再包一层 test seam。
  local scan_roots = require("ue.core.scan_roots")

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

  t.it("nested layout 有多个 uproject 时按模块声明界定范围（不回退根级）", function()
    -- 契约变更（openspec/specs/project-scan-root-discovery）：anchor 歧义时旧行为是回退到
    -- 裸 `Source`，那会把同层的配置表 / 内嵌 SDK / 打包工具重新吞进索引——正是白名单机制
    -- 当初要消除的东西。新契约要求由构建元数据推导出的具体模块子树界定范围。
    local root = vim.fn.tempname():gsub("\\", "/") .. "_ambiguous_nested_project"
    mkdir(root .. "/Source/SampleGame/Source")
    write_file(root .. "/Source/SampleGame/A.uproject", "{}")
    write_file(root .. "/Source/SampleGame/B.uproject", "{}")
    -- 同层工具链目录：无任何模块声明，不得被纳入
    mkdir(root .. "/Source/JDK/bin")
    write_file(root .. "/Source/JDK/bin/java.exe", "x")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(scan_roots.is_ambiguous_nested(root),
      "两个 .uproject（无论同目录还是分属两目录）都应判为歧义嵌套布局")
    t.assert_false(contains(dirs, "Source"),
      "歧义时不得退回裸 Source（会吞掉 Source/ 下的 SDK/配置表/打包工具）")
    t.assert_false(contains(dirs, "Source/JDK"),
      "不含模块声明的工具链目录不得成为扫描根，实际=" .. vim.inspect(dirs))
    t.assert_true(contains(dirs, "Source/SampleGame"),
      "应由推导给出含模块声明的具体子树，实际=" .. vim.inspect(dirs))

    pcall(vim.fn.delete, root, "rf")
  end)

  -- ── 扫描根推导（openspec/specs/project-scan-root-discovery）───────────────────
  -- 本次真实故障：嵌套布局下 anchor 把范围钉死在 Source/<Proj>/ 子树内，同事在同层
  -- 新增的模块目录永远不进索引（重跑 :UEPrepare 也无法修复，因范围本身不含它）。
  t.it("嵌套布局同层新增的模块目录被发现", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_sibling_module"
    mkdir(root .. "/Source/Client/Source/Runtime")
    write_file(root .. "/Source/Client/Client.uproject", "{}")
    write_file(root .. "/Source/Client/Source/Runtime/Runtime.Build.cs", "//")
    -- 同事新增：anchor 子树之外的真实模块
    mkdir(root .. "/Source/Tools/Source/ToolMod")
    write_file(root .. "/Source/Tools/Source/ToolMod/ToolMod.Build.cs", "//")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(contains(dirs, "Source/Tools/Source/ToolMod"),
      "anchor 子树之外的模块必须被推导发现，实际=" .. vim.inspect(dirs))
    t.assert_true(contains(dirs, "Source/Client/Source"),
      "并集不得丢掉既有 anchor 覆盖")

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("标准布局扫描根不得包含项目根自身", function()
    -- 标准布局的 .uproject 就在 project_root，若把根级 "" 当扫描根，收敛会把一切吞成
    -- 「扇全根」，直接引入 Content/（影视资源）与 .git/ 全量遍历——比原 bug 更严重的回归。
    local root = vim.fn.tempname():gsub("\\", "/") .. "_std_no_root_scan"
    mkdir(root .. "/Source/M1")
    write_file(root .. "/Source/M1/M1.Build.cs", "//")
    write_file(root .. "/Std.uproject", "{}")
    mkdir(root .. "/Content/Movies")
    write_file(root .. "/Content/Movies/a.mp4", "big")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_false(scan_roots.is_ambiguous_nested(root),
      "根级持有 .uproject 是标准布局，不得判为歧义")
    for _, d in ipairs(dirs) do
      t.assert_true(d ~= "" and d ~= "." and d ~= "/",
        "扫描根不得是项目根自身（会退化为全根遍历），实际=" .. vim.inspect(dirs))
    end
    t.assert_true(contains(dirs, "Source"), "标准布局仍应保留根级默认列表")

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("显式白名单优先于推导（不追加推导项）", function()
    -- .ueprepare-scan-paths 的既有语义是「显式声明即最终答案」，用于让用户**收窄**范围
    -- （877k -> 116k 的收益就来自收窄）。若合并推导结果，用户精心收窄的白名单会被自动放大回去。
    local root = vim.fn.tempname():gsub("\\", "/") .. "_whitelist_wins"
    mkdir(root .. "/Source/Client/Source/Runtime")
    write_file(root .. "/Source/Client/Client.uproject", "{}")
    write_file(root .. "/Source/Client/Source/Runtime/Runtime.Build.cs", "//")
    mkdir(root .. "/Source/Other/Source/OtherMod")
    write_file(root .. "/Source/Other/Source/OtherMod/OtherMod.Build.cs", "//")
    write_file(root .. "/.ueprepare-scan-paths", "Source/Client/Source\n# 注释行\n")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_eq(#dirs, 1, "白名单非空时扫描根应完全等于它，实际=" .. vim.inspect(dirs))
    t.assert_true(contains(dirs, "Source/Client/Source"))
    t.assert_false(contains(dirs, "Source/Other/Source/OtherMod"),
      "显式白名单不得被推导结果放大")

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("并集兜住推导盲区（无模块声明的 Shaders 仍被扫）", function()
    -- 纯 shader / Config 树不含任何 *.Build.cs，推导看不到它们；并集是防止「把漏搜 A
    -- 换成漏搜 B」的安全护欄。
    local root = vim.fn.tempname():gsub("\\", "/") .. "_union_blindspot"
    mkdir(root .. "/Source/Client/Source/Runtime")
    write_file(root .. "/Source/Client/Client.uproject", "{}")
    write_file(root .. "/Source/Client/Source/Runtime/Runtime.Build.cs", "//")
    mkdir(root .. "/Source/Client/Shaders")
    write_file(root .. "/Source/Client/Shaders/a.usf", "// shader")

    local dirs = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(contains(dirs, "Source/Client/Shaders"),
      "推导盲区必须由并集兜住，实际=" .. vim.inspect(dirs))

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("排除目录不产生扫描根（Intermediate 下的生成 Build.cs）", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_excluded_decl"
    mkdir(root .. "/Source/Client/Source/Runtime")
    write_file(root .. "/Source/Client/Client.uproject", "{}")
    write_file(root .. "/Source/Client/Source/Runtime/Runtime.Build.cs", "//")
    -- 构建产物里的生成副本：不得成为扫描根
    mkdir(root .. "/Source/Client/Intermediate/Build/Gen")
    write_file(root .. "/Source/Client/Intermediate/Build/Gen/Gen.Build.cs", "//")

    local discovered = scan_roots.discover_module_dirs(root)
    for _, d in ipairs(discovered) do
      t.assert_false(d:find("Intermediate", 1, true) ~= nil,
        "SCAN_EXCLUDES 目录不得产生扫描根，实际=" .. vim.inspect(discovered))
    end

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("声明文件识别不受大小写影响", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_decl_case"
    mkdir(root .. "/Source/Client/Source/Lower")
    write_file(root .. "/Source/Client/Client.uproject", "{}")
    -- 小写 build.cs：真实仓库里两种写法都出现过
    write_file(root .. "/Source/Client/Source/Lower/Lower.build.cs", "//")

    local discovered = scan_roots.discover_module_dirs(root)
    t.assert_true(contains(discovered, "Source/Client/Source/Lower"),
      "小写 .build.cs 也必须被识别，实际=" .. vim.inspect(discovered))

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it("推导深度有界（不进入超深层）", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_depth_bound"
    -- 造一棵超过上限的深树（depth 10）
    local deep = root .. "/a/b/c/d/e/f/g/h/i/j"
    mkdir(deep)
    write_file(deep .. "/Deep.Build.cs", "//")

    local discovered = scan_roots.discover_module_dirs(root)
    t.assert_false(contains(discovered, "a/b/c/d/e/f/g/h/i/j"),
      "超过 SCAN_ROOT_DISCOVERY_MAX_DEPTH 的目录不得被遍历，实际=" .. vim.inspect(discovered))

    pcall(vim.fn.delete, root, "rf")
  end)

  t.it(":UEReloadScanPaths 使扫描根缓存失效（同会话生效）", function()
    local root = vim.fn.tempname():gsub("\\", "/") .. "_reload_scan"
    mkdir(root .. "/Source/Client/Source/Runtime")
    write_file(root .. "/Source/Client/Client.uproject", "{}")
    write_file(root .. "/Source/Client/Source/Runtime/Runtime.Build.cs", "//")

    local before = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(#before > 1,
      "前提：白名单未写时为 anchor 默认列表 + 推导并集（多条），实际=" .. vim.inspect(before))
    -- 同一会话内写入白名单
    write_file(root .. "/.ueprepare-scan-paths", "Source/Client/Config\n")
    local cached = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_true(vim.deep_equal(cached, before),
      "未失效前应仍返回缓存值（证明确实有缓存）")

    require("ue").setup()
    vim.cmd("UEReloadScanPaths")
    local after = ue._project_index_dirs_for_test({ project_root = root })
    t.assert_eq(#after, 1, "失效后应重读白名单，实际=" .. vim.inspect(after))
    t.assert_true(contains(after, "Source/Client/Config"))

    pcall(vim.fn.delete, root, "rf")
  end)
end)
