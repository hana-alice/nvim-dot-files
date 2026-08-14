-- ue.index._generation — generation manifests, coverage selector, status snapshots.
-- Extracted from lua/ue/index/_state.lua to keep module/state concerns smaller.
return function(M, core)
  local fs = require("ue.core.fs")
  local _ufs = fs
  local _uproc = require("ue.core.proc")
  local RT = core.RT

  local INDEX_COVERAGE_RANK = {
    current = 1,
    hot = 2,
    full = 3,
  }

  local TOOLCHAIN_IDENTITY_CACHE = {}
  local CDB_DIGEST_CACHE = {}

  local read_json_file = core.h.read_json_file
  local read_text_file = core.h.read_text_file
  local module_key_from_path = core.h.module_key_from_path
  local ensure_index_state = core.h.ensure_index_state
  local index_phase_label = core.h.index_phase_label
  local module_tier_label = core.h.module_tier_label

  local function sha256_text(payload)
    local ok, digest = pcall(vim.fn.sha256, tostring(payload or ""))
    if ok and type(digest) == "string" and digest ~= "" then
      return digest
    end
    return nil
  end

  local function stable_hash(payload)
    local encoded = vim.json.encode(payload or {})
    return sha256_text(encoded)
  end

  local function canonical_cdb_path(dir, path)
    local normalized = fs.norm(path or "")
    local normalized_dir = fs.norm(dir or "")
    if normalized ~= "" and not _ufs.is_absolute_path(normalized) and normalized_dir ~= "" then
      normalized = fs.join(normalized_dir, normalized)
    end
    return fs.norm(normalized)
  end

  local function canonical_cdb_entry(entry)
    if type(entry) ~= "table" then
      return nil
    end
    local directory = fs.norm(entry.directory or "")
    local file = canonical_cdb_path(directory, entry.file or "")
    if file == "" then
      return nil
    end
    local args = {}
    if type(entry.arguments) == "table" then
      for _, arg in ipairs(entry.arguments) do
        args[#args + 1] = tostring(arg)
      end
    end
    return {
      directory = directory,
      file = file,
      output = canonical_cdb_path(directory, entry.output or ""),
      arguments = args,
      command = type(entry.command) == "string" and fs.trim(entry.command) or "",
    }
  end

  local function normalized_cdb_digest(base_cdb_path)
    base_cdb_path = fs.norm(base_cdb_path or "")
    local stat = base_cdb_path ~= "" and (vim.uv or vim.loop).fs_stat(base_cdb_path) or nil
    local signature = stat and table.concat({
      tostring(stat.size or 0),
      tostring(stat.mtime and stat.mtime.sec or 0),
      tostring(stat.mtime and stat.mtime.nsec or 0),
    }, ":") or "missing"
    local cached = CDB_DIGEST_CACHE[base_cdb_path]
    if cached and cached.signature == signature then
      return cached.digest
    end
    local content = read_text_file(base_cdb_path)
    if not content then
      return ""
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
      return ""
    end
    local canonical = {}
    for _, entry in ipairs(decoded) do
      local normalized = canonical_cdb_entry(entry)
      if normalized then
        canonical[#canonical + 1] = normalized
      end
    end
    table.sort(canonical, function(a, b)
      if a.file ~= b.file then
        return a.file < b.file
      end
      if a.directory ~= b.directory then
        return a.directory < b.directory
      end
      local a_args = table.concat(a.arguments or {}, "\31")
      local b_args = table.concat(b.arguments or {}, "\31")
      if a_args ~= b_args then
        return a_args < b_args
      end
      if a.command ~= b.command then
        return a.command < b.command
      end
      return (a.output or "") < (b.output or "")
    end)
    local digest = stable_hash(canonical) or ""
    CDB_DIGEST_CACHE[base_cdb_path] = { signature = signature, digest = digest }
    return digest
  end

  local function file_signature(path)
    path = fs.norm(path or "")
    local stat = path ~= "" and (vim.uv or vim.loop).fs_stat(path) or nil
    if not stat or stat.type ~= "file" then return "missing" end
    return table.concat({
      tostring(stat.size or 0),
      tostring(stat.mtime and stat.mtime.sec or 0),
      tostring(stat.mtime and stat.mtime.nsec or 0),
    }, ":")
  end

  local function coverage_rank(level)
    return INDEX_COVERAGE_RANK[fs.trim(level):lower()] or 0
  end

  local function build_key_from_ctx(ctx)
    if not ctx then
      return ""
    end
    local platform_key = ctx.paths and ctx.paths.platform_key or ""
    local persisted = ctx.state or {}
    return table.concat({
      fs.trim(platform_key),
      fs.trim(persisted.target or persisted.target_name or ""),
      fs.trim(persisted.target_platform or ""),
      fs.trim(persisted.target_configuration or ""),
      fs.norm(ctx.engine_root or ""),
      fs.norm(ctx.project_root or ""),
    }, "\31")
  end

  local function toolchain_identity()
    if RT.toolchain_identity_override ~= nil then
      if type(RT.toolchain_identity_override) == "function" then
        return RT.toolchain_identity_override() or ""
      end
      return tostring(RT.toolchain_identity_override or "")
    end
    local function executable_identity(path)
      path = fs.norm(path or "")
      if path == "" then
        return { path = "", version = "", size = 0, mtime = 0 }
      end
      local stat = (vim.uv or vim.loop).fs_stat(path)
      local size = stat and tonumber(stat.size) or 0
      local mtime = stat and tonumber(stat.mtime and stat.mtime.sec) or 0
      local cache_key = table.concat({ path, tostring(size), tostring(mtime) }, "\31")
      if TOOLCHAIN_IDENTITY_CACHE[cache_key] then
        return TOOLCHAIN_IDENTITY_CACHE[cache_key]
      end
      local version = ""
      local ok_result, result = pcall(function()
        return vim.system({ path, "--version" }, { text = true, timeout = 5000 }):wait()
      end)
      if ok_result and type(result) == "table" then
        local line = fs.trim((result.stdout or ""):match("([^\r\n]+)") or "")
        version = line
      end
      local identity = {
        path = path,
        version = version,
        size = size,
        mtime = mtime,
      }
      TOOLCHAIN_IDENTITY_CACHE[cache_key] = identity
      return identity
    end
    local clangd = vim.fn.exepath("clangd") or ""
    local indexer = _uproc.first_executable({
      "/mnt/c/Program Files/LLVM/bin/clangd-indexer.exe",
      "clangd-indexer",
      "clangd-indexer.exe",
      "C:/Program Files/LLVM/bin/clangd-indexer.exe",
    }) or ""
    return stable_hash({
      clangd = executable_identity(clangd),
      clangd_indexer = executable_identity(indexer),
      os = jit and jit.os or "",
    }) or ""
  end

  local function base_cdb_digest(base_cdb_path)
    return normalized_cdb_digest(base_cdb_path)
  end

  local function module_names_for_keys(state, keys)
    local names = {}
    local seen = {}
    for _, key in ipairs(keys or {}) do
      local rec = state and state.modules and state.modules[key] or nil
      local name = rec and rec.name or key
      if type(name) == "string" and name ~= "" and not seen[name] then
        seen[name] = true
        names[#names + 1] = name
      end
    end
    table.sort(names)
    return names
  end

  local function index_manifest_path(index_path)
    index_path = fs.norm(index_path or "")
    if index_path == "" then
      return ""
    end
    return index_path .. ".manifest.json"
  end

  local function read_index_manifest(path)
    local manifest = read_json_file(path, nil)
    if type(manifest) ~= "table" then
      return nil
    end
    return manifest
  end

  local function generation_for_context(ctx, opts)
    opts = opts or {}
    local base_cdb_path = opts.base_cdb_path
    if not base_cdb_path or base_cdb_path == "" then
      base_cdb_path = core.h.base_compile_commands_path and core.h.base_compile_commands_path(ctx) or nil
    end
    local cdb_digest = base_cdb_path and base_cdb_digest(base_cdb_path) or ""
    local key = build_key_from_ctx(ctx)
    local toolchain = opts.toolchain_identity or toolchain_identity()
    return {
      build_key = key,
      cdb_digest = cdb_digest,
      toolchain_identity = toolchain,
      generation_id = stable_hash({
        build_key = key,
        cdb_digest = cdb_digest,
        toolchain_identity = toolchain,
      }) or "",
    }
  end

  local function make_index_manifest(ctx, state, phase, index_path, module_keys, opts)
    opts = opts or {}
    local generation = generation_for_context(ctx, {
      base_cdb_path = opts.base_cdb_path,
      toolchain_identity = opts.toolchain_identity,
    })
    local content = read_text_file(index_path)
    local idx_hash = content and sha256_text(content) or ""
    local background_cdb_path = fs.norm(opts.background_cdb_path or "")
    local background_content = read_text_file(background_cdb_path)
    local background_cdb_hash = background_content and sha256_text(background_content) or ""
    local names = module_names_for_keys(state, module_keys)
    local module_set_hash = stable_hash(module_keys or {}) or ""
    return {
      schema = 2,
      index_kind = opts.index_kind or "controlled-background",
      phase = phase,
      coverage_level = phase,
      partial = phase ~= "full",
      build_key = generation.build_key,
      cdb_digest = generation.cdb_digest,
      cdb_source_signature = file_signature(opts.base_cdb_path),
      toolchain_identity = generation.toolchain_identity,
      generation_id = generation.generation_id,
      index_path = fs.norm(index_path or ""),
      index_name = fs.trim(vim.fs.basename(index_path or "")),
      index_path_hash = stable_hash(fs.norm(index_path or "")) or "",
      idx_hash = idx_hash,
      background_cdb_path = background_cdb_path,
      background_cdb_hash = background_cdb_hash,
      module_keys = vim.deepcopy(module_keys or {}),
      module_names = names,
      module_count = #module_keys,
      module_set_hash = module_set_hash,
      completed_at = tonumber(opts.completed_at) or core.h.unix_now(),
      artifact_fingerprint = stable_hash({
        generation_id = generation.generation_id,
        phase = phase,
        idx_hash = idx_hash,
        background_cdb_hash = background_cdb_hash,
        module_set_hash = module_set_hash,
      }) or "",
    }
  end

  local function index_state_selection_default()
    return {
      artifact_fingerprint = "",
      generation_id = "",
      coverage_level = "",
      phase = "",
      index_path = "",
      index_name = "",
      idx_hash = "",
      module_count = 0,
      partial = false,
      converging = false,
      freshness = "missing",
      build_key_hash = "",
      cdb_digest_short = "",
      generation_short = "",
      active_manifest = "",
    }
  end

  local function normalize_index_state(state)
    if type(state.index_artifacts) ~= "table" then
      state.index_artifacts = {}
    end
    if type(state.index_selection) ~= "table" then
      state.index_selection = index_state_selection_default()
    end
  end

  local function same_generation(a, b)
    return type(a) == "table" and type(b) == "table"
      and fs.trim(a.generation_id) ~= ""
      and a.generation_id == b.generation_id
  end

  local function coverage_superset(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then
      return false
    end
    local a_keys = a.module_keys or {}
    local b_keys = b.module_keys or {}
    if #a_keys > 0 and #b_keys > 0 then
      local seen = {}
      for _, key in ipairs(a_keys) do
        seen[key] = true
      end
      for _, key in ipairs(b_keys) do
        if not seen[key] then
          return false
        end
      end
      return true
    end
    local a_rank = coverage_rank(a.coverage_level)
    local b_rank = coverage_rank(b.coverage_level)
    if a_rank ~= b_rank then
      return a_rank > b_rank
    end
    return (tonumber(a.module_count) or 0) >= (tonumber(b.module_count) or 0)
  end

  local function select_active_artifact(state, generation)
    normalize_index_state(state)
    if type(generation) ~= "table" or fs.trim(generation.generation_id) == "" then
      return nil
    end
    local candidates = {}
    for _, phase in ipairs({ "current", "hot", "full" }) do
      local artifact = state.index_artifacts[phase]
      if same_generation(artifact, generation) then
        candidates[#candidates + 1] = artifact
      end
    end
    if #candidates == 0 then
      return nil
    end
    local selected = nil
    if state.index_selection and fs.trim(state.index_selection.artifact_fingerprint or "") ~= "" then
      for _, candidate in ipairs(candidates) do
        if candidate.artifact_fingerprint == state.index_selection.artifact_fingerprint then
          selected = candidate
          break
        end
      end
    end

    local function deterministic_preferred(a, b)
      local a_rank = coverage_rank(a.coverage_level)
      local b_rank = coverage_rank(b.coverage_level)
      if a_rank ~= b_rank then
        return a_rank > b_rank
      end
      local a_count = tonumber(a.module_count) or 0
      local b_count = tonumber(b.module_count) or 0
      if a_count ~= b_count then
        return a_count > b_count
      end
      local a_completed = tonumber(a.completed_at) or 0
      local b_completed = tonumber(b.completed_at) or 0
      if a_completed ~= b_completed then
        return a_completed > b_completed
      end
      return (a.artifact_fingerprint or "") > (b.artifact_fingerprint or "")
    end

    if selected then
      local supersets = {}
      for _, candidate in ipairs(candidates) do
        if candidate.artifact_fingerprint ~= selected.artifact_fingerprint
          and coverage_superset(candidate, selected)
          and not coverage_superset(selected, candidate)
        then
          supersets[#supersets + 1] = candidate
        end
      end
      if #supersets == 0 then
        return selected
      end
      local maximal = {}
      for _, candidate in ipairs(supersets) do
        local dominated = false
        for _, other in ipairs(supersets) do
          if candidate ~= other
            and coverage_superset(other, candidate)
            and not coverage_superset(candidate, other)
          then
            dominated = true
            break
          end
        end
        if not dominated then
          maximal[#maximal + 1] = candidate
        end
      end
      if #maximal ~= 1 then
        return selected
      end
      return maximal[1]
    end

    local maximal = {}
    for _, candidate in ipairs(candidates) do
      local dominated = false
      for _, other in ipairs(candidates) do
        if candidate ~= other
          and coverage_superset(other, candidate)
          and not coverage_superset(candidate, other)
        then
          dominated = true
          break
        end
      end
      if not dominated then
        maximal[#maximal + 1] = candidate
      end
    end
    if #maximal == 1 then
      return maximal[1]
    end
    table.sort(maximal, deterministic_preferred)
    return maximal[1]
  end

  local function update_index_selection(state, selection, generation, freshness)
    normalize_index_state(state)
    local next_selection = index_state_selection_default()
    freshness = fs.trim(freshness)
    if selection then
      next_selection = {
        artifact_fingerprint = selection.artifact_fingerprint or "",
        generation_id = selection.generation_id or "",
        coverage_level = selection.coverage_level or "",
        phase = selection.phase or "",
        index_path = selection.index_path or "",
        index_name = selection.index_name or "",
        idx_hash = selection.idx_hash or "",
        module_count = tonumber(selection.module_count) or #(selection.module_keys or {}),
        partial = selection.partial and true or false,
        converging = selection.coverage_level ~= "full",
        freshness = freshness ~= "" and freshness or "fresh",
        build_key_hash = stable_hash(selection.build_key or "") or "",
        cdb_digest_short = fs.trim(selection.cdb_digest or ""):sub(1, 12),
        generation_short = fs.trim(selection.generation_id or ""):sub(1, 12),
        active_manifest = index_manifest_path(selection.index_path),
      }
    elseif type(generation) == "table" and fs.trim(generation.generation_id) ~= "" then
      next_selection.generation_id = generation.generation_id
      next_selection.generation_short = generation.generation_id:sub(1, 12)
      next_selection.build_key_hash = stable_hash(generation.build_key or "") or ""
      next_selection.cdb_digest_short = fs.trim(generation.cdb_digest or ""):sub(1, 12)
      next_selection.freshness = freshness ~= "" and freshness or "missing"
    else
      next_selection.freshness = freshness ~= "" and freshness or "missing"
    end
    local changed = not vim.deep_equal(state.index_selection, next_selection)
    state.index_selection = next_selection
    return changed, next_selection
  end

  M.semantic_index_snapshot = function(ctx, subject_path)
    local state = ensure_index_state(ctx)
    normalize_index_state(state)
    local selected = state.index_selection or index_state_selection_default()
    local artifact = state.index_artifacts and state.index_artifacts[selected.phase] or nil
    if type(artifact) ~= "table"
        or artifact.artifact_fingerprint ~= selected.artifact_fingerprint then
      artifact = nil
    end

    local readiness = "missing"
    local freshness = "missing"
    if artifact and _ufs.is_file(artifact.index_path)
        and _ufs.is_file(artifact.background_cdb_path or "")
        and _ufs.is_file(ctx.paths and ctx.paths.semantic_cdb or "") then
      readiness = "ready"
      freshness = "fresh"
      local base_cdb_path = core.h.base_compile_commands_path
        and core.h.base_compile_commands_path(ctx) or nil
      if not base_cdb_path
          or fs.trim(artifact.cdb_source_signature or "") == ""
          or artifact.cdb_source_signature ~= file_signature(base_cdb_path) then
        readiness = "stale"
        freshness = "stale"
      end
    elseif state.build and state.build.status == "running" then
      readiness = "building"
    end

    local subject_module = nil
    local subject_dirty = false
    if subject_path and subject_path ~= "" then
      local key = module_key_from_path(ctx, subject_path)
      local rec = key and state.modules and state.modules[key] or nil
      subject_module = rec and rec.name or nil
      subject_dirty = rec and rec.dirty and true or false
      local bufnr = vim.fn.bufnr(fs.norm(subject_path))
      if bufnr >= 0 and vim.api.nvim_buf_is_loaded(bufnr) and vim.bo[bufnr].modified then
        freshness = "live-overlay"
        subject_dirty = false
      elseif subject_dirty or state.root_dirty then
        freshness = "stale-for-module"
      end
    elseif state.root_dirty then
      freshness = "stale-for-module"
    end

    return {
      generation_id = selected.generation_id or "",
      generation_short = selected.generation_short or "",
      artifact_fingerprint = selected.artifact_fingerprint or "",
      coverage_level = selected.coverage_level or "",
      phase = selected.phase or "",
      partial = selected.partial and true or false,
      complete = selected.coverage_level == "full",
      module_count = tonumber(selected.module_count) or 0,
      readiness = readiness,
      freshness = freshness,
      subject_module = subject_module,
      subject_dirty = subject_dirty,
      converging = selected.converging and true or false,
    }
  end

  M.index_status_summary = function(ctx)
    local state = ensure_index_state(ctx)
    local generation = generation_for_context(ctx)
    local selection = select_active_artifact(state, generation)
    local dirty = 0
    local total = 0
    local tier_counts = { core = 0, warm = 0, cold = 0 }
    for _, rec in pairs(state.modules or {}) do
      total = total + 1
      local tier = rec.tier or "warm"
      if tier_counts[tier] ~= nil then
        tier_counts[tier] = tier_counts[tier] + 1
      end
      if rec.dirty then
        dirty = dirty + 1
      end
    end
    local active_name = "-"
    local active_tier = "-"
    local active_kind = "-"
    if state.active_module and state.modules[state.active_module] then
      local active = state.modules[state.active_module]
      active_name = active.name or active_name
      active_tier = module_tier_label(active.tier)
      active_kind = active.kind or active_kind
    end
    local queued = {}
    for _, phase_name in ipairs({ "current", "hot", "full" }) do
      if state.queue and state.queue[phase_name] then
        queued[#queued + 1] = index_phase_label(phase_name)
      end
    end
    local phase = state.build and state.build.phase or "idle"
    local freshness = "missing"
    if selection then
      freshness = ((state.root_dirty or false) or dirty > 0) and "overlay" or "fresh"
    elseif fs.trim(generation.generation_id) ~= "" then
      freshness = "stale"
    end
    local _, snapshot = update_index_selection(state, selection, generation, freshness)
    return {
      active = active_name,
      active_tier = active_tier,
      active_kind = active_kind,
      dirty = dirty,
      total = total,
      core = tier_counts.core,
      warm = tier_counts.warm,
      cold = tier_counts.cold,
      queued = queued,
      queue_count = #queued,
      root_dirty = (state.root_dirty or false)
        or (core.deps.core_rt.dirty_index_roots[core.deps.status_root_key(ctx)] and true or false),
      phase = phase,
      phase_label = index_phase_label(phase),
      status = state.build and state.build.status or "idle",
      message = state.build and state.build.message or "",
      active_index = state.build and state.build.active_index or "",
      active_index_name = fs.trim(vim.fs.basename(state.build and state.build.active_index or "")),
      coverage_level = snapshot.coverage_level,
      generation_short = snapshot.generation_short,
      freshness = snapshot.freshness,
      converging = snapshot.converging,
      selected_phase = snapshot.phase,
      selected_module_count = snapshot.module_count,
      selected_partial = snapshot.partial,
    }
  end

  core.h.sha256_text = sha256_text
  core.h.stable_hash = stable_hash
  core.h.coverage_rank = coverage_rank
  core.h.build_key_from_ctx = build_key_from_ctx
  core.h.toolchain_identity = toolchain_identity
  core.h.base_cdb_digest = base_cdb_digest
  core.h.index_manifest_path = index_manifest_path
  core.h.read_index_manifest = read_index_manifest
  core.h.generation_for_context = generation_for_context
  core.h.make_index_manifest = make_index_manifest
  core.h.select_active_artifact = select_active_artifact
  core.h.update_index_selection = update_index_selection
  core.h.normalize_index_state = normalize_index_state
  core.h.module_names_for_keys = module_names_for_keys

  M.read_index_manifest = read_index_manifest
  M.index_manifest_path = index_manifest_path
  M.generation_for_context = generation_for_context
  M.make_index_manifest = make_index_manifest
  M.select_active_artifact = select_active_artifact
  M.update_index_selection = update_index_selection
  M._set_toolchain_identity_for_test = function(value)
    RT.toolchain_identity_override = value
    TOOLCHAIN_IDENTITY_CACHE = {}
  end
end
