-- First-use coordination only. Selection, prepare and doctor keep their owners.
local M = {}
local active
local ns = vim.api.nvim_create_namespace("ue_onboarding")
local esc = vim.api.nvim_replace_termcodes("<Esc>", true, false, true)
local interrupt = vim.api.nvim_replace_termcodes("<C-c>", true, false, true)

local function changed()
  pcall(vim.api.nvim_exec_autocmds, "User", { pattern = "UEWorkbenchChanged" })
end

function M.readiness(target)
  if not target.project or not target.project_root then
    return "missing"
  end
  local ok, snapshot = pcall(require("ue").semantic_index_snapshot, {
    project_root = target.project_root,
    engine_root = target.engine_root,
    uproject = target.uproject,
  })
  return ok and snapshot and snapshot.readiness or "missing"
end

function M.steps(target, readiness)
  local steps = {}
  if not target.project then
    steps[#steps + 1] = { id = "project", label = "工程", command = "UESetProject" }
  end
  if not target.platform or target.platform == "" or not target.configuration or target.configuration == "" then
    steps[#steps + 1] = { id = "platform", label = "平台/配置", row = "Platform", command = "UESetPlatform" }
  end
  for _, row in ipairs(require("utils.ue_hub").target_rows(target)) do
    if row.label ~= "Project" and row.label ~= "Platform" and row.value == "(none)" then
      steps[#steps + 1] = { id = row.label, label = row.label, row = row.label, field = row.name or row.label:lower() }
    end
  end
  readiness = readiness or M.readiness(target)
  if readiness ~= "ready" then
    steps[#steps + 1] = { id = "prepare", label = "准备索引", command = "UEPrepare", readiness = readiness }
  end
  return steps
end

function M.current()
  return active and { stage = active.stage, label = active.step and active.step.label } or nil
end

function M.cancel()
  if not active then
    return false
  end
  local flow = active
  active = nil
  vim.on_key(nil, ns)
  vim.schedule(function()
    local picker = flow.picker
    if type(picker) == "table" and not picker.closed and picker.input and picker.list then
      local win = vim.api.nvim_get_current_win()
      if win == picker.input.win.win or win == picker.list.win.win then
        picker:norm(function() if not picker.closed then picker:close() end end)
      end
    end
    changed()
  end)
  return true
end

local function valid(flow)
  if active ~= flow then
    return false
  end
  local api = vim.api
  if not api.nvim_win_is_valid(flow.win) or api.nvim_win_get_buf(flow.win) ~= flow.buf
    or api.nvim_win_get_tabpage(flow.win) ~= flow.tab or api.nvim_buf_get_name(flow.buf) ~= flow.name
    or api.nvim_buf_get_changedtick(flow.buf) ~= flow.tick
    or not vim.deep_equal(api.nvim_win_get_cursor(flow.win), flow.cursor) then
    M.cancel()
    return false
  end
  local target = require("utils.ue_hub").target()
  if flow.project and (target.project_root ~= flow.project or target.engine_root ~= flow.engine) then
    M.cancel()
    return false
  end
  return true
end

local function doctor(flow)
  if not valid(flow) then
    return
  end
  vim.api.nvim_set_current_win(flow.win)
  if not valid(flow) then
    return
  end
  M.cancel()
  vim.cmd("UEDoctor")
end

local function dependencies(flow, step, target)
  local hub = require("utils.ue_hub")
  local expected = hub.runtime_identity(target)
  if step.field then expected[step.field] = nil end
  return function()
    if not valid(flow) then return false end
    local current = hub.target()
    if step.id == "project" then
      return current.project_root == target.project_root and current.engine_root == target.engine_root
    end
    if step.id == "platform" then return true end
    if current.platform ~= target.platform or current.configuration ~= target.configuration then return false end
    local identity = hub.runtime_identity(current)
    if step.field then identity[step.field] = nil end
    return vim.deep_equal(identity, expected)
  end
end

function M.selection_guard()
  local flow = active
  if not flow or not flow.dispatching_selection then return nil end
  local step = flow.step
  local check = flow.selection_check
  return function() return flow.stage == "selecting" and flow.step == step and check() end
end

function M.selection_options()
  local guard = M.selection_guard()
  if not guard then return {} end
  return {
    is_current = guard,
    ui_select = function(items, opts, done)
      if not guard() then return done(nil) end
      local flow = active
      local picker = vim.ui.select(items, opts, function(choice, index)
        if not guard() then return done(nil) end
        if not choice then M.cancel() end
        done(choice, index)
      end)
      flow.picker = picker
      return picker
    end,
    input = function(opts, done)
      if not guard() then return done(nil) end
      local flow = active
      local input = vim.ui.input(opts, function(value)
        if not guard() then return done(nil) end
        if not value then M.cancel() end
        done(value)
      end)
      flow.input = input
      return input
    end,
  }
end

function M.run_selection(run)
  local flow = active
  if not flow or not valid(flow) then return end
  flow.dispatching_selection = true
  local ok, err = pcall(run)
  flow.dispatching_selection = nil
  if not ok then
    M.cancel()
    vim.notify("首次上手已停止：" .. tostring(err), vim.log.levels.WARN)
  end
end

-- The command entry captures this guard before its launcher defers real work.
-- Ordinary :UEPrepare calls have no onboarding guard.
function M.prepare_guard()
  local flow = active
  if not flow or not flow.dispatching_prepare then
    return nil
  end
  return function()
    local hub = require("utils.ue_hub")
    if not valid(flow) or not vim.deep_equal(hub.target(), flow.prepare_target)
      or not vim.deep_equal(hub.runtime_identity(hub.target()), flow.prepare_identity) then
      if active == flow then M.cancel() end
      return false
    end
    flow.dispatched = true
    vim.schedule(function()
      if not valid(flow) then
        return
      end
      if require("ue")._prepare_running then
        flow.started = true
      else
        -- Refused/failed synchronously: doctor still reports the unmet setup.
        doctor(flow)
      end
    end)
    return true
  end
end

function M.advance()
  local flow = active
  if not flow or not valid(flow) then
    return
  end
  if flow.stage == "preparing" then
    if require("ue")._prepare_running then
      flow.started = true
    elseif flow.started then
      doctor(flow)
    end
    return
  end
  local hub = require("utils.ue_hub")
  local target = hub.target()
  local step = M.steps(target)[1]
  if flow.stage == "selecting" and step and flow.step.id == step.id then
    if not flow.selection_check() then M.cancel() end
    return
  end
  if flow.stage == "prompt" then
    if not flow.selection_check() then M.cancel() end
    return
  end
  flow.project, flow.engine = target.project_root, target.engine_root
  if not step then
    return doctor(flow)
  end
  flow.step = step
  flow.selection_check = dependencies(flow, step, target)
  if step.row then
    flow.stage = "selecting"
    flow.picker = hub.target_switcher({
      row = step.row,
      title = "首次上手：补齐 " .. step.label .. "（Esc 取消向导）",
      guard = function() return flow.stage == "selecting" and flow.step == step and flow.selection_check() end,
      invoke = M.run_selection,
      on_cancel = function() if active == flow then M.cancel() end end,
    })
    return
  end
  flow.stage = "prompt"
  local prepare = step.id == "prepare"
  flow.picker = vim.ui.select({ prepare and "确认运行 :UEPrepare" or "选择工程 :UESetProject", "取消" }, {
    prompt = prepare and "首次上手：准备索引可能耗时，确认后才启动（Esc 取消）"
      or "首次上手：缺工程，先选择工程（Esc 取消）",
  }, function(choice, index)
    if not valid(flow) or flow.stage ~= "prompt" then
      return
    end
    if not flow.selection_check() then return M.cancel() end
    if not choice or choice == "取消" or index == 2 then
      return M.cancel()
    end
    if not vim.deep_equal(hub.target(), target) then
      return M.cancel()
    end
    vim.api.nvim_set_current_win(flow.win)
    if not valid(flow) then
      return
    end
    flow.stage = prepare and "preparing" or "selecting"
    flow.prepare_target = prepare and target or nil
    flow.prepare_identity = prepare and hub.runtime_identity(target) or nil
    flow.dispatching_prepare = prepare
    flow.dispatching_selection = not prepare
    local ok, err = pcall(vim.cmd, step.command)
    flow.dispatching_prepare = nil
    flow.dispatching_selection = nil
    if not ok then
      M.cancel()
      vim.notify("首次上手已停止：" .. tostring(err), vim.log.levels.WARN)
    elseif not prepare then
      vim.schedule(M.advance)
    end
    changed()
  end)
  changed()
end

function M.selection_changed()
  local flow = active
  if not flow then
    return
  end
  vim.schedule(function()
    if active == flow then
      M.advance()
      changed()
    end
  end)
end

function M.start(opts)
  opts = opts or {}
  M.cancel()
  local api = vim.api
  local win = opts.source_win or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then
    return false
  end
  local buf = api.nvim_win_get_buf(win)
  if vim.bo[buf].buftype ~= "" then
    return false
  end
  api.nvim_set_current_win(win)
  active = {
    win = win, buf = buf, tab = api.nvim_win_get_tabpage(win),
    name = api.nvim_buf_get_name(buf), tick = api.nvim_buf_get_changedtick(buf),
    cursor = api.nvim_win_get_cursor(win), stage = "next",
  }
  local hub = require("utils.ue_hub")
  hub.cancel_pending_action()
  vim.on_key(function(key)
    if key == esc or key == interrupt or (key == "q" and vim.fn.mode() == "n") then
      M.cancel()
    end
  end, ns)
  M.advance()
  return true
end

function M.setup()
  local group = vim.api.nvim_create_augroup("UEOnboarding", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group, pattern = "UEWorkbenchChanged",
    callback = function()
      if active and active.stage == "preparing" then
        local flow = active
        if require("ue")._prepare_running then flow.started = true end
        vim.schedule(function() if active == flow then M.advance() end end)
      end
    end,
  })
end

return M
