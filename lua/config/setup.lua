local map = vim.keymap.set

-- Hard guarantee: sessions never capture/restore cwd
vim.opt.sessionoptions = { "blank", "buffers", "folds", "help", "tabpages", "winsize", "winpos", "terminal" }
vim.opt.sessionoptions:remove("curdir")

-- Auto-session: restore/save without cd surprises
pcall(function()
  local ok, as = pcall(require, "auto-session")
  if ok and as and as.setup then
    as.setup({
      auto_save_enabled = true,
      auto_restore_enabled = true,
      cwd_change_handling = false,
      sessionoptions = "blank,buffers,folds,help,tabpages,winsize,winpos,terminal",
    })
  end
end)


-- nvim-cmp (guarded)
local ok_cmp, cmp = pcall(require, "cmp")
if not ok_cmp then
  vim.notify("nvim-cmp not available", vim.log.levels.WARN)
  return
end

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
  local project_root, engine_root, err = require("ue").ue_roots()
  if err then
    -- Fallback requirement: if no .uproject in cwd, still allow normal search within current cwd.
    return { vim.loop.cwd() }
  end
  return { project_root, engine_root }
end

-- Space f f：从 Project + Engine 找文件
vim.keymap.set("n", "<leader>sf", function()
  local project_root, engine_root, err = require("ue").ue_roots()
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local dirs = { project_root, engine_root }
  local ignore_files = require("ue").collect_ignore_files(project_root, engine_root)

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
  local project_root, engine_root, err = require("ue").ue_roots()
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local dirs = { project_root, engine_root }
  local ignore_files = require("ue").collect_ignore_files(project_root, engine_root)

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
    path_shorten = 1,
    file_icons = true,
    color_icons = true,
  },

  keymap = {
    builtin = {
      ["<Tab>"]   = "next",
      ["<S-Tab>"] = "prev",
      ["<C-n>"]   = "next",
      ["<C-p>"]   = "prev",
      ["<Esc>"]   = "abort",
      ["<CR>"]    = "accept",
    },

    -- 有的版本 Tab 只在 fzf 层生效，所以也绑一份
    fzf = {
      ["tab"]     = "down",
      ["btab"]    = "up",
      ["ctrl-n"]  = "down",
      ["ctrl-p"]  = "up",
      ["esc"]     = "abort",
      ["enter"]   = "accept",
    },
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
  local project_root, engine_root, err = require("ue").ue_roots()
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

  local project_root, engine_root, err = require("ue").ue_roots()
  if err then
    vim.notify("UE build: " .. err, vim.log.levels.WARN)
    return
  end

  -- 你的 require("ue").ue_roots() 里把 engine_root 转成了 "/"，这里给 pwsh 用回 "\"
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

-- vim.keymap.set("i", "<Tab>", function()
--   return vim.fn.pumvisible() == 1 and "<C-n>" or "<Tab>"
-- end, { expr = true })

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
  -- 重要：不自动 restore（避免 session 把 cwd 恢复到某个 Engine/Source/... 造成“自动 cd”错觉）
  auto_restore_enabled = false,

  -- 仍然自动保存/创建 session（需要时你可以手动 :SessionRestore）
  auto_save_enabled = true,
  auto_create_enabled = true,

  session_dir = vim.fn.stdpath("data") .. "/sessions/",
  auto_restore_last_session = false,
  suppressed_dirs = { "~", "~/Downloads", "/tmp" },

  pre_save_cmds = {
    "tabdo windo if &buftype == 'help' | q | endif",
    "tabdo windo if &buftype == 'quickfix' | cclose | endif",
  },

  -- 关键：不记录/恢复 curdir（避免 cwd 被 session 改写）
  sessionoptions = "blank,buffers,folds,help,tabpages,winsize,winpos,terminal",
})
