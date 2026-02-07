-- ========= Minimal nvim config (UE-friendly) =========
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
