local M = {}

local DEFAULT = "monokai_ristretto"
local THEMES = {
  { name = "monokai_ristretto", label = "Monokai Ristretto", plugin = "monokai.nvim" },
  { name = "rider-light", label = "Rider Light" },
  { name = "ubuntu-terminal", label = "Ubuntu Terminal" },
  { name = "unokai", label = "Unokai" },
  {
    name = "catppuccin",
    label = "Catppuccin",
    plugin = "catppuccin",
    current_pattern = "^catppuccin%-",
  },
  {
    name = "sonokai-espresso",
    label = "Sonokai Espresso",
    plugin = "sonokai",
    colorscheme = "sonokai",
    before = function()
      vim.g.sonokai_style = "espresso"
      -- Avoid Sonokai's synchronous first-use syntax-cache generation (the
      -- upstream docs allow up to five seconds); normal mode costs only tens
      -- of milliseconds and respects this config's no-main-loop-stall rule.
      vim.g.sonokai_better_performance = 0
    end,
  },
}
local THEME_BY_NAME = {}
for _, theme in ipairs(THEMES) do
  THEME_BY_NAME[theme.name] = theme
end

local picker = nil
local state_path_override = nil

local function state_path()
  return state_path_override or (vim.fn.stdpath("state") .. "/theme.txt")
end

local function normalize_name(name)
  return vim.trim(tostring(name or ""))
end

local function ensure_theme_loaded(theme)
  if not theme or not theme.plugin then
    return
  end

  local ok, lazy = pcall(require, "lazy")
  if ok and lazy and type(lazy.load) == "function" then
    lazy.load({ plugins = { theme.plugin } })
  end
end

local function load_theme(name)
  local theme = THEME_BY_NAME[name]
  if not theme then
    return false, "unknown theme"
  end

  ensure_theme_loaded(theme)
  if theme.before then
    theme.before()
  end
  return pcall(vim.cmd.colorscheme, theme.colorscheme or theme.name)
end

local function read_state()
  local path = state_path()
  if vim.fn.filereadable(path) ~= 1 then
    return ""
  end
  local lines = vim.fn.readfile(path)
  return vim.trim(lines[1] or "")
end

local function write_state(name)
  local path = state_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local temp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  vim.fn.writefile({ name }, temp)
  local ok = vim.uv.fs_rename(temp, path)
  if not ok then pcall(os.remove, temp) end
end

local function theme_names()
  local names = {}
  for _, theme in ipairs(THEMES) do
    names[#names + 1] = theme.name
  end
  return names
end

local function has_theme(name)
  return THEME_BY_NAME[normalize_name(name)] ~= nil
end

function M.available()
  local items = {}
  for _, theme in ipairs(THEMES) do
    items[#items + 1] = {
      name = theme.name,
      label = theme.label,
    }
  end
  return items
end

function M.complete()
  return theme_names()
end

function M.startup()
  local saved = normalize_name(read_state())
  if has_theme(saved) then
    return saved
  end
  return DEFAULT
end

function M.load_startup()
  local saved = normalize_name(read_state())
  local name = M.startup()
  if saved ~= "" and saved ~= name then
    write_state(name)
  end

  local ok, err = load_theme(name)
  if ok then
    return
  end

  write_state(DEFAULT)
  vim.schedule(function()
    vim.notify(
      "Failed to load theme " .. name .. "; fell back to " .. DEFAULT .. "\n" .. tostring(err),
      vim.log.levels.WARN
    )
  end)

  local fallback_ok, fallback_err = load_theme(DEFAULT)
  if not fallback_ok then
    error(fallback_err)
  end
end

function M.current()
  local current = normalize_name(vim.g.colors_name)
  for _, theme in ipairs(THEMES) do
    if current == (theme.colorscheme or theme.name)
      or (theme.current_pattern and current:match(theme.current_pattern))
    then
      return theme.name
    end
  end
  return M.startup()
end

function M.apply(name, opts)
  opts = opts or {}
  name = normalize_name(name)
  if name == "" then
    name = DEFAULT
  end
  if not has_theme(name) then
    require("utils.log").notify_error("theme", "Unknown theme: " .. name)
    return false
  end

  local ok, err = load_theme(name)
  if not ok then
    require("utils.log").notify_error("theme", "Failed to load theme " .. name .. ": " .. tostring(err))
    return false
  end

  if opts.persist ~= false then
    write_state(name)
  end
  if not opts.silent then
    vim.notify("Theme: " .. name)
  end
  return true
end

local function close_picker()
  if picker and picker.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, picker.augroup)
  end
  if picker and picker.win and vim.api.nvim_win_is_valid(picker.win) then
    vim.api.nvim_win_close(picker.win, true)
  end
  picker = nil
