-- tests/cases/dap_spec.lua
-- DAP 平台注册：platforms 注册/查找 + 各平台模块 attach/launch 导出。

local t = require("tests.harness")
t.bootstrap()

t.describe("ue.dap.platforms: 注册与查找", function()
  local p = require("ue.dap.platforms")

  t.it("register_attach + attach_handler 可调用", function()
    p._reset_for_test()
    local hit = false
    p.register_attach("xtest", function() hit = true end)
    local h = p.attach_handler("xtest")
    t.assert_type(h, "function")
    h()
    t.assert_true(hit, "注册的 handler 未触发")
    p._reset_for_test()
  end)

  t.it("未注册的 launch_handler 返回 nil", function()
    p._reset_for_test()
    p.register_attach("xtest", function() end)
    t.assert_nil(p.launch_handler("xtest"))
    p._reset_for_test()
  end)

  t.it("freezes lifecycle dispatch on the bound session owner", function()
    p._reset_for_test()
    local calls = {}
    p.register_attach("alpha", function() calls[#calls + 1] = "attach:alpha" end)
    p.register_attach("beta", function() calls[#calls + 1] = "attach:beta" end)
    p.register_lifecycle("alpha", {
      stop = function(opts) calls[#calls + 1] = "stop:" .. opts.owner.owner end,
      status = function(opts) calls[#calls + 1] = "status:" .. opts.owner.owner end,
      reattach = function(opts) calls[#calls + 1] = "reattach:" .. opts.owner.owner end,
      cleanup = function(opts) calls[#calls + 1] = "cleanup:" .. opts.owner.owner end,
    })
    p.register_lifecycle("beta", {
      stop = function(opts) calls[#calls + 1] = "stop:" .. opts.owner.owner end,
    })

    local started = p.begin("attach", "alpha", { device_id = "DEVICE-A" })
    t.assert_true(started)
    local session = {
      config = {
        type = "lldb",
        _ue_session_owner = "alpha",
        _ue_session_operation = "attach",
      },
    }
    local owner, bind_err = p.bind_session(session, { device_id = "DEVICE-A", process_id = 4242 })
    t.assert_nil(bind_err)
    t.assert_eq(owner.owner, "alpha")
    t.assert_eq(owner.process_id, 4242)

    -- A later UI/platform choice may prepare another invocation, but the
    -- existing session lifecycle remains bound to alpha.
    p.begin("attach", "beta")
    local stopped, stop_err = p.dispatch_lifecycle("stop", { session = session })
    t.assert_true(stopped, stop_err and stop_err.reason)
    t.assert_eq(calls[#calls], "stop:alpha")

    local cleaned, cleanup_err = p.dispatch_lifecycle("cleanup", { session = session, reason = "device-disconnect" })
    t.assert_true(cleaned, cleanup_err and cleanup_err.reason)
    t.assert_eq(calls[#calls], "cleanup:alpha")

    local ended = p.end_session(session)
    t.assert_eq(ended.owner, "alpha")
    t.assert_nil(session._ue_session_owner_record)
    t.assert_nil(p.session_owner(session))
    local reattached, reattach_err = p.dispatch_lifecycle("reattach")
    t.assert_true(reattached, reattach_err and reattach_err.reason)
    t.assert_eq(calls[#calls], "reattach:alpha")
    p._reset_for_test()
  end)

  t.it("never falls back to another target for an unsupported owner lifecycle", function()
    p._reset_for_test()
    local foreign_calls = 0
    p.register_attach("ios", function() end)
    p.register_lifecycle("ios", {
      stop = function() end,
    })
    p.register_lifecycle("mac", {
      reattach = function() foreign_calls = foreign_calls + 1 end,
    })
    p.begin("attach", "ios")
    local session = { config = { type = "lldb", _ue_session_owner = "ios" } }
    p.bind_session(session)

    local handled, err = p.dispatch_lifecycle("reattach", { session = session })
    t.assert_nil(handled)
    t.assert_eq(err.owner, "ios")
    t.assert_contains(err.reason, "does not provide")
    t.assert_eq(foreign_calls, 0)
    p._reset_for_test()
  end)

  t.it("fails closed when lifecycle owner metadata is missing", function()
    p._reset_for_test()
    p.register_attach("stale", function() end)
    p.begin("attach", "stale")
    local unmanaged, bind_err = p.bind_session({ config = { type = "lldb" } })
    t.assert_nil(unmanaged)
    t.assert_eq(bind_err.reason, "session owner metadata is missing")
    p._reset_for_test()
    local handled, err = p.dispatch_lifecycle("stop")
    t.assert_nil(handled)
    t.assert_eq(err.kind, "stop")
    t.assert_contains(err.reason, "owner metadata")
    p._reset_for_test()
  end)
end)

t.describe("ue.dap: 各平台模块导出 attach/launch", function()
  for _, id in ipairs({ "win64", "mac", "linux", "ios" }) do
    t.it(id .. " 模块导出 attach + launch", function()
      local m = require("ue.dap." .. id)
      t.assert_type(m.attach, "function", id .. ".attach")
      t.assert_type(m.launch, "function", id .. ".launch")
      if id == "ios" then
        t.assert_type(m.cleanup, "function", "ios.cleanup")
      end
    end)
  end


  t.it("IOS DAP 使用独立 device handler，不借用 Mac handler", function()
    local config = vim.fn.stdpath("config")
    local source = table.concat(vim.fn.readfile(config .. "/lua/ue/dap/ios.lua"), "\n")
    t.assert_false(source:find('require("ue.dap.mac")', 1, true) ~= nil)
    local driver, unavailable = require("ue.targets").resolve(
      "IOS", "dap_attach", require("utils.platform.macos")
    )
    t.assert_eq(driver.id, "IOS")
    t.assert_nil(unavailable)
  end)
end)

t.describe("ue.dap: generic owner lifecycle compatibility", function()
  t.it("desktop toolbar terminate preserves nvim-dap native terminate behavior", function()
    local dap_mod = require("ue.dap")
    local fallback_calls = 0
    local result = dap_mod.dap_stop_session({
      source = "terminate",
      fallback = function()
        fallback_calls = fallback_calls + 1
        return "native-terminate"
      end,
    })
    t.assert_eq(result, "native-terminate")
    t.assert_eq(fallback_calls, 1)
  end)
end)

t.describe("ue.dap.ios: legacy MobileDevice lldb-dap config", function()
  local ios = require("ue.dap.ios")
  local base = {
    binary = "/Project Root/Binaries/IOS/SampleGame",
    cwd = "/Project Root",
    device_app_path = "/private/var/containers/Bundle/Application/ABC/SampleGame.app",
    executable_name = "SampleGame",
    port = 12345,
    symbols = "/Device Support/iPhone13,2 15.4.1 (19E258)/Symbols",
  }

  t.it("attach-at-launch creates the local symbol target before RemoteLaunch", function()
    local opts = vim.tbl_extend("force", base, { mode = "launch" })
    local cfg, err = ios._build_config_for_test(opts)
    t.assert_nil(err)
    t.assert_eq(cfg.request, "attach")
    t.assert_eq(cfg.stopOnEntry, true)
    t.assert_eq(cfg._ue_ios_session_owner, "legacy-mobiledevice")
    t.assert_eq(cfg._ue_session_owner, "ios")
    t.assert_eq(cfg._ue_session_operation, "launch")
    t.assert_contains(cfg.initCommands, "settings set target.memory-module-load-level partial")
    t.assert_contains(cfg.attachCommands,
      'platform select remote-ios --sysroot "/Device Support/iPhone13,2 15.4.1 (19E258)/Symbols"')
    t.assert_contains(cfg.attachCommands,
      'target create "/Project Root/Binaries/IOS/SampleGame"')
    local all = table.concat(cfg.attachCommands, "\n")
    local target_i = assert(all:find("target create", 1, true))
    local remote_i = assert(all:find("SetPlatformFileSpec", 1, true))
    local connect_i = assert(all:find("ConnectRemote", 1, true))
    local launch_i = assert(all:find("RemoteLaunch", 1, true))
    t.assert_true(target_i < remote_i and remote_i < connect_i and connect_i < launch_i)
    t.assert_contains(all,
      "/private/var/containers/Bundle/Application/ABC/SampleGame.app/SampleGame")
    t.assert_contains(all, "True, ios_error")
    t.assert_contains(all, "local iOS binary did not match the loaded device image")
    t.assert_contains(all, "lldb.debugger.GetListener()")
    t.assert_contains(all, "time.sleep(0.1)")
    t.assert_false(all:find("StartListeningForEventClass", 1, true) ~= nil)
  end)

  t.it("ordinary attach waits for the async RemoteAttach stop", function()
    local opts = vim.tbl_extend("force", base, { mode = "attach", pid = 4242 })
    local cfg, err = ios._build_config_for_test(opts)
    t.assert_nil(err)
    local all = table.concat(cfg.attachCommands, "\n")
    t.assert_contains(all, "RemoteAttachToProcessWithID(4242, ios_error)")
    t.assert_contains(all, "ios_state != lldb.eStateStopped")
    t.assert_false(all:find("RemoteLaunch", 1, true) ~= nil)
  end)

  t.it("fails closed instead of inventing project, device, or pid defaults", function()
    local missing_binary, binary_err = ios._build_config_for_test(vim.tbl_extend(
      "force", base, { mode = "launch", binary = "" }
    ))
    local missing_pid, pid_err = ios._build_config_for_test(vim.tbl_extend(
      "force", base, { mode = "attach" }
    ))
    t.assert_nil(missing_binary)
    t.assert_contains(binary_err, "binary")
    t.assert_nil(missing_pid)
    t.assert_contains(pid_err, "pid")
  end)

  t.it("parses one exact installed bundle and its executable", function()
    local app, err = ios._parse_installed_apps_for_test(vim.json.encode({
      {
        CFBundleIdentifier = "com.example.other",
        CFBundleExecutable = "Other",
        Path = "/private/Other.app",
      },
      {
        CFBundleIdentifier = "com.example.game",
        CFBundleExecutable = "SampleGame",
        Path = "/private/SampleGame.app",
      },
    }), "com.example.game")
    t.assert_nil(err)
    t.assert_eq(app.app_path, "/private/SampleGame.app")
    t.assert_eq(app.executable_name, "SampleGame")
  end)

  t.it("keeps stdout-only libimobiledevice failures actionable", function()
    local detail = require("ue.dap._ios_process").device_unavailable("TEST-UDID", {
      code = 255,
      stdout = "ERROR: Device TEST-UDID not found!\n",
      stderr = "",
    })
    t.assert_contains(detail, "Device TEST-UDID not found")
    t.assert_contains(detail, "legacy USB")
  end)

  t.it("freezes the selected Xcode adapter instead of using Homebrew fallback", function()
    local source = table.concat({
      table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue/dap/ios.lua"), "\n"),
      table.concat(vim.fn.readfile(vim.fn.stdpath("config") .. "/lua/ue/dap/_ios_runtime.lua"), "\n"),
    }, "\n")
    t.assert_contains(source, 'runtime.tools.xcrun, "--find", "lldb-dap"')
    t.assert_contains(source, "runtime.adapter")
    t.assert_contains(source, "initialize_timeout_sec = 90")
  end)
end)

t.describe("ue.dap.ios: planned CoreDevice lldb-dap config", function()
  local ios = require("ue.dap.ios")

  local function build_coredevice_config(opts)
    opts = vim.tbl_extend("force", {
      backend = "coredevice",
      binary = "/Project Root/Binaries/IOS/SampleGame",
      dsym = "/Project Root/Binaries/IOS/SampleGame.dSYM",
      bundle_id = "com.example.samplegame",
      cwd = "/Project Root",
      device_id = "CORE-DEVICE-1",
      expected_uuids = { "322CB148-C401-3EA0-A023-4B21A104D42F" },
      mode = "attach",
      pid = 991,
    }, opts or {})

    if type(ios._build_coredevice_config_for_test) == "function" then
      return ios._build_coredevice_config_for_test(opts)
    end
    if type(ios._build_config_for_test) == "function" then
      return ios._build_config_for_test(opts)
    end
    error("ue.dap.ios must expose _build_coredevice_config_for_test() or backend-aware _build_config_for_test()")
  end

  t.it("launch config freezes the suspended CoreDevice process and uses device attach commands", function()
    local cfg, err = build_coredevice_config({ mode = "launch", pid = 991 })
    t.assert_nil(err)
    t.assert_eq(cfg.request, "attach")
    t.assert_eq(cfg.stopOnEntry, true)
    t.assert_eq(cfg._ue_session_owner, "ios")
    t.assert_eq(cfg._ue_session_operation, "launch")
    t.assert_eq(cfg._ue_ios_backend, "coredevice")
    t.assert_eq(cfg._ue_device_id, "CORE-DEVICE-1")
    t.assert_eq(cfg._ue_process_id, 991)

    local all = table.concat(cfg.attachCommands, "\n")
    local target_i = assert(all:find("target create", 1, true))
    local device_i = assert(all:find("device select", 1, true))
    local attach_i = assert(all:find("device process attach -p 991", 1, true))
    local symbols_i = assert(all:find("target symbols add", 1, true))
    t.assert_true(target_i < device_i and device_i < attach_i and attach_i < symbols_i)
    t.assert_contains(all, 'target symbols add "/Project Root/Binaries/IOS/SampleGame.dSYM"')
    t.assert_contains(all, "CORE-DEVICE-1")
    local post = table.concat(cfg.postRunCommands, "\n")
    local status_i = assert(post:find("process status", 1, true))
    local uuid_i = assert(post:find("GetUUIDString", 1, true))
    t.assert_true(status_i < uuid_i)
    t.assert_contains(post, "__UE_IOS_LOADED_UUID_OK__")
    t.assert_contains(post, "__UE_IOS_LOADED_UUID_MISMATCH__")
    t.assert_contains(post, "len(ios_loaded_main) == 1")
    t.assert_false(all:find("platform select remote-ios", 1, true) ~= nil)
    t.assert_false(all:find("ConnectRemote", 1, true) ~= nil)
    t.assert_false(all:find("RemoteLaunch", 1, true) ~= nil)
    t.assert_false(all:find("ios-deploy", 1, true) ~= nil)
  end)

  t.it("ordinary attach uses the same frozen owner/backend/device/pid metadata", function()
    local cfg, err = build_coredevice_config({ mode = "attach", pid = 4242 })
    t.assert_nil(err)
    t.assert_eq(cfg._ue_session_owner, "ios")
    t.assert_eq(cfg._ue_session_operation, "attach")
    t.assert_eq(cfg._ue_ios_backend, "coredevice")
    t.assert_eq(cfg._ue_device_id, "CORE-DEVICE-1")
    t.assert_eq(cfg._ue_process_id, 4242)

    local all = table.concat(cfg.attachCommands, "\n")
    local target_i = assert(all:find("target create", 1, true))
    local device_i = assert(all:find("device select", 1, true))
    local attach_i = assert(all:find("device process attach -p 4242", 1, true))
    local symbols_i = assert(all:find("target symbols add", 1, true))
    t.assert_true(target_i < device_i and device_i < attach_i and attach_i < symbols_i)
    t.assert_false(all:find("remote-ios", 1, true) ~= nil)
    t.assert_false(all:find("RemoteAttachToProcessWithID", 1, true) ~= nil)
  end)

  t.it("CoreDevice config does not require legacy bridge-only symbols or port inputs", function()
    local cfg, err = build_coredevice_config({
      binary = "/Project Root/Binaries/IOS/SampleGame",
      bundle_id = "com.example.samplegame",
      cwd = "/Project Root",
      device_id = "CORE-DEVICE-1",
      mode = "attach",
      pid = 991,
    })
    t.assert_nil(err)
    t.assert_eq(cfg._ue_ios_backend, "coredevice")

    local all = table.concat(cfg.attachCommands, "\n")
    t.assert_false(all:find("DeviceSupport", 1, true) ~= nil)
    t.assert_false(all:find("127.0.0.1", 1, true) ~= nil)
    t.assert_false(all:find("ios-deploy", 1, true) ~= nil)
  end)
end)

t.describe("ue.dap._ios_process: CoreDevice JSON parsers", function()
  local ios_process = require("ue.dap._ios_process")

  t.it("parses one exact CoreDevice installed app and rejects duplicates", function()
    local app, err = ios_process.parse_coredevice_apps(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          installedApplications = {
            { bundleIdentifier = "com.example.other", url = "file:///private/Other.app" },
            { bundleID = "com.example.samplegame", bundleURL = "file:///private/SampleGame.app" },
          },
        },
      }),
      {
        canonical_device_id = "CORE-DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )
    local duplicate, duplicate_err = ios_process.parse_coredevice_apps(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          apps = {
            { bundleIdentifier = "com.example.samplegame", url = "file:///private/A.app" },
            { applicationIdentifier = "com.example.samplegame", path = "file:///private/B.app" },
          },
        },
      }),
      {
        canonical_device_id = "CORE-DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )

    t.assert_nil(err)
    t.assert_eq(app.device_id, "CORE-DEVICE-1")
    t.assert_eq(app.bundle_id, "com.example.samplegame")
    t.assert_eq(app.app_url, "file:///private/SampleGame.app")
    t.assert_nil(duplicate)
    t.assert_contains(duplicate_err, "matched 2 installed apps")
  end)

  t.it("fails closed on CoreDevice app device mismatch", function()
    local app, err = ios_process.parse_coredevice_apps(
      vim.json.encode({
        result = {
          deviceIdentifier = "OTHER-DEVICE",
          installedApplications = {
            { bundleIdentifier = "com.example.samplegame", url = "file:///private/SampleGame.app" },
          },
        },
      }),
      {
        canonical_device_id = "CORE-DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )
    t.assert_nil(app)
    t.assert_contains(err, "device identity mismatch")
  end)

  t.it("parses CoreDevice launch aliases and rejects nonpositive or mismatched identities", function()
    local launched, err = ios_process.parse_coredevice_launch(
      vim.json.encode({
        result = {
          targetDeviceIdentifier = "CORE-DEVICE-1",
          launchedProcess = {
            applicationIdentifier = "com.example.samplegame",
            pid = 991,
          },
        },
      }),
      {
        canonical_device_id = "CORE-DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )
    local bad_pid, bad_pid_err = ios_process.parse_coredevice_launch(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          process = {
            bundleIdentifier = "com.example.samplegame",
            processIdentifier = 0,
          },
        },
      }),
      {
        canonical_device_id = "CORE-DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )
    local mismatch, mismatch_err = ios_process.parse_coredevice_launch(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          process = {
            bundleIdentifier = "com.example.other",
            processIdentifier = 991,
          },
        },
      }),
      {
        canonical_device_id = "CORE-DEVICE-1",
        bundle_id = "com.example.samplegame",
      }
    )

    t.assert_nil(err)
    t.assert_eq(launched.device_id, "CORE-DEVICE-1")
    t.assert_eq(launched.bundle_id, "com.example.samplegame")
    t.assert_eq(launched.process_id, 991)
    t.assert_nil(bad_pid)
    t.assert_contains(bad_pid_err, "positive PID")
    t.assert_nil(mismatch)
    t.assert_contains(mismatch_err, "bundle identity mismatch")
  end)

  t.it("parses exact running processes, reports absence, and rejects duplicates", function()
    local exact, exact_err = ios_process.parse_coredevice_processes(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          runningProcesses = {
            { processIdentifier = 991, executableURL = "file:///private/SampleGame.app/SampleGame" },
          },
        },
      }),
      {
        app_url = "file:///private/SampleGame.app",
        canonical_device_id = "CORE-DEVICE-1",
      }
    )
    local absent, absent_err = ios_process.parse_coredevice_processes(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          runningProcesses = {},
        },
      }),
      {
        app_url = "file:///private/SampleGame.app",
        canonical_device_id = "CORE-DEVICE-1",
      }
    )
    local duplicate, duplicate_err = ios_process.parse_coredevice_processes(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          runningProcesses = {
            { processIdentifier = 991, executable = "file:///private/SampleGame.app/SampleGame" },
            { processIdentifier = 992, path = "file:///private/SampleGame.app/SampleGame" },
          },
        },
      }),
      {
        app_url = "file:///private/SampleGame.app",
        canonical_device_id = "CORE-DEVICE-1",
      }
    )

    t.assert_nil(exact_err)
    t.assert_false(exact.absent)
    t.assert_eq(exact.process_id, 991)
    t.assert_eq(exact.executable, "file:///private/SampleGame.app/SampleGame")
    t.assert_nil(absent_err)
    t.assert_true(absent.absent)
    t.assert_nil(duplicate)
    t.assert_contains(duplicate_err, "matched 2 running processes")
  end)

  t.it("treats PID reuse as absence and rejects nonpositive or duplicate pid lookups", function()
    local reused, reused_err = ios_process.parse_coredevice_processes(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          processes = {
            { pid = 991, executable = "file:///private/Other.app/Other" },
          },
        },
      }),
      {
        app_url = "file:///private/SampleGame.app",
        canonical_device_id = "CORE-DEVICE-1",
        pid = 991,
      }
    )
    local missing_pid, missing_pid_err = ios_process.parse_coredevice_processes(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          processes = {},
        },
      }),
      {
        app_url = "file:///private/SampleGame.app",
        canonical_device_id = "CORE-DEVICE-1",
        pid = 991,
      }
    )
    local bad_pid, bad_pid_err = ios_process.parse_coredevice_processes(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          processes = {},
        },
      }),
      {
        app_url = "file:///private/SampleGame.app",
        canonical_device_id = "CORE-DEVICE-1",
        pid = 0,
      }
    )
    local duplicate_pid, duplicate_pid_err = ios_process.parse_coredevice_processes(
      vim.json.encode({
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          processes = {
            { pid = 991, executable = "file:///private/SampleGame.app/SampleGame" },
            { processIdentifier = 991, executableURL = "file:///private/SampleGame.app/SampleGame" },
          },
        },
      }),
      {
        app_url = "file:///private/SampleGame.app",
        canonical_device_id = "CORE-DEVICE-1",
        pid = 991,
      }
    )

    t.assert_nil(reused_err)
    t.assert_true(reused.absent)
    t.assert_true(reused.reused)
    t.assert_eq(reused.process_id, 991)
    t.assert_nil(missing_pid_err)
    t.assert_true(missing_pid.absent)
    t.assert_nil(bad_pid)
    t.assert_contains(bad_pid_err, "requires a positive PID")
    t.assert_nil(duplicate_pid)
    t.assert_contains(duplicate_pid_err, "duplicate PID")
  end)

  t.it("normalizes and compares UUID sets from dwarfdump output", function()
    local uuids, err = ios_process.parse_uuid_output(table.concat({
      "UUID: 322cb148-c401-3ea0-a023-4b21a104d42f (arm64) /tmp/SampleGame",
      "UUID: 322CB148-C401-3EA0-A023-4B21A104D42F (arm64e) /tmp/SampleGame.dSYM",
      "UUID: 2f18f0f2-c2df-4d84-8e50-2f51ec0ad481 (arm64) /tmp/Helper",
    }, "\n"))
    local none, none_err = ios_process.parse_uuid_output("not a uuid line")

    t.assert_nil(err)
    t.assert_eq(#uuids, 2)
    t.assert_eq(uuids[1], "2F18F0F2-C2DF-4D84-8E50-2F51EC0AD481")
    t.assert_eq(uuids[2], "322CB148-C401-3EA0-A023-4B21A104D42F")
    t.assert_true(ios_process.uuid_sets_equal(uuids, {
      "2F18F0F2-C2DF-4D84-8E50-2F51EC0AD481",
      "322CB148-C401-3EA0-A023-4B21A104D42F",
    }))
    t.assert_false(ios_process.uuid_sets_equal(uuids, {
      "322CB148-C401-3EA0-A023-4B21A104D42F",
    }))
    t.assert_nil(none)
    t.assert_contains(none_err, "no UUID")
  end)
end)

