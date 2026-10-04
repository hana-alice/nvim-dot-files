-- One bottom split per tab. Switching content never starts jobs or log readers.
local M = {}
local tabs = {}
local KEEP_BUILD_LOGS = 16
local order = { "build", "quickfix", "logcat", "tasks" }
local labels = { build = "构建输出", quickfix = "问题", logcat = "Logcat", tasks = "后台任务", debug = "调试" }
local empty = {
  build = "尚无构建输出；先运行构建。",
  quickfix = "当前 quickfix 没有问题。",
  logcat = "尚未启动 Logcat；按 <leader>ug 或 d4 启动读取。",
  debug = "尚无调试输出；先启动调试。",
}

local function valid_buf(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

local function state()
  for tab, old in pairs(tabs) do
    if not vim.api.nvim_tabpage_is_valid(tab) then
      local live
      for _, row in ipairs(old.build_logs or {}) do
        if valid_buf(row.buf) then
          local channel = vim.bo[row.buf].channel
          if channel > 0 and vim.fn.jobwait({ channel }, 0)[1] == -1 then
            live = true
          elseif #vim.fn.win_findbuf(row.buf) == 0 and vim.bo[row.buf].buftype ~= "" then
            pcall(vim.api.nvim_buf_delete, row.buf, { force = true })
          end
        end
      end
      if not live then
        tabs[tab] = nil
      end
    end
  end
  local tab = vim.api.nvim_get_current_tabpage()
  tabs[tab] = tabs[tab] or { buffers = {}, placeholders = {}, views = {} }
  local s = tabs[tab]
  for kind, buf in pairs(s.buffers) do
    if not valid_buf(buf) then
      s.buffers[kind], s.views[buf] = nil, nil
    end
  end
  return s, tab
end

local function normal_win(win, tab)
  return win and vim.api.nvim_win_is_valid(win)
    and vim.api.nvim_win_get_tabpage(win) == tab
    and vim.api.nvim_win_get_config(win).relative == ""
end

local function panel_win(win, tab)
  if not normal_win(win, tab) then return false end
  local buf = vim.api.nvim_win_get_buf(win)
  if vim.b[buf].ue_bottom_panel_kind then return true end
  local info = vim.fn.getwininfo(win)[1]
  return info and info.quickfix == 1 and info.loclist == 0
end

local function save_view(s, win)
  if vim.api.nvim_win_is_valid(win) then
    local buf = vim.api.nvim_win_get_buf(win)
    s.views[buf] = vim.api.nvim_win_call(win, vim.fn.winsaveview)
  end
end

local function scratch(kind, s, tab)
  local buf = s.placeholders[kind]
  if not valid_buf(buf) then
    buf = vim.api.nvim_create_buf(false, true)
    s.placeholders[kind] = buf
    vim.api.nvim_buf_set_name(buf, "ue-panel://" .. tab .. "/" .. kind)
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].filetype = "ue_panel"
    vim.b[buf].ue_bottom_panel_kind = kind
  end
  return buf
end

local function set_lines(buf, lines)
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].modified = false
end

local function placeholder(kind, s, tab)
  local buf = scratch(kind, s, tab)
  set_lines(buf, { labels[kind], "", empty[kind] or "尚无内容。" })
  return buf
end

