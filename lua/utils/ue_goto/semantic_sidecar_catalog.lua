local semantic_context = require("utils.ue_goto.semantic_context")
local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local cdb_shards = require("ue.cdb.shards")

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

function M.install(Sidecar)
  function Sidecar:handle_catalog(request)
    local started = libclang.uv.hrtime()
    local cdb_path = libclang.join(request.cdb_dir, "compile_commands.json")
    local active_cdb_path = request.active_cdb_path or cdb_path
    local fresh, freshness_reason = libclang.active_cdb_is_fresh(
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
        metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
      }
    end
    local entries = libclang.read_json(cdb_path)
    if type(entries) ~= "table" then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "catalog",
        ok = true,
        state = "unavailable",
        reason = "merged-compilation-database-unreadable",
        contexts = {},
        metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
      }
    end
    local active_entries = libclang.read_json(active_cdb_path)
    if type(active_entries) ~= "table" then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "catalog",
        ok = true,
        state = "unavailable",
        reason = "active-compilation-database-unreadable",
        contexts = {},
        metrics = self:_metrics({ total_ms = libclang.duration_ms(started) }),
      }
    end

    local compile_db = semantic_context.load_compilation_database(entries)
    local membership_db = semantic_context.load_compilation_database(active_entries)
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

    local dep_records = {}
    local dep_contexts = {}
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
        local compile_file
        local source_dependencies = {}
        for _, dependency in ipairs(dep.dependencies or {}) do
          if source_like(dependency) then
            source_dependencies[#source_dependencies + 1] = dependency
            if not compile_file then compile_file = dependency end
          end
        end
        local rsp_path = path:gsub("%.d$", ".o.rsp")
        local rsp_text = libclang.read_all(rsp_path)
        local rsp_tokens = rsp_text and semantic_context.parse_rsp_tokens(rsp_text) or nil
        compile_file = semantic_context.rsp_source_file(rsp_tokens) or compile_file

        local unity_members = {}
        local unity_text = compile_file and libclang.read_all(compile_file) or nil
        if unity_text then
          unity_members = semantic_context.parse_unity_membership(unity_text, compile_file) or {}
        end
        local donor = compile_file and compile_db.by_file[semantic_context.match_key(compile_file)] or nil
        if not donor then
          for _, dependency in ipairs(source_dependencies) do
            donor = compile_db.by_file[semantic_context.match_key(dependency)]
            if donor then break end
          end
        end
        if not donor then
          for _, member in ipairs(unity_members) do
            donor = compile_db.by_file[semantic_context.match_key(member)]
            if donor then break end
          end
        end

        local proven_members = {}
        for _, dependency in ipairs(source_dependencies) do
          if compile_db.by_file[semantic_context.match_key(dependency)] then
            proven_members[#proven_members + 1] = dependency
          end
        end
        if #proven_members > 0 then unity_members = proven_members end

        if compile_file and rsp_tokens and #rsp_tokens > 0 and donor then
          local argv = { donor.argv[1] }
          vim.list_extend(argv, rsp_tokens)
          local context = semantic_context.make_proven_context({
            project_root = request.project_root or request.engine_root,
            active_build_key = request.active_build_key,
            origin_tu = compile_file,
            compile = {
              file = compile_file,
              directory = donor.directory,
              argv = argv,
            },
            toolchain_identity = self.toolchain.toolchain_identity,
            evidence = {
              kind = "clang-d-rsp-unity",
              header = libclang.normalize(request.header),
              depfile_path = path,
              rsp_path = rsp_path,
              unity_path = compile_file,
              unity_members = unity_members,
            },
          })
          if context then dep_contexts[#dep_contexts + 1] = context end
        elseif compile_file then
          dep_records[#dep_records + 1] = {
            depfile = dep,
            depfile_path = path,
            compile_file = compile_file,
          }
        end
      end
    end
    common.records = dep_records
    vim.list_extend(contexts, semantic_context.proven_contexts_from_dep_records(common))
    vim.list_extend(contexts, dep_contexts)

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
      reason = #wire == 0 and "no-proven-context" or nil,
      contexts = wire,
      metrics = self:_metrics({
        total_ms = libclang.duration_ms(started),
        cpp_json_scanned = #cpp_paths,
        depfiles_scanned = #dep_paths,
        evidence_discovery = discovery,
      }),
    }
  end
end

return M
