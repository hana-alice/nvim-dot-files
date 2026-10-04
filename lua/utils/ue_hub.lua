-- utils.ue_hub — keyboard-first command hub and target switcher.
--
-- The UE workflow exposes ~90 `:UE*` commands. Instead of memorising them,
-- one key opens a searchable, grouped action list; another opens the current
-- target (project / platform / device / package) for switching. Entries are
-- declarative so the list is testable and stays in sync with real commands.

local M = {}

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local command_names = setmetatable({}, { __mode = "k" })
local function cmd(name)
  local run = function()
    vim.cmd(name)
  end
  command_names[run] = name
  return run
end

local function mapped_key(key)
  return function()
    local mapping = vim.fn.maparg(key, "n", false, true)
    if type(mapping.callback) == "function" then
      return mapping.callback()
    end
    vim.notify("当前入口未就绪: " .. key, vim.log.levels.WARN)
  end
end

-- Reuse the attached buffer's actual key callback, including capability guards.
-- A hub picker may change the current buffer; capture its source window first.
local function code_key(key)
  local run = mapped_key(key)
  return function()
    if #vim.lsp.get_clients({ bufnr = 0, name = "clangd" }) == 0 then
      vim.notify("C++ 导航需要当前文件已附加 clangd", vim.log.levels.WARN)
      return
    end
    return run()
  end
end

