local t = require("tests.harness")
t.bootstrap()

local targets = require("ue.targets")
local contract = require("ue.targets.contract")

local function host_stub()
  return {
    id = "macos",
    shell_entry = function(kind)
      if kind == "posix" then return "/bin/zsh" end
    end,
    ue_build_entry = function()
      return {
        executable = "/UE/Engine/Build/BatchFiles/Mac/Build.sh",
        args = { "--host-build" },
        cwd = "/UE",
        metadata = { host = "build" },
      }
    end,
    ue_uat_entry = function()
      return {
        executable = "/UE/Engine/Build/BatchFiles/RunUAT.sh",
        args = { "--host-uat" },
        cwd = "/UE",
        metadata = { host = "uat" },
      }
    end,
    xcrun_entry = function()
      return {
        executable = "/usr/bin/xcrun",
        args = {},
        cwd = "/tmp",
        metadata = { host = "xcrun" },
      }
    end,
    security_entry = function()
      return {
        executable = "/usr/bin/security",
        args = {},
        cwd = "/tmp",
      }
    end,
    plutil_entry = function()
      return {
        executable = "/usr/bin/plutil",
        args = {},
        cwd = "/tmp",
      }
    end,
  }
end

local function windows_host_stub()
  return {
    id = "windows",
    host_path = function(path)
      return tostring(path):gsub("/", "\\")
    end,
    powershell_entry = function()
      return {
        executable = "powershell.exe",
        args = {},
        cwd = "C:/UE",
      }
    end,
  }
end

t.describe("ue.targets registry and contract", function()
  t.it("registers every target driver with the required contract", function()
    t.assert_eq(table.concat(targets.known_ids(), ","), "Android,IOS,Linux,Mac,Win64")
    for _, id in ipairs(targets.known_ids()) do
      local driver = targets.must_get(id)
      contract.validate(driver)
      t.assert_eq(driver.id, id)
    end
  end)

  t.it("enforces the host-target-operation compatibility matrix", function()
    local macos = host_stub()
    local windows = {
      id = "windows",
      ue_build_entry = function()
        return { executable = "cmd.exe", args = { "/d", "/c", "call Build.bat" } }
      end,
    }

    local ios = targets.resolve("IOS", "build", macos)
    local ios_semantic = targets.resolve("IOS", "semantic_cdb", macos)
    local android = targets.resolve("Android", "build", windows)
    local _, mac_android = targets.resolve("Android", "build", macos)
    local _, win_ios = targets.resolve("IOS", "build", windows)
    local _, mac_win64 = targets.resolve("Win64", "build", macos)
    local _, ios_dap = targets.resolve("IOS", "dap_attach", macos)

    t.assert_eq(ios.id, "IOS")
    t.assert_eq(ios_semantic.id, "IOS")
    t.assert_eq(android.id, "Android")
    t.assert_eq(mac_android.status, "unavailable")
    t.assert_eq(mac_android.host_id, "macos")
    t.assert_eq(win_ios.status, "unavailable")
    t.assert_eq(mac_win64.status, "unavailable")
    t.assert_eq(ios_dap.status, "unavailable")
  end)

  t.it("keeps runtime routing policy in target drivers", function()
    t.assert_eq(targets.must_get("Android").runtime.launch.strategy, "android-device")
    t.assert_eq(targets.must_get("IOS").runtime.launch.strategy, "managed-device")
    t.assert_eq(targets.must_get("Mac").runtime.launch.strategy, "desktop")
    t.assert_true(targets.must_get("Mac").runtime.launch.editor_app_bundles)
    t.assert_eq(targets.must_get("Win64").runtime.launch.executable_suffix, ".exe")
    t.assert_eq(targets.must_get("Win64").runtime.debug_log.strategy, "desktop-debug")
    t.assert_eq(targets.must_get("Linux").runtime.main_log.strategy, "desktop-file")
  end)

  t.it("does not expose iOS lifecycle methods from Mac or Android via fallback", function()
    local mac = targets.must_get("Mac")
    local android = targets.must_get("Android")
    local unavailable_mac = mac.install_plan({}, host_stub())
    local unavailable_android = android.launch_plan({}, host_stub())
    t.assert_eq(unavailable_mac.status, "unavailable")
    t.assert_eq(unavailable_mac.driver_id, "Mac")
    t.assert_eq(unavailable_android.status, "unavailable")
    t.assert_eq(unavailable_android.driver_id, "Android")
  end)
end)

