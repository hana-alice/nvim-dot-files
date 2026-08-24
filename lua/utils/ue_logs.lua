local M = {}

local MAX_LOG_LINES = 12000

local state = {
  buf = nil,
  jobid = nil,
  kind = nil,
  source_id = nil,
  title = nil,
  win = nil,
}

local stop_requests = {}

local function project_name_from_uproject(trim, uproject)
  local name = trim(vim.fs.basename(uproject or ""))
  if name == "" then
    return ""
  end
  return name:gsub("%.uproject$", "")
end

local function prune_state()
  if state.win and not vim.api.nvim_win_is_valid(state.win) then
    state.win = nil
  end
  if state.buf and not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf = nil
    state.jobid = nil
    state.kind = nil
    state.source_id = nil
    state.title = nil
  end
end

local function focus_window(win)
  if win and vim.api.nvim_win_is_valid(win) then
    vim.api.nvim_set_current_win(win)
    return true
  end
  return false
end

local function job_running()
  if not state.jobid then
    return false
  end
  local ok, result = pcall(vim.fn.jobwait, { state.jobid }, 0)
  return ok and result and result[1] == -1
end

local function close_window()
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, false)
    state.win = nil
  end
end

local function stop_job()
  if state.jobid then
    stop_requests[state.jobid] = true
    pcall(vim.fn.jobstop, state.jobid)
    state.jobid = nil
  end
end

local function reset_state()
  stop_job()
  close_window()
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  state.buf = nil
  state.kind = nil
  state.source_id = nil
  state.title = nil
end

local function ensure_window(height)
  prune_state()

  if state.win and focus_window(state.win) then
    return state.win
  end

  local target_height = height or math.max(10, math.floor(vim.o.lines * 0.28))
  vim.cmd(("botright %dnew"):format(target_height))
  state.win = vim.api.nvim_get_current_win()

  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    vim.api.nvim_win_set_buf(state.win, state.buf)
  end

  return state.win
end

