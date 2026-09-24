local M = {}
local compiler_session = require("utils.ue_goto.semantic_session")

function M.install(client, deps)
  local protocol = deps.protocol
  local state = deps.state
  local uv = deps.uv
  local SIDECAR_NAME = deps.SIDECAR_NAME
  local REQUEST_TIMEOUT_MS = deps.REQUEST_TIMEOUT_MS
  local IDLE_EVICT_MS = deps.IDLE_EVICT_MS

  local function now_ms()
    return uv.hrtime() / 1e6
  end

  local function hash_text(value)
    local ok, digest = pcall(vim.fn.sha256, tostring(value or ""))
    if ok and type(digest) == "string" and digest ~= "" then
      return digest:sub(1, 24)
    end
    return tostring(value or ""):gsub("[^%w]", "_"):sub(1, 24)
  end

  local function emit_trace(event, fields)
    if type(state.trace) ~= "function" then return end
    fields = fields or {}
    fields.event = event
    pcall(state.trace, fields)
  end

  function client.set_trace(fn)
    state.trace = fn
  end

  local function log_sidecar(level, message, context)
    local ok, log = pcall(require, "utils.log")
    if not ok then return end
    local scoped = log.scoped and log.scoped("ue.semantic") or nil
    local fn = scoped and scoped[level] or log[level .. "_ctx"] or log[level]
    if type(fn) == "function" then
      if scoped then
        pcall(fn, message, context or {})
      else
        pcall(fn, "ue.semantic", message, context or {})
      end
    end
  end

  local function record_metrics(response)
    local metrics = response and response.metrics
    if type(metrics) ~= "table" then return end
    local safe = {
      op = tostring(response.op or "?"),
      state = tostring(response.state or (response.ok and "ok" or "error")),
      total_ms = tonumber(metrics.total_ms),
      cold_parse_ms = tonumber(metrics.cold_parse_ms),
      reparse_ms = tonumber(metrics.reparse_ms),
      cursor_query_ms = tonumber(metrics.cursor_query_ms),
      warm_query_ms = tonumber(metrics.warm_query_ms),
      tu_count = tonumber(metrics.tu_count),
      process_rss_bytes = tonumber(metrics.process_rss_bytes),
      cpp_json_scanned = tonumber(metrics.cpp_json_scanned),
      depfiles_scanned = tonumber(metrics.depfiles_scanned),
      evidence_discovery = type(metrics.evidence_discovery) == "string"
        and metrics.evidence_discovery or nil,
    }
    log_sidecar("info", "semantic timing", safe)
    pcall(function()
      local phase = safe.cold_parse_ms and safe.cold_parse_ms > 0 and "cold"
        or (safe.reparse_ms and safe.reparse_ms > 0 and "reparse" or "warm")
      require("utils.probe").record("cpp-semantic-performance", phase, safe)
    end)
  end

  local function unavailable(reason, op, id, probes)
    return {
      v = protocol.VERSION,
      id = id or -1,
      op = op or "query",
      ok = true,
      state = "unavailable",
      reason = tostring(reason or "semantic sidecar unavailable"),
      probes = probes or {},
    }
  end

  local function protocol_decode(line)
    local ok, value = pcall(vim.json.decode, line)
    if not ok or type(value) ~= "table" then
      return nil, "response is not valid JSON"
    end
    local valid, decoded = protocol.validate_response(value)
    if not valid then return nil, decoded end
    return decoded
  end

  local function close_timer(timer)
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
  end

  local function arm_idle_evict()
    close_timer(state.idle_timer)
    state.idle_timer = vim.defer_fn(function()
      state.idle_timer = nil
      if not state.ready or not state.job then return end
      for _ in pairs(state.pending) do
        arm_idle_evict()
        return
      end
      client.request("evict", { all = true }, function() end, state.start_options)
    end, IDLE_EVICT_MS)
  end

  local flush_queue

  local function finish_pending(id, response)
    local pending = state.pending[id]
    if not pending then return end
    state.pending[id] = nil
    close_timer(pending.timeout)
    if pending.session then response.compiler_session = vim.deepcopy(pending.session) end
    state.last_response = response
    record_metrics(response)
    emit_trace("response", {
      request_id = id,
      context_id = response.context_id,
      provider = response.op == "query" and "libclang" or "sidecar",
      usr = response.usr,
      terminal_state = response.state or (response.ok and "ok" or "error"),
      elapsed_ms = math.floor(now_ms() - pending.started_ms),
    })
    if response.op ~= "handshake" and response.op ~= "evict" and response.op ~= "shutdown" then
      arm_idle_evict()
    end
    vim.schedule(function() pending.callback(response) end)
    vim.schedule(function() flush_queue() end)
  end

  local function consume_stdout_line(line)
    if line == "" then return end
    local response, err = protocol_decode(line)
    if not response then
      log_sidecar("error", "discarded invalid sidecar response", { reason = err })
      return
    end
    finish_pending(response.id, response)
  end

  local function consume_stdout(data)
    if type(data) ~= "table" or #data == 0 then return end
    local first = state.stdout_tail .. (data[1] or "")
    if #data == 1 then
      state.stdout_tail = first
      return
    end
    consume_stdout_line(first)
    for i = 2, #data - 1 do consume_stdout_line(data[i] or "") end
    state.stdout_tail = data[#data] or ""
  end

  client._consume_stdout_for_test = consume_stdout

  local function abort_stuck_process()
    close_timer(state.idle_timer)
    state.idle_timer = nil
    local job = state.job
    if not job then
      state.ready, state.starting, state.stopping = false, false, false
      return
    end
    state.stopping = true
    pcall(vim.fn.jobstop, job)
  end

  local function expire_pending(pending)
    local id = pending and pending.payload and pending.payload.id
    if not id or state.pending[id] ~= pending then return false end
    state.pending[id] = nil
    close_timer(pending.timeout)
    emit_trace("response", {
      request_id = id,
      provider = "sidecar",
      terminal_state = "unavailable",
      stale_reason = "request-timeout",
      elapsed_ms = math.floor(now_ms() - pending.started_ms),
    })
    abort_stuck_process()
    pending.callback(unavailable("semantic sidecar request timed out", pending.payload.op, id))
    return true
  end

  local function arm_timeout(pending)
    pending.timeout = vim.defer_fn(function() expire_pending(pending) end, REQUEST_TIMEOUT_MS)
  end

  local function send_pending(pending)
    if not state.job or state.job <= 0 then return false end
    if next(state.pending) ~= nil then return false end
    close_timer(state.idle_timer)
    state.idle_timer = nil
    local ok_encode, encoded = pcall(protocol.encode, pending.payload)
    if not ok_encode then return false end
    if #encoded - 1 > protocol.MAX_LINE_BYTES then return false, "request-too-large" end
    local ok_write, written = pcall(vim.fn.chansend, state.job, encoded)
    if not ok_write or not written or written <= 0 then return false end
    pending.started_ms = now_ms()
    pending.session = state.session
    state.pending[pending.payload.id] = pending
    arm_timeout(pending)
    emit_trace("request", {
      request_id = pending.payload.id,
      context_id = pending.payload.contexts and pending.payload.contexts[1]
        and pending.payload.contexts[1].id,
      provider = pending.payload.op == "query" and "libclang" or "sidecar",
    })
    return true
  end

  local function queued_action_current(pending)
    if pending.is_current then return pending.is_current() end
    return true
  end

  function client.cancel_queued_actions()
    local retained = {}
    for _, pending in ipairs(state.queued) do
      local current, reason = queued_action_current(pending)
      if current then
        retained[#retained + 1] = pending
      else
        vim.schedule(function()
          pending.callback(unavailable(reason or "superseded", pending.payload.op, pending.payload.id))
        end)
      end
    end
    state.queued = retained
  end

  flush_queue = function()
    if not state.ready or state.stopping or next(state.pending) ~= nil then return end
    client.cancel_queued_actions()
    while #state.queued > 0 do
      local pending = table.remove(state.queued, 1)
      local compatible = not pending.options or not state.session
        or compiler_session.same_requested(pending.options, state.session.requested)
      local sent, write_reason
      if compatible then sent, write_reason = send_pending(pending) end
      if sent then return end
      vim.schedule(function()
        pending.callback(unavailable(compatible and (write_reason or "failed to write sidecar request")
          or "compiler-session-toolchain-mismatch",
          pending.payload.op, pending.payload.id))
      end)
    end
  end

  local function sidecar_script()
    return vim.fs.joinpath(vim.fn.stdpath("config"), "scripts", "ue_clang_semanticd.lua")
  end

  local start_process

  local function fail_all(reason)
    local callbacks = {}
    for id, pending in pairs(state.pending) do
      state.pending[id] = nil
      close_timer(pending.timeout)
      if pending.payload.op ~= "handshake" then callbacks[#callbacks + 1] = pending end
    end
    for _, pending in ipairs(state.queued) do callbacks[#callbacks + 1] = pending end
    state.queued = {}
    for _, pending in ipairs(callbacks) do
      vim.schedule(function()
        pending.callback(unavailable(reason, pending.payload.op, pending.payload.id))
      end)
    end
  end

  local function schedule_start(options)
    local ticket = state.lifecycle_generation
    vim.schedule(function()
      if ticket ~= state.lifecycle_generation then return end
      local ok, started = pcall(start_process, options)
      if not ok or not started then
        state.starting = false
        fail_all("failed to restart semantic sidecar")
        abort_stuck_process()
      end
    end)
  end

  local function on_exit(job, code)
    if job ~= state.job then return end
    state.session = nil
    close_timer(state.idle_timer)
    state.idle_timer = nil
    close_timer(state.stop_timer)
    state.stop_timer = nil
    if state.stopping then
      local callbacks = {}
      for id, pending in pairs(state.pending) do
        state.pending[id] = nil
        close_timer(pending.timeout)
        if pending.payload.op ~= "shutdown" and pending.payload.op ~= "handshake" then
          callbacks[#callbacks + 1] = pending
        end
      end
      local restart_options = state.restart_options
      state.restart_options = nil
      if not restart_options then
        for _, pending in ipairs(state.queued) do callbacks[#callbacks + 1] = pending end
        state.queued = {}
      end
      state.job, state.ready, state.starting, state.stdout_tail = nil, false, false, ""
      state.stopping = false
      for _, pending in ipairs(callbacks) do
        vim.schedule(function()
          pending.callback(unavailable("semantic sidecar stopped",
            pending.payload.op, pending.payload.id, { exit_code = code }))
        end)
      end
      log_sidecar("info", "semantic sidecar stopped", { code = code })
      if restart_options then schedule_start(restart_options) end
      return
    end
    local retry = {}
    for id, pending in pairs(state.pending) do
      state.pending[id] = nil
      close_timer(pending.timeout)
      if pending.payload.op ~= "handshake" then
        if (pending.restarts or 0) < 1 then
          pending.restarts = (pending.restarts or 0) + 1
          retry[#retry + 1] = pending
        else
          vim.schedule(function()
            pending.callback(unavailable("semantic sidecar exited after restart",
              pending.payload.op, pending.payload.id, { exit_code = code }))
          end)
        end
      end
    end
    for _, pending in ipairs(state.queued) do retry[#retry + 1] = pending end
    state.queued = retry
    state.job, state.ready, state.starting, state.stdout_tail = nil, false, false, ""
    log_sidecar(code == 0 and "info" or "error", "semantic sidecar exited", { code = code })
    if #retry > 0 and not state.restart_used then
      state.restart_used = true
      schedule_start(state.start_options)
    elseif #retry > 0 then
      fail_all("semantic sidecar unavailable after one restart")
    end
  end

  start_process = function(options)
    if state.stopping then return false end
    if state.job or state.starting then return true end
    options = options or state.start_options
    if not options or not options.clangd_path then return false end
    options = compiler_session.requested(options)
    local script = sidecar_script()
    if not uv.fs_stat(script) then return false end

    state.starting = true
    state.start_options = options
    state.session_generation = (state.session_generation or 0) + 1
    local session_generation = state.session_generation
    local job = vim.fn.jobstart({
      vim.v.progpath, "--headless", "-u", "NONE", "-l", script,
    }, {
      stdin = "pipe",
      stdout_buffered = false,
      stderr_buffered = false,
      env = { UE_CLANGD = options.clangd_path },
      on_stdout = function(job_id, data)
        if job_id == state.job then consume_stdout(data) end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data or {}) do
          if line and line ~= "" then
            log_sidecar("error", "sidecar stderr", { message = line })
          end
        end
      end,
      on_exit = on_exit,
    })
    state.job = job > 0 and job or nil
    state.starting = false
    if not state.job then return false end

    local ok_registry, registry = pcall(require, "utils.task_registry")
    if ok_registry then
      pcall(registry.register, {
        name = SIDECAR_NAME,
        group = "semantic",
        kind = "job",
        handle = state.job,
        started_at = os.time(),
      })
    end

    state.next_request_id = state.next_request_id + 1
    local handshake = {
      payload = { v = protocol.VERSION, id = state.next_request_id, op = "handshake" },
      callback = function(response)
        if state.stopping or state.job ~= job or state.session_generation ~= session_generation then return end
        if not response.ok then
          fail_all(response.reason or "semantic sidecar handshake failed")
          abort_stuck_process()
          return
        end
        local session, err = compiler_session.bind(options, response.toolchain, session_generation)
        if not session then
          fail_all(err)
          abort_stuck_process()
          return
        end
        state.session = session
        state.ready = true
        state.restart_used = false
        flush_queue()
      end,
      restarts = 0,
    }
    return send_pending(handshake)
  end

  function client.request(op, fields, callback, options, is_current)
    callback = callback or function() end
    state.next_request_id = state.next_request_id + 1
    local payload = vim.tbl_extend("force", fields or {}, {
      v = protocol.VERSION,
      id = state.next_request_id,
      op = op,
    })
    if state.stopping and not state.restart_options then
      vim.schedule(function()
        callback(unavailable("semantic sidecar is stopping", op, payload.id))
      end)
      return payload.id
    end
    local pending = { payload = payload, callback = callback, restarts = 0,
      is_current = is_current, options = options and compiler_session.requested(options) }
    state.queued[#state.queued + 1] = pending
    if state.stopping then return payload.id end
    if state.ready then
      flush_queue()
      return payload.id
    end
    if not start_process(options or state.start_options) then
      state.queued[#state.queued] = nil
      vim.schedule(function()
        callback(unavailable("failed to start semantic sidecar", op, payload.id))
      end)
    end
    return payload.id
  end

  function client.status()
    local pending_count = 0
    for _ in pairs(state.pending) do pending_count = pending_count + 1 end
    return {
      running = state.job ~= nil,
      ready = state.ready,
      stopping = state.stopping,
      pending = pending_count,
      queued = #state.queued,
      session = state.session and vim.deepcopy(state.session),
      last_state = state.last_response and (state.last_response.state or state.last_response.op),
      tu_count = state.last_response and state.last_response.metrics
        and state.last_response.metrics.tu_count,
    }
  end

  function client.stop()
    state.lifecycle_generation = (state.lifecycle_generation or 0) + 1
    state.restart_options = nil
    close_timer(state.idle_timer)
    state.idle_timer = nil
    if state.stopping then return end
    local job = state.job
    if not job then
      fail_all("semantic sidecar stopped")
      state.ready, state.starting = false, false
      return
    end
    state.stopping = true
    if state.ready then
      state.next_request_id = state.next_request_id + 1
      local sent = send_pending({
        payload = {
          v = protocol.VERSION,
          id = state.next_request_id,
          op = "shutdown",
        },
        callback = function() end,
        restarts = 1,
      })
      if not sent then pcall(vim.fn.jobstop, job) end
    else
      pcall(vim.fn.jobstop, job)
    end
    close_timer(state.stop_timer)
    state.stop_timer = vim.defer_fn(function()
      state.stop_timer = nil
      if state.stopping and state.job == job then pcall(vim.fn.jobstop, job) end
    end, 1000)
  end

  function client.restart(options)
    fail_all("semantic compiler session changed")
    client.stop()
    if state.job then
      state.restart_options = options
    else
      schedule_start(options)
    end
  end

  function client._inject_pending_for_test(id, callback)
    state.pending[id] = {
      payload = { v = protocol.VERSION, id = id, op = "query" },
      callback = callback,
      started_ms = now_ms(),
    }
  end

  function client._expire_pending_for_test(id)
    return expire_pending(state.pending[id])
  end

  function client._set_process_for_test(job, ready)
    state.job = job
    state.ready = ready == true
  end

  local function reset()
    for _, pending in pairs(state.pending) do close_timer(pending.timeout) end
    close_timer(state.idle_timer)
    close_timer(state.stop_timer)
    if state.job then pcall(vim.fn.jobstop, state.job) end
    state.job = nil
    state.stdout_tail = ""
    state.pending = {}
    state.queued = {}
    state.next_request_id = 0
    state.lifecycle_generation = (state.lifecycle_generation or 0) + 1
    state.session = nil
    state.restart_options = nil
    state.ready = false
    state.starting = false
    state.stopping = false
    state.restart_used = false
    state.start_options = nil
    state.trace = nil
    state.idle_timer = nil
    state.stop_timer = nil
    state.last_response = nil
  end


  return {
    now_ms = now_ms,
    hash_text = hash_text,
    emit_trace = emit_trace,
    unavailable = unavailable,
    close_timer = close_timer,
    reset = reset,
    IDLE_EVICT_MS = IDLE_EVICT_MS,
    REQUEST_TIMEOUT_MS = REQUEST_TIMEOUT_MS,
  }
end

return M
