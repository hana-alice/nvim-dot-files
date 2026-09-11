local M = {}

local function path_key(path)
  if not path or path == "" then return "" end
  return vim.fs.normalize((vim.uv or vim.loop).fs_realpath(path) or path)
end

function M.same_requested(left, right)
  left, right = M.requested(left), M.requested(right)
  return path_key(left.clangd_path) == path_key(right.clangd_path)
    and path_key(left.libclang_path) == path_key(right.libclang_path)
    and vim.deep_equal(left.compiler_files, right.compiler_files)
end

local function file_signature(path)
  local resolved = path_key(path)
  local stat = resolved ~= "" and (vim.uv or vim.loop).fs_stat(resolved) or nil
  return { path = resolved, size = stat and stat.size or 0,
    sec = stat and stat.mtime and stat.mtime.sec or 0,
    nsec = stat and stat.mtime and stat.mtime.nsec or 0 }
end

function M.requested(options)
  options = options or {}
  return {
    clangd_path = options.clangd_path, libclang_path = options.libclang_path,
    compiler_files = vim.deepcopy(options.compiler_files or {
      clangd = file_signature(options.clangd_path), libclang = file_signature(options.libclang_path),
    }),
  }
end

function M.bind(requested, actual, generation)
  requested = M.requested(requested)
  if type(actual) ~= "table" or type(actual.toolchain_identity) ~= "string"
      or actual.toolchain_identity == "" or type(actual.clangd_path) ~= "string"
      or actual.clangd_path == "" or type(actual.libclang_path) ~= "string" or actual.libclang_path == ""
      or type(actual.clang_version) ~= "string" or actual.clang_version == "" then
    return nil, "compiler-session-identity-missing"
  end
  if path_key(requested.clangd_path) ~= path_key(actual.clangd_path)
      or (requested.libclang_path and path_key(requested.libclang_path) ~= path_key(actual.libclang_path)) then
    return nil, "compiler-session-toolchain-mismatch"
  end
  if not M.same_requested(requested, { clangd_path = requested.clangd_path, libclang_path = requested.libclang_path }) then
    return nil, "compiler-session-toolchain-changed"
  end
  return {
    generation = generation,
    requested = requested,
    actual = vim.deepcopy(actual),
  }
end

return M
