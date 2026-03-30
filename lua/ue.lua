local M = {}

local setup_done = false
local cheatsheet_buf = nil
local cheatsheet_win = nil
local build_term_buf = nil
local build_term_win = nil
local build_term_jobid = nil
local status_cache = {} -- { key = string, value = string, tick = number }
local dirty_index_roots = {}
local _engine_root_cache = {} -- dir -> engine_root (or false)
local _context_cache = {} -- key -> { ctx, ts }
local _CONTEXT_TTL = 5 -- seconds

local function trim(value)
  return vim.trim(tostring(value or ""))
end

local function norm(path)
  if not path or path == "" then
    return ""
  end
  path = tostring(path):gsub("\\", "/")
  path = path:gsub("/+", "/")
  if #path > 1 and path:sub(-1) == "/" then
    path = path:sub(1, -2)
  end
  return path
end

local function cwd()
  local uv_cwd = vim.uv and vim.uv.cwd and vim.uv.cwd() or nil
  if uv_cwd and uv_cwd ~= "" then
    return norm(uv_cwd)
  end
  return norm(vim.fn.getcwd())
end

local function is_native_windows()
  return vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
end

local function focus_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end
  return pcall(vim.api.nvim_set_current_win, win)
end

local function startinsert_in_window(win)
  vim.schedule(function()
    if not win or not vim.api.nvim_win_is_valid(win) then
      return
    end
    if vim.api.nvim_get_current_win() ~= win then
      return
    end
    pcall(vim.cmd, "startinsert")
  end)
end

local function join(...)
  return norm(table.concat(vim.tbl_flatten({ ... }), "/"))
end

local function dirname(path)
  return norm(vim.fs.dirname(path))
end

local function is_dir(path)
  return vim.fn.isdirectory(path) == 1
end

local function is_file(path)
  return vim.fn.filereadable(path) == 1
end

local function ensure_dir(path)
  if path ~= "" and not is_dir(path) then
    vim.fn.mkdir(path, "p")
  end
end

local function file_stat(path)
  path = norm(path)
  if path == "" or not vim.uv or not vim.uv.fs_stat then
    return nil
  end
  return vim.uv.fs_stat(path)
end

local function file_mtime(path)
  local stat = file_stat(path)
  local mtime = stat and stat.mtime or nil
  if type(mtime) == "table" then
    return tonumber(mtime.sec) or 0
  end
  return tonumber(mtime) or 0
end

