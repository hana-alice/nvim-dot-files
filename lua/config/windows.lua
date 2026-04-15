local M = {}

local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

local function current_cwd()
  if vim.uv and vim.uv.cwd then
    return vim.uv.cwd()
  end
  return vim.fn.getcwd()
end

local function terminal_shell()
  if vim.fn.executable("pwsh") == 1 then
    return "pwsh"
  end
  if vim.fn.executable("powershell") == 1 then
    return "powershell"
  end
  return vim.o.shell ~= "" and vim.o.shell or "cmd.exe"
end

local function windows_path(path)
  return tostring(path or ""):gsub("/", "\\")
end

local function cmd_quote(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

local function get_term_state()
  return _G.ue_term_buf, _G.ue_term_win
end

local function set_term_state(buf, win)
  _G.ue_term_buf = buf
  _G.ue_term_win = win
end

local function open_terminal()
  vim.cmd("botright split | resize 15")
  vim.cmd("terminal")
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  set_term_state(buf, win)
  vim.cmd("startinsert")
  return buf, win
end

local function ensure_terminal_visible()
  local term_buf, term_win = get_term_state()

  if term_win and vim.api.nvim_win_is_valid(term_win) then
    return term_buf, term_win
  end

  if term_buf and vim.api.nvim_buf_is_valid(term_buf) then
    vim.cmd("botright split | resize 15")
    term_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(term_win, term_buf)
    set_term_state(term_buf, term_win)
    vim.cmd("startinsert")
    return term_buf, term_win
  end

  return open_terminal()
end

local function term_send_line(line)
  local buf, win = ensure_terminal_visible()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("Terminal not available", vim.log.levels.WARN)
    return
  end

  vim.api.nvim_set_current_win(win)
  if not vim.b.terminal_job_id then
    vim.notify("Terminal job not ready", vim.log.levels.WARN)
    return
  end

  vim.fn.chansend(vim.b.terminal_job_id, line .. "\r\n")
end

local function term_cd(dir)
  if not dir or dir == "" then
    return
  end
  term_send_line('cd "' .. dir .. '"')
end

local function open_in_explorer(path, select_file)
  path = windows_path(path)
  if path == "" then
    return
  end

  local command
  if select_file then
    command = 'start "" explorer.exe /select,' .. cmd_quote(path)
  else
    command = 'start "" explorer.exe ' .. cmd_quote(path)
  end

  local job = vim.fn.jobstart({ "cmd.exe", "/c", command }, { detach = true })
  if job <= 0 then
    vim.notify("Failed to launch Explorer for: " .. path, vim.log.levels.ERROR)
  end
end

local function reveal_current_file()
  local file = vim.api.nvim_buf_get_name(0)
  if file ~= "" and vim.fn.filereadable(file) == 1 then
    open_in_explorer(file, true)
    return
  end

  local dir = vim.fn.expand("%:p:h")
  if dir == "" or vim.fn.isdirectory(dir) ~= 1 then
    dir = current_cwd()
  end
  if dir == "" then
    vim.notify("No file or directory to reveal", vim.log.levels.WARN)
    return
  end

  open_in_explorer(dir, false)
end

local function setup_options()
  vim.g.ueindex_status = vim.g.ueindex_status or ""

  vim.opt.clipboard = "unnamedplus"
  -- Keep Neovim mouse support enabled, but don't show the old popup menu on right click.
  vim.opt.mouse = "a"
  vim.opt.mousemodel = "extend"
  vim.cmd("silent! aunmenu PopUp")
  vim.opt.undofile = true
  vim.opt.undodir = vim.fn.stdpath("state") .. "/undo"
  vim.opt.backup = false
  vim.opt.writebackup = false
  vim.opt.swapfile = false
  vim.o.foldenable = false
  vim.o.statusline = "%f %m%r %= %{get(g:,'ueindex_status','')} %l:%c"

  if vim.fn.executable("pwsh") == 1 then
    vim.opt.shell = "pwsh"
    vim.opt.shellcmdflag = "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -Command"
    vim.opt.shellquote = ""
    vim.opt.shellxquote = ""
  end
end

local function setup_keymaps()
  vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })

  vim.keymap.set("n", "<leader>tt", function()
    local term_buf, term_win = get_term_state()
    if term_win and vim.api.nvim_win_is_valid(term_win) then
      vim.api.nvim_win_close(term_win, true)
      set_term_state(term_buf, nil)
      return
    end

    ensure_terminal_visible()
  end, { desc = "Terminal: Toggle (" .. terminal_shell() .. ", reuse buffer)" })

  vim.keymap.set("n", "<leader>t", "<leader>tt", { remap = true, silent = true })
  pcall(vim.keymap.del, "n", "<leader>fE")
  pcall(vim.keymap.del, "n", "<leader>E")
  vim.keymap.set("n", "<leader>E", reveal_current_file, { desc = "Open: Reveal current file in Explorer" })
  vim.keymap.set("n", "<leader>oe", reveal_current_file, { desc = "Open: Reveal current file in Explorer" })

  vim.keymap.set("n", "<leader>tc", function()
    local dir = vim.fn.expand("%:p:h")
    if not dir or dir == "" then
      vim.notify("No current file directory", vim.log.levels.WARN)
      return
    end
    term_cd(dir)
  end, { desc = "Terminal: cd to current file dir" })

  vim.keymap.set("n", "<leader>tp", function()
    local root = current_cwd()
    local matches = vim.fn.globpath(root, "*.uproject", false, true)
    if type(matches) ~= "table" or #matches == 0 then
      vim.notify("No .uproject in cwd. :cd to the project root first.", vim.log.levels.WARN)
      return
    end
    term_cd(root)
  end, { desc = "Terminal: cd to UE project root (cwd)" })

  vim.keymap.set("n", "<leader>te", function()
    local ok, ue = pcall(require, "ue")
    if not ok or type(ue.ue_roots) ~= "function" then
      vim.notify('require("ue").ue_roots() not available', vim.log.levels.WARN)
      return
    end

    local _, engine_root, err = ue.ue_roots()
    if err or not engine_root or engine_root == "" then
      vim.notify("UE engine root not detected. Ensure cwd is a .uproject dir.", vim.log.levels.WARN)
      return
    end

    term_cd(engine_root)
  end, { desc = "Terminal: cd to UE engine root" })
end

function M.setup()
  if not is_windows then
    return
  end

  _G.ue_term_buf = _G.ue_term_buf or nil
  _G.ue_term_win = _G.ue_term_win or nil

  setup_options()
  setup_keymaps()
  vim.api.nvim_create_user_command("RevealInExplorer", reveal_current_file, {
    desc = "Reveal current file in Explorer",
  })
end

return M
