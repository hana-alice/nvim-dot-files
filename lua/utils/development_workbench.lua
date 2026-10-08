-- A current-work view over existing owners. Opening it never starts a probe/job.
local M = {}
local views = {}
local pending = false

local function clean(value)
  return tostring(value or "未选择"):gsub("[\r\n\t]", " ")
end

local function editing(win)
  return win
    and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_config(win).relative == ""
    and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

local function source(view)
  if editing(view.source_win) and vim.api.nvim_win_get_tabpage(view.source_win) == view.tab then
    return view.source_win
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(view.tab)) do
    if editing(win) then
      view.source_win = win
      return win
    end
  end
end

local function command(cmd)
  return function(win)
    if not editing(win) then
      return nil, "编辑窗口已关闭；请先打开文件。"
    end
    vim.api.nvim_set_current_win(win)
    vim.cmd(cmd)
    return true
  end
end

local outcome = {
  running = "执行中",
  awaiting_receipt = "等待该次结果",
  exit_zero = "该次进程退出 0",
  failed = "该次进程失败",
  not_current = "历史运行（原调用方已失效）",
  not_started = "未启动",
  cancelled = "停止请求/取消",
  unknown = "结果未知",
}

function M.recovery_actions(target)
  target = target or require("utils.ue_hub").target()
  local actions = {}
  local function add(label, cmd, run)
    actions[#actions + 1] = {
      group = "Recovery", label = label, always = true, command = cmd,
      run = run or function() vim.cmd(cmd) end,
    }
  end
  add("找回关掉的日志", "UEWorkspace logs")
  add("找回关掉的窗口、文件或结果", "UEWorkspace")
  local runs = require("utils.verification_runs")
  local records = target.project_root and runs.list({ project_root = target.project_root }) or {}
  local recent = records[1]
  if recent then
    add("找回最近构建日志 #" .. recent.id, nil, function()
      local ok, err = runs.show_log(recent.id)
      if not ok then vim.notify(clean(err), vim.log.levels.WARN) end
      return ok
    end)
  end
  add("继续已保存调查", "UEWorkContext")
  add("恢复上次会话", "UESessionRestore")
  add("找回异常退出的文本", "UERecovery")
  return actions
end

function M.recovery(opts)
  opts = opts or {}
  return require("utils.ue_hub").command_hub({
    source_win = opts.source_win,
    title = "恢复 — 按想做的事选择",
    actions = M.recovery_actions(),
  })
end

