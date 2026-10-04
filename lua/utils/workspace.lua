-- Explicitly recover views after <C-w>q. Neovim owns the buffers, quickfix
-- history and jobs; this entry only queries those owners when opened/refreshed.
local M = {}
local categories = { "all", "windows", "buffers", "results", "tasks", "logs" }
local PIN_ROWS, PIN_BYTES = 5000, 8 * 1024 * 1024

local function text(value)
  return tostring(value or ""):gsub("[%z\1-\31\127]", " ")
end

local function valid_buf(buf)
  return type(buf) == "number" and buf > 0 and vim.api.nvim_buf_is_valid(buf)
end

local function picker_buf(buf)
  return vim.bo[buf].filetype:match("^snacks_picker") ~= nil
end

local function name(buf)
  local title, path = vim.b[buf].ue_build_title, vim.api.nvim_buf_get_name(buf)
  return text(title or (path ~= "" and path or ("[No Name] #" .. buf)))
end

local function normal_win(win)
  return vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative == ""
end

local function editing_win(win)
  return normal_win(win) and vim.bo[vim.api.nvim_win_get_buf(win)].buftype == ""
end

local function buffer_row(buf, kind)
  return { kind = kind, buf = buf, name = vim.api.nvim_buf_get_name(buf), panel = vim.b[buf].ue_bottom_panel_kind }
end

local function qf_info(id)
  local info = vim.fn.getqflist({ id = id, nr = 0, size = 0, title = 0, context = 0 })
  return info.id == id and info or nil
end

local function select_qf(id)
  local info = qf_info(id)
  if not info then
    return nil, "结果已被原生 quickfix 历史淘汰；请重新搜索。"
  end
  vim.cmd("silent chistory " .. info.nr)
  return info
end

local function quickfix_views()
  local views = {}
  for _, info in ipairs(vim.fn.getwininfo()) do
    if info.quickfix == 1 and info.loclist == 0 and vim.api.nvim_win_is_valid(info.winid) then
      views[#views + 1] = {
        win = info.winid,
        tab = vim.api.nvim_win_get_tabpage(info.winid),
        buf = vim.api.nvim_win_get_buf(info.winid),
        view = vim.api.nvim_win_call(info.winid, vim.fn.winsaveview),
      }
    end
  end
  return views
end

local function restore_quickfix_views(views, id)
  for _, row in ipairs(views) do
    if
      vim.fn.getqflist({ id = 0 }).id == id
      and vim.api.nvim_win_is_valid(row.win)
      and vim.api.nvim_tabpage_is_valid(row.tab)
      and vim.api.nvim_win_get_tabpage(row.win) == row.tab
      and vim.api.nvim_win_get_buf(row.win) == row.buf
    then
      vim.api.nvim_win_call(row.win, function()
        vim.fn.winrestview(row.view)
      end)
    end
  end
end