t.describe("ue.dap.android: breakpoint preseed", function()
  local function with_breakpoints(raw, fn)
    local old = package.loaded["dap.breakpoints"]
    package.loaded["dap.breakpoints"] = {
      get = function() return raw end,
    }
    local ok, err = pcall(fn)
    package.loaded["dap.breakpoints"] = old
    if not ok then error(err, 0) end
  end

  t.it("K10: collects buffer-id and path keyed breakpoints", function()
    local android = require("ue.dap.android")
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "D:/proj/Source/SampleGame/Foo.cpp")
    with_breakpoints({
      [buf] = { { line = 17 } },
      ["D:/proj/Source/SampleGame/Bar.cpp"] = { { line = 29 } },
    }, function()
      local cmds = android._current_breakpoint_commands_for_test()
      t.assert_contains(cmds, '?breakpoint set -f "Bar.cpp" -l 29')
      t.assert_contains(cmds, '?breakpoint set -f "Foo.cpp" -l 17')
    end)
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
  end)

  t.it("K33: inserts preseed breakpoints after ASLR rebase and emits breakpoint list", function()
    local android = require("ue.dap.android")
    with_breakpoints({
      ["D:/proj/Source/SampleGame/Foo.cpp"] = { { line = 17 } },
    }, function()
      local cfg = {
        attachCommands = {
          'target create "D:/symbols/libUE4.so"',
          "platform select remote-android",
          "platform connect connect://[ANDROID-SERIAL-A]:5039",
          "process attach --pid 1234",
          "process handle SIGSEGV --notify false --pass true --stop false",
          "process handle SIGBUS  --notify false --pass true --stop false",
          "process handle SIGPIPE --notify false --pass false --stop false",
          "target modules load --file libUE4.so --slide 0x6c9fe21000",
        },
      }
      android._preseed_breakpoints_into_attach_commands_for_test(cfg)
      local slide_i, bp_i, list_i
      for i, cmd in ipairs(cfg.attachCommands) do
        if cmd:find("target modules load", 1, true) then slide_i = i end
        if cmd == '?breakpoint set -f "Foo.cpp" -l 17' then bp_i = i end
        if cmd == "breakpoint list" then list_i = i end
      end
      t.assert_true(slide_i and bp_i and slide_i < bp_i,
        "breakpoint must be inserted after ASLR rebase")
      t.assert_eq(list_i, bp_i + 1, "breakpoint list should immediately follow preseed")
    end)
  end)

  t.it("generic dap glue does not own Android attachCommands", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_false(text:find("ue_android_preseed_breakpoints", 1, true),
      "ue.dap.lua must not inject Android breakpoint attachCommands")
    t.assert_false(text:find("schedule_reattach", 1, true),
      "setBreakpoints must not silently detach and reattach")
  end)

  t.it("无 active DAP session 的 build preflight 不谎报 adapter 已停止", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap/android.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_contains(text, "result.adapter_killed = sess_active ~= nil")
  end)

  t.it("K34/3.4: bootstrap does not hardcode a symbol_lib fallback path", function()
    -- A literal symbol_lib short-circuits pick_symbol_lib() (its step 0 returns
    -- any existing ctx path verbatim, skipping the packageInfo versionCode
    -- exact-match), so a stale build-id lib would attach to the WRONG source
    -- revision (the 3.4 ad3d4e7c false-lead). Guard against re-introducing one.
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap/android.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    -- A `... or "...libUE4.so"` assignment is the dangerous shape: it forces a
    -- concrete library regardless of the installed APK. Comments mentioning the
    -- banned path are fine; an `or "<path>.so"` fallback expression is not.
    t.assert_false(text:find('or%s+"[^"]*libUE4%.so"') ~= nil,
      "android.lua must not hardcode an `or \"...libUE4.so\"` symbol_lib fallback")
    t.assert_false(text:find('android_symbol_lib%s*=%s*"') ~= nil,
      "android.lua must not assign a string-literal android_symbol_lib")
  end)

  t.it("K36: session-time setBreakpoints is gated and planted live (not warned)", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find('dap.listeners.after.configurationDone["ue_android_bp_config_done"]', 1, true) ~= nil,
      "Android DAP should mark configurationDone to distinguish initial sync vs live change")
    t.assert_true(text:find("session._ue_android_configuration_done ~= true", 1, true) ~= nil,
      "before-gate setBreakpoints is the preseed initial sync and must be left to attachCommands")
    -- After the gate, a session-time change must be planted live via the
    -- proven evaluate channel — NOT a :UEDAPReattach warning.
    t.assert_true(text:find("ue_android_live_plant_via_evaluate", 1, true) ~= nil,
      "active-session setBreakpoints should plant live via the evaluate channel")
    t.assert_true(text:find("active-session setBreakpoints → live evaluate plant", 1, true) ~= nil,
      "live plant path should be visible in diagnostics")
    -- The old reattach warning and its throttle must be gone.
    t.assert_true(text:find("are not silently reattached", 1, true) == nil,
      "the :UEDAPReattach active-session warning must be removed once live planting works")
    t.assert_true(text:find("D._ue_android_bp_notice_until_ms = now + 5000\n      vim.notify(\n        \"%[ue.dap%] Android breakpoint changes", 1, false) == nil,
      "the dedicated reattach-warning throttle block must be removed")
  end)

  -- ── Behavioral coverage of the live-plant pure logic ──────────────────
  -- These lock the *behavior* (not just the source text) of the load-bearing
  -- helpers behind the session-time live breakpoint path. Change
  -- android-dap-live-breakpoints (archived 2026-06-15); on-device proof in
  -- tools/evidence/android-f9/livebp-*.json.

  t.it("K36: live-plant command uses the proven basename form (matches preseed)", function()
    local D = require("ue.dap")
    -- A UE Android absolute Windows path must be rewritten to basename only —
    -- the exact shape attach-time preseed uses and that resolves against DWARF.
    local cmd, file = D._live_plant_command_for_test(
      { path = "D:/UE/EngineWorktree/Engine/Source/Runtime/Renderer/Private/MobileShadingRenderer.cpp",
        name = "MobileShadingRenderer.cpp" }, 1367)
    t.assert_eq(cmd, '`breakpoint set -f "MobileShadingRenderer.cpp" -l 1367',
      "live-plant must emit a backtick `breakpoint set -f <basename> -l <line>` command")
    t.assert_eq(file, "MobileShadingRenderer.cpp", "returned file must be the basename")
  end)

  t.it("live-plant command rejects invalid line / empty source", function()
    local D = require("ue.dap")
    t.assert_nil(D._live_plant_command_for_test({ name = "Foo.cpp" }, 0),
      "line 0 must not produce a command")
    t.assert_nil(D._live_plant_command_for_test({ name = "Foo.cpp" }, -1),
      "negative line must not produce a command")
    t.assert_nil(D._live_plant_command_for_test({ name = "Foo.cpp" }, nil),
      "nil line must not produce a command")
    t.assert_nil(D._live_plant_command_for_test({}, 10),
      "source with no usable name/path must not produce a command")
  end)

  t.it("K33: resolved-parser is the honest-verified signal (resolved>0 vs 0/nil)", function()
    local D = require("ue.dap")
    local hit = "1: file = 'MobileShadingRenderer.cpp', line = 1367, "
      .. "exact_match = 0, locations = 1, resolved = 1, hit count = 0"
    t.assert_eq(D._scan_breakpoint_resolved_for_test(hit), 1,
      "a resolved=1 breakpoint-list line must parse to 1 (real plant)")
    local pending = "1: file = 'Foo.cpp', line = 10, locations = 0, resolved = 0, hit count = 0"
    t.assert_eq(D._scan_breakpoint_resolved_for_test(pending), 0,
      "a resolved=0 (pending) line must parse to 0 — never fake success")
    t.assert_nil(D._scan_breakpoint_resolved_for_test("No breakpoints currently set."),
      "no resolved line at all must parse to nil")
    -- Multi-block dump: parser returns the LAST resolved value.
    local two = hit .. "\n2: file = 'Bar.cpp', line = 5, locations = 0, resolved = 0, hit count = 0"
    t.assert_eq(D._scan_breakpoint_resolved_for_test(two), 0,
      "multi-breakpoint dump returns the last resolved count")
  end)

  -- ── Invariant guards (the hard-won lessons that must never regress) ────

  t.it("INVARIANT: nvim-dap before.setBreakpoints runs in the RESPONSE pipeline", function()
    -- Hard-won (change android-dap-live-breakpoints): nvim-dap has NO
    -- before-request hook. `listeners.before.setBreakpoints` fires in
    -- handle_body's response pipeline with (session, err, response, request,
    -- seq) — you CANNOT mutate the outgoing args.source there. The earlier
    -- ue_android_bp_source_rewrite name implied wire-mutation; it must not
    -- come back, and the listener must recover lines from the `request` payload.
    local dap_path = vim.fn.stdpath("data") .. "/lazy/nvim-dap/lua/dap/session.lua"
    if vim.fn.filereadable(dap_path) == 1 then
      local sess = table.concat(vim.fn.readfile(dap_path), "\n")
      t.assert_true(sess:find("listeners.before%[decoded.command%]") ~= nil,
        "nvim-dap before-listeners must still fire from the response pipeline "
        .. "(handle_body) — if upstream adds a true before-request hook, revisit "
        .. "ue.dap.lua's setBreakpoints recovery")
    end
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find("ue_android_bp_source_rewrite", 1, true) == nil,
      "the misleading wire-mutating listener name must not return")
    t.assert_true(text:find("ue_android_bp_record_request", 1, true) ~= nil,
      "the before-listener must only record the request shape, not mutate it")
  end)

  t.it("K33: INVARIANT: live plant never fakes success and never detach+reattach", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    -- Reads back resolved state and warns on failure (honest verified).
    t.assert_true(text:find("scan_breakpoint_resolved", 1, true) ~= nil,
      "live plant must read back breakpoint-list resolved state")
    t.assert_true(text:find("did not resolve", 1, true) ~= nil,
      "live plant must surface an honest warning when resolved=0 / command errors")
    -- No reattach / detach-to-replant in the breakpoint path.
    t.assert_true(text:find("schedule_reattach", 1, true) == nil,
      "live plant must NOT schedule a detach+reattach to plant breakpoints")
    t.assert_true(text:find("ue_android_synthetic_breakpoint_response", 1, true) == nil,
      "the old always-verified synthetic setBreakpoints response must stay removed")
  end)

  t.it("K37: INVARIANT: explicit ASLR slide stays load-bearing with a reverify switch", function()
    -- K37: on this device, skipping `target modules load --slide` makes attach
    -- time out / crash the adapter. The slide + its plumbing must be kept; a
    -- UE_DAP_NO_SLIDE switch exists only to re-verify on other devices.
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap/android.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find("_module_rebase_cmd", 1, true) ~= nil,
      "the ASLR slide plumbing (_module_rebase_cmd) must remain")
    t.assert_true(text:find("UE_DAP_NO_SLIDE", 1, true) ~= nil,
      "the slide-skip reverify switch must remain documented for future devices")
  end)

  t.it("smoke harness installs UE DAP guards before Android attach", function()
    local path = vim.fn.stdpath("config") .. "/tools/nvim_android_dap_smoketest.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    local main_i = text:find("local function main", 1, true)
    local runtime_i = text:find("ensure_nvim_dap_runtime", main_i, true)
    local setup_i = text:find("ue.setup_dap(dap, smoke_dapui)", main_i, true)
    local attach_i = text:find("android.attach({ context = ctx })", main_i, true)
    t.assert_true(runtime_i and setup_i and attach_i and runtime_i < setup_i and setup_i < attach_i,
      "headless smoke must install ue.setup_dap guards before attach")
    t.assert_true(text:find("dap.listeners.after.event_output%[listener_key%]", 1, false) ~= nil,
      "headless smoke must capture LLDB output into its result JSON")
  end)

  t.it("DAP stackTrace guard keeps synthetic Android frames non-jumpable", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    t.assert_true(text:find("copy.line = %-1", 1, false) ~= nil,
      "synthetic Android frames should use line=-1 so nvim-dap skips UI jumps")
    t.assert_true(text:find('name = source and source.name or frame.name or "<synthetic>"', 1, true) ~= nil,
      "synthetic Android frames should retain a placeholder source name")
  end)

  t.it("synthetic-frame guards converge on a single annotated chokepoint", function()
    local path = vim.fn.stdpath("config") .. "/lua/ue/dap.lua"
    local text = table.concat(vim.fn.readfile(path), "\n")
    -- Shared anchor documenting the one upstream root cause.
    t.assert_true(text:find("ANCHOR(ue-synthetic-frame-guard)", 1, true) ~= nil,
      "synthetic-frame guards must share an ANCHOR doc-block naming the upstream cause")
    -- The three cross-referenced sites: chokepoint + two thin guards.
    t.assert_true(text:find("ANCHOR-USE:stackTrace", 1, true) ~= nil,
      "stackTrace listener must be marked as the chokepoint")
    t.assert_true(text:find("ANCHOR-USE:_frame_set", 1, true) ~= nil,
      "_frame_set patch must be cross-referenced as defence-in-depth")
    t.assert_true(text:find("ANCHOR-USE:bp-response", 1, true) ~= nil,
      "setBreakpoints response remap must be cross-referenced")
  end)

  t.it("sourceMap keeps build Engine paths local when project Engine is absent", function()
    local android = require("ue.dap.android")
    local root = vim.fn.tempname()
    local proot = root .. "/Project/Source/SampleGame"
    local build = root .. "/BuildRoot"
    vim.fn.mkdir(proot .. "/Binaries/Android", "p")
    vim.fn.mkdir(build .. "/Engine", "p")
    vim.fn.writefile({ "com.example.game", "1", "1.0.0" }, proot .. "/Binaries/Android/packageInfo.txt")

    local sm = android._pick_source_map_for_test({
      project_root = proot,
      android_build_root = build,
    })
    local build_engine = vim.fs.normalize(build .. "/Engine")
    t.assert_eq(sm[1].from, build_engine)
    t.assert_eq(sm[1].to, build_engine)
    t.assert_eq(sm[2].from, vim.fs.normalize(build))
    t.assert_eq(sm[2].to, vim.fs.normalize(proot))
    vim.fn.delete(root, "rf")
  end)

  t.it("sourceMap defaults to the selected project when no build root is configured", function()
    local android = require("ue.dap.android")
    local proot = vim.fn.tempname() .. "/Project/Source/SampleGame"
    vim.fn.mkdir(proot, "p")

    local sm = android._pick_source_map_for_test({ project_root = proot })
    local normalized = vim.fs.normalize(proot)
    t.assert_eq(sm[#sm].from, normalized)
    t.assert_eq(sm[#sm].to, normalized)
    vim.fn.delete(proot, "rf")
  end)
end)

t.describe("ue.dap: setup() 后平台已注册", function()
  -- 注意：本文件前面的用例调用过 _reset_for_test() 清空注册表，而
  -- ue.setup() 有 CORE_RT.setup_done 幂等守卫——若 setup 已执行过，
  -- 再次调用不会重新注册。因此这里直接复刻 setup 内的注册逻辑，
  -- 确保断言基于「平台注册 seam」本身的正确性，而非依赖调用顺序。
  local function ensure_platforms_registered()
    require("ue").setup()
    local p = require("ue.dap.platforms")
    -- 若被前序用例 reset 清空，按当前 host matrix 重放注册。
    p.register_supported(require("utils.platform").driver(), require("ue"))
    return p
  end

  t.it("平台注册 seam 只注册当前 host 支持的 target", function()
    local p = ensure_platforms_registered()
    local host_driver = require("utils.platform").driver()
    local targets = require("ue.targets")
    local ids = { Android = "android", Win64 = "win64", Mac = "mac", Linux = "linux", IOS = "ios" }
    for target, id in pairs(ids) do
      local attach = p.attach_handler(id)
      local launch = p.launch_handler(id)
      t.assert_eq(type(attach) == "function", targets.supports(target, "dap_attach", host_driver))
      t.assert_eq(type(launch) == "function", targets.supports(target, "dap_launch", host_driver))
    end
  end)

  t.it("重复注册会移除 foreign host 的陈旧 built-in handler", function()
    local p = require("ue.dap.platforms")
    local ue = require("ue")
    p._reset_for_test()
    p.register_supported(require("utils.platform.windows"), ue)
    t.assert_type(p.attach_handler("android"), "function")
    t.assert_type(p.attach_handler("win64"), "function")

    p.register_supported(require("utils.platform.macos"), ue)
    t.assert_nil(p.attach_handler("android"))
    t.assert_nil(p.attach_handler("win64"))
    t.assert_type(p.attach_handler("mac"), "function")
    t.assert_type(p.attach_handler("ios"), "function")
  end)

  t.it("_common.find_lldb_dap 返回 string 或 nil", function()
    local r = require("ue.dap._common").find_lldb_dap()
    t.assert_true(r == nil or type(r) == "string",
      "find_lldb_dap 返回了 " .. type(r))
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- Android 纯函数 seam 行为测（激活已抽出但未驱动的 _for_test）。
-- 这些把 CONSTRAINTS §二 的 hard-won 坑（K30/K34/K35/K37 + C1）从源码 grep
-- 升级成行为断言：输入 ctx/session → 输出决策，纯逻辑、无设备、headless 可跑。
-- 用 tmpdir 构造 cook 产物布局 + cfg.setup/reset_for_test 注入 override。
-- ════════════════════════════════════════════════════════════════════════

local function tmpdir()
  local d = vim.fn.tempname():gsub("\\", "/")
  vim.fn.mkdir(d, "p")
  return d
end

local function touch(path, content)
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "wb")
  if f then f:write(content or "x"); f:close() end
end

t.describe("ue.dap.android: pick_symbol_lib（K35 + 3.4 假线索防护）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("项目目录和符号包发现不固定 Client 项目名", function()
    local source = table.concat(vim.fn.readfile(
      vim.fn.stdpath("config") .. "/lua/ue/dap/android.lua"), "\n")
    t.assert_false(source:find("Source/SampleGame", 1, true) ~= nil)
    t.assert_false(source:find("Client_Symbols", 1, true) ~= nil)
    t.assert_false(source:find("SampleGame-arm64", 1, true) ~= nil)
  end)

  t.it("K35: 优先用 packageInfo versionCode 精确匹配的 symbol lib", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/SampleGame"
    local android_dir = proot .. "/Binaries/Android"
    -- cook 产物：packageInfo.txt 第二行 versionCode = 169723198
    touch(android_dir .. "/packageInfo.txt", "com.example.game\n169723198\n1.0.0\n")
    -- 精确匹配的符号包 + 一个更新但版本不符的干扰包
    local exact = android_dir .. "/SampleGame_Symbols_v169723198/SampleGame-arm64/libUE4.so"
    local decoy = android_dir .. "/SampleGame_Symbols_v999999999/SampleGame-arm64/libUE4.so"
    touch(exact, "EXACT")
    touch(decoy, "DECOY-NEWER")

    local picked = android._pick_symbol_lib_for_test({ project_root = proot })
    t.assert_eq(picked and picked:gsub("\\", "/"), exact,
      "应取 versionCode 精确匹配，而非按 mtime 取最新（避免符号≠APK）")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)

  t.it("无精确匹配时按 mtime 取最新符号包（best-guess 回落）", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/SampleGame"
    local android_dir = proot .. "/Binaries/Android"
    touch(android_dir .. "/packageInfo.txt", "com.example.game\n111\n1.0.0\n")
    -- 没有 v111 的精确包，只有两个 *Symbols* 包
    local older = android_dir .. "/A_Symbols/SampleGame-arm64/libUE4.so"
    local newer = android_dir .. "/B_Symbols/SampleGame-arm64/libUE4.so"
    touch(older, "OLD")
    touch(newer, "NEW")
    -- 把 newer 的 mtime 推后，确保它"最新"
    local ok_uv = vim.uv or vim.loop
    pcall(ok_uv.fs_utime, newer, os.time() + 100, os.time() + 100)

    local picked = android._pick_symbol_lib_for_test({ project_root = proot })
    t.assert_true(picked ~= nil, "应回落到 glob best-guess")
    t.assert_eq(picked and picked:gsub("\\", "/"), newer, "无精确匹配应取 mtime 最新")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)

  t.it("ctx.android_symbol_lib 显式覆盖最优先（reattach/agent 路径不 prompt）", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local explicit = d .. "/host/libUE4.so"
    touch(explicit, "HOST-DWARF")
    local picked = android._pick_symbol_lib_for_test({ android_symbol_lib = explicit })
    t.assert_eq(picked and picked:gsub("\\", "/"), explicit:gsub("\\", "/"))
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)

  t.it("config.dap.android_symbol_lib 覆盖（次于 ctx，先于自动发现）", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local cfg_lib = d .. "/cfg/libUE4.so"
    touch(cfg_lib, "CFG")
    cfg.setup({ dap = { android_symbol_lib = cfg_lib } })
    local picked = android._pick_symbol_lib_for_test({})
    t.assert_eq(picked and picked:gsub("\\", "/"), cfg_lib:gsub("\\", "/"))
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)
end)

t.describe("ue.dap.android: pick_package（K-package 单一真相 packageInfo.txt）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("ctx.android_package 显式值最优先", function()
    cfg.reset_for_test()
    t.assert_eq(android._pick_package_for_test({ android_package = "com.x.explicit" }),
      "com.x.explicit")
    cfg.reset_for_test()
  end)

  t.it("config.dap.android_package 覆盖（无 ctx 值时）", function()
    cfg.reset_for_test()
    cfg.setup({ dap = { android_package = "com.x.cfg" } })
    t.assert_eq(android._pick_package_for_test({}), "com.x.cfg")
    cfg.reset_for_test()
  end)

  t.it("从 packageInfo.txt 第一行解析 package 名", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/SampleGame"
    touch(proot .. "/Binaries/Android/packageInfo.txt",
      "com.example.game\n123\n3.4.0\n")
    t.assert_eq(android._pick_package_for_test({ project_root = proot }),
      "com.example.game")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)

  t.it("从任意项目名的 Source/<Project> nested layout 解析 package", function()
    cfg.reset_for_test()
    local root = tmpdir() .. "/Workspace"
    local project_dir = root .. "/Source/SampleGame"
    touch(project_dir .. "/SampleGame.uproject", "{}")
    touch(project_dir .. "/Binaries/Android/packageInfo.txt",
      "com.example.samplegame\n456\n1.0.0\n")
    t.assert_eq(android._pick_package_for_test({ project_root = root }),
      "com.example.samplegame")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(root, ":h"), "rf")
  end)
end)

t.describe("ue.dap.android: pick_lldb_server（C1 平台优先级，不自行重排）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("按 globs 给定顺序取第一个存在的文件（不按 mtime/字典序重排）", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local first  = d .. "/ndk27/lldb-server"
    local second = d .. "/ndk25/lldb-server"
    touch(first, "NDK27")
    touch(second, "NDK25")
    -- globs 顺序 = 平台 driver 的优先级；first 在前应被选中即便 second 也存在
    local picked = android._pick_lldb_server_for_test({ first, second })
    t.assert_eq(picked and picked:gsub("\\", "/"), first:gsub("\\", "/"),
      "必须保留 globs 优先级顺序，不得收集后排序")
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)

  t.it("config.dap.android_lldb_server 覆盖优先于 globs", function()
    cfg.reset_for_test()
    local d = tmpdir()
    local override = d .. "/custom/lldb-server"
    local glob_hit = d .. "/auto/lldb-server"
    touch(override, "X")
    touch(glob_hit, "Y")
    cfg.setup({ dap = { android_lldb_server = override } })
    local picked = android._pick_lldb_server_for_test({ glob_hit })
    t.assert_eq(picked and picked:gsub("\\", "/"), override:gsub("\\", "/"))
    cfg.reset_for_test()
    pcall(vim.fn.delete, d, "rf")
  end)

  t.it("无任何命中 → nil（调用方据此 prompt）", function()
    cfg.reset_for_test()
    t.assert_nil(android._pick_lldb_server_for_test({ "/nonexistent_zzz/lldb-server" }))
    cfg.reset_for_test()
  end)
end)