t.describe("ue.targets build planners", function()
  t.it("Mac build uses host build entry and its own target argv", function()
    local plan = targets.build_plan("Mac", {
      target = "SampleEditor",
      configuration = "Development",
      uproject = "/Project/Sample.uproject",
    }, host_stub())

    t.assert_eq(plan.executable, "/UE/Engine/Build/BatchFiles/Mac/Build.sh")
    t.assert_eq(plan.cwd, "/UE")
    t.assert_contains(plan.args, "--host-build")
    t.assert_contains(plan.args, "SampleEditor")
    t.assert_contains(plan.args, "Mac")
    t.assert_contains(plan.args, "Development")
    t.assert_contains(plan.args, "-Project=/Project/Sample.uproject")
  end)

  t.it("IOS build remains separate from Mac while reusing the host build entry", function()
    local plan = targets.build_plan("IOS", {
      target = "SampleGame",
      configuration = "Shipping",
      uproject = "/Project/Sample.uproject",
    }, host_stub())

    t.assert_eq(plan.executable, "/UE/Engine/Build/BatchFiles/Mac/Build.sh")
    t.assert_contains(plan.args, "IOS")
    t.assert_contains(
      plan.args,
      "-ini:Engine:[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:bGeneratedSYMFile=False,[/Script/IOSRuntimeSettings.IOSRuntimeSettings]:bGeneratedSYMBundle=False"
    )
    t.assert_false(
      vim.deep_equal(
        plan.args,
        targets.build_plan("Mac", {
          target = "SampleGame",
          configuration = "Shipping",
          uproject = "/Project/Sample.uproject",
        }, host_stub()).args
      ),
      "iOS and Mac target argv must remain independent"
    )
  end)

  t.it("IOS semantic CDB plan builds only the tuple action graph", function()
    local plan = targets.plan("IOS", "semantic_cdb", {
      engine_root = "/UE",
      target = "SampleGame",
      configuration = "Development",
      uproject = "/Project/Sample.uproject",
      semantic_cdb_output_dir = "/UE/.cache/nvim-ue/cdb/sources/IOS-SampleGame-Development",
      semantic_cdb_output_filename = "compile_commands.pending.json",
    }, host_stub())

    t.assert_eq(plan.executable, "/UE/Engine/Build/BatchFiles/Mac/Build.sh")
    t.assert_contains(plan.args, "SampleGame")
    t.assert_contains(plan.args, "IOS")
    t.assert_contains(plan.args, "Development")
    t.assert_contains(plan.args, "-Mode=GenerateClangDatabase")
    t.assert_contains(plan.args, "-NoExecCodeGenActions")
    t.assert_contains(plan.args, "-UsePCH")
    t.assert_contains(plan.args, "-OutputFilename=compile_commands.pending.json")
    t.assert_false(vim.tbl_contains(plan.args, "BuildCookRun"))
    t.assert_false(vim.tbl_contains(plan.args, "-cook"))
    t.assert_false(vim.tbl_contains(plan.args, "-package"))
  end)

  t.it("IOS semantic CDB validator requires IOS compiler evidence", function()
    local ios = targets.must_get("IOS")
    local ios_result = ios.validate_semantic_cdb({
      {
        file = "/UE/Engine/Source/Runtime/Apple/MetalRHI/Private/MetalBuffer.cpp",
        output = "/Project/Intermediate/Build/IOS/SampleGame/Development/MetalRHI/MetalBuffer.cpp.o",
        command = "clang++ -isysroot /Xcode/iPhoneOS.platform/SDK -miphoneos-version-min=14.0",
      },
    }, { target = "SampleGame", configuration = "Development" })
    local mac_result = ios.validate_semantic_cdb({
      {
        file = "/UE/Engine/Source/Runtime/Core/Private/Core.cpp",
        command = "clang++ -isysroot /Xcode/MacOSX.platform/SDK",
      },
    }, { target = "SampleGame", configuration = "Development" })

    t.assert_true(ios_result.ok)
    t.assert_eq(ios_result.matched, 1)
    t.assert_false(mac_result.ok)
    t.assert_contains(mac_result.reason, "IOS")
  end)

  t.it("IOS semantic CDB validator rejects a different target/config tuple", function()
    local result = targets.must_get("IOS").validate_semantic_cdb({
      {
        file = "/UE/Engine/Source/Runtime/Apple/MetalRHI/Private/MetalBuffer.cpp",
        output = "/Project/Intermediate/Build/IOS/OtherGame/Shipping/MetalRHI/MetalBuffer.cpp.o",
        command = "clang++ -isysroot /Xcode/iPhoneOS.platform/SDK",
      },
    }, { target = "SampleGame", configuration = "Development" })

    t.assert_false(result.ok)
    t.assert_contains(result.reason, "SampleGame/Development")
  end)

  t.it("wraps the native IOS build with the Nvim-owned safe AOT cache when config_root is available", function()
    local plan = targets.build_plan("IOS", {
      engine_root = "/UE",
      project_dir = "/Project Root",
      target = "SampleGame",
      configuration = "Development",
      uproject = "/Project Root/Sample.uproject",
      config_root = "/Nvim Config",
    }, host_stub())

    t.assert_eq(plan.executable, "/bin/zsh")
    t.assert_eq(plan.args[1], "/Nvim Config/scripts/ue_ios_cpp_iteration.zsh")
    t.assert_contains(plan.args, "build")
    t.assert_contains(plan.args, "/UE/Engine/Build/BatchFiles/Mac/Build.sh")
    t.assert_contains(plan.args, "--project-dir")
    t.assert_contains(plan.args, "/Project Root")
    t.assert_contains(plan.args, "--cache-dir")
    t.assert_contains(plan.args, "/UE/.cache/nvim-ue/ios-aot")
  end)

  t.it("Win64 build retains WaitMutex and FromMsBuild flags", function()
    local plan = targets.build_plan("Win64", {
      target = "SampleEditor",
      configuration = "DebugGame",
      uproject = "C:/Project/Sample.uproject",
    }, {
      id = "windows",
      ue_build_entry = function()
        return {
          executable = "cmd.exe",
          args = { "/d", "/c", "call Build.bat" },
          cwd = "C:/UE",
        }
      end,
    })

    t.assert_contains(plan.args, "-WaitMutex")
    t.assert_contains(plan.args, "-FromMsBuild")
    t.assert_contains(plan.args, "Win64")
  end)

  t.it("Android so-only build stays separate and does not use the iOS/Mac planners", function()
    local plan = targets.must_get("Android").so_build_plan({
      target = "SampleGame",
      configuration = "Test",
      engine_root = "C:/UE",
      uproject = "C:/Project/Sample.uproject",
      android_so_script = "C:/cfg/scripts/ue_android_so_build.ps1",
    }, windows_host_stub())

    t.assert_eq(plan.executable, "powershell.exe")
    t.assert_contains(table.concat(plan.args, " "), "ue_android_so_build.ps1")
    t.assert_contains(plan.args, "-Platform")
    t.assert_contains(plan.args, "Android")
    t.assert_false(vim.tbl_contains(plan.args, "IOS"), "android planner must not import ios arguments")
  end)

  t.it("Android SO-only build has no macOS PowerShell fallback", function()
    local plan = targets.must_get("Android").so_build_plan({
      target = "SampleGame",
      configuration = "Test",
      engine_root = "/UE",
      uproject = "/Project/Sample.uproject",
      android_so_script = "/cfg/scripts/ue_android_so_build.ps1",
    }, host_stub())

    t.assert_eq(plan.status, "unavailable")
    t.assert_eq(plan.host_id, "macos")
    t.assert_contains(plan.reason, "host adapter")
  end)

  t.it("Android install argv is owned by the Windows target adapter", function()
    local plan = targets.plan("Android", "install", {
      adb = "C:/Android/adb.exe",
      apk = "C:/Build/Game.apk",
      cwd = "C:/Build",
      device_id = "SERIAL-002",
    }, windows_host_stub())

    t.assert_eq(plan.executable, "C:\\Android\\adb.exe")
    t.assert_eq(table.concat(plan.args, " "), "-s SERIAL-002 install -r C:\\Build\\Game.apk")
    t.assert_eq(plan.metadata.workflow, "android-install")
  end)

  t.it("ordinary Android build has no macOS Build.sh fallback", function()
    local plan = targets.build_plan("Android", {
      target = "SampleGame",
      configuration = "Development",
      uproject = "/Project/Sample.uproject",
    }, host_stub())

    t.assert_eq(plan.status, "unavailable")
    t.assert_eq(plan.host_id, "macos")
    t.assert_eq(plan.operation, "build")
  end)

  t.it("keeps shell names out of generic target and launch/log modules", function()
    local config = vim.fn.stdpath("config")
    for _, relative in ipairs({
      "/lua/ue/targets/android.lua",
      "/lua/utils/ue_launch.lua",
      "/lua/utils/ue_logs.lua",
    }) do
      local source = table.concat(vim.fn.readfile(config .. relative), "\n"):lower()
      t.assert_false(source:find("powershell.exe", 1, true) ~= nil, relative .. " leaked powershell.exe")
      t.assert_false(source:find('"pwsh"', 1, true) ~= nil, relative .. " leaked pwsh")
      if relative:find("/utils/ue_", 1, true) then
        t.assert_false(source:find("platform ==", 1, true) ~= nil, relative .. " hard-coded target dispatch")
      end
    end
  end)

  t.it("returns structured unavailable when the host capability is missing", function()
    local result = targets.build_plan("Linux", {
      target = "SampleServer",
      configuration = "Development",
      uproject = "/Project/Sample.uproject",
    }, { id = "linux" })

    t.assert_eq(result.status, "unavailable")
    t.assert_eq(result.driver_id, "Linux")
    t.assert_eq(result.missing_capability, "ue_build_entry")
  end)

  t.it("keeps Android receipt policy in the target driver and PowerShell in the Windows adapter", function()
    local root = vim.fn.tempname()
    local binaries = root .. "/Binaries/Android"
    local source_so = binaries .. "/SampleGame-Android-Test-arm64.so"
    vim.fn.mkdir(binaries, "p")
    vim.fn.writefile({ "so" }, source_so)

    local android = targets.must_get("Android")
    local plan = android.so_deploy_plan({
      project_dir = root,
      config_root = vim.fn.stdpath("config"),
      target = "SampleGame",
      configuration = "Test",
      device_id = "DEVICE-1",
      package_name = "com.example.samplegame",
      cwd = "C:/UE",
    }, require("utils.platform.windows"))
    local unsupported = android.so_deploy_plan({
      project_dir = root,
      config_root = vim.fn.stdpath("config"),
      target = "SampleGame",
      configuration = "Test",
      device_id = "DEVICE-1",
      package_name = "com.example.samplegame",
    }, require("utils.platform.macos"))
    vim.fn.delete(root, "rf")

    t.assert_eq(plan.executable, "powershell.exe")
    t.assert_contains(table.concat(plan.args, " "), "ue_android_so_deploy.ps1")
    t.assert_contains(table.concat(plan.args, " "), "SampleGame-Android-Test-arm64.so")
    t.assert_eq(unsupported.status, "unavailable")
    t.assert_eq(unsupported.host_id, "macos")
    t.assert_contains(unsupported.reason, "host adapter")
  end)

  t.it("keeps PowerShell symbols out of macOS and generic Android drivers", function()
    local config = vim.fn.stdpath("config")
    local mac_source = table.concat(vim.fn.readfile(config .. "/lua/utils/platform/macos.lua"), "\n")
    local android_source = table.concat(vim.fn.readfile(config .. "/lua/ue/targets/android.lua"), "\n")
    local windows_adapter = table.concat(vim.fn.readfile(config .. "/lua/ue/targets/android_windows.lua"), "\n")

    t.assert_false(mac_source:lower():find("powershell", 1, true) ~= nil)
    t.assert_false(android_source:lower():find("powershell", 1, true) ~= nil)
    t.assert_contains(windows_adapter:lower(), "powershell")
  end)
end)

