local ffi = require("ffi")

local platform = require("utils.platform")

local M = {}

local uv = vim.uv or vim.loop

M.ffi = ffi
M.uv = uv
M.CX_TRANSLATION_UNIT_KEEP_GOING = 0x200
M.CX_TRANSLATION_UNIT_PRECOMPILED_PREAMBLE = 0x04

ffi.cdef([[
typedef struct {
  const void *data;
  unsigned private_flags;
} CXString;

typedef struct CXFileImpl *CXFile;
typedef struct CXTranslationUnitImpl *CXTranslationUnit;
typedef struct CXIndexImpl *CXIndex;
typedef struct CXDiagnosticImpl *CXDiagnostic;
typedef struct CXCompilationDatabaseImpl *CXCompilationDatabase;
typedef struct CXCompileCommandsImpl *CXCompileCommands;
typedef struct CXCompileCommandImpl *CXCompileCommand;

typedef struct {
  const void *ptr_data[2];
  unsigned int_data;
} CXSourceLocation;

typedef struct {
  unsigned kind;
  int xdata;
  const void *data[3];
} CXCursor;

typedef struct {
  const char *Filename;
  const char *Contents;
  unsigned Length;
} CXUnsavedFile;

typedef unsigned CXCompilationDatabase_Error;
typedef unsigned CXErrorCode;

const char *clang_getCString(CXString string);
void clang_disposeString(CXString string);
CXString clang_getClangVersion(void);
CXString clang_getCursorUSR(CXCursor);
CXString clang_getCursorKindSpelling(unsigned kind);
CXString clang_getFileName(CXFile file);
CXString clang_formatDiagnostic(CXDiagnostic Diagnostic, unsigned Options);
unsigned clang_defaultDiagnosticDisplayOptions(void);

CXIndex clang_createIndex(int excludeDeclarationsFromPCH, int displayDiagnostics);
void clang_disposeIndex(CXIndex index);

CXCompilationDatabase clang_CompilationDatabase_fromDirectory(
  const char *BuildDir,
  CXCompilationDatabase_Error *ErrorCode
);
void clang_CompilationDatabase_dispose(CXCompilationDatabase);
CXCompileCommands clang_CompilationDatabase_getCompileCommands(
  CXCompilationDatabase,
  const char *CompleteFileName
);
void clang_CompileCommands_dispose(CXCompileCommands);
unsigned clang_CompileCommands_getSize(CXCompileCommands);
CXCompileCommand clang_CompileCommands_getCommand(CXCompileCommands, unsigned I);
CXString clang_CompileCommand_getDirectory(CXCompileCommand);
CXString clang_CompileCommand_getFilename(CXCompileCommand);
unsigned clang_CompileCommand_getNumArgs(CXCompileCommand);
CXString clang_CompileCommand_getArg(CXCompileCommand, unsigned I);

CXErrorCode clang_parseTranslationUnit2(
  CXIndex CIdx,
  const char *source_filename,
  const char *const *command_line_args,
  int num_command_line_args,
  CXUnsavedFile *unsaved_files,
  unsigned num_unsaved_files,
  unsigned options,
  CXTranslationUnit *out_TU
);
int clang_reparseTranslationUnit(
  CXTranslationUnit TU,
  unsigned num_unsaved_files,
  CXUnsavedFile *unsaved_files,
  unsigned options
);
void clang_disposeTranslationUnit(CXTranslationUnit);

CXFile clang_getFile(CXTranslationUnit tu, const char *file_name);
CXSourceLocation clang_getLocation(CXTranslationUnit tu, CXFile file, unsigned line, unsigned column);
void clang_getExpansionLocation(
  CXSourceLocation location,
  CXFile *file,
  unsigned *line,
  unsigned *column,
  unsigned *offset
);
CXCursor clang_getCursor(CXTranslationUnit, CXSourceLocation);
unsigned clang_Cursor_isNull(CXCursor cursor);
unsigned clang_isInvalid(unsigned kind);
CXCursor clang_getCursorReferenced(CXCursor);
CXCursor clang_getCanonicalCursor(CXCursor);
CXCursor clang_getCursorDefinition(CXCursor);
CXSourceLocation clang_getCursorLocation(CXCursor);

unsigned clang_getNumDiagnostics(CXTranslationUnit Unit);
CXDiagnostic clang_getDiagnostic(CXTranslationUnit Unit, unsigned Index);
void clang_disposeDiagnostic(CXDiagnostic Diagnostic);
]])

function M.normalize(path)
  return vim.fs.normalize(tostring(path or ""))
end

function M.now_ms()
  return math.floor((uv.hrtime() or 0) / 1000000)
end

function M.duration_ms(start_ns)
  return math.floor(((uv.hrtime() or start_ns) - start_ns) / 1000000)
end

function M.cxstring_to_string(lib, value)
  local cstr = lib.clang_getCString(value)
  local out = cstr ~= nil and ffi.string(cstr) or ""
  lib.clang_disposeString(value)
  return out
end