--- Generic actions: { group, label, key?, command?, method?, clangd_only?, run }. Target-specific actions and
--- fields come from the active target driver's declarative `hub(state)`.
M.actions = {
  { group = "Run",    label = "Run / debug current target (F5 when idle)", key = "<F5>", target_fields = true, run = function() M.run_or_debug() end },
  { group = "Run",    label = "Launch app (no debugger)", key = "<leader>ul", target_fields = true, run = cmd("UELaunch") },
  { group = "Code", label = "Go to definition / 跳到定义", key = "gd", run = mapped_key("gd") },
  { group = "Code", label = "References / 查看引用", key = "gr", run = mapped_key("gr") },
  { group = "Code", label = "Switch source / header / 切换头文件源文件", key = "<leader>ch", run = code_key("<leader>ch") },
  { group = "Code", label = "Incoming calls / 谁调用了它", key = "<leader>cI", run = code_key("<leader>cI") },
  { group = "Code", label = "Outgoing calls / 它调用了谁", key = "<leader>cO", run = code_key("<leader>cO") },
  { group = "Code", label = "Workspace symbols / 类名、函数名", key = "<leader>sS", run = code_key("<leader>sS") },
  { group = "Code", label = "Document symbols / 当前文件大纲", key = "<leader>ss", run = code_key("<leader>ss") },
  { group = "Code", label = "Base types / 基类", key = "<leader>cB", run = code_key("<leader>cB") },
  { group = "Code", label = "Derived types / 派生类", key = "<leader>cD", run = code_key("<leader>cD") },
  { group = "Read", label = "Peek definition / 预览定义并保留上下文", run = cmd("UEPeek") },
  { group = "Read", label = "Return to investigation origin / 返回调查起点", run = cmd("UEReadReturn") },
  { group = "Read", label = "Cancel reading request / 取消待返回的阅读请求", run = cmd("UEReadCancel") },
  { group = "Read", label = "Browse incoming calls / 连续浏览调用者", method = "textDocument/prepareCallHierarchy", clangd_only = true, run = cmd("UERelations incoming") },
  { group = "Read", label = "Browse outgoing calls / 连续浏览调用目标", method = "textDocument/prepareCallHierarchy", clangd_only = true, run = cmd("UERelations outgoing") },
  { group = "Read", label = "Browse base types / 连续浏览基类", method = "textDocument/prepareTypeHierarchy", clangd_only = true, run = cmd("UERelations base") },
  { group = "Read", label = "Browse derived types / 连续浏览派生类", method = "textDocument/prepareTypeHierarchy", clangd_only = true, run = cmd("UERelations derived") },
  { group = "Read", label = "Resume relationship browser / 找回上次关系浏览", run = cmd("UERelations resume") },
  { group = "Code", label = "Rename symbol / 重命名", key = "<leader>cr", run = code_key("<leader>cr") },
  { group = "Code", label = "Code action / 代码操作", key = "<leader>ca", run = code_key("<leader>ca") },
  { group = "Code", label = "Undo refactor batch / 撤销上次整批修改", run = cmd("UERefactorUndo") },
  { group = "Code", label = "Refactor recovery / 查看修改恢复记录", run = cmd("UERefactorRecovery") },
  { group = "Code", label = "Create UE class / 预览并创建类", requires = { "project" }, run = cmd("UENewClass") },
  { group = "Code", label = "Format safely / 安全格式化", key = "<leader>cf", run = cmd("UEFormat") },
  { group = "Code", label = "Format with UE style / 用 UE 风格格式化", run = cmd("UEFormat epic") },
  { group = "Code", label = "Inlay hints / 内联提示开关", key = "<leader>uh", run = function()
    local mapping = vim.fn.maparg("<leader>uh", "n", false, true)
    if type(mapping.callback) == "function" then mapping.callback() end
  end },
  { group = "Files", label = "Unsaved files / 未保存文件", run = cmd("UEUnsaved") },
  { group = "Files", label = "Restore project session / 按需恢复会话", run = cmd("UESessionRestore") },
  { group = "Files", label = "Recover unsaved text / 恢复异常退出的未保存文本", run = cmd("UERecovery") },
  { group = "Files", label = "Quit with unsaved list / 退出前查看未保存文件", key = "<leader>qq", run = cmd("UEQuit") },
  { group = "Search", label = "Indexed code search / 快速索引搜索", key = "<leader>/", run = function() require("ue").cached_grep() end },
  { group = "Search", label = "Explicit rg code search / 独立代码搜索", key = "<leader>sg", run = mapped_key("<leader>sg") },
  { group = "Search", label = "Explicit rg text search / 搜索未索引的全部文本", key = "<leader>sG", run = mapped_key("<leader>sG") },
  { group = "Search", label = "Workspace all files / 查找工程和引擎全部文件", key = "<leader><space>", run = mapped_key("<leader><space>") },
  { group = "Search", label = "Project files / 查找项目文件", key = "<leader>ff", requires = { "project" }, run = mapped_key("<leader>ff") },
  { group = "Search", label = "Search history / 按原条件重新搜索", key = "<leader>sH", run = cmd("UESearchHistory") },
  { group = "Search", label = "Resume last search / 恢复最近搜索", key = "<leader>s/", run = mapped_key("<leader>s/") },
  { group = "Search", label = "History hub / 搜索文件跳转与结果历史", key = "<leader>fh", run = mapped_key("<leader>fh") },
  { group = "Windows", label = "Find or recover a window / 找回关闭的窗口", key = "<leader>wM", run = cmd("UEWorkspace") },
  { group = "Windows", label = "Visible windows across tabs / 跨标签窗口", run = cmd("UEWorkspace windows") },
  { group = "Windows", label = "Hidden buffers / 窗口关闭后保留的文件", run = cmd("UEWorkspace buffers") },
  { group = "Results", label = "Saved search results / 找回保存的搜索结果", run = cmd("UEWorkspace results") },
  { group = "Tasks", label = "Find tasks and output / 找回任务及日志", run = cmd("UEWorkspace tasks") },
  { group = "Logs", label = "Retained terminal and stage logs / 找回关闭的任务输出", run = cmd("UEWorkspace logs") },
  { group = "Build",  label = "Build active target", key = "<leader>ub", run = cmd("UEBuild") },
  { group = "Build",  label = "First build error / 首个构建错误", key = "<leader>uE", always = true, run = cmd("UEBuildFirstError") },
  { group = "Tests", label = "UE Editor tests / 发现与运行测试", requires = { "project" }, run = cmd("UETests") },
  { group = "Tests", label = "Last test results / 上次测试结果", requires = { "project" }, run = cmd("UETests results") },
  { group = "Tests", label = "Rerun failed tests / 重跑失败测试", requires = { "project" }, run = cmd("UETests rerun") },
  { group = "Build",  label = "Install app on device", key = "<leader>ui", target_fields = true, run = cmd("UEInstall") },
  { group = "Debug",  label = "Attach debugger", key = "<leader>da", target_fields = true, run = cmd("UEDAPAttach") },
  { group = "Debug",  label = "Launch under debugger (wait-for-debugger)", key = "<leader>dl", target_fields = true, run = cmd("UEDAPLaunch") },
  { group = "Debug",  label = "Reattach to restarted app", always = true, run = cmd("UEDAPReattach") },
  { group = "Debug",  label = "Stop debug session", key = "<S-F5>", always = true, run = cmd("UEDAPStop") },
  { group = "Debug",  label = "Debugger preflight (why would attach fail?)", target_fields = true, run = cmd("UEDAPPreflight") },
  { group = "Logs",   label = "Toggle app log", key = "<leader>ug", requires = { "project", "platform" }, target_fields = true, run = cmd("UELogToggle") },
  { group = "Logs",   label = "Logcat (debug panel tab)", key = "<leader>d4", run = cmd("UEDAPTab logcat") },
  { group = "Logs",   label = "Notification history", key = "<leader>uN", run = cmd("NotificationHistory") },
  { group = "Target", label = "Switch target (project/platform/device/package)", key = "<leader>uu", run = function() M.target_switcher() end },
  { group = "Target", label = "Run profiles / 选择运行配置", run = cmd("UERunProfile") },
  { group = "Target", label = "Save run profile / 保存当前运行配置", run = cmd("UERunProfileSave") },
  { group = "Target", label = "Delete run profile / 删除运行配置", run = cmd("UERunProfileDelete") },
  { group = "Target", label = "Set platform / configuration", run = cmd("UESetPlatform") },
  { group = "Target", label = "Set project", run = cmd("UESetProject") },
  { group = "Index",  label = "Prepare (compile DB + index)", run = cmd("UEPrepare") },
  { group = "Index",  label = "Index status", run = cmd("UEIndexStatus") },
  { group = "Index",  label = "Rebuild code search index", run = cmd("UEBuildCsearch") },
  { group = "Tasks",  label = "Background tasks (list / stop)", key = "<leader>X", run = cmd("Tasks") },
  { group = "Panels", label = "Cycle bottom panel / 底部面板", key = "<leader>uJ", run = cmd("UEPanelNext") },
  { group = "Panels", label = "Build output / 构建输出", run = cmd("UEPanel build") },
  { group = "Panels", label = "Problems / 问题列表", run = cmd("UEPanel quickfix") },
  { group = "Panels", label = "Logcat / 日志", run = cmd("UEPanel logcat") },
  { group = "Panels", label = "Background tasks / 后台任务", run = cmd("UEPanel tasks") },
  { group = "Tasks",  label = "Stop all background tasks", key = "<leader>XA", run = cmd("TaskStopAll") },
  { group = "Help",   label = "Run the fix for the last failure", key = "<leader>uk", run = function() M.run_fix() end },
  { group = "Help",   label = "Cheatsheet", key = "<leader>?", run = cmd("UECheatsheet") },
  { group = "Help",   label = "Environment doctor (tools, target, device, package)", run = cmd("UEDoctor") },
  { group = "Help",   label = "Editor health audit", run = cmd("NvimCoreHealth") },
  { group = "Help",   label = "User guide / 使用手册（日常流程、按键、排障）", key = "<leader>u?", run = function() M.open_guide() end },
}

