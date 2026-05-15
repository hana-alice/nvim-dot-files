-- ue.cdb.header_inject — synthesize .h entries into bucket.entries
--
-- UnrealBuildTool emits compile_commands.json with ONLY .cpp entries. clangd's
-- header inference fallback can't reconstruct -I for sibling headers under deep
-- module trees (e.g. Renderer/Private/MetaGeometry/MG*.h). This module scans
-- UBT-emitted <TU>.cpp.json reverse-include data and, for every .h that's
-- not already in the bucket's CDB, synthesizes a clangd-friendly entry by
-- cloning a donor .cpp's compile args.
--
-- Donor selection (per .h):
--   Path A (preferred): donor .cpp IS in bucket.entries (the CDB). Clone its
--                       arguments, swap last arg to the .h path, AND insert
--                       /FI<pch_header> at args[2]. UBT strips /FI=SharedPCH.X.h
--                       from CDB cpp entries, so the .h's preamble would be
--                       wrong without this re-injection (PoC v6: skipping the
--                       /FI regresses MeshPassProcessor.h to 22 errors).
--   Path B (fallback): donor not in CDB (typically a module wrapper like
--                      Module.Renderer.13_of_29.cpp). Read its
--                      <source>.cpp.obj.response, strip output/PCH binary
--                      flags, prepend the compiler, append the .h path.
--                      Wrapper response files KEEP /FI=SharedPCH so no
--                      separate /FI insertion is needed for Path B.
--
-- Pure Lua. Uses vim.json.decode, vim.uv.fs_scandir, vim.uv.fs_stat, io.open.

local M = {}

-- ==========================================================================
-- HELPERS
-- ==========================================================================

local function norm(p)
  if not p or p == "" then return "" end
  return (p:gsub("\\", "/")):lower()
end

local function basename(p)
  return (p:gsub("\\", "/")):match("([^/]+)$") or p
end

local function file_exists(p)
  local st = vim.uv.fs_stat(p)
  return st ~= nil
end