function M.file_exists(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "file" or false
end

function M.dir_exists(path)
  local stat = uv.fs_stat(path)
  return stat and stat.type == "directory" or false
end

function M.read_all(path)
  local file = io.open(path, "rb")
  if not file then return nil end
  local contents = file:read("*a")
  file:close()
  return contents
end

function M.read_json(path)
  local contents = M.read_all(path)
  if not contents or contents == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, contents)
  return ok and decoded or nil
end

local function mtime_before(left, right)
  local lm, rm = left and left.mtime, right and right.mtime
  if not lm or not rm then return false end
  if lm.sec ~= rm.sec then return lm.sec < rm.sec end
  return (lm.nsec or 0) < (rm.nsec or 0)
end

function M.active_cdb_is_fresh(cdb_path, active_cdb_path, manifest_path)
  local merged = M.uv.fs_stat(cdb_path)
  local active = M.uv.fs_stat(active_cdb_path)
  if not merged or merged.type ~= "file" then return false, "merged-cdb-unreadable" end
  if not active or active.type ~= "file" then return false, "active-cdb-unreadable" end
  if M.normalize(cdb_path):lower() ~= M.normalize(active_cdb_path):lower()
      and mtime_before(merged, active) then
    return false, "merged-cdb-predates-active-shard"
  end
  if manifest_path and manifest_path ~= "" then
    local manifest = M.uv.fs_stat(manifest_path)
    if not manifest or manifest.type ~= "file" then
      return false, "active-manifest-unreadable"
    end
    if mtime_before(merged, manifest) then
      return false, "merged-cdb-predates-active-selection"
    end
  end
  return true
end

function M.dirname(path)
  return vim.fn.fnamemodify(path, ":h")
end

function M.join(...)
  return M.normalize(table.concat({ ... }, "/"))
end

function M.sha256(payload)
  local ok, digest = pcall(vim.fn.sha256, payload)
  if ok and type(digest) == "string" and digest ~= "" then
    return digest
  end
  return payload
end

function M.table_is_array(value)
  if type(value) ~= "table" then return false end
  local n = #value
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key > n or key % 1 ~= 0 then
      return false
    end
  end
  return true
end

function M.shallow_copy(list)
  local out = {}
  for i, value in ipairs(list or {}) do
    out[i] = value
  end
  return out
end

