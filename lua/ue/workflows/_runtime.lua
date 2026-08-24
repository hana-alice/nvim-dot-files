local M = {}

local PROXY_RAW = setmetatable({}, { __mode = "k" })
local RAW_PROXY = setmetatable({}, { __mode = "k" })

local function trim(value)
  return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function deepcopy(value, seen)
  if type(value) ~= "table" then
    return value
  end
  seen = seen or {}
  if seen[value] then
    return seen[value]
  end
  local out = {}
  seen[value] = out
  for key, item in pairs(value) do
    out[deepcopy(key, seen)] = deepcopy(item, seen)
  end
  return out
end

local function immutable(value)
  if type(value) ~= "table" then
    return value
  end
  if RAW_PROXY[value] then
    return RAW_PROXY[value]
  end

  local proxy = {}
  RAW_PROXY[value] = proxy
  PROXY_RAW[proxy] = value

  return setmetatable(proxy, {
    __index = function(_, key)
      return immutable(value[key])
    end,
    __newindex = function()
      error("workflow snapshot is immutable", 2)
    end,
    __pairs = function()
      local function iterator(_, previous)
        local next_key, next_value = next(value, previous)
        if next_key == nil then
          return nil
        end
        return next_key, immutable(next_value)
      end
      return iterator, proxy, nil
    end,
    __len = function()
      return #value
    end,
    __metatable = "workflow_snapshot",
  })
end

local function raw_snapshot(snapshot)
  return PROXY_RAW[snapshot] or snapshot
end

local function project_key(snapshot)
  local raw = raw_snapshot(snapshot)
  if type(raw) ~= "table" then
    return ""
  end
  local project = raw.project
  if type(project) ~= "table" then
    return ""
  end
  return trim(project.canonical or project.path or project.id)
end

local function default_runner()
  local tasks = require("ue.target_tasks")
  return {
    run = tasks.run,
    progress = tasks.progress,
    error_message = tasks.error_message,
  }
end

local function progress_level(status)
  if status == "success" then
    return vim.log.levels.INFO
  end
  if status == "cancelled" then
    return vim.log.levels.WARN
  end
  return vim.log.levels.ERROR
end

local function safe_call(fn, ...)
  if type(fn) ~= "function" then
    return true, nil
  end
  return pcall(fn, ...)
end

local Session = {}
Session.__index = Session

function Session:_persist(event, payload)
  local persist = self.state and self.state.persist
  if type(persist) ~= "function" then
    return
  end
  persist(event, self.snapshot, deepcopy(payload or {}), self)
end

function Session:_project_changed()
  if type(self.project_guard) == "function" then
    local ok, allowed = pcall(self.project_guard, self.snapshot, self.state, self)
    return not ok or allowed == false
  end

  local current_project = self.state and self.state.current_project
  if type(current_project) ~= "function" then
    return false
  end

  local active = trim(current_project(self.snapshot, self))
  if active == "" then
    return false
  end
  return active ~= project_key(self.snapshot)
end

function Session:_cleanup(reason, result)
  local active = self.active_task
  if active and type(active.cleanup) == "function" then
    safe_call(active.cleanup, self.snapshot, reason, result, self)
  end
  if type(self.spec.cleanup) == "function" then
    safe_call(self.spec.cleanup, self.snapshot, reason, result, self)
  end
end

function Session:_finish(status, message, result, extra)
  if self.done then
    return {
      status = self.status,
      message = self.message,
      result = self.result,
    }
  end

  self.done = true
  self.status = status
  self.message = message
  self.result = result

  if self.progress then
    self.progress:finish(message or self.finish_message or "done", 100, progress_level(status))
  end

  self:_persist(status == "success" and "completed" or status, {
    task = self.active_task and self.active_task.id or nil,
    message = message,
    result = result,
    extra = deepcopy(extra or {}),
  })

  if status ~= "success" then
    self:_cleanup(extra and extra.reason or status, result)
  end

  local callback =
    self.spec[status == "success" and "on_success" or (status == "cancelled" and "on_cancel" or "on_failure")]
  safe_call(callback, self.snapshot, result, self, deepcopy(extra or {}))
  safe_call(self.spec.on_finish, {
    status = status,
    message = message,
    result = result,
    snapshot = self.snapshot,
    task = self.active_task and self.active_task.id or nil,
    extra = deepcopy(extra or {}),
  })

  return {
    status = status,
    message = message,
    result = result,
  }
end

function Session:_step_message(task)
  local message = trim(task.message)
  if message ~= "" then
    return message
  end
  return trim(task.id) ~= "" and task.id or "running"
end

