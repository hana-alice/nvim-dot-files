-- Native one-file restoration; investigation cache and selection belong to work_context.
local M = {}
local api = vim.api
local recipes = require("utils.search_recipe")

--- Restore read-only file hints using the coordinator's existing ownership checks.
function M.restore(file, hints, owners)
  local disk, original = hints.disk, hints.original
  local ordinary, source, owned = owners.ordinary, owners.source, owners.owned
  local selection_generation = owners.generation
  local buf = vim.fn.bufnr(file.path)
  if buf > 0 and recipes.path_key(api.nvim_buf_get_name(buf)) ~= recipes.path_key(file.path) then
    buf = -1
  end
  local loaded = buf > 0 and api.nvim_buf_is_loaded(buf)
  if not loaded and not disk then
    return nil, "保存的文件已不存在；没有创建空文档冒充恢复。"
  end
  if loaded and vim.bo[buf].buftype ~= "" then
    return nil, "保存路径的缓冲区已变成非文件视图。"
  end
  local old_tabs = {}
  local generation = selection_generation()
  local origin_buf, origin_cursor = api.nvim_get_current_buf(), api.nvim_win_get_cursor(0)
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    old_tabs[tab] = true
  end
  vim.cmd.tabnew()
  local created = {}
  for _, tab in ipairs(api.nvim_list_tabpages()) do
    if not old_tabs[tab] then
      created[#created + 1] = tab
    end
  end
  if #created ~= 1 or generation ~= selection_generation() then
    return nil, "创建视图期间标签选择已变化；保留了新选择。"
  end
  local tab = created[1]
  local windows = api.nvim_tabpage_list_wins(tab)
  local win = windows[1]
  if
    #windows ~= 1
    or api.nvim_get_current_tabpage() ~= tab
    or api.nvim_get_current_win() ~= win
    or not ordinary(win)
    or api.nvim_buf_get_name(api.nvim_win_get_buf(win)) ~= ""
    or vim.bo[api.nvim_win_get_buf(win)].modified
    or not vim.deep_equal(api.nvim_buf_get_lines(api.nvim_win_get_buf(win), 0, -1, false), { "" })
    or not vim.deep_equal(api.nvim_win_get_cursor(win), { 1, 0 })
  then
    return nil, "创建视图期间出现新输入或选择；没有继续定位。"
  end
  local empty, empty_err = source(win)
  if not empty then
    return nil, empty_err
  end
  if not loaded then
    buf = vim.fn.bufadd(file.path)
  end
  if not owned(empty) then
    return nil, "关联文件期间选择已变化；没有继续定位。"
  end
  if not api.nvim_buf_is_valid(buf) or recipes.path_key(api.nvim_buf_get_name(buf)) ~= recipes.path_key(file.path) then
    return nil, "关联路径的缓冲区身份不匹配；没有打开相似名称文件。"
  end
  local before_tick = loaded and api.nvim_buf_get_changedtick(buf) or nil
  local before_name = api.nvim_buf_get_name(buf)
  local entry_cursor = origin_buf == buf and origin_cursor or empty.cursor
  local reading, read_attached, read_changed = true, loaded, false
  local read_guard
  if not loaded then
    read_guard = api.nvim_create_autocmd("BufReadPre", {
      buffer = buf,
      once = true,
      callback = function()
        -- The buffer is attachable here. Native initial reading does not emit
        -- on_lines; edits in read callbacks do, even if modified is cleared.
        local function changed()
          if reading then
            read_changed = true
          end
          -- Only detach this listener. A clean read leaves a dormant listener
          -- which removes itself at its next real change; never detach peers.
          return true
        end
        read_attached = api.nvim_buf_attach(buf, false, { on_lines = changed, on_reload = changed })
      end,
    })
  end
  local chosen_cursor
  -- The newly empty window is still at its native default during these entry
  -- events. A callback choosing another position owns that choice. Neovim may
  -- restore the buffer's remembered cursor after the events; do not confuse
  -- that native warm-entry restore with a callback (or override the callback).
  local observer = api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
    buffer = buf,
    callback = function()
      if api.nvim_get_current_win() == win and api.nvim_win_get_buf(win) == buf then
        local cursor = api.nvim_win_get_cursor(win)
        if not vim.deep_equal(cursor, empty.cursor) and not vim.deep_equal(cursor, entry_cursor) then
          chosen_cursor = cursor
        end
      end
    end,
  })
  local setter = api.nvim_win_set_buf
  local function assign()
    local result = setter(win, buf)
    return result
  end
  local revoked = false
  local leave_guard = api.nvim_create_autocmd({ "BufLeave", "BufWinLeave" }, {
    buffer = empty.buf,
    callback = function()
      -- Let a user's nested switch finish. Only our own direct setter frame
      -- may be vetoed when its empty source has gained new input or ownership.
      for level = 2, 30 do
        local frame = debug.getinfo(level, "fS")
        if not frame then
          return
        end
        if frame.what == "C" then
          local caller = debug.getinfo(level + 1, "f")
          if frame.func ~= setter or not caller or caller.func ~= assign then
            return
          end
          break
        end
      end
      if
        not owned(empty)
        or api.nvim_buf_get_name(buf) ~= before_name
        or (loaded and api.nvim_buf_get_changedtick(buf) ~= before_tick)
      then
        revoked = true
        error("Work context source changed during buffer assignment", 0)
      end
    end,
  })
  local ok, open_err = pcall(assign)
  reading = false
  if read_guard then
    pcall(api.nvim_del_autocmd, read_guard)
  end
  pcall(api.nvim_del_autocmd, leave_guard)
  pcall(api.nvim_del_autocmd, observer)
  if revoked then
    return nil, "离开新窗口时出现新输入或选择；已保留新状态，未继续恢复。"
  end
  if not ok then
    return nil, tostring(open_err)
  end
  if
    api.nvim_get_current_win() ~= win
    or api.nvim_get_current_tabpage() ~= tab
    or not api.nvim_win_is_valid(win)
    or api.nvim_win_get_buf(win) ~= buf
    or api.nvim_buf_get_name(buf) ~= before_name
    or (loaded and api.nvim_buf_get_changedtick(buf) ~= before_tick)
    or (not loaded and (vim.bo[buf].modified or read_changed or not read_attached))
    or generation ~= selection_generation()
  then
    return nil, "打开文件期间出现新输入或选择；没有回拉或继续定位。"
  end
  if chosen_cursor then
    if not vim.deep_equal(api.nvim_win_get_cursor(win), chosen_cursor) then
      api.nvim_win_set_cursor(win, chosen_cursor)
    end
    return nil, "进入文件时位置已由回调选择；保留该位置，没有继续应用保存坐标。"
  end
  local pos, position_err = require("utils.document_location").resolve(file.line .. ":" .. file.col, buf)
  local notice
  if not pos then
    notice = "文件已打开，保存位置不可用：" .. tostring(position_err)
  else
    api.nvim_win_set_cursor(win, pos)
    if
      file.modified
      or vim.bo[buf].modified
      or not vim.deep_equal(file.disk, disk)
      or (
        original
        and original.buf == buf
        and original.name == api.nvim_buf_get_name(buf)
        and original.tick ~= api.nvim_buf_get_changedtick(buf)
      )
    then
      notice = "文件与保存时不同；显示的是历史坐标，不保证当前语义位置。"
    end
  end
  local restored = source(win)
  return win, notice, restored
end

return M
