-- ue.cdb.pipeline — orchestrates the slim → expand → pch → resolve →
-- unify → prune sequence on a compile_commands.json file.
--
-- Phase E.3: lift the pipeline driver out of `ue.lua`. Unlike the pure
-- helpers in `ue.cdb.json` and `ue.cdb.shaders`, this module DOES need
-- two upvalues from the monolith:
--
--   * `_logged_jobstart`  - background job runner with rotating logs
--   * a notifier the user already trusts
--
-- We accept them via a tiny `set_runtime` shim so the module remains
-- import-safe (no `require("ue")` at load time → no circular require)
-- and is trivially mockable in headless tests.
--
-- Public surface:
--   M.set_runtime({ jobstart = ..., notify = ..., log_error = ..., restart_clangd = ... })
--   M.slim(path)                      -> bool          (synchronous)
--   M.run(path, targets, on_done?)    -> jobid|0|nil, error? (background)

local fs = require("ue.core.fs")
local file_lock = require("ue.file_lock")
local platform = require("utils.platform")

local M = {}
local running = false
local current_jobid = nil
local pending_admission = nil
local pending_done = nil

-- Runtime injection table. Defaults assume no fancy logger so that even
-- pre-`set_runtime` calls degrade gracefully.
local _rt = {
  jobstart  = function(_, _, _) error("ue.cdb.pipeline: jobstart not configured") end,
  notify    = function(msg, level)
    vim.notify(msg, level or vim.log.levels.INFO)
  end,
  log_error = function(scope, msg)
    pcall(function() require("utils.log").notify_error(scope, msg) end)
  end,
  restart_clangd = nil,
}

--- Configure the runtime. ue.lua should call this once during setup;
--- tests can call it with stub functions.
---@param opts { jobstart: fun(cmd:any, tag:string, opts:table):integer, notify: fun(msg:string, level:integer?), log_error: fun(scope:string, msg:string)?, restart_clangd: fun()? }
function M.set_runtime(opts)
  if opts.jobstart  then _rt.jobstart  = opts.jobstart  end
  if opts.notify    then _rt.notify    = opts.notify    end
  if opts.log_error then _rt.log_error = opts.log_error end
  if opts.restart_clangd then _rt.restart_clangd = opts.restart_clangd end
end

--- Whether a compile_commands writer pipeline currently owns the mutation slot.
function M.is_running()
  return running
end

--- Cancel the in-flight pipeline job (if any). Build ⇄ prepare mutual
--- exclusion: the pipeline reads build products (rsp/receipts) and rewrites
--- the CDB; once a build starts rewriting those inputs the pipeline's output
--- is garbage (WAW hazard), so the build entrypoint kills it. jobstop drives
--- the runner's normal on_exit → on_fail → finish(false) path, which releases
--- the writer slot and the cross-process lease — nothing is force-reset here.
---@param reason string? human-readable cause for the notification
---@return boolean cancelled true when a live job was asked to stop
function M.cancel(reason)
  if not running then return false end
  _rt.notify(
    "compile_commands pipeline cancelled: " .. (reason or "superseded"),
    vim.log.levels.WARN)
  if pending_admission then
    pending_admission:cancel()
    pending_admission = nil
    running = false
    local done = pending_done
    pending_done = nil
    if done then done(false, "compile_commands pipeline cancelled before start") end
    return true
  end
  if not current_jobid then return false end
  pcall(vim.fn.jobstop, current_jobid)
  return true
end

local function python_exe()
  local resolved = platform.resolve_tool({
    name = "python",
    driver_candidates = function(driver)
      return driver.python_candidates()
    end,
  })
  if resolved.ok then return resolved.path end
  return resolved.candidates and resolved.candidates[1] or nil
end

