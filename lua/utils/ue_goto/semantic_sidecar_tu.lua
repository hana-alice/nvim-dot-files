local libclang = require("utils.ue_goto.semantic_sidecar_libclang")

local M = {}

function M.install(Sidecar)
  function Sidecar:_tu_count()
    local count = 0
    for _ in pairs(self.tus) do
      count = count + 1
    end
    return count
  end

  function Sidecar:_rss_bytes()
    if libclang.uv.resident_set_memory then
      local ok, rss = pcall(libclang.uv.resident_set_memory)
      if ok and type(rss) == "number" then
        return rss
      end
    end
    return 0
  end

  function Sidecar:_metrics(extra)
    extra = extra or {}
    extra.tu_count = self:_tu_count()
    extra.process_rss_bytes = self:_rss_bytes()
    extra.max_tus = self.max_tus
    extra.idle_evict_ms = self.idle_evict_ms
    return extra
  end

  function Sidecar:_diagnostics(entry)
    if entry.diagnostics == nil then
      entry.diagnostics = libclang.collect_diagnostics(self.toolchain.lib, entry.tu)
    end
    return entry.diagnostics
  end

  function Sidecar:_dispose_tu(entry)
    if entry and entry.tu ~= nil then
      self.toolchain.lib.clang_disposeTranslationUnit(entry.tu)
      entry.tu = nil
    end
  end

  function Sidecar:_dispose_cdb(cdb)
    if cdb and cdb.db ~= nil then
      self.toolchain.lib.clang_CompilationDatabase_dispose(cdb.db)
      cdb.db = nil
    end
  end

  function Sidecar:shutdown()
    for _, entry in pairs(self.tus) do
      self:_dispose_tu(entry)
    end
    self.tus = {}
    for _, cdb in pairs(self.cdbs) do
      self:_dispose_cdb(cdb)
    end
    self.cdbs = {}
    if self.index ~= nil then
      self.toolchain.lib.clang_disposeIndex(self.index)
      self.index = nil
    end
  end

  function Sidecar:_prune_idle(now)
    now = now or libclang.now_ms()
    for key, entry in pairs(self.tus) do
      if now - entry.last_used_ms >= self.idle_evict_ms then
        self:_dispose_tu(entry)
        self.tus[key] = nil
      end
    end
  end

  function Sidecar:_prune_lru()
    local count = self:_tu_count()
    if count <= self.max_tus then return end
    local entries = {}
    for key, entry in pairs(self.tus) do
      entries[#entries + 1] = { key = key, last_used_ms = entry.last_used_ms }
    end
    table.sort(entries, function(a, b) return a.last_used_ms < b.last_used_ms end)
    for i = 1, count - self.max_tus do
      local victim = self.tus[entries[i].key]
      self:_dispose_tu(victim)
      self.tus[entries[i].key] = nil
    end
  end

  function Sidecar:_get_cdb(cdb_dir)
    cdb_dir = libclang.normalize(cdb_dir)
    local cached = self.cdbs[cdb_dir]
    if cached and cached.db ~= nil then
      return cached
    end
    local error_code = libclang.ffi.new("CXCompilationDatabase_Error[1]")
    local db = self.toolchain.lib.clang_CompilationDatabase_fromDirectory(cdb_dir, error_code)
    if db == nil then
      return nil, {
        reason = "cdb-load-failed",
        cdb_dir = cdb_dir,
        code = libclang.map_cdb_error(error_code[0]),
      }
    end
    local record = { dir = cdb_dir, db = db }
    self.cdbs[cdb_dir] = record
    return record
  end

  function Sidecar:_read_compile_command(ctx)
    if type(ctx.compile) == "table" and type(ctx.compile.argv) == "table"
        and #ctx.compile.argv > 0 and type(ctx.compile.directory) == "string"
        and ctx.compile.directory ~= "" then
      local compile = {
        cwd = libclang.normalize(ctx.compile.directory),
        origin_tu = libclang.normalize(ctx.compile.file or ctx.origin_tu),
        argv = libclang.shallow_copy(ctx.compile.argv),
      }
      compile.fingerprint = libclang.sha256(vim.json.encode({
        cwd = compile.cwd,
        origin_tu = compile.origin_tu,
        argv = compile.argv,
      }))
      return compile
    end
    local cdb, cdb_err = self:_get_cdb(ctx.cdb_dir)
    if not cdb then
      return nil, cdb_err
    end
    local commands = self.toolchain.lib.clang_CompilationDatabase_getCompileCommands(
      cdb.db,
      libclang.normalize(ctx.origin_tu)
    )
    if commands == nil then
      return nil, {
        reason = "compile-command-missing",
        cdb_dir = libclang.normalize(ctx.cdb_dir),
        origin_tu = libclang.normalize(ctx.origin_tu),
      }
    end
    local size = tonumber(self.toolchain.lib.clang_CompileCommands_getSize(commands))
    if size < 1 then
      self.toolchain.lib.clang_CompileCommands_dispose(commands)
      return nil, {
        reason = "compile-command-missing",
        cdb_dir = libclang.normalize(ctx.cdb_dir),
        origin_tu = libclang.normalize(ctx.origin_tu),
      }
    end

    local command = self.toolchain.lib.clang_CompileCommands_getCommand(commands, 0)
    local cwd = libclang.cxstring_to_string(
      self.toolchain.lib,
      self.toolchain.lib.clang_CompileCommand_getDirectory(command)
    )
    local origin = libclang.cxstring_to_string(
      self.toolchain.lib,
      self.toolchain.lib.clang_CompileCommand_getFilename(command)
    )
    local argc = tonumber(self.toolchain.lib.clang_CompileCommand_getNumArgs(command))
    local argv = {}
    for i = 0, argc - 1 do
      argv[#argv + 1] = libclang.cxstring_to_string(
        self.toolchain.lib,
        self.toolchain.lib.clang_CompileCommand_getArg(command, i)
      )
    end
    self.toolchain.lib.clang_CompileCommands_dispose(commands)

    if cwd == "" or origin == "" or #argv == 0 then
      return nil, {
        reason = "compile-command-invalid",
        cdb_dir = libclang.normalize(ctx.cdb_dir),
        origin_tu = libclang.normalize(ctx.origin_tu),
      }
    end

    local compile = {
      cwd = libclang.normalize(cwd),
      origin_tu = libclang.normalize(origin),
      argv = argv,
    }
    compile.fingerprint = libclang.sha256(vim.json.encode({
      cwd = compile.cwd,
      origin_tu = compile.origin_tu,
      argv = compile.argv,
    }))
    return compile
  end

  function Sidecar:_ensure_tu(ctx, overlays)
    overlays = overlays or {}
    local compile, compile_err = self:_read_compile_command(ctx)
    if not compile then
      return nil, nil, compile_err
    end

    local cache_key = libclang.sha256(vim.json.encode({
      libclang.normalize(ctx.origin_tu),
      libclang.normalize(ctx.cdb_dir),
      compile.fingerprint,
      self.toolchain.toolchain_identity,
    }))
    local overlay_hash = libclang.overlays_key(overlays)
    local query_kind = "warm"
    local parse_ms = 0
    local reparse_ms = 0
    local diagnostics = {}

    local entry = self.tus[cache_key]
    local unsaved_files, keepalive = libclang.make_unsaved_files(overlays)

    if not entry then
      local parse_args = libclang.semantic_parse_args(compile.argv)
      local argv_buf = libclang.ffi.new("const char *[?]", #parse_args)
      for i, value in ipairs(parse_args) do
        argv_buf[i - 1] = value
      end
      local out = libclang.ffi.new("CXTranslationUnit[1]")
      local started = libclang.uv.hrtime()
      local previous_cwd = libclang.uv.cwd()
      local ok_chdir, changed = pcall(libclang.uv.chdir, compile.cwd)
      if not ok_chdir or changed == nil then
        return nil, nil, {
          reason = "compile-working-directory-unavailable",
          compile_command_fingerprint = compile.fingerprint,
        }
      end
      local ok_parse, code = pcall(
        self.toolchain.lib.clang_parseTranslationUnit2,
        self.index,
        nil,
        argv_buf,
        #parse_args,
        unsaved_files,
        #overlays,
        libclang.CX_TRANSLATION_UNIT_KEEP_GOING + libclang.CX_TRANSLATION_UNIT_PRECOMPILED_PREAMBLE,
        out
      )
      pcall(libclang.uv.chdir, previous_cwd)
      parse_ms = libclang.duration_ms(started)
      if not ok_parse or tonumber(code) ~= 0 or out[0] == nil then
        return nil, nil, {
          reason = "parse-failed",
          code = ok_parse and libclang.map_parse_error(code) or "ffi-call-failed",
          compile_command_fingerprint = compile.fingerprint,
          diagnostics = diagnostics,
        }
      end
      entry = {
        key = cache_key,
        tu = out[0],
        context_id = ctx.id,
        compile = compile,
        overlay_hash = overlay_hash,
        epoch = 1,
        last_used_ms = libclang.now_ms(),
        parse_ms = parse_ms,
        reparse_ms = 0,
        keepalive = keepalive,
        diagnostics = nil,
      }
      self.tus[cache_key] = entry
      query_kind = "cold"
    elseif entry.overlay_hash ~= overlay_hash then
      local started = libclang.uv.hrtime()
      local code = self.toolchain.lib.clang_reparseTranslationUnit(entry.tu, #overlays, unsaved_files, 0)
      reparse_ms = libclang.duration_ms(started)
      if tonumber(code) ~= 0 then
        return nil, nil, {
          reason = "reparse-failed",
          code = libclang.map_parse_error(code),
          compile_command_fingerprint = compile.fingerprint,
        }
      end
      entry.overlay_hash = overlay_hash
      entry.epoch = entry.epoch + 1
      entry.reparse_ms = reparse_ms
      entry.keepalive = keepalive
      entry.diagnostics = nil
      query_kind = "reparse"
    end

    entry.last_used_ms = libclang.now_ms()
    entry.context_id = ctx.id
    self:_prune_lru()

    return entry, {
      query_kind = query_kind,
      cold_parse_ms = parse_ms,
      reparse_ms = reparse_ms,
      compile_command_fingerprint = compile.fingerprint,
    }, nil
  end

  function Sidecar:_resolve_context(ctx, query, overlays)
    local entry, compile_meta, compile_err = self:_ensure_tu(ctx, overlays)
    if not entry then
      return {
        context_id = ctx.id,
        state = "unavailable",
        reason = compile_err.reason,
        diagnostics = compile_err.diagnostics or {},
        compile_command_fingerprint = compile_err.compile_command_fingerprint,
        error = compile_err,
      }, compile_meta
    end

    local started = libclang.uv.hrtime()
    local tu = entry.tu
    local file = self.toolchain.lib.clang_getFile(tu, libclang.normalize(query.path))
    if file == nil then
      return {
        context_id = ctx.id,
        state = "invalid-semantic-context",
        reason = "invalid-query-file-not-in-tu",
        diagnostics = self:_diagnostics(entry),
        compile_command_fingerprint = compile_meta.compile_command_fingerprint,
      }, compile_meta
    end

    local loc = self.toolchain.lib.clang_getLocation(tu, file, query.line, query.column)
    local cursor = self.toolchain.lib.clang_getCursor(tu, loc)
    local kind_spelling = libclang.cxstring_to_string(
      self.toolchain.lib,
      self.toolchain.lib.clang_getCursorKindSpelling(cursor.kind)
    )
    if self.toolchain.lib.clang_Cursor_isNull(cursor) ~= 0 or self.toolchain.lib.clang_isInvalid(cursor.kind) ~= 0 then
      return {
        context_id = ctx.id,
        state = "invalid-semantic-context",
        reason = "invalid-cursor",
        cursor_kind = kind_spelling,
        diagnostics = self:_diagnostics(entry),
        compile_command_fingerprint = compile_meta.compile_command_fingerprint,
      }, vim.tbl_extend("force", compile_meta, { query_ms = libclang.duration_ms(started) })
    end

    local referenced = self.toolchain.lib.clang_getCursorReferenced(cursor)
    local base = referenced
    if self.toolchain.lib.clang_Cursor_isNull(base) ~= 0 then
      base = cursor
    end
    if self.toolchain.lib.clang_Cursor_isNull(base) ~= 0 then
      return {
        context_id = ctx.id,
        state = "invalid-semantic-context",
        reason = "invalid-null-referenced-cursor",
        cursor_kind = kind_spelling,
        diagnostics = self:_diagnostics(entry),
        compile_command_fingerprint = compile_meta.compile_command_fingerprint,
      }, vim.tbl_extend("force", compile_meta, { query_ms = libclang.duration_ms(started) })
    end

    local canonical = self.toolchain.lib.clang_getCanonicalCursor(base)
    local usr = libclang.cxstring_to_string(self.toolchain.lib, self.toolchain.lib.clang_getCursorUSR(canonical))
    if usr == "" then
      return {
        context_id = ctx.id,
        state = "invalid-semantic-context",
        reason = "invalid-empty-usr",
        cursor_kind = kind_spelling,
        diagnostics = self:_diagnostics(entry),
        compile_command_fingerprint = compile_meta.compile_command_fingerprint,
      }, vim.tbl_extend("force", compile_meta, { query_ms = libclang.duration_ms(started) })
    end

    local declaration = libclang.location_from_cursor(self.toolchain.lib, canonical)
    if not declaration then
      return {
        context_id = ctx.id,
        state = "invalid-semantic-context",
        reason = "invalid-declaration-location-missing",
        cursor_kind = kind_spelling,
        diagnostics = self:_diagnostics(entry),
        compile_command_fingerprint = compile_meta.compile_command_fingerprint,
      }, vim.tbl_extend("force", compile_meta, { query_ms = libclang.duration_ms(started) })
    end

    local definition_cursor = self.toolchain.lib.clang_getCursorDefinition(canonical)
    local definition = nil
    if self.toolchain.lib.clang_Cursor_isNull(definition_cursor) == 0 then
      definition = libclang.location_from_cursor(self.toolchain.lib, definition_cursor)
    end

    local query_ms = libclang.duration_ms(started)
    return {
      context_id = ctx.id,
      state = "resolved",
      usr = usr,
      declaration = declaration,
      definition = definition,
      document_version = query.document_version or 0,
      epoch = entry.epoch,
      compile_command_fingerprint = compile_meta.compile_command_fingerprint,
    }, vim.tbl_extend("force", compile_meta, { query_ms = query_ms })
  end
end

return M
