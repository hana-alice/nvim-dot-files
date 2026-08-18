local t = require("tests.harness")
t.bootstrap()

local ue = require("ue")

local function with_target_env(platform, configuration, target, fn)
  local old_platform = vim.env.UE_TARGET_PLATFORM
  local old_configuration = vim.env.UE_TARGET_CONFIGURATION
  local old_target = vim.env.UE_BUILD_TARGET
  vim.env.UE_TARGET_PLATFORM = platform
  vim.env.UE_TARGET_CONFIGURATION = configuration
  vim.env.UE_BUILD_TARGET = target
  local ok, result_a, result_b, result_c = pcall(fn)
  vim.env.UE_TARGET_PLATFORM = old_platform
  vim.env.UE_TARGET_CONFIGURATION = old_configuration
  vim.env.UE_BUILD_TARGET = old_target
  if not ok then
    error(result_a)
  end
  return result_a, result_b, result_c
end

t.describe("ue target integration", function()
  t.it("uses the host driver's explicit default target when no target is selected", function()
    local old = vim.env.UE_TARGET_PLATFORM
    vim.env.UE_TARGET_PLATFORM = nil
    local detected = ue._target_platform_for_test(nil)
    vim.env.UE_TARGET_PLATFORM = old
    t.assert_eq(detected, require("utils.platform").driver().default_target())
  end)

  t.it("does not silently turn an unavailable host driver into Linux", function()
    local platform = require("utils.platform")
    local old_driver = platform.driver
    local old_target = vim.env.UE_TARGET_PLATFORM
    platform.driver = function() return require("utils.platform.stub") end
    vim.env.UE_TARGET_PLATFORM = nil
    local detected = ue._target_platform_for_test(nil)
    platform.driver = old_driver
    vim.env.UE_TARGET_PLATFORM = old_target
    t.assert_eq(detected, "")
  end)

  t.it("dispatches install by active target and keeps IOS on the target-driver path", function()
    local calls = {}
    local function dispatch(platform)
      return ue._install_active_target_for_test({
        resolve_context = function()
          return { engine_root = "/UE" }
        end,
        target_platform = function()
          return platform
        end,
        install_android = function()
          calls[#calls + 1] = "android"
          return "android-result"
        end,
        install_target = function(selected)
          calls[#calls + 1] = "target:" .. selected
          return "ios-result"
        end,
      })
    end

    t.assert_eq(dispatch("Android"), "android-result")
    t.assert_eq(dispatch("IOS"), "ios-result")
    t.assert_eq(table.concat(calls, ","), "android,target:IOS")
  end)

  t.it("rejects install for desktop targets instead of guessing a device workflow", function()
    local notified
    local result, err = ue._install_active_target_for_test({
      resolve_context = function()
        return { engine_root = "/UE" }
      end,
      target_platform = function()
        return "Mac"
      end,
      notify_error = function(message)
        notified = message
      end,
    })

    t.assert_eq(result, nil)
    t.assert_contains(err, "active target Mac")
    t.assert_eq(notified, err)
  end)

  t.it("offers only build targets supported by the current host", function()
    local mac = ue._available_platform_choices_for_test(require("utils.platform.macos"))
    local windows = ue._available_platform_choices_for_test(require("utils.platform.windows"))
    local linux = ue._available_platform_choices_for_test(require("utils.platform.linux"))
    t.assert_eq(table.concat(mac, ","), "Mac,IOS")
    t.assert_eq(table.concat(windows, ","), "Win64,Android")
    t.assert_eq(table.concat(linux, ","), "Linux")
  end)

  t.it("does not let a foreign .sln hide native host targets", function()
    local root = vim.fn.tempname() .. "-platform-choices"
    vim.fn.mkdir(root, "p")
    local solution = root .. "/Fixture.sln"
    vim.fn.writefile({
      "Global",
      "GlobalSection(SolutionConfigurationPlatforms) = preSolution",
      "Development|Win64 = Development|Win64",
      "Development|Android = Development|Android",
      "EndGlobalSection",
      "EndGlobal",
    }, solution)
    local choices = ue._available_platform_choices_for_test(
      require("utils.platform.macos"), root, root .. "/Fixture.uproject"
    )
    vim.fn.delete(root, "rf")
    t.assert_eq(table.concat(choices, ","), "Mac,IOS")
  end)

  t.it("IOS build combines the IOS target driver with the macOS host driver", function()
    local command, err, plan = with_target_env("IOS", "Development", "SampleGame", function()
      return ue._target_plan_for_test(
        "build",
        {
          engine_root = "/UE Root",
          project_root = "/Project Root",
          uproject = "/Project Root/Sample.uproject",
          state = {},
        },
        "IOS",
        {
          host_driver = require("utils.platform.macos"),
        }
      )
    end)

    t.assert_eq(err, nil)
    t.assert_eq(command[1], "/bin/zsh")
    t.assert_contains(command, vim.fn.stdpath("config") .. "/scripts/ue_ios_cpp_iteration.zsh")
    t.assert_contains(command, "/UE Root/Engine/Build/BatchFiles/Mac/Build.sh")
    t.assert_contains(command, "IOS")
    t.assert_contains(command, "-Project=/Project Root/Sample.uproject")
    t.assert_contains(command, "-WaitMutex")
    t.assert_contains(command, "-FromMsBuild")
    t.assert_contains(command, "-disablev8pointercompression")
    local function argv_position(value)
      for index, arg in ipairs(command) do
        if arg == value then
          return index
        end
      end
    end
    t.assert_true(argv_position("-Project=/Project Root/Sample.uproject") < argv_position("-WaitMutex"))
    t.assert_true(argv_position("-WaitMutex") < argv_position("-FromMsBuild"))
    t.assert_true(argv_position("-FromMsBuild") < argv_position("-disablev8pointercompression"))
    t.assert_eq(plan.metadata.platform, "IOS")
    t.assert_eq(plan.metadata.optimization, "cpp-iteration")
  end)

  t.it("captures the project-scoped IOS signing identity in the build plan", function()
    local identity = {
      fingerprint = "0123456789ABCDEF0123456789ABCDEF01234567",
      name = "Apple Development: Example User (TEAM123456)",
    }
    local command = with_target_env("IOS", "Development", "SampleGame", function()
      return ue._target_plan_for_test(
        "build",
        {
          engine_root = "/UE",
          project_root = "/Project",
          uproject = "/Project/Sample.uproject",
          state = { ios_signing_identity = identity },
        },
        "IOS",
        { host_driver = require("utils.platform.macos") }
      )
    end)

    t.assert_contains(
      command,
      "-ini:Engine:[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:SigningCertificate=" .. identity.name
    )
  end)

  t.it("Mac target uses its own driver and never receives IOS argv", function()
    local command = with_target_env("Mac", "Development", "SampleEditor", function()
      return ue._target_plan_for_test(
        "build",
        {
          engine_root = "/UE",
          project_root = "/Project",
          uproject = "/Project/Sample.uproject",
          state = {},
        },
        "Mac",
        {
          host_driver = require("utils.platform.macos"),
        }
      )
    end)

    t.assert_contains(command, "Mac")
    t.assert_false(vim.tbl_contains(command, "IOS"))
    t.assert_false(vim.tbl_contains(command, "-WaitMutex"))
    t.assert_false(vim.tbl_contains(command, "-FromMsBuild"))
    t.assert_false(vim.tbl_contains(command, "-disablev8pointercompression"))
  end)

  t.it("rejects incompatible host-target pairs before command planning", function()
    local command, err, plan = with_target_env("Android", "Development", "SampleGame", function()
      return ue._target_plan_for_test(
        "build",
        {
          engine_root = "/UE",
          project_root = "/Project",
          uproject = "/Project/Sample.uproject",
          state = {},
        },
        "Android",
        { host_driver = require("utils.platform.macos") }
      )
    end)

    t.assert_eq(command, nil)
    t.assert_contains(err, "unsupported host-target operation")
    t.assert_eq(plan, nil)
  end)

  t.it("accepts only the pinned clangd 22.1 toolchain", function()
    local compatible = ue._clangd_version_compatible_for_test("clangd version 22.1.5")
    local apple = ue._clangd_version_compatible_for_test("Apple clangd version 17.0.0")
    local future_minor = ue._clangd_version_compatible_for_test("clangd version 22.2.0")
    t.assert_true(compatible)
    t.assert_false(apple)
    t.assert_false(future_minor)
  end)

  t.it("routes IOS semantic generation before prepare without changing UEPrepare semantics", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local compile_start = assert(source:find("function CORE_RT%.compile_for_nvim", 1))
    local compile_end = assert(source:find("%-%- Find the newest APK", compile_start))
    local compile_body = source:sub(compile_start, compile_end)
    local semantic_pos = compile_body:find("generate_semantic_cdb_after_build", 1, true)
    local prepare_pos = compile_body:find("CORE_RT.prepare_async", 1, true)

    t.assert_true(semantic_pos ~= nil, "UECompileForNvim must generate Apple semantic evidence after build")
    t.assert_true(prepare_pos ~= nil and semantic_pos < prepare_pos)
    t.assert_contains(compile_body, "force_cdb_restart")
    t.assert_contains(compile_body, "semantic_info.no_op ~= true")

    local prepare_start = assert(source:find("local function prepare_async", 1, true))
    local prepare_end = assert(source:find("export_compile_commands = prepare_async", prepare_start, true))
    local prepare_body = source:sub(prepare_start, prepare_end)
    t.assert_false(
      prepare_body:find("GenerateClangDatabase", 1, true) ~= nil,
      "UEPrepare must remain read/transform-only"
    )
  end)

  t.it("consults PrepareIOSQADebug metadata before the no-argument signing picker", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local start = assert(source:find("function CORE_RT.select_ios_signing_certificate", 1, true))
    local finish = assert(source:find("function CORE_RT.select_target_device", start, true))
    local body = source:sub(start, finish)
    local prepared_pos = body:find("driver.prepared_signing_identity", 1, true)
    local probe_pos = body:find("driver.signing_identity_list_plan", 1, true)

    t.assert_true(prepared_pos ~= nil and probe_pos ~= nil and prepared_pos < probe_pos)
    t.assert_contains(body, 'query = prepared.identity.fingerprint')
    t.assert_contains(body, 'prepared.reason .. "; rerun PrepareIOSQADebug.sh')
  end)

  t.it("keeps IOS command strings out of other target drivers", function()
    local config = vim.fn.stdpath("config")
    local mac = table.concat(vim.fn.readfile(config .. "/lua/ue/targets/mac.lua"), "\n")
    local android = table.concat(vim.fn.readfile(config .. "/lua/ue/targets/android.lua"), "\n")
    local core = table.concat(vim.fn.readfile(config .. "/lua/ue.lua"), "\n")
    t.assert_false(mac:find("devicectl", 1, true) ~= nil)
    t.assert_false(android:find("devicectl", 1, true) ~= nil)
    t.assert_false(core:find("BuildCookRun", 1, true) ~= nil)
    t.assert_false(core:find("devicectl", 1, true) ~= nil)
    t.assert_false(core:find("ue_android_so_build.ps1", 1, true) ~= nil)
    t.assert_false(core:find("ue_android_so_deploy.ps1", 1, true) ~= nil)
  end)
end)
