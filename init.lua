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


-- Terminal: Esc to normal mode
vim.keymap.set("t", "<Esc>", [[<C-\><C-n>]], { desc = "Exit terminal mode" })

-- Toggle terminal (single instance), hide by closing window, reuse buffer
local term_buf = nil
local term_win = nil

local function term_cd_to_current_file_dir()
  local dir

  -- 终端 buffer 不要用 buf name（会是 term://...）
  if vim.bo.buftype == "terminal" then
    dir = vim.fn.getcwd()
  else
    local file = vim.api.nvim_buf_get_name(0)
    if file ~= nil and file ~= "" then
      dir = vim.fs.dirname(file)
    else
      dir = vim.fn.getcwd()
    end
  end

  if not dir or not vim.b.terminal_job_id then
    return
  end

  -- 你用的是 pwsh：不要 cd /d（那是 cmd.exe 的语法）
  local cmd = 'cd "' .. dir .. '"\r'
  vim.fn.chansend(vim.b.terminal_job_id, cmd)
end

vim.keymap.set("n", "<leader>t", function()
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

  -- 4) 可选：每次打开时 cd 到当前文件目录
  term_cd_to_current_file_dir()
end, { desc = "Toggle terminal (pwsh, reuse buffer, always startinsert)" })


-- ========== Bootstrap lazy.nvim ==========
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.uv.fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

-- ========== Plugins ==========
require("lazy").setup({
  -- File finding / grep
  { "nvim-lua/plenary.nvim" },
  {
    "nvim-telescope/telescope.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    config = function()
      local telescope = require("telescope")
      telescope.setup({
        defaults = {
          -- Respect .gitignore; critical for UE (Intermediate/DDC)
          file_ignore_patterns = {
            "DerivedDataCache/",
            "Intermediate/",
            "Saved/",
            "Binaries/",
          },
        },
      })
    end,
  },

  -- LSP
  { "neovim/nvim-lspconfig" },

  -- Optional but recommended: completion UI (kept minimal)
  { "hrsh7th/nvim-cmp" },
  { "hrsh7th/cmp-nvim-lsp" },
  
  -- Core fzf engine (git plugin, auto build/download binary)

	-- Modern Lua UI for fzf
	
	{
	  "ibhagwan/fzf-lua",
	  dependencies = { "junegunn/fzf" },
	},
	{
	  "nvim-treesitter/nvim-treesitter",
	  build = ":TSUpdate",
	},


  {
    "mikavilpas/yazi.nvim",
    version = "*",
    event = "VeryLazy",
    dependencies = 
    {
      { "nvim-lua/plenary.nvim", lazy = true },
    },
  },
  {
    "p00f/clangd_extensions.nvim",
    ft = { "c", "cpp", "objc", "objcpp" },
  }



}, {
  -- lazy options
  checker = { enabled = false },
})

-- ========== Keymaps ==========
local map = vim.keymap.set
map("n", "<leader>ff", function() require("telescope.builtin").find_files() end, { desc = "Find files" })
map("n", "<leader>fg", function() require("telescope.builtin").live_grep() end, { desc = "Live grep" })
map("n", "<leader>fb", function() require("telescope.builtin").buffers() end, { desc = "Buffers" })
map("n", "<leader>fh", function() require("telescope.builtin").help_tags() end, { desc = "Help" })

-- LSP keymaps (set on attach later)
-- ========== Completion ==========
local cmp = require("cmp")
cmp.setup({
  mapping = cmp.mapping.preset.insert({
    ["<C-Space>"] = cmp.mapping.complete(),
    ["<CR>"] = cmp.mapping.confirm({ select = true }),
  }),
  sources = {
    { name = "nvim_lsp" },
  },
})

-- ========== LSP (clangd) ==========
-- ========== LSP (Neovim 0.11+ native) ==========
local capabilities = require("cmp_nvim_lsp").default_capabilities()

local function on_attach(_, bufnr)
  local function bufmap(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
  end

  bufmap("n", "gd", vim.lsp.buf.definition, "Go to definition")
  bufmap("n", "gr", vim.lsp.buf.references, "References")
  bufmap("n", "K", vim.lsp.buf.hover, "Hover")
  bufmap("n", "<leader>rn", vim.lsp.buf.rename, "Rename")
  bufmap("n", "<leader>ca", vim.lsp.buf.code_action, "Code action")
  bufmap("n", "<leader>ds", vim.lsp.buf.document_symbol, "Document symbols")
  bufmap("n", "<leader>ws", vim.lsp.buf.workspace_symbol, "Workspace symbols")
end



-- Define clangd config
vim.lsp.config("clangd", {
  cmd = {
    "clangd",
    "--background-index",
    "--completion-style=detailed",
    "--header-insertion=never",
    "--pch-storage=memory",
    "--log=error",
    "--limit-results=200",
    "--limit-references=200",
    '--query-driver=**/clang++.exe,**/clang-cl.exe,**/aarch64-linux-android-clang++.exe,**/armv7a-linux-androideabi-clang++.exe',
  },

  capabilities = capabilities,

  root_markers = { "compile_commands.json", "*.uproject", ".git" },

  on_attach = function(client, bufnr)
    on_attach(client, bufnr)

    -- clangd_extensions
    pcall(function()
      require("clangd_extensions").setup()
    end)

    -- cpp ↔ h
    vim.keymap.set(
      "n",
      "<leader>h",
      "<cmd>ClangdSwitchSourceHeader<CR>",
      { buffer = bufnr, desc = "Switch source/header" }
    )
  end,
})

-- Enable clangd (and any other servers you add later)
vim.lsp.enable({ "clangd" })

-- UE shader filetypes (basic)
vim.filetype.add({
  extension = { usf = "hlsl", ush = "hlsl" },
})

-- =========FZF
local fzf = require('fzf-lua')
vim.keymap.set('n', '<leader>ff', fzf.files, { desc = '查找文件' })
vim.keymap.set('n', '<leader>fg', fzf.live_grep, { desc = '全局搜索字符串' })
vim.keymap.set('n', '<leader>fb', fzf.buffers, { desc = '查找打开的 Buffer' })
vim.keymap.set('n', '<leader>fh', fzf.help_tags, { desc = '查找帮助文档' })

-- =========YAZI
vim.keymap.set({ "n", "v" }, "<leader>e", "<cmd>Yazi<cr>", { desc = "Yazi file manager" })


vim.keymap.set("n", "<leader>q", ":bp | bd #<CR>", { silent = true })


-- 显示当前行错误
vim.keymap.set("n", "<leader>dd", vim.diagnostic.open_float, { desc = "Show diagnostics" })

-- 下一个 / 上一个错误
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Prev diagnostic" })

-- 当前文件错误列表
vim.keymap.set("n", "<leader>dl", function()
  vim.diagnostic.setloclist()
end, { desc = "Diagnostics list (buffer)" })

-- 全工程错误列表
vim.keymap.set("n", "<leader>dL", function()
  vim.diagnostic.setqflist()
end, { desc = "Diagnostics list (workspace)" })

