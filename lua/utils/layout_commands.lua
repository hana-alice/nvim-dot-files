-- Explicit UI commands; owners alone can restore business-specific panels.
local M = {}
local epoch = 0

local function result(win, err)
  if not win and err then vim.notify(err, vim.log.levels.WARN, { title = "Layout" }) end
  return win, err
end

local function choose(rows, title, activate)
  epoch = epoch + 1
  local request = epoch
  local source = vim.api.nvim_get_current_tabpage()
  local source_win = vim.api.nvim_get_current_win()
  local source_buf = vim.api.nvim_win_get_buf(source_win)
  local selecting, finished = false, false
  if #rows == 0 then return result(nil, "没有符合条件的有效视图。") end
  local function confirm(row)
    if request ~= epoch or finished then return end
    finished = true
    if vim.api.nvim_get_current_tabpage() ~= source or not vim.api.nvim_win_is_valid(source_win)
      or vim.api.nvim_win_get_buf(source_win) ~= source_buf
      or vim.api.nvim_get_current_win() ~= source_win then
      return result(nil, "来源 tab / 窗口 / 内容有了新选择；已保留，请重新打开列表。")
    end
    if row then return result(activate(row)) end
  end
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    return snacks.picker.pick({
      source = "ue_layout_views", title = title, format = "text", preview = "none",
      items = vim.tbl_map(function(row) return { text = row.text, data = row } end, rows),
      main = { current = true }, layout = { preset = "select" },
      auto_confirm = false,
      on_close = function() if not selecting then finished = true end end,
      confirm = function(picker, item)
        local row = item and item.data
        picker:norm(function()
          if picker.closed then return end
          selecting = true
          picker:close()
          selecting = false
          vim.schedule(function() confirm(row) end)
        end)
      end,
    })
  end
  return vim.ui.select(rows, { prompt = title, format_item = function(row) return row.text end }, confirm)
end

function M.layout(kind)
  epoch = epoch + 1
  local layout = require("utils.layout")
  if kind and kind ~= "" then return result(layout.switch(kind)) end
  return choose(layout.list_groups(), "Layouts 布局 / 工程 / 比较版本 / 文件 / 状态", layout.activate_group)
end

function M.view(role)
  epoch = epoch + 1
  if role == "" then role = nil end
  if role and role ~= "code" and role ~= "panel" then return result(nil, "视图角色：code / panel。") end
  local layout = require("utils.layout")
  local rows = layout.list_views(role)
  if role == "code" and #rows == 0 and layout.group_kind() == "review" then
    return result(nil, "当前为审阅配对视图；<leader>wN 进入编辑，<leader>wR 回审阅")
  end
  if role == "code" and #rows > 0 then
    for _, row in ipairs(rows) do
      if row.win == vim.api.nvim_get_current_win() then return result(layout.activate_view(row)) end
    end
    return result(layout.activate_view(rows[1]))
  end
  if role and #rows == 1 then return result(layout.activate_view(rows[1])) end
  return choose(rows, "Views 视图 / 角色 / 内容", layout.activate_view)
end

function M.setup()
  require("utils.layout").setup_groups()
  vim.api.nvim_create_user_command("UELayout", function(args) M.layout(args.args) end,
    { nargs = "?", complete = function() return { "normal", "review", "debug" } end, desc = "Focus a layout without starting business actions", force = true })
  vim.api.nvim_create_user_command("UELayoutRestore", function() epoch = epoch + 1; result(require("utils.layout").restore_group()) end,
    { desc = "Restore current group's retained views through their owners", force = true })
  vim.api.nvim_create_user_command("UEView", function(args) M.view(args.args) end,
    { nargs = "?", complete = function() return { "code", "panel" } end, desc = "Focus existing windows by role without replacing buffers", force = true })
  vim.api.nvim_create_user_command("UELayoutBack", function() epoch = epoch + 1; result(require("utils.layout").back()) end,
    { desc = "Return to the previous valid layout group", force = true })
end

return M
