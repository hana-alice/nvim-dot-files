-- Lightweight build-process heartbeat rendered inside the existing UE terminal.
--
-- Host process discovery is supplied by utils.platform; this module only owns
-- process-tree interpretation, async polling, and terminal-buffer decoration.

local M = {}

local namespace = vim.api.nvim_create_namespace("ue_build_monitor")
local active_by_buffer = {}

local SOURCE_EXTENSIONS = {
  [".a"] = true,
  [".app"] = true,
  [".c"] = true,
  [".cc"] = true,
  [".cpp"] = true,
  [".cxx"] = true,
  [".dll"] = true,
  [".dylib"] = true,
  [".framework"] = true,
  [".h"] = true,
  [".hpp"] = true,
  [".ipa"] = true,
  [".json"] = true,
  [".m"] = true,
  [".mm"] = true,
  [".o"] = true,
  [".rsp"] = true,
  [".s"] = true,
}

local function basename(path)
  path = tostring(path or ""):gsub("[/\\]+$", "")
  return path:match("([^/\\]+)$") or path
end

local function strip_token(token)
  token = tostring(token or "")
  token = token:gsub([[^[%(%[%{%"']+]], "")
  token = token:gsub([[[%)%]%}%"',;:]+$]], "")
  local value = token:match("^[^=]+=([^=]+)$")
  return value or token
end

local function command_tool(command)
  local executable = tostring(command or ""):match("^%s*([^%s]+)") or "process"
  return basename(strip_token(executable))
end

local function command_item(command)
  local found
  for token in tostring(command or ""):gmatch("%S+") do
    local candidate = strip_token(token)
    local lower = candidate:lower()
    for extension in pairs(SOURCE_EXTENSIONS) do
      if lower:sub(-#extension) == extension then
        found = basename(candidate)
        break
      end
    end
  end
  return found
end

---Parse `ps -Ao pid,ppid,state,etime,%cpu,%mem,command` output.
---@param output string
---@return table[]
function M.parse_snapshot(output)
  local rows = {}
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    local pid, ppid, state, elapsed, cpu, memory, command =
      line:match("^%s*(%d+)%s+(%d+)%s+(%S+)%s+(%S+)%s+([%d%.]+)%s+([%d%.]+)%s+(.+)$")
    if pid then
      rows[#rows + 1] = {
        pid = tonumber(pid),
        ppid = tonumber(ppid),
        state = state,
        elapsed = elapsed,
        cpu = tonumber(cpu) or 0,
        memory = tonumber(memory) or 0,
        command = command,
      }
    end
  end
  return rows
end

local function build_descendants(rows, root_pid)
  local by_parent = {}
  local by_pid = {}
  for _, row in ipairs(rows or {}) do
    by_pid[row.pid] = row
    by_parent[row.ppid] = by_parent[row.ppid] or {}
    by_parent[row.ppid][#by_parent[row.ppid] + 1] = row
  end

  local descendants = {}
  local queue = { { pid = tonumber(root_pid), depth = 0 } }
  local seen = {}
  local cursor = 1
  while cursor <= #queue do
    local entry = queue[cursor]
    cursor = cursor + 1
    if entry.pid and not seen[entry.pid] then
      seen[entry.pid] = true
      local row = by_pid[entry.pid]
      if row then
        row = vim.tbl_extend("force", {}, row, { depth = entry.depth })
        descendants[#descendants + 1] = row
      end
      for _, child in ipairs(by_parent[entry.pid] or {}) do
        queue[#queue + 1] = { pid = child.pid, depth = entry.depth + 1 }
      end
    end
  end
  return descendants
end

---Summarize the process subtree rooted at the terminal job PID.
---@param rows table[]
---@param root_pid integer
---@return table
function M.summarize(rows, root_pid)
  local descendants = build_descendants(rows, root_pid)
  local total_cpu = 0
  for _, row in ipairs(descendants) do
    total_cpu = total_cpu + row.cpu
  end
  table.sort(descendants, function(left, right)
    if left.cpu ~= right.cpu then
      return left.cpu > right.cpu
    end
    if left.depth ~= right.depth then
      return left.depth > right.depth
    end
    return left.pid > right.pid
  end)

  local active = descendants[1]
  if active then
    active = vim.tbl_extend("force", {}, active, {
      tool = command_tool(active.command),
      item = command_item(active.command),
    })
  end
  return {
    active = active,
    process_count = #descendants,
    total_cpu = total_cpu,
  }
end

local function format_duration(seconds)
  seconds = math.max(0, math.floor(tonumber(seconds) or 0))
  local hours = math.floor(seconds / 3600)
  local minutes = math.floor((seconds % 3600) / 60)
  local remaining = seconds % 60
  if hours > 0 then
    return ("%d:%02d:%02d"):format(hours, minutes, remaining)
  end
  return ("%02d:%02d"):format(minutes, remaining)
end

local function stage_label(active)
  if not active then
    return "waiting for child process"
  end
  if active.item and active.item ~= "" then
    return active.tool .. " · " .. active.item
  end
  return active.tool
end

---Build display lines; previous stage observations precede the live heartbeat.
---@param summary table
---@param elapsed_seconds number
---@param history? table[]
---@return string[]
function M.format_lines(summary, elapsed_seconds, history)
  local lines = {}
  for _, entry in ipairs(history or {}) do
    lines[#lines + 1] = ("[UE stage] %s · %s"):format(entry.time, entry.label)
  end

  local active = summary and summary.active or nil
  local count = summary and summary.process_count or 0
  local total_cpu = summary and summary.total_cpu or 0
  local label = stage_label(active)
  local active_cpu = active and active.cpu or 0
  lines[#lines + 1] = ("[UE heartbeat] %s · %s · CPU %.1f%% (Σ %.1f%%) · %d process%s"):format(
    format_duration(elapsed_seconds),
    label,
    active_cpu,
    total_cpu,
    count,
    count == 1 and "" or "es"
  )
  return lines
end

local function render_virtual_lines(bufnr, lines)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  pcall(vim.api.nvim_buf_clear_namespace, bufnr, namespace, 0, -1)
  if not lines or #lines == 0 then
    return
  end

  local virtual_lines = {}
  for index, line in ipairs(lines) do
    virtual_lines[#virtual_lines + 1] = {
      { line, index == #lines and "DiagnosticInfo" or "Comment" },
    }
  end
  local row = math.max(0, vim.api.nvim_buf_line_count(bufnr) - 1)
  pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, row, 0, {
    virt_lines = virtual_lines,
    -- Keeping the overlay above the terminal cursor makes it visible even
    -- when the terminal is scrolled to its final physical line.
    virt_lines_above = true,
    right_gravity = false,
  })
end

M._render_virtual_lines = render_virtual_lines

local function default_job_running(jobid)
  local ok, result = pcall(vim.fn.jobwait, { jobid }, 0)
  return ok and type(result) == "table" and result[1] == -1
end

---Start an async monitor for an already-running terminal job.
---@param opts table
---@return table|nil monitor
function M.start(opts)
  opts = opts or {}
  local driver = opts.driver or require("utils.platform").driver()
  if type(driver.build_process_snapshot_plan) ~= "function" then
    return nil
  end

  local bufnr = tonumber(opts.bufnr)
  local jobid = tonumber(opts.jobid)
  if not bufnr or not jobid or not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end

  local root_pid = tonumber(opts.root_pid)
  if not root_pid then
    local ok, pid = pcall(vim.fn.jobpid, jobid)
    if ok then
      root_pid = tonumber(pid)
    end
  end
  if not root_pid or root_pid <= 0 then
    return nil
  end

  if active_by_buffer[bufnr] then
    active_by_buffer[bufnr]:stop()
  end

  local render = opts.render or render_virtual_lines
  local schedule = opts.schedule or vim.schedule
  local run = opts.run or vim.system
  local is_job_running = opts.is_job_running or default_job_running
  local now = opts.now or os.time
  local new_timer = opts.new_timer or (vim.uv or vim.loop).new_timer
  local timer = new_timer()
  if not timer then
    return nil
  end

  local state = {
    stopped = false,
    in_flight = false,
    started_at = now(),
    current_stage = nil,
    history = {},
    failures = 0,
  }
  local handle = {}

  local function clear()
    pcall(render, bufnr, {})
  end

  function handle:stop()
    if state.stopped then
      return
    end
    state.stopped = true
    pcall(timer.stop, timer)
    local closing_ok, closing = pcall(function()
      return timer:is_closing()
    end)
    if not closing_ok or not closing then
      pcall(timer.close, timer)
    end
    if active_by_buffer[bufnr] == self then
      active_by_buffer[bufnr] = nil
    end
    clear()
  end

  local function update_stage(summary)
    local active = summary.active
    local signature = active and (tostring(active.pid) .. "\0" .. stage_label(active)) or "waiting"
    if state.current_stage and state.current_stage.signature ~= signature then
      state.history[#state.history + 1] = {
        time = os.date("%H:%M:%S"),
        label = state.current_stage.label,
      }
      while #state.history > 2 do
        table.remove(state.history, 1)
      end
    end
    state.current_stage = { signature = signature, label = stage_label(active) }
  end

  local function tick()
    if state.stopped or state.in_flight then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) or not is_job_running(jobid) then
      handle:stop()
      return
    end

    local plan = driver.build_process_snapshot_plan(root_pid)
    if type(plan) ~= "table" or not plan.executable then
      return
    end
    local argv = { plan.executable }
    vim.list_extend(argv, plan.args or {})
    state.in_flight = true
    local ok = pcall(run, argv, { text = true }, function(result)
      schedule(function()
        state.in_flight = false
        if state.stopped or not vim.api.nvim_buf_is_valid(bufnr) then
          return
        end
        if result.code ~= 0 then
          state.failures = state.failures + 1
          if state.failures >= 2 then
            render(bufnr, { "[UE heartbeat] process snapshot unavailable; build output is unaffected" })
          end
          return
        end
        state.failures = 0
        local summary = M.summarize(M.parse_snapshot(result.stdout), root_pid)
        update_stage(summary)
        render(bufnr, M.format_lines(summary, now() - state.started_at, state.history))
      end)
    end)
    if not ok then
      state.in_flight = false
      state.failures = state.failures + 1
    end
  end

  active_by_buffer[bufnr] = handle
  render(bufnr, { "[UE heartbeat] Inspecting build process tree…" })
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = function()
      handle:stop()
    end,
  })
  timer:start(0, opts.interval_ms or 2000, function()
    schedule(tick)
  end)
  return handle
end

return M