local function tool_path(name)
  -- Phase I: read from ue.config first (lets the user point cdb.tools_dir
  -- at a custom location), fall back to stdpath("config")/tools for the
  -- existing install layout.
  local ok, cfg = pcall(require, "ue.config")
  if ok and cfg and cfg.get then
    local dir = cfg.get("cdb.tools_dir")
    if type(dir) == "string" and dir ~= "" then
      return dir .. "/" .. name
    end
  end
  return vim.fn.stdpath("config") .. "/tools/" .. name
end

--- Synchronously run slim_compile_commands.py on `path`.
--- Returns true on success / false on missing-script or failed run.
function M.slim(path)
  local script = tool_path("slim_compile_commands.py")
  if not fs.is_file(script) then
    _rt.notify("slim_compile_commands.py not found: " .. script, vim.log.levels.WARN)
    return false
  end
  local python = python_exe()
  if not python then
    _rt.notify("Python is unavailable for slim_compile_commands.py", vim.log.levels.WARN)
    return false
  end
  local cmd = { python, script, path, "--keep-engine" }
  local result = vim.fn.system(cmd)
  if vim.v.shell_error == 0 then
    local removed = (result or ""):match("剔除: (%d+)")
    if removed and tonumber(removed) > 0 then
      _rt.notify(result, vim.log.levels.INFO)
    end
    return true
  end
  _rt.notify("slim_compile_commands failed: " .. (result or ""), vim.log.levels.WARN)
  return false
end

local function copy_file(src, dst, cb)
  -- Async, non-blocking (F3, health-check 2026-07): the only caller loops
  -- inside a jobstart on_exit callback copying a multi-MB CDB to N targets;
  -- the previous `vim.fn.system(copy/cp)` blocked the main loop once per
  -- target. uv.fs_copyfile does the copy on the libuv threadpool; failure is
  -- logged (next :UEPrepare rewrites all targets anyway, so a missed mirror
  -- self-heals). cb() fires on the main loop when this copy settles.
  local uvfs = vim.uv or vim.loop
  uvfs.fs_copyfile(src, dst, { excl = false }, function(err)
    vim.schedule(function()
      if err then
        _rt.notify("cdb mirror copy failed (" .. dst .. "): " .. tostring(err),
          vim.log.levels.WARN)
      end
      if cb then cb() end
    end)
  end)
end

-- Copy `src` to targets[2..N] concurrently; call done() once ALL copies have
-- settled. Sequencing matters: the caller's on_done chain hands the SAME
-- source file to partition_base_cdb which rewrites it in place — starting
-- that while a copy is still reading src would mirror a torn file (same
-- torn-write class as the 2026-06-25 partition×pipeline race).
local function mirror_targets_then(src, targets, done)
  local n = targets and #targets or 0
  if n <= 1 then done(); return end
  local pending = n - 1
  for i = 2, n do
    copy_file(src, targets[i], function()
      pending = pending - 1
      if pending == 0 then done() end
    end)
  end
end

local function restart_clangd()
  local clients = vim.lsp.get_clients({ name = "clangd" })
  for _, client in ipairs(clients) do
    local bufs = vim.lsp.get_buffers_by_client_id(client.id)
    client:stop()
    vim.defer_fn(function()
      for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(buf) then
          vim.api.nvim_buf_call(buf, function()
            vim.cmd("LspStart clangd")
          end)
          break
        end
      end
    end, 500)
  end
end

local function restart_active_clangd()
  return (_rt.restart_clangd or restart_clangd)()
end

local function mtime_key(path)
  local stat = vim.uv.fs_stat(path)
  local mtime = stat and stat.mtime or {}
  return tostring(mtime.sec or 0) .. ":" .. tostring(mtime.nsec or 0)
end

