local ffi = require("ffi")
local semantic_context = require("utils.ue_goto.semantic_context")
local uv = vim.uv or vim.loop

local M = {}

function M.file_signature(api, path)
  local stat = uv.fs_stat(path)
  if not stat or stat.type ~= "file" then
    return nil
  end
  return api.sha256(vim.json.encode({
    api.normalize(path),
    tostring(stat.size or 0),
    tostring(stat.mtime and stat.mtime.sec or 0),
    tostring(stat.mtime and stat.mtime.nsec or 0),
  }))
end

-- Compiler-authored dependency paths, including the main file. Kept only in
-- the sidecar: warm validation must not scan the project or block the editor.
function M.tu_file_signatures(api, lib, tu, origin, cwd)
  origin = api.absolute_path(origin, cwd)
  local signatures = { [origin] = api.file_signature(origin) or false }
  local visitor = ffi.cast("CXInclusionVisitor", function(file)
    local path = api.absolute_path(api.cxstring_to_string(lib, lib.clang_getFileName(file)), cwd)
    if path ~= "" then signatures[path] = api.file_signature(path) or false end
  end)
  local ok, err = pcall(lib.clang_getInclusions, tu, visitor, nil)
  visitor:free()
  if not ok then error(err) end
  return signatures
end
-- libclang calls back into Lua; this FFI call must remain outside JIT traces.
jit.off(M.tu_file_signatures, true)

-- A non-null clang_getFile is not inclusion evidence: VFS can expose a file
-- which this TU never includes. Compare compiler file identity, not opaque
-- pointer addresses or basenames, against the actual inclusion enumeration.
function M.tu_includes_file(api, lib, tu, requested)
  if requested == nil then return false end
  local included = false
  local visitor = ffi.cast("CXInclusionVisitor", function(file)
    if tonumber(lib.clang_File_isEqual(file, requested)) ~= 0 then included = true end
  end)
  local ok = pcall(lib.clang_getInclusions, tu, visitor, nil)
  visitor:free()
  return ok and included
end
jit.off(M.tu_includes_file, true)

-- An external-name alias may preserve file identity while replacing bytes.
-- Only identical user/compiler contents prove the same source coordinates.
function M.file_contents_match(api, lib, tu, file, path, overlays)
  local contents = api.read_all(path)
  for _, overlay in ipairs(overlays or {}) do
    if api.normalize(overlay.path) == api.normalize(path) then contents = overlay.contents end
  end
  if contents == nil then return false end
  local size = ffi.new("size_t[1]")
  local buffer = lib.clang_getFileContents(tu, file, size)
  return buffer ~= nil and tonumber(size[0]) == #contents
    and ffi.string(buffer, tonumber(size[0])) == contents
end

