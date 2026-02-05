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

  -- 4) 可选：每次打开时 cd 到当前文件目录
  term_cd_to_current_file_dir()
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
  { "hrsh7th/cmp-buffer" },
  { "hrsh7th/cmp-path" },

  -- Auto pairs: (), {}, [], "", ''
  {
    "windwp/nvim-autopairs",
    event = "InsertEnter",
    dependencies = { "nvim-treesitter/nvim-treesitter" },
    opts = { check_ts = true, enable_check_bracket_line = false },
    config = function(_, opts)
      local npairs = require("nvim-autopairs")
      npairs.setup(opts)
      local ok_cmp, cmp = pcall(require, "cmp")
      if ok_cmp then
        local cmp_autopairs = require("nvim-autopairs.completion.cmp")
        cmp.event:on("confirm_done", cmp_autopairs.on_confirm_done())
      end
    end,
  },
  
  -- Core fzf engine (git plugin, auto build/download binary)

	-- Modern Lua UI for fzf
	
	{
	  "ibhagwan/fzf-lua",
	  dependencies = { "junegunn/fzf" },
	},

  {
    "nvim-treesitter/nvim-treesitter",
    lazy = false,      -- main 分支要求：不要 lazy-load
    build = false,
  },

  {
    "numToStr/Comment.nvim",
    opts = {},
    lazy = false,
  },

  -- Surround: ys/cs/ds
  {
    "kylechui/nvim-surround",
    version = "*",
    event = "VeryLazy",
    opts = {},
  },

  -- Formatting (safe even if formatter binaries are missing)
  {
    "stevearc/conform.nvim",
    event = "VeryLazy",
  },



  -- Diagnostics UI (workspace/buffer list, references, etc.)
  {
    "folke/trouble.nvim",
    cmd = { "Trouble" },
    dependencies = { "nvim-tree/nvim-web-devicons" },
    opts = { focus = true },
  },

  -- Git: signs/blame/hunks
{
  "lewis6991/gitsigns.nvim",
  event = { "BufReadPre", "BufNewFile" },
  opts = {
    signs = {
      add = { text = "+" },
      change = { text = "~" },
      delete = { text = "_" },
      topdelete = { text = "‾" },
      changedelete = { text = "~" },
      untracked = { text = "┆" },
    },
    current_line_blame = false, -- toggle via keymap
    watch_gitdir = { follow_files = true },
    attach_to_untracked = true,
    update_debounce = 100,
  },
},

-- Git: full diff UI (great for MR/PR review)
{
  "sindrets/diffview.nvim",
  cmd = { "DiffviewOpen", "DiffviewClose", "DiffviewFileHistory" },
  dependencies = { "nvim-lua/plenary.nvim" },
  opts = {},
},

-- Git: :Git status/commit/rebase etc.
{
  "tpope/vim-fugitive",
  cmd = { "Git", "G", "Gdiffsplit", "Gvdiffsplit", "Gwrite", "Gread", "Gblame" },

},