local function path_has_prefix(path, prefix)
  path = norm(path)
  prefix = norm(prefix)
  if prefix == "" then
    return false
  end
  if prefix == "/" then
    return path:sub(1, 1) == "/"
  end
  return path == prefix or path:sub(1, #prefix + 1) == prefix .. "/"
end

local function is_absolute_path(path)
  path = norm(path)
  return path ~= "" and (path:sub(1, 1) == "/" or path:match("^[A-Za-z]:/") or path:match("^//"))
end

local function split_path(path)
  local parts = {}
  for part in norm(path):gmatch("[^/]+") do
    table.insert(parts, part)
  end
  return parts
end

local function common_ancestor(paths)
  local normalized = {}
  local absolute = true

  for _, path in ipairs(paths or {}) do
    path = norm(path)
    if path ~= "" then
      table.insert(normalized, path)
      absolute = absolute and path:sub(1, 1) == "/"
    end
  end

  if #normalized == 0 then
    return ""
  end

  local shared = split_path(normalized[1])
  for index = 2, #normalized do
    local parts = split_path(normalized[index])
    local keep = 0
    for part_index = 1, math.min(#shared, #parts) do
      if shared[part_index] ~= parts[part_index] then
        break
      end
      keep = part_index
    end
    while #shared > keep do
      table.remove(shared)
    end
    if #shared == 0 then
      break
    end
  end

  if #shared == 0 then
    return absolute and "/" or ""
  end

  local prefix = table.concat(shared, "/")
  if absolute then
    return "/" .. prefix
  end
  return prefix
end

local function relative_to(root, path)
  root = norm(root)
  path = norm(path)

  if root == "" then
    return path
  end
  if root == "/" then
    return path
  end
  if path == root then
    return "."
  end
  if not path_has_prefix(path, root) then
    return path
  end
  return path:sub(#root + 2)
end

local function first_executable(candidates)
  for _, candidate in ipairs(candidates or {}) do
    if candidate and candidate ~= "" then
      if candidate:find("/", 1, true) and is_file(candidate) then
        return candidate
      end
      if vim.fn.executable(candidate) == 1 then
        return candidate
      end
    end
  end
  return nil
end

local function clangd_candidates(root_dir)
  local candidates = {}
  local override = trim(vim.env.UE_CLANGD)
  if override ~= "" then
    table.insert(candidates, override)
  end

  vim.list_extend(candidates, {
    "clangd",
    "/usr/local/bin/clangd",
    "/usr/bin/clangd",
  })

  root_dir = norm(root_dir or "")
  if root_dir:match("^/mnt/[a-z]/") then
    table.insert(candidates, "/mnt/c/Program Files/LLVM/bin/clangd.exe")
  end

  return candidates
end

local function parse_global_entries(root, lines)
  local entries = {}
  root = norm(root)
  for _, line in ipairs(lines or {}) do
    local file, lnum, text = line:match("^(.-):(%d+):(.*)$")
    if file and lnum then
      file = norm(file)
      if not is_absolute_path(file) then
        file = join(root, file)
      end
      table.insert(entries, {
        filename = file,
        lnum = tonumber(lnum),
        col = 1,
        text = text or "",
      })
    end
  end
  return entries
end

local function strip_ansi(line)
  line = tostring(line or "")
  line = line:gsub("\27%[[0-9;?]*[%a]", "")
  return line:gsub("\r", "")
end

local function normalize_output_lines(output)
  if type(output) == "table" then
    local lines = {}
    for _, line in ipairs(output) do
      line = trim(strip_ansi(line))
      if line ~= "" then
        table.insert(lines, line)
      end
    end
    return lines
  end

  local lines = {}
  for line in tostring(output or ""):gmatch("[^\r\n]+") do
    line = trim(strip_ansi(line))
    if line ~= "" then
      table.insert(lines, line)
    end
  end
  return lines
end

local function resolve_output_path(root, path)
  path = norm(path)
  if path == "" then
    return ""
  end
  if not is_absolute_path(path) and root and root ~= "" then
    path = join(root, path)
  end
  return path
end

local function looks_like_diagnostic_text(text)
  local lower = trim(text):lower()
  return lower:find("error", 1, true) ~= nil
    or lower:find("warning", 1, true) ~= nil
    or lower:find("note:", 1, true) ~= nil
    or lower:find("fatal", 1, true) ~= nil
    or lower:find("failed", 1, true) ~= nil
    or lower:find("exception", 1, true) ~= nil
    or lower:find("undefined reference", 1, true) ~= nil
end

local function is_summary_diagnostic_line(line)
  return line:match("^FAILURE:")
    or line:match("^BUILD FAILED")
    or line:match("^%* What went wrong:")
    or line:match("^%* Try:")
    or line:match("^Execution failed for task")
    or line:match("^A failure occurred while executing")
    or line:match("^UnrealBuildTool:%s*ERROR:")
    or line:match("^ERROR:")
    or line:match("^error:")
    or line:match("^> ")
    or line:match("EXIT CODE")
end

local function extract_quoted_path(line)
  for _, pattern in ipairs({
    [["([A-Za-z]:[^"]+)"]],
    [['([A-Za-z]:[^']+)']],
    [["(/[^"]+)"]],
    [['(/[^']+)']],
  }) do
    local candidate = line:match(pattern)
    if candidate and is_absolute_path(candidate) then
      return norm(candidate)
    end
  end
end

local function add_quickfix_entry(entries, seen, entry)
  local key = table.concat({
    norm(entry.filename or ""),
    tostring(entry.lnum or 0),
    tostring(entry.col or 0),
    trim(entry.text or ""),
  }, "\31")
  if seen[key] then
    return
  end
  seen[key] = true
  table.insert(entries, entry)
end

local function parse_output_entry(line, opts)
  opts = opts or {}

  for _, parser in ipairs({
    function(text)
      local file, lnum, col, message = text:match("^(.-):(%d+):(%d+):%s*(.*)$")
      return file, lnum, col, message
    end,
    function(text)
      local file, lnum, message = text:match("^(.-):(%d+):%s*(.*)$")
      return file, lnum, nil, message
    end,
    function(text)
      local file, lnum, col, message = text:match("^(.-)%((%d+),(%d+)%)%s*:%s*(.*)$")
      return file, lnum, col, message
    end,
    function(text)
      local file, lnum, message = text:match("^(.-)%((%d+)%)%s*:%s*(.*)$")
      return file, lnum, nil, message
    end,
    function(text)
      local file, lnum, col, message = text:match("^(.-)%((%d+),(%d+)%)%s+(.*)$")
      return file, lnum, col, message
    end,
    function(text)
      local file, lnum, message = text:match("^(.-)%((%d+)%)%s+(.*)$")
      return file, lnum, nil, message
    end,
  }) do
    local file, lnum, col, message = parser(line)
    file = resolve_output_path(opts.root, file)
    if file ~= "" and looks_like_diagnostic_text(message or line) then
      return {
        filename = file,
        lnum = tonumber(lnum) or 1,
        col = tonumber(col) or 1,
        text = trim(message ~= "" and message or line),
      }
    end
  end

  local quoted = extract_quoted_path(line)
  if quoted and (looks_like_diagnostic_text(line) or is_summary_diagnostic_line(line)) then
    return {
      filename = quoted,
      lnum = 1,
      col = 1,
      text = trim(line),
    }
  end
end

local function diagnostic_entries_from_output(output, opts)
  opts = opts or {}
  local lines = normalize_output_lines(output)
  local entries = {}
  local seen = {}

  for _, line in ipairs(lines) do
    local entry = parse_output_entry(line, opts)
    if entry then
      add_quickfix_entry(entries, seen, entry)
    elseif is_summary_diagnostic_line(line) then
      add_quickfix_entry(entries, seen, { text = trim(line) })
    end
  end

  if #entries == 0 then
    local start = math.max(#lines - (opts.tail_limit or 12) + 1, 1)
    for index = start, #lines do
      add_quickfix_entry(entries, seen, { text = lines[index] })
    end
  end

  return entries
end

local function populate_quickfix_from_entries(title, entries)
  if not entries or #entries == 0 then
    return false
  end

  vim.fn.setqflist({}, " ", { title = title, items = entries })
  vim.cmd("copen")
  return true
end

local function populate_quickfix_from_output(title, output, opts)
  return populate_quickfix_from_entries(title, diagnostic_entries_from_output(output, opts))
end

local function jump_to_entry(entry)
  if not entry then
    return false
  end

  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(entry.filename))
  vim.api.nvim_win_set_cursor(0, { entry.lnum, math.max((entry.col or 1) - 1, 0) })
  return true
end

local function populate_quickfix_from_global(title, root, lines)
  return populate_quickfix_from_entries(title, parse_global_entries(root, lines))
end

local function jump_to_global_result(root, lines)
  local entries = parse_global_entries(root, lines)
  if #entries == 0 then
    return false
  end
  if #entries == 1 then
    return jump_to_entry(entries[1])
  end
  return populate_quickfix_from_entries("GTAGS definitions", entries)
end

function M.clangd_cmd(root_dir)
  local clangd = first_executable(clangd_candidates(root_dir or cwd())) or "clangd"
  return {
    clangd,
    "--background-index",
    "--completion-style=detailed",
    "--header-insertion=never",
    "--pch-storage=memory",
    "--clang-tidy",
    "--function-arg-placeholders",
    "--limit-results=200",
    "--limit-references=200",
    "--query-driver=**/clang*.exe,**/clang*,**/gcc,**/g++,**/cc,**/c++,**/cl.exe",
  }
end

local function run_lines(cmd, opts)
  opts = opts or {}
  if vim.system then
    local system_opts = { text = true }
    local cwd_path = norm(trim(opts.cwd))
    if cwd_path ~= "" and is_dir(cwd_path) then
      system_opts.cwd = cwd_path
    end
    local result = vim.system(cmd, system_opts):wait()
    local output = (result.stdout or "") .. (result.stderr or "")
    local lines = {}
    for line in output:gmatch("[^\r\n]+") do
      table.insert(lines, line)
    end
    return result.code or 0, lines
  end

  local joined = table.concat(cmd, " ")
  local lines = vim.fn.systemlist(joined)
  return vim.v.shell_error or 0, lines
end

local function write_all(path, content)
  ensure_dir(dirname(path))
  local file, err = io.open(path, "wb")
  if not file then
    vim.notify("write_all failed: " .. (err or path), vim.log.levels.ERROR)
    return false
  end
  file:write(content)
  file:close()
  return true
end

local function read_all(path)
  local file = io.open(path, "rb")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content
end

local function write_lines(path, lines)
  ensure_dir(dirname(path))
  vim.fn.writefile(lines, path)
end

local function find_uproject_in_dir(dir)
  local matches = vim.fn.globpath(dir, "*.uproject", false, true)
  if type(matches) == "table" and #matches > 0 then
    table.sort(matches)
    return norm(matches[1])
  end
  return nil
end

local function resolve_project_input(path)
  path = norm(trim(path))
  if path == "" then
    return nil, nil, "Project path not provided"
  end

  if path:match("%.uproject$") then
    if not is_file(path) then
      return nil, nil, "Project file not found: " .. path
    end
    return dirname(path), path, nil
  end

  if not is_dir(path) then
    return nil, nil, "Project directory not found: " .. path
  end

  local uproject = find_uproject_in_dir(path)
  if not uproject then
    return nil, nil, "Selected directory has no .uproject: " .. path
  end

  return path, uproject, nil
end

local function detect_project_root_from_path(path)
  path = norm(path)
  if path == "" then
    return nil, nil
  end

  local dir = is_file(path) and dirname(path) or path
  while dir ~= "" do
    local uproject = find_uproject_in_dir(dir)
    if uproject then
      return dir, uproject
    end
    local parent = dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  return nil, nil
end

local function is_engine_root(dir)
  dir = norm(dir)
  if dir == "" then
    return false
  end

  local required = {
    join(dir, "Engine"),
    join(dir, "Engine", "Binaries"),
    join(dir, "Engine", "Build"),
    join(dir, "Engine", "Config"),
    join(dir, "Engine", "Plugins"),
    join(dir, "Engine", "Shaders"),
    join(dir, "Engine", "Source"),
  }

  for _, path in ipairs(required) do
    if not is_dir(path) then
      return false
    end
  end

  return true
end

local function find_engine_root(path)
  path = norm(path)
  if path == "" then
    return nil
  end

  local start_dir = is_file(path) and dirname(path) or path
  if _engine_root_cache[start_dir] ~= nil then
    local cached = _engine_root_cache[start_dir]
    return cached ~= false and cached or nil
  end

  local dir = start_dir
  local visited = {}
  while dir ~= "" do
    if _engine_root_cache[dir] ~= nil then
      local cached = _engine_root_cache[dir]
      local result = cached ~= false and cached or nil
      for _, v in ipairs(visited) do
        _engine_root_cache[v] = cached
      end
      return result
    end
    table.insert(visited, dir)
    if is_engine_root(dir) then
      for _, v in ipairs(visited) do
        _engine_root_cache[v] = dir
      end
      return dir
    end
    local parent = dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
  end

  for _, v in ipairs(visited) do
    _engine_root_cache[v] = false
  end
  return nil
end

local function current_engine_root()
  local current_cwd = cwd()
  if current_cwd ~= "" then
    local engine_root = find_engine_root(current_cwd)
    if engine_root then
      return engine_root
    end
  end

  local bufname = norm(vim.api.nvim_buf_get_name(0))
  if bufname ~= "" then
    return find_engine_root(bufname)
  end

  return nil
end

local function cache_paths(engine_root)
  local cache = join(engine_root, ".cache", "nvim-ue")
  return {
    cache = cache,
    state = join(cache, "state.json"),
    project_list = join(cache, "project_gtags.files"),
    engine_list = join(cache, "engine_gtags.files"),
    workspace_list = join(cache, "workspace_gtags.files"),
    workspace_db = join(cache, "gtags", "workspace"),
  }
end

local function read_state(engine_root)
  local paths = cache_paths(engine_root)
  if not is_file(paths.state) then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(paths.state), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end

  if decoded.project_root then
    decoded.project_root = norm(decoded.project_root)
  end
  return decoded
end

local function persist_project(engine_root, project_root, uproject)
  local paths = cache_paths(engine_root)
  ensure_dir(paths.cache)

  -- Merge into existing state to preserve extra fields (android_package, etc.)
  local existing = read_state(engine_root)
  existing.project_root = norm(project_root)
  existing.uproject = uproject and norm(uproject) or nil
  existing.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  write_all(paths.state, vim.json.encode(existing))
  return existing
end

local function update_state_field(engine_root, key, value)
  local paths = cache_paths(engine_root)
  ensure_dir(paths.cache)
  local existing = read_state(engine_root)
  existing[key] = value
  existing.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  write_all(paths.state, vim.json.encode(existing))
end

local function resolve_context(opts)
  opts = opts or {}

  -- Cache key: cwd + bufname (covers the two inputs that vary)
  local cur_cwd = cwd()
  local cur_buf = norm(vim.api.nvim_buf_get_name(0))
  local cache_key = cur_cwd .. "\0" .. cur_buf
  local now = vim.uv.hrtime() / 1e9
  local cached = _context_cache[cache_key]
  if cached and (now - cached.ts) < _CONTEXT_TTL then
    return cached.ctx, cached.err
  end

  local engine_root = current_engine_root()
  if not engine_root then
    local err = "No Unreal Engine root found from current buffer or cwd"
    _context_cache[cache_key] = { ctx = nil, err = err, ts = now }
    return nil, err
  end

  local state = read_state(engine_root)
  local project_root, uproject

  if state.project_root then
    project_root, uproject = resolve_project_input(state.project_root)
  end

  if not project_root and opts.detect_project ~= false then
    local candidates = { cur_cwd }
    if cur_buf ~= "" and cur_buf ~= candidates[1] then
      table.insert(candidates, cur_buf)
    end
    for _, candidate in ipairs(candidates) do
      project_root, uproject = detect_project_root_from_path(candidate)
      if project_root then
        break
      end
    end
  end

  local ctx = {
    engine_root = engine_root,
    project_root = project_root,
    uproject = uproject,
    state = state,
    paths = cache_paths(engine_root),
  }
  _context_cache[cache_key] = { ctx = ctx, err = nil, ts = now }
  return ctx
end

local function filter_cpp(paths)
  local filtered = {}
  for _, path in ipairs(paths or {}) do
    local normalized = norm(path)
    if normalized:match("%.c$") or normalized:match("%.cc$") or normalized:match("%.cpp$") or normalized:match("%.cxx$")
      or normalized:match("%.h$") or normalized:match("%.hh$") or normalized:match("%.hpp$") or normalized:match("%.hxx$")
      or normalized:match("%.inl$") or normalized:match("%.ipp$") or normalized:match("%.inc$")
      or normalized:match("%.m$") or normalized:match("%.mm$") then
      table.insert(filtered, normalized)
    end
  end
  table.sort(filtered)
  return filtered
end

local PROJECT_INDEX_DIRS = {
  "Source",
  "Config",
  "Plugins",
  "CSharpScript",
  "Script",
  "TypeScript",
  "typescript",
}

local GTAGS_EXCLUDE_SUBSTRINGS = {
  "Engine/Source/ThirdParty/MCPP/mcpp-2.7.2/",
}

local ENGINE_PICKER_DIRS = {
  "Engine/Source",
  "Engine/Plugins",
  "Engine/Shaders",
  "Engine/Config",
}

local PICKER_EXCLUDES = {
  "**/.git/**",
  "**/.vs/**",
  "**/Binaries/**",
  "**/Content/**",
  "**/DerivedDataCache/**",
  "**/Intermediate/**",
  "**/Saved/**",
  "**/ThirdParty/**",
}

-- Extensions (for fd -e / files picker ft)
M.FT_CPP = {
  "c", "cc", "cpp", "cxx",
  "h", "hh", "hpp", "hxx",
  "inl", "ipp", "inc",
  "m", "mm",
}

M.FT_SHADER = {
  "usf", "ush",
  "hlsl", "hlsli",
  "glsl", "comp", "vert", "frag", "geom", "tesc", "tese",
  "metal",
}

M.FT_CODE = vim.list_extend(vim.list_extend({}, M.FT_CPP), M.FT_SHADER)

M.FT_CONFIG = {
  "ini", "cfg", "conf",
  "cs",
  "ts", "js",
  "json",
  "xml",
  "yaml", "yml",
  "py",
  "lua",
  "uproject", "uplugin",
  "build.cs", "target.cs",
}

M.FT_ALL = vim.list_extend(vim.list_extend({}, M.FT_CODE), M.FT_CONFIG)

-- Globs (for rg -g / grep picker)
M.GLOBS_CODE = vim.tbl_map(function(ext) return "*." .. ext end, M.FT_CODE)
M.GLOBS_ALL = vim.tbl_map(function(ext) return "*." .. ext end, M.FT_ALL)

local function existing_relative_dirs(root, search_paths)
  local dirs = {}
  for _, search_path in ipairs(search_paths or {}) do
    if is_dir(join(root, search_path)) then
      table.insert(dirs, search_path)
    end
  end
  return dirs
end

local function filter_gtags_paths(paths)
  local filtered = {}
  for _, path in ipairs(paths or {}) do
    local normalized = norm(path)
    local excluded = false
    for _, pattern in ipairs(GTAGS_EXCLUDE_SUBSTRINGS) do
      if normalized:find(pattern, 1, true) then
        excluded = true
        break
      end
    end
    if not excluded then
      table.insert(filtered, normalized)
    end
  end
  return filtered
end

local function picker_search_dirs(ctx)
  local dirs = {}
  local seen = {}

  local function add(path)
    path = norm(path)
    if path ~= "" and is_dir(path) and not seen[path] then
      seen[path] = true
      table.insert(dirs, path)
    end
  end

  for _, relative in ipairs(existing_relative_dirs(ctx.engine_root, ENGINE_PICKER_DIRS)) do
    add(join(ctx.engine_root, relative))
  end

  if ctx.project_root and ctx.project_root ~= "" then
    add(ctx.project_root)
  end

  return dirs
end

local function plugin_scope_from_root(root, path)
  root = norm(root)
  path = norm(path)
  if root == "" then
    return nil
  end

  local plugins_root = join(root, "Plugins")
  if not path_has_prefix(path, plugins_root) then
    return nil
  end

  local parts = split_path(relative_to(plugins_root, path))
  if #parts == 0 then
    return nil
  end

  local plugin_root = join(plugins_root, parts[1])
  if not is_dir(plugin_root) then
    return nil
  end

  return {
    kind = "plugin",
    name = parts[1],
    root = plugin_root,
    label = "Plugin " .. parts[1],
  }
end

local function project_module_scope(project_root, path)
  project_root = norm(project_root)
  path = norm(path)
  if project_root == "" then
    return nil
  end

  local source_root = join(project_root, "Source")
  if not path_has_prefix(path, source_root) then
    return nil
  end

  local parts = split_path(relative_to(source_root, path))
  if #parts == 0 then
    return nil
  end

  local module_root = join(source_root, parts[1])
  if not is_dir(module_root) then
    return nil
  end

  return {
    kind = "module",
    name = parts[1],
    root = module_root,
    label = "Module " .. parts[1],
  }
end

local function engine_module_scope(engine_root, path)
  engine_root = norm(engine_root)
  path = norm(path)
  if engine_root == "" then
    return nil
  end

  local source_root = join(engine_root, "Engine", "Source")
  if not path_has_prefix(path, source_root) then
    return nil
  end

  local parts = split_path(relative_to(source_root, path))
  if #parts < 2 then
    return nil
  end

  local module_root = join(source_root, parts[1], parts[2])
  if not is_dir(module_root) then
    return nil
  end

  return {
    kind = "module",
    name = parts[2],
    root = module_root,
    label = "Module " .. parts[2],
  }
end

local function current_scope_info_from_context(ctx)
  if not ctx then
    return nil, "No UE context available"
  end

  local path = norm(vim.api.nvim_buf_get_name(0))
  if path == "" then
    path = cwd()
  end

  local scope = plugin_scope_from_root(ctx.project_root, path)
    or project_module_scope(ctx.project_root, path)
    or plugin_scope_from_root(join(ctx.engine_root, "Engine"), path)
    or engine_module_scope(ctx.engine_root, path)

  if scope then
    return scope
  end

  return nil, "Current file is not inside a UE module or plugin"
end

local function current_scope_info(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    return nil, err
  end

  return current_scope_info_from_context(ctx)
end

local function index_output_paths(ctx)
  local outputs = {}
  local compile_commands = join(ctx.engine_root, "compile_commands.json")
  if compile_commands ~= "" then
    table.insert(outputs, compile_commands)
  end
  for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do
    table.insert(outputs, join(ctx.paths.workspace_db, name))
  end
  return outputs
end

local function status_root_key(ctx)
  if not ctx then
    return ""
  end
  return table.concat({
    norm(ctx.engine_root),
    norm(ctx.project_root),
  }, "\31")
end

local function clear_index_dirty(ctx)
  local key = status_root_key(ctx)
  if key ~= "" then
    dirty_index_roots[key] = nil
  end
end

local function mark_index_dirty(ctx)
  local key = status_root_key(ctx)
  if key ~= "" then
    dirty_index_roots[key] = true
  end
end

local function index_status_token(ctx)
  if not ctx or not ctx.project_root then
    return "UE?"
  end

  local outputs = index_output_paths(ctx)

  for _, path in ipairs(outputs) do
    if file_mtime(path) <= 0 then
      return "IDX?"
    end
  end
  if not db_ready(ctx.paths.workspace_db) then
    return "IDX?"
  end
  if dirty_index_roots[status_root_key(ctx)] then
    return "IDX!"
  end
  return "IDX"
end

local function short_scope_token(scope)
  if not scope or not scope.name then
    return "UE"
  end
  return (scope.kind == "plugin" and "P:" or "M:") .. scope.name
end

local function invalidate_status_cache()
  status_cache = {}
  _context_cache = {}
end

local function refresh_statusline()
  local ok, ue = pcall(require, "ue")
  local status = ""
  if ok and type(ue.statusline_status) == "function" then
    local ok_status, value = pcall(ue.statusline_status)
    if ok_status and type(value) == "string" then
      status = value
    end
  end
  if vim.g.ueindex_status == status then
    return
  end
  vim.g.ueindex_status = status
  pcall(vim.cmd, "redrawstatus")
end

local function set_build_status(value)
  vim.g.ue_build_status = trim(value)
  invalidate_status_cache()
  refresh_statusline()
end

local function scan_relative_files(root, search_paths)
  local fd = first_executable({ "fd", "fdfind" })
  if not fd then
    return nil, "fd/fdfind not found in PATH"
  end

  local cmd = { fd, "--type", "f", "--hidden", "--follow" }
  local found = false
  for _, search_path in ipairs(search_paths) do
    if is_dir(join(root, search_path)) then
      found = true
      table.insert(cmd, "--search-path")
      table.insert(cmd, search_path)
    end
  end

  if not found then
    return {}, nil
  end

  local code, lines = run_lines(cmd, { cwd = root })
  if code ~= 0 then
    return nil, table.concat(lines or {}, "\n")
  end

  return lines, nil
end

local function clean_db_dir(dir)
  pcall(vim.fn.delete, dir, "rf")
  ensure_dir(dir)
end

local function glob_paths(pattern)
  local matches = vim.fn.glob(pattern, false, true)
  if type(matches) ~= "table" then
    return {}
  end
  local paths = {}
  local seen = {}
  for _, match in ipairs(matches) do
    local path = norm(match)
    if path ~= "" and not seen[path] then
      seen[path] = true
      table.insert(paths, path)
    end
  end
  return paths
end

local function cleanup_gradle_debug_artifacts(ctx)
  if not ctx or not ctx.project_root or ctx.project_root == "" then
    return
  end

  local patterns = {
    join(ctx.project_root, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "app-debug.apk"),
    join(ctx.project_root, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "debug", "app-debug.apk"),
    join(ctx.project_root, "Intermediate", "Android", "*", "gradle", "app", "build", "intermediates", "apk", "app-debug.apk"),
    join(ctx.project_root, "Intermediate", "Android", "*", "gradle", "app", "build", "intermediates", "apk", "debug", "app-debug.apk"),
    join(ctx.project_root, "Intermediate", "Android", "*", "gradle", "app", "build", "intermediates", "incremental", "packageDebug"),
    join(ctx.project_root, "Intermediate", "Android", "*", "gradle", "app", "build", "intermediates", "incremental", "debug", "packageDebug"),
  }

  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(glob_paths(pattern)) do
      local ok = pcall(vim.fn.delete, path, "rf")
      if not ok then
        vim.notify("Failed to clean stale Gradle artifact: " .. path, vim.log.levels.WARN)
      end
    end
  end
end

local function db_ready(db_dir)
  for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do
    local path = join(db_dir, name)
    if not is_file(path) or vim.fn.getfsize(path) <= 0 then
      return false
    end
  end
  return true
end

local function build_gtags_db(root, filelist, db_dir, label)
  local gtags = first_executable({ "gtags" })
  if not gtags then
    return false, "gtags not found in PATH"
  end

  if not is_file(filelist) or vim.fn.getfsize(filelist) <= 0 then
    clean_db_dir(db_dir)
    return true, label .. ": no files to index"
  end

  clean_db_dir(db_dir)

  local cmd = { gtags, "-f", filelist, "--skip-unreadable", "--skip-symlink", db_dir }
  local code, lines = run_lines(cmd, { cwd = root })
  if code ~= 0 then
    return false, table.concat(lines or {}, "\n")
  end

  if not db_ready(db_dir) then
    local output = table.concat(lines or {}, "\n")
    if output ~= "" then
      return false, output
    end
    return false, "GTAGS database not generated: " .. db_dir
  end

  return true
end

local function global_lines(root, db_dir, args)
  local cmd = { "env", "GTAGSROOT=" .. root, "GTAGSDBPATH=" .. db_dir, "global" }
  vim.list_extend(cmd, args)
  return run_lines(cmd, { cwd = root })
end

local function detect_target_name(project_root, uproject)
  local targets = vim.fn.globpath(join(project_root, "Source"), "*.Target.cs", false, true)
  local editor_target, game_target

  for _, target in ipairs(targets or {}) do
    local name = vim.fs.basename(target):gsub("%.Target%.cs$", "")
    if name:match("Editor$") then
      editor_target = editor_target or name
    else
      game_target = game_target or name
    end
  end

  return editor_target or game_target or vim.fs.basename(uproject):gsub("%.uproject$", "")
end

local function target_platform(engine_root, cmd)
  local override = trim(vim.env.UE_TARGET_PLATFORM)
  if override ~= "" then
    return override
  end
  -- Check persisted state
  if engine_root and engine_root ~= "" then
    local state = read_state(engine_root)
    local persisted = trim(state.target_platform or "")
    if persisted ~= "" then
      return persisted
    end
  end
  local exe = trim((cmd or {})[1])
  if exe ~= "" and (exe:lower():match("%.exe$") or exe:lower():match("%.bat$")) then
    return "Win64"
  end
  if engine_root and engine_root:match("^/mnt/[a-z]/") then
    return "Win64"
  end
  return "Linux"
end

local function target_configuration(engine_root)
  local override = trim(vim.env.UE_TARGET_CONFIGURATION)
  if override ~= "" then
    return override
  end
  -- Check persisted state
  if engine_root and engine_root ~= "" then
    local state = read_state(engine_root)
    local persisted = trim(state.target_configuration or "")
    if persisted ~= "" then
      return persisted
    end
  end
  return "Development"
end

local function build_target_name(project_root, uproject)
  local override = trim(vim.env.UE_BUILD_TARGET)
  if override ~= "" then
    return override
  end
  return "Client"
end

local function command_is_windows(cmd)
  local exe = trim((cmd or {})[1])
  if exe == "" then
    return false
  end
  exe = exe:lower()
  return exe:match("%.exe$") ~= nil
end

local function command_needs_windows_wrapper(cmd)
  local exe = norm(trim((cmd or {})[1]))
  return exe ~= "" and exe:lower():match("%.exe$") ~= nil and not exe:match("^/mnt/[a-z]/")
end

local function powershell_quote(value)
  return "'" .. tostring(value or ""):gsub("'", "''") .. "'"
end

local function cmd_quote(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

local function is_windows_path(path)
  path = trim(path)
  return path:match("^[A-Za-z]:[\\/]") ~= nil or path:match("^\\\\") ~= nil
end

local function to_windows_path(path)
  path = trim(path)
  if path == "" then
    return nil
  end
  if is_windows_path(path) then
    return path:gsub("/", "\\")
  end

  local code, lines = run_lines({ "wslpath", "-w", path })
  if code ~= 0 or not lines or not lines[1] then
    return nil
  end

  local converted = trim(lines[1])
  if converted == "" then
    return nil
  end
  return converted
end

local function windows_host_cwd()
  for _, candidate in ipairs({ "/mnt/c/Windows", "/mnt/c" }) do
    if is_dir(candidate) then
      return candidate
    end
  end
  return cwd()
end

local function build_bat_path(engine_root)
  if is_windows_path(engine_root) then
    return engine_root:gsub("/", "\\") .. "\\Engine\\Build\\BatchFiles\\Build.bat"
  end
  return join(engine_root, "Engine", "Build", "BatchFiles", "Build.bat")
end

local function ubt_exe_path(engine_root)
  if is_windows_path(engine_root) then
    return engine_root:gsub("/", "\\") .. "\\Engine\\Binaries\\DotNET\\UnrealBuildTool.exe"
  end
  return join(engine_root, "Engine", "Binaries", "DotNET", "UnrealBuildTool.exe")
end

local function ensure_executable(path)
  if is_windows_path(path) then
    return true
  end
  if vim.fn.executable(path) == 1 then
    return true
  end
  local code = select(1, run_lines({ "chmod", "+x", path }))
  if code == 0 and vim.fn.executable(path) == 1 then
    return true
  end
  return false, "Failed to mark executable: " .. path
end

local function direct_ubt_command(engine_root, args)
  local exe = ubt_exe_path(engine_root)
  if not is_file(exe) then
    return nil, "UnrealBuildTool.exe not found under engine root: " .. exe
  end

  local ok_exec, exec_err = ensure_executable(exe)
  if not ok_exec then
    return nil, exec_err
  end

  local cmd = { exe }
  vim.list_extend(cmd, args or {})
  return cmd
end

local function build_bat_windows_command(engine_root, args)
  local engine_root_win = to_windows_path(engine_root)
  if not engine_root_win then
    return nil, "Failed to convert engine root to Windows path: " .. engine_root
  end

  local build_bat_win = to_windows_path(build_bat_path(engine_root))
  if not build_bat_win then
    return nil, "Failed to convert Build.bat path to Windows path: " .. build_bat_path(engine_root)
  end

  local function direct_cmd_token(value)
    value = tostring(value or "")
    if value:find("%s") then
      return cmd_quote(value)
    end
    return value
  end

  local function shell_cmd_token(value)
    value = tostring(value or "")
    if value:find("%s") then
      return '\\"' .. value:gsub('"', '\\"') .. '\\"'
    end
    return value
  end

  local direct_parts = {
    "call " .. direct_cmd_token(build_bat_win),
  }

  for _, arg in ipairs(args or {}) do
    table.insert(direct_parts, direct_cmd_token(arg))
  end

  if is_native_windows() then
    return { "cmd.exe", "/d", "/c", table.concat(direct_parts, " ") }
  end

  local parts = {
    "call " .. shell_cmd_token(build_bat_win),
  }

  for _, arg in ipairs(args or {}) do
    table.insert(parts, shell_cmd_token(arg))
  end

  local shell = first_executable({ "zsh", "bash", "sh" })
  if not shell then
    return { "cmd.exe", "/d", "/c", table.concat(direct_parts, " ") }
  end
  local shell_name = vim.fs.basename(shell)
  local shell_flag = shell_name == "sh" and "-c" or "-lc"
  local shell_cmd = ('cd %s && cmd.exe /d /c "%s"'):format(
    vim.fn.shellescape(windows_host_cwd()),
    table.concat(parts, " ")
  )

  return { shell, shell_flag, shell_cmd }
end

local function wrap_windows_command(cmd)
  local exe_win = to_windows_path((cmd or {})[1])
  if not exe_win then
    return nil, "Failed to convert Windows executable path: " .. tostring((cmd or {})[1])
  end

  local parts = { "& " .. powershell_quote(exe_win) }
  for index = 2, #cmd do
    table.insert(parts, powershell_quote(cmd[index]))
  end

  return {
    "powershell.exe",
    "-NoProfile",
    "-ExecutionPolicy",
    "Bypass",
    "-Command",
    table.concat(parts, " "),
  }
end

local function compile_commands_targets(ctx)
  return {
    join(ctx.engine_root, "compile_commands.json"),
    join(ctx.engine_root, "Engine", "compile_commands.json"),
  }
end

local function windows_engine_root(ctx)
  local override = trim(vim.env.UE_WINDOWS_ENGINE_ROOT)
  if override ~= "" then
    return to_windows_path(override)
  end

  return to_windows_path(ctx.engine_root)
end

local function compile_commands_candidates(ctx)
  local seen = {}
  local candidates = {}

  local function add(path)
    path = norm(path)
    if path ~= "" and not seen[path] and is_file(path) then
      seen[path] = true
      table.insert(candidates, path)
    end
  end

  for _, target in ipairs(compile_commands_targets(ctx)) do
    add(target)
  end
  if ctx.project_root and ctx.project_root ~= "" then
    add(join(ctx.project_root, "compile_commands.json"))
  end
  add(join(ctx.engine_root, "Engine", "Intermediate", "Build", "compile_commands.json"))

  local fd = first_executable({ "fd", "fdfind" })
  if fd then
    local cmd = {
      fd,
      "--absolute-path",
      "--type",
      "f",
      "--hidden",
      "--follow",
      "--glob",
      "compile_commands.json",
      "--search-path",
      ctx.engine_root,
    }
    if ctx.project_root and ctx.project_root ~= "" and ctx.project_root ~= ctx.engine_root then
      table.insert(cmd, "--search-path")
      table.insert(cmd, ctx.project_root)
    end

    local code, lines = run_lines(cmd, { cwd = "/" })
    if code == 0 then
      for _, line in ipairs(lines or {}) do
        add(line)
      end
    end
  end

  return candidates
end

local function write_compile_commands_targets(ctx, content)
  if not content or content == "" then
    return false, "compile_commands.json was empty"
  end

  local preferred = compile_commands_targets(ctx)[1]
  for _, target in ipairs(compile_commands_targets(ctx)) do
    write_all(target, content)
  end

  return true, preferred
end

local function export_compile_commands_to_engine_root(ctx)
  local candidates = compile_commands_candidates(ctx)
  for _, candidate in ipairs(candidates) do
    local content = read_all(candidate)
    if content then
      return write_compile_commands_targets(ctx, content)
    end
  end

  return false, "compile_commands.json not found after GenerateClangDatabase"
end

local function generate_compile_commands(ctx)
  local ok_existing, existing_path = export_compile_commands_to_engine_root(ctx)
  if ok_existing then
    return true, existing_path
  end

  if not ctx.project_root or ctx.project_root == "" then
    return false, "No project configured for engine root. Run :UESetProject [path]"
  end

  local uproject = ctx.uproject or find_uproject_in_dir(ctx.project_root)
  if not uproject then
    return false, "No .uproject found in project root: " .. ctx.project_root
  end

  local project_arg = to_windows_path(uproject)
  if not project_arg then
    return false, "Failed to convert .uproject path to Windows path for Build.bat"
  end

  local cmd, cmd_err
  if is_windows_path(ctx.engine_root) then
    local engine_root_win = windows_engine_root(ctx)
    if not engine_root_win or engine_root_win == "" then
      return false, "Failed to resolve Windows engine root for compile_commands export"
    end

    local build_bat_file = build_bat_path(engine_root_win)
    if not is_windows_path(build_bat_file) and not is_file(build_bat_file) then
      return false, "Build.bat not found under engine root: " .. build_bat_file
    end

    cmd, cmd_err = build_bat_windows_command(engine_root_win, {
      "-Mode=GenerateClangDatabase",
      detect_target_name(ctx.project_root, uproject),
      target_platform(ctx.engine_root, { "Build.bat" }),
      target_configuration(ctx.engine_root),
      "-Project=" .. project_arg,
      "-Game",
      "-Engine",
    })
  else
    cmd, cmd_err = direct_ubt_command(ctx.engine_root, {
      "-Mode=GenerateClangDatabase",
      detect_target_name(ctx.project_root, uproject),
      target_platform(ctx.engine_root, { ubt_exe_path(ctx.engine_root) }),
      target_configuration(ctx.engine_root),
      "-Project=" .. project_arg,
      "-Game",
      "-Engine",
    })
  end
  if not cmd then
    return false, cmd_err
  end

  for _, target in ipairs(compile_commands_targets(ctx)) do
    pcall(vim.fn.delete, target)
  end

  local code, lines = run_lines(cmd, { cwd = windows_host_cwd() })
  if code ~= 0 then
    return false, table.concat(lines or {}, "\n")
  end

  return export_compile_commands_to_engine_root(ctx)
end

local function android_build_command(ctx)
  local uproject = ctx.uproject or find_uproject_in_dir(ctx.project_root)
  if not uproject then
    return nil, "No .uproject found in project root: " .. ctx.project_root
  end

  local uproject_win = to_windows_path(uproject)
  if not uproject_win then
    return nil, "Failed to convert UE build paths to Windows paths"
  end

  local plat = target_platform(ctx.engine_root, nil)
  local conf = target_configuration(ctx.engine_root)

  local build_args = {
    build_target_name(ctx.project_root, uproject),
    plat,
    conf,
    "-Project=" .. uproject_win,
    "-WaitMutex",
    "-FromMsBuild",
  }

  if is_windows_path(ctx.engine_root) then
    local engine_root_win = windows_engine_root(ctx)
    if not engine_root_win or engine_root_win == "" then
      return nil, "Failed to resolve Windows engine root for build command"
    end

    local build_bat_file = build_bat_path(engine_root_win)
    if not is_windows_path(build_bat_file) and not is_file(build_bat_file) then
      return nil, "Build.bat not found under engine root: " .. build_bat_file
    end

    return build_bat_windows_command(engine_root_win, build_args)
  end

  return direct_ubt_command(ctx.engine_root, build_args)
end

local function append_job_output(lines, pending, chunks)
  pending = pending or ""
  for _, chunk in ipairs(chunks or {}) do
    if chunk and chunk ~= "" then
      pending = pending .. chunk
      while true do
        local newline = pending:find("\n", 1, true)
        if not newline then
          break
        end
        local line = trim(strip_ansi(pending:sub(1, newline - 1)))
        if line ~= "" then
          table.insert(lines, line)
        end
        pending = pending:sub(newline + 1)
      end
    end
  end
  return pending
end

local function flush_job_output(lines, pending)
  pending = trim(strip_ansi(pending))
  if pending ~= "" then
    table.insert(lines, pending)
  end
  return ""
end

local function open_terminal_command(cmd, opts)
  opts = opts or {}
  local output_lines = {}
  local stdout_pending = ""
  local stderr_pending = ""

  local function prune_state()
    if build_term_win and not vim.api.nvim_win_is_valid(build_term_win) then
      build_term_win = nil
    end
    if build_term_buf and not vim.api.nvim_buf_is_valid(build_term_buf) then
      build_term_buf = nil
    end
  end

  local function track_state(buf, win)
    build_term_buf = buf
    build_term_win = win

    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function(args)
        if build_term_buf == args.buf then
          build_term_buf = nil
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
      once = true,
      pattern = tostring(win),
      callback = function()
        if build_term_win == win then
          build_term_win = nil
        end
      end,
    })
  end

  local function job_running()
    if not build_term_jobid then
      return false
    end
    local ok, result = pcall(vim.fn.jobwait, { build_term_jobid }, 0)
    return ok and result and result[1] == -1
  end

  local function ensure_window()
    prune_state()

    if build_term_win and focus_window(build_term_win) then
      return build_term_win
    end

    local height = opts.height or math.max(8, math.floor(vim.o.lines * 0.25))
    vim.cmd(("botright %dnew"):format(height))
    build_term_win = vim.api.nvim_get_current_win()
    return build_term_win
  end

  if job_running() then
    local running_win = ensure_window()
    if build_term_buf and vim.api.nvim_buf_is_valid(build_term_buf) then
      vim.api.nvim_win_set_buf(running_win, build_term_buf)
    end
    startinsert_in_window(running_win)
    vim.notify("UE build is already running", vim.log.levels.WARN)
    return
  end

  local win = ensure_window()
  local previous_buf = build_term_buf
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(win, buf)
  track_state(buf, win)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false

  if previous_buf and previous_buf ~= buf and vim.api.nvim_buf_is_valid(previous_buf) then
    pcall(vim.api.nvim_buf_delete, previous_buf, { force = true })
  end

  if opts.quickfix_title then
    set_build_status("B...")
  end

  local active_jobid
  active_jobid = vim.fn.termopen(cmd, {
    cwd = opts.cwd,
    on_stdout = function(_, data)
      stdout_pending = append_job_output(output_lines, stdout_pending, data)
    end,
    on_stderr = function(_, data)
      stderr_pending = append_job_output(output_lines, stderr_pending, data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        stdout_pending = flush_job_output(output_lines, stdout_pending)
        stderr_pending = flush_job_output(output_lines, stderr_pending)
        if build_term_jobid == active_jobid then
          build_term_jobid = nil
        end
        if code ~= 0 and opts.quickfix_title then
          populate_quickfix_from_output(opts.quickfix_title, output_lines, {
            root = opts.quickfix_root,
            tail_limit = opts.tail_limit,
          })
        end
        if opts.quickfix_title then
          set_build_status(code == 0 and "BOK" or ("B" .. tostring(code)))
        end
        local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        vim.notify(("UE build finished with exit code %d"):format(code), level)
      end)
    end,
  })
  if active_jobid <= 0 then
    build_term_jobid = nil
    if opts.quickfix_title then
      set_build_status("BERR")
    end
    vim.notify("Failed to start UE build terminal", vim.log.levels.ERROR)
    return
  end

  build_term_jobid = active_jobid
  startinsert_in_window(win)
end

local function workspace_root(ctx)
  if ctx.project_root and ctx.project_root ~= "" then
    local root = common_ancestor({ ctx.engine_root, ctx.project_root })
    if root ~= "" then
      return root
    end
    return ctx.project_root
  end
  return ctx.engine_root
end

function M.picker_options(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    return nil, err
  end

  local dirs = picker_search_dirs(ctx)
  if #dirs == 0 then
    return nil, "No UE search directories found"
  end

  return {
    dirs = dirs,
    exclude = vim.deepcopy(PICKER_EXCLUDES),
    follow = true,
  }, nil
end

function M.picker_project_options(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    return nil, err
  end
  if not ctx.project_root then
    return nil, "No UE project configured"
  end

  return {
    dirs = { ctx.project_root },
    exclude = vim.deepcopy(PICKER_EXCLUDES),
    follow = false,
  }, nil
end

function M.current_scope_picker_options(opts)
  local scope, err = current_scope_info(opts)
  if not scope then
    return nil, nil, err
  end

  return {
    dirs = { scope.root },
    exclude = vim.deepcopy(PICKER_EXCLUDES),
    follow = true,
  }, scope, nil
end

function M.statusline_status(opts)
  local ctx = resolve_context(opts)
  if not ctx then
    return trim(vim.g.ue_build_status or "")
  end

  local parts = {}
  local scope = current_scope_info_from_context(ctx)
  parts[#parts + 1] = short_scope_token(scope)

  if ctx.project_root then
    parts[#parts + 1] = index_status_token(ctx)
  else
    parts[#parts + 1] = "UE?"
  end

  local build = trim(vim.g.ue_build_status or "")
  if build ~= "" then
    parts[#parts + 1] = build
  end

  return table.concat(parts, " ")
end

function M.ue_roots(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    return nil, nil, err
  end
  if not ctx.project_root then
    return nil, ctx.engine_root, "No project configured for engine root. Run :UESetProject [path]"
  end
  return ctx.project_root, ctx.engine_root, nil
end

function M.clangd_root(bufnr)
  bufnr = bufnr or 0
  local bufname = norm(vim.api.nvim_buf_get_name(bufnr))
  local engine_root = find_engine_root(bufname) or current_engine_root()
  if engine_root then
    if bufname == "" or path_has_prefix(bufname, engine_root) then
      return engine_root
    end
    local ctx = resolve_context()
    if ctx and ctx.project_root and path_has_prefix(bufname, ctx.project_root) then
      return ctx.engine_root
    end
    if path_has_prefix(cwd(), engine_root) then
      return engine_root
    end
  end
  return vim.fs.root(bufname ~= "" and bufname or cwd(), { "compile_commands.json", ".clangd", ".git" }) or cwd()
end

function M.gtags_references(symbol)
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  if not ctx.project_root then
    return false
  end

  local root = workspace_root(ctx)
  if db_ready(ctx.paths.workspace_db) then
    local code, lines = global_lines(root, ctx.paths.workspace_db, { "-r", "--result=grep", symbol })
    if (code == 0 or code == 1) and lines and #lines > 0 then
      return populate_quickfix_from_global("GTAGS references: " .. symbol, root, lines)
    end
  end

  return false
end

function M.gtags_definition(symbol)
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  if not ctx.project_root then
    return false
  end

  local root = workspace_root(ctx)
  if not db_ready(ctx.paths.workspace_db) then
    return false
  end

  local code, lines = global_lines(root, ctx.paths.workspace_db, { "-d", "--result=grep", symbol })
  if (code ~= 0 and code ~= 1) or not lines or #lines == 0 then
    return false
  end

  return jump_to_global_result(root, lines)
end

function M.android_build_command(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    return nil, err
  end
  if not ctx.project_root then
    return nil, "No project configured for engine root. Run :UESetProject [path]"
  end
  return android_build_command(ctx)
end

local function show_paths()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local plat = target_platform(ctx.engine_root, nil)
  local conf = target_configuration(ctx.engine_root)
  local plat_source = trim(ctx.state.target_platform or "") ~= "" and "set" or (trim(vim.env.UE_TARGET_PLATFORM or "") ~= "" and "env" or "auto")
  local conf_source = trim(ctx.state.target_configuration or "") ~= "" and "set" or (trim(vim.env.UE_TARGET_CONFIGURATION or "") ~= "" and "env" or "auto")

  local lines = {
    "Engine: " .. ctx.engine_root,
    "Project: " .. (ctx.project_root or "<unset>"),
    "Platform: " .. plat .. " (" .. plat_source .. ")",
    "Configuration: " .. conf .. " (" .. conf_source .. ")",
    "GTAGS Root: " .. workspace_root(ctx),
    "Compile Commands: " .. compile_commands_targets(ctx)[1],
    "Compile Commands (Engine): " .. compile_commands_targets(ctx)[2],
    "State: " .. ctx.paths.state,
    "Project List: " .. ctx.paths.project_list,
    "Engine List: " .. ctx.paths.engine_list,
    "Workspace List: " .. ctx.paths.workspace_list,
    "Workspace DB: " .. ctx.paths.workspace_db,
  }
  vim.notify(table.concat(lines, "\n"))
end

local function close_cheatsheet()
  if cheatsheet_win and vim.api.nvim_win_is_valid(cheatsheet_win) then
    vim.api.nvim_win_close(cheatsheet_win, true)
  end
  cheatsheet_win = nil
  cheatsheet_buf = nil
end

local function cheatsheet_path()
  return join(vim.fn.stdpath("config"), "docs", "ue_lazyvim_cheatsheet.md")
end

local function read_cheatsheet_lines()
  local path = cheatsheet_path()
  if is_file(path) then
    local lines = vim.fn.readfile(path)
    if type(lines) == "table" and #lines > 0 then
      return lines
    end
  end

  return {
    "# UE + LazyVim Cheatsheet",
    "",
    "Cheatsheet file missing.",
    "",
    "- Expected path: `" .. path .. "`",
    "- Run `:UECheatsheetEdit` to create or edit it",
  }
end

local function max_line_width(lines)
  local width = 0
  for _, line in ipairs(lines or {}) do
    width = math.max(width, vim.fn.strdisplaywidth(line))
  end
  return width
end

local function open_markdown_float(lines, title)
  if cheatsheet_win and vim.api.nvim_win_is_valid(cheatsheet_win) and cheatsheet_buf and vim.api.nvim_buf_is_valid(cheatsheet_buf) then
    vim.bo[cheatsheet_buf].modifiable = true
    vim.api.nvim_buf_set_lines(cheatsheet_buf, 0, -1, false, lines)
    vim.bo[cheatsheet_buf].modifiable = false
    vim.bo[cheatsheet_buf].readonly = true
    vim.api.nvim_set_current_win(cheatsheet_win)
    return
  end

  local width = math.min(
    math.max(80, math.min(120, max_line_width(lines) + 4)),
    math.max(vim.o.columns - 6, 60)
  )
  local height = math.min(math.max(#lines + 2, 18), math.max(vim.o.lines - 6, 10))
  local row = math.floor((vim.o.lines - height) / 2) - 1
  local col = math.floor((vim.o.columns - width) / 2)

  cheatsheet_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[cheatsheet_buf].buftype = "nofile"
  vim.bo[cheatsheet_buf].bufhidden = "wipe"
  vim.bo[cheatsheet_buf].swapfile = false
  vim.bo[cheatsheet_buf].modifiable = true
  vim.bo[cheatsheet_buf].filetype = "markdown"

  vim.api.nvim_buf_set_lines(cheatsheet_buf, 0, -1, false, lines)
  vim.bo[cheatsheet_buf].modifiable = false
  vim.bo[cheatsheet_buf].readonly = true

  cheatsheet_win = vim.api.nvim_open_win(cheatsheet_buf, true, {
    relative = "editor",
    row = math.max(row, 1),
    col = math.max(col, 1),
    width = width,
    height = height,
    border = "rounded",
    title = title,
    title_pos = "center",
    style = "minimal",
  })

  vim.wo[cheatsheet_win].wrap = true
  vim.wo[cheatsheet_win].linebreak = true
  vim.wo[cheatsheet_win].cursorline = true
  vim.wo[cheatsheet_win].number = false
  vim.wo[cheatsheet_win].relativenumber = false
  vim.wo[cheatsheet_win].signcolumn = "no"
  vim.wo[cheatsheet_win].foldenable = false
  vim.wo[cheatsheet_win].conceallevel = 0

  local close_keys = { "q", "<Esc>" }
  for _, lhs in ipairs(close_keys) do
    vim.keymap.set("n", lhs, close_cheatsheet, { buffer = cheatsheet_buf, silent = true, nowait = true })
  end

  vim.api.nvim_create_autocmd("WinClosed", {
    once = true,
    callback = function(args)
      if tonumber(args.match) == cheatsheet_win then
        cheatsheet_win = nil
        cheatsheet_buf = nil
      end
    end,
  })
end

local function edit_cheatsheet()
  local path = cheatsheet_path()
  ensure_dir(dirname(path))
  vim.cmd("edit " .. vim.fn.fnameescape(path))
end

local function show_cheatsheet()
  local ctx = resolve_context()
  local lines = vim.deepcopy(read_cheatsheet_lines())

  if ctx then
    table.insert(lines, "")
    table.insert(lines, "## Current Context")
    table.insert(lines, "- Engine: `" .. ctx.engine_root .. "`")
    table.insert(lines, "- Project: `" .. (ctx.project_root or "<unset>") .. "`")
  end

  table.insert(lines, "")
  table.insert(lines, "- Cheatsheet file: `" .. cheatsheet_path() .. "`")
  table.insert(lines, "- `:UECheatsheetEdit` opens the markdown file")
  table.insert(lines, "`q` / `<Esc>` close, `j/k` `Ctrl-f/b` `gg/G` scroll")

  open_markdown_float(lines, " UE + LazyVim Cheatsheet ")
end

local function set_project(input)
  local engine_root = current_engine_root()
  if not engine_root then
    vim.notify("No Unreal Engine root found from current buffer or cwd", vim.log.levels.WARN)
    return
  end

  input = trim(input)
  if input == "" then
    local state = read_state(engine_root)
    local default_path = state.project_root or cwd()
    input = vim.fn.input("UE project dir or .uproject: ", default_path, "file")
  end

  local project_root, uproject, err = resolve_project_input(input)
  if not project_root then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  persist_project(engine_root, project_root, uproject)
  invalidate_status_cache()
  refresh_statusline()
  vim.notify("UE project set:\nEngine: " .. engine_root .. "\nProject: " .. project_root)
end

local function set_android_package(input)
  local engine_root = current_engine_root()
  if not engine_root then
    vim.notify("No Unreal Engine root found from current buffer or cwd", vim.log.levels.WARN)
    return
  end

  input = trim(input)
  if input == "" then
    local state = read_state(engine_root)
    input = vim.fn.input("Android package name: ", state.android_package or "")
  end
  if input == "" then
    return
  end

  update_state_field(engine_root, "android_package", input)
  invalidate_status_cache()
  refresh_statusline()
  vim.notify("UE Android package set:\nEngine: " .. engine_root .. "\nPackage: " .. input)
end

local PLATFORM_CHOICES = { "Win64", "Android", "Linux", "Mac", "IOS" }
local CONFIGURATION_CHOICES = { "Development", "DebugGame", "Debug", "Shipping", "Test" }

local function set_platform(input)
  local engine_root = current_engine_root()
  if not engine_root then
    vim.notify("No Unreal Engine root found from current buffer or cwd", vim.log.levels.WARN)
    return
  end

  local state = read_state(engine_root)
  local current_plat = trim(state.target_platform or "")
  local current_conf = trim(state.target_configuration or "")

  -- Direct input: "Win64 Development" or "Win64" or "Android DebugGame"
  input = trim(input or "")
  if input ~= "" then
    local parts = vim.split(input, "%s+")
    local plat = parts[1]
    local conf = parts[2]
    if plat and plat ~= "" then
      update_state_field(engine_root, "target_platform", plat)
    end
    if conf and conf ~= "" then
      update_state_field(engine_root, "target_configuration", conf)
    end
    invalidate_status_cache()
    refresh_statusline()
    _context_cache = {}
    vim.notify(("UE platform: %s %s"):format(
      plat or current_plat or "(auto)",
      conf or current_conf or "Development"
    ))
    return
  end

  -- Interactive: select platform then configuration
  vim.ui.select(PLATFORM_CHOICES, {
    prompt = "Target Platform (current: " .. (current_plat ~= "" and current_plat or "auto") .. "):",
  }, function(plat)
    if not plat then
      return
    end
    vim.ui.select(CONFIGURATION_CHOICES, {
      prompt = "Target Configuration (current: " .. (current_conf ~= "" and current_conf or "Development") .. "):",
    }, function(conf)
      if not conf then
        return
      end
      update_state_field(engine_root, "target_platform", plat)
      update_state_field(engine_root, "target_configuration", conf)
      invalidate_status_cache()
      refresh_statusline()
      _context_cache = {}
      vim.notify(("UE platform set: %s %s\nRun :UEExportCompileCommands to regenerate for this platform"):format(plat, conf))
    end)
  end)
end

local function export_compile_commands()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local ok_compile, compile_result = generate_compile_commands(ctx)
  if not ok_compile then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEExportCompileCommands", compile_result, { root = workspace_root(ctx) })
    vim.notify("UEExportCompileCommands failed: " .. compile_result, vim.log.levels.ERROR)
    return
  end

  clear_index_dirty(ctx)
  invalidate_status_cache()
  refresh_statusline()
  vim.notify("compile_commands exported:\n" .. compile_result)
end

local function build_android()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  if not ctx.project_root then
    vim.notify("No project configured for engine root. Run :UESetProject [path]", vim.log.levels.WARN)
    return
  end

  local plat = target_platform(ctx.engine_root, nil)
  local conf = target_configuration(ctx.engine_root)
  local title = ("UEBuild %s %s"):format(plat, conf)

  local cmd, build_err = android_build_command(ctx)
  if not cmd then
    set_build_status("BERR")
    vim.notify(title .. " failed: " .. build_err, vim.log.levels.ERROR)
    return
  end

  if plat == "Android" then
    cleanup_gradle_debug_artifacts(ctx)
  end
  open_terminal_command(cmd, {
    cwd = windows_host_cwd(),
    quickfix_title = title,
    quickfix_root = workspace_root(ctx),
    tail_limit = 16,
  })
end

-- Find the newest APK in project build outputs
local function find_apk(ctx)
  if not ctx or not ctx.project_root or ctx.project_root == "" then
    return nil
  end
  local pr = ctx.project_root
  local patterns = {
    -- UE5 Gradle output (most common)
    join(pr, "Binaries", "Android", "*.apk"),
    join(pr, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "*.apk"),
    join(pr, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "debug", "*.apk"),
    join(pr, "Intermediate", "Android", "*", "gradle", "app", "build", "outputs", "apk", "release", "*.apk"),
  }
  local best = nil
  local best_mtime = 0
  for _, pattern in ipairs(patterns) do
    for _, path in ipairs(glob_paths(pattern)) do
      local mtime = vim.fn.getftime(path)
      if mtime > best_mtime then
        best = path
        best_mtime = mtime
      end
    end
  end
  return best
end

local function install_android()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  if not ctx.project_root then
    vim.notify("No project configured. Run :UESetProject [path]", vim.log.levels.WARN)
    return
  end

  local apk = find_apk(ctx)
  if not apk then
    vim.notify("No APK found in project build outputs", vim.log.levels.ERROR)
    return
  end

  local apk_win = to_windows_path(apk) or apk
  local mtime = vim.fn.getftime(apk)
  local age = os.time() - mtime
  local age_str
  if age < 60 then
    age_str = age .. "s ago"
  elseif age < 3600 then
    age_str = math.floor(age / 60) .. "m ago"
  else
    age_str = math.floor(age / 3600) .. "h ago"
  end

  local progress = require("fidget.progress")
  local handle = progress.handle.create({
    title = "Installing APK",
    message = ("built %s — %s"):format(age_str, vim.fn.fnamemodify(apk_win, ":t")),
    lsp_client = { name = "adb" },
    percentage = 0,
  })

  local dots = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" }
  local tick = 0
  local timer = vim.uv.new_timer()
  timer:start(0, 120, vim.schedule_wrap(function()
    if handle then
      tick = tick + 1
      handle.message = dots[tick % #dots + 1] .. " installing..."
    end
  end))

  vim.fn.jobstart({ "adb", "install", "-r", apk_win }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.schedule(function()
            if handle then handle.message = line end
          end)
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          vim.schedule(function()
            if handle then handle.message = line end
          end)
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        timer:stop()
        timer:close()
        if code == 0 then
          handle.message = "Installed successfully"
          handle:finish()
        else
          handle.message = "Failed (exit " .. code .. ")"
          handle:finish()
        end
      end)
    end,
  })
end

local function prepare()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  if not ctx.project_root then
    vim.notify("No project configured for engine root. Run :UESetProject [path]", vim.log.levels.WARN)
    return
  end

  if ctx.state.project_root ~= ctx.project_root then
    persist_project(ctx.engine_root, ctx.project_root, ctx.uproject)
  end

  ensure_dir(ctx.paths.cache)

  local project_rel, project_err = scan_relative_files(ctx.project_root, existing_relative_dirs(ctx.project_root, PROJECT_INDEX_DIRS))
  if not project_rel then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEPrepare project scan", project_err, { root = ctx.project_root })
    vim.notify("UEPrepare project scan failed: " .. project_err, vim.log.levels.ERROR)
    return
  end

  local engine_rel, engine_err = scan_relative_files(ctx.engine_root, { "Engine/Source", "Engine/Plugins" })
  if not engine_rel then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEPrepare engine scan", engine_err, { root = ctx.engine_root })
    vim.notify("UEPrepare engine scan failed: " .. engine_err, vim.log.levels.ERROR)
    return
  end

  local project_cpp = filter_gtags_paths(filter_cpp(project_rel))
  local engine_cpp = filter_gtags_paths(filter_cpp(engine_rel))
  local workspace_cpp = {}
  local workspace_seen = {}
  local root = workspace_root(ctx)

  for _, path in ipairs(project_cpp) do
    local absolute = join(ctx.project_root, path)
    local relative = relative_to(root, absolute)
    if not workspace_seen[relative] then
      workspace_seen[relative] = true
      table.insert(workspace_cpp, relative)
    end
  end

  for _, path in ipairs(engine_cpp) do
    local absolute = join(ctx.engine_root, path)
    local relative = relative_to(root, absolute)
    if not workspace_seen[relative] then
      workspace_seen[relative] = true
      table.insert(workspace_cpp, relative)
    end
  end

  table.sort(workspace_cpp)

  write_lines(ctx.paths.project_list, project_cpp)
  write_lines(ctx.paths.engine_list, engine_cpp)
  write_lines(ctx.paths.workspace_list, workspace_cpp)

  local ok_workspace, workspace_err = build_gtags_db(root, ctx.paths.workspace_list, ctx.paths.workspace_db, "workspace")
  if not ok_workspace then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEPrepare GTAGS", workspace_err, { root = root })
    vim.notify("UEPrepare GTAGS failed: " .. workspace_err, vim.log.levels.ERROR)
    return
  end

  local ok_compile, compile_path = generate_compile_commands(ctx)
  if not ok_compile then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEPrepare compile_commands", compile_path, { root = root })
    vim.notify("UEPrepare compile_commands failed: " .. compile_path, vim.log.levels.WARN)
    return
  end

  clear_index_dirty(ctx)
  invalidate_status_cache()
  refresh_statusline()
  vim.notify(
    ("UEPrepare done:\nProject files: %d\nEngine files: %d\nGTAGS files: %d\ncompile_commands: %s\nCache: %s"):format(
      #project_cpp,
      #engine_cpp,
      #workspace_cpp,
      compile_path,
      ctx.paths.cache
    )
  )
end

local function clear_cache()
  local ctx, err = resolve_context({ detect_project = false })
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  pcall(vim.fn.delete, ctx.paths.project_list)
  pcall(vim.fn.delete, ctx.paths.engine_list)
  pcall(vim.fn.delete, ctx.paths.workspace_list)
  pcall(vim.fn.delete, join(ctx.paths.cache, "gtags"), "rf")

  invalidate_status_cache()
  refresh_statusline()
  vim.notify("UE cache cleared under: " .. ctx.paths.cache)
end

-- ---------------------------------------------------------------------------
-- Android DAP debugging via CodeLLDB
-- ---------------------------------------------------------------------------

M._dap_session_state = M._dap_session_state or {}
M._breakpoint_specs = M._breakpoint_specs or {}
M._dap_attach_in_progress = false
M._dap_run_state = M._dap_run_state or "idle"
M._continue_debounce_until_ms = M._continue_debounce_until_ms or 0

local function mono_ms()
  local uv = vim.uv or vim.loop
  if uv and uv.hrtime then
    return math.floor(uv.hrtime() / 1e6)
  end
  return math.floor(vim.fn.reltimefloat(vim.fn.reltime()) * 1000)
end

local function clear_android_breakpoint_state()
  M._breakpoint_specs = {}
  pcall(vim.fn.sign_unplace, "ue_dap_bp")
end

local function save_breakpoints()
  local ctx = resolve_context()
  if not ctx then return end
  local specs = M._breakpoint_specs or {}
  -- Convert to a serialisable list
  local list = {}
  for key, spec in pairs(specs) do
    list[#list + 1] = {
      key = key,
      set_command = spec.set_command,
      clear_command = spec.clear_command,
      file = spec.file,
      line = spec.line,
    }
  end
  update_state_field(ctx.engine_root, "breakpoints", list)
end

local function load_breakpoints()
  local ctx = resolve_context()
  if not ctx then return end
  local state = read_state(ctx.engine_root)
  local list = state and state.breakpoints or {}
  if type(list) ~= "table" or #list == 0 then return end

  vim.fn.sign_define("UEDapBreakpoint", { text = "●", texthl = "DiagnosticError" })

  for _, entry in ipairs(list) do
    if entry.key and entry.set_command then
      -- Migrate old -H (hardware BP) commands to software BP
      local set_cmd = entry.set_command:gsub("breakpoint set %-H ", "breakpoint set ")
      M._breakpoint_specs[entry.key] = {
        set_command = set_cmd,
        clear_command = entry.clear_command,
        file = entry.file,
        line = entry.line,
      }
      -- Restore sign if the buffer is loaded
      local path = entry.key:match("^(.+):%d+$")
      if path then
        local bufnr = vim.fn.bufnr(path)
        if bufnr ~= -1 then
          vim.fn.sign_place(entry.line, "ue_dap_bp", "UEDapBreakpoint", bufnr, { lnum = entry.line })
        end
      end
    end
  end
  -- For files not yet loaded, place signs when they open
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = vim.api.nvim_create_augroup("ue_dap_bp_restore", { clear = true }),
    callback = function(ev)
      local buf_path = norm(vim.api.nvim_buf_get_name(ev.buf))
      if buf_path == "" then return end
      for key, spec in pairs(M._breakpoint_specs) do
        local kpath = key:match("^(.+):%d+$")
        if kpath and norm(kpath) == buf_path then
          vim.fn.sign_define("UEDapBreakpoint", { text = "●", texthl = "DiagnosticError" })
          vim.fn.sign_place(spec.line, "ue_dap_bp", "UEDapBreakpoint", ev.buf, { lnum = spec.line })
        end
      end
    end,
  })
end

local function basename(path)
  return path:match("([^/\\]+)$") or path
end

local function is_sigstop_stop(body)
  if type(body) ~= "table" then
    return false
  end
  local text = table.concat({
    tostring(body.reason or ""),
    tostring(body.description or ""),
    tostring(body.text or ""),
  }, " "):lower()
  return text:find("sigstop", 1, true) ~= nil
end

local function frame_has_local_source(frame)
  local source = frame and frame.source or nil
  if not source then
    return false
  end
  if tonumber(source.sourceReference or 0) ~= 0 then
    return false
  end
  local path = norm(source.path or "")
  if path == "" or path:match("^[a-z]+://") then
    return false
  end
  return is_file(path)
end

local function pick_local_source_frame(frames)
  for _, frame in ipairs(frames or {}) do
    if frame_has_local_source(frame) then
      return frame
    end
  end
  return nil
end

local function request_stack_frames(session, thread_id, cb)
  if not session or not thread_id then
    if cb then cb(nil) end
    return
  end
  session:request("stackTrace", {
    threadId = thread_id,
    startFrame = 0,
    levels = 20,
  }, function(err, response)
    if err then
      if cb then cb(nil, err) end
      return
    end
    local frames = response and response.stackFrames or nil
    local thread = session.threads and session.threads[thread_id] or nil
    if thread and frames then
      thread.frames = frames
    end
    if cb then cb(frames) end
  end)
end

local function maybe_jump_to_local_source_frame(session, body)
  if not session or M._dap_attach_in_progress or is_sigstop_stop(body) then
    return
  end
  if frame_has_local_source(session.current_frame) then
    return
  end

  local thread_id = (body and body.threadId) or session.stopped_thread_id
  if not thread_id then
    return
  end

  local function jump_from_frames(frames)
    if frame_has_local_source(session.current_frame) then
      return
    end
    local frame = pick_local_source_frame(frames)
    if not frame then
      return
    end
    if type(session._frame_set) == "function" then
      session:_frame_set(frame)
      return
    end
    local source = frame.source or {}
    local path = norm(source.path or "")
    if path == "" then
      return
    end
    vim.cmd("edit " .. vim.fn.fnameescape(path))
    vim.api.nvim_win_set_cursor(0, { frame.line or 1, math.max((frame.column or 1) - 1, 0) })
  end

  local thread = session.threads and session.threads[thread_id] or nil
  if thread and thread.frames and #thread.frames > 0 then
    jump_from_frames(thread.frames)
    return
  end

  request_stack_frames(session, thread_id, function(frames)
    vim.schedule(function()
      jump_from_frames(frames)
    end)
  end)
end

local function request_dap_continue(dap)
  local session = dap and dap.session and dap.session() or nil
  if not session then
    return false
  end
  M._continue_pending = true
  M._dap_run_state = "resuming"
  M._continue_debounce_until_ms = mono_ms() + 750
  local ok, err = pcall(dap.continue)
  if ok then
    return true
  end
  M._continue_pending = false
  M._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
  M._continue_debounce_until_ms = 0
  vim.notify("Continue failed: " .. tostring(err), vim.log.levels.WARN)
  return false
end

local function to_windows_path(p)
  if not p or p == "" then return nil end
  return tostring(p):gsub("/", "\\")
end

function M.codelldb_paths()
  local candidates = {
    vim.fn.stdpath("data") .. "/codelldb/extension/extension",
    vim.fn.stdpath("config") .. "/data/codelldb/extension/extension",
  }
  for _, root in ipairs(candidates) do
    local adapter = root .. "/adapter/codelldb"
    local liblldb = root .. "/lldb/bin/liblldb"
    if vim.fn.has("win32") == 1 then
      adapter = adapter .. ".exe"
      liblldb = liblldb .. ".dll"
    elseif vim.fn.has("mac") == 1 then
      liblldb = liblldb .. ".dylib"
    else
      liblldb = liblldb .. ".so"
    end
    if vim.fn.filereadable(adapter) == 1 then
      return adapter, liblldb, root
    end
  end
  return nil, nil, nil
end

function M._reapply_breakpoints(cb)
  local specs = M._breakpoint_specs or {}
  local keys = vim.tbl_keys(specs)
  if #keys == 0 then
    if cb then cb() end
    return
  end
  local pending = #keys
  local function done()
    pending = pending - 1
    if pending <= 0 then
      -- After all BPs set, check resolved status
      M._dap_eval_lldb("breakpoint list", function(_, bp_list)
        vim.schedule(function()
          if bp_list then
            local total, resolved = 0, 0
            for n in bp_list:gmatch("resolved = (%d+)") do
              total = total + 1
              resolved = resolved + tonumber(n)
            end
            vim.notify(("BPs: %d set, %d resolved"):format(total, resolved),
              resolved > 0 and vim.log.levels.INFO or vim.log.levels.WARN)
          end
        end)
        if cb then cb() end
      end)
    end
  end
  for _, key in ipairs(keys) do
    local spec = specs[key]
    M._dap_eval_lldb(spec.set_command, function(ok, result)
      vim.schedule(function()
        if ok then
          vim.notify(("BP restored: %s:%d"):format(spec.file, spec.line))
        else
          vim.notify(("BP restore failed: %s:%d: %s"):format(spec.file, spec.line, tostring(result)), vim.log.levels.WARN)
        end
      end)
      done()
    end)
  end
end

function M._setup_aslr_listeners(dap, attach_state, progress_update)
  local handled = false
  local function do_aslr_and_continue()
    if handled then return end
    handled = true
    dap.listeners.after.event_stopped["ue_aslr_fix"] = nil
    dap.listeners.after.event_initialized["ue_aslr_fix"] = nil
    progress_update("applying ASLR fix...")
    M._apply_aslr_fix(attach_state, function(ok)
      local function do_continue()
        -- MUST use dap.continue() to keep nvim-dap state in sync.
        -- Using _dap_eval_lldb("process continue") bypasses the DAP protocol
        -- and leaves nvim-dap unaware the process is running, which causes:
        -- 1) no auto-jump to source on breakpoint hit
        -- 2) F5 sends duplicate continue → CodeLLDB disconnects
        vim.schedule(function()
          progress_update("READY")
          request_dap_continue(dap)
          M._dap_attach_in_progress = false
        end)
      end
      if ok then
        progress_update("ASLR fix applied, syncing breakpoints...")
        M._reapply_breakpoints(function() do_continue() end)
      else
        progress_update("ASLR fix FAILED — continuing without fix", vim.log.levels.WARN)
        do_continue()
      end
    end)
  end
  -- Primary: on first stopped event (SIGSTOP from attach)
  dap.listeners.after.event_stopped["ue_aslr_fix"] = function(dap_session)
    if dap.session() ~= dap_session then return end
    progress_update("stopped event received")
    do_aslr_and_continue()
  end
  -- Fallback: if event_stopped doesn't fire within 5s
  dap.listeners.after.event_initialized["ue_aslr_fix"] = function()
    dap.listeners.after.event_initialized["ue_aslr_fix"] = nil
    progress_update("DAP initialized, waiting for stopped event...")
    vim.defer_fn(function()
      if not handled then
        progress_update("stopped event timeout, applying ASLR fix anyway...")
        do_aslr_and_continue()
      end
    end, 5000)
  end
end

function M._apply_aslr_fix(session_state, cb)
  local pid = session_state.pid
  local so_name = session_state.symbol_lib and vim.fn.fnamemodify(session_state.symbol_lib, ":t") or "libUE4.so"
  local pkg = session_state.package_name or ""
  local adb = session_state.adb or "adb"
  local cb_fired = false

  local function fire_cb(ok, msg)
    if cb_fired then return end
    cb_fired = true
    if msg then vim.notify("ASLR fix: " .. msg, ok and vim.log.levels.INFO or vim.log.levels.ERROR) end
    if cb then cb(ok) end
  end

  local function parse_base(text)
    for line in text:gmatch("[^\r\n]+") do
      if line:find(so_name, 1, true) then
        return line:match("(%x+)%-")
      end
    end
    return nil
  end

  local function apply_slide(base_addr)
    local base_hex = "0x" .. base_addr
    vim.notify("ASLR fix: " .. so_name .. " base=" .. base_hex)
    M._dap_eval_lldb(
      ("target modules load --file %s --slide %s"):format(so_name, base_hex),
      function(ok2, result2)
        vim.schedule(function()
          if ok2 then
            -- Verify module state after slide
            M._dap_eval_lldb("image list " .. so_name, function(_, img)
              vim.schedule(function()
                vim.notify("ASLR fix applied (slide=" .. base_hex .. ")\n" .. (img or ""))
                fire_cb(true, nil)
              end)
            end)
          else
            fire_cb(false, "target modules load FAILED: " .. tostring(result2))
          end
        end)
      end
    )
  end

  local function fallback_adb()
    if pkg == "" then
      fire_cb(false, "no package_name for adb fallback")
      return
    end
    vim.notify("ASLR fix: trying adb run-as fallback...")
    vim.fn.jobstart({ adb, "shell", "run-as", pkg, "cat", "/proc/" .. pid .. "/maps" }, {
      stdout_buffered = true,
      on_stdout = function(_, data)
        local text = table.concat(data or {}, "\n")
        local base = parse_base(text)
        if base then
          vim.schedule(function() apply_slide(base) end)
        else
          vim.schedule(function() fire_cb(false, so_name .. " not found (adb run-as)") end)
        end
      end,
      on_exit = function(_, code)
        if code ~= 0 then
          vim.schedule(function() fire_cb(false, "adb run-as exit " .. code) end)
        end
      end,
    })
  end

  -- Primary: LLDB platform shell (lldb-server runs as the app)
  vim.notify("ASLR fix: reading /proc/" .. pid .. "/maps via platform shell...")
  M._dap_eval_lldb(
    ('platform shell grep %s /proc/%s/maps'):format(so_name, pid),
    function(ok, result)
      vim.schedule(function()
        if ok and result and result ~= "" then
          local base = parse_base(result)
          if base then
            apply_slide(base)
            return
          end
        end
        fallback_adb()
      end)
    end
  )

  vim.defer_fn(function() fire_cb(false, "timed out (15s)") end, 15000)
end

function M._android_dap_config(session)
  local target_create = {}
  if session.symbol_lib then
    table.insert(target_create, ('target create "%s"'):format(session.symbol_lib))
  end
  for _, sp in ipairs(session.exec_search_paths or {}) do
    table.insert(target_create, ('settings append target.exec-search-paths "%s"'):format(sp))
  end
  return {
    name = "UE Android Attach",
    type = "codelldb",
    request = "attach",
    breakpointMode = "file",
    stopOnEntry = false,
    program = session.symbol_lib,
    cwd = session.project_root or vim.fn.getcwd(),
    sourceLanguages = { "cpp" },
    sourceMap = (session.source_map and next(session.source_map)) and session.source_map or vim.empty_dict(),
    initCommands = {
      "settings set stop-disassembly-display never",
      "settings set target.inline-breakpoint-strategy always",
      "settings set target.move-to-nearest-code true",
      "settings set target.process.stop-on-sharedlibrary-events false",
      "platform select remote-android",
    },
    targetCreateCommands = target_create,
    processCreateCommands = {
      ('platform connect "%s"'):format(session.connect_uri),
      ("process attach -p %s"):format(session.pid),
      "settings set target.process.thread.step-avoid-regexp ''",
      "process handle SIGSTOP -p true -s false -n false",
      "process handle SIGSEGV -p true -s false -n false",
      "process handle SIGBUS -p true -s false -n false",
      "process handle SIGPIPE -p true -s false -n false",
    },
    preTerminateCommands = { "process detach" },
  }
end

function M._android_preflight_ps1(session)
  local pkg = session.package_name
  return ([[
$ErrorActionPreference = "Stop"
$adb = "]] .. (session.adb or "adb") .. [["
$serial = (& $adb devices | Select-String "^\S+\s+device$" | Select-Object -First 1).Line.Split()[0]
if (-not $serial) { throw "No Android device found" }
Write-Host "serial=$serial"
$raw = (& $adb -s $serial shell pidof -s "]] .. pkg .. [[" 2>$null)
$targetPid = (($raw | Out-String) -replace '\D','').Trim()
if (-not $targetPid) { throw "Process ]] .. pkg .. [[ not running" }
Write-Host "pid=$targetPid"
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c 'pkill -9 lldb-server 2>/dev/null; rm -rf /data/data/]] .. pkg .. [[/lldb 2>/dev/null'" 2>$null
& $adb -s $serial shell "run-as ]] .. pkg .. [[ mkdir -p /data/data/]] .. pkg .. [[/lldb/bin"
& $adb -s $serial push "]] .. session.lldb_server_path .. [[" "/data/local/tmp/lldb-server"
& $adb -s $serial shell "cat /data/local/tmp/lldb-server | run-as ]] .. pkg .. [[ sh -c 'cat > /data/data/]] .. pkg .. [[/lldb/bin/lldb-server && chmod 700 /data/data/]] .. pkg .. [[/lldb/bin/lldb-server'"
$sockPath = "/data/data/]] .. pkg .. [[/lldb/]] .. session.socket_name .. [["
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c '/data/data/]] .. pkg .. [[/lldb/bin/lldb-server platform --server --listen unix-abstract://$sockPath </dev/null >/dev/null 2>&1 & echo started'"
Start-Sleep -Seconds 2
$lldbPid = ((& $adb -s $serial shell "run-as ]] .. pkg .. [[ pidof lldb-server" 2>$null) | Out-String).Trim()
if (-not $lldbPid) { throw "lldb-server failed to start" }
Write-Host "lldb-server pid=$lldbPid"
$connectUri = "unix-abstract-connect://[$serial]$sockPath"
Write-Host "connect_uri=$connectUri"
$targetPid | Out-File -Encoding ascii "]] .. session.pid_file .. [["
$serial | Out-File -Encoding ascii "]] .. session.serial_file .. [["
$connectUri | Out-File -Encoding ascii "]] .. session.uri_file .. [["
Write-Host "PREFLIGHT_OK"
]])
end

function M.android_dap_attach()
  local dap_ok, dap = pcall(require, "dap")
  if not dap_ok then
    vim.notify("nvim-dap not installed", vim.log.levels.ERROR)
    return
  end
  if M._dap_attach_in_progress then
    vim.notify("DAP attach/launch already in progress", vim.log.levels.WARN)
    return
  end
  if vim.fn.exepath("adb") == "" then
    vim.notify("adb not found in PATH", vim.log.levels.ERROR)
    return
  end
  local ctx = resolve_context() or {}
  local project_root = ctx.project_root or ""
  local engine_root = ctx.engine_root or ""
  local state = ctx.state or {}

  -- Auto-detect symbol .so: try libUE4.so (UE4) then libUnreal.so (UE5)
  local symbol_lib = ""
  if project_root ~= "" then
    local so_dir = project_root .. "/Intermediate/Android/arm64/jni/arm64-v8a/"
    for _, name in ipairs({ "libUE4.so", "libUnreal.so" }) do
      local candidate = vim.fn.glob(so_dir .. name)
      if candidate ~= "" then
        symbol_lib = candidate
        break
      end
    end
  end
  if symbol_lib == "" then
    local default = project_root ~= "" and (project_root .. "/") or ""
    symbol_lib = vim.fn.input("Path to symbol .so (with debug symbols): ", default)
  end
  if symbol_lib == "" then return end

  -- Package name: read from persisted state, fallback to prompt
  local saved_pkg = state.android_package or ""
  local package_name = saved_pkg
  if package_name == "" then
    package_name = vim.fn.input("Android package name: ", "")
  end
  if package_name == "" then return end
  -- Persist for next attach
  if engine_root ~= "" and package_name ~= saved_pkg then
    update_state_field(engine_root, "android_package", package_name)
    invalidate_status_cache()
  end

  -- lldb-server: search Android Studio, NDK side-by-side, then prompt
  local as_lldb = ""
  local localappdata = vim.fn.expand("$LOCALAPPDATA")
  local search_patterns = {
    localappdata .. "/Programs/Android Studio*/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server",
    localappdata .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
  }
  for _, pattern in ipairs(search_patterns) do
    as_lldb = vim.fn.glob(pattern)
    if as_lldb ~= "" then break end
  end
  if as_lldb == "" then
    as_lldb = vim.fn.input("Path to arm64 lldb-server: ")
  end
  if as_lldb == "" then return end

  local tmpdir = vim.fn.tempname():gsub("[/\\][^/\\]*$", "")
  local attach_state = {
    package_name = package_name,
    symbol_lib = to_windows_path(symbol_lib) or symbol_lib,
    lldb_server_path = to_windows_path(as_lldb) or as_lldb,
    project_root = to_windows_path(project_root) or project_root,
    engine_root = to_windows_path(engine_root) or engine_root,
    adb = to_windows_path(vim.fn.exepath("adb")) or "adb",
    socket_name = "lldb-platform-" .. vim.uv.hrtime(),
    pid_file = to_windows_path(tmpdir .. "/ue_dap_pid.txt"),
    serial_file = to_windows_path(tmpdir .. "/ue_dap_serial.txt"),
    uri_file = to_windows_path(tmpdir .. "/ue_dap_uri.txt"),
    exec_search_paths = { to_windows_path(vim.fn.fnamemodify(symbol_lib, ":h")) },
    source_map = {},
  }
  if engine_root ~= "" then
    local er = engine_root:gsub("\\", "/")
    attach_state.source_map[er] = er
  end
  if project_root ~= "" then
    local pr = project_root:gsub("\\", "/")
    attach_state.source_map[pr] = pr
  end

  M._dap_attach_in_progress = true
  M._dap_run_state = "attaching"
  local progress = { "DAP Attach" }
  local notify_id = "ue_dap_attach"
  local function progress_update(msg, level)
    table.insert(progress, msg)
    vim.notify(table.concat(progress, "\n"), level or vim.log.levels.INFO, { id = notify_id, title = "DAP Attach" })
  end

  progress_update("starting preflight...")
  local ps1 = M._android_preflight_ps1(attach_state)
  local preflight_done = false
  local preflight_job = vim.fn.jobstart({ "powershell", "-NoProfile", "-Command", ps1 }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update(line) end) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update("ERR: " .. line, vim.log.levels.WARN) end) end
      end
    end,
    on_exit = function(_, code)
      preflight_done = true
      vim.schedule(function()
        if code ~= 0 then
          M._dap_attach_in_progress = false
          M._dap_run_state = "idle"
          progress_update("FAILED (exit " .. code .. ")", vim.log.levels.ERROR)
          return
        end
        local pid = trim((vim.fn.readfile(attach_state.pid_file) or {})[1] or "")
        local connect_uri = trim((vim.fn.readfile(attach_state.uri_file) or {})[1] or "")
        if pid == "" or connect_uri == "" then
          M._dap_attach_in_progress = false
          M._dap_run_state = "idle"
          progress_update("no PID or connect URI produced", vim.log.levels.ERROR)
          return
        end
        attach_state.pid = pid
        attach_state.connect_uri = connect_uri
        M._dap_session_state = attach_state
        progress_update(("pid=%s, connecting DAP..."):format(pid))
        M._setup_aslr_listeners(dap, attach_state, progress_update)
        dap.run(M._android_dap_config(attach_state))
      end)
    end,
  })
  -- Timeout: kill preflight if it hangs (device disconnected, adb stuck)
  if preflight_job and preflight_job > 0 then
    vim.defer_fn(function()
      if preflight_done then return end
      pcall(vim.fn.jobstop, preflight_job)
      M._dap_attach_in_progress = false
      M._dap_run_state = "idle"
      progress_update("TIMED OUT (30s) — device may be disconnected", vim.log.levels.ERROR)
    end, 30000)
  end
end

function M._android_launch_preflight_ps1(session)
  local pkg = session.package_name
  -- Native debugging: start app normally (not -D which waits for JDWP/Java debugger).
  -- Auto-detect main launcher activity from package manager.
  return ([[
$ErrorActionPreference = "Stop"
$adb = "]] .. (session.adb or "adb") .. [["
$serial = (& $adb devices | Select-String "^\S+\s+device$" | Select-Object -First 1).Line.Split()[0]
if (-not $serial) { throw "No Android device found" }
Write-Host "device=$serial"
# Detect main activity
$dumpLines = (& $adb -s $serial shell "dumpsys package ]] .. pkg .. [[" 2>$null) -split "`n"
$activity = ""
$inMain = $false
foreach ($l in $dumpLines) {
    if ($l -match 'android\.intent\.action\.MAIN') { $inMain = $true; continue }
    if ($inMain -and $l -match ']] .. pkg:gsub("%.", "\\.") .. [[/([^\s]+)') {
        $activity = $Matches[1]
        break
    }
    if ($inMain -and $l.Trim() -eq "") { $inMain = $false }
}
if (-not $activity) { $activity = "com.epicgames.unreal.GameActivity" }
Write-Host "activity=$activity"
# Force-stop
Write-Host "force-stop..."
& $adb -s $serial shell "am force-stop ]] .. pkg .. [["
Start-Sleep -Milliseconds 500
# Launch
Write-Host "launching ]] .. pkg .. [[/$activity ..."
& $adb -s $serial shell "am start -n ]] .. pkg .. [[/$activity"
Write-Host "waiting for process..."
$retries = 0
$targetPid = ""
while ($retries -lt 15) {
    Start-Sleep -Milliseconds 500
    $raw = (& $adb -s $serial shell pidof -s "]] .. pkg .. [[" 2>$null)
    $targetPid = (($raw | Out-String) -replace '\D','').Trim()
    if ($targetPid) { break }
    $retries++
}
if (-not $targetPid) { throw "Process ]] .. pkg .. [[ did not start within 8s" }
Write-Host "pid=$targetPid"
Write-Host "setting up lldb-server..."
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c 'pkill -9 lldb-server 2>/dev/null; rm -rf /data/data/]] .. pkg .. [[/lldb 2>/dev/null'" 2>$null
& $adb -s $serial shell "run-as ]] .. pkg .. [[ mkdir -p /data/data/]] .. pkg .. [[/lldb/bin"
& $adb -s $serial push "]] .. session.lldb_server_path .. [[" "/data/local/tmp/lldb-server"
& $adb -s $serial shell "cat /data/local/tmp/lldb-server | run-as ]] .. pkg .. [[ sh -c 'cat > /data/data/]] .. pkg .. [[/lldb/bin/lldb-server && chmod 700 /data/data/]] .. pkg .. [[/lldb/bin/lldb-server'"
$sockPath = "/data/data/]] .. pkg .. [[/lldb/]] .. session.socket_name .. [["
& $adb -s $serial shell "run-as ]] .. pkg .. [[ sh -c '/data/data/]] .. pkg .. [[/lldb/bin/lldb-server platform --server --listen unix-abstract://$sockPath </dev/null >/dev/null 2>&1 & echo started'"
Start-Sleep -Seconds 2
$lldbPid = ((& $adb -s $serial shell "run-as ]] .. pkg .. [[ pidof lldb-server" 2>$null) | Out-String).Trim()
if (-not $lldbPid) { throw "lldb-server failed to start" }
Write-Host "lldb-server pid=$lldbPid"
$connectUri = "unix-abstract-connect://[$serial]$sockPath"
Write-Host "connect_uri=$connectUri"
$targetPid | Out-File -Encoding ascii "]] .. session.pid_file .. [["
$serial | Out-File -Encoding ascii "]] .. session.serial_file .. [["
$connectUri | Out-File -Encoding ascii "]] .. session.uri_file .. [["
Write-Host "PREFLIGHT_OK"
]])
end

function M.android_dap_launch()
  local dap_ok, dap = pcall(require, "dap")
  if not dap_ok then
    vim.notify("nvim-dap not installed", vim.log.levels.ERROR)
    return
  end
  if M._dap_attach_in_progress then
    vim.notify("DAP attach/launch already in progress", vim.log.levels.WARN)
    return
  end
  if vim.fn.exepath("adb") == "" then
    vim.notify("adb not found in PATH", vim.log.levels.ERROR)
    return
  end
  local ctx = resolve_context() or {}
  local project_root = ctx.project_root or ""
  local engine_root = ctx.engine_root or ""
  local state = ctx.state or {}

  -- Auto-detect symbol .so
  local symbol_lib = ""
  if project_root ~= "" then
    local so_dir = project_root .. "/Intermediate/Android/arm64/jni/arm64-v8a/"
    for _, name in ipairs({ "libUE4.so", "libUnreal.so" }) do
      local candidate = vim.fn.glob(so_dir .. name)
      if candidate ~= "" then
        symbol_lib = candidate
        break
      end
    end
  end
  if symbol_lib == "" then
    local default = project_root ~= "" and (project_root .. "/") or ""
    symbol_lib = vim.fn.input("Path to symbol .so (with debug symbols): ", default)
  end
  if symbol_lib == "" then return end

  -- Package name
  local saved_pkg = state.android_package or ""
  local package_name = saved_pkg
  if package_name == "" then
    package_name = vim.fn.input("Android package name: ", "")
  end
  if package_name == "" then return end
  if engine_root ~= "" and package_name ~= saved_pkg then
    update_state_field(engine_root, "android_package", package_name)
    invalidate_status_cache()
  end

  -- lldb-server
  local as_lldb = ""
  local localappdata = vim.fn.expand("$LOCALAPPDATA")
  local search_patterns = {
    localappdata .. "/Programs/Android Studio*/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server",
    localappdata .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server",
  }
  for _, pattern in ipairs(search_patterns) do
    as_lldb = vim.fn.glob(pattern)
    if as_lldb ~= "" then break end
  end
  if as_lldb == "" then
    as_lldb = vim.fn.input("Path to arm64 lldb-server: ")
  end
  if as_lldb == "" then return end

  local tmpdir = vim.fn.tempname():gsub("[/\\][^/\\]*$", "")
  local attach_state = {
    package_name = package_name,
    symbol_lib = to_windows_path(symbol_lib) or symbol_lib,
    lldb_server_path = to_windows_path(as_lldb) or as_lldb,
    project_root = to_windows_path(project_root) or project_root,
    engine_root = to_windows_path(engine_root) or engine_root,
    adb = to_windows_path(vim.fn.exepath("adb")) or "adb",
    socket_name = "lldb-platform-" .. vim.uv.hrtime(),
    pid_file = to_windows_path(tmpdir .. "/ue_dap_pid.txt"),
    serial_file = to_windows_path(tmpdir .. "/ue_dap_serial.txt"),
    uri_file = to_windows_path(tmpdir .. "/ue_dap_uri.txt"),
    exec_search_paths = { to_windows_path(vim.fn.fnamemodify(symbol_lib, ":h")) },
    source_map = {},
  }
  if engine_root ~= "" then
    local er = engine_root:gsub("\\", "/")
    attach_state.source_map[er] = er
  end
  if project_root ~= "" then
    local pr = project_root:gsub("\\", "/")
    attach_state.source_map[pr] = pr
  end

  M._dap_attach_in_progress = true
  M._dap_run_state = "attaching"
  local progress = { "DAP Launch" }
  local notify_id = "ue_dap_launch"
  local function progress_update(msg, level)
    table.insert(progress, msg)
    vim.notify(table.concat(progress, "\n"), level or vim.log.levels.INFO, { id = notify_id, title = "DAP Launch" })
  end

  progress_update("starting...")
  local ps1 = M._android_launch_preflight_ps1(attach_state)
  local preflight_done = false
  local preflight_job = vim.fn.jobstart({ "powershell", "-NoProfile", "-Command", ps1 }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update(line) end) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then vim.schedule(function() progress_update("ERR: " .. line, vim.log.levels.WARN) end) end
      end
    end,
    on_exit = function(_, code)
      preflight_done = true
      vim.schedule(function()
        if code ~= 0 then
          M._dap_attach_in_progress = false
          M._dap_run_state = "idle"
          progress_update("FAILED (exit " .. code .. ")", vim.log.levels.ERROR)
          return
        end
        local pid = trim((vim.fn.readfile(attach_state.pid_file) or {})[1] or "")
        local connect_uri = trim((vim.fn.readfile(attach_state.uri_file) or {})[1] or "")
        if pid == "" or connect_uri == "" then
          M._dap_attach_in_progress = false
          M._dap_run_state = "idle"
          progress_update("no PID or connect URI produced", vim.log.levels.ERROR)
          return
        end
        attach_state.pid = pid
        attach_state.connect_uri = connect_uri
        M._dap_session_state = attach_state
        progress_update(("pid=%s, connecting DAP..."):format(pid))
        M._setup_aslr_listeners(dap, attach_state, progress_update)
        dap.run(M._android_dap_config(attach_state))
      end)
    end,
  })
  -- Timeout: kill preflight if it hangs (device disconnected, adb stuck)
  if preflight_job and preflight_job > 0 then
    vim.defer_fn(function()
      if preflight_done then return end
      pcall(vim.fn.jobstop, preflight_job)
      M._dap_attach_in_progress = false
      M._dap_run_state = "idle"
      progress_update("TIMED OUT (30s) — device may be disconnected", vim.log.levels.ERROR)
    end, 30000)
  end
end

function M._dap_eval_lldb(command, cb)
  local dap = require("dap")
  local session = dap.session()
  if not session then
    if cb then cb(false, "No DAP session") end
    return
  end
  -- CodeLLDB repl evaluate works without frameId even when the process is running
  session:evaluate(command, function(err, resp)
    local result = resp and resp.result or ""
    if err then
      if cb then cb(false, tostring(err)) end
    else
      if cb then cb(true, result) end
    end
  end, { context = "repl" })
end

function M.dap_toggle_breakpoint()
  local dap_ok, dap = pcall(require, "dap")
  local has_session = dap_ok and dap.session() ~= nil

  local bufnr = vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local path = norm(vim.api.nvim_buf_get_name(bufnr))
  if path == "" then return end
  local file = basename(path)
  local key = path .. ":" .. line
  local is_set = M._breakpoint_specs[key] ~= nil

  if is_set then
    -- Remove breakpoint
    local spec = M._breakpoint_specs[key]
    M._breakpoint_specs[key] = nil
    vim.fn.sign_unplace("ue_dap_bp", { buffer = bufnr, id = line })
    if has_session then
      M._dap_eval_lldb(spec.clear_command, function(ok2, result)
        vim.schedule(function()
          vim.notify(ok2 and ("BP cleared: %s:%d"):format(file, line)
            or ("BP clear failed: %s"):format(result), ok2 and vim.log.levels.INFO or vim.log.levels.ERROR)
        end)
      end)
    else
      vim.notify(("BP removed (pending): %s:%d"):format(file, line))
    end
  else
    -- Add breakpoint (software BP — requires correct ASLR slide)
    local set_cmd = ('breakpoint set --file "%s" --line %d'):format(file, line)
    local clear_cmd = ('breakpoint clear --file "%s" --line %d'):format(file, line)
    M._breakpoint_specs[key] = { set_command = set_cmd, clear_command = clear_cmd, file = file, line = line }
    vim.fn.sign_define("UEDapBreakpoint", { text = "●", texthl = "DiagnosticError" })
    vim.fn.sign_place(line, "ue_dap_bp", "UEDapBreakpoint", bufnr, { lnum = line })
    if has_session then
      M._dap_eval_lldb(set_cmd, function(ok2, result)
        vim.schedule(function()
          if ok2 then
            -- Verify resolved status
            M._dap_eval_lldb("breakpoint list", function(_, bp_list)
              vim.schedule(function()
                local resolved = 0
                if bp_list then
                  for n in bp_list:gmatch("resolved = (%d+)") do
                    resolved = resolved + tonumber(n)
                  end
                end
                if resolved > 0 then
                  vim.notify(("BP set: %s:%d (resolved)"):format(file, line))
                else
                  -- Diagnose: check what LLDB knows about this file
                  M._dap_eval_lldb(('image lookup --file "%s"'):format(file), function(_, lookup)
                    vim.schedule(function()
                      local diag = ("BP UNRESOLVED: %s:%d\n"):format(file, line)
                      if lookup and lookup ~= "" then
                        -- Show first few matches to reveal DWARF paths
                        local lines = {}
                        for l in lookup:gmatch("[^\n]+") do
                          lines[#lines + 1] = l
                          if #lines >= 8 then break end
                        end
                        diag = diag .. "image lookup found:\n" .. table.concat(lines, "\n")
                      else
                        diag = diag .. "image lookup: file NOT found in any module"
                      end
                      vim.notify(diag, vim.log.levels.WARN)
                    end)
                  end)
                end
              end)
            end)
          else
            M._breakpoint_specs[key] = nil
            vim.fn.sign_unplace("ue_dap_bp", { buffer = bufnr, id = line })
            vim.notify(("BP set failed: %s"):format(result), vim.log.levels.ERROR)
          end
        end)
      end)
    else
      vim.notify(("BP pending: %s:%d (will apply on attach)"):format(file, line))
    end
  end
  save_breakpoints()
end

function M.dap_continue()
  local ok, dap = pcall(require, "dap")
  if not ok or not dap.session() then return end
  if M._dap_attach_in_progress then
    vim.notify("Attach bootstrap still running; wait for READY", vim.log.levels.DEBUG)
    return
  end
  local now = mono_ms()
  if M._dap_run_state ~= "stopped" and now < (M._continue_debounce_until_ms or 0) then
    return
  end
  if M._continue_pending or M._dap_run_state == "resuming" then return end
  local session = dap.session()
  local is_stopped = M._dap_run_state == "stopped"
    or (session.stopped_thread_id and M._dap_run_state ~= "running" and M._dap_run_state ~= "attaching")
  if is_stopped then
    request_dap_continue(dap)
  else
    M._continue_debounce_until_ms = now + 250
    vim.notify("Process already running", vim.log.levels.DEBUG)
  end
end

function M.dap_pause()
  local ok, dap = pcall(require, "dap")
  if not ok or not dap.session() then return end
  if M._pause_pending then return end
  M._pause_pending = true
  vim.defer_fn(function() M._pause_pending = false end, 500)
  local session = dap.session()
  session:request("pause", { threadId = 0 }, function(err)
    if err then
      session:request("threads", {}, function(terr, tresp)
        if not terr and tresp and tresp.threads and tresp.threads[1] then
          session:request("pause", { threadId = tresp.threads[1].id })
        else
          vim.schedule(function()
            vim.notify("Pause failed: " .. tostring(err), vim.log.levels.ERROR)
          end)
        end
      end)
    end
  end)
end

function M.dap_step_over()
  local ok, dap = pcall(require, "dap")
  if ok and dap.session() then dap.step_over() end
end

function M.dap_step_into()
  local ok, dap = pcall(require, "dap")
  if ok and dap.session() then dap.step_into() end
end

function M.dap_step_out()
  local ok, dap = pcall(require, "dap")
  if ok and dap.session() then dap.step_out() end
end

function M.dap_toggle_ui()
  local ok, dapui = pcall(require, "dapui")
  if not ok then return end
  dapui.toggle()
end

function M.dap_reset_layout()
  local dap_ok, dap = pcall(require, "dap")
  local dapui_ok, dapui = pcall(require, "dapui")
  if dap_ok and dap.session() and dapui_ok then
    -- DAP active: close and re-open DAP UI to reset split sizes
    dapui.close()
    -- Close all non-normal windows (leftover floats, etc.)
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local bt = vim.bo[buf].buftype
        if bt == "nofile" or bt == "prompt" then
          local ft = vim.bo[buf].filetype
          if ft:find("^dap") then
            pcall(vim.api.nvim_win_close, win, true)
          end
        end
      end
    end
    vim.cmd("wincmd =")
    dapui.open({ reset = true })
  else
    -- No DAP: close everything except current window
    vim.cmd("only")
    vim.cmd("wincmd =")
  end
end

function M.dap_toggle_repl()
  local ok, dap = pcall(require, "dap")
  if ok then dap.repl.toggle() end
end

function M.dap_diagnose()
  local dap_ok, dap = pcall(require, "dap")
  if not dap_ok or not dap.session() then
    vim.notify("No DAP session", vim.log.levels.WARN)
    return
  end

  local results = {}
  local pending = 3
  local function collect(label, ok, data)
    if ok and data and data ~= "" then
      results[#results + 1] = ("=== %s ===\n%s"):format(label, data)
    else
      results[#results + 1] = ("=== %s ===\n(empty)"):format(label)
    end
    pending = pending - 1
    if pending <= 0 then
      vim.schedule(function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(table.concat(results, "\n\n"), "\n"))
        vim.bo[buf].buftype = "nofile"
        vim.bo[buf].filetype = "log"
        vim.cmd("botright split")
        vim.api.nvim_win_set_buf(0, buf)
      end)
    end
  end

  -- 1) What modules does LLDB have loaded?
  M._dap_eval_lldb("image list", function(ok, r) collect("image list", ok, r) end)
  -- 2) Check symbol file status for the main .so
  local state = M._dap_session_state or {}
  local so_name = state.symbol_lib and vim.fn.fnamemodify(state.symbol_lib, ":t") or "libUE4.so"
  M._dap_eval_lldb(
    ('image dump symfile "%s"'):format(so_name),
    function(ok, r) collect("symfile " .. so_name, ok, r) end
  )
  -- 3) Check source map and settings
  M._dap_eval_lldb("settings show target.source-map", function(ok, r) collect("source-map", ok, r) end)
end

function M.setup_dap(dap, dapui)
  local adapter, liblldb = M.codelldb_paths()
  if not adapter then
    vim.notify("CodeLLDB not found. Install it to enable Android debugging.", vim.log.levels.WARN)
    return
  end
  dap.adapters.codelldb = {
    type = "server",
    port = "${port}",
    executable = { command = adapter, args = { "--port", "${port}", "--liblldb", liblldb } },
  }
  -- Remember which window/buffer was active before DAP UI opened
  local saved_win = nil
  local saved_buf = nil
  local function save_layout()
    if not saved_win then
      saved_win = vim.api.nvim_get_current_win()
      saved_buf = vim.api.nvim_get_current_buf()
    end
  end
  local function restore_layout()
    dapui.close()
    -- Close any leftover DAP/special windows, keep only normal file windows
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_is_valid(win) then
        local buf = vim.api.nvim_win_get_buf(win)
        local bt = vim.bo[buf].buftype
        local ft = vim.bo[buf].filetype
        if bt == "nofile" or ft:find("^dap") then
          pcall(vim.api.nvim_win_close, win, true)
        end
      end
    end
    -- Focus the original window or the first remaining window
    if saved_win and vim.api.nvim_win_is_valid(saved_win) then
      pcall(vim.api.nvim_set_current_win, saved_win)
    elseif saved_buf and vim.api.nvim_buf_is_valid(saved_buf) then
      -- Original window gone but buffer alive — switch to it
      pcall(vim.cmd, "buffer " .. saved_buf)
    end
    saved_win = nil
    saved_buf = nil
    -- Equalize whatever windows remain
    vim.cmd("wincmd =")
  end

  local function close_explorer()
    local ok_snacks, snacks = pcall(require, "snacks")
    if ok_snacks and snacks.picker and snacks.picker.get then
      for _, picker in ipairs(snacks.picker.get({ source = "explorer" }) or {}) do
        pcall(function() picker:close() end)
      end
    end
  end

  local function on_session_end()
    restore_layout()
    M._dap_attach_in_progress = false
    M._dap_run_state = "idle"
    M._continue_pending = false
    M._continue_debounce_until_ms = 0
    M._pause_pending = false
    -- Clean up any pending ASLR listeners (session died before event_stopped)
    dap.listeners.after.event_stopped["ue_aslr_fix"] = nil
    dap.listeners.after.event_initialized["ue_aslr_fix"] = nil
    -- Keep _breakpoint_specs and signs so they persist across re-attach.
    -- They will be re-applied to the new LLDB session after ASLR fix.
    -- Kill remote lldb-server so re-attach can start a new one
    local state = M._dap_session_state or {}
    if state.package_name then
      vim.fn.jobstart({ state.adb or "adb", "shell",
        "run-as " .. state.package_name .. " sh -c 'pkill -9 lldb-server 2>/dev/null'" }, { detach = true })
    end
    M._dap_session_state = {}
  end

  dap.listeners.after.event_initialized["dapui_config"] = function()
    close_explorer()
    save_layout()
    dapui.open()
  end
  dap.listeners.before.event_terminated["dapui_config"] = function() on_session_end() end
  dap.listeners.before.event_exited["dapui_config"] = function() on_session_end() end
  dap.listeners.after.disconnect["dapui_config"] = function() on_session_end() end

  dap.listeners.after.event_initialized["ue-android-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    M._dap_run_state = M._dap_attach_in_progress and "attaching" or "stopped"
  end
  dap.listeners.after.event_stopped["ue-android-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    M._dap_run_state = "stopped"
    M._continue_pending = false
    M._continue_debounce_until_ms = 0
    M._pause_pending = false
  end
  dap.listeners.after.event_continued["ue-android-dap-run-state"] = function(session)
    if dap.session() ~= session then return end
    M._dap_run_state = "running"
    M._continue_pending = false
    session.current_frame = nil
    session.stopped_thread_id = nil
  end
  dap.listeners.after["continue"]["ue-android-dap-run-state"] = function(session, err)
    if dap.session() ~= session or not err then return end
    M._continue_pending = false
    M._continue_debounce_until_ms = 0
    M._dap_run_state = session.stopped_thread_id and "stopped" or "idle"
  end
  dap.listeners.after.event_stopped["ue-android-dap-source-nav"] = function(session, body)
    if dap.session() ~= session then return end
    maybe_jump_to_local_source_frame(session, body)
  end

  -- Track global scope variablesReferences to block them (crashes LLDB on huge binaries)
  local blocked_refs = {}
  dap.listeners.before.event_stopped["ue_clear_blocked"] = function()
    blocked_refs = {}
  end
  dap.listeners.after.scopes["ue_block_globals"] = function(_, body)
    if body and body.scopes then
      for i = #body.scopes, 1, -1 do
        local s = body.scopes[i]
        if s.name == "Globals" or s.name == "Static" then
          blocked_refs[s.variablesReference] = true
          table.remove(body.scopes, i)
        end
      end
    end
  end
  vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DiagnosticError" })
  vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DiagnosticInfo", linehl = "CursorLine" })

  -- Full cleanup on quit: disconnect DAP, kill CodeLLDB adapter, kill remote lldb-server
  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = vim.api.nvim_create_augroup("ue_dap_cleanup", { clear = true }),
    callback = function()
      local session = dap.session()
      if not session then return end
      -- Detach cleanly so the game keeps running
      pcall(function()
        session:request("disconnect", { terminateDebuggee = false })
      end)
      -- Kill CodeLLDB adapter process
      local adapter_pid = session.adapter and session.adapter.pid
      if adapter_pid then
        if vim.fn.has("win32") == 1 then
          vim.fn.system({ "taskkill", "/F", "/T", "/PID", tostring(adapter_pid) })
        else
          vim.fn.system({ "kill", "-9", tostring(adapter_pid) })
        end
      end
      -- Kill remote lldb-server
      local state = M._dap_session_state or {}
      if state.package_name then
        vim.fn.system({ "adb", "shell",
          "run-as " .. state.package_name .. " sh -c 'pkill -9 lldb-server 2>/dev/null'" })
      end
      -- Clear session state but persist breakpoints to disk
      M._dap_session_state = {}
      save_breakpoints()
    end,
  })

  -- Restore breakpoints from last session
  load_breakpoints()
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  vim.g.ueindex_status = vim.g.ueindex_status or ""
  vim.g.ue_build_status = vim.g.ue_build_status or ""

  vim.api.nvim_create_user_command("UEPaths", show_paths, {})
  vim.api.nvim_create_user_command("UESetProject", function(opts)
    set_project(opts.args)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("UESetAndroidPackage", function(opts)
    set_android_package(opts.args)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("UESetPlatform", function(opts)
    set_platform(opts.args)
  end, {
    nargs = "?",
    complete = function(arg_lead)
      local all = {}
      for _, p in ipairs(PLATFORM_CHOICES) do
        for _, c in ipairs(CONFIGURATION_CHOICES) do
          table.insert(all, p .. " " .. c)
        end
        table.insert(all, p)
      end
      if arg_lead == "" then
        return all
      end
      local matches = {}
      for _, item in ipairs(all) do
        if item:lower():find(arg_lead:lower(), 1, true) == 1 then
          table.insert(matches, item)
        end
      end
      return matches
    end,
  })
  vim.api.nvim_create_user_command("UEExportCompileCommands", export_compile_commands, {})
  vim.api.nvim_create_user_command("UEBuild", build_android, {})
  vim.api.nvim_create_user_command("UEBuildAndroid", build_android, {})
  vim.api.nvim_create_user_command("UEInstallAndroid", install_android, {})
  vim.api.nvim_create_user_command("UEPrepare", prepare, {})
  vim.api.nvim_create_user_command("UECheatsheet", show_cheatsheet, {})
  vim.api.nvim_create_user_command("UECheatsheetEdit", edit_cheatsheet, {})
  vim.api.nvim_create_user_command("UEClearCache", clear_cache, {})

  -- Android DAP commands
  vim.api.nvim_create_user_command("UEAndroidDAPAttach", function()
    M.android_dap_attach()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPLaunch", function()
    M.android_dap_launch()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPContinue", function()
    M.dap_continue()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPPause", function()
    M.dap_pause()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPToggleBreakpoint", function()
    M.dap_toggle_breakpoint()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPStepOver", function()
    M.dap_step_over()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPStepIn", function()
    M.dap_step_into()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPStepOut", function()
    M.dap_step_out()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPToggleUI", function()
    M.dap_toggle_ui()
  end, {})
  vim.api.nvim_create_user_command("UEAndroidDAPREPL", function()
    M.dap_toggle_repl()
  end, {})
  vim.api.nvim_create_user_command("UEDAPDiag", function()
    M.dap_diagnose()
  end, {})
  vim.api.nvim_create_user_command("UEResetLayout", function()
    M.dap_reset_layout()
  end, {})

  local group = vim.api.nvim_create_augroup("ue_statusline", { clear = true })
  -- Stop old timer on reload to prevent leaks
  if M._statusline_timer then pcall(function() M._statusline_timer:stop() end) end
  M._statusline_timer = vim.uv.new_timer()
  local statusline_timer = M._statusline_timer
  vim.api.nvim_create_autocmd("BufEnter", {
    group = group,
    callback = function()
      local bt = vim.bo.buftype
      if bt ~= "" and bt ~= "help" then
        return -- skip special buffers (terminal, nofile, prompt, dap-*)
      end
      -- Debounce: defer statusline refresh so rapid buffer switches
      -- (picker confirm, DAP UI open) don't block the event loop
      statusline_timer:stop()
      statusline_timer:start(50, 0, vim.schedule_wrap(refresh_statusline))
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.Build.cs", "*.Target.cs", "*.uproject", "*.uplugin" },
    callback = function()
      local ctx = resolve_context()
      if ctx and ctx.project_root then
        mark_index_dirty(ctx)
      end
      invalidate_status_cache()
      refresh_statusline()
    end,
  })
  vim.api.nvim_create_autocmd("DirChanged", {
    group = group,
    callback = function()
      invalidate_status_cache()
      refresh_statusline()
    end,
  })

  vim.schedule(refresh_statusline)
end

return M
