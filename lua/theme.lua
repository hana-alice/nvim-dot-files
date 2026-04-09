local M = {}

local DEFAULT = "tokyonight"
local picker = nil

local LABELS = {
  tokyonight = "Tokyo Night",
  catppuccin = "Catppuccin",
  catppuccin_frappe = "Catppuccin Frappe",
  catppuccin_latte = "Catppuccin Latte",
  catppuccin_macchiato = "Catppuccin Macchiato",
  catppuccin_mocha = "Catppuccin Mocha",
  bamboo = "Bamboo",
  ["bamboo-vulgaris"] = "Bamboo Vulgaris",
  ["bamboo-multiplex"] = "Bamboo Multiplex",
  ["bamboo-light"] = "Bamboo Light",
  gruvbox = "Gruvbox",
  kanagawa = "Kanagawa",
  onedark = "One Dark",
  onelight = "One Light",
  onedark_vivid = "One Dark Vivid",
  onedark_dark = "One Dark Dark",
  Evergarden = "Evergarden",
  ["github_light"] = "GitHub Light",
  ["github_light_default"] = "GitHub Light Default",
  ["github_light_high_contrast"] = "GitHub Light High Contrast",
  ["github_light_colorblind"] = "GitHub Light Colorblind",
  ["github_light_tritanopia"] = "GitHub Light Tritanopia",
  ["github_dark"] = "GitHub Dark",
  ["github_dark_default"] = "GitHub Dark Default",
  ["rose-pine"] = "Rosé Pine",
  ["rose-pine-moon"] = "Rosé Pine Moon",
  ["rose-pine-dawn"] = "Rosé Pine Dawn",
  dayfox = "Dayfox",
  dawnfox = "Dawnfox",
  nightfox = "Nightfox",
  nordfox = "Nordfox",
  vscode = "VSCode",
  ["ubuntu-terminal"] = "Ubuntu Terminal",
  habamax = "Habamax",
}

local PLUGIN_BY_THEME = {
  tokyonight = "tokyonight.nvim",
  catppuccin = "catppuccin",
  catppuccin_frappe = "catppuccin",
  catppuccin_latte = "catppuccin",
  catppuccin_macchiato = "catppuccin",
  catppuccin_mocha = "catppuccin",
  bamboo = "bamboo",
  ["bamboo-vulgaris"] = "bamboo",
  ["bamboo-multiplex"] = "bamboo",
  ["bamboo-light"] = "bamboo",
  gruvbox = "gruvbox",
  kanagawa = "kanagawa",
  onedark = "onedarkpro.nvim",
  onelight = "onedarkpro.nvim",
  onedark_vivid = "onedarkpro.nvim",
  onedark_dark = "onedarkpro.nvim",
  Evergarden = "Evergarden",
  github_light = "github-nvim-theme",
  github_light_default = "github-nvim-theme",
  github_light_high_contrast = "github-nvim-theme",
  github_light_colorblind = "github-nvim-theme",
  github_light_tritanopia = "github-nvim-theme",
  github_dark = "github-nvim-theme",
  github_dark_default = "github-nvim-theme",
  ["rose-pine"] = "rose-pine",
  ["rose-pine-moon"] = "rose-pine",
  ["rose-pine-dawn"] = "rose-pine",
  dayfox = "nightfox.nvim",
  dawnfox = "nightfox.nvim",
  nightfox = "nightfox.nvim",
  nordfox = "nightfox.nvim",
  vscode = "vscode.nvim",
}

local function state_path()
  return vim.fn.stdpath("state") .. "/theme.txt"
end

local function normalize_name(name)
  return vim.trim(tostring(name or ""))
end

local function runtime_colors()
  local files = vim.api.nvim_get_runtime_file("colors/*.*", true)
  local names = {}
  local seen = {}
  local vimruntime = normalize_name(vim.env.VIMRUNTIME)

  for _, file in ipairs(files) do
    file = normalize_name(file)
    if vimruntime == "" or file:sub(1, #vimruntime) ~= vimruntime then
      local name = vim.fn.fnamemodify(file, ":t:r")
      if name ~= "" and not seen[name] then
        seen[name] = true
        table.insert(names, name)
      end
    end
  end

  return names
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
  for _, name in ipairs(runtime_colors()) do
    add(name)
  end
  local saved = normalize_name(vim.fn.filereadable(state_path()) == 1 and (vim.fn.readfile(state_path())[1] or "") or "")

  add(saved)

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
  local saved = read_state()
  if saved ~= "" then
    return saved
  end
  return DEFAULT
end

function M.load_startup()
  local name = normalize_name(M.startup())
  if name == "" then
    name = DEFAULT
  end

  ensure_theme_loaded(name)
  local ok, err = pcall(vim.cmd.colorscheme, name)
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
  return M.startup()
end

function M.apply(name, opts)
  opts = opts or {}
  name = vim.trim(tostring(name or ""))
  if name == "" then
    name = DEFAULT
  end
  if not has_theme(name) then
    vim.notify("Unknown theme: " .. name, vim.log.levels.ERROR)
    return false
  end

  ensure_theme_loaded(name)
  local ok, err = pcall(vim.cmd.colorscheme, name)
  if not ok then
    vim.notify("Failed to load theme " .. name .. ": " .. tostring(err), vim.log.levels.ERROR)
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
