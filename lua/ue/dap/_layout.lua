-- Window ownership for one debug UI invocation. Native splits keep their IDs;
-- only windows created by this invocation and still showing its content close.
local M = {}

local options = {
  "statusline",
  "winbar",
  "number",
  "relativenumber",
  "signcolumn",
  "wrap",
  "spell",
  "list",
  "foldcolumn",
  "colorcolumn",
  "winfixheight",
  "winfixwidth",
  "winhighlight",
}

local function valid(win, tab)
  return win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_tabpage(win) == tab
end

local function snapshot(win)
  local value = {
    buf = vim.api.nvim_win_get_buf(win),
    tick = vim.api.nvim_buf_get_changedtick(vim.api.nvim_win_get_buf(win)),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
    width = vim.api.nvim_win_get_width(win),
    height = vim.api.nvim_win_get_height(win),
    floating = vim.api.nvim_win_get_config(win).relative ~= "",
    options = {},
  }
  for _, name in ipairs(options) do
    value.options[name] = vim.wo[win][name]
  end
  return value
end

local function windows(tab)
  local result = {}
  if not vim.api.nvim_tabpage_is_valid(tab) then
    return result
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    result[win] = snapshot(win)
  end
  return result
end

local function tree(tab)
  local win = vim.api.nvim_tabpage_get_win(tab)
  return vim.api.nvim_win_call(win, vim.fn.winlayout)
end

local function geometry(values)
  local result = {}
  for win, value in pairs(values) do
    if not value.floating then
      result[win] = { value.width, value.height }
    end
  end
  return result
end

local function code_window(win, tab)
  if not valid(win, tab) or vim.api.nvim_win_get_config(win).relative ~= "" then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == ""
    and not vim.bo[buf].filetype:find("^dap")
    and not vim.api.nvim_buf_get_name(buf):match("^dap%-src://")
end

function M.begin(session)
  local tab = vim.api.nvim_get_current_tabpage()
  return {
    session = session,
    tab = tab,
    main = vim.api.nvim_get_current_win(),
    original = windows(tab),
    original_tree = tree(tab),
    restore_sizes = vim.fn.winrestcmd(),
    screen = { vim.o.columns, vim.o.lines },
    owned = {},
    borrowed = {},
    changed = false,
    navigation = {},
  }
end

