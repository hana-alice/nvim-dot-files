-- WORKAROUND
-- name: codediff.threaded_git
-- scope: codediff
-- issue: internal: Windows Git process creation blocks the editor even through vim.system
-- symptom: Opening or refreshing review stalls the UI inside process creation
-- introduced: 2026-09-29
-- removal_condition: upstream runs Git process creation outside the editor event loop
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local queue, running = {}, {}
local active = 0
local installed = false
local previous_preload, previous_apply
local metrics = { submitted = 0, spawned = 0, completed = 0, spawn_ms = 0, elapsed_ms = 0 }
local history = {}
local close_group
local exiting = false
local runner_name = "codediff.core.git.runner"
local uv = vim.uv

-- No upvalues: luv executes this function in an independent Lua state.
local function worker(encoded, channel)
  local uv = vim.uv
  local spec = vim.mpack.decode(encoded)
  local out, errout = {}, {}
  local output_bytes = 0
  local stdout, stderr = uv.new_pipe(false), uv.new_pipe(false)
  local input = spec.stdin ~= nil and uv.new_pipe(false) or nil
  local timer = uv.new_timer()
  local process, code, signal, failure, cancelled
  local started = uv.hrtime()
  local function close(handle)
    if handle and not handle:is_closing() then handle:close() end
  end
  local function stop(reason)
    failure = failure or reason
    cancelled = reason == "Git operation cancelled" or cancelled
    -- Exit can arrive before the final pipe data/error. Preserve a drain
    -- failure even when there is no longer a process to terminate.
    if code ~= nil then return end
    close(input)
    if process and not process:is_closing() then process:kill("sigkill") end
  end
  if uv.fs_stat(spec.cancel_path) then
    close(stdout); close(stderr); close(input); close(timer)
    uv.run()
    return 130, 0, "", "Git operation cancelled", true, 0, -1, 0
  end
  local pid
  local spawn_start = uv.hrtime()
  process, pid = uv.spawn(spec.executable, {
    args = spec.args, cwd = spec.cwd, stdio = { input, stdout, stderr }, hide = true,
  }, function(exit_code, exit_signal)
    code, signal = exit_code, exit_signal
    close(process); close(input); close(timer)
  end)
  local spawn_ms = (uv.hrtime() - spawn_start) / 1e6
  if not process then
    close(stdout); close(stderr); close(input); close(timer)
    uv.run()
    return -1, 0, "", "Failed to spawn Git: " .. tostring(pid), false, 0, -1, 0
  end
  -- Only primitive values cross back; reverse-transferring a worker-owned
  -- async handle is not supported reliably by this luv build.
  channel:send(pid)
  local function reader(parts, pipe)
    return function(read_error, bytes)
      if read_error then stop(tostring(read_error)) end
      if not bytes then close(pipe); return end
      output_bytes = output_bytes + #bytes
      if output_bytes > 64 * 1024 * 1024 then stop("Git output exceeds 64 MiB"); return end
      parts[#parts + 1] = bytes
    end
  end
  stdout:read_start(reader(out, stdout))
  stderr:read_start(reader(errout, stderr))
  if type(spec.stdin) == "string" then
    input:write(spec.stdin, function(write_error)
      if write_error then stop(tostring(write_error)); return end
      if not input:is_closing() then input:shutdown(function() close(input) end) end
    end)
  end
  -- A private marker avoids passing an unsafe cross-thread handle or killing
  -- a reused PID. Only this worker can signal the process it actually owns.
  timer:start(0, 50, function()
    if uv.fs_stat(spec.cancel_path) then stop("Git operation cancelled")
    elseif (uv.hrtime() - started) / 1e6 >= spec.timeout then stop("Git operation timed out") end
  end)
  uv.run()
  local error_text = failure or table.concat(errout)
  return failure and (cancelled and 130 or 124) or (code or -1), signal or 0,
    table.concat(out), error_text, cancelled or false, (uv.hrtime() - started) / 1e6, spawn_ms, pid
end

local executable
local function git_executable()
  if executable then return executable end
  local resolved = require("utils.platform").resolve_tool({ name = "git", driver_candidates = function(driver)
    return type(driver.git_binary_candidates) == "function" and driver.git_binary_candidates() or { "git" }
  end })
  if not resolved.ok then return "git" end
  executable = resolved.path
  return executable
end

local pump
local function finish(task, result)
  if task.done then return end
  task.done = true
  running[task] = nil
  if task.started then active = active - 1 end
  if not task.started then
    for i = #queue, 1, -1 do if queue[i] == task then table.remove(queue, i) end end
  end
  if task.channel and not task.channel:is_closing() then task.channel:close() end
  uv.fs_unlink(task.cancel_path)
  if task.text then
    result.stdout = result.stdout:gsub("\r\n", "\n")
    result.stderr = result.stderr:gsub("\r\n", "\n")
  end
  metrics.completed = metrics.completed + 1
  if result.spawn_ms and result.spawn_ms >= 0 then
    metrics.spawned = metrics.spawned + 1
    metrics.spawn_ms = metrics.spawn_ms + result.spawn_ms
    metrics.elapsed_ms = metrics.elapsed_ms + result.elapsed_ms
  end
  history[#history + 1] = { args = task.args, cwd = task.cwd, pid = result.pid or task.pid,
    code = result.code, spawn_ms = result.spawn_ms, elapsed_ms = result.elapsed_ms }
  if #history > 128 then table.remove(history, 1) end
  pump()
  if not exiting then task.callback(result) end
end

pump = function()
  if exiting then return end
  while active < 2 and #queue > 0 do
    local task = table.remove(queue, 1)
    if not task.done then
      active = active + 1
      task.started = true
      running[task] = true
      task.channel = uv.new_async(vim.schedule_wrap(function(pid) task.pid = pid end))
      task.work = uv.new_work(worker, vim.schedule_wrap(function(code, signal, stdout, stderr, cancelled, elapsed, spawn_ms, pid)
        finish(task, { code = code, signal = signal, stdout = stdout, stderr = stderr, cancelled = cancelled, elapsed_ms = elapsed, spawn_ms = spawn_ms, pid = pid })
      end))
      local ok, err = pcall(task.work.queue, task.work, task.encoded, task.channel)
      if not ok then
        finish(task, { code = -1, signal = 0, stdout = "", stderr = tostring(err) })
      end
    end
  end
end

-- The result protocol mirrors vim.system, but this is strictly CodeDiff-local.
-- stdin=true keeps stdin open for a cancellable batch command; no shell runs.
function M.system(args, opts, callback)
  if exiting then return nil end
  opts = opts or {}
  local task = { callback = callback, text = opts.text ~= false, cancel_path = vim.fn.tempname() .. ".git-cancel", args = vim.deepcopy(args), cwd = opts.cwd }
  function task:is_closing() return self.done == true end
  function task:kill()
    if self.done then return false end
    if not self.started then
      finish(self, { code = 130, signal = 0, stdout = "", stderr = "Git operation cancelled", cancelled = true })
      return true
    end
    local fd, err = uv.fs_open(self.cancel_path, "w", 384)
    if not fd then return nil, err end
    uv.fs_close(fd)
    return true
  end
  task.encoded = vim.mpack.encode({ executable = opts.executable or git_executable(), args = args,
    cwd = opts.cwd, stdin = opts.stdin, timeout = opts.timeout or 30000, cancel_path = task.cancel_path })
  queue[#queue + 1] = task
  metrics.submitted = metrics.submitted + 1
  pcall(require("utils.task_registry").register, { name = "CodeDiff Git " .. tostring(args[1] or "query"), group = "git-review", kind = "system", handle = task })
  pump()
  return task
end

function M.run_async(args, opts, callback)
  opts = opts or {}
  local argv = vim.deepcopy(args)
  if opts.no_optional_locks then table.insert(argv, 1, "--no-optional-locks") end
  return M.system(argv, opts, function(result)
    if result.code == 0 then callback(nil, result.stdout)
    else callback(result.stderr ~= "" and result.stderr or "Git command failed (" .. result.code .. ")", nil) end
  end)
end

function M.apply_patch(root, patch, opts, callback)
  if type(opts) == "boolean" then opts = { cached = true, reverse = opts } end
  opts = opts or {}
  local args = { "apply", "--unidiff-zero", "-" }
  if opts.cached ~= false then table.insert(args, 2, "--cached") end
  if opts.reverse then table.insert(args, 2, "--reverse") end
  return M.system(args, { cwd = root, stdin = patch, text = false }, function(result)
    callback(result.code ~= 0 and (result.stderr ~= "" and result.stderr or "git apply failed") or nil)
  end)
end

function M.apply()
  if installed then return true end
  if package.loaded[runner_name] then return false, "Install threaded_git before loading CodeDiff Git modules" end
  if not uv.new_work then return false, "This Neovim lacks libuv worker support" end
  previous_preload = package.preload[runner_name]
  package.preload[runner_name] = function()
    return { run_async = M.run_async, run_sync = function(args)
      local result = vim.fn.systemlist(vim.list_extend({ git_executable() }, args))
      return vim.v.shell_error == 0 and result or nil
    end }
  end
  installed = true
  return true
end

local function tasks_for_root(root)
  local function canonical(path)
    if not path then return nil end
    local normalized = vim.fs.normalize(uv.fs_realpath(path) or path)
    return require("utils.platform").driver().path_key(normalized)
  end
  local key, owned = canonical(root), {}
  for task in pairs(running) do if canonical(task.cwd) == key then owned[#owned + 1] = task end end
  for _, task in ipairs(queue) do if canonical(task.cwd) == key then owned[#owned + 1] = task end end
  return owned
end

-- Call after CodeDiff is loaded and before safe_mutations captures apply_patch.
function M.attach()
  local git = require("codediff.core.git")
  if git.apply_patch == M.apply_patch then return end
  previous_apply = git.apply_patch
  git.apply_patch = M.apply_patch
  close_group = vim.api.nvim_create_augroup("CodeDiffThreadedGit", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = close_group, pattern = "CodeDiffClose", callback = function(event)
    local lifecycle = require("codediff.ui.lifecycle")
    local tab = event.data and event.data.tabpage
    local session = tab and lifecycle.get_session(tab)
    local root = session and session.git_root
    if not root then return end
    -- Capture ownership now. A subsequent open may start a new status query
    -- before its session exists; the deferred close must not cancel that work.
    local closing_tasks = tasks_for_root(root)
    vim.schedule(function()
      for _, other in ipairs(vim.api.nvim_list_tabpages()) do
        local remaining = lifecycle.get_session(other)
        if remaining and remaining.git_root == root then return end
      end
      for _, task in ipairs(closing_tasks) do task:kill() end
    end)
  end })
  vim.api.nvim_create_autocmd("VimLeavePre", { group = close_group, callback = function()
    exiting = true
    M.cancel_all()
    -- libuv work must finish before Neovim tears down its Lua state. This is
    -- exit-only draining; normal editor work never waits for a process.
    vim.wait(5000, function() return active == 0 end, 10)
  end })
end

function M.cancel_all()
  local owned = {}
  for task in pairs(running) do owned[#owned + 1] = task end
  for _, task in ipairs(queue) do owned[#owned + 1] = task end
  for _, task in ipairs(owned) do task:kill() end
end

function M.cancel_root(root)
  local owned = tasks_for_root(root)
  for _, task in ipairs(owned) do task:kill() end
  return #owned
end

function M.status()
  return { applied = installed, active = active, queued = #queue, executable = executable,
    submitted = metrics.submitted, spawned = metrics.spawned, completed = metrics.completed,
    spawn_ms = metrics.spawn_ms, elapsed_ms = metrics.elapsed_ms }
end

function M.jobs() return vim.deepcopy(history) end

function M.disable()
  M.cancel_all()
  package.preload[runner_name] = previous_preload
  local git = package.loaded["codediff.core.git"]
  if git and git.apply_patch == M.apply_patch then git.apply_patch = previous_apply end
  if close_group then vim.api.nvim_del_augroup_by_id(close_group); close_group = nil end
  installed = false
  -- Captured runner closures require a restart to revert completely.
end

M._worker_for_test = worker

return M
