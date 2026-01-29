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
vim.o.foldenable = false

-- 开真彩（必须，Windows Terminal + 现代主题必开）
vim.opt.termguicolors = true



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
    lazy = false,      -- main 分支要求：不要 lazy-load
    build = ":TSUpdate",
  },

  {
    "numToStr/Comment.nvim",
    opts = {},
    lazy = false,
  },


  { "folke/tokyonight.nvim", lazy = false, priority = 1000 },

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


-- ===== UE roots from .uproject EngineAssociation (Windows HKCU Builds) =====
local function find_nearest_uproject(start_dir)
  start_dir = start_dir or vim.loop.cwd()
  local matches = vim.fs.find(function(name)
    return name:sub(-9) == ".uproject"
  end, { path = start_dir, upward = true, type = "file" })
  return matches[1]
end

local function read_all(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local s = f:read("*a")
  f:close()
  return s
end

local function extract_engine_assoc(uproject_path)
  local txt = read_all(uproject_path)
  if not txt then return nil end
  -- 不固定行数：任意空白/换行都能匹配
  return txt:match([["EngineAssociation"%s*:%s*"([^"]+)"]])
end

local function reg_query_builds_hkcu(name)
  local key = [[HKCU\Software\Epic Games\Unreal Engine\Builds]]
  local out = vim.fn.systemlist(string.format([[reg query "%s" /v "%s"]], key, name))
  for _, line in ipairs(out) do
    local k, typ, val = line:match("^%s*(%S+)%s+(REG_%S+)%s+(.+)%s*$")
    if k == name and val and #val > 0 then
      return val:gsub("\\", "/")
    end
  end
  return nil
end

local function trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end


local function ue_roots()
  local uproject = find_nearest_uproject()
  if not uproject then
    return nil, nil, "No .uproject found upward from cwd"
  end
  local project_root = vim.fs.dirname(uproject)

  local assoc = extract_engine_assoc(uproject)
  if not assoc then
    return project_root, nil, "EngineAssociation not found in .uproject"
  end

  -- 你现在是 GUID：{...}
  local engine_root = nil
  if assoc:match("^%b{}$") then
    engine_root = reg_query_builds_hkcu(assoc)
    if not engine_root then
      return project_root, nil, "Engine GUID not found in HKCU Builds: " .. assoc
    end
  else
    return project_root, nil, "EngineAssociation is not GUID: " .. assoc
  end

	engine_root = trim(engine_root)
	project_root = trim(project_root)

  return project_root, engine_root, nil
end

vim.api.nvim_create_user_command("UEPaths", function()
  local project_root, engine_root, err = ue_roots()

  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  vim.notify(
    "Project: " .. project_root ..
    "\nEngine: " .. engine_root
  )
end, {})

-- ===== UE file index (Project + Engine) =====

local function win_quote(p)
  -- cmd.exe 里用双引号包路径即可
  return '"' .. p:gsub('"', '\\"') .. '"'
end

local function ensure_dir(dir)
  if vim.fn.isdirectory(dir) == 0 then
    vim.fn.mkdir(dir, "p")
  end
end

local function ue_index_path(project_root)
  local cache_dir = project_root .. "/.cache"
  ensure_dir(cache_dir)
  return cache_dir .. "/ue_files.txt"
end

local function build_ue_index()
  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify("UEIndex failed: " .. err, vim.log.levels.WARN)
    return nil
  end

  local index_path = ue_index_path(project_root)

  -- ignore 文件（只需要写一次规则，不逐命令）
  local ignore_args = ""
  local p_ignore = project_root .. "/.ignore"
  if vim.fn.filereadable(p_ignore) == 1 then
    ignore_args = ignore_args .. " --ignore-file " .. win_quote(p_ignore)
  end
  -- 可选：如果 Engine 也有 .ignore 就一起用（你不想改 Engine 的话可以不放）
  local e_ignore = engine_root .. "/.ignore"
  if vim.fn.filereadable(e_ignore) == 1 then
    ignore_args = ignore_args .. " --ignore-file " .. win_quote(e_ignore)
  end

  -- 生成索引：一次扫盘，输出到文件（不要在 Lua 里捕获大输出）
  -- 注意：这里不写一堆 --exclude，排除策略建议放到 .ignore（一次配置）
  -- 只索引项目里的 C++ 相关目录：Source + Plugins
  local project_src = project_root .. "/Source"
  local project_plg = project_root .. "/Plugins"

  local cmd = table.concat({
    "fd",
    "--type", "f",
    "--hidden",
    "--follow",
    ignore_args,
    "--search-path", win_quote(project_src),
    "--search-path", win_quote(project_plg),
    "--search-path", win_quote(engine_root),
  }, " ")


  local lines = vim.fn.systemlist(cmd)

  if vim.v.shell_error ~= 0 then
    vim.notify("fd failed: shell_error=" .. vim.v.shell_error, vim.log.levels.ERROR)
    return nil
  end

  vim.fn.writefile(lines, index_path)
	vim.notify(("UEIndex generated (%d files): %s"):format(#lines, index_path))

  return index_path
end

-- 命令：:UEIndex 生成/刷新索引
vim.api.nvim_create_user_command("UEIndex", function()
  build_ue_index()
end, {})

-- 用索引打开文件（如果索引不存在就先生成）
local function ue_files_from_index()
  local project_root, _, err = ue_roots()
  if err then
    vim.notify("UE files failed: " .. err, vim.log.levels.WARN)
    return
  end

  local index_path = ue_index_path(project_root)
  if vim.fn.filereadable(index_path) == 0 then
    index_path = build_ue_index()
    if not index_path then return end
  end

  local fzf = require("fzf-lua")
  local actions = require("fzf-lua.actions")

  -- 用 powershell 流式输出索引，不进 Lua table，快
  local cmd = string.format(
    [[powershell -NoProfile -Command "Get-Content -LiteralPath '%s'"]],
    index_path
  )

  fzf.fzf_exec(cmd, {
    prompt = "UE Files> ",
    actions = {
      ["default"] = actions.file_edit,
      ["ctrl-s"]  = actions.file_split,
      ["ctrl-v"]  = actions.file_vsplit,
      ["ctrl-t"]  = actions.file_tabedit,
    },
  })
end

-- 你要的：<leader>fF 走索引（快）
vim.keymap.set("n", "<leader>fF", ue_files_from_index, { desc = "FZF: UE Files (index)" })


-- 可选：给一个快捷键手动刷新索引
vim.keymap.set("n", "<leader>fI", function()
  build_ue_index()
end, { desc = "UE: Rebuild file index" })



-- ========== Keymaps ==========
local map = vim.keymap.set
-- map("n", "<leader>ff", function() require("telescope.builtin").find_files() end, { desc = "Find files" })
-- map("n", "<leader>fg", function() require("telescope.builtin").live_grep() end, { desc = "Live grep" })
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
-- local fzf = require('fzf-lua')
-- vim.keymap.set('n', '<leader>ff', fzf.files, { desc = '查找文件' })
-- vim.keymap.set('n', '<leader>fg', fzf.live_grep, { desc = '全局搜索字符串' })
-- vim.keymap.set('n', '<leader>fb', fzf.buffers, { desc = '查找打开的 Buffer' })
-- vim.keymap.set('n', '<leader>fh', fzf.help_tags, { desc = '查找帮助文档' })

local builtin = require("telescope.builtin")

-- 文件 / grep
-- vim.keymap.set("n", "<leader>ff", builtin.find_files, { desc = "Find Files" })
-- vim.keymap.set("n", "<leader>fg", builtin.live_grep,  { desc = "Live Grep (ripgrep)" })


local builtin = require("telescope.builtin")

local function ue_telescope_roots()
  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return nil
  end
  return { project_root, engine_root }
end

-- Space f f：从 Project + Engine 找文件
vim.keymap.set("n", "<leader>ff", function()
  local dirs = ue_telescope_roots()
  if not dirs then return end
  builtin.find_files({
    search_dirs = dirs,
    hidden = true,
  })
end, { desc = "Telescope: Find files (Project + Engine)" })

-- Space f g：从 Project + Engine grep
vim.keymap.set("n", "<leader>fg", function()
  local dirs = ue_telescope_roots()
  if not dirs then return end
  builtin.live_grep({
    search_dirs = dirs,
    additional_args = function()
      return {
        "--hidden",
        "--follow",
        "--glob=!.git/*",
        "--glob=!**/Binaries/**",
        "--glob=!**/Intermediate/**",
        "--glob=!**/Saved/**",
        "--glob=!**/DerivedDataCache/**",
        "--glob=!**/Content/**",
      }
    end,
  })
end, { desc = "Telescope: Live grep (Project + Engine)" })


-- 最近文件 / buffer
vim.keymap.set("n", "<leader>fr", builtin.oldfiles,  { desc = "Recent Files" })
vim.keymap.set("n", "<leader>fb", builtin.buffers,   { desc = "Buffers" })

-- LSP（以后你上 clangd 会非常爽）
vim.keymap.set("n", "gr", builtin.lsp_references,    { desc = "LSP References" })
vim.keymap.set("n", "gd", builtin.lsp_definitions,  { desc = "LSP Definitions" })
vim.keymap.set("n", "gi", builtin.lsp_implementations, { desc = "LSP Implementations" })


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

local function ensure_yazi_keymap_block()
  -- 你的真实 yazi 配置目录
  local yazi_config_dir = (os.getenv("APPDATA") or "") .. "\\yazi\\config"
  if yazi_config_dir == "\\yazi\\config" then
    return
  end

  local keymap_path = yazi_config_dir .. "\\keymap.toml"

  -- 用“标记块”确保幂等：每次都替换这段，而不是 append
  local begin_mark = "# >>> managed by nvim (show-in-explorer)"
  local end_mark   = "# <<< managed by nvim (show-in-explorer)"

  local managed_block = table.concat({
    begin_mark,
    '[[mgr.prepend_keymap]]',
    'on   = "E"',  -- Shift+E
    'run  = \'shell --orphan -- explorer.exe /select,"%h"\'',
    'desc = "Show in Explorer"',
    end_mark,
    "",
  }, "\n")

  vim.fn.mkdir(yazi_config_dir, "p")

  local content = ""
  if vim.fn.filereadable(keymap_path) == 1 then
    content = table.concat(vim.fn.readfile(keymap_path), "\n")
  end

  -- 1) 先删除所有旧的 managed 块（哪怕重复多次）
  local pattern = vim.pesc(begin_mark) .. ".*" .. vim.pesc(end_mark) .. "\n?"
  content = content:gsub(pattern, "")

  -- 2) 末尾补一个换行再追加“唯一的”新块
  if content ~= "" and not content:match("\n$") then
    content = content .. "\n"
  end
  content = content .. managed_block

  vim.fn.writefile(vim.split(content, "\n", { plain = true }), keymap_path)
end

-- 启动时运行一次（也可以改成你想要的时机）
vim.api.nvim_create_autocmd("VimEnter", {
  callback = ensure_yazi_keymap_block,
})

-- ========== Treesitter (nvim-treesitter main rewrite) ==========
local ts = require("nvim-treesitter")

ts.setup({
  -- 你也可以不配 install_dir，用默认即可；这里显式写出来方便你排查安装目录
  install_dir = vim.fn.stdpath("data") .. "/site",
})

-- 需要的 parser：UE 常用 + 你的 usf/ush 映射到 hlsl，所以把 hlsl 也装上
-- （SUPPORTED_LANGUAGES 里有 hlsl）:contentReference[oaicite:6]{index=6}
ts.install({ "c", "cpp", "lua", "vim", "vimdoc", "hlsl" })

-- Treesitter highlight: enable per-filetype (main 分支不再自动开)
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp", "lua", "vim", "vimdoc", "hlsl" },
  callback = function()
    pcall(vim.treesitter.start)
  end,
})