local function tasks_buffer(s, tab)
  local buf = scratch("tasks", s, tab)
  local registry = require("utils.task_registry")
  local rows = registry.list()
  local lines, ids = { "后台任务  ·  <CR>/dd 停止当前任务  ·  r 刷新", "" }, {}
  for _, row in ipairs(rows) do
    local result = row.result == "unknown" and "done (exit unknown)" or row.result or row.status
    local code = row.code ~= nil and (" exit=" .. row.code) or ""
    lines[#lines + 1] = string.format(
      "%d  %s%s  [%s]  %s",
      row.id,
      result,
      code,
      tostring(row.group):gsub("[\r\n]", " "),
      tostring(row.name):gsub("[\r\n]", " ")
    )
    ids[#lines] = row.id
  end
  if #rows == 0 then
    lines[#lines + 1] = "没有后台任务。"
  end
  set_lines(buf, lines)
  local refresh = function()
    if valid_buf(buf) then
      tasks_buffer(s, tab)
    end
  end
  local stop = function()
    local id = ids[vim.api.nvim_win_get_cursor(0)[1]]
    if id then
      local stopped = registry.cancel(id)
      vim.notify(stopped and ("已停止任务 " .. id) or "该任务已经结束", vim.log.levels.INFO)
      refresh()
    end
  end
  for _, key in ipairs({ "<CR>", "dd" }) do
    vim.keymap.set("n", key, stop, { buffer = buf, silent = true, desc = "停止当前后台任务" })
  end
  vim.keymap.set("n", "r", refresh, { buffer = buf, silent = true, desc = "刷新后台任务" })
  return buf
end

local function quickfix_buffer(s, tab)
  local qf = vim.fn.getqflist({ size = 0, qfbufnr = 0 })
  if qf.size == 0 then return placeholder("quickfix", s, tab) end
  local buf = qf.qfbufnr
  if not valid_buf(buf) or not vim.api.nvim_buf_is_loaded(buf) then
    local previous = vim.api.nvim_get_current_win()
    -- :copen creates the native buffer and its normal <CR> jump behavior.
    vim.cmd("botright copen")
    buf = vim.api.nvim_get_current_buf()
    if vim.api.nvim_win_is_valid(previous) then vim.api.nvim_set_current_win(previous) end
  end
  M.register("quickfix", buf)
  return buf
end

--- Register content in the current tab; hiding its window must preserve jobs.
function M.register(kind, buf)
  if not labels[kind] or not valid_buf(buf) then
    return false
  end
  local s, tab = state()
  s.buffers[kind] = buf
  vim.bo[buf].bufhidden = "hide"
  vim.b[buf].ue_bottom_panel_kind = kind
  if kind == "build" then
    s.build_logs = s.build_logs or {}
    local found
    for _, row in ipairs(s.build_logs) do
      if row.buf == buf then
        found = true
        break
      end
    end
    if not found then
      table.insert(s.build_logs, 1, { buf = buf, title = vim.b[buf].ue_build_title or "构建输出" })
      M.build_history()
    end
    vim.keymap.set("n", "gH", M.show_build_history, { buffer = buf, desc = "选择阶段构建日志" })
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if normal_win(win, tab) and vim.api.nvim_win_get_buf(win) == buf then
      if not s.win or s.win == win then
        s.win, s.kind = win, kind
      end
    end
  end
  return true
end

--- Bounded history in this tab. Live terminals and visible logs are protected.
function M.build_history()
  local s = state()
  local rows, retained = {}, 0
  for _, row in ipairs(s.build_logs or {}) do
    if valid_buf(row.buf) then
      local channel = vim.bo[row.buf].channel
      local live = channel > 0 and vim.fn.jobwait({ channel }, 0)[1] == -1
      local visible = #vim.fn.win_findbuf(row.buf) > 0
      if live or visible or retained < KEEP_BUILD_LOGS then
        rows[#rows + 1] = row
        if not live then
          retained = retained + 1
        end
      else
        s.views[row.buf] = nil
        if vim.bo[row.buf].buftype ~= "" then
          pcall(vim.api.nvim_buf_delete, row.buf, { force = true })
        end
      end
    end
  end
  s.build_logs = rows
  return vim.deepcopy(rows)
end

function M.show_build_history()
  local rows = M.build_history()
  if #rows == 0 then
    vim.notify("尚无阶段构建日志", vim.log.levels.INFO)
    return
  end
  local _, tab = state()
  vim.ui.select(rows, {
    prompt = "构建 / 部署阶段日志：",
    format_item = function(row)
      return row.title
    end,
  }, function(row)
    if row and valid_buf(row.buf) and vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      M.show("build", row.buf)
    end
  end)
end

--- Managed bottom window in this tab, or nil after manual close/replacement.
function M.window()
  local s, tab = state()
  if panel_win(s.win, tab) then return s.win end
  s.win = nil
  return nil
end

--- Show content in the one bottom host. opts.focus defaults to true.
---@return integer|nil win
function M.show(kind, buf, opts)
  if not labels[kind] then return nil end
  opts = opts or {}
  local s, tab = state()
  if buf ~= nil then M.register(kind, buf) end
  local target
  if kind == "quickfix" then
    target = quickfix_buffer(s, tab)
  elseif kind == "tasks" then
    target = tasks_buffer(s, tab)
  else
    target = s.buffers[kind] or placeholder(kind, s, tab)
  end
  local previous = vim.api.nvim_get_current_win()
  local win = M.window()
  local adopted = not win
  if not win then
    local bottom = -1
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if panel_win(candidate, tab) then
        local row = vim.api.nvim_win_get_position(candidate)[1]
        if row > bottom then win, bottom = candidate, row end
      end
    end
  end
  if win then
    save_view(s, win)
    vim.api.nvim_win_set_buf(win, target)
    -- Adoption moves an existing panel to the full-width bottom without
    -- touching ordinary editing windows, floats, or another tab's panels.
    if adopted then vim.api.nvim_win_call(win, function() vim.cmd("wincmd J") end) end
  else
    win = vim.api.nvim_open_win(target, false, { split = "below", win = -1, height = opts.height or 12 })
  end
  s.win, s.kind = win, kind
  for _, duplicate in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if duplicate ~= win and panel_win(duplicate, tab) then
      save_view(s, duplicate)
      vim.api.nvim_win_close(duplicate, true)
    end
  end
  if opts.height then vim.api.nvim_win_set_height(win, math.max(1, opts.height)) end
  vim.wo[win].winfixheight = true
  vim.wo[win].winbar = ""
  vim.wo[win].number, vim.wo[win].relativenumber = false, false
  vim.wo[win].wrap, vim.wo[win].spell, vim.wo[win].list = false, false, false
  vim.wo[win].signcolumn, vim.wo[win].foldcolumn, vim.wo[win].colorcolumn = "no", "0", ""
  local names = {}
  for _, name in ipairs(order) do
    names[#names + 1] = name == kind and ("[" .. labels[name] .. "]") or labels[name]
  end
  if kind == "debug" then names[#names + 1] = "[调试]" end
  vim.wo[win].statusline = " " .. table.concat(names, " | ")
  -- Restore only on an explicit panel switch, never via BufEnter guards.
  local view = s.views[target]
  if view then
    local restored = vim.deepcopy(view)
    local count = vim.api.nvim_buf_line_count(target)
    restored.lnum, restored.topline = math.min(restored.lnum, count), math.min(restored.topline, count)
    vim.api.nvim_win_call(win, function() vim.fn.winrestview(restored) end)
  end
  if opts.focus ~= false then
    vim.api.nvim_set_current_win(win)
  elseif vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  return win
end

--- Build → problems → logcat → tasks. Debug is deliberately outside the cycle.
function M.cycle()
  local s = state()
  local current = 0
  for index, kind in ipairs(order) do
    if s.kind == kind then current = index
break end
  end
  return M.show(order[current % #order + 1])
end

--- Remove only this registration, leaving newer readers/content untouched.
function M.remove(kind, buf)
  if buf == nil then return false end
  local s, tab = state()
  local registered = s.buffers[kind]
  if not registered or (buf ~= nil and registered ~= buf) then return false end
  s.buffers[kind], s.views[registered] = nil, nil
  local win = M.window()
  if win and vim.api.nvim_win_get_buf(win) == registered then
    vim.api.nvim_win_set_buf(win, placeholder(kind, s, tab))
  end
  return true
end

function M.setup_commands()
  vim.api.nvim_create_user_command("UEPanel", function(args)
    if args.args == "history" then M.show_build_history()
    elseif args.args == "" then M.cycle() else M.show(args.args) end
  end, {
    nargs = "?",
    complete = function() return vim.list_extend(vim.deepcopy(order), { "history" }) end,
    desc = "切换底部面板：build/quickfix/logcat/tasks/history",
    force = true,
  })
  vim.api.nvim_create_user_command("UEPanelNext", M.cycle, { desc = "循环切换底部面板", force = true })
end

function M._reset_for_test()
  tabs = {}
end

return M
