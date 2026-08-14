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

local function read_cdb(path)
  if not path or path == "" or not _ufs.is_file(path) then return nil end
  local content = core.deps.read_all(path)
  local ok, decoded = pcall(vim.json.decode, content or "")
  if not ok or type(decoded) ~= "table" then return nil end
  return decoded
end

local function atomic_write_json(path, value)
  _ufs.ensure_dir(vim.fs.dirname(path))
  local tmp = path .. ".tmp." .. tostring(vim.uv.hrtime())
  if not core.deps.write_all(tmp, vim.json.encode(value)) then
    pcall(vim.fn.delete, tmp)
    return false, "temporary write failed"
  end
  local ok, err = (vim.uv or vim.loop).fs_rename(tmp, path)
  if not ok then
    pcall(vim.fn.delete, tmp)
    return false, "atomic rename failed: " .. tostring(err)
  end
  return true
end

-- Publish one controlled, coverage-complete database for clangd BackgroundIndex.
-- Exact open-buffer commands are supplied separately through clangd's
-- compilationDatabaseChanges protocol extension. Compiler-authored UBT unity
-- groups are used when fully proven; exact per-file entries retain coverage
-- elsewhere. Every completed phase is additive; current/hot entries lead the
-- queue for responsiveness but can never remove the broad full baseline.
M.publish_semantic_cdb = function(ctx, state, generation)
  local base_path = M.base_compile_commands_path(ctx)
  if not base_path or not _ufs.is_file(base_path) then
    return false, "base compile_commands.json is unreadable"
  end

  local merged, seen = {}, {}
  local function add_entries(entries)
    for _, entry in ipairs(entries or {}) do
      local file = M.normalize_cdb_file(entry)
      local key = file:lower()
      if key ~= "" and not seen[key] then
        seen[key] = true
        merged[#merged + 1] = entry
      end
    end
  end
  local controlled_count = 0
  for _, phase in ipairs({ "current", "hot", "full" }) do
    local artifact = state.index_artifacts and state.index_artifacts[phase] or nil
    if artifact and artifact.generation_id == generation.generation_id then
      local entries = read_cdb(artifact.background_cdb_path)
      if not entries then
        return false, phase .. " controlled background CDB is unreadable"
      end
      local before = #merged
      add_entries(entries)
      controlled_count = controlled_count + (#merged - before)
    end
  end
  if controlled_count == 0 then
    return false, "no same-generation controlled translation units"
  end

  local ok, err = atomic_write_json(ctx.paths.semantic_cdb, merged)
  if not ok then return false, err end
  return true, {
    entry_count = #merged,
    controlled_entry_count = controlled_count,
  }
end

-- CDB partition by (platform, config) -- see docs/changelog.md 2026-05-28 (#5)
-- UBT's compile_commands.json accumulates entries from every config + platform
-- that has ever been built in this checkout. clangd then walks all those
-- per-config -include Definitions.<Module>.h headers when servicing `gd` on
-- macros like UE_BUILD_DEVELOPMENT, jumping to whichever config's generated
-- header happens to be in the CDB (often a stale Dev one from days ago, even
-- though the current build is Test).
--
-- Fix: after every :UEPrepare we shell out to tools/cdb_partition.py, which
-- splits the base CDB into per-(plat, cfg) files under
-- <repo>/.cache/nvim-ue/cdb/active/compile_commands.<plat>-<cfg>.json and
-- rewrites the base to contain ONLY the active group + shaders. Active group
-- is auto-picked (largest cmd count) unless the caller passes an explicit
-- "Platform/Config" pair, e.g. :UECDBSwitch Win64 Development.
--
-- Pipeline placement: invoked right after run_compile_commands_pipeline (which
-- expands rsps / injects defs / unifies includes) and BEFORE
-- M.schedule_index_refresh -- so every controlled BackgroundIndex phase and
-- exact-command transport sees the already-partitioned base. Failure here is
-- non-fatal: we surface a WARN and leave the base CDB untouched (clangd
-- continues to work, just with the old multi-group mix).
M.partition_base_cdb = function(ctx, opts)
  opts = opts or {}
  local base = M.base_compile_commands_path(ctx)
  if not base then
    return false, "no base compile_commands.json"
  end

  local nvim_root = vim.fn.fnamemodify(vim.fn.stdpath("config"), ":p")
  local script = fs.join(nvim_root, "tools", "cdb_partition.py")
  if not _ufs.is_file(script) then
    return false, "cdb_partition.py missing at " .. script
  end

  -- Reuse the same Python probe sequence used elsewhere in this file for the
  -- ccjson / pch subprocesses (Python 3.12 absolute path on Windows to dodge
  -- PYTHONHOME contamination from outer shells).
  local python
  if _uplat.is_windows then
    local cands = {
      vim.env.UE_PYTHON or "",
      vim.fn.expand("~/AppData/Local/Programs/Python/Python312/python.exe"),
      vim.fn.expand("~/AppData/Local/Programs/Python/Python313/python.exe"),
      "C:/Python312/python.exe",
      "C:/Python313/python.exe",
    }
    for _, c in ipairs(cands) do
      if c and c ~= "" and _ufs.is_file(c) then python = c; break end
    end
    python = python or "python"
  else
    python = "python3"
  end

  local cmd = { python, script, base }
  if opts.active then
    table.insert(cmd, "--active")
    table.insert(cmd, opts.active)
  end
  if opts.out_dir then
    table.insert(cmd, "--out-dir")
    table.insert(cmd, opts.out_dir)
  end

  -- Scrub PYTHONPATH/PYTHONHOME (same reason as the ccjson subprocess).
  local env = vim.fn.environ()
  env.PYTHONPATH = nil
  env.PYTHONHOME = nil
  local env_list = {}
  for k, v in pairs(env) do
    table.insert(env_list, k .. "=" .. v)
  end

  local result = vim.system(cmd, { env = env_list, text = true, timeout = 120000 }):wait()
  if result.code == 0 then
    return true, (result.stdout or ""):gsub("%s+$", "")
  end
  if result.code == 3 then
    -- "no classifiable groups" -- single-config CDB, nothing to do.
    return true, "single-group CDB, no partition needed"
  end
  local msg = ("cdb_partition exit=%d stderr=%s"):format(
    result.code or -1,
    (result.stderr or ""):gsub("%s+$", ""))
  return false, msg
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

M.write_subset_compile_commands = function(ctx, phase)
  local state = ensure_index_state(ctx)
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

  local selected_keys = M.select_phase_module_keys(ctx, state, phase)
  local selected_set = {}
  for _, key in ipairs(selected_keys) do
    selected_set[key] = true
  end

  local subset = {}
  local buckets = {}
  for _, key in ipairs(selected_keys) do buckets[key] = {} end
  for _, entry in ipairs(decoded) do
    local file = M.normalize_cdb_file(entry)
    local key = module_key_from_path(ctx, file)
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
  write_json_file(out_cdb, subset)
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
  local subset_cdb, selected_keys, err
  if phase == "full" then
    selected_keys = M.select_phase_module_keys(ctx, state, phase)
    local base = M.base_compile_commands_path(ctx)
    if not base then
      err = "base compile_commands.json not found at engine root"
    else
      subset_cdb = base  -- build_full_cdb.py reads/writes this in place
    end
  else
    subset_cdb, selected_keys, err = M.write_subset_compile_commands(ctx, phase)
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
  local python
  if _uplat.is_windows then
    -- Probe well-known per-user / system Python 3.12 install locations.
    -- Falls back to PATH `python` if nothing matches (caller can override
    -- via UE_PYTHON env var for non-standard installs).
    local candidates = {
      vim.env.UE_PYTHON or "",
      vim.fn.expand("~/AppData/Local/Programs/Python/Python312/python.exe"),
      vim.fn.expand("~/AppData/Local/Programs/Python/Python313/python.exe"),
      "C:/Python312/python.exe",
      "C:/Python313/python.exe",
    }
    for _, p in ipairs(candidates) do
      if p and p ~= "" and _ufs.is_file(p) then python = p; break end
    end
    python = python or "python"
  else
    python = "python3"
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
  if _ufs.is_file(out_idx) then
    pcall(vim.fn.delete, out_idx)
  end
  if _ufs.is_file(background_cdb) then
    pcall(vim.fn.delete, background_cdb)
  end

  local cmd
  if phase == "full" then
    -- build_full_cdb.py <src> <dst_active> --idx-output <marker>
    -- Single entry that produces:
    --   * index_full_cdb       (post-processed per-file scratch CDB)
    --   * background_cdb       (super-unity-only CDB for clangd shards)
    --   * marker               (small completion artifact; not loaded by clangd)
    cmd = {
      python, build_script, subset_cdb, ctx.paths.index_full_cdb,
      "--idx-output", out_idx,
      "--background-output", background_cdb,
    }
  else
    -- hot/current: subset → compiler-proven wrappers + exact TU fallback.
    cmd = {
      python, build_script, subset_cdb,
      "--output", out_idx,
      "--background-output", background_cdb,
    }
  end

  state.queue[phase] = nil
  state.build = {
    phase = phase,
    status = "running",
    started_at = unix_now(),
    finished_at = 0,
    message = string.format("%s modules=%d", phase, #selected_keys),
    active_index = state.build and state.build.active_index or "",
  }
  save_index_state(ctx, state)
  core.deps.invalidate_status_cache()
  core.deps.refresh_statusline()

  RT.job = { root_key = root_key, phase = phase }
  -- Defensive env scrub: if our parent (hermes/wt/IDE) injected PYTHONHOME
  -- pointing at a different python minor than `python` on PATH, the child
  -- explodes with `_sre.MAGIC mismatch` from the stdlib loader. Strip it.
  -- IMPORTANT: setting key=nil in vim.fn.environ() is NOT enough — vim.system
  -- on Windows has been observed inheriting the parent env even when the key
  -- is removed from the table. Force-overwrite to the empty string so the
  -- child sees an explicit blank, which Python's site.py treats as unset.
  local child_env = vim.fn.environ()
  child_env.PYTHONHOME = ""
  child_env.PYTHONPATH = ""
  child_env.PYTHONSTARTUP = ""
  local t_build_0 = vim.uv.hrtime()
  vim.system(cmd, { text = true, cwd = ctx.engine_root, env = child_env }, function(result)
    local elapsed_s = (vim.uv.hrtime() - t_build_0) / 1e9
    vim.schedule(function()
      local live_state = ensure_index_state(ctx)
      normalize_index_state(live_state)
      RT.job = nil
      local stderr = fs.trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
      local ok_result = (result.code == 0)
        and _ufs.is_file(out_idx)
        and _ufs.is_file(background_cdb)
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
      if ok_result then
        local prev_fingerprint = live_state.index_selection and live_state.index_selection.artifact_fingerprint or ""
        local prev_active_index = live_state.build and live_state.build.active_index or ""
        local manifest = make_index_manifest(ctx, live_state, phase, out_idx, selected_keys, {
          base_cdb_path = M.base_compile_commands_path(ctx),
          background_cdb_path = background_cdb,
          index_kind = "controlled-background",
          completed_at = live_state.index_timings[phase].finished_at,
        })
        live_state.index_artifacts[phase] = manifest
        write_json_file(index_manifest_path(out_idx), manifest)
        local generation = generation_for_context(ctx, { base_cdb_path = M.base_compile_commands_path(ctx) })
        local selection = select_active_artifact(live_state, generation)
        local snapshot = persist_index_selection(live_state, selection, generation)
        local promoted = selection and M.publish_semantic_cdb(ctx, live_state, generation) or false
        local selection_changed = selection
          and snapshot.artifact_fingerprint ~= ""
          and snapshot.artifact_fingerprint ~= prev_fingerprint
        M.clear_module_dirty_flags(ctx, selected_keys)
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
        if selection_changed and promoted then
          M.maybe_restart_clangd_for_index()
        end
        if not (selection and promoted) then
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

M.schedule_index_phase = function(ctx, phase, delay_ms)
  if not ctx then
    return
  end
  local state = ensure_index_state(ctx)
  state.queue[phase] = unix_now()
  save_index_state(ctx, state)
  local timer_key = core.deps.status_root_key(ctx) .. "::" .. phase
  if RT.timers[timer_key] then
    RT.timers[timer_key]:stop()
    RT.timers[timer_key]:close()
    RT.timers[timer_key] = nil
  end
  local timer = vim.uv.new_timer()
  RT.timers[timer_key] = timer
  timer:start(delay_ms, 0, vim.schedule_wrap(function()
    if RT.timers[timer_key] then
      RT.timers[timer_key]:stop()
      RT.timers[timer_key]:close()
      RT.timers[timer_key] = nil
    end
    M.build_phase_async(ctx, phase)
  end))
end

M.schedule_index_refresh = function(ctx, opts)
  opts = opts or {}
  if not ctx or not M.base_compile_commands_path(ctx) then
    return
  end
  if opts.current ~= false then
    M.schedule_index_phase(ctx, "current", opts.current_delay_ms or RT.debounce_current_ms)
  end
  if opts.hot then
    M.schedule_index_phase(ctx, "hot", opts.hot_delay_ms or RT.debounce_hot_ms)
  end
  if opts.full then
    M.schedule_index_phase(ctx, "full", opts.full_delay_ms or RT.idle_cold_ms)
  end
end
end
