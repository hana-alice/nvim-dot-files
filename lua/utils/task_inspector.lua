-- Read existing task handles and their terminal output; viewing never starts
-- or stops a process. The registry remains the sole source of task status.
local M = {}
local details = {}

---@class TaskInspection
---@field id integer
---@field name string
---@field group string
---@field kind string
---@field handle any
---@field started_at number?
---@field status string
---@field code integer?
---@field result string
---@field output {buf: integer, name: string, panel: string}?
---@field output_reason string?

local function expired()
  return nil, "任务已过期或被清理；请刷新任务列表。"
end

local function output_for(record)
  if record.kind ~= "job" then
    return nil
  end
  local channels = vim.api.nvim_list_chans()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(buf)
      and vim.bo[buf].buftype == "terminal"
      and vim.bo[buf].channel == record.handle
    then
      -- nvim_open_term can reuse this buffer without updating bo.channel.
      -- An extra terminal stream means its current text has no unique owner.
      for _, channel in ipairs(channels) do
        if channel.mode == "terminal" and channel.buffer == buf and channel.id ~= record.handle then
          return nil, "此缓冲区存在其他终端频道，无法唯一关联到此任务。"
        end
      end
      local panel = vim.b[buf].ue_bottom_panel_kind
      if panel ~= "build" and panel ~= "logcat" and panel ~= "debug" and panel ~= "task" then
        panel = vim.b[buf].ue_build_title and "build" or "task"
      end
      return { buf = buf, name = vim.api.nvim_buf_get_name(buf), panel = panel }
    end
  end
end

--- Facts are a fresh snapshot. Only the native handle reference is retained.
---@param id integer
---@return TaskInspection? facts, string? err
function M.inspect(id)
  local registry = require("utils.task_registry")
  local record = registry.get(id)
  if not record then
    return expired()
  end
  local kind, handle = record.kind, record.handle
  local status, code = registry.status(id)
  if not status or registry.get(id) ~= record or record.kind ~= kind or record.handle ~= handle then
    return expired()
  end
  local output, output_reason = output_for(record)
  return {
    id = record.id,
    name = record.name,
    group = record.group,
    kind = kind,
    handle = handle,
    started_at = record.started_at,
    status = status,
    code = code,
    result = status == "running" and "running"
      or status == "cancelled" and "cancelled"
      or code == 0 and "success"
      or code ~= nil and "failed"
      or "unknown",
    output = output,
    output_reason = output_reason,
  }
end

---@param id integer
---@param expected? table
---@return TaskInspection? facts, string? err
local function inspect_expected(id, expected)
  local facts, err = M.inspect(id)
  if facts and expected and (facts.kind ~= expected.kind or facts.handle ~= expected.handle) then
    return expired()
  end
  return facts, err
end

local function line(value)
  return tostring(value):gsub("[\r\n]", " ")
end

local function owned(view)
  return view
    and vim.api.nvim_buf_is_valid(view.buf)
    and vim.api.nvim_buf_get_name(view.buf) == view.name
    and vim.api.nvim_buf_get_changedtick(view.buf) == view.tick
    and vim.bo[view.buf].buftype == "nofile"
    and vim.bo[view.buf].readonly
    and not vim.bo[view.buf].modifiable
    and not vim.bo[view.buf].modified
end

local function render(view, facts)
  local lines = {
    "任务详情  ·  Enter 查看 / 刷新  ·  dd/C-x 停止此任务  ·  r 刷新",
    "",
    ("任务 #%d：%s"):format(facts.id, line(facts.name)),
    "分组：" .. line(facts.group),
    "状态：" .. (facts.result == "unknown" and "已结束（退出码未知）" or facts.result),
    "句柄类型：" .. facts.kind,
  }
  if facts.code ~= nil then
    lines[#lines + 1] = "退出码：" .. facts.code
  end
  if type(facts.started_at) == "number" then
    lines[#lines + 1] = "开始时间：" .. os.date("%Y-%m-%d %H:%M:%S", facts.started_at)
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = facts.output and "保留的终端输出可用；按 Enter 查看。"
    or facts.output_reason
    or "没有与此任务句柄关联的保留终端输出。"
  lines[#lines + 1] = "关闭此视图不会停止任务；需要停止时请按 dd 或 Ctrl-X。"
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.bo[view.buf].readonly = true
  vim.bo[view.buf].modified = false
  view.tick = vim.api.nvim_buf_get_changedtick(view.buf)
end

local function detail_buffer(facts)
  for tab in pairs(details) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      details[tab] = nil
    end
  end
  local tab = vim.api.nvim_get_current_tabpage()
  local view = details[tab]
  if not owned(view) then
    local buf = vim.api.nvim_create_buf(false, true)
    local name = "ue-task://" .. tab .. "/" .. buf
    vim.api.nvim_buf_set_name(buf, name)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "ue_task"
    vim.b[buf].ue_bottom_panel_kind = "task"
    view = { buf = buf, name = name }
    details[tab] = view
  end
  render(view, facts)
  local expected = { kind = facts.kind, handle = facts.handle }
  local function current()
    if not owned(view) then
      return nil, "任务详情已被修改；请重新打开任务列表。"
    end
    return inspect_expected(facts.id, expected)
  end
  local function refresh()
    local fresh, err = current()
    if fresh then
      render(view, fresh)
    else
      vim.notify(err or "任务详情无法刷新。", vim.log.levels.WARN)
    end
  end
  local function stop()
    local fresh, err = current()
    if not fresh then
      vim.notify(err or "任务已过期；请刷新列表。", vim.log.levels.WARN)
      return
    end
    local stopped = require("utils.task_registry").cancel(fresh.id)
    vim.notify(stopped and ("已请求停止任务 " .. fresh.id) or "该任务已经结束", vim.log.levels.INFO)
    refresh()
  end
  vim.keymap.set("n", "<CR>", function()
    local fresh, err = current()
    if not fresh then
      vim.notify(err or "任务已过期；请刷新列表。", vim.log.levels.WARN)
      return
    end
    if fresh.output then
      local win, open_err = M.open(fresh.id, { expected = expected })
      if not win then
        vim.notify(open_err or "任务输出无法打开。", vim.log.levels.WARN)
      end
    else
      render(view, fresh)
    end
  end, { buffer = view.buf, silent = true, desc = "查看任务输出 / 刷新详情" })
  for _, key in ipairs({ "dd", "<C-x>" }) do
    vim.keymap.set("n", key, stop, { buffer = view.buf, silent = true, desc = "停止此后台任务" })
  end
  vim.keymap.set("n", "r", refresh, { buffer = view.buf, silent = true, desc = "刷新任务详情" })
  return view.buf
end

--- Open an existing output view, or read-only facts in the one bottom host.
--- opts.expected optionally binds a rendered entry to its kind and handle.
---@param id integer
---@param opts? table
---@return integer? win, string? err
function M.open(id, opts)
  opts = opts or {}
  local facts, err = inspect_expected(id, opts.expected)
  if not facts then
    return nil, err
  end
  local output = facts.output
  if output then
    return require("utils.workspace").activate(
      { kind = "log", buf = output.buf, name = output.name, panel = output.panel },
      opts
    )
  end
  return require("utils.bottom_panel").show("task", detail_buffer(facts), opts)
end

return M
