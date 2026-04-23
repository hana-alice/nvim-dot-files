local M = {}

local state = {
  last = "buffers",
  transition_id = 0,
  menu = {
    buf = nil,
    win = nil,
    items = nil,
    index = 1,
  },
}

local trouble_modes = {
  git_status = "ue_sidebar_git_status",
  buffers = "ue_sidebar_buffers",
  symbols = "ue_sidebar_symbols",
  diagnostics = "ue_sidebar_diagnostics",
  qflist = "ue_sidebar_qflist",
  loclist = "ue_sidebar_loclist",
  todo = "ue_sidebar_todo",
}

local mode_labels = {
  git_status = "Git Modified Files",
  buffers = "Open Buffers",
  symbols = "File Symbols",
  diagnostics = "Diagnostics",
  qflist = "Pinned Results (Quickfix)",
  loclist = "Location List",
  todo = "TODO / FIXME",
}

local mode_order = { "git_status", "buffers", "symbols", "diagnostics", "qflist", "loclist", "todo" }

local aliases = {
  git = "git_status",
  modified = "git_status",
  quickfix = "qflist",
  qf = "qflist",
  location = "loclist",
  loc = "loclist",
  todos = "todo",
}

local function normalize_mode(kind)
  if type(kind) ~= "string" then
    return nil
  end
  return aliases[kind] or kind
end

local function next_transition_id()
  state.transition_id = state.transition_id + 1
  return state.transition_id
end

local function menu_is_open()
  return state.menu.win and vim.api.nvim_win_is_valid(state.menu.win) and state.menu.buf and vim.api.nvim_buf_is_valid(state.menu.buf)
end

local function close_menu()
  if state.menu.win and vim.api.nvim_win_is_valid(state.menu.win) then
    pcall(vim.api.nvim_win_close, state.menu.win, true)
  end
  if state.menu.buf and vim.api.nvim_buf_is_valid(state.menu.buf) then
    pcall(vim.api.nvim_buf_delete, state.menu.buf, { force = true })
  end
  state.menu.buf = nil
  state.menu.win = nil
  state.menu.items = nil
  state.menu.index = 1
end

local function trouble_instance()
  local ok, trouble = pcall(require, "trouble")
  return ok and trouble or nil
end

local function close_trouble_sidebars(except_kind)
  local trouble = trouble_instance()
  if not trouble then
    return false
  end

  local closed = false
  for kind, mode in pairs(trouble_modes) do
    if kind ~= except_kind and trouble.is_open(mode) then
      trouble.close(mode)
      closed = true
    end
  end

  return closed
end

local function open_trouble(kind)
  local trouble = trouble_instance()
  if not trouble then
    require("utils.log").notify_error("sidebar", "Trouble is unavailable")
    return
  end

  trouble.open(trouble_modes[kind])
end

local function schedule_open(kind, delay)
  local transition_id = next_transition_id()
  local run = function()
    if transition_id ~= state.transition_id then
      return
    end
    open_trouble(kind)
  end

  if delay and delay > 0 then
    vim.defer_fn(function()
      vim.schedule(run)
    end, delay)
  else
    vim.schedule(run)
  end
end

