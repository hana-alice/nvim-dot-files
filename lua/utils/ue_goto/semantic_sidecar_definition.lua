local libclang = require("utils.ue_goto.semantic_sidecar_libclang")
local semantic_context = require("utils.ue_goto.semantic_context")

local M = {}

local function normalize_members(raw)
  if type(raw) == "string" then
    raw = { raw }
  end
  if type(raw) ~= "table" then
    return {}
  end
  local out, seen = {}, {}
  for _, path in ipairs(raw) do
    local normalized = libclang.normalize(path)
    local key = normalized:lower()
    if normalized ~= "" and not seen[key] then
      seen[key] = true
      out[#out + 1] = normalized
    end
  end
  table.sort(out)
  return out
end

local function normalized_match_path(path)
  return libclang.normalize(path):gsub("\\", "/"):lower()
end

local function suffix_boundary_match(path, suffix)
  local haystack = normalized_match_path(path)
  local needle = normalized_match_path(suffix):gsub("^/+", "")
  if needle == "" then return false end
  if haystack == needle then return true end
  if #haystack <= #needle then return false end
  if haystack:sub(-#needle) ~= needle then return false end
  return haystack:sub(-#needle - 1, -#needle - 1) == "/"
end

local function path_matches_controlled_subject(path, module_root, members)
  for _, member in ipairs(members or {}) do
    if suffix_boundary_match(path, member) then
      return true
    end
  end
  local root = normalized_match_path(module_root):gsub("^/+", ""):gsub("/+$", "")
  if root == "" then return false end
  local haystack = normalized_match_path(path)
  local marker = "/" .. root
  if haystack == root or haystack:find(marker .. "/", 1, true) or haystack:sub(-#marker) == marker then
    return true
  end
  return false
end

local function make_cursor_shim_fn_table(lib)
  local table_ptr = libclang.ffi.new("UECursorShimFns[1]")
  table_ptr[0].clang_getCString = lib.clang_getCString
  table_ptr[0].clang_disposeString = lib.clang_disposeString
  table_ptr[0].clang_isDeclaration = lib.clang_isDeclaration
  table_ptr[0].clang_getTranslationUnitCursor = lib.clang_getTranslationUnitCursor
  table_ptr[0].clang_visitChildren = lib.clang_visitChildren
  table_ptr[0].clang_getCanonicalCursor = lib.clang_getCanonicalCursor
  table_ptr[0].clang_getCursorUSR = lib.clang_getCursorUSR
  table_ptr[0].clang_getCursorDefinition = lib.clang_getCursorDefinition
  table_ptr[0].clang_Cursor_isNull = lib.clang_Cursor_isNull
  table_ptr[0].clang_getCursorLocation = lib.clang_getCursorLocation
  table_ptr[0].clang_getExpansionLocation = lib.clang_getExpansionLocation
  table_ptr[0].clang_getFileName = lib.clang_getFileName
  return table_ptr
end

function M.install(Sidecar, deps)
  local location_key = deps.location_key

  function Sidecar:_read_controlled_cdb(cdb_path)
    cdb_path = libclang.normalize(cdb_path)
    local signature = libclang.file_signature(cdb_path)
    if not signature then
      return nil, { reason = "lookup-cdb-unreadable", cdb_path = cdb_path }
    end
    local cache = self.controlled_cdb_cache[cdb_path]
    if cache and cache.signature == signature then
      return cache
    end

    local decoded = libclang.read_json(cdb_path)
    if type(decoded) ~= "table" then
      return nil, { reason = "lookup-cdb-invalid-json", cdb_path = cdb_path }
    end

    local contexts = {}
    for _, entry in ipairs(decoded) do
      local compile = semantic_context.parse_compilation_entry(entry)
      if compile then
        local module_root = libclang.normalize(
          entry.nvim_ue_module_root or entry.module_root or ""
        )
        local members = normalize_members(entry.nvim_ue_members or entry.members)
        if module_root ~= "" and #members > 0 then
          contexts[#contexts + 1] = {
            id = libclang.sha256(vim.json.encode({
              cdb_path,
              compile.file,
              compile.directory,
              compile.argv,
              module_root,
              members,
            })),
            origin_tu = compile.file,
            cdb_dir = libclang.dirname(cdb_path),
            compile = compile,
            module_root = module_root,
            members = members,
            compile_command_fingerprint = libclang.sha256(vim.json.encode({
              compile.file,
              compile.directory,
              compile.argv,
            })),
          }
        end
      end
    end

    local record = {
      path = cdb_path,
      signature = signature,
      contexts = contexts,
    }
    self.controlled_cdb_cache[cdb_path] = record
    return record
  end

  function Sidecar:_select_controlled_cdb(cdb_paths, subject_path)
    local subject = libclang.normalize(subject_path)
    for _, path in ipairs(cdb_paths or {}) do
      local record, err = self:_read_controlled_cdb(path)
      if record then
        local matched = {}
        for _, context in ipairs(record.contexts) do
          if path_matches_controlled_subject(subject, context.module_root, context.members) then
            matched[#matched + 1] = context
          end
        end
        if #matched > 0 then
          table.sort(matched, function(a, b)
            return tostring(a.origin_tu) < tostring(b.origin_tu)
          end)
          return record, matched
        end
      elseif err then
        return nil, nil, err
      end
    end
    return nil, {}, nil
  end

  function Sidecar:_collect_usr_definition(entry, usr, shim)
    if not self.cursor_shim_fns then
      self.cursor_shim_fns = make_cursor_shim_fn_table(self.toolchain.lib)
    end
    local result = libclang.ffi.new("UECursorShimResult[1]")
    local code = tonumber(shim.handle.ue_clang_cursor_shim_lookup_definitions(
      self.cursor_shim_fns,
      entry.tu,
      usr,
      result
    ))
    local frame = result[0]
    local definitions = {}
    if code ~= 0 and frame.error_code == 0 then
      frame.error_code = code
    end
    for i = 0, tonumber(frame.count or 0) - 1 do
      local item = frame.definitions[i]
      local definition = {
        path = libclang.normalize(libclang.ffi.string(item.path)),
        line = tonumber(item.line),
        column = tonumber(item.column),
        offset = tonumber(item.offset),
      }
      local key = location_key(definition)
      if key then
        definitions[key] = definition
      end
    end
    return definitions, {
      abi_version = tonumber(frame.abi_version or 0),
      visited_declarations = tonumber(frame.visited_declarations or 0),
      matched_declarations = tonumber(frame.matched_declarations or 0),
      overflow = tonumber(frame.overflow or 0) ~= 0,
      error_code = tonumber(frame.error_code or 0),
    }
  end

  function Sidecar:_lookup_definition_cache_key(request)
    local signatures = {}
    for _, path in ipairs(request.cdb_paths or {}) do
      local signature = libclang.file_signature(path)
      signatures[#signatures + 1] = {
        path = libclang.normalize(path),
        signature = signature or "missing",
      }
    end
    return libclang.sha256(vim.json.encode({
      request.usr,
      signatures,
      libclang.overlays_key(request.overlays or {}),
      self.toolchain.toolchain_identity,
    }))
  end

  function Sidecar:_lookup_definition_metrics(started, extra)
    extra = extra or {}
    extra.total_ms = libclang.duration_ms(started)
    return self:_metrics(extra)
  end

  function Sidecar:handle_lookup_definition(request)
    local started = libclang.uv.hrtime()
    if not self.toolchain.ok then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = self.toolchain.reason,
        probes = self.toolchain.probes,
        metrics = self:_lookup_definition_metrics(started, { cache_hit = false }),
      }
    end

    local usr = tostring(request.usr or "")
    if usr == "" then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = "lookup-usr-missing",
        metrics = self:_lookup_definition_metrics(started, { cache_hit = false }),
      }
    end
    local subject_path = libclang.normalize(request.subject or "")
    if subject_path == "" then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = "lookup-subject-missing",
        metrics = self:_lookup_definition_metrics(started, { cache_hit = false }),
      }
    end
    if type(request.cdb_paths) ~= "table" or #request.cdb_paths == 0 then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = "lookup-cdb-paths-missing",
        metrics = self:_lookup_definition_metrics(started, { cache_hit = false }),
      }
    end

    local cache_key = self:_lookup_definition_cache_key(request)
    local cached = self.lookup_cache[cache_key]
    if cached then
      local frame = vim.deepcopy(cached)
      frame.id = request.id
      frame.subject = subject_path
      frame.document_version = tonumber(request.document_version or 0) or 0
      frame.metrics = self:_lookup_definition_metrics(started, {
        cache_hit = true,
        shim_abi_version = self.cursor_shim_abi_version,
        query_kinds = { { context_id = "lookup-cache", kind = "warm-cache" } },
      })
      return frame
    end

    local record, contexts, cdb_err = self:_select_controlled_cdb(request.cdb_paths, subject_path)
    if cdb_err then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = cdb_err.reason,
        metrics = self:_lookup_definition_metrics(started, { cache_hit = false }),
      }
    end
    if not record or #contexts == 0 then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = "lookup-no-subject-module-contexts",
        metrics = self:_lookup_definition_metrics(started, { cache_hit = false }),
      }
    end
    if #contexts > 64 then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = "lookup-context-limit-exceeded",
        metrics = self:_lookup_definition_metrics(started, {
          cache_hit = false,
          selected_cdb_signature = record.signature,
        }),
      }
    end

    local shim, shim_err = libclang.ensure_cursor_shim(self.toolchain)
    if not shim then
      return {
        v = self.protocol.VERSION,
        id = request.id,
        op = "lookup-definition",
        ok = true,
        state = "unavailable",
        reason = shim_err.reason,
        metrics = self:_lookup_definition_metrics(started, {
          cache_hit = false,
        }),
      }
    end
    self.cursor_shim_abi_version = shim.abi_version

    self:_prune_idle(libclang.now_ms())

    local all_definitions, query_kinds = {}, {}
    local contexts_summary = {}
    local aggregate_cold_parse_ms, aggregate_reparse_ms = 0, 0
    local shim_overflow = false
    for _, ctx in ipairs(contexts) do
      local entry, meta, compile_err = self:_ensure_tu(ctx, request.overlays or {})
      if entry then
        aggregate_cold_parse_ms = aggregate_cold_parse_ms + (meta.cold_parse_ms or 0)
        aggregate_reparse_ms = aggregate_reparse_ms + (meta.reparse_ms or 0)
        query_kinds[#query_kinds + 1] = {
          context_id = ctx.id,
          kind = meta.query_kind,
        }
        local definitions, shim_meta = self:_collect_usr_definition(entry, usr, shim)
        local definition_count = 0
        for key, definition in pairs(definitions) do
          definition_count = definition_count + 1
          all_definitions[key] = all_definitions[key] or definition
        end
        shim_overflow = shim_overflow or shim_meta.overflow
        contexts_summary[#contexts_summary + 1] = {
          context_id = ctx.id,
          origin_tu = ctx.origin_tu,
          definition_count = definition_count,
          visited_declarations = shim_meta.visited_declarations,
          matched_declarations = shim_meta.matched_declarations,
          shim_error_code = shim_meta.error_code,
          compile_command_fingerprint = meta.compile_command_fingerprint,
        }
      else
        contexts_summary[#contexts_summary + 1] = {
          context_id = ctx.id,
          origin_tu = ctx.origin_tu,
          state = "unavailable",
          reason = compile_err and compile_err.reason or "compile-command-missing",
        }
      end
    end

    local definition_keys = vim.tbl_keys(all_definitions)
    table.sort(definition_keys)
    local base_frame = {
      v = self.protocol.VERSION,
      op = "lookup-definition",
      ok = true,
      usr = usr,
      subject = subject_path,
      document_version = tonumber(request.document_version or 0) or 0,
      contexts = contexts_summary,
      selected_cdb_signature = record.signature,
    }

    local frame
    if shim_overflow then
      frame = vim.tbl_extend("force", base_frame, {
        state = "unavailable",
        reason = "lookup-definition-overflow",
      })
    elseif #definition_keys == 1 then
      frame = vim.tbl_extend("force", base_frame, {
        state = "resolved",
        definition = all_definitions[definition_keys[1]],
      })
    elseif #definition_keys == 0 then
      frame = vim.tbl_extend("force", base_frame, {
        state = "unavailable",
        reason = "definition-not-found",
      })
    else
      frame = vim.tbl_extend("force", base_frame, {
        state = "unavailable",
        reason = "multiple-definitions",
        definitions = vim.tbl_map(function(key) return all_definitions[key] end, definition_keys),
      })
    end

    if frame.state == "resolved" then
      self.lookup_cache[cache_key] = vim.deepcopy(frame)
    end
    frame.id = request.id
    frame.metrics = self:_lookup_definition_metrics(started, {
      cache_hit = false,
      shim_abi_version = shim.abi_version,
      query_kinds = query_kinds,
      cold_parse_ms = aggregate_cold_parse_ms,
      reparse_ms = aggregate_reparse_ms,
      selected_cdb_signature = record.signature,
    })
    return frame
  end
end

return M
