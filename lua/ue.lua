-- ===== UE roots from .uproject EngineAssociation (Windows HKCU Builds) =====
local function find_nearest_uproject(start_dir)
  -- User requirement: only accept .uproject in the *current directory* (no upward search).
  local dir = start_dir or vim.loop.cwd()
  -- globpath(..., true) returns a list; robust on Windows paths.
  local matches = vim.fn.globpath(dir, "*.uproject", false, true)
  if type(matches) == "table" and #matches > 0 then
    return matches[1]
  end
  return nil
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
    return nil, nil, "No .uproject found in cwd (run :cd into the .uproject folder or open from there)"
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

-- ===== UE grep (Project + Engine) with .ignore -> quickfix =====
-- Uses ripgrep (rg). If UEIndex exists, prefer --files-from for stable speed.
local function _rg_ignore_args(ignore_files)
  local args = {}
  for _, f in ipairs(ignore_files or {}) do
    table.insert(args, "--ignore-file")
    table.insert(args, win_quote(f))
  end
  return table.concat(args, " ")
end

local function ue_grep(pattern)
  if not pattern or pattern == "" then return end
  if vim.fn.executable("rg") == 0 then
    vim.notify("UEGrep: ripgrep (rg) not found in PATH.", vim.log.levels.ERROR)
    return
  end

  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify("UEGrep failed: " .. err, vim.log.levels.WARN)
    return
  end

  local ignore_files = collect_ignore_files(project_root, engine_root)
  local ignore_args = _rg_ignore_args(ignore_files)

  local index_path = ue_index_path(project_root)
  local use_index = (vim.fn.filereadable(index_path) == 1)

  local cmd
  if use_index then
    cmd = table.concat(vim.tbl_flatten({
      "rg",
      "--vimgrep",
      "--smart-case",
      "--hidden",
      "--follow",
      ignore_args,
      "--files-from", win_quote(index_path),
      win_quote(pattern),
    }), " ")
  else
    cmd = table.concat(vim.tbl_flatten({
      "rg",
      "--vimgrep",
      "--smart-case",
      "--hidden",
      "--follow",
      ignore_args,
      win_quote(pattern),
      win_quote(project_root),
      win_quote(engine_root),
    }), " ")
  end

  local out = vim.fn.systemlist(cmd)
  -- rg returns 1 when no matches; treat as empty result set (not error)
  if vim.v.shell_error ~= 0 and vim.v.shell_error ~= 1 then
    vim.notify("UEGrep: rg failed (code=" .. vim.v.shell_error .. ")", vim.log.levels.ERROR)
    return
  end

  vim.fn.setqflist({}, " ", { title = "UEGrep: " .. pattern, lines = out })
  vim.cmd("copen")
end

vim.api.nvim_create_user_command("UEGrep", function(opts)
  ue_grep(opts.args)
end, { nargs = 1, desc = "Ripgrep in UE (project+engine, respects .ignore, quickfix)" })

vim.api.nvim_create_user_command("UEGrepPrompt", function()
  vim.ui.input({ prompt = "UEGrep> " }, function(input)
    ue_grep(input)
  end)
end, { desc = "Prompted UEGrep" })

-- Keymaps: Ctrl+Shift+F style
vim.keymap.set("n", "<leader>sg", "<cmd>UEGrepPrompt<cr>", { desc = "Search: UE grep (quickfix, .ignore)" })
vim.keymap.set("n", "]q", "<cmd>cnext<cr>", { desc = "Quickfix: next" })
vim.keymap.set("n", "[q", "<cmd>cprev<cr>", { desc = "Quickfix: prev" })
vim.keymap.set("n", "<leader>qo", "<cmd>copen<cr>", { desc = "Quickfix: open" })
vim.keymap.set("n", "<leader>qc", "<cmd>cclose<cr>", { desc = "Quickfix: close" })

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


-- ===== Module exports / backward-compat globals =====
local M = M or {}
-- Expose frequently used helpers for other modules that still expect globals.
_G.ue_roots = ue_roots
_G.find_nearest_uproject = find_nearest_uproject
_G.collect_ignore_files = collect_ignore_files
_G.ue_index_path = ue_index_path

M.ue_roots = ue_roots
M.find_nearest_uproject = find_nearest_uproject
M.collect_ignore_files = collect_ignore_files
M.ue_index_path = ue_index_path
M.ue_grep = ue_grep

return M

