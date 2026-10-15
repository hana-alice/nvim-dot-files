-- Synchronous navigation transactions. Observers exist only during one step;
-- they record callback choices, never guard cursors or enter events globally.
local M = {}
local api = vim.api
local events = { "WinEnter", "TabEnter", "BufEnter", "BufReadPost", "WinNew", "TabNewEntered" }

local function live(win, tab)
  return type(win) == "number" and api.nvim_win_is_valid(win)
    and api.nvim_tabpage_is_valid(tab) and api.nvim_win_get_tabpage(win) == tab
end

function M.capture(win)
  win = win or api.nvim_get_current_win()
  if not api.nvim_win_is_valid(win) then return nil end
  local buf, tab = api.nvim_win_get_buf(win), api.nvim_win_get_tabpage(win)
  local layout = require("utils.layout")
  local owner, kind = layout.navigation_owner(tab)
  local role, window_owner = layout.window_role(win, tab)
  return { win = win, tab = tab, buf = buf, tick = api.nvim_buf_get_changedtick(buf),
    cursor = api.nvim_win_get_cursor(win), owner = owner, kind = kind, ownership = true,
    role = role, window_owner = window_owner }
end

function M.revalidate(source, destination)
  if not source or not live(source.win, source.tab) then return false, "导航来源已关闭。" end
  local layout = require("utils.layout")
  local owner, kind = layout.navigation_owner(source.tab)
  if owner ~= source.owner or kind ~= source.kind then return false, "导航来源 owner 已变化。" end
  local role, window_owner = layout.window_role(source.win, source.tab)
  if role ~= source.role or window_owner ~= source.window_owner then
    return false, "导航来源窗口角色/owner 已变化。"
  end
  if not destination or source.win ~= destination.win then
    if api.nvim_win_get_buf(source.win) ~= source.buf
      or api.nvim_buf_get_changedtick(source.buf) ~= source.tick
      or not vim.deep_equal(api.nvim_win_get_cursor(source.win), source.cursor) then
      return false, "导航来源内容/位置已变化。"
    end
  end
  if destination then
    local tab = destination.tab or (api.nvim_win_is_valid(destination.win) and api.nvim_win_get_tabpage(destination.win))
    if not live(destination.win, tab) or api.nvim_win_get_buf(destination.win) ~= destination.buf
      or (destination.active ~= false and (api.nvim_get_current_win() ~= destination.win
        or api.nvim_get_current_tabpage() ~= tab))
      or (destination.code and (not layout.is_code(destination.win, tab)
        or (source.tab ~= tab and layout.routes_to_normal(tab)))) then
      return false, "导航目的窗口/内容/角色有了新选择。"
    end
    if destination.tick and api.nvim_buf_get_changedtick(destination.buf) ~= destination.tick then
      return false, "导航目标正文已变化。"
    end
    if destination.ownership then
      local destination_owner, destination_kind = layout.navigation_owner(tab)
      if destination_owner ~= destination.owner or destination_kind ~= destination.kind then
        return false, "导航目标 owner 已变化。"
      end
    end
    if destination.role then
      local destination_role, window_owner = layout.window_role(destination.win, tab)
      if destination_role ~= destination.role or window_owner ~= destination.window_owner then
        return false, "导航目标窗口角色/owner 已变化。"
      end
    end
    if destination.cursor and not vim.deep_equal(api.nvim_win_get_cursor(destination.win), destination.cursor) then
      return false, "导航目标位置已变化。"
    end
  end
  return true
end

local function step(source, destination, action, accepts)
  local valid, err = M.revalidate(source)
  -- A prior own buffer stage can legitimately change this same window.
  if destination and source and destination.win == source.win then
    valid, err = M.revalidate(source, { win = source.win, tab = source.tab,
      buf = api.nvim_win_get_buf(source.win), active = false })
  end
  if not valid then return false, nil, err end
  if destination then
    local win = destination.win
    if not api.nvim_win_is_valid(win) then return false, nil, "导航目的窗口已关闭。" end
    valid, err = M.revalidate(source, { win = win, tab = destination.tab,
      buf = api.nvim_win_get_buf(win), active = false, code = destination.code,
      ownership = destination.ownership, owner = destination.owner, kind = destination.kind,
      role = destination.role, window_owner = destination.window_owner })
    if not valid then return false, nil, err end
  end
  local chosen
  local watch = api.nvim_create_autocmd(events, { callback = function(ev)
    if not accepts(ev.event) then
      local win = api.nvim_get_current_win()
      chosen = { win = win, tab = api.nvim_get_current_tabpage(), buf = api.nvim_win_get_buf(win) }
    end
  end })
  local ok, result = pcall(action)
  api.nvim_del_autocmd(watch)
  if chosen then
    -- bufload/open_win can restore their temporary context after callbacks.
    -- Retain that choice, without restoring buffers or cursors over new work.
    if live(chosen.win, chosen.tab) and api.nvim_win_get_buf(chosen.win) == chosen.buf
      and api.nvim_get_current_win() ~= chosen.win then api.nvim_set_current_win(chosen.win) end
    return false, nil, "导航回调产生了新选择；已保留。"
  end
  if not ok then return false, nil, tostring(result) end
  valid, err = M.revalidate(source, destination)
  if not valid then return false, nil, err end
  return true, result
