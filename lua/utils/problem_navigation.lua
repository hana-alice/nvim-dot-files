-- List ownership stays native; only protected review destinations are adapted.
local M = {}
local api = vim.api

local function warn(err)
  vim.notify(tostring(err), vim.log.levels.WARN)
end

local function run(command, count)
  return pcall(vim.cmd[command], { count = count })
end

local function index(list, command, count)
  local items = list.items
  if command == "cc" or command == "ll" then return count or list.idx end
  local step = command == "cprev" and -1 or 1
  local row = list.idx
  local valid_only = false
  for _, item in ipairs(items) do if item.valid == 1 then valid_only = true; break end end
  for _ = 1, count or 1 do
    local next_row = row
    repeat next_row = next_row + step until not items[next_row] or not valid_only or items[next_row].valid == 1
    -- Native counts clamp at the final reachable result after making progress.
    if not items[next_row] then return row ~= list.idx and row or nil end
    row = next_row
  end
  return row
end

function M.quickfix(command, count)
  local source = api.nvim_get_current_win()
  local source_buf = api.nvim_win_get_buf(source)
  local tab = api.nvim_get_current_tabpage()
  local layout = require("utils.layout")
  local session = layout.sync_review(tab)
  local owner = layout.navigation_owner(tab)
  if not layout.routes_to_normal(tab) then
    local ok, err = run(command, count)
    if not ok then warn(err) end
    return ok
  end
  -- Reject native list boundaries before creating or focusing a browser.
  local list = vim.fn.getqflist({ id = 0, idx = 0, items = 0, changedtick = 0 })
  local destination
  local function current()
    local now = vim.fn.getqflist({ id = 0, idx = 0, changedtick = 0 })
    local active_tab = destination and api.nvim_win_get_tabpage(destination) or tab
    return api.nvim_get_current_tabpage() == active_tab and api.nvim_win_is_valid(source)
      and api.nvim_win_get_buf(source) == source_buf
      and layout.sync_review(tab) == session and now.id == list.id and now.idx == list.idx
      and now.changedtick == list.changedtick and layout.navigation_owner(tab) == owner
  end
  local row = index(list, command, count)
  if not row or not list.items[row] then
    warn(#list.items == 0 and "No quickfix entries" or "No more quickfix entries")
    return false
  end
  if list.items[row].bufnr == 0 then
    local ok, err = run(command, count)
    if not ok then warn(err) end
    return ok
  end
  local win, err = layout.resolve({ tab = tab, source_win = source })
  if not win then warn(err); return false end
  destination = win
  local destination_tab = api.nvim_win_get_tabpage(win)
  if not current() then return false end
  local switchbuf = vim.o.switchbuf
  -- From code, an empty switchbuf keeps native :cc/cnext off existing aux.
  vim.o.switchbuf = ""
  api.nvim_set_current_win(win)
  if not current() or api.nvim_get_current_win() ~= win
    or layout.resolve({ tab = destination_tab, source_win = win, create = false }) ~= win then
    vim.o.switchbuf = switchbuf
    return false
  end
  local ok, result = run(command, count)
  vim.o.switchbuf = switchbuf
  if not ok then
    if api.nvim_get_current_tabpage() == destination_tab and api.nvim_get_current_win() == win
      and api.nvim_win_is_valid(source) then api.nvim_set_current_win(source) end
    warn(result)
  end
  return ok
end

local function location_enter(source, row)
  local tab = api.nvim_win_get_tabpage(source)
  local layout = require("utils.layout")
  local session = layout.sync_review(tab)
  local navigation_owner = layout.navigation_owner(tab)
  if not layout.routes_to_normal(tab) then
    local ok, err = run("ll", row)
    if not ok then warn(err) end
    return ok
  end
  local source_buf = api.nvim_win_get_buf(source)
  local handoff = require("utils.layout_handoff")
  local snapshot = handoff.capture(source)
  local list = vim.fn.getloclist(source, { id = 0, items = 0, filewinid = 0, changedtick = 0 })
  local item = list.items[row]
  if not item then warn("No location entry to jump to"); return false end
  local owner = list.filewinid
  if not owner or owner == 0 or not api.nvim_win_is_valid(owner) then
    warn("Location list owner is unavailable"); return false
  end
  if item.bufnr == 0 then
    -- Native Enter can select a non-file message without leaving the list.
    vim.fn.setloclist(owner, {}, "a", { id = list.id, idx = row })
    return true
  end
  local win, err = layout.resolve({ tab = tab, source_win = owner })
  if not win then warn(err); return false end
  local destination_tab = api.nvim_win_get_tabpage(win)
  local function current()
    if api.nvim_get_current_tabpage() ~= destination_tab or not api.nvim_win_is_valid(source)
      or api.nvim_win_get_buf(source) ~= source_buf or not api.nvim_win_is_valid(owner)
      or layout.sync_review(tab) ~= session or layout.navigation_owner(tab) ~= navigation_owner then return false end
    local now = vim.fn.getloclist(source, { id = 0, filewinid = 0, changedtick = 0 })
    -- filewinid is reported as 0 for a location window in an inactive tab.
    -- Verify the native owner's own list ID rather than copying it to code.
    local native_owner = vim.fn.getloclist(owner, { id = 0 })
    return now.id == list.id and native_owner.id == list.id
      and (now.filewinid == owner or (destination_tab ~= tab and now.filewinid == 0))
      and now.changedtick == list.changedtick
  end
  if not current() then return false end
  -- :ll always prefers the associated owner, including an aux displaying the
  -- target already. Keep that association and list ID; update only its index.
  vim.fn.setloclist(owner, {}, "a", { id = list.id, idx = row })
  list.changedtick = vim.fn.getloclist(owner, { changedtick = 0 }).changedtick
  api.nvim_set_current_win(win)
  if not current() or api.nvim_get_current_win() ~= win
    or layout.resolve({ tab = destination_tab, source_win = win, create = false }) ~= win then return false end
  local ok, result = pcall(function()
    vim.cmd("normal! m'")
    local destination = { win = win, tab = destination_tab, buf = item.bufnr, code = true }
    if api.nvim_buf_is_loaded(item.bufnr) then destination.tick = api.nvim_buf_get_changedtick(item.bufnr) end
    local accepted, _, failure = handoff.handoff(snapshot, destination, function() vim.cmd.buffer(item.bufnr) end)
    if not accepted then return false, failure end
    if not current() or not handoff.revalidate(snapshot, destination) then return false end
    if item.pattern and item.pattern ~= "" then
      local cursor = api.nvim_win_get_cursor(win)
      api.nvim_win_set_cursor(win, { 1, 0 })
      if vim.fn.search(item.pattern, "cW") == 0 then api.nvim_win_set_cursor(win, cursor) end
    else
      local line = item.lnum > 0 and math.min(item.lnum, api.nvim_buf_line_count(item.bufnr))
        or api.nvim_win_get_cursor(win)[1]
      if item.lnum > 0 then api.nvim_win_set_cursor(win, { line, 0 }) end
      if item.col > 0 then
        -- Native | uses screen columns for vcol entries and byte columns otherwise.
        local col = item.vcol == 1 and vim.fn.virtcol2col(win, line, item.col) or item.col
        api.nvim_win_set_cursor(win, { line, math.max(0, col - 1) })
      else
        vim.cmd("normal! ^")
      end
    end
    vim.cmd("normal! zzzv")
    return true
  end)
  if not ok then warn(result) end
  return ok and result == true
end

function M.enter()
  local source = api.nvim_get_current_win()
  local info = vim.fn.getwininfo(source)[1]
  local row = api.nvim_win_get_cursor(source)[1]
  if info and info.loclist == 1 then return location_enter(source, row) end
  return M.quickfix("cc", row)
end

function M.setup()
  local group = api.nvim_create_augroup("ue_problem_navigation", { clear = true })
  local function attach(buf)
    if vim.bo[buf].filetype ~= "qf" then return end
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      vim.wo[win].winfixbuf = true
      require("utils.layout").register(win, "panel", { owner = "problem_list" })
    end
    vim.keymap.set("n", "<CR>", M.enter, { buffer = buf, silent = true, desc = "Open native problem entry" })
  end
  api.nvim_create_autocmd({ "FileType", "BufWinEnter" }, {
    group = group,
    callback = function(ev) attach(ev.buf) end,
  })
  for _, win in ipairs(api.nvim_list_wins()) do attach(api.nvim_win_get_buf(win)) end
end

--- Public Trouble custom actions preserve its own jump/fold/split behavior.
function M.trouble_action(name)
  return function(view, ctx)
    local actions = require("trouble.config.actions")
    local source = view.win.win
    local tab = source and api.nvim_win_is_valid(source) and api.nvim_win_get_tabpage(source)
    local layout = require("utils.layout")
    local session = tab and layout.sync_review(tab)
    local owner = tab and layout.navigation_owner(tab)
    if not owner or not ctx.item then return actions[name](view, ctx) end
    if api.nvim_get_current_tabpage() ~= tab then return end
    local source_buf = api.nvim_win_get_buf(source)
    local destination
    local function current()
      local active_tab = destination and api.nvim_win_get_tabpage(destination) or tab
      return api.nvim_win_is_valid(source) and api.nvim_win_get_buf(source) == source_buf
        and api.nvim_get_current_tabpage() == active_tab and layout.sync_review(tab) == session
        and layout.navigation_owner(tab) == owner
    end
    require("trouble.view.preview").close()
    if not current() then return end
    -- Preload through the shared synchronous observer before native Trouble
    -- creates or focuses its destination. Do not let a restored autocmd
    -- context erase a callback's newer tab/window choice.
    local item = ctx.item
    if not (item.buf or item.filename) then return actions[name](view, ctx) end
    local handoff = require("utils.layout_handoff")
    local snapshot = handoff.capture(source)
    local prior = layout.resolve({ tab = tab, source_win = source, create = false, route_to_normal = true })
    local prior_snapshot = prior and handoff.capture(prior)
    if prior_snapshot then prior_snapshot.active, prior_snapshot.code = false, true end
    item.buf = item.buf or vim.fn.bufadd(item.filename)
    local loaded, _, load_error = handoff.load(snapshot, item.buf, prior_snapshot)
    if not loaded then warn(load_error); return end
    if not current() then warn("Problem navigation source changed while loading target"); return end
    local win, err = layout.resolve({ tab = tab, source_win = source })
    if not win then return warn(err) end
    destination = win
    local destination_tab = api.nvim_win_get_tabpage(win)
    if not current() then return end
    local main = {
      win = win, buf = api.nvim_win_get_buf(win), cursor = api.nvim_win_get_cursor(win),
      filename = api.nvim_buf_get_name(api.nvim_win_get_buf(win)),
    }
    require("trouble.view.main").set(main)
    -- The custom action's receiver supplies this destination directly. Trouble's
    -- Main.get otherwise rejects nowrite revision buffers, and a pinned view
    -- can retain an unrelated main. Neither should reopen another tab here.
    local action_view = setmetatable({ main = function()
      if not current() or layout.resolve({ tab = destination_tab, source_win = win, create = false }) ~= win then
        error("Problem navigation source or destination changed")
      end
      return main
    end }, { __index = view })
    local ok, result = pcall(actions[name], action_view, ctx)
    if not ok then warn(result) end
    return ok and result or nil
  end
end

return M
