-- Run ordinary phase manifests and CDB publication outside the editor loop.
return function(M, core)
  local uv = vim.uv or vim.loop
  local source = debug.getinfo(1, "S").source:sub(2)
  local worker = vim.fs.dirname(source) .. "/publication_worker.lua"
  local active = {}
  local exit_hook = false
  M.cancel_publication_workers = function()
    for path, item in pairs(active) do
      active[path] = nil
      if item.process and type(item.process.kill) == "function" then pcall(item.process.kill, item.process, 15) end
      item.cleanup()
    end
  end
  local function identity(path)
    local stat = path and path ~= "" and uv.fs_stat(path) or nil
    if not stat then return false end
    return { size = stat.size, mtime = stat.mtime, ctime = stat.ctime,
      dev = string.format("%.17g", stat.dev or 0), ino = string.format("%.17g", stat.ino or 0) }
  end
  M.publication_needs_worker = function(ctx, state, base, background, marker)
    local function large(path)
      local stat = path and path ~= "" and uv.fs_stat(path)
      return stat and stat.size > 1024 * 1024 or false
    end
    for _, path in ipairs({ base or "", background or "", (background or "") .. ".semantic.json",
      marker or "", ctx.paths.semantic_cdb or "" }) do
      if large(path) then return true end
    end
    for _, artifact in pairs(state.index_artifacts or {}) do
      if large(artifact.background_cdb_path) or large(artifact.semantic_cdb_path) then return true end
    end
    return false
  end
  M.finish_publication_async = function(ctx, state, phase, marker, keys, opts, callback)
    local request_path = marker .. ".publication." .. vim.fn.getpid() .. "." .. string.format("%.0f", uv.hrtime()) .. ".request.json"
    local output_path = request_path .. ".result.json"
    local signatures = {}
    for _, path in ipairs({ opts.base_cdb_path, opts.background_cdb_path, opts.semantic_cdb_path or "", marker }) do
      if path ~= "" then signatures[path] = identity(path) end
    end
    for _, artifact in pairs(state.index_artifacts or {}) do
      for _, path in ipairs({ artifact.background_cdb_path or "", artifact.semantic_cdb_path or "" }) do
        if path ~= "" then signatures[path] = identity(path) end
      end
    end
    local request = { schema = 1, ctx = ctx, state = state, phase = phase, marker = marker,
      keys = keys, opts = opts, signatures = signatures, output = output_path }
    local function cleanup()
      active[request_path] = nil
      uv.fs_unlink(request_path)
      uv.fs_unlink(output_path)
    end
    local function done(err, result)
      cleanup()
      callback(err, result)
    end
    local ok, err = core.h.write_json_file(request_path, request)
    if not ok then cleanup(); return false, "publication request write failed: " .. tostring(err) end
    if not exit_hook then
      exit_hook = true
      vim.api.nvim_create_autocmd("VimLeavePre", { once = true, callback = M.cancel_publication_workers })
    end
    local record = { cleanup = cleanup }
    active[request_path] = record
    local spawned, process = pcall(vim.system,
      { vim.v.progpath, "--headless", "-u", "NONE", "-i", "NONE", "-l", worker, request_path },
      { text = true, timeout = 120000, env = { NVIM_INDEX_WORKER = "1" } }, function(result)
        vim.schedule(function()
          if active[request_path] ~= record then cleanup(); return end
          local data = core.h.read_json_file(output_path, nil)
          if result.code ~= 0 or type(data) ~= "table" or data.ok ~= true then
            done("publication worker failed: " .. tostring(data and data.reason or result.stderr or result.code)); return
          end
          local lease = opts.lease
          local owner = lease and require("ue.file_lock").owner(lease.path)
          if not owner or owner.pid ~= opts.owner_pid or owner.token ~= lease.token then
            done("publication lease changed before delivery"); return
          end
          for path, before in pairs(signatures) do
            if not vim.deep_equal(before, identity(path)) then done("publication input changed: " .. path); return end
          end
          if core.h.accept_verified_cdb_digest and data.generation then
            if not core.h.accept_verified_cdb_digest(opts.base_cdb_path, data.generation.cdb_digest,
              signatures[opts.base_cdb_path]) then done("publication digest identity changed before delivery"); return end
          end
          done(nil, data)
        end)
      end)
    if not spawned or not process then cleanup(); return false, "publication worker spawn failed: " .. tostring(process) end
    record.process = process
    return true
  end
end