-- VFS external contents are parse inputs even when external names are hidden.
-- Keep these separate from inclusion evidence: an overlay listing does not
-- prove that the TU actually includes any of its mapped files.
function M.vfs_input_signatures(api, compile, included_files)
  local signatures = {}
  local included = {}
  for path in pairs(included_files or {}) do included[semantic_context.match_key(path)] = path end
  local function capture(path, cwd)
    path = api.absolute_path(path, cwd)
    signatures[path] = api.file_signature(path) or false
    return path
  end
  for index, arg in ipairs(compile.argv or {}) do
    if arg == "-ivfsoverlay" and type(compile.argv[index + 1]) == "string" then
      local path = capture(compile.argv[index + 1], compile.cwd)
      local overlay = api.read_json(path)
      local cwd = overlay and overlay["overlay-relative"] and api.dirname(path) or compile.cwd
      local function visit(nodes, prefix)
        for _, node in ipairs(nodes or {}) do
          local virtual = api.absolute_path(node.name or "", prefix or compile.cwd)
          if type(node["external-contents"]) == "string" then
            local external = api.absolute_path(node["external-contents"], cwd)
            if node.type == "directory" or node.type == "directory-remap" then
              local virtual_key, external_key = semantic_context.match_key(virtual), semantic_context.match_key(external)
              for key, included_path in pairs(included) do
                if key:sub(1, #virtual_key + 1) == virtual_key .. "/" then
                  capture(api.join(external, included_path:sub(#virtual + 2)))
                  capture(included_path)
                elseif key:sub(1, #external_key + 1) == external_key .. "/" then
                  capture(included_path)
                  capture(api.join(virtual, included_path:sub(#external + 2)))
                end
              end
            elseif included[semantic_context.match_key(virtual)] or included[semantic_context.match_key(external)] then
              capture(virtual)
              capture(external)
            end
          end
          if type(node.contents) == "table" then visit(node.contents, virtual) end
        end
      end
      if overlay and type(overlay.roots) == "table" then visit(overlay.roots) end
    end
  end
  return signatures
end

function M.file_signatures_current(api, signatures)
  if not signatures then return false end
  for path, signature in pairs(signatures) do
    if (api.file_signature(path) or false) ~= signature then return false end
  end
  return true
end

local function mtime_before(left, right)
  local lm, rm = left and left.mtime, right and right.mtime
  if not lm or not rm then return false end
  if lm.sec ~= rm.sec then return lm.sec < rm.sec end
  return (lm.nsec or 0) < (rm.nsec or 0)
end

local function content_hash(api, path, verified)
  local stat = api.uv.fs_stat(path)
  if not stat or stat.type ~= "file" then return nil end
  -- Filesystem metadata may be preserved or have insufficient precision.
  -- Only an actual read/hash can establish the current content identity.
  local bytes = api.read_all(path)
  if not bytes then return nil end
  local ok, hash = pcall(vim.fn.sha256, bytes)
  if not ok then return nil end
  verified[api.normalize(path)] = hash
  return hash
end

function M.active_cdb_is_fresh(api, cdb_path, active_cdb_path, manifest_path)
  local merged = api.uv.fs_stat(cdb_path)
  local active = api.uv.fs_stat(active_cdb_path)
  if not merged or merged.type ~= "file" then return false, "merged-cdb-unreadable" end
  if not active or active.type ~= "file" then return false, "active-cdb-unreadable" end
  if manifest_path and manifest_path ~= "" then
    local manifest = api.uv.fs_stat(manifest_path)
    if not manifest or manifest.type ~= "file" then return false, "active-manifest-unreadable" end
    local committed = api.read_json(cdb_path .. ".pipeline-result.json")
    local proof = committed and committed.provenance
    if proof ~= nil then
      local function digest(value)
        return type(value) == "string" and #value == 64 and value:match("^[a-f0-9]+$")
      end
      if type(proof) ~= "table" or proof.schema ~= 1
          or type(proof.active_key) ~= "string" or proof.active_key == ""
          or not digest(proof.active_cdb_sha256) or not digest(proof.merged_cdb_sha256) then
        return false, "merged-cdb-provenance-invalid"
      end
      local selection = api.read_json(manifest_path)
      local selected_path = api.normalize(vim.fs.joinpath(vim.fs.dirname(manifest_path), proof.active_key .. ".json"))
      if type(selection) ~= "table" or selection.active ~= proof.active_key
          or api.normalize(active_cdb_path):lower() ~= selected_path:lower() then
        return false, "merged-cdb-selection-mismatch"
      end
      local verified = {}
      local merged_hash = content_hash(api, cdb_path, verified)
      local active_hash = content_hash(api, active_cdb_path, verified)
      if merged_hash ~= proof.merged_cdb_sha256 then return false, "merged-cdb-identity-mismatch" end
      if active_hash ~= proof.active_cdb_sha256 then return false, "active-cdb-identity-mismatch" end
      return true, nil, verified
    end
  end
  if api.normalize(cdb_path):lower() ~= api.normalize(active_cdb_path):lower()
      and mtime_before(merged, active) then
    return false, "merged-cdb-predates-active-shard"
  end
  if manifest_path and manifest_path ~= "" then
    local manifest = api.uv.fs_stat(manifest_path)
    if not manifest or manifest.type ~= "file" then
      return false, "active-manifest-unreadable"
    end
    if mtime_before(merged, manifest) then
      return false, "merged-cdb-predates-active-selection"
    end
  end
  return true
end

return M