local function set_header(buf, spec)
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end

  local lines = {
    ("# %s"):format(spec.title),
  }

  if spec.summary and spec.summary ~= "" then
    lines[#lines + 1] = ("# %s"):format(spec.summary)
  end

  lines[#lines + 1] = ""
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
end

local function append_lines(buf, lines)
  if not vim.api.nvim_buf_is_valid(buf) or not lines or #lines == 0 then
    return
  end

  local windows = vim.fn.win_findbuf(buf)
  local at_bottom = {}
  local line_count_before = vim.api.nvim_buf_line_count(buf)

  for _, win in ipairs(windows or {}) do
    if vim.api.nvim_win_is_valid(win) then
      local cursor = vim.api.nvim_win_get_cursor(win)
      at_bottom[win] = cursor[1] >= math.max(1, line_count_before - 1)
    end
  end

  vim.api.nvim_buf_set_lines(buf, -1, -1, false, lines)

  local total = vim.api.nvim_buf_line_count(buf)
  if total > MAX_LOG_LINES then
    local trim_count = total - MAX_LOG_LINES
    vim.api.nvim_buf_set_lines(buf, 0, trim_count, false, {})
    total = vim.api.nvim_buf_line_count(buf)
  end

  for _, win in ipairs(windows or {}) do
    if at_bottom[win] and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_set_cursor(win, { total, 0 })
    end
  end
end

local function normalize_chunks(env, pending, chunks)
  local out = {}
  pending = pending or ""

  for _, chunk in ipairs(chunks or {}) do
    if chunk and chunk ~= "" then
      local text = env.strip_ansi(chunk)
      text = text:gsub("\r\n", "\n"):gsub("\r", "\n")
      pending = pending .. text

      while true do
        local newline = pending:find("\n", 1, true)
        if not newline then
          break
        end
        out[#out + 1] = pending:sub(1, newline - 1)
        pending = pending:sub(newline + 1)
      end
    end
  end

  return pending, out
end

local function flush_pending(pending)
  if pending and pending ~= "" then
    return { pending }
  end
  return {}
end

local function newest_existing_file(env, candidates)
  local best
  local best_mtime = -1

  for _, candidate in ipairs(candidates or {}) do
    local normalized = env.norm(candidate)
    if normalized ~= "" and env.is_file(normalized) then
      local mtime = env.file_mtime(normalized)
      if mtime > best_mtime or (mtime == best_mtime and (not best or normalized < best)) then
        best = normalized
        best_mtime = mtime
      end
    end
  end

  return best
end

local function newest_log_in_dirs(env, dirs)
  local files = {}

  for _, dir in ipairs(dirs or {}) do
    for _, path in ipairs(env.glob_paths(env.join(dir, "*.log"))) do
      files[#files + 1] = path
    end
  end

  return newest_existing_file(env, files)
end

local function desktop_ue_log_path(env, ctx)
  if not ctx.project_root then
    return nil, "No project configured for engine root. Run :UESetProject [path]"
  end

  local uproject = ctx.uproject or env.find_uproject_in_dir(ctx.project_root)
  local project_name = project_name_from_uproject(env.trim, uproject)
  local dirs = {}

  local function add_dir(path)
    path = env.norm(path)
    if path ~= "" then
      dirs[#dirs + 1] = path
    end
  end

  add_dir(env.join(ctx.project_root, "Saved", "Logs"))
  if project_name ~= "" then
    local local_appdata = env.trim(vim.env.LOCALAPPDATA or "")
    if local_appdata ~= "" then
      add_dir(env.join(local_appdata, project_name, "Saved", "Logs"))
    end
  end
  add_dir(env.join(ctx.engine_root, "Engine", "Saved", "Logs"))

  local named_candidates = {}
  if project_name ~= "" then
    for _, dir in ipairs(dirs) do
      named_candidates[#named_candidates + 1] = env.join(dir, project_name .. ".log")
    end
  end
  for _, dir in ipairs(dirs) do
    named_candidates[#named_candidates + 1] = env.join(dir, "UE4.log")
    named_candidates[#named_candidates + 1] = env.join(dir, "UnrealEditor.log")
  end

  local existing = newest_existing_file(env, named_candidates)
  if existing then
    return existing, project_name
  end

  local newest = newest_log_in_dirs(env, dirs)
  if newest then
    return newest, project_name
  end

  if project_name ~= "" then
    return env.join(ctx.project_root, "Saved", "Logs", project_name .. ".log"), project_name
  end

  return nil, "No UE log file candidate found"
end

local function desktop_ue_log_spec(env, ctx)
  local path, detail = desktop_ue_log_path(env, ctx)
  if not path then
    return nil, detail
  end

  local host_driver = env.host_driver or require("utils.platform").driver()
  local plan, plan_err = host_driver.follow_file_plan(path)
  local cmd, command_err = require("ue.target_tasks").command(plan)
  if not cmd then
    return nil, plan_err or command_err
  end

  return {
    kind = "ue_log",
    source_id = env.norm(path),
    title = "UE Log",
    summary = host_driver.host_path(path),
    cmd = cmd,
    cwd = plan.cwd or env.dirname(path),
  }
end

local function desktop_debug_log_spec(env)
  local host_driver = env.host_driver or require("utils.platform").driver()
  if type(host_driver.debug_log_plan) ~= "function" then
    return nil, "Program debug log is unavailable on host: " .. tostring(host_driver.id)
  end
  local launch = require("utils.ue_launch")
  local spec, resolve_ctx = launch.resolve_spec(env)
  if not spec then
    return nil, resolve_ctx
  end

  local exe = env.trim(spec.exe or "")
  if exe == "" or not env.is_file(exe) then
    return nil, "Launch executable not found for current configuration"
  end

  local cmd_needle = ""
  if spec.kind == "Editor" and spec.args and spec.args[1] then
    cmd_needle = host_driver.host_path(spec.args[1]):lower()
  end
  local plan = host_driver.debug_log_plan({
    executable = exe,
    command_needle = cmd_needle,
    cwd = spec.cwd or env.dirname(exe),
  })
  local cmd, command_err = require("ue.target_tasks").command(plan)
  if not cmd then
    return nil, command_err
  end

  return {
    kind = "debug_log",
    source_id = host_driver.host_path(exe) .. "|" .. cmd_needle,
    title = "Program Debug Log",
    summary = host_driver.host_path(exe),
    cmd = cmd,
    cwd = plan.cwd or spec.cwd or env.dirname(exe),
  }
end

local function create_buffer(spec)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "log"
  vim.bo[buf].modifiable = true
  pcall(vim.api.nvim_buf_set_name, buf, ("ue://log/%s"):format(spec.kind))
  set_header(buf, spec)
  return buf
end

local function track_state(buf, win)
  state.buf = buf
  state.win = win

  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = buf,
    once = true,
    callback = function(args)
      if state.buf == args.buf then
        stop_job()
        state.buf = nil
        state.kind = nil
        state.source_id = nil
        state.title = nil
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    pattern = tostring(win),
    callback = function()
      if state.win == win then
        state.win = nil
      end
    end,
  })
end

local function start_stream(env, spec)
  reset_state()

  local win = ensure_window()
  local buf = create_buffer(spec)
  vim.api.nvim_win_set_buf(win, buf)
  track_state(buf, win)

  state.kind = spec.kind
  state.source_id = spec.source_id
  state.title = spec.title

  local stdout_pending = ""
  local stderr_pending = ""

  local function handle_chunks(chunks, is_stderr)
    local pending = is_stderr and stderr_pending or stdout_pending
    pending, chunks = normalize_chunks(env, pending, chunks)
    if is_stderr then
      stderr_pending = pending
    else
      stdout_pending = pending
    end

    if #chunks == 0 then
      return
    end

    vim.schedule(function()
      append_lines(buf, chunks)
    end)
  end

  local active_jobid
  active_jobid = vim.fn.jobstart(spec.cmd, {
    cwd = spec.cwd,
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = function(_, data)
      handle_chunks(data, false)
    end,
    on_stderr = function(_, data)
      handle_chunks(data, true)
    end,
    on_exit = function(_, code)
      local stopped = stop_requests[active_jobid] == true
      stop_requests[active_jobid] = nil

      vim.schedule(function()
        append_lines(buf, flush_pending(stdout_pending))
        append_lines(buf, flush_pending(stderr_pending))

        if state.jobid == active_jobid then
          state.jobid = nil
        end

        if vim.api.nvim_buf_is_valid(buf) then
          append_lines(buf, {
            "",
            ("[stream exited with code %d]"):format(code),
          })
        end

        if not stopped and code ~= 0 then
          vim.notify(("%s exited with code %d"):format(spec.title, code), vim.log.levels.WARN)
        end
      end)
    end,
  })

  if active_jobid <= 0 then
    reset_state()
    require("utils.log").notify_error("ue_logs", ("Failed to start %s (jobstart returned %s)"):format(spec.title, tostring(active_jobid)))
    return
  end

  state.jobid = active_jobid
  -- Register the log-stream job for :Tasks list/cancel. Pure side-path:
  -- register only, after job creation; on_exit above is untouched.
  pcall(function()
    require("utils.task_registry").register({
      name = spec.title or "log stream",
      group = "log",
      kind = "job",
      handle = active_jobid,
      started_at = os.time(),
    })
  end)
  vim.cmd("stopinsert")
end

local function toggle_spec(env, spec)
  prune_state()

  if state.kind == spec.kind and state.source_id == spec.source_id and job_running() then
    reset_state()
    return
  end

  start_stream(env, spec)
end

local LOG_STRATEGIES = {
  ["android-logcat"] = function(env, ctx, driver, host_driver)
    return require("ue.workflows").dispatch(driver.id, "log", {
      host_driver = host_driver,
      payload = {
        env = env,
        context = ctx,
        reinvoke = function() M.toggle_main_log(env) end,
      },
    })
  end,
  ["desktop-file"] = desktop_ue_log_spec,
  ["desktop-debug"] = desktop_debug_log_spec,
  unavailable = function(_, _, driver)
    return nil, driver.id .. " log mode is unavailable"
  end,
}

local function resolve_spec(env, mode)
  local ctx, err = env.resolve_context()
  if not ctx then
    return nil, err
  end

  local platform = env.target_platform(ctx.engine_root, nil)
  local host_driver = env.host_driver or require("utils.platform").driver()
  local operation = mode == "debug" and "debug_log" or "log"
  local policy_key = mode == "debug" and "debug_log" or "main_log"
  local driver, unavailable = require("ue.targets").resolve(platform, operation, host_driver)
  if not driver then
    return nil, unavailable.reason
  end
  local strategy = driver.runtime[policy_key].strategy
  local resolver = LOG_STRATEGIES[strategy]
  if not resolver then
    return nil, "Unknown log strategy: " .. tostring(strategy), strategy
  end
  return resolver(env, ctx, driver, host_driver)
end

function M.toggle_main_log(env)
  local spec, err = resolve_spec(env, "main")
  if not spec then
    if err then vim.notify(err, vim.log.levels.WARN) end
    return
  end
  toggle_spec(env, spec)
end

function M.toggle_debug_log(env)
  local spec, err = resolve_spec(env, "debug")
  if not spec then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  toggle_spec(env, spec)
end

function M._android_logcat_spec_for_test(env, ctx)
  return require("ue.workflows").invoke("Android", "log", "resolve", { env, ctx }, env.host_driver)
end

return M