function Session:_run_next(index)
  if self.done then
    return
  end
  if index > #self.tasks then
    return self:_finish("success", self.success_message or "workflow complete", nil, { reason = "completed" })
  end
  if self:_project_changed() then
    self:_persist("project_changed", {
      task = self.tasks[index] and self.tasks[index].id or nil,
    })
    return self:_finish("failed", self.project_change_message, nil, { reason = "project-changed" })
  end

  local task = self.tasks[index]
  self.active_task = task
  self.active_index = index
  self.progress:report(self:_step_message(task), task.percentage)
  self:_persist("task_started", { task = task.id, plan = deepcopy(task.plan) })
  safe_call(task.on_start, self.snapshot, self)

  local handle, err = self.runner.run(task.plan, {
    name = task.name or task.id,
    group = task.group or self.group,
    env = task.env,
    on_stdout = task.on_stdout,
    on_stderr = task.on_stderr,
    on_exit = function(result)
      if self.done then
        return
      end
      if self:_project_changed() then
        self:_persist("project_changed", { task = task.id })
        return self:_finish("failed", self.project_change_message, result, { reason = "project-changed" })
      end
      if tonumber(result.code or 0) ~= 0 then
        local message = self.runner.error_message and self.runner.error_message(result) or "workflow task failed"
        self:_persist("task_failed", {
          task = task.id,
          result = result,
          message = message,
        })
        safe_call(task.on_failure, self.snapshot, result, self)
        return self:_finish("failed", message, result, { reason = "task-failed" })
      end

      self:_persist("task_succeeded", { task = task.id, result = result })
      safe_call(task.on_success, self.snapshot, result, self)
      self:_run_next(index + 1)
    end,
  })

  if not handle then
    self:_persist("task_start_failed", {
      task = task.id,
      message = err,
    })
    safe_call(task.on_start_failure, self.snapshot, err, self)
    return self:_finish("failed", err, nil, { reason = "task-start-failed" })
  end

  self.active_handle = handle
end

function Session:cancel(reason)
  if self.done then
    return false
  end
  reason = trim(reason) ~= "" and trim(reason) or "cancelled"

  local handle = self.active_handle
  if handle and type(handle.kill) == "function" then
    pcall(handle.kill, handle, 15)
  elseif handle and type(handle.terminate) == "function" then
    pcall(handle.terminate, handle)
  end

  self:_persist("cancel_requested", {
    task = self.active_task and self.active_task.id or nil,
    reason = reason,
  })
  self:_finish("cancelled", self.cancel_message, nil, { reason = reason })
  return true
end

function Session:poll(payload)
  if self.done or type(self.spec.poller) ~= "function" then
    return nil
  end
  if self:_project_changed() then
    self:_persist("project_changed", {
      task = self.active_task and self.active_task.id or nil,
      stage = "poll",
    })
    self:_finish("failed", self.project_change_message, nil, { reason = "project-changed" })
    return nil
  end
  local ok, result = pcall(self.spec.poller, self.snapshot, payload, self)
  if not ok then
    self:_persist("poll_failed", {
      task = self.active_task and self.active_task.id or nil,
      message = result,
    })
    self:_finish("failed", tostring(result), nil, { reason = "poll-failed" })
    return nil
  end
  return result
end

function Session:get_snapshot()
  return self.snapshot
end

function M.snapshot(spec)
  assert(type(spec) == "table", "workflow snapshot spec must be a table")

  local raw = deepcopy(spec)
  raw.operation = trim(raw.operation)
  raw.owner = trim(raw.owner)

  if type(raw.project) ~= "table" then
    raw.project = { canonical = trim(raw.project) }
  else
    raw.project.canonical = trim(raw.project.canonical or raw.project.path or raw.project.id)
  end
  if type(raw.target) ~= "table" then
    raw.target = { id = trim(raw.target or raw.target_id or raw.platform) }
  else
    raw.target.id = trim(raw.target.id or raw.target.platform or raw.target.name)
  end
  raw.configuration = trim(raw.configuration or (raw.context and raw.context.configuration))
  raw.host = type(raw.host) == "table" and raw.host or { id = trim(raw.host_id) }
  raw.device = type(raw.device) == "table" and raw.device or {}
  raw.signing = type(raw.signing) == "table" and raw.signing or {}
  raw.runtime = type(raw.runtime) == "table" and raw.runtime or {}
  raw.context = type(raw.context) == "table" and raw.context or {}

  return immutable(raw)
end

function M.unwrap(snapshot)
  return deepcopy(raw_snapshot(snapshot))
end

function M.start(spec)
  assert(type(spec) == "table", "workflow runtime spec must be a table")
  local tasks = spec.tasks or {}
  assert(type(tasks) == "table" and #tasks > 0, "workflow runtime requires at least one task")

  local runner = spec.runner or default_runner()
  assert(type(runner.run) == "function", "workflow runner must expose run(plan, opts)")

  local session = setmetatable({
    spec = spec,
    snapshot = spec.snapshot,
    runner = runner,
    tasks = deepcopy(tasks),
    state = spec.state or {},
    group = trim(spec.group) ~= "" and trim(spec.group) or "ue",
    finish_message = trim(spec.finish_message) ~= "" and trim(spec.finish_message) or "workflow complete",
    success_message = trim(spec.success_message) ~= "" and trim(spec.success_message) or "workflow complete",
    cancel_message = trim(spec.cancel_message) ~= "" and trim(spec.cancel_message) or "workflow cancelled",
    project_change_message = trim(spec.project_change_message) ~= "" and trim(spec.project_change_message)
      or "workflow aborted because the active project changed",
    project_guard = spec.project_guard,
    progress = (spec.progress_factory or runner.progress)({
      title = spec.title or "UE",
      scope = spec.scope or "ue.workflow",
      message = spec.start_message or "starting",
      percentage = spec.start_percentage,
      replace = spec.replace,
    }),
  }, Session)

  session:_persist("started", {
    owner = raw_snapshot(spec.snapshot).owner,
    operation = raw_snapshot(spec.snapshot).operation,
  })
  session:_run_next(1)
  return session
end

return M