-- 可选：Treesitter folding（Neovim 原生）
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp", "lua", "hlsl" },
  callback = function()
    vim.wo.foldexpr = "v:lua.vim.treesitter.foldexpr()"
    vim.wo.foldmethod = "expr"
  end,
})

-- 可选：Treesitter indentexpr（nvim-treesitter 提供，README 标注 experimental）
vim.api.nvim_create_autocmd("FileType", {
  pattern = { "c", "cpp", "lua", "hlsl" },
  callback = function()
    vim.bo.indentexpr = "v:lua.require'nvim-treesitter'.indentexpr()"
  end,
})

vim.treesitter.language.register("hlsl", { "hlsl" })

-- Treesitter highlight: try start for any buffer with a parser
vim.api.nvim_create_autocmd({ "FileType", "BufReadPost", "BufNewFile" }, {
  callback = function(args)
    -- 新版要求显式 start；没 parser 会报错，用 pcall 吃掉
    pcall(vim.treesitter.start, args.buf)
  end,
})

-- 设定默认主题（开机即生效）
vim.cmd.colorscheme("unokai")

-- 自动记住上一次使用的 colorscheme
vim.api.nvim_create_autocmd("ColorScheme", {
  callback = function()
    vim.fn.writefile({ vim.g.colors_name }, vim.fn.stdpath("data") .. "/last_colorscheme")
  end,
})

