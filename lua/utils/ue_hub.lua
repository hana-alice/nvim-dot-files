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

local function cmd(name) return function() vim.cmd(name) end end

-- Reuse the attached buffer's actual key callback, including capability guards.
-- A hub picker may change the current buffer; capture its source window first.
local function code_key(key)
  return function()
    if #vim.lsp.get_clients({ bufnr = 0, name = "clangd" }) == 0 then
      vim.notify("C++ 导航需要当前文件已附加 clangd", vim.log.levels.WARN)
      return
    end
    local mapping = vim.fn.maparg(key, "n", false, true)
    if type(mapping.callback) == "function" then return mapping.callback() end
    vim.notify("当前 clangd 未提供此动作: " .. key, vim.log.levels.WARN)
  end
end

--- Generic actions: { group, label, key?, run }. Target-specific actions and
--- fields come from the active target driver's declarative `hub(state)`.
M.actions = {
  { group = "Run",    label = "Run / debug current target (F5 when idle)", key = "<F5>", run = function() M.run_or_debug() end },
  { group = "Run",    label = "Launch app (no debugger)", key = "<leader>ul", run = cmd("UELaunch") },
  { group = "Code", label = "Incoming calls / 谁调用了它", key = "<leader>cI", run = code_key("<leader>cI") },
  { group = "Code", label = "Outgoing calls / 它调用了谁", key = "<leader>cO", run = code_key("<leader>cO") },
  { group = "Code", label = "Workspace symbols / 类名、函数名", key = "<leader>sS", run = code_key("<leader>sS") },
  { group = "Code", label = "Document symbols / 当前文件大纲", key = "<leader>ss", run = code_key("<leader>ss") },
  { group = "Code", label = "Base types / 基类", key = "<leader>cB", run = code_key("<leader>cB") },
  { group = "Code", label = "Derived types / 派生类", key = "<leader>cD", run = code_key("<leader>cD") },
  { group = "Code", label = "Rename symbol / 重命名", key = "<leader>cr", run = code_key("<leader>cr") },
  { group = "Code", label = "Code action / 代码操作", key = "<leader>ca", run = code_key("<leader>ca") },
  { group = "Build",  label = "Build active target", key = "<leader>ub", run = cmd("UEBuild") },
  { group = "Build",  label = "First build error / 首个构建错误", key = "<leader>uE", run = cmd("UEBuildFirstError") },
  { group = "Build",  label = "Install app on device", key = "<leader>ui", run = cmd("UEInstall") },
  { group = "Debug",  label = "Attach debugger", key = "<leader>da", run = cmd("UEDAPAttach") },
  { group = "Debug",  label = "Launch under debugger (wait-for-debugger)", key = "<leader>dl", run = cmd("UEDAPLaunch") },
  { group = "Debug",  label = "Reattach to restarted app", run = cmd("UEDAPReattach") },
  { group = "Debug",  label = "Stop debug session", key = "<S-F5>", run = cmd("UEDAPStop") },
  { group = "Debug",  label = "Debugger preflight (why would attach fail?)", run = cmd("UEDAPPreflight") },
  { group = "Logs",   label = "Toggle app log", key = "<leader>ug", run = cmd("UELogToggle") },
  { group = "Logs",   label = "Logcat (debug panel tab)", key = "<leader>d4", run = cmd("UEDAPTab logcat") },
  { group = "Logs",   label = "Notification history", key = "<leader>uN", run = cmd("NotificationHistory") },
  { group = "Target", label = "Switch target (project/platform/device/package)", key = "<leader>uu", run = function() M.target_switcher() end },
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
}

local function target_hub(target)
  local driver = require("ue.targets").driver(target.platform)
  if driver and type(driver.hub) == "function" then
    local ok, contribution = pcall(driver.hub, target.state or {})
    if ok and type(contribution) == "table" then return contribution end
  end
  return { actions = {}, fields = {} }
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
    engine_root = ctx and ctx.engine_root or nil,
    platform = trim(state.target_platform),
    configuration = trim(state.target_configuration),
    state = state,
  }
end

--- Actions visible for a target: target-owned actions join their groups
--- after the generic ones.
function M.visible_actions(target)
  local out = {}
  for _, action in ipairs(M.actions) do out[#out + 1] = action end
  for _, action in ipairs(target_hub(target).actions or {}) do
    out[#out + 1] = { group = action.group, label = action.label, key = action.key, run = cmd(action.command) }
  end
  local first, rank = {}, {}
  for index, action in ipairs(out) do
    first[action.group] = first[action.group] or index
    rank[action] = first[action.group] * 1000 + index
  end
  table.sort(out, function(x, y) return rank[x] < rank[y] end)
  return out
end

function M.format_action(action)
  local key = action.key and ("  " .. action.key) or ""
  return ("%-7s %s%s"):format(action.group, action.label, key)
end

local function pick(items, prompt, format, on_choice)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    return snacks.picker.pick({
      title = prompt,
      items = vim.tbl_map(function(item) return { text = format(item), data = item } end, items),
      format = "text",
      preview = "none",
      layout = { preset = "vscode" },
      confirm = function(picker, choice)
        picker:close()
        if choice then vim.schedule(function() on_choice(choice.data) end) end
      end,
    })
  end
  vim.ui.select(items, { prompt = prompt, format_item = format }, function(choice)
    if choice then on_choice(choice) end
  end)
end

--- Searchable hub: grouped actions with their keys shown for learning.
function M.command_hub()
  local target = M.target()
  local source_win = vim.api.nvim_get_current_win()
  pick(M.visible_actions(target), "UE  " .. M.target_summary(target), M.format_action,
    function(action)
      if not vim.api.nvim_win_is_valid(source_win) then return end
      vim.api.nvim_set_current_win(source_win)
      action.run()
    end)
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
  local loop = target_hub(M.target()).loop_command
  return vim.cmd(loop or "UEDAPLaunch")
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
function M.setup_commands()
  local create = vim.api.nvim_create_user_command
  create("UEHub", function() M.command_hub() end,
    { desc = "Searchable hub of every UE action for the active target" })
  create("UETarget", function() M.target_switcher() end,
    { desc = "Show and switch the active project / platform / device / package" })
  create("UEDoctor", function() M.doctor() end,
    { desc = "Check tools, target, device and package; <CR> on a failed row runs its fix" })
  create("UESearchHistory", function()
    require("utils.history_hub").searches({
      rerun = function(query) require("ue").cached_grep({ search = query }) end,
    })
  end, { desc = "Search history for this project (used searches first)" })
  create("UEAndroidCrash", function() require("ue.dap._android_crash").run() end,
    { desc = "Android: symbolicate the latest native crash from the device into quickfix" })
end

return M
