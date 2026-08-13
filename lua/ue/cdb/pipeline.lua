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
--   M.set_runtime({ jobstart = ..., notify = ..., log_error = ... })
--   M.slim(path)                      -> bool          (synchronous)
--   M.run(path, targets, on_done?)    -> jobid|0|nil, error? (background)

local fs = require("ue.core.fs")
local file_lock = require("ue.file_lock")

local M = {}
local running = false

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
}

--- Configure the runtime. ue.lua should call this once during setup;
--- tests can call it with stub functions.
---@param opts { jobstart: fun(cmd:any, tag:string, opts:table):integer, notify: fun(msg:string, level:integer?), log_error: fun(scope:string, msg:string)? }
function M.set_runtime(opts)
  if opts.jobstart  then _rt.jobstart  = opts.jobstart  end
  if opts.notify    then _rt.notify    = opts.notify    end
  if opts.log_error then _rt.log_error = opts.log_error end
end

--- Whether a compile_commands writer pipeline currently owns the mutation slot.
function M.is_running()
  return running
end

local function python_exe()
  return (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and "python" or "python3"
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
  local cmd = { python_exe(), script, path, "--keep-engine" }
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
---@return integer? jobid
---@return string? error
function M.run(path, targets, on_done)
  if running then
    local msg = "compile_commands pipeline is already running"
    _rt.notify(msg, vim.log.levels.WARN)
    if on_done then on_done(false, msg) end
    return nil, msg
  end

  local python = python_exe()

  local CANONICAL_ARGS = {
    ["expand_response_cdb.py"] = function(p) return '"' .. p .. '"' end,
    ["prebuild_pch_v2.py"]     = function(p) return '"' .. p .. '"' end,
    ["resolve_cdb_paths.py"]   = function(p) return '"' .. p .. '"' end,
    ["unify_include_dirs.py"]  = function(p) return '"' .. p .. '" --max-overhead=200' end,
    ["prune_include_dirs.py"]  = function(p, isolate)
      isolate.value = true
      return '"' .. p .. '" --sample 20'
    end,
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

  local cmds = {}
  for _, name in ipairs(script_names) do
    local script_path = tool_path(name)
    if fs.is_file(script_path) then
      local arg_builder = CANONICAL_ARGS[name]
      local isolate_flag = { value = false }
      local args
      if arg_builder then
        args = arg_builder(path, isolate_flag)
        if name == "unify_include_dirs.py" and engine_only then
          args = args .. " --include-engine"
        end
      else
        -- Unknown script: pass the cdb path as a single quoted arg.
        args = '"' .. path .. '"'
      end
      local prefix = isolate_flag.value and (python .. ' -I "') or (python .. ' "')
      table.insert(cmds, prefix .. script_path .. '" ' .. args)
    end
  end

  if #cmds == 0 then
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

  _rt.notify("compile_commands pipeline: expand+pch+resolve+unify+prune in background...", vim.log.levels.INFO)

  local stat_before = vim.uv.fs_stat(path)
  local mtime_before = (stat_before and stat_before.mtime and stat_before.mtime.sec) or 0
  local shell_cmd = table.concat(cmds, " && ")

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
    file_lock.release(lease)
    if on_done then on_done(ok, err) end
  end

  local jobid = _rt.jobstart(shell_cmd, "ue-pipeline", {
    cdb = path,
    on_exit = function(_, _, _)
      local stat_after = vim.uv.fs_stat(path)
      local mtime_after = (stat_after and stat_after.mtime and stat_after.mtime.sec) or 0
      if mtime_after == mtime_before then
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
        restart_clangd()
        finish(true)
      end)
    end,
    on_fail = function(code, log_lines, log_path)
      local tail = {}
      for i = math.max(1, #log_lines - 4), #log_lines do
        tail[#tail + 1] = log_lines[i]
      end
      local msg = ("ue-pipeline failed (exit %d)\nlog: %s\n--- last lines ---\n%s")
        :format(code, log_path, table.concat(tail, "\n"))
      _rt.log_error("ue.runner", msg)
      finish(false, msg)
    end,
  })
  if not jobid or jobid <= 0 then
    local msg = "compile_commands pipeline failed to start"
    _rt.log_error("ue.runner", msg)
    finish(false, msg)
    return nil, msg
  end
  if finished and not finish_ok then
    return nil, finish_err
  end
  return jobid
end

return M
