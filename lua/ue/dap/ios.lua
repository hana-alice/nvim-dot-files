-- ue.dap.ios — physical-device iOS DAP via CoreDevice or MobileDevice.
--
-- Independent from ue.dap.mac: pair the local symbol-rich Mach-O with the
-- installed executable, expose legacy debugserver through ios-deploy, then
-- RemoteLaunch(stop_at_entry=true) or RemoteAttachToProcessWithID via LLDB.
local C = require("ue.dap._common")
local CoreDevice = require("ue.dap._ios_coredevice")
local IOSProcess = require("ue.dap._ios_process")
local Runtime = require("ue.dap._ios_runtime")
local IOSSession = require("ue.dap._ios_session")
local Progress = require("ue.dap._progress")
local M = {
  _session = nil,
  _cleanup_runtime = nil,
  _starting = false,
  _stopping = false,
}
local INIT_COMMANDS = {
  "settings set stop-disassembly-display never",
  "settings set target.inline-breakpoint-strategy always",
  "settings set target.move-to-nearest-code true",
  "settings set target.process.stop-on-sharedlibrary-events false",
  -- Avoid downloading all remote images; local Client DWARF remains complete.
  "settings set target.memory-module-load-level partial",
}
local function trim(value)
  return vim.trim(tostring(value or ""))
end
local function notify(message, level)
  vim.notify("[ue.dap] " .. tostring(message), level or vim.log.levels.INFO)
end
local function progress(method, message)
  pcall(function()
    Progress[method](message)
  end)
end
local function lldb_quote(value)
  local escaped = tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. escaped .. '"'
end

local function python_string(value)
  return vim.json.encode(tostring(value or ""))
end

local function python_exec(source)
  return "script exec(" .. python_string(source) .. ")"
end

local function connect_wait_script()
  return table.concat({
    "ios_state=ios_process.GetState()",
    "for ios_i in range(30):",
    "    if ios_state == lldb.eStateConnected: break",
    "    time.sleep(0.1)",
    "    ios_state=ios_process.GetState()",
    'if ios_state != lldb.eStateConnected: raise RuntimeError("legacy debugserver did not connect")',
  }, "\n")
end

local function stopped_wait_script()
  return table.concat({
    "ios_state=ios_process.GetState()",
    "for ios_i in range(180):",
    "    if ios_state == lldb.eStateStopped: break",
    "    if ios_state in (lldb.eStateCrashed, lldb.eStateDetached, lldb.eStateExited, lldb.eStateInvalid):",
    '        raise RuntimeError("legacy iOS debug ended in state %d" % ios_state)',
    "    time.sleep(0.1)",
    "    ios_state=ios_process.GetState()",
    'if ios_state != lldb.eStateStopped: raise RuntimeError("legacy iOS debug did not stop")',
  }, "\n")
end

local function required(opts, key)
  local value = opts and opts[key]
  if type(value) == "number" then
    if value > 0 then
      return value
    end
  elseif trim(value) ~= "" then
    return value
  end
  return nil, "iOS DAP " .. key .. " is required"
end

