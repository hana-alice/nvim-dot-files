-- Invalidate migrated main shards. CDB spelling is the fast key; an old
-- wrapper spelling is accepted only after its own srcs node proves identity.
local M = {}
local uv = vim.uv or vim.loop
local fs = require("ue.core.fs")

local function signature(path)
  local stat = uv.fs_stat(path)
  return stat and { stat.size, stat.mtime, stat.ctime, stat.dev, stat.ino } or false
end

function M.invalidate(files, cache, report)
  local began = uv.hrtime()
  local pending = {}
  local function failure(file, shard, reason)
    report.errors[#report.errors + 1] = { file = file, shard = shard, error = tostring(reason) }
  end
  local function unlink(file, shard, field)
    local called, removed, err, code = pcall(uv.fs_unlink, shard)
    if called and removed then report[field] = report[field] + 1; return true end
    if called and code == "ENOENT" then return false end
    failure(file, shard, called and err or removed)
    return nil
  end
  for _, file in ipairs(files) do
    local ok, name = pcall(require("ue.index.shard_name").for_path, file)
    if not ok then failure(file, nil, name)
    elseif unlink(file, fs.join(cache, name), "removed") == false then
      pending[#pending + 1] = { file = file }
    end
  end

  if #pending > 0 then
    local scan_started, candidates = uv.hrtime(), {}
    report.scan_count = 1
    local handle, err, code = uv.fs_scandir(cache)
    if handle then
      while true do
        local name, kind = uv.fs_scandir_next(handle)
        if not name then break end
        local basename, digest = name:match("^(.*)%.([%x]+)%.idx$")
        if basename and #digest == 16 and (kind == "file" or kind == "link") then
          local key = basename:lower()
          candidates[key] = candidates[key] or {}
          candidates[key][#candidates[key] + 1] = fs.join(cache, name)
        end
      end
    elseif code ~= "ENOENT" then
      failure(nil, cache, "shard directory scan: " .. tostring(err))
    end
    report.scan_ms = (uv.hrtime() - scan_started) / 1e6
    local paths, before, selected = {}, {}, {}
    for _, item in ipairs(pending) do
      item.paths = candidates[vim.fs.basename(fs.norm(item.file)):lower()] or {}
      for _, path in ipairs(item.paths) do
        if not selected[path] then
          selected[path] = true
          before[path] = signature(path)
          paths[#paths + 1] = path
        end
      end
    end
    table.sort(paths)
    local owners = {}
    if #paths > 0 then
      local read_started = uv.hrtime()
      -- One stdlib-only reader for the whole candidate set. Normal production
      -- dispatch sends a CDB with a shard store to publication_worker first.
      local ok, decoded = pcall(function()
        local python = require("utils.platform").resolve_tool({ name = "python", env = { "UE_PYTHON" },
          driver_candidates = function(driver) return driver.python_candidates() end })
        assert(python.ok, "shard own-node reader: Python unavailable")
        local result = vim.system({ python.path, "-B", "-I",
          vim.fn.stdpath("config") .. "/tools/clangd_shard_owners.py" },
          { text = true, stdin = vim.json.encode({ paths = paths }), timeout = 30000 }):wait()
        assert(result.code == 0, "shard own-node reader failed: " .. tostring(result.stderr))
        local data = vim.json.decode(result.stdout)
        assert(type(data) == "table" and type(data.items) == "table" and #data.items == #paths,
          "shard own-node reader returned an incomplete batch")
        local seen = {}
        for _, item in ipairs(data.items) do
          assert(type(item) == "table" and selected[item.path] and not seen[item.path],
            "shard own-node reader returned an unexpected path")
          seen[item.path] = true
          if not item.error then
            assert(type(item.own_uris) == "table" and #item.own_uris == 1
              and type(item.own_uris[1]) == "string", "shard own node is not unique")
          end
        end
        return data
      end)
      report.read_ms = (uv.hrtime() - read_started) / 1e6
      report.candidates_read = #paths
      if ok then
        report.reader_ms = decoded.read_ms
        report.read_bytes = decoded.bytes_read
        for _, item in ipairs(decoded.items) do owners[item.path] = item end
      else
        for _, path in ipairs(paths) do owners[path] = { error = tostring(decoded) } end
      end
    end

    local driver, physical = require("utils.platform").driver(), {}
    local function identity(path)
      if physical[path] then return physical[path] end
      local real, reason = uv.fs_realpath(path)
      assert(real, "cannot establish physical path identity: " .. tostring(reason))
      local key = driver.path_key(fs.norm(real))
      physical[path] = key
      return key
    end
    local removed, checked = {}, {}
    for _, item in ipairs(pending) do
      local found, errored = false, false
      for _, path in ipairs(item.paths) do
        local owner = owners[path]
        if owner.error then
          if not checked[path] then failure(item.file, path, owner.error); checked[path] = true end
          errored = true
        else
          local ok, matches = pcall(function()
            local uri = owner.own_uris[1]
            assert(uri:sub(1, 7) == "file://", "unsupported own-node URI")
            return identity(vim.uri_to_fname(uri)) == identity(item.file)
          end)
          if not ok then failure(item.file, path, matches); errored = true
          elseif matches then
            if removed[path] then found = true
            elseif not before[path] or not vim.deep_equal(before[path], signature(path)) then
              failure(item.file, path, "shard changed during own-node verification"); errored = true
            else
              local deleted = unlink(item.file, path, "removed_by_identity")
              if deleted then removed[path], found = true, true
              elseif deleted == nil then errored = true end
            end
          end
        end
      end
      if not found and not errored then report.missing = report.missing + 1 end
    end
  end
  report.delete_ms = (uv.hrtime() - began) / 1e6 - report.scan_ms - report.read_ms
  return report
end

return M
