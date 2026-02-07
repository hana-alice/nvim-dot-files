-- ========= Minimal nvim config (UE-friendly) =========
vim.g.mapleader = " "
vim.g.maplocalleader = " "
vim.opt.number = true
vim.opt.relativenumber = true
vim.opt.termguicolors = true
vim.opt.mouse = "a"
vim.opt.clipboard = "unnamedplus"
vim.opt.updatetime = 250
vim.opt.signcolumn = "yes"
vim.opt.completeopt = { "menu", "menuone", "noselect" }

-- Persist undo (survives restarts) + reduce Windows file-lock surprises
vim.opt.undofile = true
vim.opt.undodir = vim.fn.stdpath("state") .. "/undo"
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.swapfile = false


-- Better searching
vim.opt.ignorecase = true
vim.opt.smartcase = true

-- Indent
vim.opt.expandtab = true
vim.opt.shiftwidth = 2
vim.opt.tabstop = 2

-- Use PowerShell as default shell (Windows)
vim.opt.shell = "pwsh"
vim.opt.shellcmdflag = "-NoLogo -NoProfile -ExecutionPolicy RemoteSigned -Command"
vim.opt.shellquote = ""
vim.opt.shellxquote = ""
vim.o.foldenable = false

-- 开真彩（必须，Windows Terminal + 现代主题必开）
vim.opt.termguicolors = true



-- Terminal: Esc to normal mode
vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })

-- Toggle terminal (single instance), hide by closing window, reuse buffer
local term_buf = nil
local term_win = nil

vim.keymap.set("n", "<leader>tt", function()
  -- 1) 如果终端窗口存在：隐藏（关闭窗口即可，保留 buffer）
  if term_win and vim.api.nvim_win_is_valid(term_win) then
    vim.api.nvim_win_close(term_win, true)
    term_win = nil
    return
  end

  -- 2) 打开（或复用）终端 buffer 到底部分屏
  if not term_buf or not vim.api.nvim_buf_is_valid(term_buf) then
    vim.cmd("botright split | resize 15 | terminal pwsh")
    term_win = vim.api.nvim_get_current_win()
    term_buf = vim.api.nvim_get_current_buf()
  else
    vim.cmd("botright split | resize 15")
    term_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(term_win, term_buf)
  end

  -- 3) 每次显示出来都进入输入模式（满足你“再次打开直接可输命令”）
  vim.cmd("startinsert")

  -- 4) no implicit cd here (pure toggle)
end, { desc = "Terminal: Toggle (pwsh, reuse buffer)" })

-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>t", "<leader>tt", { remap = true, silent = true })


-- Ensure terminal window is visible (reuse the same terminal buffer).
-- Unlike <leader>t toggle, this will OPEN if hidden but will NOT close it.
local function ensure_terminal_visible()
  if term_win and vim.api.nvim_win_is_valid(term_win) then
    return term_buf, term_win
  end

  if not term_buf or not vim.api.nvim_buf_is_valid(term_buf) then
    vim.cmd("botright split | resize 15 | terminal pwsh")
    term_win = vim.api.nvim_get_current_win()
    term_buf = vim.api.nvim_get_current_buf()
  else
    vim.cmd("botright split | resize 15")
    term_win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(term_win, term_buf)
  end

  vim.cmd("startinsert")
  return term_buf, term_win
end



-- Terminal: explicit cd helpers (no :cd / :lcd)
local function term_send_line(line)
  -- ensure terminal exists and get into its buffer
  local buf, win = ensure_terminal_visible()
  if not buf or not vim.api.nvim_buf_is_valid(buf) then
    vim.notify("Terminal not available", vim.log.levels.WARN)
    return
  end
  -- terminal_job_id is buffer-local; make sure we're in that buffer
  vim.api.nvim_set_current_win(win)
  if not vim.b.terminal_job_id then
    vim.notify("Terminal job not ready", vim.log.levels.WARN)
    return
  end
  vim.fn.chansend(vim.b.terminal_job_id, line .. "\r\n")
end

-- Statusline: show UEIndex/GTAGS progress in the status bar
vim.g.ueindex_status = vim.g.ueindex_status or ""
vim.o.statusline = "%f %m%r %= %{get(g:,'ueindex_status','')} %l:%c"

-- Show UEIndex/GTAGS progress in statusline (works with lualine too)
vim.g.ueindex_status = vim.g.ueindex_status or ""

local function ue_status()
  local s = vim.g.ueindex_status
  if not s or s == "" then return "" end
  return s
end

-- If lualine is present, inject a component (no window changes)
do
  local ok, lualine = pcall(require, "lualine")
  if ok and not vim.g._ue_lualine_injected then
    vim.g._ue_lualine_injected = true

    local cfg = {}
    pcall(function()
      cfg = lualine.get_config() or {}
    end)

    cfg.sections = cfg.sections or {}
    -- pick a section that typically exists
    cfg.sections.lualine_x = cfg.sections.lualine_x or {}

    -- avoid duplicate injection
    local already = false
    for _, c in ipairs(cfg.sections.lualine_x) do
      if type(c) == "function" and c == ue_status then
        already = true
        break
      end
    end
    if not already then
      table.insert(cfg.sections.lualine_x, 1, ue_status)
    end

    -- re-setup once to apply
    pcall(lualine.setup, cfg)
  elseif not ok then
    -- Fallback to builtin statusline (no lualine)
    vim.o.statusline = "%f %m%r %= %{get(g:,'ueindex_status','')} %l:%c"
  end
end