function M.unique_strings(values)
  local out, seen = {}, {}
  for _, value in ipairs(values or {}) do
    if type(value) == "string" and value ~= "" and not seen[value] then
      seen[value] = true
      out[#out + 1] = value
    end
  end
  return out
end

function M.resolve_executable(candidate)
  candidate = M.normalize(candidate)
  if candidate == "" then return nil end
  if candidate:find("/", 1, true) then
    return M.file_exists(candidate) and candidate or nil
  end
  local path = vim.fn.exepath(candidate)
  if type(path) == "string" and path ~= "" then
    return M.normalize(path)
  end
  return nil
end

function M.sibling_libclang_candidates(clangd_path)
  local driver = platform.driver()
  local bin_dir = M.dirname(clangd_path)
  local parent = M.dirname(bin_dir)
  local suffix = driver.id == "windows" and "dll"
    or (driver.id == "macos" and "dylib" or "so")
  return M.unique_strings({
    M.join(bin_dir, "libclang." .. suffix),
    M.join(parent, "lib", "libclang." .. suffix),
    M.join(parent, "lib64", "libclang." .. suffix),
    "libclang." .. suffix,
  })
end

function M.discover_clangd_candidates()
  local candidates = {}

  local override = M.normalize(vim.env.UE_CLANGD or "")
  if override ~= "" then
    candidates[#candidates + 1] = override
  end

  local ok_cfg, cfg = pcall(require, "ue.config")
  if ok_cfg and cfg and cfg.get then
    local extra = cfg.get("clangd.candidates_extra")
    if M.table_is_array(extra) then
      for _, candidate in ipairs(extra) do
        candidates[#candidates + 1] = candidate
      end
    end
  end

  local ok_ue, ue = pcall(require, "ue")
  if ok_ue and ue and ue.clangd_cmd then
    local cmd = ue.clangd_cmd(vim.loop.cwd())
    if type(cmd) == "table" and type(cmd[1]) == "string" then
      candidates[#candidates + 1] = cmd[1]
    end
  end

  vim.list_extend(candidates, platform.driver().default_clangd_candidates())
  return M.unique_strings(candidates)
end

function M.discover_toolchain(opts)
  opts = opts or {}
  local probes = {
    clangd_candidates = {},
    libclang_candidates = {},
  }

  local clangd_candidates = opts.clangd_candidates or M.discover_clangd_candidates()
  for _, candidate in ipairs(clangd_candidates) do
    probes.clangd_candidates[#probes.clangd_candidates + 1] = candidate
    local resolved = M.resolve_executable(candidate)
    if resolved then
      local libclang_candidates = opts.libclang_candidates or M.sibling_libclang_candidates(resolved)
      for _, lib_candidate in ipairs(libclang_candidates) do
        probes.libclang_candidates[#probes.libclang_candidates + 1] = lib_candidate
        local resolved_lib = lib_candidate:find("/", 1, true) and M.normalize(lib_candidate) or lib_candidate
        local ok_lib, handle = pcall(ffi.load, resolved_lib)
        if ok_lib and handle then
          local version = M.cxstring_to_string(handle, handle.clang_getClangVersion())
          return {
            ok = true,
            clangd_path = resolved,
            libclang_path = resolved_lib,
            clang_version = version,
            lib = handle,
            probes = probes,
            toolchain_identity = M.sha256(vim.json.encode({ resolved, resolved_lib, version })),
          }
        end
      end
    end
  end

  return {
    ok = false,
    reason = "libclang-not-found",
    probes = probes,
  }
end

function M.overlays_key(overlays)
  local parts = {}
  for _, overlay in ipairs(overlays or {}) do
    parts[#parts + 1] = M.normalize(overlay.path)
    parts[#parts + 1] = overlay.contents
  end
  return M.sha256(vim.json.encode(parts))
end

function M.make_unsaved_files(overlays)
  local count = #(overlays or {})
  if count == 0 then
    return nil, nil
  end
  local records = ffi.new("CXUnsavedFile[?]", count)
  local keepalive = {}
  for index, overlay in ipairs(overlays) do
    local contents = overlay.contents or ""
    keepalive[#keepalive + 1] = contents
    records[index - 1].Filename = M.normalize(overlay.path)
    records[index - 1].Contents = contents
    records[index - 1].Length = #contents
  end
  return records, keepalive
end

function M.map_cdb_error(code)
  local names = {
    [0] = "success",
    [1] = "cannot-load-database",
  }
  return names[tonumber(code)] or ("cdb-error-" .. tostring(code))
end

function M.map_parse_error(code)
  local names = {
    [0] = "success",
    [1] = "failure",
    [2] = "crashed",
    [3] = "invalid-arguments",
    [4] = "ast-read-error",
  }
  return names[tonumber(code)] or ("parse-error-" .. tostring(code))
end

function M.location_from_cursor(lib, cursor)
  local loc = lib.clang_getCursorLocation(cursor)
  local file_ptr = ffi.new("CXFile[1]")
  local line_ptr = ffi.new("unsigned[1]")
  local column_ptr = ffi.new("unsigned[1]")
  local offset_ptr = ffi.new("unsigned[1]")
  lib.clang_getExpansionLocation(loc, file_ptr, line_ptr, column_ptr, offset_ptr)
  if file_ptr[0] == nil then
    return nil
  end
  local path = M.cxstring_to_string(lib, lib.clang_getFileName(file_ptr[0]))
  if path == "" then return nil end
  return {
    path = M.normalize(path),
    line = tonumber(line_ptr[0]),
    column = tonumber(column_ptr[0]),
    offset = tonumber(offset_ptr[0]),
  }
end

function M.collect_diagnostics(lib, tu)
  local out = {}
  local n = tonumber(lib.clang_getNumDiagnostics(tu))
  local opts = tonumber(lib.clang_defaultDiagnosticDisplayOptions())
  for i = 0, n - 1 do
    local diag = lib.clang_getDiagnostic(tu, i)
    out[#out + 1] = M.cxstring_to_string(lib, lib.clang_formatDiagnostic(diag, opts))
    lib.clang_disposeDiagnostic(diag)
  end
  return out
end

function M.semantic_parse_args(argv)
  local out = {}
  local gcc_toolchain
  local has_resource_dir = false
  local i = 2
  while i <= #argv do
    local arg = argv[i]
    local lower = arg:lower()
    if lower:match("^%-resource%-dir=") then has_resource_dir = true end
    if lower:match("^%-%-gcc%-toolchain=") then
      gcc_toolchain = arg:sub(#"--gcc-toolchain=" + 1)
    elseif arg == "--gcc-toolchain" and argv[i + 1] then
      gcc_toolchain = argv[i + 1]
    end
    if arg == "-c" or arg == "-MD" or arg == "-MMD" then
      i = i + 1
    elseif arg == "-o" or arg == "-MF" or arg == "-MT" or arg == "-MQ"
        or arg == "-include-pch" then
      i = i + 2
    elseif lower:match("^%-mf.+") or lower:match("^%-mt.+") or lower:match("^%-mq.+")
        or lower:match("^/fo") or lower:match("^/fd") then
      i = i + 1
    else
      out[#out + 1] = arg
      i = i + 1
    end
  end

  if not has_resource_dir and gcc_toolchain then
    local versions = {}
    for _, base in ipairs({
      M.normalize(gcc_toolchain .. "/lib64/clang"),
      M.normalize(gcc_toolchain .. "/lib/clang"),
    }) do
      local scanner = uv.fs_scandir(base)
      if scanner then
        while true do
          local name, kind = uv.fs_scandir_next(scanner)
          if not name then break end
          if kind == "directory" then versions[#versions + 1] = M.normalize(base .. "/" .. name) end
        end
      end
    end
    if #versions == 1 then
      table.insert(out, 1, "-resource-dir=" .. versions[1])
    end
  end

  out[#out + 1] = "-Wno-error"
  out[#out + 1] = "-ferror-limit=0"
  return out
end

return M
