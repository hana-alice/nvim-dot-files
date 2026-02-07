-- ===== UE roots from .uproject EngineAssociation (Windows HKCU Builds) =====
local function find_nearest_uproject(start_dir)
  -- User requirement: only accept .uproject in the *current directory* (no upward search).
  local dir = start_dir or vim.loop.cwd()
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
  vim.notify("Project: " .. project_root .. "\nEngine: " .. engine_root)
end, {})

-- ===== Default .ignore templates (auto-create if missing) =====
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
  local dir = vim.fs.dirname(path)
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local lines = vim.split(content, "\n", { plain = true })
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

local function ue_index_paths(project_root)
  local cache_dir = project_root .. "/.cache"
  ensure_dir(cache_dir)
  return {
    all = cache_dir .. "/ue_files.txt",
    project = cache_dir .. "/ue_files_project.txt",
    engine = cache_dir .. "/ue_files_engine.txt",
    gtags_project = cache_dir .. "/gtags_project.files",
    gtags_engine = cache_dir .. "/gtags_engine.files",
  }
end

local function _norm(p)
  return (tostring(p or ""):gsub("\\", "/"))
end

local function _run_lines(cmd, opts)
  opts = opts or {}
  if vim.system then
    local r = vim.system(cmd, { text = true, cwd = opts.cwd, env = opts.env }):wait()
    local out = (r.stdout or "") .. (r.stderr or "")
    local lines = {}
    for s in out:gmatch("[^\r\n]+") do
      table.insert(lines, s)
    end
    return r.code or 0, lines
  end
  local joined = table.concat(cmd, " ")
  local lines = vim.fn.systemlist(joined)
  return vim.v.shell_error or 0, lines
end

local function _set_status(msg)
  vim.g.ueindex_status = msg or ""
  vim.schedule(function()
    pcall(vim.cmd, "redrawstatus")
  end)
end


local function _writefile(lines, path)
  vim.fn.writefile(lines, path)
end

local function _filter_cpp_list(lines)
  local out = {}
  for _, p in ipairs(lines or {}) do
    local s = _norm(p)
    if s:match("%.c$") or s:match("%.cc$") or s:match("%.cpp$") or s:match("%.cxx$")
      or s:match("%.h$") or s:match("%.hh$") or s:match("%.hpp$") or s:match("%.hxx$")
      or s:match("%.inl$") or s:match("%.ipp$") or s:match("%.inc$")
      or s:match("%.m$") or s:match("%.mm$") then
      table.insert(out, s)
    end
  end
  return out
end