local function menu_items()
  local items = {}
  for _, kind in ipairs(mode_order) do
    local label = mode_labels[kind]
    if M.is_open(kind) then
      label = label .. " [open]"
    elseif state.last == kind then
      label = label .. " [last]"
    end
    items[#items + 1] = { kind = kind, label = label }
  end
  return items
end

local function render_menu()
  if not menu_is_open() then
    return
  end

  local lines = {
    "Sidebar Views",
    "1-7 choose  j/k move  Enter confirm  q close",
    "",
  }

  local items = state.menu.items or {}
  for i, item in ipairs(items) do
    local prefix = i == state.menu.index and ">" or " "
    lines[#lines + 1] = string.format("%s %d. %s", prefix, i, item.label)
  end

  vim.bo[state.menu.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.menu.buf, 0, -1, false, lines)
  vim.bo[state.menu.buf].modifiable = false

  local row = math.min(#lines, state.menu.index + 3)
  pcall(vim.api.nvim_win_set_cursor, state.menu.win, { row, 0 })
end

local function menu_move(delta)
  if not menu_is_open() or not state.menu.items or #state.menu.items == 0 then
    return
  end
  state.menu.index = ((state.menu.index - 1 + delta) % #state.menu.items) + 1
  render_menu()
end

local function menu_choose(index)
  if not menu_is_open() or not state.menu.items then
    return
  end

  local item = state.menu.items[index or state.menu.index]
  close_menu()
  if item and item.kind then
    M.open(item.kind)
  end
end

local function open_menu()
  close_menu()

  state.menu.items = menu_items()
  for i, item in ipairs(state.menu.items) do
    if item.kind == state.last then
      state.menu.index = i
      break
    end
  end

  local width = 0
  for _, item in ipairs(state.menu.items) do
    width = math.max(width, #item.label + 8)
  end
  width = math.max(width, 42)

  local height = #state.menu.items + 3
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "ue-sidebar-picker"

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    title = " Sidebar ",
    title_pos = "center",
    width = width,
    height = height,
    row = math.max(math.floor((vim.o.lines - height) / 2) - 1, 1),
    col = math.max(math.floor((vim.o.columns - width) / 2), 1),
  })

  state.menu.buf = buf
  state.menu.win = win

  local opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set("n", "q", close_menu, opts)
  vim.keymap.set("n", "<Esc>", close_menu, opts)
  vim.keymap.set("n", "j", function() menu_move(1) end, opts)
  vim.keymap.set("n", "k", function() menu_move(-1) end, opts)
  vim.keymap.set("n", "<Down>", function() menu_move(1) end, opts)
  vim.keymap.set("n", "<Up>", function() menu_move(-1) end, opts)
  vim.keymap.set("n", "<Tab>", function() menu_move(1) end, opts)
  vim.keymap.set("n", "<S-Tab>", function() menu_move(-1) end, opts)
  vim.keymap.set("n", "<CR>", function() menu_choose() end, opts)
  for i = 1, math.min(#state.menu.items, 9) do
    local idx = i
    vim.keymap.set("n", tostring(idx), function() menu_choose(idx) end, opts)
  end

  render_menu()
end

function M.is_open(kind)
  kind = normalize_mode(kind)
  if not kind then
    return false
  end

  local mode = trouble_modes[kind]
  if not mode then
    return false
  end

  local trouble = trouble_instance()
  return trouble and trouble.is_open(mode) or false
end

function M.is_any_open()
  local trouble = trouble_instance()
  if not trouble then
    return false
  end

  for _, mode in pairs(trouble_modes) do
    if trouble.is_open(mode) then
      return true
    end
  end

  return false
end

function M.close()
  next_transition_id()
  close_menu()
  return close_trouble_sidebars()
end

function M.open(kind)
  kind = normalize_mode(kind or state.last)
  if not kind or not mode_labels[kind] then
    require("utils.log").notify_error("sidebar", "Unknown sidebar mode: " .. tostring(kind))
    return
  end

  if M.is_open(kind) then
    open_trouble(kind)
    return
  end

  close_menu()
  state.last = kind

  if kind == "git_status" then
    pcall(function()
      require("trouble.sources.ue_sidebar").request_refresh("git_status")
    end)
  end

  local had_sidebar = M.is_any_open()
  close_trouble_sidebars()
  schedule_open(kind, had_sidebar and 10 or 0)
end

function M.toggle(kind)
  kind = normalize_mode(kind)
  if kind == nil then
    if M.is_any_open() then
      M.close()
    else
      M.open(state.last)
    end
    return
  end

  if M.is_open(kind) then
    M.close()
  else
    M.open(kind)
  end
end

function M.pick()
  if menu_is_open() then
    close_menu()
  else
    open_menu()
  end
end

return M
