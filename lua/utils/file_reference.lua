-- Run native gf with the source buffer's path/includeexpr/suffixesadd rules,
-- while keeping CodeDiff's paired buffers in their owned windows.
local M = {}
local api = vim.api

function M.open()
  local source, tab = api.nvim_get_current_win(), api.nvim_get_current_tabpage()
  local layout = require("utils.layout")
  local session = layout.sync_review(tab)
  if not layout.routes_to_normal(tab) then
    return pcall(vim.cmd.normal, { args = { "gf" }, bang = true })
  end
  local buf, cursor = api.nvim_get_current_buf(), api.nvim_win_get_cursor(source)
  local tick = api.nvim_buf_get_changedtick(buf)
  local owner = layout.navigation_owner(tab)
  local function source_current()
    return api.nvim_win_is_valid(source)
      and api.nvim_win_get_buf(source) == buf and api.nvim_buf_get_changedtick(buf) == tick
      and vim.deep_equal(api.nvim_win_get_cursor(source), cursor) and layout.sync_review(tab) == session
      and layout.navigation_owner(tab) == owner
  end
  local cwd = vim.fn.getcwd(vim.fn.win_id2win(source))
  local win, err = layout.resolve({ tab = tab, source_win = source })
  if not win then
    if not source_current() or api.nvim_get_current_win() ~= source then return true end
    return false, err
  end
  -- An owner callback changed context: consume this mouse action so it cannot
  -- start a new definition request in the replacement source.
  if not source_current() or api.nvim_get_current_win() ~= win then return true end
  local destination_tab = api.nvim_win_get_tabpage(win)
  if win == source then return pcall(vim.cmd.normal, { args = { "gf" }, bang = true }) end
  local previous = api.nvim_win_get_buf(win)
  local view = api.nvim_win_call(win, vim.fn.winsaveview)
  local destination_number = api.nvim_tabpage_get_number(destination_tab)
  local window_number = api.nvim_win_get_number(win)
  local localdir = vim.fn.haslocaldir(window_number, destination_number)
  local destination_cwd = vim.fn.getcwd(window_number, destination_number)
  local opened, failure
  local chosen_win
  local tab_event = api.nvim_create_autocmd({ "TabEnter", "BufReadPost", "WinEnter" }, { callback = function()
    if api.nvim_get_current_tabpage() ~= destination_tab then chosen_win = api.nvim_get_current_win() end
  end })
  local ok, call_err = pcall(api.nvim_win_call, win, function()
    -- The temporary source display produces no attach or enter side effects.
    -- gf itself remains native, including its source jumplist entry.
    vim.cmd("noautocmd keepalt keepjumps buffer " .. buf)
    api.nvim_win_set_cursor(win, cursor)
    if cwd ~= destination_cwd then vim.cmd.lcd(vim.fn.fnameescape(cwd)) end
    opened, failure = pcall(vim.cmd.normal, { args = { "gf" }, bang = true })
    if cwd ~= destination_cwd then
      api.nvim_win_call(win, function()
        if localdir == 1 then vim.cmd.lcd(vim.fn.fnameescape(destination_cwd))
        elseif localdir == 2 then vim.cmd.tcd(vim.fn.fnameescape(destination_cwd))
        else vim.cmd.cd(vim.fn.fnameescape(destination_cwd)) end
      end)
    end
    if not opened then
      vim.cmd("noautocmd keepalt keepjumps buffer " .. previous)
      vim.fn.winrestview(view)
    end
  end)
  api.nvim_del_autocmd(tab_event)
  -- nvim_win_call restores its caller even if a load callback chose another
  -- tab. Preserve that choice after this one synchronous operation finishes.
  if chosen_win and api.nvim_win_is_valid(chosen_win) then
    api.nvim_set_current_win(chosen_win)
    return true
  end
  if not ok then return false, call_err end
  if opened and source_current()
    and layout.resolve({ tab = destination_tab, source_win = win, create = false }) == win then
    api.nvim_set_current_win(win)
  elseif not opened and source_current() and api.nvim_get_current_win() == win then
    api.nvim_set_current_win(source)
  end
  return opened, failure
end

return M
