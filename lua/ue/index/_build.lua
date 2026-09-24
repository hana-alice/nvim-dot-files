-- ue.index._build — subset CDB, partition, phase build + scheduling.
-- Extracted verbatim from lua/ue.lua (F1 split phase-1).
return function(M, core)
  local fs = require("ue.core.fs")
  local file_lock = require("ue.file_lock")
  local _ufs = fs
  local _uplat = require("utils.platform")
  local RT = core.RT
  local unix_now = core.h.unix_now
  local write_json_file = core.h.write_json_file
  local ensure_index_state = core.h.ensure_index_state

  local function resolve_python()
    local resolved = _uplat.resolve_tool({
      name = "python",
      env = { "UE_PYTHON" },
      driver_candidates = function(driver)
        return driver.python_candidates()
      end,
    })
    if resolved.ok then
      return resolved.path, resolved
    end
    return nil, resolved
  end
  local save_index_state = core.h.save_index_state
  local module_key_from_path = core.h.module_key_from_path
  local sorted_module_records = core.h.sorted_module_records
  local seed_core_modules = core.h.seed_core_modules
  local make_index_manifest = core.h.make_index_manifest
  local select_active_artifact = core.h.select_active_artifact
  local update_index_selection = core.h.update_index_selection
  local generation_for_context = core.h.generation_for_context
  local index_manifest_path = core.h.index_manifest_path
  local normalize_index_state = core.h.normalize_index_state

M.base_compile_commands_path = function(ctx)
  local active = ctx.paths and ctx.paths.active_cdb or nil
  if active and _ufs.is_file(active) then
    return active
  end
  local path = fs.join(ctx.engine_root, "compile_commands.json")
  if _ufs.is_file(path) then
    return path
  end
  path = fs.join(ctx.engine_root, "Engine", "compile_commands.json")
  if _ufs.is_file(path) then
    return path
  end
  return nil
end
core.h.base_compile_commands_path = M.base_compile_commands_path

local function artifact_freshness(state, selection)
  if not selection then
    return "missing"
  end
  local dirty = false
  if state.root_dirty then
    dirty = true
  else
    for _, rec in pairs(state.modules or {}) do
      if rec.dirty then
        dirty = true
        break
      end
    end
  end
  return dirty and "overlay" or "fresh"
end

local function persist_index_selection(state, selection, generation)
  local _, snapshot = update_index_selection(state, selection, generation, artifact_freshness(state, selection))
  return snapshot
end

local function phase_background_cdb(ctx, phase)
  if phase == "current" then return ctx.paths.semantic_current_cdb end
  if phase == "hot" then return ctx.paths.semantic_hot_cdb end
  return ctx.paths.semantic_full_cdb
end

M.build_progress_line = function(line)
  local batch = line:match("^%[verified%-batch%] (.+)$")
  if batch then return "SuperUnity: " .. batch end
  local input = line:match("^%[input%] (%d+) per%-file entries")
    or line:match("^%[hot%-super%] input: (%d+) per%-file TUs")
  if input then return ("input: %s source entries"):format(input) end

  local groups, grouped, exact = line:match(
    "^%[hot%-super%].-proven groups: (%d+); grouped sources: (%d+); exact per%-file fallback: (%d+)")
  if groups then
    return ("controlled: %d TUs (%s Unity, %s exact); %d source entries"):format(
      tonumber(groups) + tonumber(exact), groups, exact, tonumber(grouped) + tonumber(exact))
  end
  if line:match("^%[%d+/%d+%]") or line:match("^%[indexer%]") then return line end
  return nil
end

