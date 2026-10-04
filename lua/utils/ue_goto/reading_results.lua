-- Explicit preview/open/return for compiler locations. Preview never changes
-- the source window, and return is an explicit action rather than a view hook.
local M = {}
local ownership = require("utils.ue_goto.reading_owner")
local location = require("utils.ue_goto.location")
local ns = vim.api.nvim_create_namespace("ue.reading.origin")
local origin
local MAX_RESULTS = 1000

local function notify(message)
  vim.notify(message, vim.log.levels.WARN, { title = "代码阅读" })
end

local function signature(path)
  local stat = vim.uv.fs_stat(path)
  return stat and { size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec } or nil
end

function M.items(locations)
  local rows, seen = {}, {}
  for _, loc in ipairs(locations or {}) do
    local uri = loc.uri or loc.targetUri
    local range = loc.targetSelectionRange or loc.targetRange or loc.range
    local start = range and range.start
    if
      type(uri) == "string"
      and uri:sub(1, 5) == "file:"
      and type(start) == "table"
      and type(start.line) == "number"
      and start.line >= 0
      and start.line % 1 == 0
      and type(start.character) == "number"
      and start.character >= 0
      and start.character % 1 == 0
    then
      local ok, file = pcall(vim.uri_to_fname, uri)
      local stat = ok and vim.uv.fs_stat(file) or nil
      local buf = ok and vim.fn.bufnr(file) or -1
      local loaded = buf >= 0 and vim.api.nvim_buf_is_loaded(buf)
      local key = ok and location.location_key(loc)
      if ok and not seen[key] and ((stat and stat.type == "file") or loaded) then
        seen[key] = true
        if #rows == MAX_RESULTS then
          return rows, true
        end
        rows[#rows + 1] = {
          text = file .. ":" .. (start.line + 1),
          file = file,
          pos = { start.line + 1, start.character },
          loc = { uri = uri, range = vim.deepcopy(range), encoding = loc._position_encoding or "utf-16" },
          location = vim.deepcopy(loc),
          buf = loaded and buf or nil,
          target_path = loaded and vim.api.nvim_buf_get_name(buf) or nil,
          target_tick = loaded and vim.api.nvim_buf_get_changedtick(buf) or nil,
          target_signature = signature(file),
        }
      end
    end
  end
  return rows, false
end

function M.target_current(row)
  if row.proof_is_current then
    local ok, current = pcall(row.proof_is_current)
    if not ok or not current then
      return false
    end
  end
  if not row.buf then
    local loaded = vim.fn.bufnr(row.file)
    if loaded >= 0 and vim.api.nvim_buf_is_loaded(loaded) and vim.bo[loaded].modified then
      return false
    end
  end
  return (
    not row.buf
    or (
      vim.api.nvim_buf_is_valid(row.buf)
      and vim.api.nvim_buf_get_name(row.buf) == row.target_path
      and vim.api.nvim_buf_get_changedtick(row.buf) == row.target_tick
    )
  ) and vim.deep_equal(signature(row.file), row.target_signature)
end

function M.copy(owner, picker, row, mode)
  row = row or picker:current()
  if not row or not ownership.current(owner, true) or not M.target_current(row) then
    return false
  end
  return require("utils.file_query").copy(picker, row, mode)
end