local function frame_position(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return {
    buf = buf,
    tick = vim.api.nvim_buf_get_changedtick(buf),
    view = vim.api.nvim_win_call(win, vim.fn.winsaveview),
  }
end

local function same_position(a, b)
  return a and b and a.buf == b.buf and (b.tick == nil or a.tick == b.tick) and vim.deep_equal(a.view, b.view)
end

--- Bracket the native jump, not user input events. Capture only existing IDs.
function M.before_frame(states)
  local result = {}
  for _, state in pairs(states) do
    local positions = {}
    for win in pairs(state.original) do
      if valid(win, state.tab) then
        positions[win] = frame_position(win)
      end
    end
    result[state] = positions
  end
  return result
end

function M.after_frame(before, frame)
  local path = frame and frame.source and frame.source.path
  local line = frame and tonumber(frame.line)
  if type(path) ~= "string" or not line or line < 1 then
    return
  end
  local target = vim.fn.bufnr(path)
  for state, positions in pairs(before or {}) do
    for win, previous in pairs(positions) do
      if valid(win, state.tab) then
        local current = frame_position(win)
        if current.buf == target and current.view.lnum == line and not same_position(current, previous) then
          local navigation = state.navigation[win]
          local expected = navigation and navigation.expected or (state.after and state.after[win])
          local restore = navigation and navigation.restore or state.original[win]
          -- A user changed the buffer/view/content before the next native
          -- frame. That latest intent becomes the restoration point.
          if not same_position(previous, expected) then
            restore = previous
          end
          state.navigation[win] = { restore = restore, expected = current }
        end
      end
    end
  end
end

--- Explicit focus helper: never resurrect a split deliberately closed by a user.
function M.focus(state)
  local tab = vim.api.nvim_get_current_tabpage()
  local current = vim.api.nvim_get_current_win()
  if code_window(current, tab) then
    return current
  end
  if state and code_window(state.main, tab) then
    vim.api.nvim_set_current_win(state.main)
    return state.main
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if code_window(win, tab) then
      vim.api.nvim_set_current_win(win)
      return win
    end
  end
  local buf = vim.api.nvim_create_buf(true, false)
  local win = vim.api.nvim_open_win(buf, true, { split = "above", win = current })
  return win
end

--- Track one synchronous UI operation, including a borrowed shared bottom host.
function M.open(state, operation)
  local before = windows(state.tab)
  if
    state.after
    and (
      not vim.deep_equal(geometry(before), geometry(state.after))
      or not vim.deep_equal(tree(state.tab), state.after_tree)
    )
  then
    state.changed = true
  end
  operation()
  local after = windows(state.tab)
  for win, value in pairs(after) do
    local previous = before[win]
    local content = vim.bo[value.buf].filetype:find("^dap")
      or vim.b[value.buf].ue_bottom_panel_kind == "debug"
      or vim.b[value.buf].ue_bottom_panel_kind == "logcat"
    if not previous and content then
      state.owned[win] = value.buf
    elseif state.owned[win] then
      -- A source window adopted by the user is no longer ours to reclaim.
      if previous.buf == state.owned[win] then
        state.owned[win] = value.buf
      end
    elseif previous and previous.buf ~= value.buf and content then
      state.borrowed[win] = state.borrowed[win] or previous
      state.borrowed[win].content = value.buf
    end
    -- Splitting a window may move its viewport; preserve the reading position
    -- once at this explicit layout operation, never in a BufEnter/Cursor guard.
    if previous and previous.buf == value.buf and not state.owned[win] then
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(previous.view)
      end)
    end
  end
  state.after, state.after_tree = windows(state.tab), tree(state.tab)
end