-- Partition only AFTER the CDB writer pipeline and BEFORE index delivery.
-- Mixed platform/config Definitions would otherwise make macro navigation
-- select a foreign build. Keep the shader entries alongside the active tuple;
-- an explicit :UECDBSwitch overrides the partitioner's largest-group default.
local function partition_plan(ctx, opts)
  opts = opts or {}
  local base = M.base_compile_commands_path(ctx)
  if not base then return nil, "no base compile_commands.json" end
  local script = fs.join(vim.fn.fnamemodify(vim.fn.stdpath("config"), ":p"),
    "tools", "cdb_partition.py")
  if not _ufs.is_file(script) then return nil, "cdb_partition.py missing at " .. script end
  local python, resolved = resolve_python()
  if not python then
    return nil, "python unavailable for cdb_partition.py ("
      .. tostring(resolved and resolved.reason or "tool-not-found") .. ")"
  end
  local command = { python, script, base }
  if opts.active then vim.list_extend(command, { "--active", opts.active }) end
  if opts.out_dir then vim.list_extend(command, { "--out-dir", opts.out_dir }) end
  if opts.manifest then vim.list_extend(command, { "--manifest", opts.manifest }) end
  local env, env_list = vim.fn.environ(), {}
  env.PYTHONPATH, env.PYTHONHOME = nil, nil
  for key, value in pairs(env) do env_list[#env_list + 1] = key .. "=" .. value end
  return { command = command, env = env_list, base = base }
end

local function partition_result(result)
  if result.code == 0 then return true, (result.stdout or ""):gsub("%s+$", "") end
  if result.code == 3 then return true, "single-group CDB, no partition needed" end
  return false, ("cdb_partition exit=%d stderr=%s"):format(
    result.code or -1, (result.stderr or ""):gsub("%s+$", ""))
end

-- Explicit blocking twin retained only for :UEPrepareSync/headless debugging.
M.partition_base_cdb = function(ctx, opts)
  local plan, err = partition_plan(ctx, opts)
  if not plan then return false, err end
  local lease, lease_err = file_lock.acquire(plan.base .. ".writer.lock")
  if not lease then return false, "CDB writer is owned by another Neovim: " .. tostring(lease_err) end
  local ok, result, message = pcall(function()
    return partition_result(vim.system(plan.command, {
      env = plan.env, text = true, timeout = 120000,
    }):wait())
  end)
  file_lock.release(lease)
  if not ok then return false, tostring(result) end
  return result, message
end

-- Normal UI path: admitted and fully asynchronous.
M.partition_base_cdb_async = function(ctx, opts, on_done)
  on_done = on_done or function() end
  local plan, err = partition_plan(ctx, opts)
  if not plan then on_done(false, err); return nil, err end
  local admission = require("utils.host_admission")
  local _, _, _, control = admission.run_when_allowed({
    name = "CDB partition",
    start = function()
      local lease, lease_err = file_lock.acquire(plan.base .. ".writer.lock")
      if not lease then
        on_done(false, "CDB writer is owned by another Neovim: " .. tostring(lease_err))
        return
      end
      local ok_spawn, handle = pcall(vim.system, plan.command, {
        env = plan.env, text = true, timeout = 120000,
      }, function(result)
        vim.schedule(function()
          file_lock.release(lease)
          on_done(partition_result(result))
        end)
      end)
      if not ok_spawn then
        file_lock.release(lease)
        on_done(false, tostring(handle))
        return
      end
      pcall(function()
        require("utils.task_registry").register({
          name = "UE CDB partition", group = "ue", kind = "system",
          handle = handle, started_at = os.time(),
        })
      end)
      return function()
        if handle and not handle:is_closing() then pcall(handle.kill, handle, 15) end
      end
    end,
    on_error = function(reason) on_done(false, tostring(reason)) end,
  })
  return control
end

-- Read the partition manifest to know what groups exist + which is active.
-- Returns nil if no manifest (CDB never partitioned yet).
M.read_partition_manifest = function(ctx)
  local base = M.base_compile_commands_path(ctx)
  if not base then return nil end
  local mf_path = vim.fn.fnamemodify(base, ":h") .. "/compile_commands.partition.json"
  if not _ufs.is_file(mf_path) then return nil end
  local content = core.deps.read_all(mf_path)
  if not content or content == "" then return nil end
  local ok, mf = pcall(vim.json.decode, content)
  if not ok or type(mf) ~= "table" then return nil end
  return mf, mf_path
end

M.normalize_cdb_file = function(entry)
  if type(entry) ~= "table" then
    return ""
  end
  local file = fs.norm(entry.file or "")
  local dir = fs.norm(entry.directory or "")
  if file ~= "" and not _ufs.is_absolute_path(file) and dir ~= "" then
    file = fs.join(dir, file)
  end
  return fs.norm(file)
end

M.select_phase_module_keys = function(ctx, state, phase)
  seed_core_modules(ctx, state)
  local selected = {}
  local seen = {}
  local ordered = sorted_module_records(state)
  local function add(key)
    if key and key ~= "" and not seen[key] and state.modules[key] then
      seen[key] = true
      selected[#selected + 1] = key
    end
  end

  -- Current/hot exist to make the user's active semantic context ready first.
  -- Broad core coverage remains additive, but must not occupy the front of
  -- the BackgroundIndex queue ahead of the file that triggered the refresh.
  if state.active_module then
    add(state.active_module)
  end

  if phase == "current" then
    for _, rec in ipairs(ordered) do
      if rec.dirty then
        add(rec.key)
      end
      if #selected >= 6 then
        break
      end
    end
  elseif phase == "hot" then
    for _, rec in ipairs(ordered) do
      if rec.tier == "core" then add(rec.key) end
    end
    for _, rec in ipairs(ordered) do
      if rec.tier ~= "cold" or rec.dirty or rec.key == state.active_module then
        add(rec.key)
      end
      if #selected >= 18 then
        break
      end
    end
  else
    for _, rec in ipairs(ordered) do
      add(rec.key)
    end
  end

  -- A scheduled current build normally has an active/dirty module. Keep a
  -- deterministic fallback for non-editor callers without widening every
  -- ordinary current refresh to the whole core tier.
  if #selected == 0 and ordered[1] then add(ordered[1].key) end

  return selected
end

M.write_subset_compile_commands = function(ctx, phase, selected_keys)
  -- The isolated subset worker receives the parent's selected modules. It
  -- reuses the same path classification without touching the editor's ledger.
  selected_keys = selected_keys or M.select_phase_module_keys(ctx, ensure_index_state(ctx), phase)
  local cdb_path = M.base_compile_commands_path(ctx)
  if not cdb_path then
    return nil, nil, "compile_commands.json not found"
  end
  local content = core.deps.read_all(cdb_path)
  if not content or content == "" then
    return nil, nil, "compile_commands.json is empty"
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, nil, "Failed to parse compile_commands.json"
  end

  local selected_set = {}
  local selected_unity_names = phase ~= "full" and {} or nil
  for _, key in ipairs(selected_keys) do
    selected_set[key] = true
    if selected_unity_names then
      local root = type(key) == "string" and (key:match("^module:(.+)$") or key:match("^plugin:(.+)$"))
      local name = root and fs.norm(root):match("/([A-Za-z_][A-Za-z0-9_]*)$")
      if name and fs.is_absolute_path(root) then
        selected_unity_names[name:lower()] = true
      else
        -- Unknown key shapes must retain the original filesystem discovery.
        selected_unity_names = nil
      end
    end
  end

  local subset = {}
  local buckets = {}
  for _, key in ipairs(selected_keys) do buckets[key] = {} end
  for _, entry in ipairs(decoded) do
    local file = M.normalize_cdb_file(entry)
    local key = module_key_from_path(ctx, file, selected_unity_names)
    if phase == "full" then
      subset[#subset + 1] = entry
    elseif key ~= "" and selected_set[key] then
      buckets[key][#buckets[key] + 1] = entry
    end
  end
  if phase ~= "full" then
    for _, key in ipairs(selected_keys) do
      vim.list_extend(subset, buckets[key])
    end
  end

  if #subset == 0 then
    return nil, nil, "No compile_commands entries matched selected modules"
  end

  local out_cdb = M.index_phase_paths(ctx, phase)
  _ufs.ensure_dir(ctx.paths.index_cdb_dir)
  if not write_json_file(out_cdb, subset) then
    return nil, nil, "Failed to write subset compile_commands.json"
  end
  return out_cdb, selected_keys, nil
end

M.build_phase_async = function(ctx, phase)
  local state = ensure_index_state(ctx)
  local root_key = core.deps.status_root_key(ctx)
  if RT.job then
    state.queue[phase] = unix_now()
    save_index_state(ctx, state)
    return false, "busy"
  end

  local phase_lease, lease_err = file_lock.acquire(ctx.paths.index_state .. ".build.lock")
  if not phase_lease then
    return false, "index artifacts are owned by another Neovim: " .. tostring(lease_err)
  end
  local function fail_before_spawn(message)
    file_lock.release(phase_lease)
    return false, message
  end

  -- Phase split:
  --   full        → build_full_cdb.py over the complete active CDB.
  --   hot/current → build_clangd_index.py over a prioritized module subset.
  -- Both produce controlled BackgroundIndex CDBs. Sources are grouped only
  -- through compiler-authored UBT unity membership with the matching response
  -- file; entries lacking that proof remain exact per-file TUs.
  local subset_cdb, err
  local selected_keys = M.select_phase_module_keys(ctx, state, phase)
  local base = M.base_compile_commands_path(ctx)
  if not base then
    err = "base compile_commands.json not found at engine root"
  elseif phase == "full" then
    subset_cdb = base
  else
    -- Only choose the output here. The existing generator process runs the
    -- original Lua subset classifier in an isolated worker; reading, decoding
    -- and scanning a full active CDB must never run on the editor thread.
    subset_cdb = M.index_phase_paths(ctx, phase)
  end
  if not subset_cdb then
    state.build = {
      phase = phase,
      status = "error",
      started_at = unix_now(),
      finished_at = unix_now(),
      message = err,
      active_index = state.build and state.build.active_index or "",
    }
    save_index_state(ctx, state)
    core.deps.invalidate_status_cache()
    core.deps.refresh_statusline()
    return fail_before_spawn(err)
  end

  -- Pin to Python 3.12 absolute path on Windows: relying on PATH `python`
  -- bites us when an outer shell (hermes-aux, uv, conda) injects PYTHONHOME
  -- pointing at a different minor (3.11/3.14) — child explodes with
  -- `_sre.MAGIC mismatch` from the stdlib loader. Absolute path + scrubbed
  -- env is the only reliable combo.
  local python, resolved = resolve_python()
  if not python then
    return fail_before_spawn("python unavailable for index build (" .. tostring(resolved and resolved.reason or "tool-not-found") .. ")")
  end

  local tools_dir = vim.fn.stdpath("config") .. "/tools"
  local build_script
  if phase == "full" then
    build_script = tools_dir .. "/build_full_cdb.py"
  else
    build_script = tools_dir .. "/build_clangd_index.py"
  end
  if not _ufs.is_file(build_script) then
    return fail_before_spawn(build_script .. " not found")
  end

  local _, out_idx = M.index_phase_paths(ctx, phase)
  local background_cdb = phase_background_cdb(ctx, phase)
  -- Generators atomically replace changed output. Keep the prior baseline
  -- readable during a rebuild and preserve mtimes when its content is equal.

  local cmd, input_signature
  if phase == "full" then
    -- build_full_cdb.py <src> <dst_active> --idx-output <marker>
    -- Single entry that produces:
    --   * index_full_cdb       (post-processed per-file scratch CDB)
    --   * background_cdb       (proven Unity groups + exact per-file fallback)
    --   * marker               (small completion artifact; not loaded by clangd)
    cmd = {
      python, build_script, subset_cdb, ctx.paths.index_full_cdb,
      "--idx-output", out_idx,
      "--background-output", background_cdb,
    }
  else
    -- hot/current: subset → compiler-proven wrappers + exact TU fallback.
    local stat = vim.uv.fs_stat(base)
    if not stat then return fail_before_spawn("active compile_commands.json became unavailable") end
    input_signature = { size = stat.size, mtime = stat.mtime, ctime = stat.ctime }
    local request_path = subset_cdb .. ".request.json"
    local request = {
      schema = 1, phase = phase, selected_keys = selected_keys,
      owner_pid = vim.fn.getpid(), build_lease = phase_lease,
      input_signature = input_signature,
      ctx = { engine_root = ctx.engine_root, project_root = ctx.project_root,
        paths = { active_cdb = base, index_cdb_dir = ctx.paths.index_cdb_dir,
          index_current_cdb = phase == "current" and subset_cdb or ctx.paths.index_current_cdb,
          index_hot_cdb = phase == "hot" and subset_cdb or ctx.paths.index_hot_cdb } },
    }
    _ufs.ensure_dir(vim.fs.dirname(request_path))
    if not write_json_file(request_path, request) then
      return fail_before_spawn("failed to write subset selection request")
    end
    cmd = {
      python, build_script, subset_cdb,
      "--output", out_idx,
      "--background-output", background_cdb,
      "--subset-request", request_path, "--nvim", vim.v.progpath,
    }
  end
  local base_cdb = M.base_compile_commands_path(ctx)
  vim.list_extend(cmd, { "--super-dir", fs.join(vim.fs.dirname(ctx.paths.semantic_cdb), "super_unity_cpps") })
  if base_cdb and _ufs.is_file(base_cdb .. ".unity-receipt.json") then
    vim.list_extend(cmd, { "--unity-receipt", base_cdb .. ".unity-receipt.json" })
  end
  local clangd = _uplat.resolve_tool({ name = "clangd", env = { "UE_CLANGD" },
    config = { "clangd.candidates_extra" },
    driver_candidates = function(driver) return driver.default_clangd_candidates() end })
  local process_config = vim.lsp.config and vim.lsp.config.clangd or {}
  local server_profile, profile_error = require("ue.index.batch_runtime").server_profile(
    require("ue").clangd_cmd(ctx.engine_root), process_config)
  if clangd.ok and not profile_error then
    vim.list_extend(cmd, { "--verified-batches", "--reuse-verified-only",
      "--clangd", clangd.path, "--batch-size", "8" })
    -- A project/target-scoped selection points at immutable qualified assets.
    -- It selects where to look; only the existing receipt checks grant reuse.
    local store_path = fs.join(vim.fs.dirname(ctx.paths.semantic_cdb), "batch-store.json")
    local store_stat = vim.uv.fs_stat(store_path)
    if store_stat then
      if store_stat.type ~= "file" or store_stat.size > 65536 then
        return fail_before_spawn("invalid batch-store.json: expected a small selection file")
      end
      local store = core.h.read_json_file(store_path)
      if type(store) ~= "table" or store.schema ~= 1 or type(store.path) ~= "string"
          or not fs.is_absolute_path(store.path) or store.path:find("[%z\r\n]") then
        return fail_before_spawn("invalid batch-store.json: expected schema=1 and an absolute proof-store path")
      end
      vim.list_extend(cmd, { "--verified-batch-store", store.path })
    end
    if server_profile then vim.list_extend(cmd, { "--server-profile", vim.json.encode(server_profile) }) end
  end

  state.queue[phase] = nil
  state.build = {
    phase = phase,
    status = "running",
    started_at = unix_now(),
    finished_at = 0,
    message = string.format("%s modules=%d", phase, #selected_keys),
    active_index = state.build and state.build.active_index or "",
    -- Owner identity makes "running" falsifiable across processes: without it a
    -- build interrupted by a Neovim exit stays "running" forever and nothing can
    -- tell an in-flight build apart from an orphaned record.
    owner_pid = vim.fn.getpid(),
  }
  save_index_state(ctx, state)
  core.deps.invalidate_status_cache()
  core.deps.refresh_statusline()

  RT.job = { root_key = root_key, phase = phase }

  -- Visible progress for the controlled index build (P5-compliant).
  --
  -- WHY: this build is scheduled automatically by every UEPrepare completion
  -- path, and `full` processes ~16k TUs / writes ~270MB -- minutes of work. It
  -- previously ran as a completely silent fire-and-forget child: no progress, no
  -- log, and the failure branch did not even notify. So when it was interrupted
  -- (window closed) or failed, the user saw prepare finish, reasonably assumed
  -- the semantic layer was ready, and then got a degraded `gd` with nothing on
  -- screen explaining why. Delivery must be observable.
  --
  -- Uses the same fidget channel as UEPrepare (bottom-right, alongside LSP
  -- progress) rather than async_launcher's floating window: this task starts on
  -- its own, so it must inform without stealing screen space. P5 is honored --
  -- start + coarse updates driven by real child output, no periodic ticker, and
  -- it disappears on success.
  local ok_fidget, fidget_progress = pcall(require, "fidget.progress")
  local progress_handle
  if ok_fidget then
    progress_handle = fidget_progress.handle.create({
      title = "UE index",
      message = string.format("%s: %d module(s) starting...", phase, #selected_keys),
      lsp_client = { name = "ue.index" },
      percentage = nil, -- indeterminate: the child does not report a total
    })
  end
  local function progress_report(msg)
    if progress_handle then
      progress_handle.message = string.format("%s: %s", phase, msg)
    end
  end
  local function progress_finish(msg)
    if not progress_handle then return end
    if msg then progress_handle.message = msg end
    pcall(function() progress_handle:finish() end)
    progress_handle = nil
  end

  -- Defensive env scrub: if our parent (hermes/wt/IDE) injected PYTHONHOME
  -- pointing at a different python minor than `python` on PATH, the child
  -- explodes with `_sre.MAGIC mismatch` from the stdlib loader. Strip it.
  -- IMPORTANT: setting key=nil in vim.fn.environ() is NOT enough — vim.system
  -- on Windows has been observed inheriting the parent env even when the key
  -- is removed from the table. Force-overwrite to the empty string so the
  -- child sees an explicit blank, which Python's site.py treats as unset.
  local child_env = require("ue.index.batch_runtime").process_environment(process_config)
  child_env.PYTHONHOME = ""
  child_env.PYTHONPATH = ""
  child_env.PYTHONSTARTUP = ""
  local t_build_0 = vim.uv.hrtime()

  -- Stream child output into the progress message. jobstart/vim.system deliver
  -- arbitrary chunks that are NOT line-aligned, so keep a pending buffer and
  -- only surface complete lines (same lesson as K51's pipeline logging).
  local pending_out = ""
  local last_line = ""
  -- Input size cannot prove grouping succeeded. Show the generator's measured
  -- Unity/exact breakdown, including the legitimate zero-Unity fallback case.

  local function consume(chunk)
    if not chunk or chunk == "" then return end
    pending_out = pending_out .. chunk
    while true do
      local nl = pending_out:find("\n")
      if not nl then break end
      local line = fs.trim(pending_out:sub(1, nl - 1))
      pending_out = pending_out:sub(nl + 1)
      if line ~= "" then
        last_line = line
        local shown = M.build_progress_line(line)
        if shown then
          vim.schedule(function()
            progress_report(shown:sub(1, 120))
          end)
        end
      end
    end
  end

  vim.system(cmd, {
    text = true,
    cwd = ctx.engine_root,
    env = child_env,
    clear_env = true,
    stdout = function(_, data) consume(data) end,
    stderr = function(_, data) consume(data) end,
  }, function(result)
    local elapsed_s = (vim.uv.hrtime() - t_build_0) / 1e9
    vim.schedule(function()
      local live_state = ensure_index_state(ctx)
      normalize_index_state(live_state)
      RT.job = nil
      local stderr = fs.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
      local ok_result = (result.code == 0)
        and _ufs.is_file(out_idx)
        and _ufs.is_file(background_cdb)
      if input_signature then
        local stat = vim.uv.fs_stat(base)
        local current = stat and { size = stat.size, mtime = stat.mtime, ctime = stat.ctime }
        if not vim.deep_equal(current, input_signature) then
          ok_result, stderr = false, "active compile_commands.json changed during the subset build"
        end
      end
      -- Persist per-phase timing so :UEIndexTimings (and post-mortem
      -- inspection of state.json) can answer "how long did the last
      -- :UEIndexFull take" without relying on console output.
      live_state.index_timings = live_state.index_timings or {}
      live_state.index_timings[phase] = {
        elapsed_s = math.floor(elapsed_s * 100 + 0.5) / 100,
        modules = #selected_keys,
        status = ok_result and "ready" or "error",
        controlled_background = true,
        finished_at = unix_now(),
      }
      -- MANIFEST LANDS WITH THE ARTIFACT, not after the whole chain succeeds.
      --
      -- WHY: the manifest is the ONLY on-disk proof of which build a given index
      -- artifact belongs to, and it is what lets a later process recover readiness
      -- without re-running UEPrepare (spec: "Prepared tuple artifacts survive a
      -- Nvim restart"). Writing it only after selection/promotion/clangd-restart
      -- all succeed meant a produced artifact could sit on disk with no way to
      -- prove its provenance -- exactly the state found on this machine: 261MB of
      -- controlled CDB present, zero manifests anywhere, stats still {0,0,0}.
      --
      -- The artifact existing is sufficient evidence to describe it. Downstream
      -- failures are recorded separately and MUST NOT erase this record.
      local manifest = nil
      if ok_result then
        manifest = make_index_manifest(ctx, live_state, phase, out_idx, selected_keys, {
          base_cdb_path = M.base_compile_commands_path(ctx),
          background_cdb_path = background_cdb,
          semantic_cdb_path = _ufs.is_file(background_cdb .. ".semantic.json")
            and (background_cdb .. ".semantic.json") or nil,
          index_kind = "controlled-background",
          completed_at = live_state.index_timings[phase].finished_at,
        })
        live_state.index_artifacts[phase] = manifest
        local ok_write = write_json_file(index_manifest_path(out_idx), manifest)
        if not ok_write then
          -- Without the manifest the artifact is unrecoverable next session, so a
          -- failed write must be visible rather than silently degrading.
          pcall(function()
            require("utils.log").error_ctx("ue.index", "failed to persist index manifest", {
              phase = phase,
              path = index_manifest_path(out_idx),
            })
          end)
        end
      end

      if ok_result then
        local prev_fingerprint = live_state.index_selection and live_state.index_selection.artifact_fingerprint or ""
        local prev_active_index = live_state.build and live_state.build.active_index or ""
        local generation = generation_for_context(ctx, { base_cdb_path = M.base_compile_commands_path(ctx) })
        local selection = select_active_artifact(live_state, generation)
        local snapshot = persist_index_selection(live_state, selection, generation)
        local promoted, publication = false, nil
        if selection then promoted, publication = M.publish_semantic_cdb(ctx, live_state, generation) end
        local selection_changed = selection
          and snapshot.artifact_fingerprint ~= ""
          and snapshot.artifact_fingerprint ~= prev_fingerprint
        local source_pending = M.source_refresh_pending(ctx)
        if not source_pending then M.clear_module_dirty_flags(ctx, selected_keys) end
        live_state.stats[phase .. "_runs"] = (tonumber(live_state.stats[phase .. "_runs"]) or 0) + 1
        live_state.build = {
          phase = phase,
          status = (selection and promoted) and "ready" or "error",
          started_at = live_state.build.started_at or unix_now(),
          finished_at = unix_now(),
          message = (selection and promoted) and string.format(
            "%s ready (%d modules, base=%s, coverage=%s) in %.1fs",
            phase,
            #selected_keys,
            snapshot.phase ~= "" and snapshot.phase or "-",
            snapshot.coverage_level ~= "" and snapshot.coverage_level or "-",
            elapsed_s
          ) or (stderr ~= "" and stderr or "failed to select/promote active semantic index"),
          active_index = (selection and promoted) and ctx.paths.semantic_cdb or prev_active_index,
        }
        save_index_state(ctx, live_state)
        -- Phase/coverage metadata may change without changing clangd's commands.
        -- Preserve its in-flight index work when the published CDB is identical.
        local publication_changed = type(publication) ~= "table" or publication.changed ~= false
        if selection and promoted and source_pending then
          M.deliver_source_refresh(ctx, selected_keys)
        elseif selection_changed and promoted and publication_changed then
          local restart_options = { context = ctx }
          if type(publication) == "table" then restart_options.original_changed = publication.original_changed end
          M.maybe_restart_clangd_for_index(restart_options)
        end
        if not (selection and promoted) then
          -- Artifacts were produced but delivery did not complete
          -- (manifest/selection/promotion). This is a FAILURE, not a quiet
          -- partial success: the gate consumes persisted readiness, so leaving it
          -- unreported is exactly how a 270MB full.json can sit on disk while
          -- `gd` keeps degrading with no explanation.
          ok_result = false
        end
      else
        live_state.build = {
          phase = phase,
          status = "error",
          started_at = live_state.build.started_at or unix_now(),
          finished_at = unix_now(),
          message = stderr ~= "" and stderr or (phase .. " index build failed"),
          active_index = live_state.build.active_index or "",
        }
        save_index_state(ctx, live_state)
      end

      -- Failure MUST be visible. Previously both failure branches only wrote
      -- status="error" into a JSON file: no notify, no log, and no index build
      -- log has ever existed in this repository. The user therefore had no way
      -- to learn that the semantic index they were implicitly waiting for had
      -- failed -- the whole reason this defect stayed hidden.
      if ok_result then
        progress_finish()
      else
        local detail = fs.trim(live_state.build and live_state.build.message or "")
        if detail == "" then detail = last_line end
        pcall(function()
          require("utils.log").error_ctx("ue.index", "controlled index build failed", {
            phase = phase,
            exit_code = result.code,
            modules = #selected_keys,
            elapsed_s = math.floor(elapsed_s * 10 + 0.5) / 10,
            detail = detail ~= "" and detail:sub(1, 400) or nil,
          })
        end)
        progress_finish(string.format("%s FAILED", phase))
        vim.notify(string.format(
          "UE index: %s build failed (exit %s) -- C++ definition navigation stays degraded.\n%s\nSee :NvimLog for details.",
          phase,
          tostring(result.code),
          detail ~= "" and detail:sub(1, 200) or "no output captured"),
          vim.log.levels.ERROR, { title = "UE index" })
      end

      core.deps.invalidate_status_cache()
      core.deps.refresh_statusline()
      file_lock.release(phase_lease)
      M.try_start_queued_build()
    end)
  end)

  return true
end

M.try_start_queued_build = function()
  if RT.job then
    return false
  end
  local started = false
  while not RT.job do
    local picked_phase, picked_ctx, picked_state, picked_ts = nil, nil, nil, nil
    for _, phase_name in ipairs({ "current", "hot", "full" }) do
      for key, state in pairs(RT.module_state or {}) do
        local queued_at = state and state.queue and state.queue[phase_name]
        local ctx = RT.contexts[key]
        if queued_at and ctx and (picked_ts == nil or queued_at < picked_ts) then
          picked_phase = phase_name
          picked_ctx = ctx
          picked_state = state
          picked_ts = queued_at
        end
      end
      if picked_phase then
        break
      end
    end
    if not picked_phase or not picked_ctx or not picked_state then
      break
    end
    -- Queue draining is a second start path and MUST share the scheduler gate.
    -- If denied, the gate re-arms the phase; keep its persisted queue entry.
    if M.admit_index_phase_start
        and not M.admit_index_phase_start(picked_ctx, picked_phase) then
      break
    end
    local ok_started = M.build_phase_async(picked_ctx, picked_phase)
    if ok_started then
      started = true
      break
    end
    picked_state.queue[picked_phase] = nil
    save_index_state(picked_ctx, picked_state)
  end
  return started
end
end
