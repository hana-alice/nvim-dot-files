local t = require("tests.harness")
t.bootstrap()

local function write_json_from_argv(argv, payload)
  for index, value in ipairs(argv) do
    if value == "--json-output" then
      local path = argv[index + 1]
      vim.fn.writefile({ vim.json.encode(payload) }, path)
      return path
    end
  end
  error("missing --json-output")
end

local function coredevice_runtime()
  return {
    binary = "/Project/Binaries/IOS/SampleGame",
    bundle_id = "com.example.sample",
    cwd = "/Project",
    device_id = "APPLE-UDID",
    dsym = "/Project/Binaries/IOS/SampleGame.dSYM",
    tools = { xcrun = "/usr/bin/xcrun" },
  }
end

local function bootstrap_system(calls)
  return function(argv, _, callback)
    calls[#calls + 1] = vim.deepcopy(argv)
    if vim.list_contains(argv, "dwarfdump") then
      callback({
        code = 0,
        stdout = vim.list_contains(argv, "--uuid") and "UUID: 322CB148-C401-3EA0-A023-4B21A104D42F (arm64) artifact"
          or "",
        stderr = "",
      })
      return
    end
    local payload
    if vim.list_contains(argv, "apps") then
      payload = {
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          apps = {
            { bundleIdentifier = "com.example.sample", url = "file:///private/SampleGame.app" },
          },
        },
      }
    elseif vim.list_contains(argv, "launch") then
      payload = {
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          process = {
            executable = "file:///private/SampleGame.app/SampleGame",
            processIdentifier = 991,
          },
        },
      }
    else
      payload = {
        result = {
          deviceIdentifier = "CORE-DEVICE-1",
          runningProcesses = {
            { executable = "file:///private/SampleGame.app/SampleGame", processIdentifier = 991 },
          },
        },
      }
    end
    write_json_from_argv(argv, payload)
    callback({ code = 0, stdout = "", stderr = "" })
  end
end