local function build_config(opts)
  opts = opts or {}
  local mode = trim(opts.mode):lower()
  if mode ~= "attach" and mode ~= "launch" then
    return nil, "iOS DAP mode must be attach or launch"
  end
  local binary, err = required(opts, "binary")
  if not binary then
    return nil, err
  end
  local symbols
  symbols, err = required(opts, "symbols")
  if not symbols then
    return nil, err
  end
  local app_path
  app_path, err = required(opts, "device_app_path")
  if not app_path then
    return nil, err
  end
  local executable
  executable, err = required(opts, "executable_name")
  if not executable then
    return nil, err
  end
  local port
  port, err = required(opts, "port")
  if not port then
    return nil, err
  end
  local pid
  if mode == "attach" then
    pid, err = required(opts, "pid")
    if not pid then
      return nil, err
    end
  end

  local remote_executable = trim(app_path):gsub("/$", "") .. "/" .. trim(executable)
  local commands = {
    "platform select remote-ios --sysroot " .. lldb_quote(symbols),
    "target create " .. lldb_quote(binary),
    "script ios_module=lldb.target.modules[0]; ios_remote_ok=ios_module.SetPlatformFileSpec("
      .. "lldb.SBFileSpec("
      .. python_string(remote_executable)
      .. ")); "
      .. 'assert ios_remote_ok, "failed to map the installed iOS executable"',
    "script import time; ios_listener=lldb.debugger.GetListener()",
    "script ios_error=lldb.SBError(); ios_process=lldb.target.ConnectRemote(" .. "ios_listener, " .. python_string(
      ("connect://127.0.0.1:%d"):format(port)
    ) .. ", None, ios_error)",
    python_exec(connect_wait_script()),
  }

  if mode == "launch" then
    commands[#commands + 1] = "script ios_ok=ios_process.RemoteLaunch([], "
      .. '["OS_ACTIVITY_DT_MODE=enable"], None, None, None, None, 0, True, ios_error); '
      .. 'assert ios_ok, "iOS RemoteLaunch failed: " + str(ios_error)'
  else
    commands[#commands + 1] = ("script ios_ok=ios_process.RemoteAttachToProcessWithID(%d, ios_error); "):format(pid)
      .. 'assert ios_ok, "iOS RemoteAttach failed: " + str(ios_error)'
  end
  commands[#commands + 1] = python_exec(stopped_wait_script())
  commands[#commands + 1] = "script ios_load_address=ios_module.GetObjectFileHeaderAddress().GetLoadAddress(lldb.target); "
    .. 'assert ios_load_address != lldb.LLDB_INVALID_ADDRESS, "local iOS binary did not match the loaded device image"'
  return {
    name = mode == "launch" and "UE IOS Attach at Launch" or "UE IOS Attach",
    _ue_ios_session_owner = "legacy-mobiledevice",
    _ue_session_owner = "ios",
    _ue_session_operation = mode,
    _ue_device_id = opts.device_id,
    _ue_process_id = opts.pid,
    type = "lldb",
    -- attachCommands drives the externally managed remote debugserver.
    request = "attach",
    stopOnEntry = true,
    timeout = 240,
    cwd = trim(opts.cwd) ~= "" and opts.cwd or vim.fn.getcwd(),
    initCommands = vim.deepcopy(INIT_COMMANDS),
    attachCommands = commands,
    postRunCommands = { "process status" },
  }
end

local function parse_installed_apps(payload, bundle_id)
  local ok, decoded = pcall(vim.json.decode, tostring(payload or ""))
  if not ok or type(decoded) ~= "table" then
    return nil, "failed to decode ideviceinstaller app plist"
  end
  local matches = {}
  for _, app in ipairs(decoded) do
    if type(app) == "table" and trim(app.CFBundleIdentifier) == bundle_id then
      matches[#matches + 1] = app
    end
  end
  if #matches ~= 1 then
    return nil, ("installed bundle %q matched %d apps"):format(bundle_id, #matches)
  end
  local app = matches[1]
  local path = trim(app.Path)
  local executable = trim(app.CFBundleExecutable)
  if path == "" or executable == "" then
    return nil, "installed app metadata is missing Path or CFBundleExecutable"
  end
  return {
    app_path = path,
    executable_name = executable,
    entitlements = type(app.Entitlements) == "table" and app.Entitlements or {},
  }
end

local function system_async(argv, opts, callback)
  opts = opts or {}
  local ok, handle_or_err = pcall(vim.system, argv, {
    text = true,
    cwd = opts.cwd,
    stdin = opts.stdin,
  }, function(result)
    vim.schedule(function()
      callback(result or { code = -1, stderr = "no result" })
    end)
  end)
  if not ok then
    vim.schedule(function()
      callback({ code = -1, stdout = "", stderr = tostring(handle_or_err) })
    end)
    return nil
  end
  return handle_or_err
end

local function parse_device_info(output)
  local fields = {}
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local key, value = line:match("^([^:]+):%s*(.*)$")
    if key then
      fields[key] = value
    end
  end
  return fields
end

local function find_device_symbols(fields)
  local product = trim(fields.ProductType)
  local version = trim(fields.ProductVersion)
  local build = trim(fields.BuildVersion)
  if product == "" or version == "" or build == "" then
    return nil, "ideviceinfo is missing ProductType/ProductVersion/BuildVersion"
  end
  local root = vim.fn.expand("~/Library/Developer/Xcode/iOS DeviceSupport")
  local exact = ("%s/%s %s (%s)/Symbols"):format(root, product, version, build)
  if vim.fn.isdirectory(exact) == 1 then
    return vim.fs.normalize(exact)
  end
  local matches = vim.fn.glob(("%s/%s %s (*)/Symbols"):format(root, product, version), false, true)
  if #matches == 1 and vim.fn.isdirectory(matches[1]) == 1 then
    return vim.fs.normalize(matches[1])
  end
  return nil, ("exact Xcode DeviceSupport symbols are missing for %s %s (%s)"):format(product, version, build)
end

local function query_installed_app(runtime, callback)
  system_async({
    runtime.tools.ideviceinstaller,
    "-u",
    runtime.device_id,
    "-l",
    "-o",
    "xml",
  }, {}, function(list_result)
    if list_result.code ~= 0 then
      callback(nil, "ideviceinstaller failed: " .. IOSProcess.error_message(list_result))
      return
    end
    system_async({ runtime.tools.plutil, "-convert", "json", "-o", "-", "-" }, {
      stdin = list_result.stdout or "",
    }, function(plist_result)
      if plist_result.code ~= 0 then
        callback(nil, "plutil failed to decode installed apps: " .. IOSProcess.error_message(plist_result))
        return
      end
      callback(parse_installed_apps(plist_result.stdout, runtime.bundle_id))
    end)
  end)
end

local function query_device_symbols(runtime, callback)
  system_async({ runtime.tools.ideviceinfo, "-u", runtime.device_id }, {}, function(result)
    if result.code ~= 0 then
      callback(nil, IOSProcess.device_unavailable(runtime.device_id, result))
      return
    end
    callback(find_device_symbols(parse_device_info(result.stdout)))
  end)
end

local function query_pid(runtime, callback)
  system_async({
    runtime.tools.ios_deploy,
    "--id",
    runtime.device_id,
    "--no-wifi",
    "--bundle_id",
    runtime.bundle_id,
    "--get_pid",
  }, {}, function(result)
    local output = (result.stdout or "") .. "\n" .. (result.stderr or "")
    local pid = tonumber(output:match("pid:%s*(-?%d+)"))
    if pid and pid > 0 then
      callback(pid, nil, false)
      return
    end
    if result.code == 0 and ((pid and pid <= 0) or output:find("Could not find pid", 1, true)) then
      callback(nil, "installed app is not running; use :UEDAPLaunch for attach-at-launch", true)
      return
    end
    callback(nil, "failed to verify the device process: " .. trim(output), false)
  end)
end

local function reserve_port()
  local tcp = vim.uv.new_tcp()
  if not tcp then
    return nil, "failed to create a local TCP socket"
  end
  local ok, err = tcp:bind("127.0.0.1", 0)
  if not ok then
    tcp:close()
    return nil, tostring(err)
  end
  local address = tcp:getsockname()
  tcp:close()
  local port = address and tonumber(address.port)
  if not port or port <= 0 then
    return nil, "failed to reserve a local debugserver port"
  end
  return port
end

local function stop_bridge(session)
  local bridge = session and session.bridge
  if bridge and bridge.job_id and bridge.job_id > 0 then
    pcall(vim.fn.jobstop, bridge.job_id)
    bridge.job_id = nil
  end
end

local function start_bridge(runtime, callback)
  local port, port_err = reserve_port()
  if not port then
    callback(nil, port_err)
    return
  end
  local bridge = { output = "", port = port, ready = false, finished = false }
  local function finish(value, err)
    if bridge.finished then
      return
    end
    bridge.finished = true
    if bridge.timer then
      pcall(function()
        bridge.timer:stop()
        bridge.timer:close()
      end)
      bridge.timer = nil
    end
    callback(value, err)
  end
  local function consume(data)
    if type(data) ~= "table" then
      return
    end
    for _, line in ipairs(data) do
      if line ~= "" then
        bridge.output = bridge.output .. line .. "\n"
      end
      if not bridge.ready and line:find("Listening for lldb connections", 1, true) then
        bridge.ready = true
        vim.schedule(function()
          finish(bridge)
        end)
      end
    end
  end
  bridge.job_id = vim.fn.jobstart({
    runtime.tools.ios_deploy,
    "--id",
    runtime.device_id,
    "--no-wifi",
    "--nolldb",
    "--port",
    tostring(port),
    "--faster-path-search",
  }, {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      consume(data)
    end,
    on_stderr = function(_, data)
      consume(data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if not bridge.ready then
          finish(nil, ("ios-deploy debugserver bridge exited (%d): %s"):format(code, trim(bridge.output)))
        end
      end)
    end,
  })
  if bridge.job_id <= 0 then
    callback(nil, "failed to start ios-deploy debugserver bridge")
    return
  end
  bridge.timer = vim.uv.new_timer()
  if bridge.timer then
    bridge.timer:start(
      30000,
      0,
      vim.schedule_wrap(function()
        stop_bridge({ bridge = bridge })
        finish(nil, "timed out waiting for the iOS debugserver bridge")
      end)
    )
  end
end

local function kill_app(runtime, callback)
  system_async({
    runtime.tools.ios_deploy,
    "--id",
    runtime.device_id,
    "--no-wifi",
    "--bundle_id",
    runtime.bundle_id,
    "--kill",
  }, {}, function()
    query_pid(runtime, function(pid, err, absent)
      if pid then
        callback(false, ("device process is still running (pid=%d)"):format(pid))
      elseif not absent then
        callback(false, err or "failed to verify that the device process stopped")
      else
        callback(true)
      end
    end)
  end)
end

local function stop_runtime(runtime, callback)
  stop_bridge(runtime)
  if runtime and runtime.backend == "coredevice" then
    CoreDevice.stop(runtime, { system_async = system_async }, callback)
  else
    kill_app(runtime, callback)
  end
end

local function preserves_attached_process(runtime)
  return runtime and runtime.backend == "coredevice" and runtime._ue_coredevice_owns_process ~= true
end

local function end_unexpected_session(session, on_done)
  if not IOSSession.is_owned(session) or M._stopping then
    return false
  end
  local runtime = M._session or M._cleanup_runtime
  if not runtime then
    return false
  end
  M._session = nil
  M._cleanup_runtime = runtime
  local preserve = preserves_attached_process(runtime)
  progress(
    "step",
    preserve and "iOS debugger ended; verifying attached device process …"
      or "iOS debugger ended; stopping device process …"
  )
  stop_runtime(runtime, function(ok, err)
    if ok then
      progress(
        "done",
        preserve and "iOS debugger ended; attached device process preserved"
          or "iOS debugger and device process stopped"
      )
    else
      progress("error", err)
      notify(err, vim.log.levels.ERROR)
    end
    if type(on_done) == "function" then
      on_done(ok, err)
    end
  end)
  return true
end

local install_listeners

local function run_coredevice(runtime, config)
  M._session = runtime
  M._starting = false
  install_listeners()
  progress("step", "4/4 LLDB attaching and validating the loaded image UUID …")
  if
    C.run(config, "UEDAP ios " .. config._ue_session_operation, runtime.adapter, {
      initialize_timeout_sec = 90,
      disconnect_timeout_sec = 10,
    })
  then
    return true
  end
  M._session = nil
  return false
end

install_listeners = function()
  IOSSession.install({
    notify = notify,
    on_unexpected_end = end_unexpected_session,
    progress = progress,
  })
end

local function fail_start(message)
  M._starting = false
  progress("error", message)
  notify(message, vim.log.levels.ERROR)
end

local function run_with_metadata(mode, runtime, app, symbols, pid)
  progress("step", "3/4 starting legacy USB debugserver bridge …")
  start_bridge(runtime, function(bridge, bridge_err)
    if not bridge then
      fail_start(bridge_err)
      return
    end
    runtime.app = app
    runtime.bridge = bridge
    runtime.symbols = symbols
    runtime.pid = pid
    local config, config_err = build_config({
      mode = mode,
      binary = runtime.binary,
      cwd = runtime.cwd,
      device_id = runtime.device_id,
      device_app_path = app.app_path,
      executable_name = app.executable_name,
      pid = pid,
      port = bridge.port,
      symbols = symbols,
    })
    if not config then
      stop_bridge(runtime)
      fail_start(config_err)
      return
    end
    M._session = runtime
    M._starting = false
    install_listeners()
    progress("step", "4/4 LLDB loading local UE symbols (first stop can take ~30s) …")
    if
      not C.run(config, "UEDAP ios " .. mode, runtime.adapter, {
        initialize_timeout_sec = 90,
        disconnect_timeout_sec = 10,
      })
    then
      M._session = nil
      stop_bridge(runtime)
      fail_start("failed to start lldb-dap")
    end
  end)
end

local function prepare(mode, opts)
  if M._starting then
    notify("an iOS DAP bootstrap is already running", vim.log.levels.WARN)
    return
  end
  if M._session then
    notify("an iOS DAP session is already active; run :UEDAPStop first", vim.log.levels.WARN)
    return
  end
  if M._cleanup_runtime and M._cleanup_runtime._ue_coredevice_cleanup then
    if not M._cleanup_runtime._ue_coredevice_cleanup.done then
      notify("the previous iOS owner cleanup is still running", vim.log.levels.WARN)
      return
    end
    M._cleanup_runtime = nil
  end
  local runtime, err = Runtime.resolve(opts)
  if not runtime then
    fail_start(err)
    return
  end
  M._starting = true
  notify(
    (mode == "launch" and "iOS attach-at-launch" or "iOS attach") .. " bootstrap started for " .. runtime.device_id
  )
  progress("step", "1/4 resolving the frozen iOS debug context …")
  Runtime.query_adapter(runtime, system_async, function(adapter, adapter_err)
    if not adapter then
      fail_start(adapter_err)
      return
    end
    runtime.adapter = adapter
    if runtime.backend == "coredevice" then
      CoreDevice.prepare(mode, runtime, {
        fail = fail_start,
        init_commands = INIT_COMMANDS,
        progress = progress,
        run = run_coredevice,
        system_async = system_async,
      })
      return
    end
    query_device_symbols(runtime, function(symbols, symbols_err)
      if not symbols then
        fail_start(symbols_err)
        return
      end
      query_installed_app(runtime, function(app, app_err)
        if not app then
          fail_start(app_err)
          return
        end
        if app.entitlements["get-task-allow"] ~= true then
          fail_start("installed app is not development-debuggable (get-task-allow is false)")
          return
        end
        progress("step", "2/4 installed app verified; preparing device process …")
        if mode == "attach" then
          query_pid(runtime, function(pid, pid_err)
            if not pid then
              fail_start(pid_err)
              return
            end
            run_with_metadata(mode, runtime, app, symbols, pid)
          end)
          return
        end
        system_async({
          runtime.tools.ios_deploy,
          "--id",
          runtime.device_id,
          "--no-wifi",
          "--bundle_id",
          runtime.bundle_id,
          "--kill",
        }, {}, function()
          run_with_metadata(mode, runtime, app, symbols)
        end)
      end)
    end)
  end)
end

function M.attach(opts)
  prepare("attach", opts)
end

function M.launch(opts)
  prepare("launch", opts)
end

function M.stop(opts)
  opts = opts or {}
  local on_done = type(opts.on_done) == "function" and opts.on_done or function() end
  local runtime = M._session or M._cleanup_runtime
  if not runtime then
    notify("no active iOS DAP owner to stop")
    on_done(true)
    return
  end
  M._stopping = true
  local finalized = false
  local function finalize()
    if finalized then
      return
    end
    finalized = true
    M._session = nil
    M._cleanup_runtime = runtime
    local preserve = preserves_attached_process(runtime)
    progress(
      "step",
      preserve and "detaching and verifying the iOS device process …"
        or "stopping and verifying the iOS device process …"
    )
    stop_runtime(runtime, function(ok, err)
      M._stopping = false
      if ok then
        progress(
          "done",
          preserve and "iOS device process preserved after detach" or "iOS device process stopped (pid absent)"
        )
        notify(
          preserve and "iOS debugger detached; existing device process preserved"
            or "iOS debugger detached and device process stopped"
        )
        on_done(true)
      else
        progress("error", err)
        notify(err, vim.log.levels.ERROR)
        on_done(false, err)
      end
    end)
  end
  local dap = C.require_dap()
  local active = dap and dap.session and dap.session() or nil
  if active and IOSSession.is_owned(active) then
    local ok = pcall(dap.disconnect, { terminateDebuggee = false }, function()
      vim.schedule(finalize)
    end)
    if ok then
      vim.defer_fn(finalize, 5000)
      return
    end
  end
  finalize()
end

function M.cleanup(opts)
  local session = type(opts) == "table" and opts.session or nil
  local completed = false
  local function done()
    completed = true
  end
  local started = end_unexpected_session(session, done)
  if not started and M._cleanup_runtime then
    started = true
    stop_runtime(M._cleanup_runtime, done)
  end
  if started then
    vim.wait(65000, function()
      return completed
    end, 50)
  end
end

function M._build_config_for_test(opts)
  return build_config(opts)
end

function M._parse_installed_apps_for_test(payload, bundle_id)
  return parse_installed_apps(payload, bundle_id)
end

function M._build_coredevice_config_for_test(opts)
  return CoreDevice.build_config(opts)
end

function M._resolve_runtime_for_test(opts)
  return Runtime.resolve(opts)
end

return M
