local M = {}
local git = require("ue.csearch_git")
local fs = require("ue.core.fs")
M.CSEARCH_ADD_RATIO_MAX = 0.30

function M.csearch_snapshot_path(ctx)
  local idx = ctx and ctx.paths and ctx.paths.csearch_idx
  if not idx or idx == "" then return nil end
  return idx .. ".files"
end

-- Pure decision. stats = { forced, has_snapshot, added_n, removed_n, dirty_n,
-- total_n }. Returns mode ("reset"|"add"|"skip") + human reason.
function M.csearch_build_mode(stats)
  stats = stats or {}
  if stats.forced then return "reset", "forced" end
  if stats.dirty_capped and not stats.git_recovered then return "reset", "dirty coverage was truncated" end
  if stats.git_recovered and stats.has_snapshot then return "add", "complete Git overflow recovery" end
  if not stats.has_snapshot then return "reset", "no snapshot of last indexed set" end
  local work = (stats.added_n or 0) + (stats.dirty_n or 0) + (stats.removed_n or 0)
  if work == 0 then return "skip", "indexed set unchanged" end
  local total = math.max(tonumber(stats.total_n) or 0, 1)
  if work > total * M.CSEARCH_ADD_RATIO_MAX then
    return "reset", ("delta %d > %d%% of %d files"):format(
      work, math.floor(M.CSEARCH_ADD_RATIO_MAX * 100), total)
  end
  return "add", ("+%d added, %d dirty, -%d removed"):format(
    stats.added_n or 0, stats.dirty_n or 0, stats.removed_n or 0)
end

-- Read a list file into { set = {path=true}, list = {...}, n = count }.
local function read_list_file(path)
  local set, list, n = {}, {}, 0
  local f = path and io.open(path, "r") or nil
  if not f then return nil end
  for line in f:lines() do
    line = line:gsub("\r$", "")
    if line ~= "" and not set[line] then
      set[line] = true
      n = n + 1
      list[n] = line
    end
  end
  f:close()
  return { set = set, list = list, n = n }
end