--- Background pipeline: expand → pch → resolve → unify → prune. Each step
--- is skipped if its python script is absent. After success, syncs `path`
--- to every other entry in `targets` and restarts clangd. Returns the
--- jobid from `_rt.jobstart`, 0 when no scripts exist, or nil + error when
--- the writer slot is occupied or the background job cannot start.
---
--- Phase I: the script list and per-step args are sourced from
--- ue.config.cdb.steps (default = the original 5-step recipe). To skip a
--- step the user simply removes its entry from the list.
---@param path string CDB file to mutate in-place
---@param targets string[]? sibling CDB targets to copy `path` into on success
---@param on_done fun(ok:boolean, err:string?)? optional completion callback (after clangd restart)
---@param opts? { force_restart?: boolean } force reload when the source changed before this pipeline started
---@return integer? jobid
---@return string? error
function M.run(path, targets, on_done, opts)
  opts = opts or {}
  if running then
    local msg = "compile_commands pipeline is already running"
    _rt.notify(msg, vim.log.levels.WARN)
    if on_done then on_done(false, msg) end
    return nil, msg
  end

  -- Gate the whole chain once, before taking the writer lease or spawning its
  -- first Python step. Later steps belong to the already-admitted unit and MUST
  -- NOT independently re-enter policy (that could strand a half-written CDB).
  if opts._host_admitted ~= true then
    local admission = require("utils.host_admission")
    local started, jobid, start_err, control = admission.run_when_allowed({
      name = "compile_commands pipeline",
      start = function()
        running = false
        pending_admission = nil
        pending_done = nil
        return M.run(path, targets, on_done,
          vim.tbl_extend("force", opts, { _host_admitted = true }))
      end,
      on_defer = function(reason, reading, deferrals)
        pcall(function()
          require("utils.log").debug_ctx("host.admission", "deferred CDB pipeline", {
            reason = reason,
            deferrals = deferrals,
            host_pct = reading and reading.host_pct or nil,
          })
        end)
      end,
      on_error = function(err)
        running = false
        pending_admission = nil
        pending_done = nil
        _rt.log_error("host.admission", "CDB admission failed: " .. tostring(err))
        if on_done then on_done(false, tostring(err)) end
      end,
    })
    if started then return jobid, start_err end
    if control.finished then return nil, control.error or "CDB admission failed" end
    running = true
    pending_admission = control
    pending_done = on_done
    _rt.notify("compile_commands pipeline queued until host resources are available",
      vim.log.levels.INFO)
    return 0
  end

  local python = python_exe()

  local CANONICAL_ARGS = {
    ["expand_response_cdb.py"] = function(p) return { p } end,
    ["prebuild_pch_v2.py"] = function(p) return { p } end,
    ["resolve_cdb_paths.py"] = function(p) return { p } end,
    ["unify_include_dirs.py"] = function(p) return { p, "--max-overhead=200" } end,
    -- --sample 4: the script's own default is 2 ("per-module groups have
    -- 1-3 distinct -I sets; 2 is enough" — prune_include_dirs.py main());
    -- the old 20 predates module-grouping and cost ~5x the IO for no
    -- observed keep-set difference. 4 keeps a safety margin over 2.
    -- --workers 4: the previous min(20, cpu_count) thread pool saturated
    -- every core during UBT builds (2026-08-18 incident). The scan is
    -- IO-bound os.walk + file reads; 4 threads keep it reasonable while
    -- leaving cores for a concurrent build.
    ["prune_include_dirs.py"] = function(p) return { p, "--sample", "4", "--workers", "4" }, true end,
  }

  -- Read the configured pipeline; fall back to canonical recipe if config
  -- is unavailable for any reason.
  local script_names
  do
    local ok, cfg = pcall(require, "ue.config")
    script_names = (ok and cfg and cfg.get and cfg.get("cdb.steps")) or {
      "expand_response_cdb.py",
      "prebuild_pch_v2.py",
      "resolve_cdb_paths.py",
      "unify_include_dirs.py",
      "prune_include_dirs.py",
    }
  end

  -- Engine-only CDB → unify needs --include-engine
  local path_lower = path:gsub("\\", "/"):lower()
  local engine_only = path_lower:find("/engine/") ~= nil

  local host_driver = require("utils.platform").driver()
  local steps = {}
  for _, name in ipairs(script_names) do
    local script_path = tool_path(name)
    local host_supports_step = name ~= "prebuild_pch_v2.py"
      or type(host_driver.pch_build_plan) == "function"
    if host_supports_step and fs.is_file(script_path) then
      local arg_builder = CANONICAL_ARGS[name]
      local args
      local isolate = false
      if arg_builder then
        args, isolate = arg_builder(path)
        if name == "unify_include_dirs.py" and engine_only then
          args[#args + 1] = "--include-engine"
        end
      else
        -- Unknown scripts receive the CDB path as one argv item.
        args = { path }
      end

      -- `-u`: unbuffered stdout. Python fully buffers stdout when piped, so a
      -- long step (prune's threaded include scan can run minutes on a 300MB
      -- CDB) produced ZERO log output until exit — indistinguishable from a
      -- hang. With -u every print() reaches the streamed log immediately.
      local command = { python, "-u" }
      if isolate then command[#command + 1] = "-I" end
      command[#command + 1] = script_path
      vim.list_extend(command, args)
      steps[#steps + 1] = {
        name = name:gsub("%.py$", ""),
        command = command,
      }
    end
  end

  if #steps == 0 then
    if opts.force_restart then
      restart_active_clangd()
    end
    if on_done then on_done(true) end
    return 0
  end

  local lease, lease_err = file_lock.acquire(path .. ".writer.lock")
  if not lease then
    local msg = "compile_commands pipeline is owned by another Neovim: " .. tostring(lease_err)
    _rt.notify(msg, vim.log.levels.WARN)
    if on_done then on_done(false, msg) end
    return nil, msg
  end

  local phase_names = {}
  for _, step in ipairs(steps) do phase_names[#phase_names + 1] = step.name end
  _rt.notify(
    "compile_commands pipeline: " .. table.concat(phase_names, "+") .. " in background...",
    vim.log.levels.INFO
  )

  local mtime_before = mtime_key(path)

  running = true
  local finished = false
  local finish_ok
  local finish_err
  local function finish(ok, err)
    if finished then return end
    finished = true
    finish_ok = ok
    finish_err = err
    running = false
    current_jobid = nil
    file_lock.release(lease)
    if on_done then on_done(ok, err) end
  end

  -- Intermediate backups written by the python steps (prebuild_pch_v2 ->
  -- `.pre-pch.bak`, unify_include_dirs -> `.pre-unify.bak`). They exist so a
  -- failing step can be diagnosed against its input, but on SUCCESS they are
  -- dead weight: each is a near-copy of a ~250MB CDB, and nothing ever removed
  -- them. Observed on this machine: 492MB of stale `.bak` beside a 241MB active
  -- CDB. C4-6 ("skip writes when unchanged") had no counterpart for "delete what
  -- succeeded", so they accumulated silently.
  --
  -- Only remove on success, and only these two exact suffixes: never touch the
  -- active CDB, another platform's shard, or another project bucket (K27/C5b).
  local function cleanup_intermediate_backups()
    local removed, freed = 0, 0
    for _, bak in ipairs(M.intermediate_backup_paths(path)) do
      local stat = vim.uv.fs_stat(bak)
      if stat and stat.type == "file" then
        local ok = pcall(vim.uv.fs_unlink, bak)
        if ok then
          removed = removed + 1
          freed = freed + (stat.size or 0)
        end
      end
    end
    if removed > 0 then
      _rt.notify(("compile_commands pipeline: removed %d intermediate backup(s), freed %.0f MB")
        :format(removed, freed / 1024 / 1024), vim.log.levels.INFO)
    end
    return removed, freed
  end

  local function finish_success()
    -- Cleanup belongs to the success path: a failed run must keep its backups
    -- so the failure remains diagnosable.
    cleanup_intermediate_backups()
    local mtime_after = mtime_key(path)
    if not opts.force_restart and mtime_after == mtime_before then
      _rt.notify("compile_commands pipeline: no changes, skipping clangd restart", vim.log.levels.INFO)
      finish(true)
      return
    end
    -- Mirror to secondary targets ASYNC, then restart clangd + hand off.
    -- on_done (→ partition_base_cdb) must not run until mirrors settle —
    -- partition rewrites `path` in place and a concurrent reader would
    -- mirror a torn file.
    mirror_targets_then(path, targets, function()
      _rt.notify("compile_commands pipeline: done. Restarting clangd...", vim.log.levels.INFO)
      restart_active_clangd()
      finish(true)
    end)
  end

  local function fail_step(step, code, log_lines, log_path)
    local tail = {}
    log_lines = log_lines or {}
    for i = math.max(1, #log_lines - 4), #log_lines do
      tail[#tail + 1] = log_lines[i]
    end
    local msg = ("ue-pipeline-%s failed (exit %d)\nlog: %s\n--- last lines ---\n%s")
      :format(step.name, tonumber(code) or -1, tostring(log_path or ""), table.concat(tail, "\n"))
    _rt.log_error("ue.runner", msg)
    finish(false, msg)
  end

  local start_step
  start_step = function(index)
    if finished then return nil, finish_err end
    local step = steps[index]
    local tag = "ue-pipeline-" .. step.name
    local jobid = _rt.jobstart(step.command, tag, {
      cdb = path,
      on_exit = function()
        if index == #steps then
          finish_success()
          return
        end
        start_step(index + 1)
      end,
      on_fail = function(code, log_lines, log_path)
        fail_step(step, code, log_lines, log_path)
      end,
    })
    if not jobid or jobid <= 0 then
      local msg = tag .. " failed to start"
      _rt.log_error("ue.runner", msg)
      finish(false, msg)
      return nil, msg
    end
    -- Track the CURRENT step's job so M.cancel() (build ⇄ prepare mutual
    -- exclusion) kills whichever step is in flight, not just the first.
    current_jobid = jobid
    return jobid
  end

  local jobid, start_err = start_step(1)
  if not jobid then
    return nil, start_err or finish_err
  end
  if finished and not finish_ok then
    return nil, finish_err
  end
  -- Register the pipeline in the generic task registry so :Tasks can
  -- list/cancel it. Register-only side path per task_registry contract:
  -- single pcall AFTER job creation, nothing added to on_exit callbacks.
  -- (Each step streams its own live log under stdpath('log')/ue-pipeline-*;
  -- failures carry the exact per-step log path.)
  pcall(function()
    require("utils.task_registry").register({
      name = "UE cdb pipeline (" .. #steps .. " steps)",
      group = "ue",
      kind = "job",
      handle = jobid,
      started_at = os.time(),
    })
  end)
  return jobid
end

-- Suffixes of intermediate backups the python steps leave behind
-- (prebuild_pch_v2 -> `.pre-pch.bak`, unify_include_dirs -> `.pre-unify.bak`).
-- Module-level so the cleanup policy is inspectable and testable rather than
-- hidden in a closure. Deliberately an exact suffix list: anything broader risks
-- deleting an active CDB, another platform's shard, or another project bucket
-- (K27/C5b invalidation matrix).
M.INTERMEDIATE_BACKUP_SUFFIXES = { ".pre-pch.bak", ".pre-unify.bak" }

--- Which paths should be removed after a SUCCESSFUL pipeline run.
--- Pure: takes the active CDB path, returns the backup paths to unlink.
--- @param path string active compile_commands.json path
--- @return string[] paths
function M.intermediate_backup_paths(path)
  local out = {}
  if type(path) ~= "string" or path == "" then
    return out
  end
  for _, suffix in ipairs(M.INTERMEDIATE_BACKUP_SUFFIXES) do
    out[#out + 1] = path .. suffix
  end
  return out
end

return M
