-- Diffview adapter for utils.layout: a Diffview tab is a review owner, so
-- external navigation (gd, pickers) routes to the normal editing layout and
-- never replaces one side of the paired diff panes.
-- Only an already loaded diffview.lib is consulted; nothing here loads Git UI.
local M = {}
local api = vim.api

function M.view(tab)
  local lib = package.loaded["diffview.lib"]
  if not lib or type(lib.tabpage_to_view) ~= "function" or not api.nvim_tabpage_is_valid(tab) then return nil end
  local ok, view = pcall(lib.tabpage_to_view, tab)
  return ok and view or nil
end

local function valid(group)
  if not group.token or M.view(group.tab) ~= group.token then
    return false, "Diffview 已关闭；需重新打开比较。"
  end
  return true
end

local function focus(group)
  local layout = group.token and group.token.cur_layout
  local ok, main = pcall(function() return layout and layout:get_main_win() end)
  local win = ok and main and main.id
  if not (type(win) == "number" and api.nvim_win_is_valid(win) and api.nvim_win_get_tabpage(win) == group.tab) then
    win = api.nvim_tabpage_get_win(group.tab)
  end
  api.nvim_set_current_win(win)
  return win
end

--- register_group options for the Diffview view owning `tab`.
function M.group_opts(tab, view)
  local adapter = view.adapter
  local ctx = adapter and adapter.ctx
  return { tab = tab, token = view, owner = "diffview", project = ctx and ctx.toplevel,
    valid = valid, focus = focus, restore = focus,
    metadata = { repo = ctx and ctx.toplevel, selected_path = view.cur_entry and view.cur_entry.path } }
end

return M