-- Drop-in replacement for the three prepare-path build_index calls.
-- cb(ok, err, stats) — stats gains .mode ("reset"|"add"|"skip") and .delta.
-- Owns: diff, mode decision, add→reset fallback, snapshot refresh on success.
-- Does NOT own: csearch_build_begin/done (call sites keep that), fingerprint /
-- dirty-clear (call sites keep on_full_csearch_success — snapshot refresh here
-- is the only extra obligation, and it is idempotent).
function M.csearch_smart_build(ctx, cs_ctx, abs_list, cb, deps)
  local original_cb, finished = cb, false
  cb = function(...)
    if finished then return end
    finished = true
    original_cb(...)
  end
  local function guard(fn)
    return function(...)
      local ok, err = pcall(fn, ...)
      if not ok then cb(false, tostring(err), {}) end
    end
  end
  local code_search = require("utils.code_search")
  local snap_path = M.csearch_snapshot_path(ctx)
  local new_list = read_list_file(abs_list)
  if not new_list then
    vim.schedule(function() cb(false, "cannot read " .. tostring(abs_list), {}) end)
    return
  end

  local function snapshot_current()
    if not snap_path then return true end
    local ok, copied = pcall(vim.uv.fs_copyfile, abs_list, snap_path)
    return ok and copied == true
  end

  local git_before, recovered, recovery_stats
  local missing_from_cache = {}
  local function publish_filtered_workspace()
    local path = ctx and ctx.paths and ctx.paths.workspace_all_list
    if not next(missing_from_cache) or not path then return true end
    local input = read_list_file(path)
    if not input or not cs_ctx.workspace_root then return false end
    local remaining, path_key = {}, require("utils.platform").driver().path_key
    local removed_keys = {}
    for p in pairs(missing_from_cache) do removed_keys[path_key(fs.norm(p))] = true end
    for _, line in ipairs(input.list) do
      local full = fs.is_absolute_path(line) and fs.norm(line) or fs.join(cs_ctx.workspace_root, line)
      if not removed_keys[path_key(full)] then remaining[#remaining + 1] = line end
    end
    local tmp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
    local ok = pcall(function()
      local f = assert(io.open(tmp, "wb"))
      for _, line in ipairs(remaining) do assert(f:write(line, "\n")) end
      assert(f:close()); assert(vim.uv.fs_rename(tmp, path))
    end)
    if not ok then pcall(os.remove, tmp) end
    return ok
  end
  local function published(stats, complete)
    if not publish_filtered_workspace() or not snapshot_current() then
      local path = git.path(ctx); if path then pcall(os.remove, path) end
      cb(false, "cannot publish csearch file snapshot", stats); return
    end
    stats.workspace_list_changed = next(missing_from_cache) ~= nil
    git.save(ctx, git_before, complete, stats.covered_paths, guard(function(saved, coverage_valid)
      stats.git_recorded = saved == true
      stats.git_recovered = stats.git_recovered == true and coverage_valid == true
      stats.git_recovery = recovery_stats
      cb(true, nil, stats)
    end))
  end

  local function run_reset(reason, after_fallback)
    code_search.build_index(cs_ctx, abs_list, guard(function(ok, err, stats)
      stats = stats or {}
      stats.mode = "reset"
      stats.delta = reason
      if ok then published(stats, true) else cb(ok, err, stats) end
    end), { mode = "reset" })
    if after_fallback then
      vim.schedule(function()
        vim.notify("[ue] csearch incremental add failed — fell back to full rebuild ("
          .. tostring(after_fallback) .. ")", vim.log.levels.WARN,
          { title = "UE", replace = "ue.csearch.build" })
      end)
    end
  end

  -- Gather diff inputs.
  local old_list = snap_path and read_list_file(snap_path) or nil
  -- The sidecar predates the primary csearch index and can be absent after an
  -- upgrade or interrupted cleanup. Rebuild it without a full reset only when
  -- two independent facts agree: the primary index is usable, and the current
  -- canonical workspace list has the exact fingerprint recorded after the last
  -- successful build. The absolute temp list cannot be hashed for this check
  -- because workspace_all.files is workspace-relative on same-drive entries.
  if not old_list and snap_path and ctx and ctx.paths and ctx.paths.workspace_all_list then
    local state = deps.read_state(ctx.engine_root)
    local recorded = state and state.csearch_input_hash or nil
    local current = deps.list_fingerprint(ctx.paths.workspace_all_list)
    local ok_indexed, indexed = pcall(code_search.is_indexed, cs_ctx)
    if ok_indexed and indexed and type(recorded) == "string" and recorded ~= ""
        and current == recorded then
      old_list = new_list
    end
  end
  local added, removed = {}, {}
  if old_list then
    for _, p in ipairs(new_list.list) do
      if not old_list.set[p] then added[#added + 1] = p end
    end
    for _, p in ipairs(old_list.list) do
      if not new_list.set[p] then removed[#removed + 1] = p end
    end
  end
  -- Watcher dirty files still present in the new set (modified existing files;
  -- drop entries that vanished — they show up as removals instead).
  local dirty_in_set, dirty_seen, dirty_capped = {}, {}, false
  do
    local ok_watch, watch = pcall(require, "utils.ue_watch")
    dirty_capped = ok_watch and watch.persistent_dirty_status and watch.persistent_dirty_status().capped or false
    if ok_watch and type(watch.snapshot_persistent_dirty) == "function" then
      for _, p in ipairs(watch.snapshot_persistent_dirty() or {}) do
        if new_list.set[p] and not dirty_seen[p] then
          dirty_seen[p] = true
          dirty_in_set[#dirty_in_set + 1] = p
        end
      end
    end
  end
  local function decide()
    -- added ∪ dirty without double-counting.
    local add_input, add_seen = {}, {}
    for _, p in ipairs(added) do
      if new_list.set[p] and not add_seen[p] then add_seen[p] = true; add_input[#add_input + 1] = p end
    end
    for _, p in ipairs(dirty_in_set) do
      if new_list.set[p] and not add_seen[p] then add_seen[p] = true; add_input[#add_input + 1] = p end
    end

    local mode, why = M.csearch_build_mode({
      forced       = ctx and ctx._force_csearch or false,
      has_snapshot = old_list ~= nil,
      added_n      = #added,
      removed_n    = #removed,
      dirty_n      = #dirty_in_set,
      dirty_capped = dirty_capped,
      git_recovered = recovered,
      total_n      = new_list.n,
    })

    -- Probe (D11 soak): record which mode each prepare takes, so the next
    -- session can verify the incremental path actually fires in daily use
    -- (report-first workflow — probe-feedback-loop spec #1).
    pcall(function()
      local probe = require("utils.probe")
      -- Routine decisions are evidence, not failures (state=ok).
      probe.observe("csearch-smart-build", "git-overflow-2026-10-03")
      probe.record("csearch-smart-build", mode, { state = "ok", why = why, removed = #removed })
    end)

    if mode == "skip" then
      snapshot_current()  -- ordering may differ; keep snapshot in lockstep with list
      vim.schedule(function()
        cb(true, nil, { mode = "skip", delta = why, ms = 0, index_size = 0, skipped = true })
      end)
      return
    end

    if mode == "reset" then
      run_reset(why)
      return
    end

    -- mode == "add": feed ONLY the delta.
    local add_list_path = abs_list .. (".add.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
    local fout = io.open(add_list_path, "w")
    if not fout then
      run_reset("cannot write add-list")
      return
    end
    for _, p in ipairs(add_input) do fout:write(p, "\n") end
    fout:close()
    local delete_list_path
    if #removed > 0 then
      delete_list_path = add_list_path .. ".delete"
      local dout = io.open(delete_list_path, "w")
      if not dout then
        pcall(os.remove, add_list_path)
        run_reset("cannot write delete-list")
        return
      end
      for _, p in ipairs(removed) do dout:write(p, "\n") end
      dout:close()
    end
    code_search.build_index(cs_ctx, add_list_path, guard(function(ok, err, stats)
      pcall(os.remove, add_list_path)
      if delete_list_path then pcall(os.remove, delete_list_path) end
      if ok then
        stats = stats or {}
        stats.mode = "add"
        stats.delta = why
        stats.git_recovered = recovered == true
        stats.covered_paths = add_input
        published(stats, recovered == true)
        return
      end
      -- Incremental refused/failed (typically D9 unusable-idx guard). One
      -- automatic reset — always safe — instead of surfacing a dead end.
      pcall(function()
        require("utils.probe").record("csearch-smart-build", "add-fallback-reset",
          tostring(err or "?"):sub(1, 120))
      end)
      run_reset("fallback after add failure", err or "?")
    end), { mode = "add", delete_list = delete_list_path })
  end
  if not dirty_capped and old_list and not (ctx and ctx._force_csearch)
      and #added + #removed + #dirty_in_set == 0 then decide(); return end
  git.capture(ctx, guard(function(before)
    git_before = before
    if not dirty_capped or not old_list or (ctx and ctx._force_csearch) then decide(); return end
    git.recover(ctx, before, new_list.list, old_list.list, guard(function(changes, failure, details)
      recovery_stats = details
      recovered = changes ~= nil
      if changes then
        local paths, index, removed_set = vim.tbl_keys(changes), 0, {}
        for _, p in ipairs(removed) do removed_set[p] = true end
        local function finish_stat()
          if next(missing_from_cache) then
            local filtered = {}
            for _, file in ipairs(new_list.list) do
              if new_list.set[file] then filtered[#filtered + 1] = file end
            end
            new_list.list, new_list.n = filtered, #filtered
            local f = io.open(abs_list, "wb")
            if not f then cb(false, "cannot filter csearch input", {}); return end
            for _, file in ipairs(filtered) do f:write(file, "\n") end
            f:close()
          end
          decide()
        end
        local function next_stat()
          index = index + 1
          local p = paths[index]
          if not p then finish_stat(); return end
          vim.uv.fs_stat(p, function(stat_err, stat)
            vim.schedule(guard(function()
              if stat_err and not tostring(stat_err):find("ENOENT", 1, true)
                  and not tostring(stat_err):find("ENOTDIR", 1, true) then
                recovered = false; finish_stat(); return
              end
              if not stat or stat.type ~= "file" then
                if new_list.set[p] then
                  new_list.set[p], missing_from_cache[p] = nil, true
                  if not removed_set[p] then removed_set[p] = true; removed[#removed + 1] = p end
                end
              elseif new_list.set[p] and not dirty_seen[p] then
                dirty_seen[p] = true; dirty_in_set[#dirty_in_set + 1] = p
              end
              next_stat()
            end))
          end)
        end
        next_stat()
        return
      else
        pcall(function() require("utils.probe").record("csearch-smart-build", "git-recovery-reset",
          {state = "ok", why = failure}) end)
      end
      decide()
    end))
  end))
end

return M