t.describe("ue.targets classify_rsp", function()
  t.it("matches only the current target tuple", function()
    local candidate = {
      path = "/Project/Intermediate/Build/IOS/arm64/SampleGame/Development/Core/Module.Core.cpp.o.rsp",
    }
    local match = targets.classify_rsp("IOS", candidate, {
      target = "SampleGame",
      configuration = "Development",
      target_platform = "IOS",
    })
    local foreign = targets.classify_rsp("IOS", {
      path = "/Project/Intermediate/Build/Mac/arm64/SampleGame/Development/Core/Module.Core.cpp.o.rsp",
    }, {
      target = "SampleGame",
      configuration = "Development",
      target_platform = "IOS",
    })

    t.assert_true(match.match)
    t.assert_eq(match.reason, "matched")
    t.assert_false(foreign.match)
    t.assert_eq(foreign.reason, "foreign-platform")
  end)

  t.it("accepts explicit tuple metadata when the path classifier cannot infer it", function()
    local result = targets.classify_rsp("Mac", {
      path = "/tmp/Module.Render.response",
      platform = "Mac",
      target = "SampleEditor",
      configuration = "Development",
    }, {
      target = "SampleEditor",
      configuration = "Development",
    })

    t.assert_true(result.match)
  end)
end)

t.describe("ue.targets.ios package/device/install/launch planners", function()
  local ios = targets.must_get("IOS")

  t.it("packages existing cooked data without build, cook, archive, deploy, or run", function()
    local plan = ios.package_plan({
      target = "SampleGame",
      configuration = "Development",
      uproject = "/Project/Sample.uproject",
    }, host_stub())

    t.assert_eq(plan.executable, "/UE/Engine/Build/BatchFiles/RunUAT.sh")
    t.assert_contains(plan.args, "BuildCookRun")
    t.assert_contains(plan.args, "-targetplatform=IOS")
    t.assert_contains(plan.args, "-skipbuild")
    t.assert_contains(plan.args, "-skipcook")
    t.assert_contains(plan.args, "-nocleanstage")
    t.assert_contains(plan.args, "-stage")
    t.assert_contains(plan.args, "-package")
    t.assert_contains(plan.args, "-nodebuginfo")
    t.assert_false(vim.tbl_contains(plan.args, "-build"))
    t.assert_false(vim.tbl_contains(plan.args, "-cook"))
    t.assert_false(vim.tbl_contains(plan.args, "-archive"))
    t.assert_false(vim.tbl_contains(plan.args, "-deploy"))
    t.assert_false(vim.tbl_contains(plan.args, "-run"))
    t.assert_eq(table.concat(plan.metadata.stages, ","), "stage,package")
    t.assert_true(plan.metadata.reuses_cooked_data)
  end)

  t.it("builds an on-demand dSYM plan that verifies Mach-O UUIDs in the same terminal", function()
    local plan = ios.symbols_plan({
      engine_root = "/UE",
      project_dir = "/Project Root",
      target = "SampleGame",
      configuration = "Development",
      uproject = "/Project Root/Sample.uproject",
      config_root = "/Nvim Config",
    }, host_stub())

    t.assert_eq(plan.executable, "/bin/zsh")
    t.assert_eq(plan.args[1], "/Nvim Config/scripts/ue_ios_cpp_iteration.zsh")
    t.assert_contains(plan.args, "symbols")
    t.assert_contains(plan.args, "/usr/bin/xcrun")
    t.assert_contains(plan.args, "/Project Root/Binaries/IOS/SampleGame")
    t.assert_eq(plan.metadata.output, "/Project Root/Binaries/IOS/SampleGame.dSYM")
  end)

  t.it("builds devicectl list/install/launch plans from xcrun entries", function()
    local list_plan = ios.device_list_plan({ json_output = "/tmp/devices.json" }, host_stub())
    local install_plan = ios.install_plan({
      device_id = "DEVICE-1",
      json_output = "/tmp/install.json",
      target = "SampleGame",
      configuration = "Development",
      artifacts = {
        {
          path = "/Stage/IOS/Development/Payload/SampleGame.app",
          platform = "IOS",
          target = "SampleGame",
          configuration = "Development",
        },
      },
    }, host_stub())
    local launch_plan = ios.launch_plan({
      device_id = "DEVICE-1",
      bundle_id = "com.example.samplegame",
      json_output = "/tmp/launch.json",
    }, host_stub())

    t.assert_eq(list_plan.executable, "/usr/bin/xcrun")
    t.assert_contains(list_plan.args, "devicectl")
    t.assert_contains(list_plan.args, "--json-output")
    t.assert_contains(install_plan.args, "install")
    t.assert_contains(install_plan.args, "/Stage/IOS/Development/Payload/SampleGame.app")
    t.assert_contains(install_plan.args, "/tmp/install.json")
    t.assert_contains(launch_plan.args, "process")
    t.assert_contains(launch_plan.args, "com.example.samplegame")
    t.assert_contains(launch_plan.args, "/tmp/launch.json")
  end)

  t.it("selects the staged app by tuple provenance and rejects ipa-only fallbacks", function()
    local selected = ios.select_staged_artifact({
      {
        path = "/Stage/IOS/Development/Payload/SampleGame.app",
        platform = "IOS",
        target = "SampleGame",
        configuration = "Development",
        metadata = { source = "current-task" },
      },
      {
        path = "/Stage/IOS/Shipping/Payload/SampleGame.app",
        platform = "IOS",
        target = "SampleGame",
        configuration = "Shipping",
      },
    }, {
      target = "SampleGame",
      configuration = "Development",
      uproject = "/Project/Sample.uproject",
    })
    local ipa_only = ios.select_staged_artifact({
      {
        path = "/Archives/SampleGame.ipa",
        platform = "IOS",
        target = "SampleGame",
        configuration = "Development",
      },
    }, {
      target = "SampleGame",
      configuration = "Development",
    })

    t.assert_true(selected.ok)
    t.assert_eq(selected.app_path, "/Stage/IOS/Development/Payload/SampleGame.app")
    t.assert_eq(selected.provenance.tuple.platform, "IOS")
    t.assert_eq(ipa_only.status, "unavailable")
  end)

  t.it("validates bundle identifiers and can build an Info.plist probe plan", function()
    local ok_result = ios.validate_bundle_id("com.example.samplegame")
    local bad_result = ios.validate_bundle_id("com.example..bad")
    local underscore_result = ios.validate_bundle_id("com.example.bad_name")
    local plist_plan = ios.bundle_id_plan("/Stage/IOS/Payload/SampleGame.app", host_stub(), {})

    t.assert_true(ok_result.ok)
    t.assert_eq(ok_result.bundle_id, "com.example.samplegame")
    t.assert_eq(bad_result.status, "unavailable")
    t.assert_eq(underscore_result.status, "unavailable")
    t.assert_eq(plist_plan.executable, "/usr/bin/plutil")
    t.assert_contains(plist_plan.args, "CFBundleIdentifier")
    t.assert_contains(plist_plan.args, "/Stage/IOS/Payload/SampleGame.app/Info.plist")
  end)

  t.it("derives package artifacts from the engine's iOS AutomationTool layout", function()
    local result = ios.artifact_candidates({
      project_dir = "/Project",
      archive_dir = "/Archive",
      target = "SampleGame",
      configuration = "Development",
    })

    t.assert_true(result.ok)
    t.assert_eq(result.candidates[1].path, "/Project/Binaries/IOS/Payload/SampleGame.app")
    t.assert_eq(result.candidates[1].tuple.platform, "IOS")
    for _, candidate in ipairs(result.candidates) do
      t.assert_false(
        candidate.path:find("Saved/StagedBuilds/IOS/Payload", 1, true) ~= nil,
        "raw stage directory is not the signed packaged app payload"
      )
    end
  end)

  t.it("parses devicectl json results and rejects mismatched identities", function()
    local devices = ios.parse_device_list(vim.json.encode({
      result = {
        devices = {
          {
            identifier = "DEVICE-1",
            name = "Alice iPhone",
            platform = "iOS 18.0",
            available = true,
            physical = true,
          },
          {
            identifier = "SIM-1",
            name = "Simulator",
            platform = "iOS 18.0",
            available = true,
            physical = false,
          },
        },
      },
    }))
    local install_ok = ios.parse_install_result(
      vim.json.encode({
        result = {
          deviceIdentifier = "DEVICE-1",
          installedApplications = {
            { bundleIdentifier = "com.example.samplegame" },
          },
        },
      }),
      {
        device_id = "DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )
    local launch_bad = ios.parse_launch_result(
      vim.json.encode({
        result = {
          deviceIdentifier = "DEVICE-2",
          process = {
            bundleIdentifier = "com.example.samplegame",
            processIdentifier = 991,
          },
        },
      }),
      {
        device_id = "DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )

    t.assert_true(devices.ok)
    t.assert_eq(#devices.devices, 1)
    t.assert_true(install_ok.ok)
    t.assert_eq(launch_bad.status, "unavailable")
  end)

  t.it("parses the current CoreDevice schema and excludes disconnected hardware", function()
    local devices = ios.parse_device_list(vim.json.encode({
      result = {
        devices = {
          {
            identifier = "CONNECTED-1",
            connectionProperties = {
              pairingState = "paired",
              tunnelState = "connected",
            },
            deviceProperties = {
              name = "Connected iPhone",
              osVersionNumber = "18.5",
            },
            hardwareProperties = {
              platform = "iOS",
              reality = "physical",
              deviceType = "iPhone",
            },
          },
          {
            identifier = "OFFLINE-1",
            connectionProperties = {
              pairingState = "paired",
              tunnelState = "unavailable",
            },
            deviceProperties = { name = "Offline iPhone" },
            hardwareProperties = {
              platform = "iOS",
              reality = "physical",
              deviceType = "iPhone",
            },
          },
        },
      },
    }))

    t.assert_true(devices.ok)
    t.assert_eq(#devices.devices, 1)
    t.assert_eq(devices.devices[1].id, "CONNECTED-1")
    t.assert_eq(devices.devices[1].name, "Connected iPhone")
    t.assert_eq(devices.devices[1].os_version, "18.5")
  end)

  t.it("owns iOS SDK and signing preflight plans and validation", function()
    local descriptor = ios.preflight_plans("package", {}, host_stub())
    t.assert_true(descriptor.ok)
    t.assert_eq(#descriptor.plans, 2)
    t.assert_contains(descriptor.plans[1].args, "iphoneos")
    t.assert_contains(descriptor.plans[2].args, "codesigning")

    local valid = ios.validate_preflight("package", {
      {
        code = 0,
        stdout = "/Applications/Xcode.app/SDKs/iPhoneOS.sdk\n",
        plan = descriptor.plans[1],
      },
      {
        code = 0,
        stdout = "1 valid identities found\n",
        plan = descriptor.plans[2],
      },
    })
    local unsigned = ios.validate_preflight("package", {
      {
        code = 0,
        stdout = "/Applications/Xcode.app/SDKs/iPhoneOS.sdk\n",
        plan = descriptor.plans[1],
      },
      {
        code = 0,
        stdout = "0 valid identities found\n",
        plan = descriptor.plans[2],
      },
    })
    t.assert_true(valid.ok)
    t.assert_eq(unsigned.status, "unavailable")
  end)

  t.it("exposes stage-specific preflight descriptors owned by the iOS driver", function()
    local preflights = ios.preflight_descriptors()
    t.assert_eq(#preflights, 5)
    t.assert_eq(preflights[1].stage, "build")
    t.assert_eq(preflights[2].stage, "package")
    t.assert_eq(preflights[3].stage, "symbols")
    t.assert_eq(preflights[4].stage, "install")
    t.assert_eq(preflights[5].stage, "launch")
    t.assert_eq(preflights[2].requires[3].host_capability, "security_entry")
  end)
end)