local function layout()
  local result = {}
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local windows = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_config(win).relative == "" then
        windows[#windows + 1] =
          { win = win, width = vim.api.nvim_win_get_width(win), height = vim.api.nvim_win_get_height(win) }
      end
    end
    result[#result + 1] = { tab = tab, windows = windows }
  end
  return result
end

function M.remember(owner)
  if origin and vim.api.nvim_buf_is_valid(origin.buf) then
    pcall(vim.api.nvim_buf_del_extmark, origin.buf, ns, origin.mark)
  end
  origin = {
    win = owner.win,
    tab = owner.tab,
    buf = owner.buf,
    path = owner.path,
    origin_window_buf = owner.buf,
    view = vim.deepcopy(owner.view),
    build = vim.deepcopy(owner.build),
    mark = vim.api.nvim_buf_set_extmark(owner.buf, ns, owner.cursor[1] - 1, owner.cursor[2], { right_gravity = false }),
  }
  return origin
end

function M.jump(owner, row, cmd, saved_origin)
  if not row or not row.location or not ownership.current(owner, true) then
    return false
  end
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd.stopinsert()
    vim.schedule(function()
      if ownership.current(owner, true) then
        M.jump(owner, row, cmd, saved_origin)
      end
    end)
    return true
  end
  if not M.target_current(row) then
    notify("目标已改变，请重新查询")
    return false
  end
  if not ownership.close_picker(owner) or not M.target_current(row) or not ownership.current(owner) then
    return false
  end
  local saved = saved_origin or M.remember(owner)
  owner.handoff = true
  local succeeded, ok = pcall(function()
    vim.api.nvim_set_current_win(owner.win)
    if cmd == "vsplit" then
      vim.cmd.vsplit()
    elseif cmd == "split" then
      vim.cmd.split()
    elseif cmd == "tab" then
      vim.cmd("tab split")
    end
    if not ownership.valid(owner) or not M.target_current(row) then
      return false
    end
    return require("utils.ue_goto.jumper").jump(row.location)
  end)
  owner.handoff = false
  if ownership.active() == owner then
    ownership.cancel()
  end
  ok = succeeded and ok or false
  if ok then
    if row.on_jump then
      row.on_jump(vim.api.nvim_get_current_win())
    end
    origin = saved
    if owner.win == origin.win then
      origin.origin_window_buf = vim.api.nvim_win_get_buf(origin.win)
    end
    origin.layout = layout()
    origin.destination_win = vim.api.nvim_get_current_win()
    origin.destination_buf = vim.api.nvim_get_current_buf()
  end
  return ok
end

function M.return_to_origin()
  local saved = origin
  if
    not saved
    or not vim.api.nvim_win_is_valid(saved.win)
    or not vim.api.nvim_buf_is_valid(saved.buf)
    or vim.api.nvim_buf_get_name(saved.buf) ~= saved.path
  then
    notify("没有仍有效的调查起点")
    return false
  end
  local _, build = ownership.context(saved.buf)
  if not vim.deep_equal(build, saved.build) or not vim.deep_equal(layout(), saved.layout) then
    notify("工程或窗口布局已改变；保留当前布局，请从跳转历史返回")
    return false
  end
  if vim.api.nvim_win_get_buf(saved.win) ~= saved.origin_window_buf then
    notify("原窗口已改用于其他任务，保留当前现场")
    return false
  end
  if
    not vim.api.nvim_win_is_valid(saved.destination_win)
    or vim.api.nvim_win_get_buf(saved.destination_win) ~= saved.destination_buf
  then
    notify("调查窗口已改用于其他文件，保留当前现场")
    return false
  end
  local mark = vim.api.nvim_buf_get_extmark_by_id(saved.buf, ns, saved.mark, {})
  if #mark ~= 2 then
    notify("调查起点已失效")
    return false
  end
  ownership.cancel()
  vim.api.nvim_set_current_win(saved.win)
  vim.api.nvim_win_set_buf(saved.win, saved.buf)
  local view = vim.deepcopy(saved.view)
  local delta = mark[1] + 1 - view.lnum
  view.lnum, view.col = mark[1] + 1, mark[2]
  view.topline = math.max(1, view.topline + delta)
  vim.fn.winrestview(view)
  vim.api.nvim_buf_del_extmark(saved.buf, ns, saved.mark)
  origin = nil
  return true
end

function M.pin(owner, rows, opts)
  if not ownership.current(owner, true) then
    return false
  end
  local items = {}
  for _, row in ipairs(rows) do
    if not M.target_current(row) then
      notify("目标已改变，请重新查询后固定结果")
      return false
    end
    local start = row.location
      and (row.location.range or row.location.targetSelectionRange or row.location.targetRange).start
    if start then
      local col = (row.loc.resolved or row.loc.encoding == "utf-8") and row.pos[2] + 1 or 1
      if row.buf and vim.api.nvim_buf_is_loaded(row.buf) then
        local line = vim.api.nvim_buf_get_lines(row.buf, start.line, start.line + 1, false)[1]
        if line then
          local converted, byte = pcall(vim.str_byteindex, line, row.loc.encoding, start.character, false)
          if converted then
            col = byte + 1
          end
        end
      end
      items[#items + 1] = {
        filename = row.file,
        lnum = start.line + 1,
        col = col,
        text = row.text .. (col == 1 and " [行定位]" or ""),
      }
    end
  end
  local ok, workspace = pcall(require, "utils.workspace")
  if not ok then
    notify("结果固定入口尚不可用")
    return false
  end
  local id, err =
    workspace.pin(items, { title = opts.title, source = opts.source or "LSP", truncated = opts.truncated })
  if not id then
    notify(err or "无法固定结果")
    return false
  end
  return true
end

function M.open(owner, rows, opts)
  opts = opts or {}
  if not ownership.current(owner, true) then
    return nil
  end
  if #rows == 0 then
    notify("提供者未返回可导航文件；覆盖未知，不能据此断言不存在")
    return nil
  end
  local snacks = _G.Snacks
  if not snacks then
    local ok, loaded = pcall(require, "snacks")
    if ok then
      snacks = loaded
    end
  end
  if not snacks or not snacks.picker then
    notify("Snacks picker 不可用")
    return nil
  end
  local title = (opts.title or "代码位置")
    .. " · "
    .. (opts.source or "LSP")
    .. " · 覆盖未知"
    .. (opts.truncated and " · 前1000项（受限）" or "")
  local function jump(picker, row, command)
    if ownership.current(owner, true) then
      M.jump(owner, row or picker:current(), command, opts.origin)
    end
  end
  return ownership.present(owner, function()
    return snacks.picker.pick({
      title = title,
      items = rows,
      format = require("utils.search_ui").format,
      preview = "file",
      auto_confirm = false,
      layout = { preset = "telescope" },
      jump = { close = true, reuse_win = false },
      confirm = function(picker, row)
        jump(picker, row)
      end,
      actions = {
        read_split = function(picker, row)
          jump(picker, row, "split")
        end,
        read_vsplit = function(picker, row)
          jump(picker, row, "vsplit")
        end,
        read_tab = function(picker, row)
          jump(picker, row, "tab")
        end,
        read_pin = function()
          M.pin(owner, rows, opts)
        end,
        copy_position = function(picker, row)
          return M.copy(owner, picker, row, "position")
        end,
        copy_absolute_path = function(picker, row)
          return M.copy(owner, picker, row, "absolute")
        end,
        copy_relative_path = function(picker, row)
          return M.copy(owner, picker, row, "relative")
        end,
      },
      win = {
        input = {
          keys = {
            ["<Esc>"] = { "cancel", mode = { "n", "i" } },
            ["<C-s>"] = { "read_split", mode = { "n", "i" } },
            ["<M-v>"] = { "read_vsplit", mode = { "n", "i" } },
            ["<C-t>"] = { "read_tab", mode = { "n", "i" } },
            ["<C-q>"] = { "read_pin", mode = { "n", "i" } },
          },
        },
        list = {
          keys = {
            ["<C-s>"] = "read_split",
            ["<M-v>"] = "read_vsplit",
            ["<C-t>"] = "read_tab",
            ["<C-q>"] = "read_pin",
          },
        },
      },
      on_close = function(picker)
        ownership.picker_closed(owner, picker)
      end,
    })
  end)
end

function M.reset()
  ownership.cancel()
  if origin and vim.api.nvim_buf_is_valid(origin.buf) then
    pcall(vim.api.nvim_buf_del_extmark, origin.buf, ns, origin.mark)
  end
  origin = nil
end

return M
