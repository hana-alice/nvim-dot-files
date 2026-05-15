-- ue.cdb.pch_fi_inject — re-inject `/FI<header>` flags for SharedPCH headers
-- that UnrealBuildTool strips from its emitted compile_commands.json.
--
-- Why this exists:
--   UBT writes `/Yu /Fp` to consume a binary PCH at compile time, then it
--   STRIPS the corresponding `/FI"...SharedPCH.X.h"` and `/FI"...PCH.X.h"`
--   flags from the CDB JSON it emits. cl.exe still gets PCH content via the
--   binary; clangd does not — it needs text /FI to rebuild the same symbol
--   preamble. Missing those flags causes severity-1 cascades like
--   `unknown type name 'template'` on IWYU-incomplete .cpp files.
--
-- Algorithm (per bucket):
--   1. Resolve config-level dir from bucket.roots (parent of any root).
--   2. For each entry in bucket.entries with file ending in `.cpp`:
--      a. Idempotent guard — if any arg already starts with /FI or -FI and
--         mentions SharedPCH or PCH.<X>, skip (already injected).
--      b. Look up `<basename>.cpp.obj.response` under the config-level dir,
--         tolerating Windows case differences.
--      c. If missing on disk → skip (this .cpp was built by a different
--         target/config, leave it alone).
--      d. Scan response text for `/FI"...SharedPCH..."` and `/FI"...\PCH.<X>..."`
--         directives. Append each as a new `/FI<header>` arg.
--   3. Return stats.

local M = {}

-- ----------------------------------------------------------------------------
-- helpers

local function norm(p)
  return (p or ""):gsub("\\", "/"):lower()
end

local function basename(p)
  return (p:gsub("\\", "/")):match("([^/]+)$") or p
end

local function file_exists(path)
  local st = vim.uv.fs_stat(path)
  return st ~= nil
end

local function read_all(path)
  local fd = io.open(path, "rb")
  if not fd then return nil end
  local data = fd:read("*a")
  fd:close()
  return data
end

--- Derive the config-level intermediate dir from any bucket root by stripping
--- its last path segment. `roots` is a set keyed by module-level dir.
local function derive_config_level_dir(bucket)
  if not bucket or not bucket.roots then return nil end
  local first
  for k, _ in pairs(bucket.roots) do first = k; break end
  if not first then return nil end
  local p = first:gsub("\\", "/")
  return p:match("^(.*)/[^/]+$")
end

--- Build a basename→absolute-path map of every `*.cpp.obj.response` directly
--- under `<config_level>/<Module>/` (UBT lays them one directory deep). Keys
--- are lowercased basenames so Windows case mismatch is a no-op.
local function build_response_index(config_level_dir)
  local index = {}
  if not config_level_dir then return index end
  local sd = vim.uv.fs_scandir(config_level_dir)
  if not sd then return index end
  while true do
    local name, kind = vim.uv.fs_scandir_next(sd)
    if not name then break end
    if kind == "directory" or kind == "link" or kind == nil then
      local module_dir = config_level_dir .. "/" .. name
      local sd2 = vim.uv.fs_scandir(module_dir)
      if sd2 then
        while true do
          local fname = vim.uv.fs_scandir_next(sd2)
          if not fname then break end
          if fname:sub(-#".cpp.obj.response") == ".cpp.obj.response"
             or fname:lower():sub(-#".cpp.obj.response") == ".cpp.obj.response" then
            index[fname:lower()] = module_dir .. "/" .. fname
          end
        end
      end
    end
  end
  return index
end

--- True if `args` already carries a /FI...SharedPCH or /FI...PCH.<X> flag.
local function has_pch_fi(args)
  for _, a in ipairs(args) do
    local la = a:lower()
    if la:sub(1, 3) == "/fi" or la:sub(1, 3) == "-fi" then
      if la:find("sharedpch", 1, true) or la:find("/pch.", 1, true)
         or la:find("\\pch.", 1, true) or la:find("|pch.", 1, true) then
        return true
      end
    end
  end
  return false
end

--- Extract every PCH-bearing /FI header path from response text.
local function extract_pch_fi_headers(text)
  local out = {}
  for hdr in text:gmatch('/FI"([^"]+)"') do
    local lh = hdr:lower()
    if lh:find("sharedpch", 1, true)
       or lh:find("/pch.", 1, true) or lh:find("\\pch.", 1, true) then
      out[#out + 1] = hdr
    end
  end
  return out
end

-- ----------------------------------------------------------------------------
-- public API

function M.run(bucket, config_level_dir)
  local stats = { scanned = 0, fi_added = 0, response_missing = 0, already_had = 0 }
  if not bucket or type(bucket.entries) ~= "table" then return stats end

  config_level_dir = config_level_dir or derive_config_level_dir(bucket)
  local rsp_index = build_response_index(config_level_dir)

  for _, entry in ipairs(bucket.entries) do
    local f = entry.file or ""
    if f:sub(-4):lower() == ".cpp" then
      stats.scanned = stats.scanned + 1
      local args = entry.arguments
      if type(args) == "table" then
        if has_pch_fi(args) then
          stats.already_had = stats.already_had + 1
        else
          local bn = basename(f):lower()
          local rsp_path = bn .. ".obj.response"
          local disk = rsp_index[rsp_path]
          if not disk then
            -- Fallback: maybe response sits next to entry.file (rare layout).
            local sibling = f:gsub("\\", "/") .. ".obj.response"
            if file_exists(sibling) then disk = sibling end
          end
          if not disk then
            stats.response_missing = stats.response_missing + 1
          else
            local text = read_all(disk)
            if text then
              local headers = extract_pch_fi_headers(text)
              if #headers > 0 then
                for _, hdr in ipairs(headers) do
                  args[#args + 1] = "/FI" .. hdr
                end
                stats.fi_added = stats.fi_added + 1
              end
            end
          end
        end
      end
    end
  end

  return stats
end

return M