local function build_ue_index_split()
  local project_root, engine_root, err = ue_roots()
  if err then
    vim.notify("UEIndex failed: " .. err, vim.log.levels.WARN)
    return nil
  end

  project_root = _norm(project_root)
  engine_root = _norm(engine_root)
  local paths = ue_index_paths(project_root)

  local ignore_files = collect_ignore_files(project_root, engine_root)
  local p_ignore = ignore_files[1]
  local e_ignore = ignore_files[2]

  _set_status("UEIndex: scanning project...")
  local cmd_p = { "fd", "--type", "f", "--hidden", "--follow" }
  if p_ignore and vim.fn.filereadable(p_ignore) == 1 then
    table.insert(cmd_p, "--ignore-file")
    table.insert(cmd_p, p_ignore)
  end
  table.insert(cmd_p, "--search-path"); table.insert(cmd_p, "Source")
  table.insert(cmd_p, "--search-path"); table.insert(cmd_p, "Plugins")

  local code_p, project_lines = _run_lines(cmd_p, { cwd = project_root })
  if code_p ~= 0 then
    vim.notify("UEIndex project scan failed (code=" .. code_p .. ")", vim.log.levels.ERROR)
    _set_status("")
    return nil
  end

  _set_status("UEIndex: scanning engine...")
  local cmd_e = { "fd", "--type", "f", "--hidden", "--follow" }
  if e_ignore and vim.fn.filereadable(e_ignore) == 1 then
    table.insert(cmd_e, "--ignore-file")
    table.insert(cmd_e, e_ignore)
  end
  table.insert(cmd_e, "--search-path"); table.insert(cmd_e, "Engine/Source")
  table.insert(cmd_e, "--search-path"); table.insert(cmd_e, "Engine/Plugins")

  local code_e, engine_lines = _run_lines(cmd_e, { cwd = engine_root })
  if code_e ~= 0 then
    vim.notify("UEIndex engine scan failed (code=" .. code_e .. ")", vim.log.levels.ERROR)
    _set_status("")
    return nil
  end

  -- rel lists (for gtags) + abs lists (for rg/fzf)
  local proj_rel, eng_rel = {}, {}
  for _, p in ipairs(project_lines) do table.insert(proj_rel, _norm(p)) end
  for _, p in ipairs(engine_lines) do table.insert(eng_rel, _norm(p)) end

  local proj_abs, eng_abs = {}, {}
  for _, p in ipairs(proj_rel) do table.insert(proj_abs, project_root .. "/" .. p) end
  for _, p in ipairs(eng_rel) do table.insert(eng_abs, engine_root .. "/" .. p) end

  local all = {}
  vim.list_extend(all, proj_abs)
  vim.list_extend(all, eng_abs)

  _writefile(all, paths.all)
  _writefile(proj_abs, paths.project)
  _writefile(eng_abs, paths.engine)

  _writefile(_filter_cpp_list(proj_rel), paths.gtags_project)
  _writefile(_filter_cpp_list(eng_rel), paths.gtags_engine)

  vim.notify(("UEIndex generated (project=%d, engine=%d): %s"):format(#proj_abs, #eng_abs, paths.all))
  _set_status("UEIndex: done")
  vim.defer_fn(function() _set_status("") end, 1500)

  return {
    project_root = project_root,
    engine_root = engine_root,
    paths = paths,
  }
end

local function _count_lines(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then return 0 end
  return #lines
end

local function _file_size(path)
  local st = vim.loop.fs_stat(path)
  return st and st.size or 0
end

local function build_gtags_from_filelist(root, filelist, label, on_exit)
  if vim.fn.executable("gtags") == 0 then
    vim.notify("gtags not found in PATH", vim.log.levels.ERROR)
    return false
  end

  root = root:gsub("\\", "/")
  filelist = filelist:gsub("\\", "/")

  local total = _count_lines(filelist)
  local gtags_db = root .. "/GTAGS"
  local last_sz = 0

  -- 轮询：用 GTAGS 文件大小变化做“显式进度”（近似）
  local timer = vim.loop.new_timer()
  timer:start(500, 500, function()
    local sz = _file_size(gtags_db)
    if sz > 0 then
      last_sz = sz
    end
    -- 注意：timer 回调也是 fast event，必须 schedule
    vim.schedule(function()
      if total > 0 then
        -- 这里用 size 做占位进度文本（不是百分百准确，但能看到在动）
        _set_status(("GTAGS(%s): running  files=%d  db=%s"):format(label, total, tostring(last_sz)))
      else
        _set_status(("GTAGS(%s): running  db=%s"):format(label, tostring(last_sz)))
      end
    end)
  end)

  vim.schedule(function()
    if total > 0 then
      _set_status(("GTAGS(%s): starting  files=%d"):format(label, total))
    else
      _set_status(("GTAGS(%s): starting"):format(label))
    end
  end)

  local cmd = { "gtags", "-f", filelist, "--skip-unreadable", "--skip-symlink" }

  vim.system(cmd, { cwd = root, stdout = false, stderr = false }, function(res)
    -- 回调是 fast event：先停 timer，再 schedule UI 更新
    if timer then
      timer:stop()
      timer:close()
    end

    vim.schedule(function()
      if res.code == 0 then
        _set_status(("GTAGS(%s): done"):format(label))
      else
        _set_status(("GTAGS(%s): failed(%d)"):format(label, res.code))
      end

      if on_exit then
        pcall(on_exit, res.code)
      end

      vim.defer_fn(function()
        if vim.g.ueindex_status:match("^GTAGS%(") then
          _set_status("")
        end
      end, 2000)
    end)
  end)

  return true
end


-- :UEIndex = rebuild UEIndex (split) + rebuild GTAGS(project/engine)
vim.api.nvim_create_user_command("UEIndex", function()
  local r = build_ue_index_split()
  if not r then return end

  -- project first, then engine
  build_gtags_from_filelist(r.project_root, r.paths.gtags_project, "project", function(code)
    if code ~= 0 then
      vim.notify("GTAGS(project) failed", vim.log.levels.WARN)
      vim.defer_fn(function() _set_status("") end, 3000)
      return
    end
    build_gtags_from_filelist(r.engine_root, r.paths.gtags_engine, "engine", function(_)
      vim.defer_fn(function() _set_status("") end, 3000)
    end)
  end)
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
    vim.cmd("UEIndex")
    return
  end

  local fzf = require("fzf-lua")
  local actions = require("fzf-lua.actions")

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

vim.keymap.set("n", "<leader>su", ue_files_from_index, { desc = "Search: UE files (index)" })
vim.keymap.set("n", "<leader>fF", "<leader>su", { remap = true, silent = true })

vim.keymap.set("n", "<leader>sU", function()
  vim.cmd("UEIndex")
end, { desc = "Search: Rebuild UE file index" })
vim.keymap.set("n", "<leader>fI", "<leader>sU", { remap = true, silent = true })

-- ...（后面 shader index 部分不变，省略）...

-- ===== Module exports / backward-compat globals =====
local M = M or {}
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