-- Git: LazyGit integration
{
  "kdheepak/lazygit.nvim",
  cmd = { "LazyGit", "LazyGitConfig", "LazyGitCurrentFile", "LazyGitFilter", "LazyGitFilterCurrentFile" },
  dependencies = { "nvim-lua/plenary.nvim" },
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
  },

  {
    "rmagatti/auto-session",
    lazy = false, -- 建议别懒加载：要在启动阶段恢复 session
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


-- ===== Default .ignore templates (auto-create if missing) =====
-- These are used by: UE index (fd), Telescope find_files/live_grep (fd/rg)
local DEFAULT_IGNORE_PROJECT = [[
// p4
.cache
.idea
.vs
Binaries
Build
Content
DerivedDataCache
enc_temp_folder
Intermediate
KuroReleases
Platforms
Saved
SoundBanks

//engine
.cache
Samples
Engine\Binaries
Engine\Build
Engine\Content
Engine\DerivedDataCache
Engine\Intermediate
Engine\Saved
]]

local DEFAULT_IGNORE_ENGINE = [[
//engine
.cache
Samples
Engine\Binaries
Engine\Build
Engine\Content
Engine\DerivedDataCache
Engine\Intermediate
Engine\Saved
]]

local _ignore_bootstrap_done = false

local function ensure_ignore_file(path, content)
  if vim.fn.filereadable(path) == 1 then
    return true
  end
  -- Create parent dir just in case (should already exist)
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local lines = vim.split(content, "\n", { plain = true })
  -- Trim trailing empty lines (nicer diffs)
  while #lines > 0 and (lines[#lines] == "" or lines[#lines] == "\r") do
    table.remove(lines, #lines)
  end
  vim.fn.writefile(lines, path)
  return vim.fn.filereadable(path) == 1
end

local function ensure_default_ignores(project_root, engine_root)
  if _ignore_bootstrap_done then
    return
  end
  _ignore_bootstrap_done = true

  if project_root and project_root ~= "" then
    ensure_ignore_file(project_root .. "/.ignore", DEFAULT_IGNORE_PROJECT)
  end
  if engine_root and engine_root ~= "" then
    ensure_ignore_file(engine_root .. "/.ignore", DEFAULT_IGNORE_ENGINE)
  end
end

local function collect_ignore_files(project_root, engine_root)
  ensure_default_ignores(project_root, engine_root)

  local files = {}
  local p = project_root and (project_root .. "/.ignore") or nil
  local e = engine_root and (engine_root .. "/.ignore") or nil

  if p and vim.fn.filereadable(p) == 1 then table.insert(files, p) end
  if e and vim.fn.filereadable(e) == 1 then table.insert(files, e) end
  return files
end

local function _cmd_quote(p)
  return '"' .. tostring(p):gsub('"', '\"') .. '"'
end

local function fd_ignore_args(ignore_files)
  local args = {}
  for _, f in ipairs(ignore_files or {}) do
    table.insert(args, "--ignore-file")
    table.insert(args, _cmd_quote(f))
  end
  return table.concat(args, " ")
end

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

  -- ignore 文件：如果缺失就自动生成默认 .ignore（一次配置，所有搜索/索引复用）
  local ignore_files = collect_ignore_files(project_root, engine_root)
  local ignore_args = fd_ignore_args(ignore_files)

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
vim.keymap.set("n", "<leader>su", ue_files_from_index, { desc = "Search: UE files (index)" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>fF", "<leader>su", { remap = true, silent = true })


-- 可选：给一个快捷键手动刷新索引
vim.keymap.set("n", "<leader>sU", function()
  build_ue_index()
end, { desc = "Search: Rebuild UE file index" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>fI", "<leader>sU", { remap = true, silent = true })


-- ===== UE shader symbol index (.usf/.ush) + gd =====
-- Goal: fast "gd" without HLSL LSP, UE-friendly (handles includes + indexed symbols)
-- NOTE: This is independent from UEIndex (file index). No incremental changes to UEIndex logic.

local function ue_shader_index_path(project_root)
  local cache_dir = project_root .. "/.cache"
  ensure_dir(cache_dir)
  return cache_dir .. "/ue_shader_symbols.json"
end

local function rg_ignore_args(ignore_files)
  local args = {}
  for _, f in ipairs(ignore_files or {}) do
    table.insert(args, "--ignore-file")
    table.insert(args, win_quote(f))
  end
  return table.concat(args, " ")
end

local function _parse_rg_vimgrep_line(line)
  -- rg --vimgrep: file:line:col:text
  local file, lno, col, text = line:match("^(.-):(%d+):(%d+):(.*)$")
  if not file then return nil end
  return {
    file = file:gsub("\\", "/"),
    line = tonumber(lno),
    col = tonumber(col),
    text = text or "",
  }
end

local function _extract_shader_symbol(text)
  -- #define NAME
  local s = text:match("^%s*#%s*define%s+([%w_]+)")
  if s then return s, "define" end

  -- struct/class/enum NAME
  s = text:match("^%s*struct%s+([%w_]+)")
  if s then return s, "struct" end
  s = text:match("^%s*class%s+([%w_]+)")
  if s then return s, "class" end
  s = text:match("^%s*enum%s+([%w_]+)")
  if s then return s, "enum" end

  -- cbuffer NAME
  s = text:match("^%s*cbuffer%s+([%w_]+)")
  if s then return s, "cbuffer" end

  -- function-ish: returnType Name(
  s = text:match("^%s*[%w_]+%s+([%w_]+)%s*%(")
  if s then return s, "func" end

  return nil, nil
end

local function build_ue_shader_index()
  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify("UEShaderIndex failed: " .. err, vim.log.levels.WARN)
    return nil
  end

  local out_path = ue_shader_index_path(project_root)

  -- reuse .ignore auto-generation + collection
  local ignore_files = collect_ignore_files(project_root, engine_root)
  local ignore_args = rg_ignore_args(ignore_files)

  local dirs = {}
  local pr_shaders = project_root .. "/Shaders"
  if vim.fn.isdirectory(pr_shaders) == 1 then table.insert(dirs, win_quote(pr_shaders)) end
  local er_shaders = engine_root .. "/Engine/Shaders"
  if vim.fn.isdirectory(er_shaders) == 1 then table.insert(dirs, win_quote(er_shaders)) end
  if #dirs == 0 then
    -- fallback: still restrict by glob; scan engine_root as last resort
    table.insert(dirs, win_quote(engine_root))
    table.insert(dirs, win_quote(project_root))
  end

  -- Match common UE shader symbol definitions
  local pcre = table.concat({
    [[^\s*#\s*define\s+\w+]],
    [[^\s*(struct|class|enum)\s+\w+]],
    [[^\s*cbuffer\s+\w+]],
    [[^\s*\w+\s+\w+\s*\(]],
  }, "|")

  local cmd = table.concat(vim.tbl_flatten({
    "rg",
    "--vimgrep",
    "--pcre2",
    "--no-heading",
    ignore_args,
    "--glob", "*.usf",
    "--glob", "*.ush",
    win_quote(pcre),
    dirs,
  }), " ")

  local lines = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 and #lines == 0 then
    -- If rg returns 1 because "no matches", still fine; write empty index
    -- but if rg missing, also ends up here; give a hint.
    if vim.fn.executable("rg") == 0 then
      vim.notify("UEShaderIndex: ripgrep (rg) not found in PATH.", vim.log.levels.ERROR)
      return nil
    end
  end

  local index = {}
  for _, l in ipairs(lines) do
    local e = _parse_rg_vimgrep_line(l)
    if e then
      local sym, kind = _extract_shader_symbol(e.text)
      if sym then
        e.kind = kind
        index[sym] = index[sym] or {}
        table.insert(index[sym], e)
      end
    end
  end

  local payload = {
    version = 1,
    project_root = project_root,
    engine_root = engine_root,
    generated_at = os.time(),
    index = index,
  }

  local ok, json = pcall(vim.fn.json_encode, payload)
  if not ok then
    vim.notify("UEShaderIndex: json encode failed.", vim.log.levels.ERROR)
    return nil
  end

  vim.fn.writefile(vim.split(json, "\n"), out_path)
  vim.notify(("UEShaderIndex generated (%d symbols): %s"):format(vim.tbl_count(index), out_path))
  return out_path
end

local _shader_index_cache = { path = nil, mtime = 0, data = nil }

local function load_ue_shader_index()
  local project_root, _, err = ue_roots()
  if err then return nil, err end
  local path = ue_shader_index_path(project_root)
  local st = vim.loop.fs_stat(path)
  if not st then
    return nil, "index not found (run :UEShaderIndex)"
  end
  local mtime = st.mtime and st.mtime.sec or 0
  if _shader_index_cache.path == path and _shader_index_cache.mtime == mtime and _shader_index_cache.data then
    return _shader_index_cache.data
  end
  local content = table.concat(vim.fn.readfile(path), "\n")
  local ok, decoded = pcall(vim.fn.json_decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, "index decode failed"
  end
  _shader_index_cache = { path = path, mtime = mtime, data = decoded }
  return decoded
end

local function shader_try_open_include(project_root, engine_root)
  local line = vim.api.nvim_get_current_line()
  local inc = line:match('^%s*#%s*include%s+"([^"]+)"')
  if not inc then return false end

  -- Normalize UE-style absolute include "/Engine/.."
  inc = inc:gsub("^/+", "")

  local curdir = vim.fs.dirname(vim.api.nvim_buf_get_name(0))
  local candidates = {
    curdir .. "/" .. inc,
    project_root .. "/Shaders/" .. inc,
    engine_root .. "/Engine/Shaders/" .. inc,
    project_root .. "/" .. inc,
    engine_root .. "/" .. inc,
  }

  for _, p in ipairs(candidates) do
    p = p:gsub("\\", "/")
    if vim.fn.filereadable(p) == 1 then
      vim.cmd("edit " .. vim.fn.fnameescape(p))
      return true
    end
  end

  vim.notify("Include not found: " .. inc, vim.log.levels.WARN)
  return true
end

local function shader_gd_indexed()
  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify("Shader gd: " .. err, vim.log.levels.WARN)
    return
  end

  -- include jump first
  if shader_try_open_include(project_root, engine_root) then return end

  local sym = vim.fn.expand("<cword>")
  if not sym or sym == "" then return end

  local db, derr = load_ue_shader_index()
  if not db then
    vim.notify("Shader gd: " .. (derr or "no index"), vim.log.levels.WARN)
    return
  end

  local hits = db.index and db.index[sym] or nil
  if not hits or #hits == 0 then
    vim.notify("Shader gd: not found in index: " .. sym, vim.log.levels.INFO)
    return
  end

  local function jump(entry)
    vim.cmd("edit " .. vim.fn.fnameescape(entry.file))
    vim.api.nvim_win_set_cursor(0, { entry.line, math.max((entry.col or 1) - 1, 0) })
  end

  if #hits == 1 then
    jump(hits[1])
    return
  end

  -- multi hits: telescope picker if available; else vim.ui.select
  local ok_pick, pickers = pcall(require, "telescope.pickers")
  local ok_find, finders = pcall(require, "telescope.finders")
  local ok_conf, conf = pcall(require, "telescope.config")
  local ok_actions, actions = pcall(require, "telescope.actions")
  local ok_state, action_state = pcall(require, "telescope.actions.state")

  if ok_pick and ok_find and ok_conf and ok_actions and ok_state then
    local items = {}
    for _, h in ipairs(hits) do
      local disp = ("%s:%d:%d  [%s]  %s"):format(h.file, h.line, h.col, h.kind or "sym", h.text or "")
      table.insert(items, { value = h, display = disp, ordinal = disp })
    end

    pickers.new({}, {
      prompt_title = "Shader GD: " .. sym,
      finder = finders.new_table({
        results = items,
        entry_maker = function(e)
          return { value = e.value, display = e.display, ordinal = e.ordinal }
        end,
      }),
      sorter = conf.values.generic_sorter({}),
      attach_mappings = function(bufnr, _)
        actions.select_default:replace(function()
          actions.close(bufnr)
          local sel = action_state.get_selected_entry()
          if sel and sel.value then jump(sel.value) end
        end)
        return true
      end,
    }):find()
    return
  end

  local choices = {}
  for _, h in ipairs(hits) do
    table.insert(choices, {
      label = ("%s:%d:%d [%s] %s"):format(h.file, h.line, h.col, h.kind or "sym", h.text or ""),
      entry = h,
    })
  end

  vim.ui.select(choices, {
    prompt = "Shader GD: " .. sym,
    format_item = function(item) return item.label end,
  }, function(item)
    if item and item.entry then jump(item.entry) end
  end)
end

-- Command: :UEShaderIndex build/refresh shader symbol index
vim.api.nvim_create_user_command("UEShaderIndex", function()
  build_ue_shader_index()
end, {})

-- Key: rebuild shader symbol index
vim.keymap.set("n", "<leader>sS", "<cmd>UEShaderIndex<cr>", { desc = "Search: Rebuild UE shader symbol index" })

-- Bind gd only for .usf/.ush (doesn't affect C++ LSP gd)
vim.api.nvim_create_autocmd({ "BufEnter", "BufWinEnter" }, {
  callback = function(args)
    local name = (vim.api.nvim_buf_get_name(args.buf) or ""):lower()
    if name:match("%.usf$") or name:match("%.ush$") then
      vim.keymap.set("n", "gd", shader_gd_indexed, { buffer = args.buf, desc = "Shader: go to definition (indexed)" })
    end
  end,
})




-- ========== Keymaps ==========
local map = vim.keymap.set
-- map("n", "<leader>ff", function() require("telescope.builtin").find_files() end, { desc = "Find files" })
-- map("n", "<leader>fg", function() require("telescope.builtin").live_grep() end, { desc = "Live grep" })


-- ========== Git keymaps ==========
-- Status / UI
map("n", "<leader>gg", "<cmd>Git<cr>", { desc = "Git: status (fugitive)" })
map("n", "<leader>gl", "<cmd>LazyGit<cr>", { desc = "Git: LazyGit" })
map("n", "<leader>gD", "<cmd>DiffviewOpen<cr>", { desc = "Git: Diffview open" })
map("n", "<leader>gq", "<cmd>DiffviewClose<cr>", { desc = "Git: Diffview close" })
map("n", "<leader>gF", "<cmd>DiffviewFileHistory %<cr>", { desc = "Git: File history (current)" })
map("n", "<leader>gH", "<cmd>DiffviewFileHistory<cr>", { desc = "Git: Repo history" })

-- Gitsigns (hunks/blame)
map("n", "]c", function()
  local gs = package.loaded.gitsigns
  if gs then gs.next_hunk() end
end, { desc = "Git: next hunk" })

map("n", "[c", function()
  local gs = package.loaded.gitsigns
  if gs then gs.prev_hunk() end
end, { desc = "Git: prev hunk" })

map({ "n", "v" }, "<leader>hs", function()
  local gs = package.loaded.gitsigns
  if not gs then return end
  local m = vim.fn.mode()
  if m == "v" or m == "V" or m == "\22" then
    gs.stage_hunk({ vim.fn.line("."), vim.fn.line("v") })
  else
    gs.stage_hunk()
  end
end, { desc = "Git: stage hunk" })

map({ "n", "v" }, "<leader>hr", function()
  local gs = package.loaded.gitsigns
  if not gs then return end
  local m = vim.fn.mode()
  if m == "v" or m == "V" or m == "\22" then
    gs.reset_hunk({ vim.fn.line("."), vim.fn.line("v") })
  else
    gs.reset_hunk()
  end
end, { desc = "Git: reset hunk" })

map("n", "<leader>hp", function()
  local gs = package.loaded.gitsigns
  if gs then gs.preview_hunk() end
end, { desc = "Git: preview hunk" })

map("n", "<leader>hb", function()
  local gs = package.loaded.gitsigns
  if gs then gs.blame_line({ full = true }) end
end, { desc = "Git: blame line (full)" })

map("n", "<leader>hB", function()
  local gs = package.loaded.gitsigns
  if gs then gs.toggle_current_line_blame() end
end, { desc = "Git: toggle inline blame" })

map("n", "<leader>hd", function()
  local gs = package.loaded.gitsigns
  if gs then gs.diffthis() end
end, { desc = "Git: diff this" })

map("n", "<leader>hD", function()
  local gs = package.loaded.gitsigns
  if gs then gs.diffthis("~") end
end, { desc = "Git: diff this (against ~)" })

-- LSP keymaps (set on attach later)
-- ========== Completion ==========
local cmp = require("cmp")

cmp.setup({
  mapping = cmp.mapping.preset.insert({
    ["<C-Space>"] = cmp.mapping.complete(),
    ["<CR>"] = cmp.mapping.confirm({ select = true }),

    -- Tab to navigate completion menu, otherwise insert a real <Tab>
    ["<Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_next_item()
      else
        fallback()
      end
    end, { "i", "s" }),

    ["<S-Tab>"] = cmp.mapping(function(fallback)
      if cmp.visible() then
        cmp.select_prev_item()
      else
        fallback()
      end
    end, { "i", "s" }),
  }),

  sources = cmp.config.sources({
    { name = "nvim_lsp" },
    { name = "path" },
    { name = "buffer" },
  }),
})

-- ========== Formatting ==========
pcall(function()
  local conform = require("conform")
  conform.setup({
    format_on_save = false,
    formatters_by_ft = {
      lua = { "stylua" },
      -- C/C++/ObjC: prefer clang-format (works well for UE too if you have .clang-format)
      c = { "clang_format" },
      cpp = { "clang_format" },
      objc = { "clang_format" },
      objcpp = { "clang_format" },
      hlsl = { "clang_format" }, -- optional; many people use clang-format for .usf/.ush too
      json = { "prettierd", "prettier" },
      jsonc = { "prettierd", "prettier" },
      markdown = { "prettierd", "prettier" },
    },
  })

  vim.keymap.set({ "n", "v" }, "<leader>fm", function()
    conform.format({ async = true, lsp_fallback = true })
  end, { desc = "Format: File/range (manual)" })
end)

-- ========== LSP (clangd) ==========
-- ========== LSP (Neovim 0.11+ native) ==========
local capabilities = require("cmp_nvim_lsp").default_capabilities()

local function on_attach(_, bufnr)
  local function bufmap(mode, lhs, rhs, desc)
    vim.keymap.set(mode, lhs, rhs, { buffer = bufnr, desc = desc })
  end

  bufmap("n", "gd", vim.lsp.buf.definition, "LSP: Go to definition")
  bufmap("n", "gr", vim.lsp.buf.references, "LSP: References")
  bufmap("n", "K", vim.lsp.buf.hover, "LSP: Hover")
  bufmap("n", "<leader>rn", vim.lsp.buf.rename, "LSP: Rename")
  bufmap("n", "<leader>ca", vim.lsp.buf.code_action, "LSP: Code action")
  bufmap("n", "<leader>ds", vim.lsp.buf.document_symbol, "LSP: Document symbols")
  bufmap("n", "<leader>ws", vim.lsp.buf.workspace_symbol, "LSP: Workspace symbols")
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
      { buffer = bufnr, desc = "LSP: Switch source/header" }
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
vim.keymap.set("n", "<leader>sf", function()
  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local dirs = { project_root, engine_root }
  local ignore_files = collect_ignore_files(project_root, engine_root)

  -- Use fd explicitly so we can inject ignore files (consistent with UE index)
  local find_command = { "fd", "--type", "f", "--hidden", "--follow" }
  for _, f in ipairs(ignore_files) do
    table.insert(find_command, "--ignore-file")
    table.insert(find_command, f)
  end

  builtin.find_files({
    search_dirs = dirs,
    hidden = true,
    find_command = find_command,
  })
end, { desc = "Search: Telescope: Find files (Project + Engine)" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>ff", "<leader>sf", { remap = true, silent = true })

-- Space f g：从 Project + Engine grep
vim.keymap.set("n", "<leader>sg", function()
  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local dirs = { project_root, engine_root }
  local ignore_files = collect_ignore_files(project_root, engine_root)

  builtin.live_grep({
    search_dirs = dirs,
    additional_args = function()
      local args = {
        "--hidden",
        "--follow",
        "--glob=!.git/*",
        "--glob=!**/Binaries/**",
        "--glob=!**/Intermediate/**",
        "--glob=!**/Saved/**",
        "--glob=!**/DerivedDataCache/**",
        "--glob=!**/Content/**",
      }
      for _, f in ipairs(ignore_files) do
        table.insert(args, "--ignore-file")
        table.insert(args, f)
      end
      return args
    end,
  })
end, { desc = "Search: Telescope: Live grep (Project + Engine)" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>fg", "<leader>sg", { remap = true, silent = true })


-- 最近文件 / buffer
vim.keymap.set("n", "<leader>sr", builtin.oldfiles,  { desc = "Search: Recent files" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>fr", "<leader>sr", { remap = true, silent = true })
vim.keymap.set("n", "<leader>sb", builtin.buffers,   { desc = "Search: Buffers" })
vim.keymap.set("n", "<leader>sh", builtin.help_tags, { desc = "Search: Help tags" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>fh", "<leader>sh", { remap = true, silent = true })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>fb", "<leader>sb", { remap = true, silent = true })

-- LSP（以后你上 clangd 会非常爽）
vim.keymap.set("n", "gr", builtin.lsp_references,    { desc = "LSP References" })
vim.keymap.set("n", "gd", builtin.lsp_definitions,  { desc = "LSP Definitions" })
vim.keymap.set("n", "gi", builtin.lsp_implementations, { desc = "LSP Implementations" })


-- =========YAZI
vim.keymap.set({ "n", "v" }, "<leader>oe", "<cmd>Yazi<cr>", { desc = "Open: Yazi file manager" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set({ "n", "v" }, "<leader>e", "<leader>oe", { remap = true, silent = true })


vim.keymap.set("n", "<leader>bd", ":bp | bd #<CR>", { silent = true, desc = "Buffer: Delete current" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>q", "<leader>bd", { remap = true, silent = true })


-- 显示当前行错误
vim.keymap.set("n", "<leader>xd", vim.diagnostic.open_float, { desc = "Diagnostics: Line float" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>dd", "<leader>xd", { remap = true, silent = true })

-- 下一个 / 上一个错误
vim.keymap.set("n", "]d", vim.diagnostic.goto_next, { desc = "Next diagnostic" })
vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, { desc = "Prev diagnostic" })

-- 当前文件错误列表
vim.keymap.set("n", "<leader>xl", function()
  vim.diagnostic.setloclist()
end, { desc = "Diagnostics: Loclist (buffer)" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>dl", "<leader>xl", { remap = true, silent = true })

-- 全工程错误列表
vim.keymap.set("n", "<leader>xL", function()
  vim.diagnostic.setqflist()
end, { desc = "Diagnostics: Quickfix (workspace)" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>dL", "<leader>xL", { remap = true, silent = true })


-- Trouble (nice list UI for diagnostics/references)
vim.keymap.set("n", "<leader>xx", "<cmd>Trouble diagnostics toggle<cr>", { desc = "Diagnostics: Trouble toggle" })
vim.keymap.set("n", "<leader>xw", "<cmd>Trouble diagnostics toggle filter.buf=0<cr>", { desc = "Diagnostics: Trouble (buffer)" })
vim.keymap.set("n", "<leader>xW", "<cmd>Trouble diagnostics toggle<cr>", { desc = "Diagnostics: Trouble (workspace)" })
vim.keymap.set("n", "<leader>xr", "<cmd>Trouble lsp_references toggle<cr>", { desc = "LSP: Trouble references" })


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

local install_dir = vim.fn.stdpath("data") .. "/site"
ts.setup({ install_dir = install_dir })

local function ensure_parsers_once(parsers)
  local parser_dir = install_dir .. "/parser"
  for _, lang in ipairs(parsers) do
    local so = parser_dir .. "/" .. lang .. ".so"
    local dll = parser_dir .. "/" .. lang .. ".dll" -- Windows 有时是 dll
    if vim.uv.fs_stat(so) or vim.uv.fs_stat(dll) then
      -- ok
    else
      ts.install(parsers)
      return
    end
  end
end

ensure_parsers_once({ "c", "cpp", "lua", "vim", "vimdoc", "hlsl" })

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

vim.keymap.set("n", "<leader>sf", function()
  local dirs = ue_telescope_roots()
  if not dirs then return end
  builtin.find_files({
    search_dirs = dirs,
    hidden = true,
  })
end, { desc = "Search: Telescope: Find files (Project + Engine)" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>ff", "<leader>sf", { remap = true, silent = true })

vim.keymap.set("n", "<leader>sg", function()
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
end, { desc = "Search: Telescope: Live grep (Project + Engine)" })
-- Back-compat (no cheatsheet entry)
vim.keymap.set("n", "<leader>fg", "<leader>sg", { remap = true, silent = true })


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

vim.keymap.set("i", "<Tab>", function()
  return vim.fn.pumvisible() == 1 and "<C-n>" or "<Tab>"
end, { expr = true })

vim.keymap.set("i", "<S-Tab>", function()
  return vim.fn.pumvisible() == 1 and "<C-p>" or "<S-Tab>"
end, { expr = true })


-- ========== Cheatsheet (auto from keymap desc) ==========
-- Press <leader>? to open. Close with q / <Esc>. Search with /.
local function open_cheatsheet()
  local modes = { "n", "v", "i", "t" }
  local seen = {}
  local items = {}

  local function add_maps(list, mode)
    for _, m in ipairs(list) do
      if m.desc and m.desc ~= "" then
        local key = mode .. "\t" .. m.lhs .. "\t" .. m.desc
        if not seen[key] then
          seen[key] = true
          table.insert(items, { mode = mode, lhs = m.lhs, desc = m.desc })
        end
      end
    end
  end

  for _, mode in ipairs(modes) do
    add_maps(vim.api.nvim_get_keymap(mode), mode)
    add_maps(vim.api.nvim_buf_get_keymap(0, mode), mode) -- include buffer-local (LSP on_attach)
  end

  local function group_of(desc)
    return desc:match("^([%w_]+)%s*:") or "General"
  end

  table.sort(items, function(a, b)
    local ga, gb = group_of(a.desc), group_of(b.desc)
    if ga ~= gb then return ga < gb end
    if a.lhs ~= b.lhs then return a.lhs < b.lhs end
    return a.mode < b.mode
  end)

  local lines = {
    "# Neovim Cheatsheet (custom keymaps)",
    "",
    "Leader: <Space>",
    "",
    "Close: q / <Esc>",
    "Search: /",
    "",
  }

  local current_group = nil
  for _, it in ipairs(items) do
    local g = group_of(it.desc)
    if g ~= current_group then
      table.insert(lines, "")
      table.insert(lines, "## " .. g)
      current_group = g
    end
    table.insert(lines, ("- [%s] %-12s : %s"):format(it.mode, it.lhs, it.desc))
  end

  table.insert(lines, "")
  table.insert(lines, "Note: This list is generated from keymaps that have a { desc = ... }.")

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "markdown"
  vim.bo[buf].modifiable = false

  local ui = vim.api.nvim_list_uis()[1]
  local width = math.floor(ui.width * 0.92)
  local height = math.floor(ui.height * 0.88)
  local row = math.floor((ui.height - height) / 2)
  local col = math.floor((ui.width - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    style = "minimal",
    border = "rounded",
    width = width,
    height = height,
    row = row,
    col = col,
  })

  vim.keymap.set("n", "q", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf, nowait = true, silent = true })

  vim.keymap.set("n", "<Esc>", function()
    if vim.api.nvim_win_is_valid(win) then vim.api.nvim_win_close(win, true) end
  end, { buffer = buf, nowait = true, silent = true })
end

vim.keymap.set("n", "<leader>?", open_cheatsheet, { desc = "General: Cheatsheet" })

require("auto-session").setup({
  -- 自动恢复：进入某个 cwd 时，如果有 session 就恢复
  auto_restore_enabled = true,

  auto_save_enabled = true,

  auto_create_enabled = true,

  -- 会话文件放哪里（建议固定到标准目录，避免污染项目）
  session_dir = vim.fn.stdpath("data") .. "/sessions/",

  -- session 的命名策略（按 cwd 生成唯一名）
  -- 旧版本是 auto_session_use_git_branch / auto_session_root_dir 等字段，
  -- 新版本的字段可能略有变化；这个插件整体很稳定，但你装的版本不同字段会差一点。
  -- 如果你发现某字段无效，直接 :h auto-session 或 :checkhealth 看提示即可。

  -- 避免某些目录自动 restore（比如 home / Downloads / temp）
  auto_restore_last_session = false,
  suppressed_dirs = { "~", "~/Downloads", "/tmp" },

  -- 保存前清理：把不该进 session 的东西从 buffer list 里移掉
  pre_save_cmds = {
    "tabdo windo if &buftype == 'help' | q | endif",
    "tabdo windo if &buftype == 'quickfix' | cclose | endif",
  },

  -- sessionoptions 很关键：决定 session 里保存什么
  sessionoptions = "blank,buffers,curdir,folds,help,tabpages,winsize,winpos,terminal",
})