--- Build a headless-testable view; selection readiness is not runtime health.
function M.model(opts)
  opts = opts or {}
  local hub = require("utils.ue_hub")
  local target = opts.target or hub.target()
  local lines, actions, sections = {}, {}, {}
  local width = opts.width or 52
  local function add(label, run, info)
    -- Keep the five sections visible; full identities stay with their owners.
    local full_label = label
    if vim.fn.strdisplaywidth(label) > width then
      local count = vim.fn.strchars(label)
      repeat
        count = count - 1
        label = vim.fn.strcharpart(full_label, 0, count) .. "…"
      until vim.fn.strdisplaywidth(label) <= width or count == 0
    end
    lines[#lines + 1] = label
    if run then
      actions[#lines] = vim.tbl_extend("force", info or {}, { label = label, full_label = full_label, run = run })
    end
  end
  local function section(label)
    sections[#sections + 1] = { label = label, line = #lines + 1 }
    add(label)
  end
  add("当前开发工作台")
  add("Enter 操作 · g 向导 · R 恢复 · p 命令 · r 刷新 · q 关闭")
  add("")
  section("当前目标（Enter 修改选择）")
  for _, row in ipairs(hub.target_rows(target)) do
    add("  " .. clean(row.label) .. ": " .. clean(row.value), function(win)
      if not editing(win) then
        return nil, "编辑窗口已关闭。"
      end
      vim.api.nvim_set_current_win(win)
      row.run()
      return true
    end, { kind = "selection" })
  end
  add("  本实例最近状态: " .. clean(vim.g.ueindex_status or "暂无报告"))
  add("  > 查看未保存文件: " .. tostring(tonumber(vim.g.ue_unsaved_count) or 0), command("UEUnsaved"))
  add("")
  section("下一步（构建读取磁盘，不自动保存）")
  local onboarding = require("utils.ue_onboarding")
  local steps, flow = onboarding.steps(target), onboarding.current()
  if flow then
    add("  向导: " .. clean(flow.label or "配置检查") .. " · Esc 取消")
    add("  > 取消首次上手向导", function() return onboarding.cancel() end, { kind = "onboarding_cancel" })
  elseif #steps > 0 then
    add("  > 首次上手向导：补齐 " .. steps[1].label .. "（g）", function(win)
      return onboarding.start({ source_win = win })
    end, { kind = "onboarding", missing = steps })
  end
  for _, spec in ipairs({
    { label = "构建当前目标", group = "Build", cmd = "UEBuild" },
    {
      label = "运行或调试当前目标",
      group = "Run",
      target_fields = true,
      run = function()
        return hub.run_or_debug()
      end,
    },
    { label = "检查配置", always = true, cmd = "UEDoctor" },
    { label = "刷新索引", requires = { "project", "platform" }, cmd = "UEPrepare" },
  }) do
    local action = vim.tbl_extend("force", spec, { run = spec.run or function()
      vim.cmd(spec.cmd)
    end })
    local ready = hub.action_state(action, target)
    add("  > " .. spec.label .. (ready.ready and "" or (" [" .. ready.reason .. "]")), function(win)
      if not editing(win) then
        return nil, "编辑窗口已关闭。"
      end
      hub.invoke_action(action, { source_win = win })
      return true
    end, { kind = "action", readiness = ready })
  end
  if hub._pending_fix then
    add("  > 修复上次失败", function(win)
      if not editing(win) then return nil, "编辑窗口已关闭。" end
      vim.api.nvim_set_current_win(win)
      hub.run_fix()
      return true
    end, { kind = "fix" })
  end
  local loop = package.loaded["ue.workflows.android.iterate"]
  local active = loop and loop.active and loop.active()
  if active then
    add("  活动流程（r 更新）: " .. clean(active.status) .. " · " .. clean(active.stage))
  end
  local contexts = require("utils.work_context")
  local investigation = contexts.active(target)
  if investigation then
    add("  > 当前调查: " .. clean(investigation.name) .. "（Enter 详情与下一步）", function(win)
      return contexts.details(investigation, { source_win = win })
    end, { kind = "work_context_details", context_id = investigation.id })
  end
  add("  > 保存当前调查", function(win)
    if not editing(win) then
      return nil, "编辑窗口已关闭。"
    end
    contexts.prompt_save({ source_win = win })
    return true
  end, { kind = "work_context_save" })
  add("")
  section("最近结果（本工程构建，按发起时间）")
  local runs = require("utils.verification_runs")
  local records = target.project_root and runs.list({ project_root = target.project_root }) or {}
  if #records == 0 then
    add(target.project_root and "  尚无本实例构建记录" or "  请先选择工程")
  end
  for index, run in ipairs(records) do
    if index > 1 then
      add("  > 更多构建记录", function(win)
        local actions = {}
        for _, record in ipairs(records) do
          actions[#actions + 1] = { label = "#" .. record.id .. " 输出", always = true, group = "Results",
            run = function() return runs.show_log(record.id) end }
          actions[#actions + 1] = { label = "#" .. record.id .. " 错误", always = true, group = "Results",
            run = function() return runs.show_problems(record.id) end }
        end
        return hub.command_hub({ source_win = win, title = "本工程构建记录", actions = actions })
      end)
      break
    end
    add(("  #%d %s"):format(run.id, outcome[run.result] or "结果未知"))
    add(
      "    "
        .. clean(run.platform) .. " " .. clean(run.configuration)
        .. " · 发起时未保存: "
        .. tostring(run.dirty_count_start or "未知")
        .. (run.code ~= nil and (" · exit=" .. tostring(run.code)) or "")
    )
    add("    > 查看该次错误" .. (run.partial and "（部分记录）" or ""), function()
      return runs.show_problems(run.id)
    end, { kind = "problems", run_id = run.id })
    add("    > 查看该次输出", function()
      return runs.show_log(run.id)
    end, { kind = "log", run_id = run.id })
  end
  add("  历史退出结果不证明当前代码已验证")
  add("")
  section("运行中任务（Enter 查看；停止是独立操作）")
  local registry = require("utils.task_registry")
  local tasks = vim.tbl_filter(function(task) return task.status == "running" end, registry.list())
  if #tasks == 0 then
    add("  没有已登记任务")
  end
  for index, task in ipairs(tasks) do
    if index > 2 then
      break
    end
    local record = registry.get(task.id)
    if record then
      local expected = { kind = record.kind, handle = record.handle }
      add(("  #%d [%s] %s"):format(task.id, clean(task.result), clean(task.name)), function(win)
        return require("utils.task_inspector").open(task.id, { source_win = win, expected = expected })
      end, { kind = "task", task_id = task.id })
    end
  end
  add("  > 查看全部任务", command("UEPanel tasks"))
  add("")
  section("恢复（按想做的事选择）")
  add("  > 找回窗口、日志、调查、会话或异常退出文本（R）", function(win)
    if not editing(win) then return nil, "编辑窗口已关闭。" end
    M.recovery({ source_win = win })
    return true
  end, { kind = "recovery" })
  return { target = target, lines = lines, actions = actions, sections = sections }
end

local function valid(view)
  return vim.api.nvim_tabpage_is_valid(view.tab)
    and vim.api.nvim_win_is_valid(view.win)
    and vim.api.nvim_buf_is_valid(view.buf)
    and vim.api.nvim_win_get_buf(view.win) == view.buf
end

local function render(view)
  if not valid(view) then
    return
  end
  local previous = view.model
  view.model = M.model({ width = vim.api.nvim_win_get_width(view.win) })
  if previous and vim.deep_equal(previous.lines, view.model.lines) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(view.win)
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, view.model.lines)
  vim.bo[view.buf].modified = false
  vim.bo[view.buf].modifiable = false
  vim.api.nvim_win_set_cursor(view.win, { math.min(cursor[1], #view.model.lines), 0 })
end

function M.refresh()
  for tab, view in pairs(views) do
    if valid(view) then
      render(view)
    else
      views[tab] = nil
    end
  end
end

local function enqueue()
  if next(views) == nil then
    return
  end
  if pending then
    return
  end
  pending = true
  vim.schedule(function()
    pending = false
    M.refresh()
  end)
end

function M.activate(win)
  win = win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return false
  end
  local view = views[vim.api.nvim_win_get_tabpage(win)]
  if not view or not valid(view) or view.win ~= win then
    return false
  end
  local action = view.model.actions[vim.api.nvim_win_get_cursor(win)[1]]
  if not action then
    return false
  end
  local ok, result, err = pcall(action.run, source(view))
  if not ok or err then
    vim.notify(clean(err or result), vim.log.levels.WARN)
  end
  enqueue()
  return ok and result ~= nil
end

function M.close(win)
  win = win or vim.api.nvim_get_current_win()
  for tab, view in pairs(views) do
    if view.win == win and valid(view) then
      vim.api.nvim_win_close(win, false)
      views[tab] = nil
      return true
    end
  end
  return false
end

function M.open(opts)
  opts = opts or {}
  local tab = vim.api.nvim_get_current_tabpage()
  local previous = views[tab]
  if previous and valid(previous) then
    if editing(opts.source_win) then
      previous.source_win = opts.source_win
    end
    render(previous)
    vim.api.nvim_set_current_win(previous.win)
    return previous.win
  end
  local view = { tab = tab, source_win = opts.source_win or vim.api.nvim_get_current_win() }
  local origin = source(view)
  if not origin then
    vim.notify("请先打开一个编辑窗口，再打开开发工作台。", vim.log.levels.WARN)
    return nil
  end
  view.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[view.buf].bufhidden = "wipe"
  vim.bo[view.buf].filetype = "ue_workbench"
  view.win = vim.api.nvim_open_win(view.buf, true, {
    split = "right",
    win = origin,
    width = math.min(52, math.max(30, math.floor(vim.o.columns * 0.4))),
  })
  views[tab] = view
  vim.wo[view.win].wrap = true
  vim.wo[view.win].number = false
  vim.wo[view.win].relativenumber = false
  vim.wo[view.win].signcolumn = "no"
  vim.wo[view.win].foldcolumn = "0"
  vim.wo[view.win].cursorline = true
  vim.wo[view.win].winfixwidth = true
  for key, fn in pairs({
    ["<CR>"] = function()
      M.activate(view.win)
    end,
    r = M.refresh,
    q = function()
      require("utils.ue_onboarding").cancel()
      M.close(view.win)
    end,
    g = function()
      local win = source(view)
      if win then require("utils.ue_onboarding").start({ source_win = win }) end
    end,
    R = function() M.recovery({ source_win = source(view) }) end,
    p = function() require("utils.ue_hub").command_hub({ source_win = source(view) }) end,
  }) do
    vim.keymap.set("n", key, fn, { buffer = view.buf, nowait = true, silent = true })
  end
  render(view)
  return view.win
end

function M.setup()
  require("utils.ue_onboarding").setup()
  require("utils.work_context").setup()
  vim.api.nvim_create_user_command("UEWorkbench", function()
    M.open()
  end, { desc = "Current target, next actions, build evidence and tasks" })
  local group = vim.api.nvim_create_augroup("UEDevelopmentWorkbench", { clear = true })
  vim.api.nvim_create_autocmd("User", { group = group, pattern = "UEWorkbenchChanged", callback = enqueue })
  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost", "BufModifiedSet", "FocusGained", "TermClose" }, {
    group = group,
    callback = function(event)
      for _, view in pairs(views) do
        if event.buf == view.buf then
          return
        end
      end
      enqueue()
    end,
  })
end

return M
