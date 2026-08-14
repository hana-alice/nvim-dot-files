local M = {}

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

  local function finish_pending(id, response)
    local pending = state.pending[id]
    if not pending then return end
    state.pending[id] = nil
    close_timer(pending.timeout)
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

  local function arm_timeout(pending)
    pending.timeout = vim.defer_fn(function()
      local id = pending.payload.id
      if state.pending[id] ~= pending then return end
      state.pending[id] = nil
      emit_trace("response", {
        request_id = id,
        provider = "sidecar",
        terminal_state = "unavailable",
        stale_reason = "request-timeout",
        elapsed_ms = math.floor(now_ms() - pending.started_ms),
      })
      pending.callback(unavailable("semantic sidecar request timed out", pending.payload.op, id))
    end, REQUEST_TIMEOUT_MS)
  end

  local function send_pending(pending)
    if not state.job or state.job <= 0 then return false end
    close_timer(state.idle_timer)
    state.idle_timer = nil
    local ok_encode, encoded = pcall(protocol.encode, pending.payload)
    if not ok_encode then return false end
    local ok_write, written = pcall(vim.fn.chansend, state.job, encoded)
    if not ok_write or not written or written <= 0 then return false end
    pending.started_ms = now_ms()
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

  local function flush_queue()
    if not state.ready then return end
    local queue = state.queued
    state.queued = {}
    for _, pending in ipairs(queue) do
      if not send_pending(pending) then
        vim.schedule(function()
          pending.callback(unavailable("failed to write sidecar request",
            pending.payload.op, pending.payload.id))
        end)
      end
    end
  end

  local function resolve_executable(candidate)
    if not candidate or candidate == "" then return nil end
    if uv.fs_stat(candidate) then return vim.fs.normalize(candidate) end
    local found = vim.fn.exepath(candidate)
    return found ~= "" and vim.fs.normalize(found) or nil
  end

  local function sibling_libclang(clangd)
    if not clangd then return nil end
    local bin = vim.fs.dirname(clangd)
    local parent = vim.fs.dirname(bin)
    for _, candidate in ipairs({
      vim.fs.joinpath(bin, "libclang.dll"),
      vim.fs.joinpath(bin, "libclang.so"),
      vim.fs.joinpath(bin, "libclang.dylib"),
      vim.fs.joinpath(parent, "lib", "libclang.so"),
      vim.fs.joinpath(parent, "lib", "libclang.dylib"),
    }) do
      if uv.fs_stat(candidate) then return vim.fs.normalize(candidate) end
    end
    return nil
  end

  local function first_cdb(ctx)
    local ok, paths = pcall(require, "ue.cdb.paths")
    local candidates = ok and paths.targets(ctx) or {
      vim.fs.joinpath(ctx.engine_root, "compile_commands.json"),
    }
    if ctx.project_root then
      candidates[#candidates + 1] = vim.fs.joinpath(ctx.project_root, "compile_commands.json")
    end
    for _, path in ipairs(candidates) do
      local stat = uv.fs_stat(path)
      if stat and stat.type == "file" then return vim.fs.normalize(path), stat end
    end
    return nil
  end

  local function read_json_file(path)
    if not path or path == "" then return nil end
    local fd = io.open(path, "rb")
    if not fd then return nil end
    local content = fd:read("*a")
    fd:close()
    local ok, decoded = pcall(vim.json.decode, content or "")
    if ok and type(decoded) == "table" then
      return decoded
    end
    return nil
  end

  local function file_identity(path)
    path = path and vim.fs.normalize(path) or ""
    if path == "" then
      return { path = "", size = 0, mtime = 0 }
    end
    local stat = uv.fs_stat(path)
    return {
      path = path,
      size = stat and tonumber(stat.size) or 0,
      mtime = stat and stat.mtime and tonumber(stat.mtime.sec) or 0,
    }
  end

  local function controlled_phase_manifests(ctx, generation_id)
    if type(ctx) ~= "table" or type(ctx.paths) ~= "table"
        or type(generation_id) ~= "string" or generation_id == "" then
      return {}
    end
    local matches = {}
    for _, phase in ipairs({ "current", "hot", "full" }) do
      local index_path = ctx.paths[phase .. "_index"]
      if type(index_path) == "string" and index_path ~= "" then
        local normalized_index_path = vim.fs.normalize(index_path)
        local manifest_path = normalized_index_path .. ".manifest.json"
        local manifest = read_json_file(manifest_path)
        if type(manifest) == "table"
            and tostring(manifest.generation_id or "") == generation_id
            and tostring(manifest.index_kind or "") == "controlled-background"
            and vim.fs.normalize(tostring(manifest.index_path or "")) == normalized_index_path
            and tostring(manifest.phase or "") == phase
            and tostring(manifest.coverage_level or "") == phase
        then
          local background_cdb_path = vim.fs.normalize(tostring(manifest.background_cdb_path or ""))
          local background_stat = uv.fs_stat(background_cdb_path)
          if background_cdb_path ~= "" and background_stat and background_stat.type == "file" then
            matches[#matches + 1] = {
              phase = phase,
              manifest = manifest,
              manifest_path = manifest_path,
              background_cdb_path = background_cdb_path,
              manifest_identity = file_identity(manifest_path),
              background_identity = file_identity(background_cdb_path),
            }
          end
        end
      end
    end
    return matches
  end

  local function active_build(ctx, index_snapshot)
    local persisted = ctx.state or {}
    local result = {
      platform = tostring(persisted.target_platform or ""),
      configuration = tostring(persisted.target_configuration or ""),
      target = tostring(persisted.target or persisted.target_name or ""),
    }
    local key = table.concat({ result.platform, result.target, result.configuration }, "|")
    local active_cdb_path
    local active_manifest_path
    local controlled_candidates = {}
    local ok, shards = pcall(require, "ue.cdb.shards")
    if ok then
      local manifest_path = vim.fs.joinpath(shards.shards_dir(ctx), "manifest.json")
      local manifest = shards.read_manifest(ctx)
      local active = shards.active_key(ctx, manifest)
      local metadata = manifest and manifest.shards and manifest.shards[active]
      if active and active ~= "" then key = active end
      if active and active ~= "" then
        -- Keep the explicit paths even when an artifact is missing: the
        -- sidecar must report an unreadable selected shard/manifest instead
        -- of silently treating the merged CDB as its own provenance proof.
        active_cdb_path = vim.fs.normalize(shards.shard_path(ctx, active))
        active_manifest_path = vim.fs.normalize(manifest_path)
      end
      if metadata then
        result.platform = tostring(metadata.platform or result.platform)
        result.configuration = tostring(metadata.config or result.configuration)
        result.target = tostring(metadata.target or result.target)
      end
    end
    controlled_candidates = controlled_phase_manifests(ctx,
      type(index_snapshot) == "table" and tostring(index_snapshot.generation_id or "") or "")
    return key, result, active_cdb_path, active_manifest_path, controlled_candidates
  end

  local function evidence_roots(ctx, build)
    local roots, seen = {}, {}
    local function add(path)
      path = path and vim.fs.normalize(path) or nil
      if path and path ~= "" and uv.fs_stat(path) and not seen[path:lower()] then
        seen[path:lower()] = true
        roots[#roots + 1] = path
      end
    end
    local suffix = build.platform ~= "" and build.platform or nil
    add(vim.fs.joinpath(ctx.engine_root, "Engine", "Intermediate", "Build", suffix or ""))
    if ctx.project_root then
      add(vim.fs.joinpath(ctx.project_root, "Intermediate", "Build", suffix or ""))
    end
    if ctx.uproject and ctx.uproject ~= "" then
      add(vim.fs.joinpath(vim.fs.dirname(ctx.uproject), "Intermediate", "Build", suffix or ""))
    end
    return roots
  end

  function client.discover_toolchain(bufnr)
    local ok_ue, ue = pcall(require, "ue")
    if not ok_ue or type(ue.resolve_context) ~= "function" then
      return nil, "UE context API unavailable"
    end
    local bufname = vim.api.nvim_buf_get_name(bufnr or 0)
    local ctx, err = ue.resolve_context({ bufname = bufname ~= "" and bufname or nil })
    if not ctx then return nil, err or "UE context unavailable" end

    local clangd_cmd = type(ue.clangd_cmd) == "function" and ue.clangd_cmd(ctx.engine_root) or nil
    local clangd = resolve_executable(type(clangd_cmd) == "table" and clangd_cmd[1] or clangd_cmd)
    if not clangd then return nil, "clangd executable unavailable" end
    local libclang = sibling_libclang(clangd)
    if not libclang then return nil, "matching libclang unavailable next to clangd" end
    local cdb_path, cdb_stat = first_cdb(ctx)
    if not cdb_path then return nil, "active compile_commands.json unavailable" end
    local index_snapshot = type(ue.semantic_index_snapshot) == "function"
      and ue.semantic_index_snapshot({ bufname = bufname, subject_path = bufname }) or nil

    local build_key, build, active_cdb_path, active_manifest_path, controlled_candidates
      = active_build(ctx, index_snapshot)
    active_cdb_path = active_cdb_path or cdb_path
    local active_cdb_stat = uv.fs_stat(active_cdb_path)
    local active_manifest_stat = active_manifest_path and uv.fs_stat(active_manifest_path) or nil
    local state_stat = ctx.paths and ctx.paths.state and uv.fs_stat(ctx.paths.state) or nil
    local controlled_signature = {}
    for _, candidate in ipairs(controlled_candidates or {}) do
      controlled_signature[#controlled_signature + 1] = {
        phase = candidate.phase,
        manifest = candidate.manifest_identity,
        background = candidate.background_identity,
      }
    end
    local build_fingerprint = hash_text(vim.json.encode({
      tostring(ctx.project_root or ""), build_key, cdb_path,
      tostring(cdb_stat.mtime and cdb_stat.mtime.sec or 0), tostring(cdb_stat.size or 0),
      active_cdb_path,
      tostring(active_cdb_stat and active_cdb_stat.mtime and active_cdb_stat.mtime.sec or 0),
      tostring(active_cdb_stat and active_cdb_stat.size or 0),
      tostring(active_manifest_path or ""),
      tostring(active_manifest_stat and active_manifest_stat.mtime
        and active_manifest_stat.mtime.sec or 0),
      tostring(active_manifest_stat and active_manifest_stat.size or 0),
      tostring(state_stat and state_stat.mtime and state_stat.mtime.sec or 0),
      clangd, libclang,
      index_snapshot and index_snapshot.generation_id or "",
      index_snapshot and index_snapshot.artifact_fingerprint or "",
      controlled_signature,
    }))

    if state.last_build_fingerprint and state.last_build_fingerprint ~= build_fingerprint then
      client.clear_contexts()
      if state.ready then
        client.request("evict", { all = true }, function() end, state.start_options)
      end
    end
    state.last_build_fingerprint = build_fingerprint

    local semantic_cdb_paths = {}
    for _, candidate in ipairs(controlled_candidates or {}) do
      semantic_cdb_paths[#semantic_cdb_paths + 1] = candidate.background_cdb_path
    end

    return {
      project_root = ctx.project_root or ctx.engine_root,
      engine_root = ctx.engine_root,
      active_build_key = build_key,
      active_build = build,
      cdb_dir = vim.fs.dirname(cdb_path),
      cdb_path = cdb_path,
      active_cdb_path = active_cdb_path,
      active_manifest_path = active_manifest_path,
      clangd_path = clangd,
      libclang_path = libclang,
      toolchain_identity = hash_text(vim.json.encode({ clangd, libclang })),
      build_fingerprint = build_fingerprint,
      index = index_snapshot or {
        generation_id = "",
        artifact_fingerprint = "",
        coverage_level = "",
        readiness = "missing",
        freshness = "missing",
        partial = true,
        complete = false,
      },
      controlled_cdb_path = controlled_candidates[1] and controlled_candidates[1].background_cdb_path or nil,
      controlled_manifest_path = controlled_candidates[1] and controlled_candidates[1].manifest_path or nil,
      controlled_candidates = controlled_candidates,
      semantic_cdb_paths = semantic_cdb_paths,
      evidence_roots = evidence_roots(ctx, build),
    }
  end

  function client.index_snapshot_is_current(expected, bufnr)
    if type(expected) ~= "table" then return true end
    local ok_ue, ue = pcall(require, "ue")
    if not ok_ue or type(ue.semantic_index_snapshot) ~= "function" then
      return false, "index-status-unavailable"
    end
    local bufname = vim.api.nvim_buf_get_name(bufnr or 0)
    local current = ue.semantic_index_snapshot({
      bufname = bufname ~= "" and bufname or nil,
      subject_path = bufname,
    })
    if type(current) ~= "table" then return false, "index-status-unavailable" end
    if tostring(current.generation_id or "") ~= tostring(expected.generation_id or "") then
      return false, "index-generation-changed"
    end
    if tostring(current.artifact_fingerprint or "")
        ~= tostring(expected.artifact_fingerprint or "") then
      return false, "index-base-changed"
    end
    return true
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

  local function on_exit(_, code)
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
      for _, pending in ipairs(state.queued) do callbacks[#callbacks + 1] = pending end
      state.queued = {}
      state.job, state.ready, state.starting, state.stdout_tail = nil, false, false, ""
      state.stopping = false
      for _, pending in ipairs(callbacks) do
        vim.schedule(function()
          pending.callback(unavailable("semantic sidecar stopped",
            pending.payload.op, pending.payload.id, { exit_code = code }))
        end)
      end
      log_sidecar("info", "semantic sidecar stopped", { code = code })
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
      vim.schedule(function() start_process(state.start_options) end)
    elseif #retry > 0 then
      fail_all("semantic sidecar unavailable after one restart")
    end
  end

  start_process = function(options)
    if state.stopping then return false end
    if state.job or state.starting then return true end
    options = options or state.start_options
    if not options or not options.clangd_path then return false end
    local script = sidecar_script()
    if not uv.fs_stat(script) then return false end

    state.starting = true
    state.start_options = options
    local job = vim.fn.jobstart({
      vim.v.progpath, "--headless", "-u", "NONE", "-l", script,
    }, {
      stdin = "pipe",
      stdout_buffered = false,
      stderr_buffered = false,
      env = { UE_CLANGD = options.clangd_path },
      on_stdout = function(_, data) consume_stdout(data) end,
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
        if state.stopping then return end
        if not response.ok then
          fail_all(response.reason or "semantic sidecar handshake failed")
          return
        end
        state.ready = true
        state.restart_used = false
        flush_queue()
      end,
      restarts = 0,
    }
    return send_pending(handshake)
  end

  function client.request(op, fields, callback, options)
    callback = callback or function() end
    state.next_request_id = state.next_request_id + 1
    local payload = vim.tbl_extend("force", fields or {}, {
      v = protocol.VERSION,
      id = state.next_request_id,
      op = op,
    })
    if state.stopping then
      vim.schedule(function()
        callback(unavailable("semantic sidecar is stopping", op, payload.id))
      end)
      return payload.id
    end
    local pending = { payload = payload, callback = callback, restarts = 0 }
    if state.ready then
      if not send_pending(pending) then
        vim.schedule(function()
          callback(unavailable("failed to write sidecar request", op, payload.id))
        end)
      end
      return payload.id
    end
    state.queued[#state.queued + 1] = pending
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
      build_fingerprint = state.last_build_fingerprint,
      last_state = state.last_response and (state.last_response.state or state.last_response.op),
      tu_count = state.last_response and state.last_response.metrics
        and state.last_response.metrics.tu_count,
    }
  end

  function client.stop()
    client.cancel_action()
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

  function client._inject_pending_for_test(id, callback)
    state.pending[id] = {
      payload = { v = protocol.VERSION, id = id, op = "query" },
      callback = callback,
      started_ms = now_ms(),
    }
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
    state.next_action_token = 0
    state.active_action_token = 0
    state.ready = false
    state.starting = false
    state.stopping = false
    state.restart_used = false
    state.start_options = nil
    state.trace = nil
    state.idle_timer = nil
    state.stop_timer = nil
    state.last_build_fingerprint = nil
    state.last_response = nil
  end

  client._discover_controlled_phase_manifests_for_test = controlled_phase_manifests

  return {
    now_ms = now_ms,
    hash_text = hash_text,
    emit_trace = emit_trace,
    unavailable = unavailable,
    close_timer = close_timer,
    reset = reset,
    IDLE_EVICT_MS = IDLE_EVICT_MS,
  }
end

return M
