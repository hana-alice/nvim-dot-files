local M = {}

local DEFAULT = "tokyonight"
local ALIASES = {
  ubokai = "unokai",
  ubuntu = "ubuntu-terminal",
  catppuccin_frappe = "catppuccin-frappe",
  catppuccin_latte = "catppuccin-latte",
  catppuccin_macchiato = "catppuccin-macchiato",
  catppuccin_mocha = "catppuccin-mocha",
  rider = "rider-light",
  rider_light = "rider-light",
  ["rider light"] = "rider-light",
  white = "porcelain-white",
  porcelain = "porcelain-white",
  porcelain_white = "porcelain-white",
  ["porcelain white"] = "porcelain-white",
}
local picker = nil

local LABELS = {
  tokyonight = "Tokyo Night",
  catppuccin = "Catppuccin",
  ["catppuccin-frappe"] = "Catppuccin Frappe",
  ["catppuccin-latte"] = "Catppuccin Latte",
  ["catppuccin-macchiato"] = "Catppuccin Macchiato",
  ["catppuccin-mocha"] = "Catppuccin Mocha",
  kanagawa = "Kanagawa",
  monokai = "Monokai",
  monokai_pro = "Monokai Pro",
  monokai_soda = "Monokai Soda",
  monokai_ristretto = "Monokai Ristretto",
  unokai = "Unokai",
  ["ubuntu-terminal"] = "Ubuntu Terminal",
  ["rider-light"] = "Rider Light",
  ["porcelain-white"] = "Porcelain White",
  apprentice = "Apprentice",
}

local PLUGIN_BY_THEME = {
  tokyonight = "tokyonight.nvim",
  catppuccin = "catppuccin",
  ["catppuccin-frappe"] = "catppuccin",
  ["catppuccin-latte"] = "catppuccin",
  ["catppuccin-macchiato"] = "catppuccin",
  ["catppuccin-mocha"] = "catppuccin",
  kanagawa = "kanagawa.nvim",
  monokai = "monokai.nvim",
  monokai_pro = "monokai.nvim",
  monokai_soda = "monokai.nvim",
  monokai_ristretto = "monokai.nvim",
}

local function state_path()
  return vim.fn.stdpath("state") .. "/theme.txt"
end

local function normalize_name(name)
  name = vim.trim(tostring(name or ""))
  return ALIASES[name] or name
end

local function known_colors()
  local names = {}
  for name in pairs(LABELS) do
    table.insert(names, name)
  end
  return names
end

local function ensure_theme_loaded(name)
  local plugin = PLUGIN_BY_THEME[name]
  if not plugin then
    return
  end

  local ok, lazy = pcall(require, "lazy")
  if ok and lazy and type(lazy.load) == "function" then
    lazy.load({ plugins = { plugin } })
  end
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
  vim.fn.mkdir(vim.fn.fnamemodify(state_path(), ":h"), "p")
  vim.fn.writefile({ name }, state_path())
end

local function theme_names()
  local ordered = {}
  local seen = {}
  local function add(name)
    name = normalize_name(name)
    if name ~= "" and not seen[name] then
      seen[name] = true
      table.insert(ordered, name)
    end
  end

  for _, name in ipairs(known_colors()) do
    add(name)
  end
  add(read_state())

  if vim.tbl_isempty(ordered) then
    ordered = { DEFAULT }
  end

  table.sort(ordered, function(a, b)
    if a == DEFAULT then
      return true
    end
    if b == DEFAULT then
      return false
    end
    return a < b
  end)

  return ordered
end

local function has_theme(name)
  name = normalize_name(name)
  for _, item in ipairs(theme_names()) do
    if item == name then
      return true
    end
  end
  return false
end

local function theme_label(name)
  if LABELS[name] then
    return LABELS[name]
  end
  local label = name:gsub("[_-]+", " ")
  label = label:gsub("(%a)([%w']*)", function(first, rest)
    return string.upper(first) .. string.lower(rest)
  end)
  return label
end

function M.available()
  local items = {}
  for _, name in ipairs(theme_names()) do
    table.insert(items, {
      name = name,
      label = theme_label(name),
    })
  end
  return items
end

function M.complete()
  return theme_names()
end

function M.startup()
  local saved = normalize_name(read_state())
  if saved ~= "" then
    return saved
  end
  return DEFAULT
end

local function colorscheme_for(name)
  if name == "kanagawa" then
    return "kanagawa-dragon"
  end
  return name
end

function M.load_startup()
  local name = normalize_name(M.startup())
  if name == "" then
    name = DEFAULT
  end

  ensure_theme_loaded(name)
  local ok, err = pcall(vim.cmd.colorscheme, colorscheme_for(name))
  if ok then
    return
  end

  write_state(DEFAULT)
  ensure_theme_loaded(DEFAULT)
  vim.schedule(function()
    vim.notify(
      "Failed to load theme " .. name .. "; fell back to " .. DEFAULT .. "\n" .. tostring(err),
      vim.log.levels.WARN
    )
  end)

  vim.cmd.colorscheme(DEFAULT)
end

function M.current()
  local current = vim.g.colors_name
  if has_theme(current) then
    return current
  end
  return normalize_name(M.startup())
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

  ensure_theme_loaded(name)
  local ok, err = pcall(vim.cmd.colorscheme, colorscheme_for(name))
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

return M
