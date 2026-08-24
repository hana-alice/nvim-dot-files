local M = {}

local progress_sequence = 0

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function plan_error(plan)
  if type(plan) ~= "table" then
    return "target plan must be a table"
  end
  if plan.status == "unavailable" or plan.ok == false then
    return trim(plan.reason) ~= "" and trim(plan.reason) or "target operation is unavailable"
  end
  if trim(plan.executable) == "" then
    return "target plan executable is missing"
  end
  if plan.args ~= nil and type(plan.args) ~= "table" then
    return "target plan args must be a list"
  end
  return nil
end

function M.command(plan)
  local err = plan_error(plan)
  if err then
    return nil, err
  end

  local command = { tostring(plan.executable) }
  for index, value in ipairs(plan.args or {}) do
    value = tostring(value or "")
    if value == "" then
      return nil, ("target plan args[%d] is empty"):format(index)
    end
    command[#command + 1] = value
  end
  return command
end

function M.progress(opts)
  opts = opts or {}
  local title = trim(opts.title) ~= "" and trim(opts.title) or "UE"
  local scope = trim(opts.scope) ~= "" and trim(opts.scope) or "ue.target"
  local message = trim(opts.message) ~= "" and trim(opts.message) or "starting"
  local percentage = tonumber(opts.percentage)
  local done = false
  local fidget_handle
  local function record_history(next_message, level)
    pcall(function()
      require("utils.notification_history").record({
        scope = scope,
        title = title,
        message = next_message,
        level = level or vim.log.levels.INFO,
      })
    end)
  end
  local ok, fidget = pcall(require, "fidget.progress")
  if ok and fidget and fidget.handle and type(fidget.handle.create) == "function" then
    local created, handle = pcall(fidget.handle.create, {
      title = title,
      message = message,
      lsp_client = { name = "ue" },
      percentage = percentage,
    })
    if created then fidget_handle = handle end
  end

  progress_sequence = progress_sequence + 1
  local replace = opts.replace or ("ue.target.progress.%d"):format(progress_sequence)
  if not fidget_handle then
    vim.notify(message, vim.log.levels.INFO, { title = title, replace = replace })
  end
  record_history(message, vim.log.levels.INFO)

  local controller = {}
  function controller:report(next_message, next_percentage)
    if done then return end
    next_message = trim(next_message) ~= "" and trim(next_message) or message
    next_percentage = tonumber(next_percentage)
    message = next_message
    if next_percentage then percentage = next_percentage end
    if fidget_handle then
      pcall(fidget_handle.report, fidget_handle, {
        message = message,
        percentage = percentage,
      })
    else
      vim.notify(message, vim.log.levels.INFO, { title = title, replace = replace })
    end
  end

  function controller:finish(final_message, final_percentage, level)
    if done then return end
    self:report(final_message or message, final_percentage)
    done = true
    record_history(final_message or message, level)
    if fidget_handle then
      pcall(fidget_handle.finish, fidget_handle)
    else
      vim.notify(final_message or message, level or vim.log.levels.INFO, {
        title = title,
        replace = replace,
      })
    end
  end

  return controller
end

function M.run(plan, opts)
  opts = opts or {}
  local command, err = M.command(plan)
  if not command then
    return nil, err
  end

  local stdout_chunks = {}
  local stderr_chunks = {}
  local function stream(chunks, callback)
    return function(_, data)
      if type(data) ~= "string" or data == "" then return end
      chunks[#chunks + 1] = data
      vim.schedule(function()
        callback(data)
      end)
    end
  end
  local system_opts = {
    cwd = plan.cwd,
    text = true,
    env = opts.env,
  }
  if type(opts.on_stdout) == "function" then
    system_opts.stdout = stream(stdout_chunks, opts.on_stdout)
  end
  if type(opts.on_stderr) == "function" then
    system_opts.stderr = stream(stderr_chunks, opts.on_stderr)
  end

  local ok, handle = pcall(vim.system, command, system_opts, function(result)
    vim.schedule(function()
      if type(opts.on_exit) == "function" then
        opts.on_exit({
          code = result.code,
          signal = result.signal,
          stdout = system_opts.stdout and table.concat(stdout_chunks) or result.stdout or "",
          stderr = system_opts.stderr and table.concat(stderr_chunks) or result.stderr or "",
          plan = plan,
        })
      end
    end)
  end)
  if not ok then
    return nil, tostring(handle)
  end

  pcall(function()
    require("utils.task_registry").register({
      name = opts.name or ("UE " .. tostring(plan.metadata and plan.metadata.platform or "target")),
      group = opts.group or "ue",
      kind = "system",
      handle = handle,
      started_at = os.time(),
    })
  end)

  return handle
end

function M.error_message(result)
  if type(result) ~= "table" then
    return tostring(result or "target task failed")
  end
  local stderr = trim(result.stderr)
  local stdout = trim(result.stdout)
  local detail = stderr ~= "" and stderr or stdout
  if detail == "" then
    detail = "no output captured"
  end
  return ("exit=%s: %s"):format(tostring(result.code or -1), detail)
end

return M
