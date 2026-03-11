local M = {}

local setup_done = false

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
    return path:gsub("^/+", "")
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
  for _, line in ipairs(lines or {}) do
    local file, lnum, text = line:match("^(.-):(%d+):(.*)$")
    if file and lnum then
      file = norm(file)
      if file:sub(1, 1) ~= "/" then
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

local function populate_quickfix_from_entries(title, entries)
  if not entries or #entries == 0 then
    return false
  end

  vim.fn.setqflist({}, " ", { title = title, items = entries })
  vim.cmd("copen")
  return true
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
    local result = vim.system(cmd, { text = true, cwd = opts.cwd }):wait()
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
  local file = assert(io.open(path, "wb"))
  file:write(content)
  file:close()
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

  local dir = is_file(path) and dirname(path) or path
  while dir ~= "" do
    if is_engine_root(dir) then
      return dir
    end
    local parent = dirname(dir)
    if parent == dir then
      break
    end
    dir = parent
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

  local payload = {
    project_root = norm(project_root),
    uproject = uproject and norm(uproject) or nil,
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }

  write_all(paths.state, vim.json.encode(payload))
  return payload
end

local function resolve_context(opts)
  opts = opts or {}

  local engine_root = current_engine_root()
  if not engine_root then
    return nil, "No Unreal Engine root found from current buffer or cwd"
  end

  local state = read_state(engine_root)
  local project_root, uproject

  if state.project_root then
    project_root, uproject = resolve_project_input(state.project_root)
  end

  if not project_root and opts.detect_project ~= false then
    local candidates = { cwd() }
    local bufname = norm(vim.api.nvim_buf_get_name(0))
    if bufname ~= "" and bufname ~= candidates[1] then
      table.insert(candidates, bufname)
    end
    for _, candidate in ipairs(candidates) do
      project_root, uproject = detect_project_root_from_path(candidate)
      if project_root then
        break
      end
    end
  end

  return {
    engine_root = engine_root,
    project_root = project_root,
    uproject = uproject,
    state = state,
    paths = cache_paths(engine_root),
  }
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

local function db_ready(db_dir)
  return is_file(join(db_dir, "GTAGS")) and is_file(join(db_dir, "GRTAGS")) and is_file(join(db_dir, "GPATH"))
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
  local exe = trim((cmd or {})[1])
  if exe ~= "" and (exe:lower():match("%.exe$") or exe:lower():match("%.bat$")) then
    return "Win64"
  end
  if engine_root:match("^/mnt/[a-z]/") then
    return "Win64"
  end
  return "Linux"
end

local function target_configuration()
  local override = trim(vim.env.UE_TARGET_CONFIGURATION)
  if override ~= "" then
    return override
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

local function build_bat_windows_command(engine_root, args)
  local engine_root_win = to_windows_path(engine_root)
  if not engine_root_win then
    return nil, "Failed to convert engine root to Windows path: " .. engine_root
  end

  local build_bat_win = to_windows_path(build_bat_path(engine_root))
  if not build_bat_win then
    return nil, "Failed to convert Build.bat path to Windows path: " .. build_bat_path(engine_root)
  end

  local function cmd_token(value)
    value = tostring(value or "")
    if value:find("%s") then
      return '\\"' .. value:gsub('"', '\\"') .. '\\"'
    end
    return value
  end

  local parts = {
    "pushd " .. cmd_token(engine_root_win),
    "&&",
    "call " .. cmd_token(build_bat_win),
  }

  for _, arg in ipairs(args or {}) do
    table.insert(parts, cmd_token(arg))
  end

  local shell = first_executable({ "zsh", "bash", "sh" }) or "sh"
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

local function infer_windows_engine_root_from_compile_commands(path)
  local content = read_all(path)
  if not content or content == "" then
    return nil
  end

  local directory = content:match('"directory"%s*:%s*"([A-Za-z]:[^"]+)"')
  if directory then
    directory = directory:gsub("/", "\\")
    local lower = directory:lower()
    local index = lower:find("\\engine\\source", 1, true)
    if index then
      return directory:sub(1, index - 1)
    end
  end

  local file = content:match('"file"%s*:%s*"([A-Za-z]:[^"]+)"')
  if file then
    file = file:gsub("/", "\\")
    local lower = file:lower()
    local index = lower:find("\\engine\\", 1, true)
    if index then
      return file:sub(1, index - 1)
    end
  end

  return nil
end