for _, action in ipairs(M.actions) do
  action.command = command_names[action.run]
end

local function target_hub(target)
  local driver = require("ue.targets").driver(target.platform)
  if driver and type(driver.hub) == "function" then
    local ok, contribution = pcall(driver.hub, target.state or {})
    if ok and type(contribution) == "table" then return contribution end
  end
  return { actions = {}, fields = {} }
end

local CODE_METHODS = {
  ["<leader>cI"] = "textDocument/prepareCallHierarchy",
  ["<leader>cO"] = "textDocument/prepareCallHierarchy",
  ["<leader>sS"] = "workspace/symbol",
  ["<leader>ss"] = "textDocument/documentSymbol",
  ["<leader>cB"] = "textDocument/prepareTypeHierarchy",
  ["<leader>cD"] = "textDocument/prepareTypeHierarchy",
  ["<leader>cr"] = "textDocument/rename",
  ["<leader>ca"] = "textDocument/codeAction",
  ["<leader>ch"] = "textDocument/switchSourceHeader",
}

-- Selection readiness is not proof of device, symbol or full-index health.
-- Only read current state/capabilities; never prepare, scan or probe a device.
function M.action_state(action, target, opts)
  opts = opts or {}
  local dap = package.loaded["dap"]
  if action.key == "<F5>" and dap and dap.session and dap.session() then
    return { ready = true }
  end
  if action.always then
    return { ready = true }
  end
  local requirements = action.requires
    or (
      (action.group == "Build" or action.group == "Run" or action.group == "Debug") and { "project", "platform" } or {}
    )
  for _, requirement in ipairs(requirements) do
    if requirement == "project" and not target.project then
      return { ready = false, reason = "缺工程", fix = "UESetProject" }
    elseif requirement == "platform" and trim(target.platform) == "" then
      return { ready = false, reason = "缺平台/配置", fix = "UESetPlatform" }
    end
  end
  if action.target_fields then
    local contribution = opts.contribution or target_hub(target)
    for _, name in
      ipairs(action.target_fields == true and (contribution.runtime_requires or {}) or action.target_fields)
    do
      for _, field in ipairs(contribution.fields or {}) do
        if field.name == name and not field.value then
          return { ready = false, reason = "缺 " .. (field.label or name), fix = field.command or "UEDoctor" }
        end
      end
    end
  end
  local method = action.method or CODE_METHODS[action.key]
  if method then
    local clients = opts.clients
      or vim.lsp.get_clients({ bufnr = opts.buf or 0, name = not action.method and "clangd" or nil })
    for _, client in ipairs(clients) do
      -- Match reading.choose_client(..., true), which UERelations uses.
      if
        (not action.clangd_only or tostring(client.name):lower():find("clangd", 1, true))
        and client:supports_method(method, opts.buf or 0)
      then
        return { ready = true }
      end
    end
    return {
      ready = false,
      reason = action.method and "当前位置没有支持此操作的提供者"
        or (#clients == 0 and "当前文件 clangd 未就绪" or "clangd 不支持此操作"),
      fix = "UEDoctor",
    }
  end
  return { ready = true }
end
--- Current target snapshot from persisted state.
function M.target(opts)
  opts = opts or {}
  local ok, ue = pcall(require, "ue")
  local ctx = opts.ctx
  if not ctx and ok and type(ue.resolve_context) == "function" then
    local ok_ctx, resolved = pcall(ue.resolve_context)
    if ok_ctx then ctx = resolved end
  end
  local state = (ctx and ctx.state) or {}
  return {
    project = ctx and (ctx.uproject and vim.fn.fnamemodify(ctx.uproject, ":t:r") or ctx.project_root) or nil,
    project_root = ctx and ctx.project_root or nil,
    uproject = ctx and ctx.uproject or nil,
    engine_root = ctx and ctx.engine_root or nil,
    platform = trim(state.target_platform),
    configuration = trim(state.target_configuration),
    state = state,
  }
end

--- Actions visible for a target: target-owned actions join their groups
--- after the generic ones.
function M.visible_actions(target, opts)
  opts = opts or {}
  local out = {}
  local contribution = target_hub(target)
  for _, action in ipairs(M.actions) do
    out[#out + 1] = vim.tbl_extend("force", {}, action)
  end
  for _, action in ipairs(contribution.actions or {}) do
    out[#out + 1] = vim.tbl_extend("force", {}, action, { run = cmd(action.command) })
  end
  for _, action in ipairs(out) do
    action.readiness = M.action_state(action, target, { contribution = contribution, buf = opts.buf })
  end
  local first, rank = {}, {}
  for index, action in ipairs(out) do
    first[action.group] = first[action.group] or index
    rank[action] = first[action.group] * 1000 + index
  end
  table.sort(out, function(x, y)
    return rank[x] < rank[y]
  end)
  return out
end

function M.format_action(action)
  local shortcut = action.key or (action.command and (":" .. action.command))
  local key = shortcut and ("  " .. shortcut) or ""
  local state = action.readiness
  local readiness = state and not state.ready and ("  [" .. state.reason .. "]") or ""
  return ("%-7s %s%s%s"):format(action.group, action.label, key, readiness)
end

local pending_action
local intent_epoch = 0
function M.pending_action() return pending_action end

local function runtime_identity(target)
  local fields = {}
  for _, field in ipairs(target_hub(target).fields or {}) do
    fields[field.name] = field.identity or field.value or false
  end
  return fields
end

local function source_valid(pending)
  return pending.epoch == intent_epoch
    and vim.api.nvim_win_is_valid(pending.win)
    and vim.api.nvim_win_get_buf(pending.win) == pending.buf
    and vim.api.nvim_buf_get_name(pending.buf) == pending.name
    and vim.api.nvim_buf_get_changedtick(pending.buf) == pending.tick
    and (not pending.tab or vim.api.nvim_win_get_tabpage(pending.win) == pending.tab)
    and (not pending.cursor or vim.deep_equal(vim.api.nvim_win_get_cursor(pending.win), pending.cursor))
end

-- Called after an explicit, successful selection. The user confirms continuing
-- the retained intent; cancelling a picker can never start a delayed build.
function M.selection_changed()
  local pending = pending_action
  if not pending or pending.checking then return end
  pending.checking = true
  vim.schedule(function()
    if pending_action ~= pending then return end
    pending.checking = nil
    if not source_valid(pending) then pending_action = nil; return end
    local target = M.target()
    local runtime = runtime_identity(target)
    if pending.project and (target.project ~= pending.project
      or target.project_root ~= pending.project_root or target.engine_root ~= pending.engine_root) then
      pending_action = nil; return
    end
    pending_action = nil
    vim.ui.select({ "继续 " .. pending.action.label, "取消" }, {
      prompt = "配置已更新：" .. M.target_summary(target) .. "，继续原操作？",
    }, function(choice)
      if choice and choice ~= "取消" and source_valid(pending) then
        local current = M.target()
        if not vim.deep_equal(current, target) or not vim.deep_equal(runtime_identity(current), runtime) then return end
        M.invoke_action(pending.action, { source_win = pending.win })
      end
    end)
  end)
end

function M.invoke_action(action, opts)
  opts = opts or {}
  intent_epoch = intent_epoch + 1
  pending_action = nil
  local win = opts.source_win or vim.api.nvim_get_current_win()
  if not vim.api.nvim_win_is_valid(win) then
    return
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local epoch, tick, name = intent_epoch, vim.api.nvim_buf_get_changedtick(buf), vim.api.nvim_buf_get_name(buf)
  local source = {
    epoch = epoch,
    win = win,
    buf = buf,
    tick = tick,
    name = name,
    tab = vim.api.nvim_win_get_tabpage(win),
    cursor = vim.api.nvim_win_get_cursor(win),
  }
  local target = opts.target or M.target()
  local state = M.action_state(action, target, { buf = buf })
  if state.ready then
    vim.api.nvim_set_current_win(win)
    if
      not source_valid(source)
      or vim.api.nvim_get_current_win() ~= win
      or not vim.deep_equal(opts.target or M.target(), target)
    then
      return
    end
    return action.run()
  end
  vim.ui.select({ "配置/检查：" .. state.fix, "取消" }, {
    prompt = state.reason .. " — " .. action.label,
  }, function(choice)
    if
      not choice
      or choice == "取消"
      or epoch ~= intent_epoch
      or not vim.api.nvim_win_is_valid(win)
      or vim.api.nvim_win_get_buf(win) ~= buf
      or vim.api.nvim_buf_get_name(buf) ~= name
      or vim.api.nvim_buf_get_changedtick(buf) ~= tick
    then
      return
    end
    local pending = {
      action = action,
      win = win,
      buf = buf,
      name = name,
      epoch = epoch,
      tick = tick,
      project = target.project,
      project_root = target.project_root,
      engine_root = target.engine_root,
    }
    pending_action = pending
    -- A single bounded expiry, not polling. It never invokes the action.
    vim.defer_fn(function()
      if pending_action == pending then
        pending_action = nil
      end
    end, 60000)
    vim.api.nvim_set_current_win(win)
    vim.cmd(state.fix)
  end)
end

local function pick(items, prompt, format, on_choice)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    return snacks.picker.pick({
      title = prompt,
      items = vim.tbl_map(function(item)
        return { text = format(item), data = item }
      end, items),
      format = "text",
      preview = "none",
      layout = { preset = "vscode" },
      confirm = function(picker, choice)
        if picker.closed then
          return
        end
        local closed, err = pcall(picker.close, picker)
        if not closed then
          vim.notify("未能关闭动作列表，操作已取消: " .. tostring(err), vim.log.levels.WARN)
          return
        end
        if choice then
          vim.schedule(function()
            on_choice(choice.data)
          end)
        end
      end,
    })
  end
  vim.ui.select(items, { prompt = prompt, format_item = format }, function(choice)
    if choice then
      on_choice(choice)
    end
  end)
end

--- Searchable hub: grouped actions with their keys shown for learning.
function M.command_hub()
  intent_epoch = intent_epoch + 1
  pending_action = nil
  local target = M.target()
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local source = {
    epoch = intent_epoch,
    win = source_win,
    buf = source_buf,
    name = vim.api.nvim_buf_get_name(source_buf),
    tick = vim.api.nvim_buf_get_changedtick(source_buf),
    tab = vim.api.nvim_get_current_tabpage(),
    cursor = vim.api.nvim_win_get_cursor(source_win),
  }
  local runtime = runtime_identity(target)
  return pick(
    M.visible_actions(target, { buf = source_buf }),
    "UE  " .. M.target_summary(target),
    M.format_action,
    function(action)
      if
        not source_valid(source)
        or vim.api.nvim_get_current_win() ~= source_win
        or vim.api.nvim_get_current_tabpage() ~= source.tab
      then
        return
      end
      local current = M.target()
      if not vim.deep_equal(current, target) or not vim.deep_equal(runtime_identity(current), runtime) then
        return
      end
      M.invoke_action(action, { source_win = source_win })
    end
  )
end

function M.target_summary(target)
  local parts = { target.project or "no project" }
  if target.platform ~= "" then
    parts[#parts + 1] = target.platform .. (target.configuration ~= "" and (" " .. target.configuration) or "")
  end
  for _, field in ipairs(target_hub(target).fields or {}) do
    if not field.doctor_only then parts[#parts + 1] = field.value or ("no " .. field.name) end
  end
  return table.concat(parts, " · ")
end

--- Rows for the target switcher: generic project/platform plus target fields.
function M.target_rows(target)
  local rows = {
    { label = "Project", value = target.project or "(none)", run = cmd("UESetProject") },
    { label = "Platform", value = (target.platform ~= "" and target.platform or "(auto)")
      .. (target.configuration ~= "" and (" " .. target.configuration) or ""), run = cmd("UESetPlatform") },
  }
  for _, field in ipairs(target_hub(target).fields or {}) do
    if not field.doctor_only and field.command then
      rows[#rows + 1] = { label = field.label, value = field.value or "(none)", run = cmd(field.command) }
    end
  end
  return rows
end

function M.target_switcher()
  local target = M.target()
  pick(M.target_rows(target), "UE target", function(row)
    return ("%-9s %s"):format(row.label, row.value)
  end, function(row) row.run() end)
end

--- F5 when no debug session: run the target's own loop when it declares one,
--- otherwise launch under the debugger. In a session F5 stays "continue".
function M.run_or_debug()
  local ok_dap, dap = pcall(require, "dap")
  if ok_dap and dap.session and dap.session() then
    return vim.cmd("UEDAPContinue")
  end
  local contribution = target_hub(M.target())
  local profiles = package.loaded["ue.run_profiles"]
  if profiles and profiles.mode and profiles.mode() == "run" then
    return vim.cmd(contribution.run_command or "UELaunch")
  end
  return vim.cmd(contribution.loop_command or "UEDAPLaunch")
end

-- ── one-key fix for the last failure ───────────────────────────────────────
M._pending_fix = nil

--- Remember the command that remedies the most recent failure.
function M.offer_fix(command, reason)
  M._pending_fix = { command = command, reason = reason }
end

--- Run (and consume) the pending fix. Returns the command that ran, or nil.
function M.run_fix()
  local fix = M._pending_fix
  if not fix then
    vim.notify("No pending fix — nothing failed recently", vim.log.levels.INFO)
    return nil
  end
  M._pending_fix = nil
  vim.cmd(fix.command)
  return fix.command
end

--- Compact debug indicator for the statusline: empty without a session.
--- Reads only in-memory state (cheap enough for every redraw).
function M.debug_indicator()
  local loaded = package.loaded["dap"]
  if not loaded or not loaded.session or not loaded.session() then return "" end
  local state = (package.loaded["ue.dap"] or {})._dap_run_state
  local icon = ({ stopped = "⏸ DBG", running = "▶ DBG", attaching = "… DBG", resuming = "▶ DBG" })[state]
  return icon or "● DBG"
end

-- ── doctor ─────────────────────────────────────────────────────────────────

--- One-shot environment check. Each row: { name, ok, detail, fix? }.
function M.doctor_rows(target)
  local plat = require("utils.platform")
  local rows = {}
  local function tool(name, env, candidates)
    local found = plat.resolve_tool({ name = name, env = env, driver_candidates = candidates })
    rows[#rows + 1] = { name = name, ok = found.ok, detail = found.ok and found.path or "not found" }
  end
  tool("clangd", { "UE_CLANGD" }, function(d) return d.default_clangd_candidates() end)
  tool("python", { "UE_PYTHON" }, function(d) return d.python_candidates() end)
  tool("rg", nil, { "rg" })
  rows[#rows + 1] = { name = "project", ok = target.project ~= nil, detail = target.project or "none",
    fix = "UESetProject" }
  rows[#rows + 1] = { name = "platform", ok = target.platform ~= "", detail = target.platform ~= "" and target.platform or "not set",
    fix = "UESetPlatform" }
  for _, field in ipairs(target_hub(target).fields or {}) do
    rows[#rows + 1] = { name = field.name, ok = field.value ~= nil,
      detail = field.value or (field.command and "not set" or "not found"), fix = field.command,
      check = field.value ~= nil and field.check or nil }
  end
  return rows
end

function M.format_doctor_row(row)
  return ("%s %-9s %s%s"):format(row.ok and "✓" or "✗", row.name, row.detail,
    (not row.ok and row.fix) and ("   → :" .. row.fix) or "")
end

-- Rows with an async `check` (e.g. a selected device that may be unplugged)
-- render first, then their line is rewritten in place when the check returns.
local function run_doctor_checks(buf, rows, first_line)
  for i, row in ipairs(rows) do
    if row.check then
      row.check(function(ok, detail)
        if not vim.api.nvim_buf_is_valid(buf) then return end
        local updated = vim.tbl_extend("force", row, { ok = ok,
          detail = ok and row.detail or (row.detail .. " — " .. tostring(detail)) })
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(buf, first_line + i - 1, first_line + i, false, { M.format_doctor_row(updated) })
        vim.bo[buf].modifiable = false
      end)
    end
  end
end

function M.doctor()
  local target = M.target()
  local rows = M.doctor_rows(target)
  local lines, fixes = { "UE doctor — " .. M.target_summary(target), "" }, {}
  for _, row in ipairs(rows) do
    lines[#lines + 1] = M.format_doctor_row(row)
    if not row.ok and row.fix then fixes[#fixes + 1] = row end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Debugger layers: :UEDAPPreflight   ·   editor audit: :NvimCoreHealth"
  lines[#lines + 1] = "<CR> on a ✗ row runs its fix"
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe"
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  vim.api.nvim_win_set_height(0, math.min(#lines + 1, 16))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<CR>", function()
    local line = vim.api.nvim_get_current_line()
    local fix = line:match("→ :(%S+)")
    if fix then vim.cmd("close"); vim.cmd(fix) end
  end, { buffer = buf, nowait = true })
  run_doctor_checks(buf, rows, 2)
end

--- Register the keyboard-first entry commands (kept out of ue.lua, whose
--- size is ratcheted down).
--- Open the long-lived user guide (docs/USER_GUIDE.md) read-only in a tab.
function M.guide_path()
  return vim.fs.joinpath(vim.fn.stdpath("config"), "docs", "USER_GUIDE.md")
end

function M.open_guide()
  local path = M.guide_path()
  if vim.fn.filereadable(path) ~= 1 then
    vim.notify("使用手册不存在: " .. path, vim.log.levels.ERROR)
    return nil
  end
  vim.cmd("tabedit " .. vim.fn.fnameescape(path))
  vim.bo.readonly = true
  return path
end

function M.setup_commands()
  require("utils.workspace").setup_commands()
  require("utils.session_restore").setup_commands()
  require("utils.edit_recovery").setup_commands()
  require("utils.lsp_fallback").setup_refactor_commands()
  require("utils.ue_entities").setup_commands()
  require("ue.editor_tests").setup_commands()
  local create = vim.api.nvim_create_user_command
  create("UEGuide", function() M.open_guide() end,
    { desc = "Open the user guide: daily workflow, keys, troubleshooting" })
  create("UEHub", function() M.command_hub() end,
    { desc = "Searchable hub of every UE action for the active target" })
  create("UETarget", function() M.target_switcher() end,
    { desc = "Show and switch the active project / platform / device / package" })
  create("UEDoctor", function() M.doctor() end,
    { desc = "Check tools, target, device and package; <CR> on a failed row runs its fix" })
  create("UESearchHistory", function()
    require("utils.history_hub").searches()
  end, { desc = "Search history for this project (used searches first)" })
  create("UEAndroidCrash", function() require("ue.dap._android_crash").run() end,
    { desc = "Android: symbolicate the latest native crash from the device into quickfix" })
end

return M
