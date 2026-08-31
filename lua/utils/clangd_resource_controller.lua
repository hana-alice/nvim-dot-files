-- utils/clangd_resource_controller.lua — reversible priority for owned clangd.
--
-- Long-lived LSP services cannot use batch admission: killing/suspending clangd
-- discards preambles. This controller only switches OS priority class for PIDs
-- proven to be direct children of the current Neovim process.

local M = {}

local state = {
  pids = {},
  subscriber = nil,
  driver = nil,
  logged = {},
}

local function log_once(key, message, context)
  if state.logged[key] then return end
  state.logged[key] = true
  pcall(function()
    require("utils.log").warn_ctx("clangd.resources", message, context or {})
  end)
end

--- Pure mapping from shared host policy to reversible service priority.
function M.desired_priority(load, current, opts)
  local admission = require("utils.host_admission")
  opts = vim.tbl_extend("force", opts or admission.options(), {
    max_deferrals = math.huge,
    was_deferring = current == "low",
  })
  local allow = admission.admit(load, 0, opts)
  return allow and "normal" or "low"
end

local function unsubscribe_if_idle()
  if next(state.pids) ~= nil or not state.subscriber then return end
  pcall(function() require("utils.cpu_load").unsubscribe(state.subscriber) end)
  state.subscriber = nil
end

--- Apply one cached reading to every currently owned live PID.
function M.reconcile(reading, deps)
  deps = deps or {}
  local driver = deps.driver or state.driver or require("utils.platform").driver()
  if type(driver) ~= "table" or type(driver.set_process_priority) ~= "function" then
    log_once("unsupported", "clangd process priority is unsupported on this host", {
      host = type(driver) == "table" and driver.id or "unknown",
    })
    return false, "unsupported"
  end
  local options = vim.deepcopy(deps.options or require("utils.host_admission").options())
  if deps.foreground_active ~= nil then
    options.foreground_active = deps.foreground_active
  else
    options.foreground_active = require("utils.host_admission").foreground_active()
  end

  for pid, item in pairs(state.pids) do
    local process = item.native or pid
    local exists = true
    if type(driver.process_exists) == "function" then
      local ok, present = pcall(driver.process_exists, process)
      exists = ok and present == true
    end
    if not exists then
      if item.native and type(driver.close_process) == "function" then
        pcall(driver.close_process, item.native)
      end
      state.pids[pid] = nil
    else
      local desired = M.desired_priority(reading, item.priority, options)
      if desired ~= item.priority then
        local ok_call, changed, err = pcall(driver.set_process_priority, process, desired)
        if ok_call and changed == true then
          item.priority = desired
          item.changed_at = os.time()
        else
          log_once("priority:" .. tostring(pid) .. ":" .. tostring(err or changed),
            "failed to adjust owned clangd priority", {
              pid = pid,
              desired = desired,
              reason = tostring(err or changed),
            })
        end
      end
    end
  end
  unsubscribe_if_idle()
  return true
end

local function ensure_subscription()
  if state.subscriber then return end
  local cpu_load = require("utils.cpu_load")
  state.subscriber = cpu_load.subscribe(function(reading)
    M.reconcile(reading)
  end)
end

--- Register an already-proven owned PID.
function M.register(pid, deps)
  deps = deps or {}
  pid = tonumber(pid)
  if not pid or pid <= 0 then
    log_once("missing-pid", "clangd PID is unavailable; resource constraint skipped")
    return false, "pid-unavailable"
  end
  local driver = deps.driver or require("utils.platform").driver()
  if type(driver.set_process_priority) ~= "function" then
    log_once("unsupported", "clangd process priority is unsupported on this host", { host = driver.id })
    if deps.native and type(driver.close_process) == "function" then pcall(driver.close_process, deps.native) end
    return false, "unsupported"
  end
  if type(driver.process_exists) == "function" then
    local ok, exists = pcall(driver.process_exists, deps.native or pid)
    if not ok or exists ~= true then
      if deps.native and type(driver.close_process) == "function" then pcall(driver.close_process, deps.native) end
      return false, "process-unavailable"
    end
  end

  state.driver = driver
  state.pids[pid] = state.pids[pid] or {
    pid = pid,
    priority = "normal",
    registered_at = os.time(),
    parent_pid = tonumber(deps.parent_pid),
    executable_name = deps.executable_name,
    native = deps.native,
  }
  ensure_subscription()
  M.reconcile(deps.reading or require("utils.cpu_load").reading(), {
    driver = driver,
    options = deps.options,
    foreground_active = deps.foreground_active,
  })
  return true
