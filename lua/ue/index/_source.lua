-- Source bytes and compiler commands have separate refresh lifecycles.
return function(M, core)
  local fs, uv = require("ue.core.fs"), vim.uv or vim.loop
  local path_key = require("utils.platform").driver().path_key
  local RT, ensure, save = core.RT, core.h.ensure_index_state, core.h.save_index_state
  RT.source_hashes = RT.source_hashes or {}
  RT.source_reads = RT.source_reads or {}
  RT.source_restarts = RT.source_restarts or {}
  RT.source_notices = RT.source_notices or {}

  M.source_refresh_pending = function(ctx)
    local state = ensure(ctx)
    return (tonumber(state.source_revision) or 0) > (tonumber(state.source_delivered) or 0)
  end

  -- Lost notifications have no trustworthy path/digest. Keep that uncertainty
  -- pending until normal full delivery attaches a refreshed matching client.
  M.source_observation_unknown = function(ctx, _reason)
    if not ctx then return false end
    local state = ensure(ctx)
    state.source_revision = (tonumber(state.source_revision) or 0) + 1
    state.root_dirty = true
    save(ctx, state)
    M.schedule_index_phase(ctx, "full", 1000, { protect = true })
    return true
  end

  M.source_content_changed = function(ctx, path, digest, baseline)
    local scope = core.deps.status_root_key(ctx)
    local key = scope .. "\0" .. path_key(fs.norm(path))
    local previous = RT.source_hashes[key]
    RT.source_hashes[key] = digest
    if previous == digest or (baseline and previous == nil) then return false end
    local state = ensure(ctx)
    state.source_revision = (tonumber(state.source_revision) or 0) + 1
    M.mark_module_dirty(ctx, path, "source-content")
    save(ctx, state)
    M.schedule_index_refresh(ctx, { current = true, hot = true, current_delay_ms = 150, hot_delay_ms = 2500 })
    return true
  end

  -- Read only notified paths, asynchronously; never scan/hash the source tree.
  M.check_source = function(ctx, path, baseline)
    path = fs.norm(path)
    if not ctx or path == "" then return end
    local lower, owned = path_key(path), false
    for _, root in ipairs({ ctx.engine_root or "", ctx.project_root or "" }) do
      root = path_key(fs.norm(root)):gsub("/+$", "")
      if root ~= "" and lower:sub(1, #root + 1) == root .. "/" then owned = true end
    end
    if not owned then return end
    local key = core.deps.status_root_key(ctx) .. "\0" .. lower
    local active = RT.source_reads[key]
    if active then active.again = true; active.baseline = active.baseline and baseline; return end
    active = { baseline = baseline == true }
    RT.source_reads[key] = active
    local function finish(content, err)
      vim.schedule(function()
        RT.source_reads[key] = nil
        local digest = content and vim.fn.sha256(content) or ("unreadable:" .. tostring(err))
        M.source_content_changed(ctx, path, digest, active.baseline)
        if active.again then M.check_source(ctx, path, false) end
      end)
    end
    uv.fs_open(path, "r", 438, function(open_err, fd)
      if not fd then finish(nil, open_err); return end
      uv.fs_fstat(fd, function(stat_err, stat)
        if not stat then uv.fs_close(fd); finish(nil, stat_err); return end
        uv.fs_read(fd, stat.size, 0, function(read_err, content)
          uv.fs_close(fd)
          finish(content, read_err)
        end)
      end)
    end)
  end

  M.deliver_source_refresh = function(ctx, module_keys, dependencies)
    if not M.source_refresh_pending(ctx) then return false end
    local scope = core.deps.status_root_key(ctx)
    if RT.source_restarts[scope] then return true end
    dependencies = dependencies or {}
    local revision = ensure(ctx).source_revision
    local quiet_retry = RT.source_notices[scope] == revision
    RT.source_notices[scope] = revision
    RT.source_restarts[scope] = revision
    local finished = false
    local function complete(ok)
      if finished then return end
      finished = true
      RT.source_restarts[scope] = nil
      local state = ensure(ctx)
      if ok then state.source_delivered = math.max(tonumber(state.source_delivered) or 0, revision) end
      save(ctx, state)
      if M.source_refresh_pending(ctx) then
        M.schedule_index_phase(ctx, "current", 1000)
      elseif ok then
        M.clear_module_dirty_flags(ctx, module_keys)
      end
    end
    local function restart(_, attached)
      local function acknowledged(ok, reason) complete(ok); attached(ok, reason) end
      local ok, started, delay = pcall(dependencies.restart or M.restart_source_clangd, ctx, acknowledged)
      if not ok then acknowledged(false, tostring(started)); return false end
      if not started and not finished then
        finished = true -- Preserve the restart owner's specific retry delay.
        RT.source_restarts[scope] = nil
        M.schedule_index_phase(ctx, "current", delay or 5000)
      end
      return started
    end
    local started = require("ue.index.switch_commands").run({ resolve = function() return ctx end,
      scope = function() return scope end, restart = restart, helper = dependencies.switch_reindex,
      force_reader_refresh = true, -- A source revision still needs its actual reader acknowledgement.
      notify = quiet_retry and function() end or (dependencies.notify or vim.notify),
      prepare = dependencies.prepare or require("ue.index.prepare_observer").prepare,
      completed = function() if not finished then complete(false) end end })
    if not started then RT.source_restarts[scope] = nil; M.schedule_index_phase(ctx, "current", 5000) end
    return true
  end
end