-- 启动时恢复上一次主题
local last = vim.fn.stdpath("data") .. "/last_colorscheme"
if vim.fn.filereadable(last) == 1 then
  local name = vim.fn.readfile(last)[1]
  pcall(vim.cmd.colorscheme, name)
else
  vim.cmd.colorscheme("tokyonight")  -- 默认兜底
end

-- -- 用 fzf-lua 打开文件（更快，适合大工程）
-- vim.keymap.set("n", "<leader>fF", function()
--   require("fzf-lua").files()
-- end, { desc = "FZF: Find Files (fast)" })

require("fzf-lua").setup({
  files = {
    path_shorten = 1,        -- 缩短中间路径
    file_icons = true,
    color_icons = true,
  },
})


require("telescope").setup({
  defaults = {
    layout_strategy = "vertical",
    layout_config = {
      vertical = {
        width = 0.95,      -- 几乎全屏
        preview_height = 0.4,
      },
    },
    path_display = { "filename_first" },
  },
})


-- ===== Telescope UE compatibility (UE uses Project+Engine, else fallback to cwd) =====
local builtin = require("telescope.builtin")

local function smart_roots()
  local project_root, engine_root, err = ue_roots()
  if err then
    return nil, false
  end
  return {
	  project_root .. "/Source",
	  project_root .. "/Plugins",
	  engine_root,
	}, true
	