local function windows_engine_root(ctx)
  local override = trim(vim.env.UE_WINDOWS_ENGINE_ROOT)
  if override ~= "" then
    return to_windows_path(override)
  end

  if ctx.project_root and ctx.project_root ~= "" then
    local inferred = infer_windows_engine_root_from_compile_commands(join(ctx.project_root, "compile_commands.json"))
    if inferred then
      return inferred
    end
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

  local engine_root_win = windows_engine_root(ctx)
  if not engine_root_win or engine_root_win == "" then
    return false, "Failed to resolve Windows engine root for compile_commands export"
  end

  local build_bat_file = build_bat_path(engine_root_win)
  if not is_windows_path(build_bat_file) and not is_file(build_bat_file) then
    return false, "Build.bat not found under engine root: " .. build_bat_file
  end

  local uproject = ctx.uproject or find_uproject_in_dir(ctx.project_root)
  if not uproject then
    return false, "No .uproject found in project root: " .. ctx.project_root
  end

  local project_arg = to_windows_path(uproject)
  if not project_arg then
    return false, "Failed to convert .uproject path to Windows path for Build.bat"
  end

  local cmd, cmd_err = build_bat_windows_command(engine_root_win, {
    "-Mode=GenerateClangDatabase",
    detect_target_name(ctx.project_root, uproject),
    target_platform(ctx.engine_root, { "Build.bat" }),
    target_configuration(),
    "-Project=" .. project_arg,
    "-Game",
    "-Engine",
  })
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

  local engine_root_win = windows_engine_root(ctx)
  if not engine_root_win or engine_root_win == "" then
    return nil, "Failed to resolve Windows engine root for build command"
  end

  local build_bat_file = build_bat_path(engine_root_win)
  if not is_windows_path(build_bat_file) and not is_file(build_bat_file) then
    return nil, "Build.bat not found under engine root: " .. build_bat_file
  end

  local uproject_win = to_windows_path(uproject)
  if not uproject_win then
    return nil, "Failed to convert UE build paths to Windows paths"
  end

  return build_bat_windows_command(engine_root_win, {
    build_target_name(ctx.project_root, uproject),
    "Android",
    "Development",
    "-Project=" .. uproject_win,
    "-WaitMutex",
    "-FromMsBuild",
  })
end

local function open_terminal_command(cmd, opts)
  opts = opts or {}
  vim.cmd(("botright %dnew"):format(opts.height or 14))
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false

  vim.fn.termopen(cmd, {
    cwd = opts.cwd,
    on_exit = function(_, code)
      vim.schedule(function()
        local level = code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        vim.notify(("UE build finished with exit code %d"):format(code), level)
      end)
    end,
  })
  vim.cmd("startinsert")
end

local function workspace_root(ctx)
  if ctx.project_root and ctx.project_root ~= "" then
    return common_ancestor({ ctx.engine_root, ctx.project_root })
  end
  return ctx.engine_root
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

  local lines = {
    "Engine: " .. ctx.engine_root,
    "Project: " .. (ctx.project_root or "<unset>"),
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
  vim.notify("UE project set:\nEngine: " .. engine_root .. "\nProject: " .. project_root)
end

local function export_compile_commands()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local ok_compile, compile_result = generate_compile_commands(ctx)
  if not ok_compile then
    vim.notify("UEExportCompileCommands failed: " .. compile_result, vim.log.levels.ERROR)
    return
  end

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

  local cmd, build_err = android_build_command(ctx)
  if not cmd then
    vim.notify("UEBuildAndroid failed: " .. build_err, vim.log.levels.ERROR)
    return
  end

  open_terminal_command(cmd, { cwd = windows_host_cwd() })
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

  local project_rel, project_err = scan_relative_files(ctx.project_root, { "Source", "Plugins" })
  if not project_rel then
    vim.notify("UEPrepare project scan failed: " .. project_err, vim.log.levels.ERROR)
    return
  end

  local engine_rel, engine_err = scan_relative_files(ctx.engine_root, { "Engine/Source", "Engine/Plugins" })
  if not engine_rel then
    vim.notify("UEPrepare engine scan failed: " .. engine_err, vim.log.levels.ERROR)
    return
  end

  local project_cpp = filter_cpp(project_rel)
  local engine_cpp = filter_cpp(engine_rel)
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
    vim.notify("UEPrepare GTAGS failed: " .. workspace_err, vim.log.levels.ERROR)
    return
  end

  local ok_compile, compile_path = generate_compile_commands(ctx)
  if not ok_compile then
    vim.notify("UEPrepare compile_commands failed: " .. compile_path, vim.log.levels.WARN)
    return
  end

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

  vim.notify("UE cache cleared under: " .. ctx.paths.cache)
end

function M.setup()
  if setup_done then
    return
  end
  setup_done = true

  vim.api.nvim_create_user_command("UEPaths", show_paths, {})
  vim.api.nvim_create_user_command("UESetProject", function(opts)
    set_project(opts.args)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("UEExportCompileCommands", export_compile_commands, {})
  vim.api.nvim_create_user_command("UEBuildAndroid", build_android, {})
  vim.api.nvim_create_user_command("UEPrepare", prepare, {})
  vim.api.nvim_create_user_command("UEClearCache", clear_cache, {})
end

return M
