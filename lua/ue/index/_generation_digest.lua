-- ue.index._generation_digest — canonical content hashing and CDB digest cache.
return function(M, core)
  local fs = require("ue.core.fs")
  local _ufs = fs
  local read_text_file = core.h.read_text_file
  local CDB_DIGEST_CACHE = {}

  local function sha256_text(payload)
    local ok, digest = pcall(vim.fn.sha256, tostring(payload or ""))
    if ok and type(digest) == "string" and digest ~= "" then
      return digest
    end
    return nil
  end

  local function canonical_json(value, seen)
    local kind = type(value)
    if kind ~= "table" then return vim.json.encode(value) end

    seen = seen or {}
    if seen[value] then error("cannot hash cyclic table") end
    seen[value] = true

    local encoded = {}
    if vim.islist(value) then
      for _, item in ipairs(value) do
        encoded[#encoded + 1] = canonical_json(item, seen)
      end
      seen[value] = nil
      return "[" .. table.concat(encoded, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do
      if type(key) ~= "string" then error("generation maps require string keys") end
      keys[#keys + 1] = key
    end
    table.sort(keys)
    for _, key in ipairs(keys) do
      encoded[#encoded + 1] = vim.json.encode(key) .. ":" .. canonical_json(value[key], seen)
    end
    seen[value] = nil
    return "{" .. table.concat(encoded, ",") .. "}"
  end

  local function stable_hash(payload)
    return sha256_text(canonical_json(payload or {}))
  end

  local function canonical_cdb_path(dir, path)
    local normalized = fs.norm(path or "")
    local normalized_dir = fs.norm(dir or "")
    if normalized ~= "" and not _ufs.is_absolute_path(normalized) and normalized_dir ~= "" then
      normalized = fs.join(normalized_dir, normalized)
    end
    return fs.norm(normalized)
  end

  local function canonical_cdb_entry(entry)
    if type(entry) ~= "table" then
      return nil
    end
    local directory = fs.norm(entry.directory or "")
    local file = canonical_cdb_path(directory, entry.file or "")
    if file == "" then
      return nil
    end
    local args = {}
    if type(entry.arguments) == "table" then
      for _, arg in ipairs(entry.arguments) do
        args[#args + 1] = tostring(arg)
      end
    end
    return {
      directory = directory,
      file = file,
      output = canonical_cdb_path(directory, entry.output or ""),
      arguments = args,
      command = type(entry.command) == "string" and fs.trim(entry.command) or "",
    }
  end

  local function normalized_cdb_digest(base_cdb_path)
    base_cdb_path = fs.norm(base_cdb_path or "")
    local stat = base_cdb_path ~= "" and (vim.uv or vim.loop).fs_stat(base_cdb_path) or nil
    local signature = stat and table.concat({
      tostring(stat.size or 0),
      tostring(stat.mtime and stat.mtime.sec or 0),
      tostring(stat.mtime and stat.mtime.nsec or 0),
    }, ":") or "missing"
    local cached = CDB_DIGEST_CACHE[base_cdb_path]
    if cached and cached.signature == signature then
      return cached.digest
    end
    local content = read_text_file(base_cdb_path)
    if not content then
      return ""
    end
    local ok, decoded = pcall(vim.json.decode, content)
    if not ok or type(decoded) ~= "table" then
      return ""
    end
    local canonical = {}
    for _, entry in ipairs(decoded) do
      local normalized = canonical_cdb_entry(entry)
      if normalized then
        canonical[#canonical + 1] = normalized
      end
    end
    table.sort(canonical, function(a, b)
      if a.file ~= b.file then
        return a.file < b.file
      end
      if a.directory ~= b.directory then
        return a.directory < b.directory
      end
      local a_args = table.concat(a.arguments or {}, "\31")
      local b_args = table.concat(b.arguments or {}, "\31")
      if a_args ~= b_args then
        return a_args < b_args
      end
      if a.command ~= b.command then
        return a.command < b.command
      end
      return (a.output or "") < (b.output or "")
    end)
    local digest = stable_hash(canonical) or ""
    CDB_DIGEST_CACHE[base_cdb_path] = { signature = signature, digest = digest }
    return digest
  end

  local function file_signature(path)
    path = fs.norm(path or "")
    local stat = path ~= "" and (vim.uv or vim.loop).fs_stat(path) or nil
    if not stat or stat.type ~= "file" then return "missing" end
    return table.concat({
      tostring(stat.size or 0),
      tostring(stat.mtime and stat.mtime.sec or 0),
      tostring(stat.mtime and stat.mtime.nsec or 0),
    }, ":")
  end

  return {
    sha256_text = sha256_text,
    stable_hash = stable_hash,
    normalized_cdb_digest = normalized_cdb_digest,
    file_signature = file_signature,
  }
end