end

vim.keymap.set("n", "<leader>ff", function()
  local dirs, is_ue = smart_roots()
  if is_ue then
    return builtin.find_files({
      search_dirs = dirs,
      hidden = true,
    })
  end
  return builtin.find_files()
end, { desc = "Telescope: Find files (UE: Project+Engine / else: cwd)" })

vim.keymap.set("n", "<leader>fg", function()
  local dirs, is_ue = smart_roots()
  if is_ue then
    return builtin.live_grep({
      search_dirs = dirs,
      additional_args = function()
        return {
          "--hidden",
          "--follow",
          "--glob=!.git/*",
          "--glob=!**/Binaries/**",
          "--glob=!**/Intermediate/**",
          "--glob=!**/Saved/**",
          "--glob=!**/DerivedDataCache/**",
          "--glob=!**/Content/**",
        }
      end,
    })
  end
  return builtin.live_grep()
end, { desc = "Telescope: Live grep (UE: Project+Engine / else: cwd)" })


-- ===== UE build hotkey (reuse ue_roots + reuse single terminal) =====

local function ensure_term_visible()
  -- 如果终端窗口存在，直接复用
  if term_win and vim.api.nvim_win_is_valid(term_win) then
    vim.api.nvim_set_current_win(term_win)
    return term_buf
  end

  -- 否则打开（或复用）终端 buffer 到底部分屏（复用你现有逻辑）
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
  return term_buf
end

local function pwsh_send(job_id, s)
  -- 统一加回车
  vim.fn.chansend(job_id, s .. "\r")
end

local function ue_build_android()
  local uproject = find_nearest_uproject()
  if not uproject then
    vim.notify("UE build: no .uproject found upward from cwd", vim.log.levels.WARN)
    return
  end

  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify("UE build: " .. err, vim.log.levels.WARN)
    return
  end

  -- 你的 ue_roots() 里把 engine_root 转成了 "/"，这里给 pwsh 用回 "\"
  engine_root = engine_root:gsub("/", "\\")
  uproject    = uproject:gsub("/", "\\")

  local buf = ensure_term_visible()
  local job = vim.b[buf].terminal_job_id
  if not job then
    vim.notify("UE build: terminal job not ready", vim.log.levels.ERROR)
    return
  end

  
  local build_bat = engine_root .. [[\Engine\Build\BatchFiles\Build.bat]]

  local cmd = ([[& "%s" Client Android Development -Project="%s" -WaitMutex -FromMsBuild]])
    :format(build_bat, uproject)

  pwsh_send(job, cmd)

end

vim.keymap.set("n", "<leader>ub", ue_build_android, { desc = "UE Build: Client Android Development" })
