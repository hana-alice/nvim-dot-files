local t = require("tests.harness")
t.bootstrap()

local function owned(pid, backend, device)
  return {
    config = {
      _ue_session_owner = "ios",
      _ue_ios_session_owner = backend or "legacy-mobiledevice",
      _ue_device_id = device or "MOBILE-UDID",
      _ue_process_id = pid or 123,
    },
    on_close = {},
    request = function()
      error("log reader must not request DAP actions")
    end,
  }
end

local function with_reader(callback)
  local original = {
    system = vim.system,
    jobstart = vim.fn.jobstart,
    jobstop = vim.fn.jobstop,
    exepath = vim.fn.exepath,
    autocmd = vim.api.nvim_create_autocmd,
    registry = package.loaded["utils.task_registry"],
    module = package.loaded["ue.dap._ios_log"],
  }
  local state =
    { queries = {}, jobs = {}, stopped = {}, tasks = {}, sessions = {}, buffers = {}, autocmds = {}, missing = {} }
  vim.fn.exepath = function(name)
    return state.missing[name] and "" or "/existing/" .. name
  end
  vim.system = function(argv, options, done)
    local query = { argv = argv, options = options, done = done, kills = 0 }
    query.handle = {
      kill = function(_, signal)
        t.assert_eq(signal, 15)
        query.kills = query.kills + 1
      end,
    }
    state.queries[#state.queries + 1] = query
    return query.handle
  end
  vim.fn.jobstart = function(argv, options)
    if state.spawn_failure then
      return -1
    end
    local id = 100 + #state.jobs
    state.jobs[#state.jobs + 1] = { argv = argv, options = options, id = id }
    return id
  end
  vim.fn.jobstop = function(id)
    state.stopped[#state.stopped + 1] = id
    return 1
  end
  vim.api.nvim_create_autocmd = function(event, options)
    state.autocmds[#state.autocmds + 1] = { event = event, options = options }
    return original.autocmd(event, options)
  end
  package.loaded["utils.task_registry"] = {
    register = function(spec)
      if spec.kind == "job" then
        t.assert_true(#state.jobs > 0, "reader registration must follow spawn")
      else
        t.assert_true(#state.queries > 0, "query registration must follow spawn")
      end
      state.tasks[#state.tasks + 1] = spec
    end,
  }
  package.loaded["ue.dap._ios_log"] = nil
  local Log = require("ue.dap._ios_log")
  function state.buffer(session)
    state.sessions[#state.sessions + 1] = session
    local buffer = Log.buffer(session)
    if buffer then
      state.buffers[#state.buffers + 1] = buffer
    end
    return buffer
  end
  function state.complete(payload, index, result)
    local query = state.queries[index or 1]
    local position = assert(vim.fn.index(query.argv, "--json-output")) + 2
    vim.fn.writefile({ type(payload) == "string" and payload or vim.json.encode(payload) }, query.argv[position])
    query.done(result or { code = 0, stdout = "", stderr = "" })
    vim.wait(10)
  end
  function state.lines(buffer)
    return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
  end
  local ok, err = xpcall(function()
    callback(Log, state)
  end, debug.traceback)
  for _, session in ipairs(state.sessions) do
    Log.stop(session)
  end
  for _, buffer in ipairs(state.buffers) do
    if vim.api.nvim_buf_is_valid(buffer) then
      pcall(vim.api.nvim_buf_delete, buffer, { force = true })
    end
  end
  vim.wait(10)
  vim.system, vim.fn.jobstart, vim.fn.jobstop = original.system, original.jobstart, original.jobstop
  vim.fn.exepath, vim.api.nvim_create_autocmd = original.exepath, original.autocmd
  package.loaded["utils.task_registry"], package.loaded["ue.dap._ios_log"] = original.registry, original.module
  if not ok then
    error(err)
  end
end

local function details(id, udid, transport)
  return {
    result = {
      identifier = id,
      hardwareProperties = { udid = udid },
      connectionProperties = { transportType = transport },
    },
  }
end

t.describe("iOS DAP session logs", function()
  t.it("rejects foreign owners and reports invalid frozen identity without spawning", function()
    with_reader(function(Log, state)
      t.assert_eq(Log.label, "iOS Logs")
      t.assert_eq(state.buffer({ config = { _ue_session_owner = "android" } }), nil)
      local session = owned(-2)
      local buffer = state.buffer(session)
      t.assert_contains(table.concat(state.lines(buffer), "\n"), "positive PID")
      t.assert_eq(#state.jobs, 0)
      t.assert_eq(#state.queries, 0)
      Log.stop(nil)
    end)
  end)

  t.it("starts one legacy reader for the frozen UDID and PID and hides its buffer", function()
    with_reader(function(Log, state)
      local session = owned(123)
      local buffer = state.buffer(session)
      t.assert_eq(Log.buffer(session), buffer)
      t.assert_eq(#state.jobs, 1)
      t.assert_true(
        vim.deep_equal(
          state.jobs[1].argv,
          { "/existing/idevicesyslog", "--udid", "MOBILE-UDID", "--process", "123", "--no-colors", "--exit" }
        )
      )
      t.assert_eq(vim.bo[buffer].bufhidden, "hide")
      t.assert_eq(vim.bo[buffer].filetype, "log")
      t.assert_true(vim.b[buffer].ue_dap_log)
      t.assert_contains(vim.api.nvim_buf_get_name(buffer), "ue-ios-log:123")
      t.assert_eq(#state.tasks, 1)
      t.assert_eq(state.tasks[1].handle, state.jobs[1].id)
      t.assert_eq(state.tasks[1].kind, "job")
    end)
  end)

  t.it("maps only the frozen CoreDevice identifier to its hardware UDID with a bounded network query", function()
    with_reader(function(_, state)
      local session = owned(44, "coredevice", "CORE-A")
      state.buffer(session)
      t.assert_eq(#state.jobs, 0)
      local query = state.queries[1]
      t.assert_true(vim.deep_equal(vim.list_slice(query.argv, 1, 11), {
        "/existing/xcrun",
        "devicectl",
        "device",
        "info",
        "details",
        "--device",
        "CORE-A",
        "--quiet",
        "--timeout",
        "20",
        "--json-output",
      }))
      t.assert_eq(query.options.timeout, 25000)
      session.config._ue_device_id, session.config._ue_process_id = "CORE-B", 99
      state.complete(details("CORE-A", "HARDWARE-A", "network"))
      t.assert_true(
        vim.deep_equal(
          state.jobs[1].argv,
          { "/existing/idevicesyslog", "--udid", "HARDWARE-A", "--process", "44", "--no-colors", "--exit", "--network" }
        )
      )
      t.assert_eq(#state.tasks, 2)
      t.assert_eq(state.tasks[1].kind, "system")
      t.assert_eq(state.tasks[2].kind, "job")
      t.assert_eq(vim.fn.filereadable(query.argv[12]), 0)
    end)
  end)

  t.it("fails closed on wrong device, malformed JSON, or absent hardware UDID", function()
    for _, payload in ipairs({ details("CORE-B", "OTHER", "wired"), "not json", details("CORE-A", nil, "wired") }) do
      with_reader(function(_, state)
        local buffer = state.buffer(owned(22, "coredevice", "CORE-A"))
        state.complete(payload)
        t.assert_eq(#state.jobs, 0)
        local text = table.concat(state.lines(buffer), "\n")
        t.assert_contains(text, "layer=L1 owner=ios.logrelay")
        t.assert_contains(text, "evidence:")
        t.assert_contains(text, "remedy:")
      end)
    end
  end)

  t.it("shows tool, query, and spawn errors without installing tools or starting another route", function()
    for _, missing in ipairs({ "idevicesyslog", "xcrun" }) do
      with_reader(function(_, state)
        state.missing[missing] = true
        local buffer = state.buffer(owned(22, "coredevice", "CORE-A"))
        t.assert_contains(table.concat(state.lines(buffer), "\n"), "layer=L0")
        t.assert_eq(#state.queries, 0)
        t.assert_eq(#state.jobs, 0)
      end)
    end
    with_reader(function(_, state)
      local buffer = state.buffer(owned(22, "coredevice", "CORE-A"))
      state.complete({}, nil, { code = 124, stderr = "query timed out\nconnection unavailable\n" })
      t.assert_contains(table.concat(state.lines(buffer), "\n"), "query timed out")
      t.assert_contains(table.concat(state.lines(buffer), "\n"), "connection unavailable")
      t.assert_eq(#state.jobs, 0)
    end)
    with_reader(function(_, state)
      state.spawn_failure = true
      local buffer = state.buffer(owned())
      t.assert_contains(table.concat(state.lines(buffer), "\n"), "spawn failed")
      t.assert_eq(#state.tasks, 0)
    end)
  end)

  t.it("joins partial chunks separately for stdout and stderr and flushes them at exit", function()
    with_reader(function(_, state)
      local buffer = state.buffer(owned())
      local options = state.jobs[1].options
      options.on_stdout(100, { "hel" })
      options.on_stdout(100, { "lo", "next" })
      options.on_stderr(100, { "warn", "last" })
      options.on_stdout(100, { " line", "" })
      options.on_exit(100, 1)
      vim.wait(10)
      local text = table.concat(state.lines(buffer), "\n")
      t.assert_contains(text, "hello\n[stderr] warn\nnext line\n[stderr] last")
      t.assert_contains(text, "idevicesyslog exited with code 1")
    end)
  end)

  t.it("caps retained output and preserves a scrolled cursor while following the last line", function()
    with_reader(function(_, state)
      local buffer = state.buffer(owned())
      local win = vim.api.nvim_get_current_win()
      local previous = vim.api.nvim_win_get_buf(win)
      vim.api.nvim_win_set_buf(win, buffer)
      local emit = state.jobs[1].options.on_stdout
      local data = {}
      for index = 1, 12000 do
        data[#data + 1] = tostring(index)
      end
      data[#data + 1] = ""
      emit(100, data)
      vim.wait(10)
      t.assert_eq(vim.api.nvim_buf_line_count(buffer), 12000)
      t.assert_eq(vim.api.nvim_win_get_cursor(win)[1], 12000)
      vim.api.nvim_win_set_cursor(win, { 100, 0 })
      emit(100, { "12001", "12002", "" })
      vim.wait(10)
      t.assert_eq(vim.api.nvim_buf_line_count(buffer), 12000)
      t.assert_eq(vim.api.nvim_win_get_cursor(win)[1], 98)
      t.assert_eq(state.lines(buffer)[12000], "12002")
      vim.api.nvim_win_set_buf(win, previous)
    end)
  end)

  t.it("isolates stopped queries and queued reader output from newer owned sessions", function()
    with_reader(function(Log, state)
      local first = owned(31, "coredevice", "CORE-A")
      local old_buffer = state.buffer(first)
      Log.stop(first)
      t.assert_eq(state.queries[1].kills, 1)
      local second = owned(32)
      local buffer = state.buffer(second)
      state.complete(details("CORE-A", "OLD-HARDWARE", "wired"))
      t.assert_eq(#state.jobs, 1)
      local callback = state.jobs[1].options.on_stdout
      callback(100, { "queued", "" })
      local before = #state.lines(buffer)
      Log.stop(second)
      local third = owned(33)
      state.buffer(third)
      Log.stop(first)
      Log.stop(nil)
      vim.wait(10)
      t.assert_eq(#state.lines(buffer), before)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(#state.jobs, 2)
      t.assert_eq(#state.lines(old_buffer), 1)
    end)
  end)

  t.it("reopens wiped logs for the same session and rejects stale reader callbacks", function()
    with_reader(function(Log, state)
      local session = owned(51)
      local old_buffer = state.buffer(session)
      local old_job = state.jobs[1]
      old_job.options.on_stdout(old_job.id, { "queued old output", "" })
      session.on_close.ue_ios_log(session)
      vim.api.nvim_buf_delete(old_buffer, { force = true })
      local buffer = state.buffer(session)
      t.assert_true(buffer ~= old_buffer)
      t.assert_eq(Log.buffer(session), buffer)
      t.assert_eq(#state.jobs, 2)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(state.stopped[1], old_job.id)
      old_job.options.on_stdout(old_job.id, { "late old output", "" })
      old_job.options.on_exit(old_job.id, 1)
      state.jobs[2].options.on_stdout(state.jobs[2].id, { "current output", "" })
      vim.wait(10)
      local text = table.concat(state.lines(buffer), "\n")
      t.assert_contains(text, "current output")
      t.assert_true(not text:find("old output", 1, true))
      t.assert_true(not text:find("exited", 1, true))
      t.assert_eq(#state.stopped, 1)
    end)
  end)

  t.it("ignores a wiped buffer's identity query after reopening the same CoreDevice session", function()
    with_reader(function(Log, state)
      local session = owned(52, "coredevice", "CORE-A")
      local old_buffer = state.buffer(session)
      vim.api.nvim_buf_delete(old_buffer, { force = true })
      local buffer = state.buffer(session)
      t.assert_eq(Log.buffer(session), buffer)
      t.assert_eq(#state.queries, 2)
      t.assert_eq(state.queries[1].kills, 1)
      state.complete(details("CORE-A", "STALE-HARDWARE", "wired"), 1)
      t.assert_eq(#state.jobs, 0)
      state.complete(details("CORE-A", "CURRENT-HARDWARE", "wired"), 2)
      t.assert_eq(#state.jobs, 1)
      t.assert_eq(state.jobs[1].argv[3], "CURRENT-HARDWARE")
      t.assert_eq(#state.stopped, 0)
    end)
  end)

  t.it("stops only the owned reader on close, buffer wipe, or editor exit without DAP actions", function()
    with_reader(function(_, state)
      local first, second = owned(41), owned(42)
      local first_buffer = state.buffer(first)
      state.buffer(second)
      first.on_close.ue_ios_log(first)
      vim.wait(10)
      t.assert_eq(#state.stopped, 1)
      t.assert_eq(state.stopped[1], state.jobs[1].id)
      t.assert_eq(first.on_close.ue_ios_log, nil)
      vim.api.nvim_buf_delete(first_buffer, { force = true })
      t.assert_eq(#state.stopped, 1)
      local third = owned(43)
      local third_buffer = state.buffer(third)
      vim.api.nvim_buf_delete(third_buffer, { force = true })
      t.assert_eq(state.stopped[2], state.jobs[3].id)
      state.autocmds[4].options.callback()
      t.assert_eq(state.stopped[3], state.jobs[2].id)
    end)
  end)
end)
