-- ue.index._generation_digest — canonical content hashing and CDB digest cache.
return function(M, core)
  local fs = require("ue.core.fs")
  local _ufs = fs
  local read_text_file = core.h.read_text_file
  local CDB_DIGEST_CACHE = {}
  local CDB_DIGEST_PENDING = {}
  local CDB_DIGEST_ERRORS = {}
  local source = debug.getinfo(1, "S").source:sub(2)
  local worker = fs.join(vim.fs.dirname(source), "generation_digest_worker.lua")
  local SYNC_LIMIT = 1024 * 1024
  local exit_autocmd

  local function cancel_pending()
    for _, pending in pairs(CDB_DIGEST_PENDING) do
      pending.cancelled = true
      local handle = pending.handle
      if handle and type(handle.kill) == "function" then pcall(handle.kill, handle, 15) end
    end
  end

  local function identity(path)
    local stat = (vim.uv or vim.loop).fs_stat(path)
    if not stat or stat.type ~= "file" then return nil end
    -- Windows dev/ino can exceed JSON's exactly representable integer range.
    -- Preserve their process-local representation through the worker transport.
    return { size = stat.size, mtime = stat.mtime, ctime = stat.ctime,
      dev = string.format("%.17g", stat.dev or 0), ino = string.format("%.17g", stat.ino or 0) }
  end

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

  local function compute_cdb_digest(base_cdb_path)
    base_cdb_path = fs.norm(base_cdb_path or "")
    local stat = base_cdb_path ~= "" and (vim.uv or vim.loop).fs_stat(base_cdb_path) or nil
    local signature = identity(base_cdb_path)
    local cached = CDB_DIGEST_CACHE[base_cdb_path]
    if cached and vim.deep_equal(cached.signature, signature) then
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
    if not vim.deep_equal(signature, identity(base_cdb_path)) then return nil, "cdb-changed" end
    CDB_DIGEST_CACHE[base_cdb_path] = { signature = signature, digest = digest }
    return digest
  end

  local function normalized_cdb_digest_async(path, callback, opts)
    path, opts = fs.norm(path or ""), opts or {}
    local signature = identity(path)
    if not signature then vim.schedule(function() callback(nil, "cdb-missing") end); return end
    local cached = CDB_DIGEST_CACHE[path]
    if cached and vim.deep_equal(cached.signature, signature) then
      vim.schedule(function()
        if vim.deep_equal(signature, identity(path)) then callback(cached.digest)
        else normalized_cdb_digest_async(path, callback, opts) end
      end)
      return
    end
    local failed = CDB_DIGEST_ERRORS[path]
    if not opts.retry and failed and vim.deep_equal(failed.signature, signature) then
      vim.schedule(function()
        if vim.deep_equal(signature, identity(path)) then callback(nil, failed.reason)
        else normalized_cdb_digest_async(path, callback, opts) end
      end)
      return
    end
    local pending = CDB_DIGEST_PENDING[path]
    if pending then pending.callbacks[#pending.callbacks + 1] = callback; return end
    pending = { callbacks = { callback }, attempts = 0 }
    CDB_DIGEST_PENDING[path] = pending
    local function finish(value, err)
      CDB_DIGEST_PENDING[path] = nil
      CDB_DIGEST_ERRORS[path] = err and { signature = identity(path), reason = err } or nil
      for _, cb in ipairs(pending.callbacks) do cb(value, err) end
    end
    local launch
    launch = function()
      if pending.cancelled then return end
      if not exit_autocmd then
        exit_autocmd = vim.api.nvim_create_autocmd("VimLeavePre", { once = true, callback = cancel_pending })
      end
      pending.attempts = pending.attempts + 1
      local before = identity(path)
      if not before then finish(nil, "cdb-missing"); return end
      local spawn = opts.spawn or vim.system
      local ok, handle = pcall(spawn, { vim.v.progpath, "--headless", "-u", "NONE", "-l", worker, path },
        { text = true, timeout = 120000 }, function(result)
          vim.schedule(function()
            if pending.cancelled then return end
            local parsed_ok, result_data = pcall(vim.json.decode, result.stdout or "")
            local changed = not vim.deep_equal(before, identity(path))
              or (parsed_ok and type(result_data) == "table" and result_data.reason == "cdb-changed")
            if changed then
              if pending.attempts < 3 then launch() else finish(nil, "cdb-keeps-changing") end
              return
            end
            if result.code ~= 0 or not parsed_ok or type(result_data) ~= "table"
                or not result_data.ok or type(result_data.digest) ~= "string" or result_data.digest == "" then
              local reason = type(result_data) == "table" and result_data.reason or "invalid-result"
              local detail = fs.trim(result.stderr or "")
              if detail == "" then detail = tostring(reason or result.code) end
              finish(nil, "digest-worker-failed: " .. detail)
              return
            end
            if not vim.deep_equal(before, result_data.identity) then finish(nil, "digest-worker-identity-mismatch"); return end
            CDB_DIGEST_CACHE[path] = { signature = before, digest = result_data.digest }
            finish(result_data.digest)
          end)
        end)
      if not ok or not handle then finish(nil, "digest-worker-spawn-failed: " .. tostring(handle)) end
      pending.handle = ok and handle or nil
    end
    launch()
  end

  local function normalized_cdb_digest(path)
    path = fs.norm(path or "")
    local signature = identity(path)
    local cached = CDB_DIGEST_CACHE[path]
    if cached and vim.deep_equal(cached.signature, signature) then return cached.digest end
    local failed = CDB_DIGEST_ERRORS[path]
    if failed and vim.deep_equal(failed.signature, signature) then return nil, failed.reason end
    if vim.g.ue_index_worker or vim.env.NVIM_INDEX_WORKER == "1" or not signature or signature.size <= SYNC_LIMIT then
      return compute_cdb_digest(path)
    end
    if not CDB_DIGEST_PENDING[path] then
      normalized_cdb_digest_async(path, function(_, err)
        if err then
          require("utils.log").warn_ctx("ue.index", "CDB digest worker failed", { path = path, reason = err })
        end
        if core.deps and core.deps.invalidate_status_cache then core.deps.invalidate_status_cache() end
        if core.deps and core.deps.refresh_statusline then core.deps.refresh_statusline() end
      end)
    end
    return nil, "digest-pending"
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

  local function accept_verified_digest(path, value, signature)
    path = fs.norm(path or "")
    if type(value) ~= "string" or #value ~= 64 or not signature
      or not vim.deep_equal(signature, identity(path)) then return false end
    CDB_DIGEST_CACHE[path] = { signature = signature, digest = value }
    CDB_DIGEST_ERRORS[path] = nil
    return true
  end

  return {
    sha256_text = sha256_text,
    stable_hash = stable_hash,
    normalized_cdb_digest = normalized_cdb_digest,
    normalized_cdb_digest_async = normalized_cdb_digest_async,
    compute_cdb_digest = compute_cdb_digest,
    cdb_identity = identity,
    accept_verified_digest = accept_verified_digest,
    cancel_pending = cancel_pending,
    file_signature = file_signature,
  }
end