local function read_file_all(p)
  local f = io.open(p, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  return data
end

local function decode_json_file(p)
  local data = read_file_all(p)
  if not data or data == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then return nil end
  return decoded
end

--- Lowercase tail comparison; both args already normalized OR plain lowercase.
local function ends_with(s, suffix)
  if #suffix > #s then return false end
  return s:sub(-#suffix) == suffix
end

--- Derive config-level intermediate dir from a bucket.roots key.
--- bucket.roots keys look like
---   D:/.../Intermediate/Build/Win64/UE4Editor/Development/Renderer
--- Stripping the trailing /<Module> yields the config-level dir.
local function derive_config_dir(bucket)
  if not bucket or not bucket.roots then return nil end
  local first = next(bucket.roots)
  if not first then return nil end
  local p = first:gsub("\\", "/")
  return p:match("^(.*)/[^/]+$")
end

-- ==========================================================================
-- TOKENIZER for .cpp.obj.response files
-- ==========================================================================

--- Tokenize a response-file text into arg tokens. Respects double-quoted args
--- (quotes are stripped). Whitespace (incl. newlines) separates tokens.
local function tokenize_response(text)
  local out = {}
  local i, n = 1, #text
  while i <= n do
    local c = text:sub(i, i)
    if c == " " or c == "\t" or c == "\r" or c == "\n" then
      i = i + 1
    elseif c == '"' then
      -- Quoted token; find closing quote.
      local j = text:find('"', i + 1, true)
      if not j then
        out[#out + 1] = text:sub(i + 1)
        break
      end
      out[#out + 1] = text:sub(i + 1, j - 1)
      i = j + 1
    else
      -- Unquoted token: read until whitespace, BUT preserve embedded quoted
      -- substrings like /FI"path with space". We collapse them into the token.
      local buf = {}
      while i <= n do
        local cc = text:sub(i, i)
        if cc == " " or cc == "\t" or cc == "\r" or cc == "\n" then break end
        if cc == '"' then
          local j = text:find('"', i + 1, true)
          if not j then
            buf[#buf + 1] = text:sub(i + 1)
            i = n + 1
            break
          end
          buf[#buf + 1] = text:sub(i + 1, j - 1)
          i = j + 1
        else
          buf[#buf + 1] = cc
          i = i + 1
        end
      end
      out[#out + 1] = table.concat(buf)
    end
  end
  return out
end

--- Strip flags that don't belong to a .h preamble. KEEP: /FI /D /I /imsvc /external
--- and unknown/positional args. STRIP: /Yu /Fp /Fo /Fd /Tp /Ts /Yc
--- /sourcedependencies /scandependencies and trailing .cpp/.c source file.
local STRIP_PREFIXES = {
  "/yu", "/fp", "/fo", "/fd", "/tp", "/ts", "/yc",
  "/sourcedependencies", "/scandependencies",
}

local function should_strip(tok)
  local lt = tok:lower()
  for _, pref in ipairs(STRIP_PREFIXES) do
    if lt:sub(1, #pref) == pref then return true end
  end
  -- Trailing source file (.cpp/.c with no slash flag preceding)
  if lt:sub(1, 1) ~= "/" and lt:sub(1, 1) ~= "-" then
    if ends_with(lt, ".cpp") or ends_with(lt, ".c") then return true end
  end
  return false
end

local function strip_response_args(tokens)
  local out = {}
  for _, t in ipairs(tokens) do
    if not should_strip(t) then out[#out + 1] = t end
  end
  return out
end

-- ==========================================================================
-- CASE-INSENSITIVE RESPONSE FILE LOOKUP
-- ==========================================================================

--- Given a .cpp path (which may not match disk case), find its .cpp.obj.response
--- by scanning the parent directory case-insensitively. Returns absolute path
--- to the response file, or nil.
local function find_response_for_cpp(cpp_path)
  local p = cpp_path:gsub("\\", "/")
  local dir, base = p:match("^(.*)/([^/]+)$")
  if not dir or not base then return nil end
  local want = (base .. ".obj.response"):lower()
  local scanner = vim.uv.fs_scandir(dir)
  if not scanner then return nil end
  while true do
    local name, _ = vim.uv.fs_scandir_next(scanner)
    if not name then break end
    if name:lower() == want then return dir .. "/" .. name end
  end
  return nil
end

-- ==========================================================================
-- MAIN
-- ==========================================================================

--- Run header injection on a bucket. Mutates bucket.entries in place.
--- @param bucket table  { entries=[], seen_files={}, roots={}, key=, ... }
--- @param config_level_dir string|nil  Optional pre-resolved config dir.
--- @return table stats { scanned, h_added, donor_a, donor_b,
---                        skipped_no_donor, skipped_already_in_cdb }
function M.run(bucket, config_level_dir)
  local stats = {
    scanned = 0,
    h_added = 0,
    donor_a = 0,
    donor_b = 0,
    skipped_no_donor = 0,
    skipped_already_in_cdb = 0,
  }
  if not bucket or type(bucket.entries) ~= "table" then return stats end
  bucket.seen_files = bucket.seen_files or {}

  local cfg_dir = config_level_dir or derive_config_dir(bucket)
  if not cfg_dir then return stats end
  if not file_exists(cfg_dir) then return stats end

  -- Build CDB lookup: normalized cpp path -> entry index in bucket.entries.
  local cdb_by_norm = {}
  for i, e in ipairs(bucket.entries) do
    local f = e.file
    if not f or f == "" then
      -- Some entries store the input file as last arg; fall back to that.
      if type(e.arguments) == "table" and #e.arguments > 0 then
        f = e.arguments[#e.arguments]
      end
    end
    if f and f ~= "" then
      cdb_by_norm[norm(f)] = i
    end
  end

  -- Pick a default compiler from existing entries for Path B response synthesis.
  local default_compiler = "clang++"
  if bucket.entries[1] and type(bucket.entries[1].arguments) == "table"
      and bucket.entries[1].arguments[1] then
    default_compiler = bucket.entries[1].arguments[1]
  end

  -- ------------------------------------------------------------------------
  -- Phase 1: scan all .cpp.json under config_dir/<module>/, build
  --   donors_by_h[norm_h_path] = { { cpp_path, pch_path, include_count }, ... }
  -- and donor_cpp_set (set of normalized cpp paths that own at least one .h).
  -- ------------------------------------------------------------------------
  local donors_by_h = {}
  local cpp_meta = {}  -- norm_cpp -> { source, pch }

  local function scan_dir_for_json(module_dir)
    local scanner = vim.uv.fs_scandir(module_dir)
    if not scanner then return end
    while true do
      local name, t = vim.uv.fs_scandir_next(scanner)
      if not name then break end
      if (t == "file" or t == nil) and name:sub(-9):lower() == ".cpp.json" then
        local full = module_dir .. "/" .. name
        local decoded = decode_json_file(full)
        if decoded and type(decoded.Data) == "table" then
          stats.scanned = stats.scanned + 1
          local d = decoded.Data
          local src = d.Source or ""
          local pch = d.PCH or ""
          if src ~= "" and pch ~= "" and pch:sub(-4):lower() == ".pch"
              and type(d.Includes) == "table" then
            local n_src = norm(src)
            local inc_count = #d.Includes
            cpp_meta[n_src] = { source = src, pch = pch, includes = inc_count }
            for _, h in ipairs(d.Includes) do
              if type(h) == "string" and h ~= "" then
                local nh = norm(h)
                local last = nh:sub(-2)
                local last3 = nh:sub(-3)
                local last4 = nh:sub(-4)
                if last == ".h" or last3 == ".hh" or last4 == ".hpp"
                    or last4 == ".inl" or last3 == ".ix" then
                  local list = donors_by_h[nh]
                  if not list then list = {}; donors_by_h[nh] = list end
                  list[#list + 1] = {
                    cpp_norm = n_src,
                    h_path = h,  -- preserve original casing for entry.file
                    include_count = inc_count,
                  }
                end
              end
            end
          end
        end
      end
    end
  end

  -- Walk one level: cfg_dir/<Module>/*.cpp.json
  local top = vim.uv.fs_scandir(cfg_dir)
  if not top then return stats end
  while true do
    local name, t = vim.uv.fs_scandir_next(top)
    if not name then break end
    if t == "directory" or t == nil then
      scan_dir_for_json(cfg_dir .. "/" .. name)
    end
  end

  if stats.scanned == 0 then return stats end

  -- ------------------------------------------------------------------------
  -- Phase 2: for each .h, sort candidates by include_count asc, prefer Path A.
  -- ------------------------------------------------------------------------
  for nh, candidates in pairs(donors_by_h) do
    if bucket.seen_files[nh] or cdb_by_norm[nh] then
      stats.skipped_already_in_cdb = stats.skipped_already_in_cdb + 1
    else
      table.sort(candidates, function(a, b)
        return a.include_count < b.include_count
      end)

      -- Try Path A: pick smallest candidate whose cpp is in CDB.
      local picked, picked_path = nil, nil
      for _, c in ipairs(candidates) do
        if cdb_by_norm[c.cpp_norm] then
          picked = c; picked_path = "A"; break
        end
      end
      if not picked then
        -- Path B: pick smallest candidate (already sorted) whose response
        -- file we can locate on disk.
        for _, c in ipairs(candidates) do
          local meta = cpp_meta[c.cpp_norm]
          if meta and meta.source then
            local resp = find_response_for_cpp(meta.source)
            if resp then
              picked = c; picked_path = "B"; picked.response = resp
              break
            end
          end
        end
      end

      if not picked then
        stats.skipped_no_donor = stats.skipped_no_donor + 1
      else
        local meta = cpp_meta[picked.cpp_norm]
        local pch_full = meta.pch
        local pch_header = pch_full:sub(1, -5)  -- strip ".pch"
        local h_path = picked.h_path
        local new_entry

        if picked_path == "A" then
          local donor_idx = cdb_by_norm[picked.cpp_norm]
          local donor = bucket.entries[donor_idx]
          local args = vim.deepcopy(donor.arguments) or {}
          if #args > 0 then
            args[#args] = h_path
          else
            args = { default_compiler, h_path }
          end
          -- Insert /FI<pch_header> at args[2] if no SharedPCH/PCH. /FI present.
          local has_pch_fi = false
          for _, a in ipairs(args) do
            if type(a) == "string" then
              local la = a:lower()
              if la:sub(1, 3) == "/fi" or la:sub(1, 3) == "-fi" then
                if la:find("sharedpch", 1, true) or la:find("pch.", 1, true) then
                  has_pch_fi = true
                  break
                end
              end
            end
          end
          if not has_pch_fi then
            table.insert(args, 2, "/FI" .. pch_header)
          end
          new_entry = {
            directory = donor.directory,
            arguments = args,
            file = h_path,
          }
          stats.donor_a = stats.donor_a + 1
        else
          -- Path B
          local text = read_file_all(picked.response) or ""
          local tokens = tokenize_response(text)
          local kept = strip_response_args(tokens)
          local args = { default_compiler }
          for _, tk in ipairs(kept) do args[#args + 1] = tk end
          args[#args + 1] = h_path
          -- Response files use paths relative to a working directory. We use
          -- the same directory as any existing CDB entry (Engine/Source on
          -- this workspace). Fall back to the response file's parent.
          local directory = nil
          if bucket.entries[1] and bucket.entries[1].directory then
            directory = bucket.entries[1].directory
          else
            directory = picked.response:match("^(.*)/[^/]+$")
          end
          new_entry = {
            directory = directory,
            arguments = args,
            file = h_path,
          }
          stats.donor_b = stats.donor_b + 1
        end

        bucket.entries[#bucket.entries + 1] = new_entry
        bucket.seen_files[nh] = true
        stats.h_added = stats.h_added + 1
      end
    end
  end

  return stats
end

return M
