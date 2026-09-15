-- Standalone csearch rebuild owner. The facade supplies existing scan/list
-- policy and writer hooks; this module never dispatches a Prepare workflow.
local M = {}
local fs = require("ue.core.fs")
local file_lock = require("ue.file_lock")
local project_state = require("ue.project_state")

-- An explicit search-only writer: share Prepare's list lease, but never enter
-- its CDB, GTAGS or target-build phases.
function M.start(opts, deps)
  opts = opts or {}
  local ctx, err = opts.context, nil
  if not ctx then ctx, err = deps.resolve_context() end
  if not ctx then
    vim.notify(err or "UEBuildCsearch: no UE context", vim.log.levels.WARN)
    return
  end
  ctx = vim.deepcopy(ctx)
  ctx._force_csearch = true
  local code_search = require("utils.code_search")
  if not code_search.cindex_uefilter_exe() then
    vim.notify("UEBuildCsearch: cindex-uefilter not found — " .. code_search.install_hint(), vim.log.levels.WARN)
    return
  end
  if deps.is_running() then
    vim.notify("UEBuildCsearch: prepare or csearch build already in progress", vim.log.levels.WARN)
    return
  end
  local lease, lease_err = file_lock.acquire(fs.join(ctx.paths.runtime_dir, "prepare.lock"))
  if not lease then
    vim.notify("UEBuildCsearch: workspace lists owned by another writer: " .. tostring(lease_err), vim.log.levels.WARN)
    return
  end
  if not deps.build_begin("UEBuildCsearch", ctx.paths.csearch_idx) then
    file_lock.release(lease)
    return
  end
  local dirty_snapshot, started_at = deps.build_snapshot()
  local selection = vim.deepcopy(project_state.current(ctx.engine_root))
  local watch = require("utils.ue_watch")
  local dirty_owner = watch.persistent_dirty_status().path
  local scan = opts.scan or deps.scan
  local root = deps.workspace_root(ctx)
  local abs_list = ctx.paths.cache .. ("/csearch_full.%d.%s.txt"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local staged_list = abs_list .. ".workspace"
  local input_hash
  local finished = false
  local function finish(ok, failure, stats)
    if finished then return end
    finished = true
    local clean_ok, clean_err = pcall(function()
      if ok then
        local current = project_state.current(ctx.engine_root)
        if selection and current and current.project_key == selection.project_key
            and watch.persistent_dirty_status().path == dirty_owner then
          deps.clear_dirty("UEBuildCsearch", dirty_snapshot,
            started_at, true)
        end
        if input_hash then
          local saved, save_err = project_state.update(ctx.engine_root, "csearch_input_hash", input_hash, selection)
          if not saved then error(save_err or "cannot save csearch input fingerprint") end
        end
        code_search._reset_probe_cache()
      end
    end)
    deps.build_done()
    file_lock.release(lease)
    pcall(os.remove, abs_list)
    pcall(os.remove, staged_list)
    if not clean_ok then ok, failure = false, clean_err end
    vim.notify(ok and ("UEBuildCsearch: csearch rebuilt in %.1fs"):format(((stats or {}).ms or 0) / 1000)
      or ("UEBuildCsearch failed: " .. tostring(failure or "unknown error")),
      ok and vim.log.levels.INFO or vim.log.levels.WARN, { title = "UE", replace = "ue.csearch.build" })
  end
  local function guarded(fn)
    return function(...)
      if finished then return end
      local ok, failure = pcall(fn, ...)
      if not ok then finish(false, failure) end
    end
  end
  local function build(project_rel, engine_rel)
    local absolute, relative, seen = {}, {}, {}
    local function add(base, entries)
      for _, path in ipairs(deps.filter_paths(entries)) do
        local full = fs.join(base, path)
        if not seen[full] then
          seen[full] = true
          absolute[#absolute + 1] = full
          relative[#relative + 1] = fs.relative_to(root, full)
        end
      end
    end
    add(ctx.project_root, project_rel)
    add(ctx.engine_root, engine_rel)
    table.sort(absolute)
    table.sort(relative)
    assert(deps.write_lines(abs_list, absolute), "cannot write csearch input list")
    assert(deps.write_lines(staged_list, relative), "cannot write workspace list")
    input_hash = assert(deps.fingerprint(staged_list), "cannot fingerprint workspace list")
    fs.ensure_dir(fs.dirname(ctx.paths.workspace_all_list))
    assert(vim.uv.fs_rename(staged_list, ctx.paths.workspace_all_list))
    deps.smart_build(ctx, { workspace_root = root, csearch_idx = ctx.paths.csearch_idx },
      abs_list, guarded(finish))
  end
  vim.notify("UEBuildCsearch: scanning files and rebuilding csearch ...", vim.log.levels.INFO,
    { title = "UE", replace = "ue.csearch.build" })
  guarded(function()
    local function scan_engine(project_rel)
      scan(ctx.engine_root, deps.engine_dirs, guarded(function(engine_rel, scan_err)
        if not engine_rel then finish(false, scan_err); return end
        build(project_rel, engine_rel)
      end))
    end
    if ctx.project_root and ctx.project_root ~= "" then
      scan(ctx.project_root, deps.project_dirs(ctx), guarded(function(project_rel, scan_err)
        if not project_rel then finish(false, scan_err); return end
        scan_engine(project_rel)
      end))
    else
      scan_engine({})
    end
  end)()
end

return M
