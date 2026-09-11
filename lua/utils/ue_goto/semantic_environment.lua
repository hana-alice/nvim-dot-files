local M = {}
local uv = vim.uv or vim.loop
local session = require("utils.ue_goto.semantic_session")

local function hash_text(value)
  return vim.fn.sha256(tostring(value or "")):sub(1, 24)
end

local function resolve_executable(candidate)
  if not candidate or candidate == "" then return nil end
  if uv.fs_stat(candidate) then return vim.fs.normalize(candidate) end
  local found = vim.fn.exepath(candidate)
  return found ~= "" and vim.fs.normalize(found) or nil
end

local function sibling_libclang(clangd)
  if not clangd then return nil end
  local platform = require("utils.platform")
  for _, candidate in ipairs(platform.libclang_candidates(clangd)) do
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

function M.read(bufnr, opts)
  local route = opts and opts.route or "header"
  if route ~= "source" and route ~= "header" then return nil, "unknown semantic route" end
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
  if not libclang and route == "header" then return nil, "matching libclang unavailable next to clangd" end
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
  local requested = session.requested({ clangd_path = clangd, libclang_path = libclang })
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
    clangd, libclang, requested.compiler_files,
    index_snapshot and index_snapshot.generation_id or "",
    index_snapshot and index_snapshot.artifact_fingerprint or "",
    controlled_signature,
  }))


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
    compiler_files = requested.compiler_files,
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

function M.index_snapshot_is_current(expected, bufnr)
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

function M.transition(previous, current)
  if not previous then return "reuse" end
  if not session.same_requested(previous, current) then return "restart" end
  return previous.build_fingerprint ~= current.build_fingerprint and "evict" or "reuse"
end

M.controlled_phase_manifests = controlled_phase_manifests
return M