end

function M.handoff(source, destination, action)
  local win = destination and destination.win or api.nvim_get_current_win()
  local tab = destination and destination.tab or api.nvim_win_get_tabpage(win)
  return step(source, destination, action, function(event)
    if api.nvim_get_current_win() ~= win or api.nvim_get_current_tabpage() ~= tab then return false end
    return not destination or (event ~= "BufEnter" and event ~= "BufReadPost")
      or api.nvim_get_current_buf() == destination.buf
  end)
end

function M.load(source, buf, destination)
  local win, tab = api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  return step(source, destination, function() vim.fn.bufload(buf) end, function()
    local current = api.nvim_get_current_win()
    if api.nvim_get_current_tabpage() ~= tab then return false end
    if current == win then return true end
    if vim.fn.win_gettype(current) == "autocmd" then return api.nvim_get_current_buf() == buf end
    -- bufload uses an unlisted autocmd window for a hidden document. Real
    -- callback-selected windows remain in list_wins and must cancel the step.
    for _, real in ipairs(api.nvim_list_wins()) do if real == current then return false end end
    return api.nvim_get_current_buf() == buf
  end)
end

local function create(source, buf, action, new_tab, enter, initial_buf)
  local existing, before = {}, api.nvim_get_current_win()
  local tab = api.nvim_get_current_tabpage()
  for _, win in ipairs(api.nvim_list_wins()) do existing[win] = true end
  local ok, win, err = step(source, nil, action, function(event)
    local current = api.nvim_get_current_win()
    if existing[current] then return current == before end
    return (new_tab or api.nvim_get_current_tabpage() == tab) and (api.nvim_get_current_buf() == buf
      or (event == "WinNew" and api.nvim_get_current_buf() == initial_buf))
  end)
  if not ok then return nil, err end
  if not win or not api.nvim_win_is_valid(win) or existing[win] or api.nvim_win_get_buf(win) ~= buf
    or (enter and api.nvim_get_current_win() ~= win) then return nil, "新窗口被回调更换；已保留。" end
  local role, owner, registered = require("utils.layout").window_role(win, api.nvim_win_get_tabpage(win))
  if registered and (role ~= "code" or owner ~= nil) then
    return nil, "新窗口的角色/owner 已由回调接管；已保留。"
  end
  return win
end

function M.open_window(source, buf, opts)
  local initial_buf = opts.win and api.nvim_win_get_buf(opts.win)
  return create(source, buf, function() return api.nvim_open_win(buf, false, opts) end, false, false, initial_buf)
end

function M.new_tab(source, buf)
  -- tab sbuffer first creates a tab showing the source, then switches buffers.
  -- Keep those two observable steps separate and validate each identity.
  local win, err = create(source, source.buf, function()
    vim.cmd("tab split")
    return api.nvim_get_current_win()
  end, true, true)
  if not win then return nil, err end
  if require("utils.layout").routes_to_normal(api.nvim_win_get_tabpage(win)) then
    return nil, "新 tab 已由其它 UI owner 使用；已保留。"
  end
  -- tab split inherits its source's review/panel window options. This fresh
  -- window belongs to normal editing, not to that source UI owner.
  vim.wo[win].winfixbuf, vim.wo[win].diff = false, false
  vim.wo[win].scrollbind, vim.wo[win].cursorbind = false, false
  vim.w[win].codediff_restore, vim.w[win].ue_bottom_panel_pin = nil, nil
  vim.w[win].snacks_main = true
  local ok, _, reason = M.handoff(source, { win = win, tab = api.nvim_win_get_tabpage(win), buf = buf },
    function() api.nvim_win_set_buf(win, buf) end)
  return ok and win or nil, reason