t.describe("ue.dap iOS CoreDevice runtime", function()
  t.it("freezes explicit CoreDevice inputs without requiring legacy tools", function()
    local root = vim.fn.tempname() .. "-ios-runtime"
    local binary = root .. "/Binaries/IOS/SampleGame"
    local dsym = binary .. ".dSYM"
    local source = root .. "/Source/SampleGame.cpp"
    vim.fn.mkdir(dsym, "p")
    vim.fn.mkdir(vim.fs.dirname(source), "p")
    vim.fn.writefile({ "binary" }, binary)
    vim.fn.writefile({ "int sample = 1;" }, source)

    local roots = { project = root }
    local runtime, err = require("ue.dap._ios_runtime").resolve({
      device_backend = "coredevice",
      device_id = "DEVICE-1",
      bundle_id = "com.example.sample",
      binary = binary,
      dsym = dsym,
      source = source,
      source_roots = roots,
      xcrun = vim.fn.exepath("true"),
    })

    t.assert_nil(err)
    t.assert_eq(runtime.backend, "coredevice")
    t.assert_eq(runtime.device_id, "DEVICE-1")
    t.assert_eq(runtime.bundle_id, "com.example.sample")
    t.assert_eq(runtime.source, vim.fs.normalize(source))
    t.assert_type(runtime.tools.xcrun, "string")
    t.assert_nil(runtime.tools.ios_deploy)
    roots.project = "/changed-after-freeze"
    t.assert_eq(runtime.source_roots.project, root)
    vim.fn.delete(root, "rf")
  end)

  t.it("debug launch captures and revalidates the start-stopped PID before DAP", function()
    local calls = {}
    local captured
    local failure
    require("ue.dap._ios_coredevice").prepare("launch", coredevice_runtime(), {
      fail = function(message)
        failure = message
      end,
      init_commands = { "settings set stop-disassembly-display never" },
      progress = function() end,
      run = function(runtime, config)
        captured = { runtime = runtime, config = config }
        return true
      end,
      system_async = bootstrap_system(calls),
    })

    t.assert_nil(failure)
    t.assert_eq(captured.runtime.coredevice_id, "CORE-DEVICE-1")
    t.assert_eq(captured.runtime.pid, 991)
    t.assert_true(captured.runtime._ue_coredevice_owns_process)
    t.assert_eq(captured.config._ue_session_operation, "launch")
    local launch
    for _, argv in ipairs(calls) do
      if vim.list_contains(argv, "launch") then
        launch = table.concat(argv, " ")
      end
    end
    t.assert_type(launch, "string")
    t.assert_contains(launch, "--terminate-existing")
    t.assert_contains(launch, "--start-stopped")
    t.assert_contains(launch, "com.example.sample")
  end)

  t.it("ordinary attach selects the unique current app process without launching", function()
    local calls = {}
    local captured
    local runtime = coredevice_runtime()
    require("ue.dap._ios_coredevice").prepare("attach", runtime, {
      fail = function(message)
        error(message)
      end,
      init_commands = {},
      progress = function() end,
      run = function(frozen, config)
        captured = { runtime = frozen, config = config }
        return true
      end,
      system_async = bootstrap_system(calls),
    })

    t.assert_eq(captured.runtime.pid, 991)
    t.assert_false(captured.runtime._ue_coredevice_owns_process)
    t.assert_eq(captured.config._ue_session_operation, "attach")
    for _, argv in ipairs(calls) do
      t.assert_false(vim.list_contains(argv, "launch"))
    end
  end)

  t.it("ordinary attach failure never terminates the existing app process", function()
    local calls = {}
    local failure
    require("ue.dap._ios_coredevice").prepare("attach", coredevice_runtime(), {
      fail = function(message)
        failure = message
      end,
      init_commands = {},
      progress = function() end,
      run = function()
        return false
      end,
      system_async = bootstrap_system(calls),
    })

    t.assert_contains(failure, "failed to start Apple lldb-dap")
    for _, argv in ipairs(calls) do
      t.assert_false(vim.list_contains(argv, "terminate"))
    end
  end)

  t.it("rejects malformed DWARF before creating a launch-owned process", function()
    local calls = {}
    local base = bootstrap_system(calls)
    local failure
    require("ue.dap._ios_coredevice").prepare("launch", coredevice_runtime(), {
      fail = function(message)
        failure = message
      end,
      init_commands = {},
      progress = function() end,
      run = function()
        error("DAP must not run after failed DWARF verification")
      end,
      system_async = function(argv, opts, callback)
        if vim.list_contains(argv, "--verify") then
          calls[#calls + 1] = vim.deepcopy(argv)
          callback({ code = 1, stdout = "", stderr = "invalid abbreviation set" })
        else
          base(argv, opts, callback)
        end
      end,
    })

    t.assert_contains(failure, "failed DWARF verification")
    for _, argv in ipairs(calls) do
      t.assert_false(vim.list_contains(argv, "launch"))
    end
  end)

  t.it("terminates one frozen PID once and verifies absence idempotently", function()
    local CoreDevice = require("ue.dap._ios_coredevice")
    local runtime = {
      _ue_coredevice_owns_process = true,
      app = { app_url = "file:///private/SampleGame.app" },
      coredevice_id = "DEVICE-1",
      pid = 991,
      tools = { xcrun = "/usr/bin/xcrun" },
    }
    local calls = { info = 0, terminate = 0, outputs = {} }
    local function system_async(argv, _, callback)
      local is_terminate = vim.list_contains(argv, "terminate")
      if is_terminate then
        calls.terminate = calls.terminate + 1
      else
        calls.info = calls.info + 1
      end
      local processes = calls.terminate == 0
          and {
            {
              executable = "file:///private/SampleGame.app/SampleGame",
              processIdentifier = 991,
            },
          }
        or {}
      local path = write_json_from_argv(argv, {
        result = {
          deviceIdentifier = "DEVICE-1",
          runningProcesses = processes,
        },
      })
      calls.outputs[#calls.outputs + 1] = path
      callback({ code = 0, stdout = "", stderr = "" })
    end

    local results = {}
    CoreDevice.stop(runtime, { system_async = system_async }, function(ok, err)
      results[#results + 1] = { ok = ok, err = err }
    end)
    CoreDevice.stop(runtime, { system_async = system_async }, function(ok, err)
      results[#results + 1] = { ok = ok, err = err }
    end)

    t.assert_eq(calls.info, 2)
    t.assert_eq(calls.terminate, 1)
    t.assert_eq(#results, 2)
    t.assert_true(results[1].ok)
    t.assert_true(results[2].ok)
    for _, path in ipairs(calls.outputs) do
      t.assert_eq(vim.fn.filereadable(path), 0)
    end
  end)

  t.it("ordinary attach cleanup verifies and preserves the existing app process", function()
    local CoreDevice = require("ue.dap._ios_coredevice")
    local runtime = {
      _ue_coredevice_owns_process = false,
      app = { app_url = "file:///private/SampleGame.app" },
      coredevice_id = "DEVICE-1",
      pid = 991,
      tools = { xcrun = "/usr/bin/xcrun" },
    }
    local info_calls = 0
    local terminate_calls = 0
    local function system_async(argv, _, callback)
      if vim.list_contains(argv, "terminate") then
        terminate_calls = terminate_calls + 1
      else
        info_calls = info_calls + 1
      end
      write_json_from_argv(argv, {
        result = {
          deviceIdentifier = "DEVICE-1",
          runningProcesses = {
            { executable = "file:///private/SampleGame.app/SampleGame", processIdentifier = 991 },
          },
        },
      })
      callback({ code = 0, stdout = "", stderr = "" })
    end

    local results = {}
    CoreDevice.stop(runtime, { system_async = system_async }, function(ok, err)
      results[#results + 1] = { ok = ok, err = err }
    end)
    CoreDevice.stop(runtime, { system_async = system_async }, function(ok, err)
      results[#results + 1] = { ok = ok, err = err }
    end)

    t.assert_eq(info_calls, 1)
    t.assert_eq(terminate_calls, 0)
    t.assert_eq(#results, 2)
    t.assert_true(results[1].ok)
    t.assert_true(results[2].ok)
  end)

  t.it("does not terminate a reused PID owned by another app", function()
    local CoreDevice = require("ue.dap._ios_coredevice")
    local runtime = {
      _ue_coredevice_owns_process = true,
      app = { app_url = "file:///private/SampleGame.app" },
      coredevice_id = "DEVICE-1",
      pid = 991,
      tools = { xcrun = "/usr/bin/xcrun" },
    }
    local terminate_calls = 0
    local function system_async(argv, _, callback)
      if vim.list_contains(argv, "terminate") then
        terminate_calls = terminate_calls + 1
      end
      write_json_from_argv(argv, {
        result = {
          deviceIdentifier = "DEVICE-1",
          runningProcesses = {
            { executable = "file:///private/Other.app/Other", processIdentifier = 991 },
          },
        },
      })
      callback({ code = 0, stdout = "", stderr = "" })
    end

    local stopped
    CoreDevice.stop(runtime, { system_async = system_async }, function(ok)
      stopped = ok
    end)
    t.assert_true(stopped)
    t.assert_eq(terminate_calls, 0)
  end)

  t.it("shares one in-flight cleanup and reports a devicectl timeout without terminating", function()
    local CoreDevice = require("ue.dap._ios_coredevice")
    local runtime = {
      _ue_coredevice_owns_process = true,
      app = { app_url = "file:///private/SampleGame.app" },
      coredevice_id = "DEVICE-1",
      pid = 991,
      tools = { xcrun = "/usr/bin/xcrun" },
    }
    local pending
    local query_calls = 0
    local terminate_calls = 0
    local function system_async(argv, _, callback)
      if vim.list_contains(argv, "terminate") then
        terminate_calls = terminate_calls + 1
      else
        query_calls = query_calls + 1
      end
      pending = callback
    end

    local results = {}
    CoreDevice.stop(runtime, { system_async = system_async }, function(ok, err)
      results[#results + 1] = { ok = ok, err = err }
    end)
    CoreDevice.stop(runtime, { system_async = system_async }, function(ok, err)
      results[#results + 1] = { ok = ok, err = err }
    end)

    t.assert_eq(query_calls, 1)
    t.assert_eq(terminate_calls, 0)
    t.assert_eq(#results, 0)
    pending({ code = 124, stdout = "", stderr = "operation timed out" })
    t.assert_eq(#results, 2)
    t.assert_false(results[1].ok)
    t.assert_contains(results[1].err, "operation timed out")
    t.assert_eq(results[1].err, results[2].err)
    t.assert_eq(terminate_calls, 0)
  end)

  t.it("allows a late UUID marker but bounds missing-marker disconnect cleanup", function()
    local C = require("ue.dap._common")
    local original_require_dap = C.require_dap
    local active
    local disconnects = 0
    local cleanups = 0
    local dap = {
      listeners = {
        after = { disconnect = {}, event_initialized = {}, event_output = {}, event_stopped = {}, setBreakpoints = {} },
        before = { event_exited = {}, event_terminated = {} },
      },
      disconnect = function()
        disconnects = disconnects + 1
      end,
      session = function()
        return active
      end,
    }
    C.require_dap = function()
      return dap
    end
    package.loaded["ue.dap._ios_session"] = nil
    local IOSSession = require("ue.dap._ios_session")
    IOSSession.install({
      cleanup_fallback_ms = 5,
      notify = function() end,
      on_unexpected_end = function()
        cleanups = cleanups + 1
      end,
      progress = function() end,
      uuid_marker_grace_ms = 10,
    })
    local listeners = dap.listeners.after
    local key = "ue_ios_lifecycle"

    active = {
      config = { _ue_session_owner = "ios", _ue_ios_session_owner = "coredevice", _ue_ios_backend = "coredevice" },
    }
    listeners.event_initialized[key](active)
    listeners.setBreakpoints[key](active, nil, {
      breakpoints = { { verified = true } },
    }, { arguments = { source = { path = "/Project/Game.cpp" } } })
    listeners.event_output[key](active, { output = "__UE_IOS_LOADED_UUID_OK__\n" })
    vim.wait(25)
    t.assert_true(active._ue_ios_loaded_uuid_verified)
    t.assert_true(active._ue_ios_has_verified_breakpoint)
    t.assert_eq(disconnects, 0)
    t.assert_eq(cleanups, 0)

    active = {
      config = { _ue_session_owner = "ios", _ue_ios_session_owner = "coredevice", _ue_ios_backend = "coredevice" },
    }
    listeners.event_initialized[key](active)
    vim.wait(50, function()
      return cleanups == 1
    end, 2)
    t.assert_eq(disconnects, 1)
    t.assert_eq(cleanups, 1)

    C.require_dap = original_require_dap
    package.loaded["ue.dap._ios_session"] = nil
  end)
end)