local function project(node, removed, values)
  if node[1] == "leaf" then
    local win, value = node[2], values[node[2]]
    if removed[win] or not value or vim.api.nvim_win_get_config(win).relative ~= "" then
      return nil
    end
    return { kind = "leaf", win = win, width = value.width, height = value.height }
  end
  local children = {}
  for _, child in ipairs(node[2]) do
    local kept = project(child, removed, values)
    if kept then
      children[#children + 1] = kept
    end
  end
  if #children == 0 then
    return nil
  end
  if #children == 1 then
    return children[1]
  end
  local width, height = 0, 0
  for _, child in ipairs(children) do
    if node[1] == "row" then
      width, height = width + child.width, math.max(height, child.height)
    else
      width, height = math.max(width, child.width), height + child.height
    end
  end
  if node[1] == "row" then
    width = width + #children - 1
  else
    height = height + #children - 1
  end
  return { kind = node[1], children = children, width = width, height = height }
end

local function shape(node)
  if node.kind == "leaf" then
    return { "leaf", node.win }
  end
  local children = {}
  for _, child in ipairs(node.children) do
    children[#children + 1] = shape(child)
  end
  return { node.kind, children }
end

local function targets(node, width, height, result)
  if node.kind == "leaf" then
    result[node.win] = { width = width, height = height }
    return
  end
  local horizontal = node.kind == "row"
  local field = horizontal and "width" or "height"
  local available = (horizontal and width or height) - #node.children + 1
  local sum = 0
  for _, child in ipairs(node.children) do
    sum = sum + child[field]
  end
  local used = 0
  for i, child in ipairs(node.children) do
    local amount = i == #node.children and (available - used) or math.floor(available * child[field] / sum + 0.5)
    amount = math.max(1, amount)
    targets(child, horizontal and amount or width, horizontal and height or amount, result)
    used = used + amount
  end
end

local function detach_upstream(owned)
  local ok, ui_windows = pcall(require, "dapui.windows")
  if not ok then
    return
  end
  for _, layout in ipairs(ui_windows.layouts or {}) do
    local keep = {}
    for _, win in pairs(layout.opened_wins or {}) do
      if not owned[win] and vim.api.nvim_win_is_valid(win) then
        keep[#keep + 1] = win
      end
    end
    layout.opened_wins = keep
    for win in pairs(owned) do
      if layout.win_bufs then
        layout.win_bufs[win] = nil
      end
    end
  end
end

--- Release the current UI; retained or repurposed windows remain user's windows.
function M.close(state)
  if not state or not vim.api.nvim_tabpage_is_valid(state.tab) then
    return
  end
  local current = vim.api.nvim_get_current_win()
  local before, removed = windows(state.tab), {}
  local unchanged = state.after
    and not state.changed
    and vim.deep_equal(geometry(before), geometry(state.after))
    and vim.deep_equal(tree(state.tab), state.after_tree)
    and vim.deep_equal(state.screen, { vim.o.columns, vim.o.lines })
  for win, buf in pairs(state.owned) do
    if valid(win, state.tab) and vim.api.nvim_win_get_buf(win) == buf then
      removed[win] = true
    end
  end
  local wanted = project(tree(state.tab), removed, before)
  detach_upstream(state.owned)
  for win in pairs(removed) do
    pcall(vim.api.nvim_win_close, win, true)
  end
  for win, saved in pairs(state.borrowed) do
    if
      valid(win, state.tab)
      and vim.api.nvim_win_get_buf(win) == saved.content
      and vim.api.nvim_buf_is_valid(saved.buf)
    then
      vim.api.nvim_win_set_buf(win, saved.buf)
      local expected = state.after and state.after[win]
      for name, value in pairs(saved.options) do
        if expected and vim.wo[win][name] == expected.options[name] then
          vim.wo[win][name] = value
        end
      end
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(saved.view)
      end)
    end
  end
  if unchanged and vim.deep_equal(tree(state.tab), state.original_tree) then
    local anchor = vim.api.nvim_tabpage_get_win(state.tab)
    vim.api.nvim_win_call(anchor, function()
      vim.cmd(state.restore_sizes)
    end)
  elseif wanted and vim.deep_equal(tree(state.tab), shape(wanted)) then
    -- Retain the proportions of the user's latest topology after removing the
    -- debug rail/bottom area. Never rebuild a window or restore a closed split.
    local actual = project(tree(state.tab), {}, windows(state.tab))
    local sizes = {}
    targets(wanted, actual.width, actual.height, sizes)
    for _ = 1, 2 do
      for win, size in pairs(sizes) do
        pcall(vim.api.nvim_win_set_width, win, size.width)
        pcall(vim.api.nvim_win_set_height, win, size.height)
      end
    end
  end
  local restored_frames = {}
  for win, navigation in pairs(state.navigation) do
    if
      valid(win, state.tab)
      and same_position(before[win], navigation.expected)
      and vim.api.nvim_buf_is_valid(navigation.restore.buf)
    then
      vim.api.nvim_win_set_buf(win, navigation.restore.buf)
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(navigation.restore.view)
      end)
      restored_frames[win] = true
    end
  end
  for win, previous in pairs(before) do
    if not restored_frames[win] and valid(win, state.tab) and vim.api.nvim_win_get_buf(win) == previous.buf then
      local expected, original = state.after and state.after[win], state.original[win]
      local view = previous.view
      if original and expected and previous.buf == original.buf and vim.deep_equal(previous.view, expected.view) then
        view = original.view
      end
      vim.api.nvim_win_call(win, function()
        vim.fn.winrestview(view)
      end)
    end
  end
  if vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  elseif valid(state.main, state.tab) then
    vim.api.nvim_set_current_win(state.main)
  end
end

return M