end

function M.split(source, destination, cmd)
  local valid, err = M.revalidate(source, destination)
  if not valid then return nil, err end
  return create(source, destination.buf, function()
    vim.cmd(cmd == "tab" and "tab split" or cmd)
    return api.nvim_get_current_win()
  end, cmd == "tab", true)
end

-- Ordinary pickers keep the installed native action. Protected owners use
-- the same buffer-opening action, deferring its positioning until validation.
function M.confirm(picker, item, action)
  local layout, jump = require("utils.layout"), require("snacks.picker.actions").jump
  local source = picker.main
  if picker.filter then source = picker:filter().current_win or source end
  local snapshot = M.capture(source)
  if not snapshot then return vim.notify("Navigation source window is unavailable", vim.log.levels.WARN) end
  if not layout.routes_to_normal(snapshot.tab) and not layout.is_panel(source, snapshot.tab) then
    return jump(picker, item, action or {})
  end
  if picker.closed or api.nvim_get_current_tabpage() ~= snapshot.tab then return end
  if vim.fn.mode():sub(1, 1) == "i" then
    vim.cmd.stopinsert()
    vim.schedule(function() if not picker.closed and M.revalidate(snapshot) then M.confirm(picker, item, action) end end)
    return
  end
  local rows = picker:selected({ fallback = true })
  if #rows == 0 then return jump(picker, item, action or {}) end
  local prepared = {}
  for _, row in ipairs(rows) do
    local copy = vim.tbl_extend("force", {}, row)
    copy.buf = row.buf or vim.fn.bufadd(assert(require("snacks.picker.util").path(row)))
    local loaded = M.load(snapshot, copy.buf)
    if not loaded then return end
    copy.pos, copy.search = nil, nil
    prepared[#prepared + 1] = copy
  end
  local before, main = api.nvim_get_current_win(), picker.main
  local main_buf = main and api.nvim_win_is_valid(main) and api.nvim_win_get_buf(main)
  if picker.opts.jump and picker.opts.jump.close then picker:close() end
  if not M.revalidate(snapshot) or api.nvim_get_current_tabpage() ~= snapshot.tab then return end
  local current = api.nvim_get_current_win()
  local restored_main = current == main and api.nvim_win_is_valid(main) and api.nvim_win_get_buf(main) == main_buf
  if current ~= source and current ~= before and not restored_main and layout.is_code(current, snapshot.tab) then return end
  local win, reason = layout.focus({ tab = snapshot.tab, source_win = source, create = true })
  if not win then return vim.notify(reason, vim.log.levels.WARN) end
  action = vim.tbl_extend("force", {}, action or {})
  local destination = { win = win, tab = api.nvim_win_get_tabpage(win), buf = api.nvim_win_get_buf(win), code = true }
  if action.cmd == "split" or action.cmd == "vsplit" or action.cmd == "tab" then
    win, reason = M.split(snapshot, destination, action.cmd)
    if not win then return vim.notify(reason, vim.log.levels.WARN) end
    destination.win, destination.tab = win, api.nvim_win_get_tabpage(win)
  end
  action.cmd = "edit" -- explicit created destination; no independent drop/reuse search
  picker.main = win
  local old_jump, old_selected = picker.opts.jump, picker.selected
  picker.opts.jump = vim.tbl_extend("force", old_jump or {}, { close = false, reuse_win = false, match = false })
  picker.selected = function() return prepared end
  destination.buf = prepared[1].buf
  local ok, result, err = M.handoff(snapshot, destination, function() return jump(picker, item, action) end)
  picker.opts.jump, picker.selected = old_jump, old_selected
  if not ok then if err then vim.notify(err, vim.log.levels.WARN) end; return end
  local row, pos = rows[1], rows[1].pos
  if old_jump and old_jump.match then
    pos = picker.matcher:bufpos(destination.buf, row) or pos
  end
  if not M.revalidate(snapshot, destination) then return end
  if pos and pos[1] > 0 then
    api.nvim_win_set_cursor(win, pos)
    if M.revalidate(snapshot, destination) then vim.cmd("normal! zzzv") end
  elseif row.search then
    local searched = M.handoff(snapshot, destination, function() vim.cmd(row.search) end)
    if searched then vim.cmd("noh") end
  end
  if M.revalidate(snapshot, destination) then layout.register(win, "code") end
  return result
end

return M
