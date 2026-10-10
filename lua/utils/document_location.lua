-- Current-editor locations share the file picker's one-based UTF-8 byte columns.
local M = {}
local api = vim.api
local request = 0

local function warn(message)
  vim.notify(message, vim.log.levels.WARN, { title = "Document location" })
end

function M.resolve(input, buf)
  local text = tostring(input or "")
  if #text > 64 then
    return nil, "位置过长；请输入行号或 行:字节列"
  end
  text = vim.trim(text)
  local line, column = text:match("^(%d+):(%d+)$")
  if not line then
    line = text:match("^(%d+)$")
  end
  if not line then
    return nil, "请输入正整数行号或 行:字节列，例如 42:7"
  end
  line, column = tonumber(line), tonumber(column) or 1
  buf = buf or api.nvim_get_current_buf()
  if not api.nvim_buf_is_loaded(buf) then
    return nil, "文档已关闭"
  end
  if not line or line < 1 or line > api.nvim_buf_line_count(buf) or column < 1 then
    return nil, "行号或字节列超出当前文档范围"
  end
  local value = api.nvim_buf_get_lines(buf, line - 1, line, false)[1]
  if column > math.max(1, #value) then
    return nil, "字节列超出该行范围"
  end
  local byte = value:byte(column)
  if byte and byte >= 128 and byte < 192 then
    return nil, "字节列位于 UTF-8 字符内部；请选择字符起始位置"
  end
  return { line, column - 1 }
end

local function ordinary()
  local win, buf = api.nvim_get_current_win(), api.nvim_get_current_buf()
  return vim.bo[buf].buftype == "" and api.nvim_win_get_config(win).relative == ""
end

-- This dialog owns its close protocol. Normalise insert mode before closing;
-- the generic input backend schedules an unconditional parent-window restore.
function M.input(opts, on_confirm)
  local finishing = false
  local function finish(self, confirm)
    if finishing or self.closed then
      return
    end
    finishing = true
    local value = confirm and self:text() or nil
    local function deliver()
      if self.closed then
        return
      end
      if confirm and api.nvim_get_current_win() == self.win and self:text() ~= value then
        finishing = false
        warn("输入已变化，请重新确认位置")
        return
      end
      if api.nvim_get_current_win() ~= self.win then
        value = nil
      end
      self:close()
      on_confirm(value)
    end
    if vim.fn.mode():sub(1, 1) == "i" then
      vim.cmd.stopinsert()
      vim.schedule(deliver)
    else
      deliver()
    end
  end
  return require("snacks").win({
    enter = true,
    height = 1,
    width = 60,
    row = 2,
    relative = "editor",
    border = "rounded",
    title = opts.prompt,
    title_pos = "center",
    bo = { buftype = "nofile", filetype = "document_location_input", swapfile = false },
    b = { completion = false },
    on_win = function()
      vim.cmd.startinsert()
    end,
    keys = {
      ["<cr>"] = {
        function(self)
          finish(self, true)
        end,
        mode = { "i", "n" },
        expr = false,
      },
      ["<esc>"] = {
        function(self)
          finish(self, false)
        end,
        mode = { "i", "n" },
        expr = false,
      },
      q = {
        function(self)
          finish(self, false)
        end,
        mode = "n",
      },
    },
  })
end

function M.open()
  if not ordinary() then
    warn("请从普通文档编辑区跳到行或列")
    return
  end
  request = request + 1
  local id, done = request, false
  local win, buf, tab = api.nvim_get_current_win(), api.nvim_get_current_buf(), api.nvim_get_current_tabpage()
  local name, tick, cursor = api.nvim_buf_get_name(buf), api.nvim_buf_get_changedtick(buf), api.nvim_win_get_cursor(win)
  return M.input({
    prompt = string.format("跳到行[:UTF-8 字节列] · 1–%d 行", api.nvim_buf_line_count(buf)),
  }, function(value)
    if done then
      return
    end
    done = true
    if value == nil or id ~= request then
      return
    end
    if
      not api.nvim_win_is_valid(win)
      or not api.nvim_buf_is_loaded(buf)
      or api.nvim_get_current_tabpage() ~= tab
      or api.nvim_get_current_win() ~= win
      or api.nvim_win_get_buf(win) ~= buf
      or api.nvim_buf_get_name(buf) ~= name
      or api.nvim_buf_get_changedtick(buf) ~= tick
      or not vim.deep_equal(api.nvim_win_get_cursor(win), cursor)
    then
      warn("来源文档或位置已变化；请重新打开跳转入口")
      return
    end
    local pos, err = M.resolve(value, buf)
    if not pos then
      warn(err)
      return
    end
    if vim.deep_equal(pos, cursor) then
      return
    end
    vim.cmd("normal! m'")
    api.nvim_win_set_cursor(win, pos)
    vim.cmd("normal! zvzz")
  end)
end

function M.copy(kind)
  if not ordinary() then
    warn("请从普通文件编辑区复制路径或位置")
    return
  end
  local name = api.nvim_buf_get_name(0)
  if name == "" then
    warn("当前文档尚未命名；没有可复制的文件路径")
    return
  end
  local fs = require("ue.core.fs")
  local path = fs.norm(vim.fn.fnamemodify(name, ":p"))
  local value, label = path, "绝对路径"
  if kind == "relative" then
    value, label = fs.relative_to(vim.fn.getcwd(), path), "相对当前窗口工作目录的路径"
    if value == path then
      label = "绝对路径（文件位于当前窗口工作目录外）"
    end
  elseif kind == "position" then
    value, label =
      require("utils.file_query").position_text(path, api.nvim_win_get_cursor(0)), "路径:行:UTF-8 字节列"
  end
  -- Writing the unnamed alias directly can overwrite a user's named register.
  vim.fn.setreg("0", value)
  vim.fn.setreg('"', { points_to = "0" })
  local copied = pcall(vim.fn.setreg, "+", value)
  vim.notify(
    "已复制" .. label .. (copied and "" or "（系统剪贴板不可用；文本保留在未命名寄存器）")
  )
  return value
end

return M