t.describe("ue.dap.android: effective_project_root（含 android marker 优先）", function()
  local android = require("ue.dap.android")
  local cfg = require("ue.config")

  t.it("优先返回带 Android marker 的候选根", function()
    cfg.reset_for_test()
    local proot = tmpdir() .. "/Project/Source/SampleGame"
    touch(proot .. "/Binaries/Android/packageInfo.txt", "com.x\n1\n1.0\n")
    local got = android._effective_project_root_for_test({ project_root = proot })
    t.assert_eq(got and got:gsub("\\", "/"), proot:gsub("\\", "/"),
      "带 Android marker 的根应优先于无 marker 的祖先")
    cfg.reset_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(proot, ":h:h:h"), "rf")
  end)
end)

t.describe("ue.dap.android: attach_commands（K30/K34/K37 顺序与 slide 开关）", function()
  local android = require("ue.dap.android")

  local function base_session()
    return {
      symbol_lib = "D:/symbols/SampleGame_Symbols_v1/SampleGame-arm64/libUE4.so",
      serial = "ANDROID-SERIAL-A",
      port = 5039,
      pid = 1234,
      _module_rebase_cmd =
        'target modules load --file "libUE4.so" --slide 0x6c9fe21000',
    }
  end

  local function index_of(cmds, pred)
    for i, c in ipairs(cmds) do if pred(c) then return i end end
    return nil
  end

  t.it("K34: symbol-rich `target create` 必须是第一条命令", function()
    local cmds = android._attach_commands_for_test(base_session())
    t.assert_true(cmds[1]:find('target create', 1, true) ~= nil,
      "首条必须 target create symbol-rich libUE4.so（DWARF 来源）")
    t.assert_true(cmds[1]:find("libUE4.so", 1, true) ~= nil)
  end)

  t.it("K34: target create 早于 platform connect / process attach", function()
    local cmds = android._attach_commands_for_test(base_session())
    local create_i = index_of(cmds, function(c) return c:find("target create", 1, true) end)
    local connect_i = index_of(cmds, function(c) return c:find("platform connect", 1, true) end)
    local attach_i = index_of(cmds, function(c) return c:find("process attach", 1, true) end)
    t.assert_true(create_i and connect_i and attach_i, "三条命令都应存在")
    t.assert_true(create_i < connect_i and connect_i < attach_i,
      "顺序必须 target create → platform connect → process attach")
  end)

  t.it("K30: connect URL 是 serial 方括号形式 connect://[<serial>]:<port>", function()
    local cmds = android._attach_commands_for_test(base_session())
    local connect = cmds[index_of(cmds, function(c) return c:find("platform connect", 1, true) end)]
    t.assert_eq(connect, "platform connect connect://[ANDROID-SERIAL-A]:5039",
      "必须 serial 方括号形式，禁 localhost（K30/K32）")
    -- 反向守护：不得出现 localhost/127.0.0.1 形式
    t.assert_true(connect:find("localhost", 1, true) == nil)
    t.assert_true(connect:find("127.0.0.1", 1, true) == nil)
  end)

  t.it("K30: 信号处置 SIGSEGV/SIGBUS/SIGPIPE 在 attach 后下发", function()
    local cmds = android._attach_commands_for_test(base_session())
    local attach_i = index_of(cmds, function(c) return c:find("process attach", 1, true) end)
    local seg_i = index_of(cmds, function(c) return c:find("SIGSEGV", 1, true) end)
    t.assert_true(seg_i and attach_i and seg_i > attach_i,
      "信号处置必须在 process attach 之后")
  end)

  t.it("K37: 默认下发显式 ASLR slide（_module_rebase_cmd 在末尾）", function()
    local cmds = android._attach_commands_for_test(base_session())
    local slide = cmds[#cmds]
    t.assert_true(slide:find("target modules load", 1, true) ~= nil
      and slide:find("--slide 0x", 1, true) ~= nil,
      "默认应包含显式 slide（K37 load-bearing）")
  end)

  t.it("K37: UE_DAP_NO_SLIDE=1 时跳过显式 slide（reverify 开关）", function()
    local saved = vim.env.UE_DAP_NO_SLIDE
    vim.env.UE_DAP_NO_SLIDE = "1"
    local cmds = android._attach_commands_for_test(base_session())
    local has_slide = index_of(cmds, function(c) return c:find("--slide 0x", 1, true) end)
    t.assert_nil(has_slide, "UE_DAP_NO_SLIDE=1 应跳过显式 slide 命令")
    vim.env.UE_DAP_NO_SLIDE = saved or ""
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- lldb-server 推送与 chmod EPERM 残留（2026-07-24 真机日志：root-owned
-- /data/local/tmp/lldb-server 让 shell 用户 chmod EPERM，但文件已 0755 可复用；
-- 尺寸不匹配时必须先 rm -f 再 push）。纯决策函数，不碰设备。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.android: lldb_server_stage_plan（chmod EPERM 残留）", function()
  local android = require("ue.dap.android")

  t.it("同尺寸 + 已可执行 → reuse（root-owned 残留直接复用，不再 chmod）", function()
    t.assert_eq(android._lldb_server_stage_plan_for_test(true, true), "reuse")
  end)

  t.it("同尺寸 + 不可执行 → chmod（只补权限，不重推）", function()
    t.assert_eq(android._lldb_server_stage_plan_for_test(true, false), "chmod")
  end)

  t.it("尺寸不匹配 → repush（rm -f 残留后 push + chmod）", function()
    t.assert_eq(android._lldb_server_stage_plan_for_test(false, false), "repush")
    t.assert_eq(android._lldb_server_stage_plan_for_test(false, true), "repush")
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- /proc/<pid>/maps 解析（K2/K11/K4：首个映射段 start 地址，纯字符串抽取，
-- 严禁 string.format("%x") — LuaJIT 截 32 位）。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.android: parse_maps_base_hex（K2/K11/K4）", function()
  local android = require("ue.dap.android")
  local maps = table.concat({
    "70b4c2a000-70b4c2b000 r--p 00000000 fe:00 123 /system/lib64/libc.so",
    "6c9fe21000-6ca1e21000 r--p 00000000 fe:21 456 /data/app/x/lib/arm64/libUE4.so",
    "6ca1e21000-6ce1e21000 r-xp 02000000 fe:21 456 /data/app/x/lib/arm64/libUE4.so",
  }, "\n")

  t.it("取第一段映射的 start（64 位 hex 字符串原样保留）", function()
    t.assert_eq(android._parse_maps_base_hex_for_test(maps, "libUE4.so"), "6c9fe21000")
  end)

  t.it("找不到目标 so → nil；空输入 → nil", function()
    t.assert_nil(android._parse_maps_base_hex_for_test(maps, "libFoo.so"))
    t.assert_nil(android._parse_maps_base_hex_for_test("", "libUE4.so"))
    t.assert_nil(android._parse_maps_base_hex_for_test(nil, "libUE4.so"))
  end)

  t.it("basename 里的 '.' 不当作通配符（libUE4Xso 不得匹配）", function()
    local trap = "6c9fe21000-6ca1e21000 r--p 00000000 fe:21 456 /data/app/x/libUE4Xso"
    t.assert_nil(android._parse_maps_base_hex_for_test(trap, "libUE4.so"))
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- wait-for-debugger launch（Android Studio debug 按钮语义）：
-- set-debug-app -w → start → clear-debug-app 的命令形状 + jdb 释放 JDWP 闸门。
-- 纯命令构造，不碰设备。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap.android: wait-for-debugger launch 命令形状", function()
  local android = require("ue.dap.android")

  t.it("set-debug-app 必须带 -w（不带 -w 不会等待调试器）", function()
    local steps = android._wait_launch_device_steps_for_test("com.example.game")
    t.assert_eq(table.concat(steps.set_wait, " "),
      "shell am set-debug-app -w com.example.game")
  end)

  t.it("包含 force-stop / start / clear-debug-app 全部步骤", function()
    local steps = android._wait_launch_device_steps_for_test("com.x")
    t.assert_eq(table.concat(steps.force_stop, " "), "shell am force-stop com.x")
    t.assert_true(table.concat(steps.start, " "):find("monkey %-p com%.x") ~= nil,
      "start 应经 monkey LAUNCHER intent")
    t.assert_eq(table.concat(steps.clear_wait, " "), "shell am clear-debug-app",
      "必须有 clear-debug-app，否则 debug-app 闸门粘住后续手动启动")
  end)

  t.it("jdb 连接串是 SocketAttach localhost:<port>", function()
    local argv = android._jdb_connect_argv_for_test("C:/jdk/bin/jdb.exe", 8712)
    t.assert_eq(argv[1], "C:/jdk/bin/jdb.exe")
    t.assert_eq(argv[2], "-connect")
    t.assert_eq(argv[3], "com.sun.jdi.SocketAttach:hostname=localhost,port=8712")
  end)
end)

-- ════════════════════════════════════════════════════════════════════════
-- F9 断点持久化往返（K10）。mock dap.breakpoints，纯 JSON + 路径归一化逻辑，
-- 不需要真实调试会话。
-- ════════════════════════════════════════════════════════════════════════
t.describe("ue.dap._persist_bp: F9 持久化往返（K10）", function()
  local bp = require("ue.dap._persist_bp")

  t.it("JSON 编解码往返保形（version/project/breakpoints）", function()
    bp._reset_state_for_test()
    local path = tmpdir() .. "/bp.json"
    local data = {
      version = 1, project = "MyGame",
      breakpoints = {
        ["D:/proj/Source/X.cpp"] = { { line = 42 }, { line = 57, condition = "i==3" } },
      },
    }
    local back = bp._json_round_trip_for_test(path, data)
    t.assert_true(back ~= nil, "应能读回")
    t.assert_eq(back.version, 1)
    t.assert_eq(back.project, "MyGame")
    t.assert_eq(#back.breakpoints["D:/proj/Source/X.cpp"], 2)
    t.assert_eq(back.breakpoints["D:/proj/Source/X.cpp"][2].condition, "i==3")
    bp._reset_state_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(path, ":h"), "rf")
  end)

  t.it("路径键归一化：反斜杠/正斜杠归一为同一键", function()
    bp._reset_state_for_test()
    t.assert_eq(bp._norm_for_test("D:\\proj\\Source\\X.cpp"),
                bp._norm_for_test("D:/proj/Source/X.cpp"),
      "Windows/Bash 分隔符必须归一，避免 K10 同文件 mis-match")
    bp._reset_state_for_test()
  end)

  t.it("project_name sanitize：非法文件名字符替换为 _", function()
    t.assert_eq(bp._project_name_for_test("E:/workspace/SampleGame.uproject", nil), "SampleGame",
      "uproject 取 basename 去 .uproject 后缀")
    t.assert_eq(bp._project_name_for_test(nil, "E:/Projects/My Game"), "My_Game",
      "空格等非法字符替换为 _")
    t.assert_eq(bp._project_name_for_test(nil, nil), "default",
      "无 uproject/project_root 回落 default")
  end)

  t.it("K10: save 合并 pending_paths，未开文件的断点不被擦除", function()
    bp._reset_state_for_test()
    -- mock dap.breakpoints：当前只有一个已开 buffer 的断点
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_name(buf, "D:/proj/Source/Opened.cpp")
    local opened_key = bp._norm_for_test(vim.api.nvim_buf_get_name(buf))
    local old = package.loaded["dap.breakpoints"]
    package.loaded["dap.breakpoints"] = {
      get = function() return { [buf] = { { line = 10 } } } end,
    }

    local path = tmpdir() .. "/bp.json"
    -- pending_paths 含一个"未开文件"的断点，save 必须保留它
    local back = bp._save_with_state_for_test(path, {
      ["D:/proj/Source/Unopened.cpp"] = { { line = 99 } },
    })
    package.loaded["dap.breakpoints"] = old
    pcall(vim.api.nvim_buf_delete, buf, { force = true })

    t.assert_true(back ~= nil, "save 后应能读回")
    t.assert_true(back.breakpoints[opened_key] ~= nil,
      "已开文件的断点应被写入")
    t.assert_true(back.breakpoints["D:/proj/Source/Unopened.cpp"] ~= nil,
      "未开文件的 pending 断点必须保留（K10 灾难场景守护）")
    t.assert_eq(back.breakpoints["D:/proj/Source/Unopened.cpp"][1].line, 99)
    bp._reset_state_for_test()
    pcall(vim.fn.delete, vim.fn.fnamemodify(path, ":h"), "rf")
  end)
end)
