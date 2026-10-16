local semantic_context = require("utils.ue_goto.semantic_context")
local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local cdb_shards = require("ue.cdb.shards")
local compile_command = require("utils.ue_goto.reading_compile")
local cdb_cache = require("utils.ue_goto.semantic_cdb_cache")

local M = {}

local function source_like(path)
  local lower = tostring(path or ""):lower()
  return lower:match("%.c$") or lower:match("%.cc$")
    or lower:match("%.cpp$") or lower:match("%.cxx$")
    or lower:match("%.m$") or lower:match("%.mm$")
end

local function evidence_matches_active_build(path, active)
  active = active or {}
  -- Reuse the repository's UBT artifact-path grammar.  Ordered substring
  -- searches are insufficient here: a later Source/<Target> segment can look
  -- like the active target even when the artifact belongs to another target.
  local platform, target, configuration = cdb_shards.classify_rsp_path(path)
  if not platform then return false end

  local function normalized(value)
    return tostring(value or ""):lower():gsub("^%s+", ""):gsub("%s+$", "")
  end
  local expected_platform = normalized(active.platform)
  local expected_target = normalized(active.target)
  local expected_configuration = normalized(active.configuration):gsub(" editor$", "")
  return (expected_platform == "" or normalized(platform) == expected_platform)
    and (expected_target == "" or normalized(target) == expected_target)
    and (expected_configuration == "" or normalized(configuration) == expected_configuration)
end