--- Save, without opening/closing/focusing any window. Native history is bounded
--- by Neovim (ten lists); the context describes partial results honestly.
---@return integer? id, string? err
function M.pin(items, opts)
  opts = opts or {}
  if type(items) ~= "table" or #items == 0 then
    return nil, "没有可保存的结果。"
  end
  if #items > PIN_ROWS then
    return nil, "结果超过 5000 行保存预算；请收窄搜索。"
  end
  local current = vim.fn.getqflist({ id = 0, nr = 0 })
  local previous = current.id
  local last = vim.fn.getqflist({ nr = "$" }).nr
  -- Appending to a full native stack evicts its oldest list. Refuse before
  -- even selecting the newest list when that victim is the user's active one.
  if last and last >= 10 and current.nr == 1 then
    return nil,
      "quickfix 历史已满 10 条，保存会淘汰当前结果；本次未保存，请先显式切换结果。"
  end
  local bytes = 0
  local saved = {}
  for _, item in ipairs(items) do
    if type(item) ~= "table" then
      return nil, "结果项格式无效。"
    end
    local copy = {}
    for _, key in ipairs({
      "filename",
      "bufnr",
      "lnum",
      "end_lnum",
      "col",
      "end_col",
      "vcol",
      "nr",
      "type",
      "text",
      "valid",
    }) do
      copy[key] = item[key]
      if type(item[key]) == "string" then
        bytes = bytes + #item[key]
      end
    end
    saved[#saved + 1] = copy
  end
  if bytes > PIN_BYTES then
    return nil, "结果超过 8 MiB 保存预算；请收窄搜索。"
  end
  local recipe
  if opts.recipe then
    local ok, encoded = pcall(vim.json.encode, opts.recipe)
    if not ok or #encoded > 8192 then
      return nil, "搜索条件格式无效或超过保存预算。"
    end
    recipe = vim.json.decode(encoded)
  end
  local context = {
    kind = "ue_workspace_pin",
    version = 1,
    source = vim.fn.strcharpart(text(opts.source), 0, 256),
    recipe = recipe,
    truncated = opts.truncated == true,
  }
  -- Native history switches reset visible qf cursors to its selected item.
  -- Preserve only views owned by this synchronous save, never BufEnter guards.
  local views = quickfix_views()
  if last and last > 0 then
    vim.cmd("silent chistory " .. last)
  end
  local ok, result = pcall(vim.fn.setqflist, {}, " ", {
    title = vim.fn.strcharpart(text(opts.title ~= nil and opts.title or "Saved search results"), 0, 512),
    items = saved,
    context = context,
  })
  local id = ok and result == 0 and vim.fn.getqflist({ id = 0 }).id or nil
  if previous and previous > 0 and qf_info(previous) then
    select_qf(previous)
    restore_quickfix_views(views, previous)
  end
  if not id then
    return nil, "无法保存 quickfix 结果：" .. tostring(result)
  end
  return id
end

--- A fresh view of native ownership, including every tab; no persisted rows.
function M.list(opts)
  opts = opts or {}
  local category = opts.category or "all"
  local rows, visible = {}, {}
  local current_tab = vim.api.nvim_get_current_tabpage()
  local current_qf = vim.fn.getqflist({ id = 0 }).id
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      visible[buf] = true
      if not picker_buf(buf) then
        local row = buffer_row(buf, "window")
        row.win, row.tab = win, tab
        local info = vim.fn.getwininfo(win)[1]
        if info and info.quickfix == 1 and info.loclist == 0 then
          row.qf_id = current_qf
        end
        row.text = ("Windows 窗口 · tab %d%s / win %d · %s%s"):format(
          vim.api.nvim_tabpage_get_number(tab),
          tab == current_tab and " current" or "",
          win,
          vim.bo[buf].modified and "[modified 未保存] " or "",
          name(buf)
        )
        rows[#rows + 1] = row
      end
    end
  end
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and not picker_buf(buf) then
      local panel, bt = vim.b[buf].ue_bottom_panel_kind, vim.bo[buf].buftype
      local log = bt == "terminal" or panel == "build" or panel == "logcat" or panel == "debug"
      if log or (not visible[buf] and bt == "" and (vim.bo[buf].buflisted or vim.bo[buf].modified)) then
        local row = buffer_row(buf, log and "log" or "buffer")
        row.text = ("%s · %s%s · %s"):format(
          log and "Logs 日志" or "Buffers 缓冲区",
          visible[buf] and "visible 已显示" or "hidden 窗口已关闭",
          vim.bo[buf].modified and " / modified 未保存" or "",
          name(buf)
        )
        rows[#rows + 1] = row
      end
    end
  end
  local last = vim.fn.getqflist({ nr = "$" }).nr or 0
  for nr = last, 1, -1 do
    local info = vim.fn.getqflist({ nr = nr, id = 0, title = 0, size = 0, context = 0 })
    local context = type(info.context) == "table" and info.context or {}
    local source = context.kind == "ue_workspace_pin" and "saved 已保存" or "quickfix history"
    rows[#rows + 1] = {
      kind = "result",
      id = info.id,
      text = ("Results 结果 · #%d %s · %d rows%s · %s"):format(
        info.id,
        source,
        info.size,
        context.truncated and " / partial 已截断" or "",
        text(info.title)
      ),
    }
  end
  local registry = require("utils.task_registry")
  for _, task in ipairs(registry.list()) do
    local record = registry.get(task.id)
    if record then
      local buf
      if record.kind == "job" then
        for _, candidate in ipairs(vim.api.nvim_list_bufs()) do
          if
            vim.api.nvim_buf_is_loaded(candidate)
            and vim.bo[candidate].buftype == "terminal"
            and vim.bo[candidate].channel == record.handle
          then
            buf = candidate
            break
          end
        end
      end
      rows[#rows + 1] = {
        kind = "task",
        id = task.id,
        handle = record.handle,
        task_kind = record.kind,
        buf = buf,
        name = buf and vim.api.nvim_buf_get_name(buf) or nil,
        panel = buf and vim.b[buf].ue_bottom_panel_kind or nil,
        text = ("Tasks 任务 · #%d %s%s · [%s] %s · %s"):format(
          task.id,
          task.result == "unknown" and "done (exit unknown)" or task.result,
          task.code ~= nil and (" exit=" .. task.code) or "",
          text(task.group),
          text(task.name),
          buf and "Enter: output 日志 / Ctrl-X: stop 停止" or "Enter: task list / Ctrl-X: stop 停止"
        ),
      }
    end
  end
  if category ~= "all" then
    local kinds = { windows = "window", buffers = "buffer", results = "result", tasks = "task", logs = "log" }
    rows = vim.tbl_filter(function(row)
      return row.kind == kinds[category]
    end, rows)
  end
  return rows
end

local function task_record(row)
  local record = require("utils.task_registry").get(row.id)
  return record and record.handle == row.handle and record.kind == row.task_kind and record or nil
end

local function reopen(row, opts)
  if not valid_buf(row.buf) or vim.api.nvim_buf_get_name(row.buf) ~= row.name then
    return nil, "缓冲区已被删除或更名；按 Ctrl-R 刷新列表。"
  end
  -- Prefer an actual existing view, including another tab, before creating one.
  local current_tab = vim.api.nvim_get_current_tabpage()
  local windows = vim.fn.win_findbuf(row.buf)
  table.sort(windows, function(a, b)
    local ac, bc = vim.api.nvim_win_get_tabpage(a) == current_tab, vim.api.nvim_win_get_tabpage(b) == current_tab
    return ac ~= bc and ac or ac == bc and a < b
  end)
  for _, win in ipairs(windows) do
    if vim.api.nvim_win_is_valid(win) and not picker_buf(row.buf) then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end
  if row.panel == "build" or row.panel == "logcat" or row.panel == "debug" then
    return require("utils.bottom_panel").show(row.panel, row.buf)
  end
  local source = opts.source_win
  if not source or not editing_win(source) then
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
      if editing_win(win) then
        source = win
        break
      end
    end
  end
  if not source or not normal_win(source) then
    return nil, "没有可用于恢复视图的普通窗口。"
  end
  return vim.api.nvim_open_win(row.buf, true, { split = "right", win = source })
end

--- Confirm a row's native identity before any window or cancellation effect.
---@return integer? win, string? err
function M.activate(row, opts)
  opts = opts or {}
  if type(row) ~= "table" then
    return nil, "没有选择条目。"
  end
  if row.kind == "result" then
    local info, err = select_qf(row.id)
    if not info then
      return nil, err
    end
    return require("utils.bottom_panel").show("quickfix")
  elseif row.kind == "window" then
    if vim.api.nvim_win_is_valid(row.win) then
      if
        not vim.api.nvim_tabpage_is_valid(row.tab)
        or vim.api.nvim_win_get_tabpage(row.win) ~= row.tab
        or vim.api.nvim_win_get_buf(row.win) ~= row.buf
        or vim.api.nvim_buf_get_name(row.buf) ~= row.name
      then
        return nil, "窗口内容已变化；按 Ctrl-R 刷新列表。"
      end
      if row.qf_id and vim.fn.getqflist({ id = 0 }).id ~= row.qf_id then
        return nil, "窗口的结果列表已切换；按 Ctrl-R 刷新列表。"
      end
      vim.api.nvim_set_current_win(row.win)
      return row.win
    end
    if row.qf_id then
      return M.activate({ kind = "result", id = row.qf_id }, opts)
    end
    return reopen(row, opts)
  elseif row.kind == "task" then
    if not task_record(row) then
      return nil, "任务已被淘汰；按 Ctrl-R 刷新列表。"
    end
    if row.buf then
      return reopen(row, opts)
    end
    return require("utils.bottom_panel").show("tasks")
  elseif row.kind == "buffer" or row.kind == "log" then
    return reopen(row, opts)
  end
  return nil, "条目类型无效。"
end

--- Only the registry-owned handle captured by this task row can be stopped.
function M.stop(row)
  if type(row) ~= "table" or row.kind ~= "task" then
    return false, "请先选择一个后台任务。"
  end
  if not task_record(row) then
    return false, "任务已被淘汰；按 Ctrl-R 刷新列表。"
  end
  local stopped = require("utils.task_registry").cancel(row.id)
  if stopped then
    return true
  end
  return false, "该任务已经结束。"
end

function M.open(opts)
  if type(opts) == "string" then
    opts = { category = opts }
  end
  opts = opts or {}
  if opts.category and not vim.tbl_contains(categories, opts.category) then
    vim.notify("Workspace 分类：" .. table.concat(categories, ", "), vim.log.levels.WARN)
    return nil
  end
  local source_win = vim.api.nvim_get_current_win()
  local function confirm(row)
    local win, err = M.activate(row, { source_win = source_win })
    if not win then
      vim.notify(err, vim.log.levels.WARN)
    end
  end
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    return snacks.picker.pick({
      source = "ue_workspace",
      title = "Workspace 窗口 / 缓冲区 / 结果 / 任务 / 日志",
      finder = function()
        return vim.tbl_map(function(row)
          return { text = row.text, data = row }
        end, M.list(opts))
      end,
      format = "text",
      preview = "none",
      sort = function(a, b)
        return a.idx < b.idx
      end,
      focus = "input",
      auto_confirm = false,
      show_empty = true,
      layout = { preset = "vscode" },
      actions = {
        workspace_refresh = function(picker)
          picker:refresh()
        end,
        workspace_stop = function(picker)
          local item = picker:current()
          local stopped, err = M.stop(item and item.data)
          vim.notify(stopped and "已停止所选后台任务" or err, vim.log.levels.INFO)
          picker:refresh()
        end,
      },
      win = {
        input = {
          keys = {
            ["<C-r>"] = { "workspace_refresh", mode = { "i", "n" }, desc = "Refresh native ownership" },
            ["<C-x>"] = { "workspace_stop", mode = { "i", "n" }, desc = "Stop selected task" },
          },
        },
        list = { keys = { r = "workspace_refresh", ["<C-r>"] = "workspace_refresh", ["<C-x>"] = "workspace_stop" } },
      },
      confirm = function(picker, item)
        picker:close()
        if item then
          vim.schedule(function()
            confirm(item.data)
          end)
        end
      end,
    })
  end
  -- The same ownership checks apply if Snacks is not loaded in headless use.
  return vim.ui.select(M.list(opts), {
    prompt = "Workspace 窗口 / 结果 / 任务",
    format_item = function(row)
      return row.text
    end,
  }, function(row)
    if row then
      confirm(row)
    end
  end)
end

function M.setup_commands()
  vim.api.nvim_create_user_command("UEWorkspace", function(args)
    M.open(args.args ~= "" and args.args or "all")
  end, {
    nargs = "?",
    complete = function()
      return vim.deepcopy(categories)
    end,
    desc = "Find windows, hidden buffers, saved results, tasks and retained logs",
    force = true,
  })
end

return M