end

local function render_picker()
  if not picker or not vim.api.nvim_buf_is_valid(picker.buf) then
    return
  end

  local lines = {
    "Theme Picker",
    "j/k or arrows: preview   Enter: save   q/Esc: cancel",
    "",
  }

  local items = M.available()
  for index, item in ipairs(items) do
    local prefix = index == picker.index and "> " or "  "
    local mark = item.name == picker.original and "* " or "  "
    table.insert(lines, prefix .. mark .. item.label .. " [" .. item.name .. "]")
  end

  vim.bo[picker.buf].modifiable = true
  vim.api.nvim_buf_set_lines(picker.buf, 0, -1, false, lines)
  vim.bo[picker.buf].modifiable = false
  vim.api.nvim_win_set_cursor(picker.win, { picker.index + 3, 0 })
end

local function selected_theme()
  if not picker then
    return nil
  end
  local items = M.available()
  return items[picker.index]
end

local function preview_theme()
  local item = selected_theme()
  if not item or item.name == picker.previewed then
    return
  end
  if M.apply(item.name, { persist = false, silent = true }) then
    picker.previewed = item.name
  end
end

local function update_index_from_cursor()
  if not picker or not picker.win or not vim.api.nvim_win_is_valid(picker.win) then
    return
  end
  local line = vim.api.nvim_win_get_cursor(picker.win)[1] - 3
  local items = M.available()
  local index = math.max(1, math.min(#items, line))
  if index ~= picker.index then
    picker.index = index
    render_picker()
    preview_theme()
  end
end

local function move_picker(delta)
  if not picker then
    return
  end
  local items = M.available()
  picker.index = ((picker.index - 1 + delta) % #items) + 1
  render_picker()
  preview_theme()
end

local function confirm_picker()
  if not picker then
    return
  end
  local item = selected_theme()
  close_picker()
  if item then
    M.apply(item.name, { persist = true, silent = false })
  end
end

local function cancel_picker()
  if not picker then
    return
  end
  local original = picker.original
  close_picker()
  M.apply(original, { persist = false, silent = true })
end

function M.select()
  if picker and picker.win and vim.api.nvim_win_is_valid(picker.win) then
    vim.api.nvim_set_current_win(picker.win)
    return
  end

  local current = M.current()
  local items = M.available()
  local width = 52
  local height = #items + 3
  local row = math.floor((vim.o.lines - height) / 2 - 1)
  local col = math.floor((vim.o.columns - width) / 2)
  local buf = vim.api.nvim_create_buf(false, true)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    row = math.max(row, 1),
    col = math.max(col, 0),
    width = width,
    height = height,
    style = "minimal",
    border = "rounded",
    title = " Theme ",
    title_pos = "center",
    noautocmd = true,
  })

  picker = {
    buf = buf,
    win = win,
    original = current,
    previewed = current,
    index = 1,
    augroup = vim.api.nvim_create_augroup("UEThemePicker", { clear = true }),
  }

  for index, item in ipairs(items) do
    if item.name == current then
      picker.index = index
      break
    end
  end

  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].modifiable = false
  vim.bo[buf].filetype = "theme-picker"
  vim.wo[win].cursorline = true
  vim.wo[win].wrap = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  render_picker()

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = picker.augroup,
    buffer = buf,
    callback = update_index_from_cursor,
  })

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "j", function()
    move_picker(1)
  end, opts)
  vim.keymap.set("n", "k", function()
    move_picker(-1)
  end, opts)
  vim.keymap.set("n", "<Down>", function()
    move_picker(1)
  end, opts)
  vim.keymap.set("n", "<Up>", function()
    move_picker(-1)
  end, opts)
  vim.keymap.set("n", "<CR>", confirm_picker, opts)
  vim.keymap.set("n", "q", cancel_picker, opts)
  vim.keymap.set("n", "<Esc>", cancel_picker, opts)
end

function M.close()
  cancel_picker()
end

function M._set_state_path_for_test(path)
  state_path_override = path
end

return M
