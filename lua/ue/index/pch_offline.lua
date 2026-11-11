-- Optional private PCH producer. The ordinary clangd reader/command stays owned
-- by the existing delivery path; failures always return to that path.
return function(M, core)
  local config = require("ue.config")
  local fs = require("ue.core.fs")
  local capability

  local function settings()
    local value = config.get("index.pch_offline")
    return type(value) == "table" and value or { enabled = value ~= false }
  end

  local function failure(reason)
    local result = { ok = false, error = tostring(reason) }
    pcall(function()
      require("utils.probe").record("index-pch-offline", result.error, {
        state = "failed", reason = result.error,
      })
    end)
    pcall(function()
      require("utils.log").warn_ctx("ue.index", "PCH offline fallback", { reason = result.error })
    end)
    return result
  end

  local function stamp(path)
    local stat = vim.uv.fs_stat(path)
    if not stat or stat.type ~= "file" then return "missing", false end
    return table.concat({ stat.size, stat.mtime.sec, stat.mtime.nsec }, ":"), true
  end

  M.probe_pch_offline = function(callback)
    local opts = settings()
    if opts.enabled == false then callback({ ok = false, disabled = true }); return end
    local directory = vim.fn.expand(opts.bin_dir or "~/.cache/clangd-pch-22.1.5/metadata-v24c/bin")
    local suffix = tostring(require("utils.platform").driver().exe_suffix or "")
    local clangd = vim.fs.joinpath(directory, "clangd" .. suffix)
    local probe = vim.fs.joinpath(directory, "clangd-pch-probe" .. suffix)
    local clangd_stamp, has_clangd = stamp(clangd)
    local probe_stamp, has_probe = stamp(probe)
    local identity = table.concat({ directory, clangd_stamp, probe_stamp }, "\n")
    if capability and capability.identity == identity then
      if capability.result then callback(capability.result)
      else capability.waiters[#capability.waiters + 1] = callback end
      return
    end
    local current = { identity = identity, waiters = { callback } }
    capability = current
    local function finish(result)
      current.result = result
      for _, waiter in ipairs(current.waiters) do waiter(result) end
      current.waiters = nil
    end
    if not has_clangd or not has_probe then
      finish(failure("private-binaries-missing"))
      return
    end
    local invoked, err = pcall(vim.system, { clangd, "--version" }, { text = true, timeout = 5000 }, function(result)
      vim.schedule(function()
        if result.code == 0 and (result.stdout or ""):match("clangd version") then
          finish({ ok = true, bin_dir = directory, identity = identity })
        else
          finish(failure("private-clangd-version-failed:" .. tostring(result.code)))
        end
      end)
    end)
    if not invoked then finish(failure("private-clangd-version-spawn:" .. tostring(err))) end
  end

  local function system(command, opts, timeout_ms, callback)
    local invoked, err = pcall(vim.system, command, {
      text = true, cwd = opts.cwd, env = opts.env, clear_env = opts.env ~= nil, timeout = timeout_ms,
    }, function(result) vim.schedule(function() callback(result) end) end)
    if not invoked then callback({ code = -1, spawn_error = true, stderr = tostring(err) }) end
  end

  local function read_json(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local raw = file:read("*a"); file:close()
    local ok, value = pcall(vim.json.decode, raw)
    return ok and type(value) == "table" and value or nil
  end

  local function tier1_probe(key, data)
    pcall(function()
      require("utils.probe").record("index-pch-offline-tier1", key, data)
    end)
  end

  local function proof_command(request, tier1, arguments)
    local command = { request.python, "-u", fs.join(config.get("cdb.tools_dir"), "cdb_background_batch.py") }
    vim.list_extend(command, arguments)
    vim.list_extend(command, { "--clangd", tier1.clangd })
    if tier1.profile then vim.list_extend(command, { "--server-profile", vim.json.encode(tier1.profile) }) end
    return command
  end

  -- Plan the same ordinary Tier 1 groups the background proof would schedule.
  -- Any failure only disables absorption; the PCH producer still runs.
  local function plan_tier1(ctx, request, callback)
    local tier1 = request.tier1
    if type(tier1) ~= "table" or not tier1.background or not tier1.store then callback(nil); return end
    local source = tier1.background .. ".semantic.json"
    if not vim.uv.fs_stat(source) then callback(nil, "tier1-source-missing"); return end
    local base = M.base_compile_commands_path(ctx)
    local generation = base and core.h.generation_for_context(ctx, { base_cdb_path = base })
    if not generation or generation.pending or generation.failed then
      callback(nil, "tier1-generation-unavailable"); return
    end
    local control = fs.join(vim.fs.dirname(tier1.store), "background-control")
    fs.ensure_dir(control)
    local plan_path = fs.join(control, "plan.json")
    system(proof_command(request, tier1, { "--plan", source, "--store", tier1.store, "--out", plan_path,
      "--auto-tier1-large" }), { cwd = ctx.engine_root, env = request.env }, 600000, function(result)
      local plan = result.code == 0 and read_json(plan_path) or nil
      if not plan or plan.schema ~= 1 or type(plan.input_sha256) ~= "string" then
        callback(nil, "tier1-plan-failed:" .. tostring(result.code) .. ":" .. tostring(result.stderr or ""):sub(1, 200))
        return
      end
      callback({ plan = plan_path, input_sha256 = plan.input_sha256, source = source, base = base,
        base_signature = core.h.file_signature(base), generation = generation, control = control })
    end)
  end

  -- Admit the offline-accepted receipts through the ordinary cache-only collect
  -- and isolated publication worker while this full build still owns the lease.
  local function publish_tier1(ctx, request, planned, report, callback)
    local tier1 = request.tier1
    local accepted = type(report.tier1_accepted_ids) == "table" and report.tier1_accepted_ids or {}
    if report.tier1_error then
      callback({ ok = false, reason = "tier1-prepare:" .. tostring(report.tier1_error):sub(1, 200) }); return
    end
    if #accepted == 0 then callback({ ok = true, skipped = true, reason = "no-accepted-groups" }); return end
    local generation = planned.generation
    local publication_request = { schema = 1, ctx = { engine_root = ctx.engine_root, project_root = ctx.project_root,
        paths = ctx.paths, state = ctx.state }, base = planned.base, base_signature = planned.base_signature,
      generation_id = generation.generation_id, generation = generation, source = planned.source,
      marker = tier1.marker, background = tier1.background,
      publication_result = fs.join(planned.control, "activation.json"),
      lease = tier1.lease, owner_pid = vim.fn.getpid(), source_sha256 = planned.input_sha256 }
    local request_path = fs.join(planned.control, "activation-request.json")
    local file = io.open(request_path, "wb")
    local wrote = file and file:write(vim.json.encode(publication_request))
    if not file or not wrote or not file:close() then
      callback({ ok = false, reason = "tier1-activation-request-write-failed" }); return
    end
    local collect_path = fs.join(planned.control, "collection.json")
    system(proof_command(request, tier1, { "--collect", planned.plan, "--completed", vim.json.encode(accepted),
      "--background", tier1.background, "--marker", tier1.marker, "--out", collect_path,
      "--publish-request", request_path, "--nvim", vim.v.progpath,
      "--publish-worker", fs.join(vim.fn.stdpath("config"), "lua", "ue", "index", "batch_publish_worker.lua") }),
      { cwd = ctx.engine_root, env = request.env }, 600000, function(result)
        local collected = result.code == 0 and read_json(collect_path) or nil
        if not collected or not collected.ok then
          callback({ ok = false, reason = "tier1-collect-failed:" .. tostring(result.code) .. ":"
            .. tostring(result.stderr or ""):sub(1, 200) }); return
        end
        if core.h.file_signature(planned.base) ~= planned.base_signature then
          callback({ ok = false, reason = "tier1-base-changed" }); return
        end
        local applied, publication = pcall(M.apply_background_activation, ctx, generation, collected.activation,
          { probe = tier1_probe, drain = false, restart = false })
        if not applied then callback({ ok = false, reason = "tier1-activation:" .. tostring(publication) }); return end
        local revalidated = collected.revalidated_completed or {}
        callback({ ok = true, accepted = #accepted, revalidated = #revalidated,
          collect_accepted = collected.metrics and collected.metrics.collect_accepted_count or nil,
          changed = type(publication) == "table" and publication.changed or nil })
      end)
  end

  local function run_tool(ctx, request, probed, planned, callback)
    local script = vim.fs.joinpath(config.get("cdb.tools_dir"), "clangd_pch_offline.py")
    if not request.python or not vim.uv.fs_stat(script) then
      callback(failure("offline-tool-unavailable")); return
    end
    local jobs = tonumber(request.jobs) or require("ue.clangd_jobs").resolve()
    for index, arg in ipairs(request.command or {}) do
      local value = type(arg) == "string" and arg:match("^%-j=(%d+)$")
      if arg == "-j" then value = request.command[index + 1] end
      if tonumber(value) then jobs = tonumber(value) end
    end
    jobs = math.max(1, math.floor(jobs))
    local timeout = math.max(1, tonumber(settings().timeout_s) or 1800)
    local command = { request.python, "-u", script, "--cdb", ctx.paths.semantic_cdb,
      "--index-dir", vim.fs.joinpath(vim.fs.dirname(ctx.paths.semantic_cdb), ".cache", "clangd", "index"),
      "--bin-dir", probed.bin_dir, "-j", tostring(jobs), "--timeout", tostring(math.floor(timeout)) }
    if planned then
      vim.list_extend(command, { "--tier1-plan", planned.plan, "--tier1-clangd", request.tier1.clangd })
      if request.tier1.profile then
        vim.list_extend(command, { "--server-profile", vim.json.encode(request.tier1.profile) })
      end
    end
    system(command, { cwd = ctx.engine_root, env = request.env }, timeout * 1000, function(result)
      if result.spawn_error then callback(failure("offline-tool-spawn:" .. tostring(result.stderr))); return end
      local decoded, report = pcall(vim.json.decode, result.stdout or "")
      if result.code ~= 0 or not decoded or type(report) ~= "table" or report.ok ~= true then
        local detail = decoded and type(report) == "table" and report.error or result.stderr
        callback(failure("offline-tool-failed:" .. tostring(result.code) .. ":" .. tostring(detail or "invalid output"):sub(1, 300)))
        return
      end
      if not planned then callback(report); return end
      publish_tier1(ctx, request, planned, report, function(outcome)
        report.tier1_activation = outcome
        tier1_probe(outcome.ok and "ok" or "failed", { state = outcome.ok and "ok" or "failed",
          reason = outcome.reason, accepted = outcome.accepted, rejected = report.tier1_rejected and vim.tbl_count(report.tier1_rejected) or nil,
          retry_tus = report.tier1_retry_tus, retry_covered = report.tier1_retry_covered,
          fallback = type(report.fallback_tus) == "table" and #report.fallback_tus or nil })
        callback(report)
      end)
    end)
  end

  -- Tier 1 absorption needs the same proof inputs the background queue would use.
  M.pch_offline_tier1_request = function(background_request, lease)
    if not background_request then return nil end
    return { clangd = background_request.clangd, profile = background_request.profile,
      store = background_request.store, background = background_request.background,
      marker = background_request.marker, lease = lease }
  end

  M.run_pch_offline = function(ctx, request, callback)
    request = request or {}
    if settings().enabled == false then callback({ ok = false, disabled = true }); return end
    M.probe_pch_offline(function(probed)
      if not probed.ok then callback(probed); return end
      plan_tier1(ctx, request, function(planned, reason)
        if reason then tier1_probe("skipped:" .. reason, { state = "failed", reason = reason }) end
        run_tool(ctx, request, probed, planned, callback)
      end)
    end)
  end
end
