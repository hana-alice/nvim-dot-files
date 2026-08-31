-- ue.dap._ios_coredevice — iOS 17+ CoreDevice DAP bootstrap and cleanup.
--
-- This module owns only the CoreDevice route. The legacy MobileDevice bridge
-- stays in ue.dap.ios and a frozen session never switches between them.
local IOSProcess = require("ue.dap._ios_process")

local M = {}

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function lldb_quote(value)
  local escaped = tostring(value or ""):gsub("\\", "\\\\"):gsub('"', '\\"')
  return '"' .. escaped .. '"'
end

local function python_string(value)
  return vim.json.encode(tostring(value or ""))
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
  return nil, "iOS CoreDevice DAP " .. key .. " is required"
end

function M.build_config(opts)
  opts = opts or {}
  local mode = trim(opts.mode):lower()
  if mode ~= "attach" and mode ~= "launch" then
    return nil, "iOS CoreDevice DAP mode must be attach or launch"
  end
  local binary, err = required(opts, "binary")
  if not binary then
    return nil, err
  end
  local dsym
  dsym, err = required(opts, "dsym")
  if not dsym then
    return nil, err
  end
  local device_id
  device_id, err = required(opts, "device_id")
  if not device_id then
    return nil, err
  end
  local pid
  pid, err = required(opts, "pid")
  if not pid then
    return nil, err
  end
  local expected_uuids = opts.expected_uuids
  if type(expected_uuids) ~= "table" or #expected_uuids == 0 then
    return nil, "iOS CoreDevice DAP expected_uuids is required"
  end

  local quoted_uuids = {}
  for _, uuid in ipairs(expected_uuids) do
    quoted_uuids[#quoted_uuids + 1] = python_string(trim(uuid):upper())
  end
  local uuid_probe = table.concat({
    "script import lldb; ios_expected_uuids={",
    table.concat(quoted_uuids, ","),
    "}; ios_target=lldb.target; ios_main_name=ios_target.GetExecutable().GetFilename(); ios_loaded_main=[",
    "ios_module for ios_module in ios_target.modules if ios_module.GetFileSpec().GetFilename() == ios_main_name ",
    "and ios_module.GetObjectFileHeaderAddress().GetLoadAddress(ios_target) != lldb.LLDB_INVALID_ADDRESS",
    "]; print('__UE_IOS_LOADED_UUID_OK__' if len(ios_loaded_main) == 1 and ",
    "(ios_loaded_main[0].GetUUIDString() or '').upper() in ios_expected_uuids ",
    "else '__UE_IOS_LOADED_UUID_MISMATCH__')",
  })
  local commands = {
    "target create " .. lldb_quote(binary),
    "device select " .. lldb_quote(device_id),
    ("device process attach -p %d"):format(pid),
    "target symbols add " .. lldb_quote(dsym),
  }
  return {
    name = mode == "launch" and "UE IOS CoreDevice Debug Launch" or "UE IOS CoreDevice Attach",
    _ue_ios_backend = "coredevice",
    _ue_ios_session_owner = "coredevice",
    _ue_session_owner = "ios",
    _ue_session_operation = mode,
    _ue_device_id = device_id,
    _ue_process_id = pid,
    type = "lldb",
    request = "attach",
    stopOnEntry = true,
    timeout = 240,
    cwd = trim(opts.cwd) ~= "" and opts.cwd or vim.fn.getcwd(),
    initCommands = vim.deepcopy(opts.init_commands or {}),
    attachCommands = commands,
    postRunCommands = { "process status", uuid_probe },
  }
end

local function read_json_file(path)
  if vim.fn.filereadable(path) ~= 1 then
    return nil, "devicectl did not create its JSON result"
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then
    return nil, "failed to read devicectl JSON result"
  end
  return table.concat(lines, "\n")
end

local function json_command(runtime, args, deps, callback)
  local output = vim.fn.tempname() .. ".json"
  local argv = { runtime.tools.xcrun }
  vim.list_extend(argv, args)
  vim.list_extend(argv, { "--quiet", "--timeout", "60", "--json-output", output })
  deps.system_async(argv, {}, function(result)
    local payload, read_err
    if result.code == 0 then
      payload, read_err = read_json_file(output)
    end
    pcall(vim.fn.delete, output)
    if result.code ~= 0 then
      callback(nil, "devicectl failed: " .. IOSProcess.error_message(result))
      return
    end
    if not payload then
      callback(nil, read_err)
      return
    end
    callback(payload)
  end)
end

local function query_app(runtime, deps, callback)
  json_command(
    runtime,
    {
      "devicectl",
      "device",
      "info",
      "apps",
      "--device",
      runtime.device_id,
      "--bundle-id",
      runtime.bundle_id,
    },
    deps,
    function(payload, command_err)
      if not payload then
        callback(nil, command_err)
        return
      end
      callback(IOSProcess.parse_coredevice_apps(payload, { bundle_id = runtime.bundle_id }))
    end
  )
end

local function query_process(runtime, deps, pid, callback)
  json_command(
    runtime,
    {
      "devicectl",
      "device",
      "info",
      "processes",
      "--device",
      runtime.coredevice_id,
    },
    deps,
    function(payload, command_err)
      if not payload then
        callback(nil, command_err)
        return
      end
      callback(IOSProcess.parse_coredevice_processes(payload, {
        app_url = runtime.app.app_url,
        canonical_device_id = runtime.coredevice_id,
        pid = pid,
      }))
    end
  )
end

local function query_uuid(runtime, path, deps, callback)
  deps.system_async({ runtime.tools.xcrun, "dwarfdump", "--uuid", path }, {}, function(result)
    if result.code ~= 0 then
      callback(nil, "dwarfdump failed: " .. IOSProcess.error_message(result))
      return
    end
    callback(IOSProcess.parse_uuid_output((result.stdout or "") .. "\n" .. (result.stderr or "")))
  end)
end

local function query_host_uuids(runtime, deps, callback)
  query_uuid(runtime, runtime.binary, deps, function(binary_uuids, binary_err)
    if not binary_uuids then
      callback(nil, binary_err)
      return
    end
    query_uuid(runtime, runtime.dsym, deps, function(dsym_uuids, dsym_err)
      if not dsym_uuids then
        callback(nil, dsym_err)
        return
      end
      if not IOSProcess.uuid_sets_equal(binary_uuids, dsym_uuids) then
        callback(nil, "local iOS Mach-O and dSYM UUIDs do not match")
        return
      end
      deps.system_async({ runtime.tools.xcrun, "dwarfdump", "--verify", "--quiet", runtime.dsym }, {}, function(result)
        if result.code ~= 0 then
          callback(nil, "local iOS dSYM failed DWARF verification; regenerate it before debugging")
          return
        end
        callback(binary_uuids)
      end)
    end)
  end)
end

local function launch_stopped(runtime, deps, callback)
  json_command(
    runtime,
    {
      "devicectl",
      "device",
      "process",
      "launch",
      "--device",
      runtime.coredevice_id,
      "--terminate-existing",
      "--start-stopped",
      runtime.bundle_id,
    },
    deps,
    function(payload, command_err)
      if not payload then
        callback(nil, command_err)
        return
      end
      local launched, parse_err = IOSProcess.parse_coredevice_launch(payload, {
        bundle_id = runtime.bundle_id,
        canonical_device_id = runtime.coredevice_id,
      })
      if not launched then
        callback(nil, parse_err)
        return
      end
      runtime.pid = launched.process_id
      query_process(runtime, deps, runtime.pid, function(process, process_err)
        if not process then
          callback(nil, process_err)
        elseif process.absent then
          callback(nil, "CoreDevice launched PID is absent or belongs to another app")
        else
          callback(process)
        end
      end)
    end
  )
end

local function terminate(runtime, deps, callback)
  if not runtime or not runtime.pid or not runtime.app or trim(runtime.coredevice_id) == "" then
    callback(false, "CoreDevice cleanup requires a captured device, app and PID")
    return
  end
  query_process(runtime, deps, runtime.pid, function(before, before_err)
    if not before then
      callback(false, before_err)
      return
    end
    if before.absent then
      callback(true)
      return
    end
    json_command(
      runtime,
      {
        "devicectl",
        "device",
        "process",
        "terminate",
        "--device",
        runtime.coredevice_id,
        "--pid",
        tostring(runtime.pid),
      },
      deps,
      function(_, terminate_err)
        if terminate_err then
          callback(false, terminate_err)
          return
        end
        query_process(runtime, deps, runtime.pid, function(after, after_err)
          if not after then
            callback(false, after_err)
          elseif not after.absent then
            callback(false, "CoreDevice process is still running after terminate")
          else
            callback(true)
          end
        end)
      end
    )
  end)
end

local function verify_preserved(runtime, deps, callback)
  if not runtime or not runtime.pid or not runtime.app or trim(runtime.coredevice_id) == "" then
    callback(false, "CoreDevice attach cleanup requires a captured device, app and PID")
    return
  end
  query_process(runtime, deps, runtime.pid, function(process, process_err)
    if not process then
      callback(false, process_err)
    elseif process.absent then
      callback(false, "CoreDevice attached process is absent after debugger detach")
    else
      callback(true)
    end
  end)
end

local function fail_owned(runtime, deps, message)
  if not runtime.pid or runtime._ue_coredevice_owns_process ~= true then
    deps.fail(message)
    return
  end
  terminate(runtime, deps, function(ok, cleanup_err)
    if ok then
      deps.fail(message)
    else
      deps.fail(message .. "; cleanup failed: " .. tostring(cleanup_err))
    end
  end)
end

function M.prepare(mode, runtime, deps)
  runtime._ue_coredevice_owns_process = mode == "launch"
  deps.progress("step", "1/4 resolving CoreDevice app identity and local UUIDs …")
  query_app(runtime, deps, function(app, app_err)
    if not app then
      deps.fail(app_err)
      return
    end
    runtime.app = app
    runtime.coredevice_id = app.device_id
    query_host_uuids(runtime, deps, function(expected_uuids, uuid_err)
      if not expected_uuids then
        deps.fail(uuid_err)
        return
      end
      runtime.expected_uuids = expected_uuids
      deps.progress("step", "2/4 preparing the frozen CoreDevice process identity …")
      local function start(process, process_err)
        if not process then
          fail_owned(runtime, deps, process_err)
          return
        end
        runtime.pid = process.process_id
        local config, config_err = M.build_config({
          mode = mode,
          binary = runtime.binary,
          cwd = runtime.cwd,
          device_id = runtime.coredevice_id,
          dsym = runtime.dsym,
          expected_uuids = runtime.expected_uuids,
          init_commands = deps.init_commands,
          pid = runtime.pid,
        })
        if not config then
          fail_owned(runtime, deps, config_err)
          return
        end
        deps.progress("step", "3/4 starting Apple lldb-dap on the frozen CoreDevice PID …")
        if not deps.run(runtime, config) then
          fail_owned(runtime, deps, "failed to start Apple lldb-dap")
        end
      end
      if mode == "launch" then
        launch_stopped(runtime, deps, start)
      else
        query_process(runtime, deps, runtime.requested_pid, function(process, process_err)
          if process and process.absent then
            start(nil, "installed app is not running; use :UEDAPLaunch for debug launch")
          else
            start(process, process_err)
          end
        end)
      end
    end)
  end)
end

function M.stop(runtime, deps, callback)
  callback = type(callback) == "function" and callback or function() end
  if not runtime then
    callback(false, "CoreDevice cleanup requires a frozen runtime")
    return
  end
  local state = runtime._ue_coredevice_cleanup
  if type(state) == "table" then
    if state.done then
      callback(state.ok, state.err)
    else
      state.waiters[#state.waiters + 1] = callback
    end
    return
  end
  state = { done = false, waiters = { callback } }
  runtime._ue_coredevice_cleanup = state
  local cleanup = runtime._ue_coredevice_owns_process == true and terminate or verify_preserved
  cleanup(runtime, deps, function(ok, err)
    state.done = true
    state.ok = ok
    state.err = err
    local waiters = state.waiters
    state.waiters = {}
    for _, waiter in ipairs(waiters) do
      waiter(ok, err)
    end
  end)
end

function M._json_argv_for_test(xcrun, args, output)
  local argv = { xcrun }
  vim.list_extend(argv, args)
  vim.list_extend(argv, { "--quiet", "--timeout", "60", "--json-output", output })
  return argv
end

return M
