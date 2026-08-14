local M = {}

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

function M.run(plan, opts)
  opts = opts or {}
  local command, err = M.command(plan)
  if not command then
    return nil, err
  end

  local ok, handle = pcall(vim.system, command, {
    cwd = plan.cwd,
    text = true,
    env = opts.env,
  }, function(result)
    vim.schedule(function()
      if type(opts.on_exit) == "function" then
        opts.on_exit({
          code = result.code,
          signal = result.signal,
          stdout = result.stdout or "",
          stderr = result.stderr or "",
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