local function collect_evidence_files(roots, active, subject)
  local cpp_json, depfiles = {}, {}
  local searchable_roots = {}
  for _, root in ipairs(roots or {}) do
    root = libclang.normalize(root)
    if libclang.dir_exists(root) then
      searchable_roots[#searchable_roots + 1] = root
    end
  end

  local rg = vim.fn.exepath("rg")
  if rg ~= "" and type(subject) == "string" and subject ~= "" and #searchable_roots > 0 then
    local slash = libclang.normalize(subject):gsub("\\", "/")
    local backslash = slash:gsub("/", "\\")
    local json_backslash = backslash:gsub("\\", "\\\\")
    local args = {
      rg,
      "--threads", "1",
      "--no-ignore",
      "--files-with-matches",
      "--fixed-strings",
      "--ignore-case",
      "--no-messages",
      "--glob", "*.cpp.json",
      "--glob", "*.d",
      "-e", slash,
      "-e", backslash,
      "-e", json_backslash,
    }
    vim.list_extend(args, searchable_roots)
    local result = vim.system(args, { text = true }):wait()
    if result.code == 0 or result.code == 1 then
      for path in tostring(result.stdout or ""):gmatch("[^\r\n]+") do
        path = libclang.normalize(path)
        if evidence_matches_active_build(path, active) then
          local lower = path:lower()
          if lower:sub(-9) == ".cpp.json" then
            cpp_json[#cpp_json + 1] = path
          elseif lower:sub(-2) == ".d" then
            depfiles[#depfiles + 1] = path
          end
        end
      end
      return cpp_json, depfiles, "rg-exact-prefilter"
    end
  end

  for _, root in ipairs(searchable_roots) do
    local found = vim.fs.find(function(name, path)
      local lower = name:lower()
      if lower:sub(-9) ~= ".cpp.json" and lower:sub(-2) ~= ".d" then
        return false
      end
      return evidence_matches_active_build(libclang.normalize(path .. "/" .. name), active)
    end, { path = root, type = "file", limit = 200000 })
    for _, path in ipairs(found or {}) do
      local lower = path:lower()
      if lower:sub(-9) == ".cpp.json" then
        cpp_json[#cpp_json + 1] = libclang.normalize(path)
      elseif lower:sub(-2) == ".d" then
        depfiles[#depfiles + 1] = libclang.normalize(path)
      end
    end
  end
  return cpp_json, depfiles, "filesystem-scan"
end

local function processed_compile(commands_by_file, membership_db, compile_file, members, dependencies)
  local main = semantic_context.match_key(compile_file)
  if not dependencies[main] then return nil, "dep-context-primary-input-unproven" end
  local donors = membership_db.by_file[main] and commands_by_file[main] or {}
  if #donors == 0 then
    for _, member in ipairs(members) do
      local key = semantic_context.match_key(member)
      if dependencies[key] and membership_db.by_file[key] then
        vim.list_extend(donors, commands_by_file[key] or {})
      end
    end
  end
  local compile, fingerprint
  local donor_sources, seen = {}, {}
  for _, donor in ipairs(donors) do
    -- Preserve the merged command's PCH, forced includes, VFS and compatibility
    -- fixes. The raw RSP proves its primary input; it is not the parse argv.
    local rebound = compile_command.rebind(donor, donor.file, compile_file)
    if not rebound then return nil, "dep-context-main-file-unproven" end
    local current = semantic_context.compile_descriptor_fingerprint(
      rebound.workingDirectory, compile_file, rebound.compilationCommand)
    if fingerprint and fingerprint ~= current then
      return nil, "dep-context-donor-environment-conflict"
    end
    fingerprint = current
    compile = { file = compile_file, directory = rebound.workingDirectory, argv = rebound.compilationCommand }
    local key = semantic_context.match_key(donor.file)
    if not seen[key] then
      seen[key] = true
      donor_sources[#donor_sources + 1] = donor.file
    end
  end
  table.sort(donor_sources)
  return compile, nil, donor_sources
end

local Catalog = {}
Catalog.__index = Catalog

do
  function Catalog:handle_catalog(request)
    local started = libclang.uv.hrtime()
    local cdb_path = libclang.join(request.cdb_dir, "compile_commands.json")
    local active_cdb_path = request.active_cdb_path or cdb_path
    local fresh, freshness_reason, verified = libclang.active_cdb_is_fresh(
      cdb_path, active_cdb_path, request.active_manifest_path)
    if not fresh then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "catalog",
        ok = true,
        state = "unavailable",
        reason = freshness_reason,
        contexts = {},
        metrics = self.metrics({ total_ms = libclang.duration_ms(started) }),
      }
    end
    local compile_db, compile_error, merged_readable = self.compilation_databases:load(cdb_path,
      verified and verified[libclang.normalize(cdb_path)])
    if not merged_readable then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "catalog",
        ok = true,
        state = "unavailable",
        reason = "merged-compilation-database-unreadable",
        contexts = {},
        metrics = self.metrics({ total_ms = libclang.duration_ms(started) }),
      }
    end
    local membership_db, membership_error, active_readable = self.compilation_databases:load(active_cdb_path,
      verified and verified[libclang.normalize(active_cdb_path)])
    if not active_readable then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "catalog",
        ok = true,
        state = "unavailable",
        reason = "active-compilation-database-unreadable",
        contexts = {},
        metrics = self.metrics({ total_ms = libclang.duration_ms(started) }),
      }
    end

    if not compile_db or not compile_db.complete or not membership_db or not membership_db.complete then
      local failed, detail = membership_db, membership_error
      if not compile_db or not compile_db.complete then failed, detail = compile_db, compile_error end
      return {
        v = self.protocol.VERSION, id = request.id, op = "catalog", ok = true, state = "unavailable",
        reason = (not compile_db or not compile_db.complete) and "merged-cdb-incomplete" or "active-cdb-incomplete",
        contexts = {}, coverage = { complete = false,
          rejected = failed and failed.rejected or { { reason = detail or "cdb-unreadable" } } },
        metrics = self.metrics({ total_ms = libclang.duration_ms(started) }),
      }
    end
    local after_verified
    fresh, freshness_reason, after_verified = libclang.active_cdb_is_fresh(cdb_path, active_cdb_path, request.active_manifest_path)
    if fresh and verified and not vim.deep_equal(verified, after_verified) then
      fresh, freshness_reason = false, "cdb-changed-during-proof"
    end
    if not fresh then
      return { v = self.protocol.VERSION, id = request.id, op = "catalog", ok = true, state = "unavailable",
        reason = freshness_reason, contexts = {},
        metrics = self.metrics({ total_ms = libclang.duration_ms(started) }) }
    end
    local cpp_paths, dep_paths, discovery = collect_evidence_files(
      request.evidence_roots,
      request.active_build,
      request.header
    )
    local cpp_records = {}
    for _, path in ipairs(cpp_paths) do
      local decoded = libclang.read_json(path)
      if decoded then
        cpp_records[#cpp_records + 1] = { record = decoded, evidence_path = path }
      end
    end

    local common = {
      compile_db = compile_db,
      membership_db = membership_db,
      header = request.header,
      project_root = request.project_root or request.engine_root,
      active_build_key = request.active_build_key,
      toolchain_identity = self.toolchain.toolchain_identity,
    }
    common.records = cpp_records
    local contexts = semantic_context.proven_contexts_from_cpp_json(common)

    local dep_contexts = {}
    local dep_context_error
    local commands_by_file = {}
    -- Build once per request and retain every command, including conflicting
    -- duplicates. A common header must not rescan the whole CDB per depfile.
    for _, entry in ipairs(compile_db.entries) do
      local key = semantic_context.match_key(entry.file)
      commands_by_file[key] = commands_by_file[key] or {}
      commands_by_file[key][#commands_by_file[key] + 1] = entry
    end
    for _, path in ipairs(dep_paths) do
      local text = libclang.read_all(path)
      local dep = text and semantic_context.parse_depfile(text) or nil
      local subject_in_dep = false
      if dep then
        local wanted = semantic_context.match_key(request.header)
        for _, dependency in ipairs(dep.dependencies or {}) do
          if semantic_context.match_key(dependency) == wanted then
            subject_in_dep = true
            break
          end
        end
      end
      if dep and subject_in_dep then
        local source_dependencies = {}
        local dependencies = {}
        for _, dependency in ipairs(dep.dependencies or {}) do
          dependencies[semantic_context.match_key(dependency)] = true
          if source_like(dependency) then
            source_dependencies[#source_dependencies + 1] = dependency
          end
        end
        local rsp_path = path:gsub("%.d$", ".o.rsp")
        local rsp_text = libclang.read_all(rsp_path)
        local rsp_tokens = rsp_text and semantic_context.parse_rsp_tokens(rsp_text) or nil
        local compile_file = semantic_context.rsp_source_file(rsp_tokens)
        if not compile_file and #source_dependencies == 1 then compile_file = source_dependencies[1] end

        local unity_members = {}
        local unity_text = compile_file and libclang.read_all(compile_file) or nil
        if unity_text then
          unity_members = semantic_context.parse_unity_membership(unity_text, compile_file) or {}
        end
        local compile, reason, donor_sources
        if compile_file then
          compile, reason, donor_sources = processed_compile(
            commands_by_file, membership_db, compile_file, unity_members, dependencies)
        end
        if compile then
          local context = semantic_context.make_proven_context({
            project_root = request.project_root or request.engine_root,
            active_build_key = request.active_build_key,
            origin_tu = compile_file,
            compile = compile,
            toolchain_identity = self.toolchain.toolchain_identity,
            evidence = {
              kind = rsp_tokens and "clang-d-rsp-unity" or "clang-d",
              header = libclang.normalize(request.header),
              depfile_path = path,
              rsp_path = rsp_path,
              unity_path = compile_file,
              unity_members = unity_members,
              donor_sources = donor_sources,
            },
          })
          if context then dep_contexts[#dep_contexts + 1] = context end
        elseif reason == "dep-context-donor-environment-conflict" or reason == "dep-context-main-file-unproven" then
          dep_context_error = reason
        end
      end
    end
    vim.list_extend(contexts, dep_contexts)
    if dep_context_error then contexts = {} end

    local unique, wire = {}, {}
    for _, context in ipairs(contexts) do
      if not unique[context.context_id] then
        unique[context.context_id] = true
        wire[#wire + 1] = {
          id = context.context_id,
          context_id = context.context_id,
          origin_tu = context.origin_tu,
          cdb_dir = libclang.normalize(request.cdb_dir),
          compile = context.compile,
          compile_command_fingerprint = context.compile_command_fingerprint,
          evidence_fingerprint = context.evidence_fingerprint,
          subject_membership = context.subject_membership,
          evidence_kind = context.evidence and context.evidence.kind,
          label = vim.fn.fnamemodify(context.origin_tu, ":t"),
        }
      end
    end
    table.sort(wire, function(a, b) return a.id < b.id end)

    local state = #wire == 0 and "unavailable"
      or (#wire == 1 and "resolved" or "ambiguous-context")
    return {
      v = self.protocol.VERSION,
      id = request.id,
      op = "catalog",
      ok = true,
      state = state,
      reason = dep_context_error or (#wire == 0 and "no-proven-context" or nil),
      contexts = wire,
      metrics = self.metrics({
        total_ms = libclang.duration_ms(started),
        cpp_json_scanned = #cpp_paths,
        depfiles_scanned = #dep_paths,
        evidence_discovery = discovery,
      }),
    }
  end
end

function M.new(deps)
  return setmetatable({
    toolchain = deps.toolchain, protocol = deps.protocol, metrics = assert(deps.metrics),
    compilation_databases = deps.compilation_databases or cdb_cache.new(),
  }, Catalog)
end

return M
