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

  t.it("routes explicit platform selection through the order-independent target handoff", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local start = assert(source:find("local function set_platform(input, opts)", 1, true))
    local finish = assert(source:find("local function build_target(opts)", start, true))
    local body = source:sub(start, finish)

    t.assert_contains(body, "CORE_RT.project_state.stage_target")
    t.assert_contains(body, "opts.stage_next == false")
    t.assert_contains(body, "CORE_RT.project_state.update_target")
    t.assert_contains(body, "UE target staged for the next project")
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
    t.assert_contains(
      command,
      vim.fn.stdpath("config"):gsub("\\", "/") .. "/scripts/ue_ios_cpp_iteration.zsh"
    )
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

  t.it("moves Apple semantic generation into UEPrepare without making UEPrepare compile", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local compile_start = assert(source:find("function CORE_RT%.compile_for_nvim", 1))
    local compile_end = assert(source:find("%-%- Find the newest APK", compile_start))
    local compile_body = source:sub(compile_start, compile_end)
    t.assert_contains(compile_body, "build_target")
    t.assert_contains(compile_body, "CORE_RT.prepare_async")
    t.assert_false(compile_body:find("generate_semantic_cdb_after_build", 1, true) ~= nil,
      "UECompileForNvim compatibility entry must delegate semantic ownership to UEPrepare")

    local prepare_start = assert(source:find("local function prepare_async", 1, true))
    local prepare_end = assert(source:find("export_compile_commands = prepare_async", prepare_start, true))
    local prepare_body = source:sub(prepare_start, prepare_end)
    t.assert_contains(prepare_body, "CORE_RT.prepare_apple_semantics")
    t.assert_false(prepare_body:find("build_target(", 1, true) ~= nil,
      "UEPrepare must depend on the preceding build and never compile")

    local helper_start = assert(source:find("function CORE_RT.prepare_apple_semantics", 1, true))
    local helper_end = assert(source:find("function CORE_RT.compile_for_nvim", helper_start, true))
    local helper_body = source:sub(helper_start, helper_end)
    t.assert_contains(helper_body, 'targets.supports(target_ctx.platform, "semantic_cdb"')
    t.assert_contains(helper_body, "CORE_RT.apple_build_evidence_matches")
    t.assert_contains(helper_body, "run <leader>ub and wait for it to finish")
    t.assert_contains(helper_body, "CORE_RT.run_clangd_preflight")
    t.assert_contains(helper_body, "CORE_RT.generate_semantic_cdb_after_build")
    t.assert_contains(helper_body, "CORE_RT.setup_ios")
    t.assert_contains(helper_body, 'target_ctx.platform == "IOS"')

    local semantic_start = assert(source:find("function CORE_RT.generate_semantic_cdb_after_build", 1, true))
    local semantic_end = assert(source:find("function CORE_RT.ios_setup_is_ready", semantic_start, true))
    local semantic_body = source:sub(semantic_start, semantic_end)
    t.assert_contains(semantic_body, "env = plan.env")

    local terminal_start = assert(source:find("local function open_terminal_command", 1, true))
    local terminal_end = assert(source:find("PICKER INTEGRATION", terminal_start, true))
    local terminal_body = source:sub(terminal_start, terminal_end)
    t.assert_contains(terminal_body, "env = opts.env")
  end)

  t.it("migrates an exact pre-marker IOS receipt into project-scoped build evidence", function()
    local persisted_key
    local persisted_value
    local recovered = {
      target = "SampleGame",
      platform = "IOS",
      configuration = "Development",
      completed_at = "2026-08-19T12:52:44Z",
      receipt_path = "/Project/Binaries/IOS/SampleGame.target",
      launch_path = "/Project/Binaries/IOS/SampleGame",
      source = "ubt-receipt",
    }
    local ok, evidence = ue._apple_build_evidence_matches_for_test({
      engine_root = "/UE",
      project_root = "/Workspace",
      uproject = "/Project/Sample.uproject",
    }, {
      project_dir = "/Project",
      target = "SampleGame",
      platform = "IOS",
      configuration = "Development",
    }, {
      read_state = function() return {} end,
      driver = {
        build_receipt_evidence = function() return recovered end,
      },
      update_state_field = function(_, key, value)
        persisted_key = key
        persisted_value = value
        return true
      end,
      notify = function() end,
    })

    t.assert_true(ok)
    t.assert_eq(evidence.source, "ubt-receipt")
    t.assert_eq(persisted_key, "apple_semantic_build")
    t.assert_eq(persisted_value.project_root, "/Workspace")
    t.assert_eq(persisted_value.uproject, "/Project/Sample.uproject")
    t.assert_eq(persisted_value.target, "SampleGame")
    t.assert_eq(persisted_value.platform, "IOS")
    t.assert_eq(persisted_value.configuration, "Development")
  end)

  t.it("reuses a validated IOS semantic source only for the exact build evidence and file signature", function()
    local ctx = {
      engine_root = "/UE",
      project_root = "/Workspace",
      uproject = "/Project/Sample.uproject",
    }
    local target_ctx = {
      target = "SampleGame",
      platform = "IOS",
      configuration = "Development",
    }
    local build_evidence = {
      completed_at = "2026-08-19T12:52:44Z",
    }
    local marker = {
      project_root = ctx.project_root,
      uproject = ctx.uproject,
      target = target_ctx.target,
      platform = target_ctx.platform,
      configuration = target_ctx.configuration,
      build_completed_at = build_evidence.completed_at,
      entry_count = 14073,
      source = {
        path = "/UE/cdb/IOS/compile_commands.json",
        size = 291457510,
        mtime_sec = 100,
        mtime_nsec = 200,
      },
    }
    local function check(stat, evidence)
      return ue._apple_semantic_source_reusable_for_test(
        ctx,
        target_ctx,
        marker.source.path,
        evidence or build_evidence,
        {
          read_state = function() return { apple_semantic_cdb = marker } end,
          fs_stat = function() return stat end,
        }
      )
    end

    local reusable, info = check({
      type = "file",
      size = marker.source.size,
      mtime = { sec = marker.source.mtime_sec, nsec = marker.source.mtime_nsec },
    })
    local changed_source = check({
      type = "file",
      size = marker.source.size + 1,
      mtime = { sec = marker.source.mtime_sec, nsec = marker.source.mtime_nsec },
    })
    local newer_build = check({
      type = "file",
      size = marker.source.size,
      mtime = { sec = marker.source.mtime_sec, nsec = marker.source.mtime_nsec },
    }, { completed_at = "2026-08-20T00:00:00Z" })

    t.assert_true(reusable)
    t.assert_true(info.reused)
    t.assert_true(info.no_op)
    t.assert_eq(info.entry_count, 14073)
    t.assert_false(changed_source)
    t.assert_false(newer_build)
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
    t.assert_contains(body, 'CORE_RT.run_target_preflight(driver, "build"')
    t.assert_contains(body, "if opts.require_prepared and not prepared.found")
    t.assert_contains(body, "vim.ui.select")
  end)

  t.it("provides one IOS setup flow for platform, verified signing, and device", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local start = assert(source:find("function CORE_RT.setup_ios", 1, true))
    local finish = assert(source:find("local function with_target_bundle_id", start, true))
    local body = source:sub(start, finish)

    t.assert_contains(body, 'set_platform("IOS", { stage_next = false })')
    t.assert_contains(body, "CORE_RT.select_ios_signing_certificate")
    t.assert_contains(body, "CORE_RT.select_target_device")
    t.assert_contains(body, "require_prepared = true")
    t.assert_contains(body, "auto_select_single = true")
    t.assert_contains(body, "expected_engine_root = setup_engine_root")
    t.assert_contains(body, "expected_project_root = setup_project_root")
    t.assert_contains(body, "resolve_ios_legacy_install_script")
    t.assert_contains(body, "project changed during IOS setup")
    t.assert_contains(body, "if not runtime then")
    t.assert_contains(body, "IOS setup ready")
  end)

  t.it("revalidates the legacy IOS install helper before treating setup as ready", function()
    local ctx = {
      engine_root = "/UE",
      project_root = "/Project",
    }
    local dependencies = {
      read_state = function()
        return {
          ios_signing_identity = {
            fingerprint = "ABC123",
          },
          target_runtime = {
            IOS = {
              device_id = "LEGACY-DEVICE",
              device_backend = "legacy-mobiledevice",
              setup_verified_at = "2026-08-20T08:00:00Z",
              setup_signing_fingerprint = "ABC123",
            },
          },
        }
      end,
      driver = {
        prepared_signing_identity = function()
          return {
            ok = true,
            found = true,
            identity = { fingerprint = "ABC123" },
          }
        end,
      },
    }

    t.assert_false(ue._ios_setup_is_ready_for_test(ctx, vim.tbl_extend("force", dependencies, {
      resolve_legacy_install_script = function() return nil, "missing helper" end,
    })))
    t.assert_true(ue._ios_setup_is_ready_for_test(ctx, vim.tbl_extend("force", dependencies, {
      resolve_legacy_install_script = function() return "/Tools/InstallIOSClient.sh" end,
    })))
  end)

  t.it("propagates target runtime persistence failures", function()
    local missing_engine = vim.fn.tempname() .. "-unselected-engine"
    local runtime, err = ue._update_target_runtime_for_test(missing_engine, "IOS", {
      device_id = "MUST-NOT-BE-PERSISTED",
    })

    t.assert_nil(runtime)
    t.assert_contains(err, "no project selected")
  end)

  t.it("falls back to structured pre-iOS17 discovery and persists its backend", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local start = assert(source:find("function CORE_RT.select_target_device", 1, true))
    local finish = assert(source:find("local function with_target_bundle_id", start, true))
    local body = source:sub(start, finish)

    t.assert_contains(body, "fallback_device_list_plan")
    t.assert_contains(body, "parse_fallback_device_list")
    t.assert_contains(body, "device_backend = device.backend")
    t.assert_contains(body, "expected_engine_root")
    t.assert_contains(body, "project changed during IOS setup")
    t.assert_contains(body, "if not runtime then")
    t.assert_contains(body, "IOS device discovery")
    t.assert_contains(body, "Checking CoreDevice")
    t.assert_contains(body, "Checking pre-iOS17 USB MobileDevice")
    t.assert_contains(body, "Recovering legacy IOS USB route")
    t.assert_contains(body, "resolve_ios_usb_reset_script")
    t.assert_contains(body, "mobiledevice_device_list_plans")
    t.assert_contains(body, "parse_mobiledevice_device_list")
    t.assert_contains(body, "preferred_device_id")
    t.assert_contains(body, "saved, offline")
    t.assert_contains(body, "local plan = mobile_plan")
    t.assert_contains(body, "plan.metadata.transport")
    t.assert_contains(body, "local function refresh_offline_device")
    t.assert_contains(body, '{ "--force", device.id }')
    t.assert_contains(body, "IOS USB route refreshed; rediscovering selected device")
    t.assert_contains(body, "IOS USB route is still offline; refreshed device list")
    t.assert_contains(body, "CORE_RT.select_target_device(platform, opts)")
    t.assert_contains(body, "refresh_offline_device(device)")
    t.assert_contains(body, "next_opts.offline_refresh_attempted = true")
    t.assert_contains(body, "remains offline after one refresh")
    t.assert_false(body:find('fail("IOS USB refresh failed:', 1, true) ~= nil,
      "offline selection must refresh the picker even when physical recovery fails")
  end)

  t.it("reads the selected staged IOS app bundle id instead of reusing persisted runtime state", function()
    local seen = {
      validated = {},
    }
    local resolved_bundle
    local resolved_artifacts
    local resolved_error
    local artifacts = {
      {
        path = "/Stage/IOS/Development/Payload/NewBuild.app",
      },
    }

    ue._with_target_bundle_id_for_test({}, {
      id = "IOS",
      select_staged_artifact = function(received_artifacts)
        t.assert_eq(received_artifacts, artifacts)
        return {
          ok = true,
          app_path = "/Stage/IOS/Development/Payload/NewBuild.app",
        }
      end,
      bundle_id_plan = function(app_path)
        t.assert_eq(app_path, "/Stage/IOS/Development/Payload/NewBuild.app")
        return { app_path = app_path }
      end,
      validate_bundle_id = function(value)
        seen.validated[#seen.validated + 1] = value
        if value == "com.example.newbuild" then
          return { ok = true, bundle_id = value }
        end
        return { ok = false, reason = "unexpected bundle id: " .. tostring(value) }
      end,
    }, {
      artifacts = artifacts,
      bundle_id = "com.example.persisted-runtime",
    }, require("utils.platform.macos"), function(bundle_id, callback_artifacts, bundle_err)
      resolved_bundle = bundle_id
      resolved_artifacts = callback_artifacts
      resolved_error = bundle_err
    end, {
      task_runner = {
        run = function(plan, opts)
          t.assert_eq(plan.app_path, "/Stage/IOS/Development/Payload/NewBuild.app")
          opts.on_exit({
            code = 0,
            stdout = "com.example.newbuild",
          })
          return true
        end,
        error_message = function(result)
          return tostring(result.stderr or result.stdout or "bundle probe failed")
        end,
      },
    })

    t.assert_eq(resolved_bundle, "com.example.newbuild")
    t.assert_eq(resolved_artifacts, artifacts)
    t.assert_nil(resolved_error)
    t.assert_eq(#seen.validated, 1)
    t.assert_eq(seen.validated[1], "com.example.newbuild")
  end)

  t.it("routes a selected legacy backend through the installed-app launch helper", function()
    local command, err, plan = with_target_env("IOS", "Development", "SampleGame", function()
      return ue._target_plan_for_test(
        "launch",
        {
          engine_root = "/UE",
          project_root = "/Project",
          uproject = "/Project/Sample.uproject",
          state = {
            target_runtime = {
              IOS = {
                device_id = "LEGACY-DEVICE",
                device_backend = "legacy-mobiledevice",
                bundle_id = "com.example.samplegame",
              },
            },
          },
        },
        "IOS",
        {
          host_driver = {
            id = "macos",
            shell_entry = function() return "/bin/zsh" end,
            ios_deploy_entry = function() return "/opt/homebrew/bin/ios-deploy" end,
          },
          legacy_launch_script = "/NvimConfig/scripts/ue_ios_legacy_launch.zsh",
          legacy_signing = { prepared_app = "/Prepared/Client.app" },
          json_output = "/tmp/ios-launch.json",
        }
      )
    end)

    t.assert_nil(err)
    t.assert_type(command, "table")
    t.assert_contains(plan.args, "/NvimConfig/scripts/ue_ios_legacy_launch.zsh")
    t.assert_contains(plan.args, "--bundle-id")
    t.assert_eq(plan.metadata.backend, "legacy-mobiledevice")
  end)

  t.it("rehydrates legacy install and launch evidence after a Nvim restart", function()
    local source = table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue.lua"), "\n")
    local helper_start = assert(source:find("local function prepare_legacy_ios_install", 1, true))
    local helper_finish = assert(source:find("function CORE_RT.run_target_preflight", helper_start, true))
    local helper = source:sub(helper_start, helper_finish)
    local install_start = assert(source:find("function CORE_RT.install_target", helper_finish, true))
    local install_finish = assert(source:find("function CORE_RT.launch_target", install_start, true))
    local install = source:sub(install_start, install_finish)
    local launch_finish = assert(source:find("\nend\n\nfunction M.launch_app", install_finish, true))
    local launch = source:sub(install_finish, launch_finish)

    t.assert_contains(install, 'target_ctx.device_backend == "legacy-mobiledevice"')
    t.assert_contains(helper, "collect_existing_artifacts(driver, target_ctx)")
    t.assert_contains(helper, "legacy_install_script")
    t.assert_contains(helper, "legacy_signing")
    t.assert_contains(helper, "prepare_legacy_ios_launch")
    t.assert_contains(helper, "prepared.prepared_app")
    t.assert_contains(install, "install_progress_tracker")
    t.assert_contains(install, "on_stdout = stdout_progress")
    t.assert_contains(install, "on_stderr = stderr_progress")
    t.assert_contains(install, "Starting container-preserving install")
    t.assert_contains(launch, "prepare_legacy_ios_launch(ctx, driver, target_ctx)")
    t.assert_contains(launch, "IOS launch")
    t.assert_contains(launch, "launch_progress:report")
    t.assert_contains(launch, "Waiting for selected IOS device")
    t.assert_contains(launch, "Verifying launched IOS process")
    t.assert_contains(launch, "finish_launch_progress")
    t.assert_contains(launch, "target_launch_running")
    t.assert_contains(launch, "launch is already in progress")
    t.assert_contains(launch, "ensure_legacy_ios_launch_device")
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
