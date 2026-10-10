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

local function assert_coredevice_attach_policy(captured, initial_commands)
  local config = captured.config
  local runtime = captured.runtime
  local expected_init = vim.deepcopy(initial_commands)
  expected_init[#expected_init + 1] = "settings set plugin.process.gdb-remote.packet-timeout 60"
  t.assert_true(vim.deep_equal(config.initCommands, expected_init), "packet timeout must be set before attach")
  t.assert_true(config.initCommands ~= initial_commands)
  t.assert_eq(config.request, "attach")
  t.assert_true(config.stopOnEntry)
  t.assert_eq(config._ue_device_id, runtime.coredevice_id)
  t.assert_eq(config._ue_process_id, runtime.pid)
  t.assert_true(
    vim.deep_equal(config.attachCommands, {
      'target create "' .. runtime.binary .. '"',
      'device select "' .. runtime.coredevice_id .. '"',
      "device process attach -p " .. runtime.pid,
      'target symbols add "' .. runtime.dsym .. '"',
    }),
    "attach must keep the frozen target and PID suspended"
  )
  t.assert_eq(config.postRunCommands[1], "process status")
  t.assert_contains(config.postRunCommands[2], runtime.expected_uuids[1])
  t.assert_contains(config.postRunCommands[2], "__UE_IOS_LOADED_UUID_OK__")
  t.assert_contains(config.postRunCommands[2], "__UE_IOS_LOADED_UUID_MISMATCH__")
end

local function with_ios_lifecycle(callback)
  local C = require("ue.dap._common")
  local Runtime = require("ue.dap._ios_runtime")
  local CoreDevice = require("ue.dap._ios_coredevice")
  local original = {
    resolve = Runtime.resolve,
    query_adapter = Runtime.query_adapter,
    prepare = CoreDevice.prepare,
    stop = CoreDevice.stop,
    run = C.run,
    require_dap = C.require_dap,
    defer_fn = vim.defer_fn,
    ios = package.loaded["ue.dap.ios"],
    session = package.loaded["ue.dap._ios_session"],
    ui = package.loaded["ue.dap"],
  }
  local state = { stopped = {}, deferred = {}, disconnects = 0, restores = 0 }
  local dap = {
    listeners = {
      after = { disconnect = {}, event_initialized = {}, event_output = {}, event_stopped = {}, setBreakpoints = {} },
      before = { event_exited = {}, event_terminated = {} },
      on_session = {},
    },
    session = function()
      return state.active
    end,
    disconnect = function(_, done)
      state.disconnects = state.disconnects + 1
      state.disconnect_done = done
    end,
  }
  Runtime.resolve = function()
    return { backend = "coredevice", device_id = "DEVICE-1" }
  end
  Runtime.query_adapter = function(_, _, done)
    done({})
  end
  CoreDevice.prepare = function(mode, runtime, deps)
    runtime._ue_coredevice_owns_process = mode == "launch"
    deps.run(runtime, {
      _ue_session_owner = "ios",
      _ue_ios_session_owner = "coredevice",
      _ue_ios_backend = "coredevice",
      _ue_session_operation = mode,
    })
  end
  CoreDevice.stop = function(runtime, _, done)
    if runtime._ue_coredevice_cleanup and runtime._ue_coredevice_cleanup.done then
      done(true)
      return
    end
    state.stopped[#state.stopped + 1] = runtime
    runtime._ue_coredevice_cleanup = { done = true }
    done(true)
  end
  C.run = function(config)
    local old_session = state.active
    state.active = { config = vim.deepcopy(config), on_close = {} }
    for _, on_session in pairs(dap.listeners.on_session) do
      on_session(old_session, state.active)
    end
    return true
  end
  C.require_dap = function()
    return dap
  end
  vim.defer_fn = function(fn)
    state.deferred[#state.deferred + 1] = fn
  end
  package.loaded["ue.dap.ios"] = nil
  package.loaded["ue.dap._ios_session"] = nil
  package.loaded["ue.dap"] = {
    _dap_restore_edit_layout = function()
      state.restores = state.restores + 1
    end,
  }
  local ok, err = xpcall(function()
    callback(require("ue.dap.ios"), dap, state)
  end, debug.traceback)
  Runtime.resolve = original.resolve
  Runtime.query_adapter = original.query_adapter
  CoreDevice.prepare = original.prepare
  CoreDevice.stop = original.stop
  C.run = original.run
  C.require_dap = original.require_dap
  vim.defer_fn = original.defer_fn
  package.loaded["ue.dap.ios"] = original.ios
  package.loaded["ue.dap._ios_session"] = original.session
  package.loaded["ue.dap"] = original.ui
  if not ok then
    error(err)
  end
end

t.describe("ue.dap iOS CoreDevice runtime", function()
  local function failed_prepare(mode, result)
    local runtime = coredevice_runtime()
    runtime.device_id = "DEVICE-MISSING"
    local calls = {}
    local failure
    require("ue.dap._ios_coredevice").prepare(mode, runtime, {
      fail = function(message)
        failure = message
      end,
      progress = function() end,
      run = function()
        error("DAP must not start when the frozen device lookup fails")
      end,
      system_async = function(argv, _, callback)
        calls[#calls + 1] = vim.deepcopy(argv)
        callback(result)
      end,
    })
    t.assert_type(failure, "string")
    t.assert_eq(#calls, 1)
    t.assert_contains(calls[1], "apps")
    t.assert_nil(runtime.pid)
    t.assert_nil(runtime.app)
    t.assert_nil(runtime._ue_coredevice_cleanup)
    return failure, calls[1]
  end

  t.it(
    "reports missing CoreDevice transport with command evidence and safe retry guidance before creating a PID",
    function()
      for _, mode in ipairs({ "launch", "attach" }) do
        for _, stderr in ipairs({
          "Unable to locate a device matching requested device identifier DEVICE-MISSING.",
          "Unable to locate a device matching the requested device identifier DEVICE-MISSING.",
          "Failed to locate device. (com.apple.dt.CoreDeviceError error 1011.)",
        }) do
          local message, argv =
            failed_prepare(mode, { code = 1, stdout = "Inventory query attempted", stderr = stderr })
          t.assert_match(message, "^%[L1 transport%] owner: dap%.ios%.coredevice")
          t.assert_contains(message, table.concat(argv, " "))
          t.assert_contains(message, "rc=1")
          t.assert_contains(message, "Inventory query attempted")
          t.assert_contains(message, stderr)
          t.assert_contains(message, "Reconnect")
          t.assert_contains(message, "unlock")
          t.assert_contains(message, "trust")
          t.assert_contains(message, ":UESetIOSDevice")
          t.assert_contains(message, "retry")
        end
      end
    end
  )

  t.it("keeps unclassified CoreDevice failures undetermined instead of guessing target policy", function()
    for _, stderr in ipairs({
      "A service returned permission denied without target-policy evidence.",
      "An unrelated failure. (com.apple.dt.CoreDeviceError error 10110.)",
    }) do
      local message, argv = failed_prepare("launch", {
        code = 2,
        stdout = "CoreDevice request submitted",
        stderr = stderr,
      })
      t.assert_match(message, "^%[L%? UNDETERMINED%] owner: dap%.ios%.coredevice")
      t.assert_contains(message, table.concat(argv, " "))
      t.assert_contains(message, "rc=2")
      t.assert_contains(message, "CoreDevice request submitted")
      t.assert_contains(message, stderr)
      t.assert_contains(message, "determine")
      t.assert_false(message:find("[L2", 1, true) ~= nil)
    end
  end)

  t.it(
    "restores the edit layout once and clears bootstrap state when iOS adapter lookup fails without a DAP session",
    function()
      with_ios_lifecycle(function(ios, _, state)
        require("ue.dap._ios_runtime").query_adapter = function(_, _, done)
          t.assert_true(ios._starting)
          done(nil, "The selected Apple adapter is unavailable")
        end
        ios.launch({})
        t.assert_false(ios._starting)
        t.assert_nil(ios._session)
        t.assert_nil(state.active)
        t.assert_eq(state.restores, 1)
        t.assert_eq(#state.stopped, 0)
        t.assert_eq(state.disconnects, 0)
      end)
    end
  )

  t.it("preserves another platform's active DAP layout when the iOS device bootstrap fails", function()
    with_ios_lifecycle(function(ios, _, state)
      local foreign = { config = { _ue_session_owner = "mac" }, on_close = {} }
      state.active = foreign
      require("ue.dap._ios_coredevice").prepare = function(_, _, deps)
        t.assert_true(ios._starting)
        deps.fail("The frozen CoreDevice route could not be resolved")
      end
      ios.launch({})
      t.assert_false(ios._starting)
      t.assert_nil(ios._session)
      t.assert_eq(state.active, foreign)
      t.assert_eq(state.restores, 0)
      t.assert_eq(#state.stopped, 0)
      t.assert_eq(state.disconnects, 0)
    end)
  end)

  t.it(
    "reports missing CoreDevice JSON as an undetermined result failure with the successful command evidence",
    function()
      local message, argv = failed_prepare("attach", { code = 0, stdout = "Query finished without JSON", stderr = "" })
      t.assert_match(message, "^%[L%? UNDETERMINED%] owner: dap%.ios%.coredevice")
      t.assert_contains(message, table.concat(argv, " "))
      t.assert_contains(message, "rc=0")
      t.assert_contains(message, "Query finished without JSON")
      t.assert_contains(message, "devicectl did not create its JSON result")
    end
  )

  t.it("cleans the owned iOS runtime after adapter EOF without protocol end events", function()
    with_ios_lifecycle(function(ios, _, state)
      ios.launch({})
      local session = state.active
      local runtime = ios._session
      session.closed = true
      for _, on_close in pairs(session.on_close) do
        on_close(session)
      end
      session.on_close = {}
      t.assert_eq(ios._session, runtime)
      t.assert_true(vim.wait(100, function()
        return ios._session == nil
      end, 2))
      t.assert_eq(state.stopped[1], runtime)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(state.disconnects, 0)
    end)
  end)

  t.it("ignores an old iOS close callback queued before a new session starts", function()
    with_ios_lifecycle(function(ios, dap, state)
      ios.launch({})
      local old_session = state.active
      t.assert_type(old_session.on_close.ue_ios_lifecycle, "function")
      old_session.on_close.ue_ios_lifecycle(old_session)
      dap.listeners.after.disconnect.ue_ios_lifecycle(old_session)
      ios.launch({})
      local new_runtime = ios._session
      vim.wait(10)
      t.assert_eq(ios._session, new_runtime)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(state.disconnects, 0)
    end)
  end)

  t.it("coalesces protocol cleanup and adapter close for the same iOS owner", function()
    with_ios_lifecycle(function(ios, dap, state)
      ios.attach({})
      local session = state.active
      local on_close = session.on_close.ue_ios_lifecycle
      t.assert_type(on_close, "function")
      dap.listeners.on_session.ue_ios_lifecycle(session, session)
      t.assert_eq(vim.tbl_count(session.on_close), 1)
      dap.listeners.after.disconnect.ue_ios_lifecycle(session)
      on_close(session)
      vim.wait(10)
      t.assert_nil(ios._session)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(state.disconnects, 0)
    end)
  end)

  t.it("leaves another platform's close hooks and active iOS owner untouched", function()
    with_ios_lifecycle(function(ios, dap, state)
      ios.attach({})
      local runtime = ios._session
      local foreign_close = function() end
      local foreign_session = { config = { _ue_session_owner = "android" }, on_close = { other = foreign_close } }
      t.assert_type(dap.listeners.on_session.ue_ios_lifecycle, "function")
      dap.listeners.on_session.ue_ios_lifecycle(state.active, foreign_session)
      t.assert_nil(foreign_session.on_close.ue_ios_lifecycle)
      t.assert_eq(foreign_session.on_close.other, foreign_close)
      vim.wait(10)
      t.assert_eq(ios._session, runtime)
      t.assert_eq(#state.stopped, 0)
      t.assert_eq(state.disconnects, 0)
    end)
  end)

  t.it("ignores an old owner's UUID fallback and exit events after a new debug launch", function()
    with_ios_lifecycle(function(ios, dap, state)
      local key = "ue_ios_lifecycle"
      ios.launch({})
      local old_session = state.active
      local old_runtime = ios._session
      dap.listeners.after.event_output[key](old_session, { output = "__UE_IOS_LOADED_UUID_MISMATCH__" })
      t.assert_true(vim.wait(100, function()
        return #state.deferred == 1
      end, 2))
      dap.listeners.after.disconnect[key](old_session)
      t.assert_eq(state.stopped[1], old_runtime)
      ios.launch({})
      local new_runtime = ios._session
      state.deferred[1]()
      dap.listeners.before.event_exited[key](old_session)
      dap.listeners.before.event_terminated[key](old_session)
      ios.cleanup({ session = old_session })
      t.assert_eq(ios._session, new_runtime)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(state.disconnects, 1)
      dap.listeners.after.disconnect[key](state.active)
      t.assert_eq(state.stopped[2], new_runtime)
    end)
  end)

  t.it("does not reuse another owner's cached cleanup for a stale session", function()
    with_ios_lifecycle(function(ios, dap, state)
      ios.attach({})
      local old_session = state.active
      dap.listeners.after.disconnect.ue_ios_lifecycle(old_session)
      ios.attach({})
      local new_session = state.active
      dap.listeners.after.disconnect.ue_ios_lifecycle(new_session)
      ios.cleanup({ session = old_session })
      t.assert_eq(#state.stopped, 2)
    end)
  end)

  t.it("rejects stale stop requests and never disconnects a different active DAP session", function()
    with_ios_lifecycle(function(ios, dap, state)
      ios.launch({})
      local old_session = state.active
      dap.listeners.after.disconnect.ue_ios_lifecycle(old_session)
      ios.launch({})
      local new_runtime = ios._session
      local stopped
      ios.stop({
        session = old_session,
        on_done = function(ok)
          stopped = ok
        end,
      })
      t.assert_false(stopped)
      t.assert_eq(ios._session, new_runtime)
      t.assert_eq(#state.stopped, 1)
      state.active = old_session
      ios.stop({})
      t.assert_eq(state.disconnects, 0)
      t.assert_eq(state.stopped[2], new_runtime)
    end)
  end)

  t.it("waits for the matching owner's disconnect cleanup before accepting another launch", function()
    with_ios_lifecycle(function(ios, _, state)
      ios.launch({})
      local runtime = ios._session
      ios.stop({})
      t.assert_eq(state.disconnects, 1)
      t.assert_true(ios._stopping)
      ios.launch({})
      t.assert_eq(ios._session, runtime)
      t.assert_eq(#state.stopped, 0)
      state.deferred[1]()
      t.assert_false(ios._stopping)
      t.assert_eq(state.stopped[1], runtime)
      ios.launch({})
      t.assert_true(ios._session ~= runtime)
    end)
  end)

  t.it("shares repeated stop requests and ignores their late finalizer after a new launch", function()
    with_ios_lifecycle(function(ios, _, state)
      ios.launch({})
      local completed = 0
      local opts = {
        on_done = function(ok)
          t.assert_true(ok)
          completed = completed + 1
        end,
      }
      ios.stop(opts)
      ios.stop(opts)
      t.assert_eq(state.disconnects, 1)
      t.assert_eq(#state.deferred, 1)
      state.deferred[1]()
      t.assert_eq(completed, 2)
      t.assert_eq(#state.stopped, 1)
      ios.launch({})
      local new_runtime = ios._session
      state.deferred[1]()
      state.disconnect_done()
      vim.wait(10)
      t.assert_eq(ios._session, new_runtime)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(completed, 2)
    end)
  end)

  t.it("freezes explicit CoreDevice inputs with real xcrun or fails closed without it", function()
    local root = vim.fn.tempname() .. "-ios-runtime"
    local binary = root .. "/Binaries/IOS/SampleGame"
    local dsym = binary .. ".dSYM"
    local source = root .. "/Source/SampleGame.cpp"
    vim.fn.mkdir(dsym, "p")
    vim.fn.mkdir(vim.fs.dirname(source), "p")
    vim.fn.writefile({ "binary" }, binary)
    vim.fn.writefile({ "int sample = 1;" }, source)

    local roots = { project = root }
    local xcrun = vim.fn.exepath("xcrun")
    local runtime, err = require("ue.dap._ios_runtime").resolve({
      device_backend = "coredevice",
      device_id = "DEVICE-1",
      bundle_id = "com.example.sample",
      binary = binary,
      dsym = dsym,
      source = source,
      source_roots = roots,
      xcrun = xcrun ~= "" and xcrun or nil,
    })

    if xcrun == "" then
      t.assert_nil(runtime)
      t.assert_contains(err, "xcrun is not installed or not executable")
      vim.fn.delete(root, "rf")
      return
    end

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
    local init_commands = { "settings set stop-disassembly-display never" }
    require("ue.dap._ios_coredevice").prepare("launch", coredevice_runtime(), {
      fail = function(message)
        failure = message
      end,
      init_commands = init_commands,
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
    t.assert_true(vim.deep_equal(init_commands, { "settings set stop-disassembly-display never" }))
    assert_coredevice_attach_policy(captured, init_commands)
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
    local init_commands = { "settings set auto-confirm true" }
    require("ue.dap._ios_coredevice").prepare("attach", runtime, {
      fail = function(message)
        error(message)
      end,
      init_commands = init_commands,
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
    t.assert_true(vim.deep_equal(init_commands, { "settings set auto-confirm true" }))
    assert_coredevice_attach_policy(captured, init_commands)
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
    local active = {
      config = { _ue_session_owner = "ios", _ue_ios_session_owner = "coredevice", _ue_ios_backend = "coredevice" },
      on_close = {},
    }
    local disconnects = 0
    local cleanups = 0
    local dap = {
      listeners = {
        after = { disconnect = {}, event_initialized = {}, event_output = {}, event_stopped = {}, setBreakpoints = {} },
        before = { event_exited = {}, event_terminated = {} },
        on_session = {},
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

    t.assert_type(active.on_close[key], "function")
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