end

--- Discover clangd processes that are direct children of this Neovim only.
function M.discover(executable, deps)
  deps = deps or {}
  local driver = deps.driver or require("utils.platform").driver()
  if type(driver.child_processes) ~= "function" then
    log_once("discovery-unsupported", "cannot discover owned clangd PID on this host", { host = driver.id })
    return 0, "unsupported"
  end
  local name = tostring(executable or ""):match("([^/\\]+)$")
  if not name or name == "" then return 0, "executable-unavailable" end
  local parent_pid = tonumber(deps.parent_pid) or vim.fn.getpid()
  local ok, children, err = pcall(driver.child_processes, parent_pid, name)
  if not ok or type(children) ~= "table" then
    log_once("discovery:" .. tostring(err or children), "clangd PID discovery failed", {
      reason = tostring(err or children),
    })
    return 0, tostring(err or children)
  end

  if #children == 0 then
    if not deps.silent_no_match then
      log_once("no-child:" .. tostring(parent_pid) .. ":" .. name:lower(),
        "no owned clangd child matched PID discovery", {
          parent_pid = parent_pid,
          executable = name,
        })
    end
    return 0, "no-matching-child"
  end

  local added = 0
  for _, child in ipairs(children) do
    local pid = tonumber(type(child) == "table" and child.pid or child)
    if pid and not state.pids[pid] then
      local registered = M.register(pid, {
        driver = driver,
        reading = deps.reading,
        options = deps.options,
        foreground_active = deps.foreground_active,
        parent_pid = parent_pid,
        executable_name = name,
        native = type(child) == "table" and child.native or nil,
      })
      if registered then added = added + 1 end
    elseif pid and type(child) == "table" and child.native
        and type(driver.close_process) == "function" then
      pcall(driver.close_process, child.native)
    end
  end
  return added, added == 0 and "already-registered" or nil
end

--- Bounded startup discovery: no permanent poller, but no one-shot race either.
function M.discover_with_retry(executable, deps)
  deps = deps or {}
  local delays = deps.delays or { 0, 100, 500 }
  local control = { attempts = 0, registered = 0, done = false, reason = nil }
  local schedule = deps.schedule or vim.schedule
  local defer_fn = deps.defer_fn or vim.defer_fn
  local attempt
  attempt = function()
    if control.done then return end
    control.attempts = control.attempts + 1
    local last = control.attempts >= #delays
    local discover_deps = vim.tbl_extend("force", deps, { silent_no_match = not last })
    discover_deps.delays, discover_deps.schedule, discover_deps.defer_fn = nil, nil, nil
    local added, reason = M.discover(executable, discover_deps)
    control.registered = control.registered + added
    control.reason = reason
    if added > 0 or reason == "already-registered" or last then control.done = true; return end
    defer_fn(attempt, delays[control.attempts + 1])
  end
  if (delays[1] or 0) <= 0 then schedule(attempt) else defer_fn(attempt, delays[1]) end
  return control
end

function M.status()
  local items = {}
  for _, item in pairs(state.pids) do
    items[#items + 1] = {
      pid = item.pid,
      priority = item.priority,
      registered_at = item.registered_at,
      changed_at = item.changed_at,
      parent_pid = item.parent_pid,
      executable_name = item.executable_name,
      native_handle = item.native ~= nil,
    }
  end
  table.sort(items, function(a, b) return a.pid < b.pid end)
  return { count = #items, subscribed = state.subscriber ~= nil, items = items }
end

function M._reset_for_test()
  if state.subscriber then pcall(function() require("utils.cpu_load").unsubscribe(state.subscriber) end) end
  for _, item in pairs(state.pids) do
    if item.native and state.driver and type(state.driver.close_process) == "function" then
      pcall(state.driver.close_process, item.native)
    end
  end
  state = { pids = {}, subscriber = nil, driver = nil, logged = {} }
end

return M
