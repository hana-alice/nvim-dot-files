-- Descriptor validation and owned local cache preparation; no runtime authority.
local M = {}
local uv = vim.uv or vim.loop
local platform = require("utils.platform")
local fs = require("ue.core.fs")

function M.selected_store(store, phase)
  if type(store) ~= "table" or store.schema ~= 1 or type(store.path) ~= "string"
      or not fs.is_absolute_path(store.path) or store.path:find("[%z\r\n]") then
    return nil, "invalid batch-store.json: expected schema=1 and an absolute proof-store path"
  end
  if store.phases == nil then return store.path end
  local invalid = "invalid batch-store.json: phases must be a nonempty unique list of current/hot/full"
  if type(store.phases) ~= "table" or not vim.islist(store.phases) or #store.phases == 0 then
    return nil, invalid
  end
  local allowed, seen = { current = true, hot = true, full = true }, {}
  for _, name in ipairs(store.phases) do
    if type(name) ~= "string" or not allowed[name] or seen[name] then return nil, invalid end
    seen[name] = true
  end
  if seen[phase] then return store.path end
end

local function key(path)
  return platform.driver().path_key(vim.fs.normalize(path))
end

local function path_list(value, required)
  if value == nil then return not required end
  if type(value) ~= "table" or not vim.islist(value) or (required and #value == 0) then return false end
  for _, path in ipairs(value) do
    if type(path) ~= "string" or not (path:match("^%a:[/\\]$") or fs.is_absolute_path(path)) then return false end
  end
  return true
end

-- The first shard creates a local .cache tree beside the frozen database.
-- Prepare that owned tree before watching its parent; weakening ancestor
-- invalidation would also hide real directory replacement or metadata changes.
local function prepare_local_cache(original, verified)
  local parent = vim.fs.dirname(original)
  local resolved = uv.fs_realpath(parent)
  if not resolved or key(parent) ~= key(resolved) then return false end
  local directory = vim.fs.joinpath(parent, "verified")
  if key(verified) ~= key(vim.fs.joinpath(directory, "compile_commands.json")) then return false end
  for _, part in ipairs({ "", ".cache", "clangd", "index" }) do
    if part ~= "" then directory = vim.fs.joinpath(directory, part) end
    local stat = uv.fs_lstat(directory)
    if stat and stat.type ~= "directory" then return false end
    if not stat and not uv.fs_mkdir(directory, 448) then return false end
    local actual = uv.fs_realpath(directory)
    if not actual or key(actual) ~= key(directory) then return false end
  end
  return true
end

local function watch_sets(descriptor)
  local result = {}
  if descriptor.directory_write_policy ~= nil and descriptor.directory_write_policy ~= "stable-directory-write-v1" then
    return nil
  end
  result.directory_write_policy = descriptor.directory_write_policy
  for _, field in ipairs({ "watch_roots", "lookup_roots", "watched_files", "input_roots", "exclude_roots" }) do
    if not path_list(descriptor[field], field == "watch_roots" or field == "watched_files" or field == "input_roots") then
      return nil
    end
    result[field] = {}
    for _, path in ipairs(descriptor[field] or {}) do result[field][key(path)] = true end
  end
  return result
end

M.path_list = path_list
M.prepare_local_cache = prepare_local_cache
M.watch_sets = watch_sets

return M
