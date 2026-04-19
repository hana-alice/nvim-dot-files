local M = {}

-- ==========================================================================
-- MODULE STATE
-- ==========================================================================

local CORE_RT = {
  setup_done = false,
  build_term_buf = nil,
  build_term_win = nil,
  build_term_jobid = nil,
  prepare_jobid = nil,
  status_cache = {}, -- { key = string, value = string, tick = number }
  dirty_index_roots = {},
  engine_root_cache = {}, -- dir -> engine_root (or false)
  context_cache = {}, -- key -> { ctx, ts }
}
local INDEX_FN = {}
local INDEX_RT = {
  job = nil,
  module_state = {},
  contexts = {},
  timers = {},
  idle_cold_ms = 120000,
  debounce_current_ms = 1200,
  debounce_hot_ms = 8000,
  restart_debounce_s = 45,
  last_restart_at = 0,
  status_cache = {},
  status_ttl = 30,
}
local cache_paths
local _CONTEXT_TTL = 30 -- seconds (filesystem walks are expensive on NTFS)

-- ==========================================================================
-- CORE UTILITIES — paths, files, process, ANSI
-- ==========================================================================

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

local _platform = require("utils.platform")
local function is_native_windows()
  return _platform.is_windows
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
  return norm(table.concat(vim.iter({ ... }):flatten():totable(), "/"))
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

-- ==========================================================================
-- CLANGD / LSP
-- ==========================================================================

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

  -- Windows native paths: when running nvim on Windows directly (not under
  -- WSL), `clangd` may not be on PATH (the user installs LLVM into Program
  -- Files but doesn't always add bin/ to PATH). Try the canonical install
  -- location explicitly.
  if vim.fn.has("win32") == 1 then
    table.insert(candidates, "C:/Program Files/LLVM/bin/clangd.exe")
    table.insert(candidates, "C:/Program Files (x86)/LLVM/bin/clangd.exe")
  end

  return candidates
end

-- ==========================================================================
-- OUTPUT PARSING — diagnostics, quickfix, GTAGS results
-- ==========================================================================

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

local function parse_rg_entries(lines)
  local entries = {}
  for _, line in ipairs(lines or {}) do
    local file, lnum, col, text = tostring(line or ""):match("^(.-):(%d+):(%d+):(.*)$")
    if file and lnum and col then
      entries[#entries + 1] = {
        filename = norm(file),
        lnum = tonumber(lnum),
        col = tonumber(col),
        text = text or "",
      }
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

  local target = norm(entry.filename)
  local current = norm(vim.api.nvim_buf_get_name(0))
  vim.cmd("normal! m'")
  if target ~= "" and target ~= current then
    vim.cmd("edit " .. vim.fn.fnameescape(target))
  end
  local max_line = vim.api.nvim_buf_line_count(0)
  local lnum = math.min(entry.lnum, max_line)
  local line_text = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, false)[1] or ""
  local col = math.max((entry.col or 1) - 1, 0)
  local symbol = trim(entry._symbol or "")
  if symbol ~= "" then
    local from = line_text:find("%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]")
    if from then
      col = from - 1
    end
  end
  col = math.min(col, #line_text)
  vim.api.nvim_win_set_cursor(0, { lnum, col })
  return true
end

local function populate_quickfix_from_global(title, root, lines)
  return populate_quickfix_from_entries(title, parse_global_entries(root, lines))
end

local function path_proximity_score(entry_path, current_file)
  local entry_norm = norm(entry_path):lower()

  -- Vendored/duplicate header directories that should be deprioritized
  -- when a canonical copy lives elsewhere.
  local vendored_pats = {
    "thirdparty/sdl2/.-/vulkan/",
    "thirdparty/sdl2/.-/khronos/",
    "thirdparty/sdl/.-/vulkan/",
    "thirdparty/sdl/.-/khronos/",
  }

  -- Penalise vendored duplicates
  for _, pat in ipairs(vendored_pats) do
    if entry_norm:find(pat) then
      return -30
    end
  end

  -- Reward sharing a common ThirdParty/<Lib> prefix with the current file.
  -- e.g. current = .../ThirdParty/Vulkan/... and entry = .../ThirdParty/Vulkan/...
  local cur_norm = current_file:lower()
  local cur_tp = cur_norm:match("thirdparty/([^/]+)/")
  local ent_tp = entry_norm:match("thirdparty/([^/]+)/")
  if cur_tp and ent_tp and cur_tp == ent_tp then
    return 10
  end

  -- Reward being under the same module directory (e.g. both in VulkanRHI)
  local cur_mod = cur_norm:match("/([^/]+)/private/") or cur_norm:match("/([^/]+)/public/")
  local ent_mod = entry_norm:match("/([^/]+)/private/") or entry_norm:match("/([^/]+)/public/")
  if cur_mod and ent_mod and cur_mod == ent_mod then
    return 10
  end

  return 0
end

local function jump_to_global_result(root, lines, symbol)
  local entries = parse_global_entries(root, lines)
  if #entries == 0 then
    return false
  end
  for _, entry in ipairs(entries) do
    entry._symbol = symbol
  end
  if #entries == 1 then
    return jump_to_entry(entries[1])
  end

  -- When GTAGS -d returns multiple identical definitions (e.g. vendored
  -- copies of the same header), pick the best one by path proximity
  -- instead of dumping them all into quickfix.
  local current_file = norm(vim.api.nvim_buf_get_name(0))
  for _, entry in ipairs(entries) do
    entry._prox = path_proximity_score(entry.filename, current_file)
  end
  table.sort(entries, function(a, b)
    return a._prox > b._prox
  end)
  local best = entries[1]
  local second = entries[2]
  if best._prox > (second and second._prox or -999) then
    return jump_to_entry(best)
  end

  return populate_quickfix_from_entries("GTAGS definitions", entries)
end

local function is_header_like_path(path)
  local lower = norm(path):lower()
  return lower:match("%.h$") ~= nil
    or lower:match("%.hh$") ~= nil
    or lower:match("%.hpp$") ~= nil
    or lower:match("%.hxx$") ~= nil
    or lower:match("%.inl$") ~= nil
    or lower:match("%.inc$") ~= nil
    or lower:match("%.ipp$") ~= nil
end

local function grep_definition_score(symbol, entry, current_file, current_line)
  local text = trim(entry.text or "")
  if text == "" then
    return -1
  end

  local escaped = vim.pesc(symbol)
  local token_pattern = "%f[%w_]" .. escaped .. "%f[^%w_]"
  if not text:find(token_pattern) then
    return -1
  end

  local score = 0
  if norm(entry.filename) == current_file and tonumber(entry.lnum) == tonumber(current_line) then
    score = score - 120
  end
  if is_header_like_path(entry.filename) then
    score = score + 15
  end

  -- Path proximity: penalise vendored duplicates, reward same-module headers
  score = score + path_proximity_score(entry.filename, current_file)

  if text:match("^%s*#%s*define%s+" .. escaped .. "%f[^%w_]") then
    score = score + 140
  end
  if is_header_like_path(entry.filename)
    and text:match("%f[%w_]" .. escaped .. "%f[^%w_]")
    and text:match(";%s*$")
    and not text:match("=")
    and not text:match("%(")
  then
    score = score + 150
  end
  if text:match("^%s*" .. escaped .. "%s*,") then
    score = score + 120
  end
  if text:match("^%s*" .. escaped .. "%s*=") then
    score = score - 20
  end
  if text:match("^%s*enum%s+.-" .. escaped .. "%f[^%w_]") then
    score = score + 110
  end
  if text:match("^%s*class%s+" .. escaped .. "%f[^%w_]") then
    score = score + 110
  end
  if text:match("^%s*struct%s+" .. escaped .. "%f[^%w_]") then
    score = score + 110
  end
  if text:match("^%s*typedef%s+.-" .. escaped .. "%f[^%w_]") then
    score = score + 100
  end
  if text:match("^%s*using%s+" .. escaped .. "%f[^%w_]") then
    score = score + 100
  end
  if text:match("%f[%w_]" .. escaped .. "%f[^%w_]%s*%(") and not text:match("^%s*return%s+") then
    score = score + 80
  end

  return score
end

local function copy_qf_entry(entry)
  return {
    filename = entry.filename,
    lnum = entry.lnum,
    col = entry.col,
    text = entry.text,
    _symbol = entry._symbol,
  }
end

local function jump_to_grep_candidate_entries(symbol, entries)
  if #entries == 0 then
    return false
  end

  local current_file = norm(vim.api.nvim_buf_get_name(0))
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  for _, entry in ipairs(entries) do
    entry._symbol = symbol
    entry._score = grep_definition_score(symbol, entry, current_file, current_line)
  end

  table.sort(entries, function(a, b)
    if a._score ~= b._score then
      return a._score > b._score
    end
    local a_file = norm(a.filename):lower()
    local b_file = norm(b.filename):lower()
    if a_file ~= b_file then
      return a_file < b_file
    end
    return (a.lnum or 0) < (b.lnum or 0)
  end)

  local best = entries[1]
  local second = entries[2]
  if best and best._score >= 100 and (not second or best._score > second._score) then
    return jump_to_entry(best)
  end

  local candidates = {}
  if best and best._score > 0 then
    for _, entry in ipairs(entries) do
      if entry._score == best._score then
        candidates[#candidates + 1] = copy_qf_entry(entry)
      end
    end
    if #candidates == 1 then
      return jump_to_entry(candidates[1])
    end
    return populate_quickfix_from_entries("GTAGS symbol candidates: " .. symbol, candidates)
  end

  if #entries == 1 then
    return jump_to_entry(entries[1])
  end

  for index, entry in ipairs(entries) do
    entries[index] = copy_qf_entry(entry)
  end
  return populate_quickfix_from_entries("GTAGS grep: " .. symbol, entries)
end

local function jump_to_global_grep_candidate(root, symbol, lines)
  local entries = parse_global_entries(root, lines)
  return jump_to_grep_candidate_entries(symbol, entries)
end

-- ==========================================================================
-- PUBLIC: CLANGD
-- ==========================================================================

-- Forward declaration for find_engine_root, which is defined further below
-- (line ~1152). Without this forward decl, the call inside clangd_cmd
-- (around line 771) resolves to global _G.find_engine_root (nil) and
-- raises "attempt to call global 'find_engine_root' (a nil value)" the
-- first time clangd_cmd is called with a non-nil root_dir (e.g. via
-- on_new_config). The historical reason this didn't fire in practice is
-- that LazyVim's ue.lua plugin wrapper invokes clangd_cmd() with no
-- args, which skips the offending branch. Forward-declaring keeps it
-- correct for all entry points.
local find_engine_root

function M.clangd_cmd(root_dir)
  local clangd = first_executable(clangd_candidates(root_dir or cwd())) or "clangd"

  -- Adaptive -j: clangd preambles for UE TUs cost 1.5–3 GB each. With
  -- --pch-storage=memory + N parallel workers, peak memory ~= N * 2 GB.
  -- Default budget: 1 worker per 4 GB RAM, clamped to [8, 24]. Override
  -- via UE_CLANGD_JOBS=N.
  local jobs
  local env_jobs = tonumber(vim.env.UE_CLANGD_JOBS or "")
  if env_jobs and env_jobs > 0 then
    jobs = math.floor(env_jobs)
  else
    local total_mb = 0
    local ok, mem = pcall(function()
      return vim.uv.get_total_memory and vim.uv.get_total_memory() or 0
    end)
    if ok and type(mem) == "number" and mem > 0 then
      total_mb = math.floor(mem / (1024 * 1024))
    end
    if total_mb >= 1024 then
      local total_gb = math.floor(total_mb / 1024)
      jobs = math.floor(total_gb / 4)
    else
      jobs = 8
    end
    if jobs < 8 then jobs = 8 end
    if jobs > 24 then jobs = 24 end
  end

  local cmd = {
    clangd,
    "--background-index",
    "--background-index-priority=normal",
    "-j=" .. tostring(jobs),
    "--completion-style=detailed",
    "--completion-parse=auto",          -- text-based completion while preamble builds
    "--header-insertion=never",
    "--pch-storage=memory",
    "--function-arg-placeholders",
    "--limit-results=200",
    "--limit-references=200",
    "--query-driver=**/clang*.exe,**/clang*,**/gcc,**/g++,**/cc,**/c++,**/cl.exe",
  }

  -- Point clangd to the engine root's compile_commands.json explicitly.
  -- Without this, clangd searches from the file's directory upward and may
  -- find a stale copy or miss the one we maintain at the engine root.
  if root_dir and root_dir ~= "" then
    local engine_root = find_engine_root(root_dir)
    if engine_root then
      local cc_path = join(engine_root, "compile_commands.json")
      local cc_mtime = 0
      if is_file(cc_path) then
        table.insert(cmd, "--compile-commands-dir=" .. engine_root)
        local st = vim.uv.fs_stat(cc_path)
        cc_mtime = st and st.mtime and st.mtime.sec or 0
      end
      -- Use staged offline indexes if available; active index wins.
      -- CRITICAL: only attach indexes that are AT LEAST as fresh as the
      -- compile_commands.json. A stale index references TUs that no
      -- longer exist after CDB regeneration; clangd will not clean it
      -- and gd can jump to phantom locations in deleted files.
      local idx_candidates = {
        cache_paths(engine_root).active_index,
        cache_paths(engine_root).hot_index,
        cache_paths(engine_root).current_index,
        cache_paths(engine_root).full_index,
      }
      for _, idx_path in ipairs(idx_candidates) do
        if is_file(idx_path) then
          local st = vim.uv.fs_stat(idx_path)
          local idx_mtime = st and st.mtime and st.mtime.sec or 0
          if cc_mtime == 0 or idx_mtime >= cc_mtime then
            table.insert(cmd, "--index-file=" .. idx_path)
            break
          end
        end
      end
    end
  end

  return cmd
end

-- ==========================================================================
-- FILE I/O + PROCESS
-- ==========================================================================

local function run_lines(cmd, opts)
  opts = opts or {}
  if vim.system then
    local system_opts = { text = true }
    local cwd_path = norm(trim(opts.cwd))
    if cwd_path ~= "" and is_dir(cwd_path) then
      system_opts.cwd = cwd_path
    end
    if type(opts.env) == "table" and next(opts.env) ~= nil then
      system_opts.env = vim.tbl_extend("force", vim.fn.environ(), opts.env)
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

-- run_lines_async: forward-declared inside an immediately-executed do-block to
-- avoid consuming a slot in the main-chunk's 200-local budget. The actual
-- function is assigned to a module-level upvalue table M._async so callers
-- (also inside a do-block) can reach it without polluting main-chunk locals.
M._async = M._async or {}
do
  function M._async.run_lines(cmd, opts, on_done)
    opts = opts or {}
    if not vim.system then
      local code, lines = run_lines(cmd, opts)
      vim.schedule(function() on_done(code, lines) end)
      return nil
    end

    local system_opts = { text = true }
    local cwd_path = norm(trim(opts.cwd))
    if cwd_path ~= "" and is_dir(cwd_path) then
      system_opts.cwd = cwd_path
    end
    if type(opts.env) == "table" and next(opts.env) ~= nil then
      system_opts.env = vim.tbl_extend("force", vim.fn.environ(), opts.env)
    end

    local handle = vim.system(cmd, system_opts, function(result)
      local output = (result.stdout or "") .. (result.stderr or "")
      local lines = {}
      for line in output:gmatch("[^\r\n]+") do
        table.insert(lines, line)
      end
      vim.schedule(function() on_done(result.code or 0, lines) end)
    end)
    return handle
  end
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

-- ==========================================================================
-- PROJECT DETECTION — uproject, solutions, configurations, engine root
-- ==========================================================================

local function find_uproject_in_dir(dir)
  local matches = vim.fn.globpath(dir, "*.uproject", false, true)
  if type(matches) == "table" and #matches > 0 then
    table.sort(matches)
    return norm(matches[1])
  end
  return nil
end

local UE_CONST = {
  DEFAULT_PLATFORM_CHOICES = { "Win64", "Android", "Linux", "Mac", "IOS" },
  DEFAULT_CONFIGURATION_CHOICES = {
    "Development Editor", "Development", "DebugGame Editor", "DebugGame",
    "Debug", "Shipping", "Test",
  },
  TARGET_KIND_SUFFIXES = { "Editor", "Client", "Server" },
}

local function copy_list(items)
  local copy = {}
  vim.list_extend(copy, items or {})
  return copy
end

local function push_unique(list, seen, value)
  value = trim(value)
  if value == "" or seen[value] then
    return
  end
  seen[value] = true
  table.insert(list, value)
end

local function find_solution_in_dir(dir, uproject)
  local matches = vim.fn.globpath(dir, "*.sln", false, true)
  if type(matches) ~= "table" or #matches == 0 then
    return nil
  end

  table.sort(matches)
  if uproject and uproject ~= "" then
    local preferred = join(dir, vim.fs.basename(uproject):gsub("%.uproject$", "") .. ".sln")
    for _, match in ipairs(matches) do
      match = norm(match)
      if match == preferred then
        return match
      end
    end
  end

  return norm(matches[1])
end

local function parse_solution_configurations(solution_path)
  local content = read_all(solution_path)
  if not content or content == "" then
    return nil
  end

  local platforms = {}
  local platform_seen = {}
  local configs_by_platform = {}
  local in_section = false

  for line in content:gmatch("[^\r\n]+") do
    local text = trim(line)
    if text:match("^GlobalSection%(SolutionConfigurationPlatforms%)%s*=%s*preSolution$") then
      in_section = true
    elseif in_section and text == "EndGlobalSection" then
      break
    elseif in_section then
      local left = trim(text:match("^([^=]+)=") or "")
      local configuration, platform = left:match("^(.-)|(.+)$")
      configuration = trim(configuration)
      platform = trim(platform)
      if configuration ~= "" and platform ~= "" then
        push_unique(platforms, platform_seen, platform)
        local bucket = configs_by_platform[platform]
        if not bucket then
          bucket = { order = {}, seen = {} }
          configs_by_platform[platform] = bucket
        end
        push_unique(bucket.order, bucket.seen, configuration)
      end
    end
  end

  if #platforms == 0 then
    return nil
  end

  local configurations = {}
  for platform, bucket in pairs(configs_by_platform) do
    configurations[platform] = bucket.order
  end

  return {
    path = norm(solution_path),
    platforms = platforms,
    configurations = configurations,
  }
end

local function solution_configuration_data(project_root, uproject)
  project_root = norm(project_root)
  if project_root == "" or not is_dir(project_root) then
    return nil
  end

  local solution = find_solution_in_dir(project_root, uproject)
  if not solution then
    return nil
  end

  return parse_solution_configurations(solution)
end

local function available_platform_choices(project_root, uproject)
  local solution = solution_configuration_data(project_root, uproject)
  if solution and #solution.platforms > 0 then
    return copy_list(solution.platforms)
  end
  return copy_list(UE_CONST.DEFAULT_PLATFORM_CHOICES)
end

local function available_configuration_choices(project_root, uproject, platform)
  local solution = solution_configuration_data(project_root, uproject)
  if solution then
    local platform_configs = solution.configurations[trim(platform or "")]
    if platform_configs and #platform_configs > 0 then
      return copy_list(platform_configs)
    end

    local merged = {}
    local seen = {}
    for _, candidate_platform in ipairs(solution.platforms or {}) do
      for _, configuration in ipairs(solution.configurations[candidate_platform] or {}) do
        push_unique(merged, seen, configuration)
      end
    end
    if #merged > 0 then
      return merged
    end
  end

  return copy_list(UE_CONST.DEFAULT_CONFIGURATION_CHOICES)
end

local function split_target_configuration_name(configuration)
  configuration = trim(configuration)
  for _, suffix in ipairs(UE_CONST.TARGET_KIND_SUFFIXES) do
    local base = trim(configuration:match("^(.-)%s+" .. suffix .. "$") or "")
    if base ~= "" then
      return base, suffix
    end
  end
  return configuration ~= "" and configuration or "Development", "Game"
end

local function default_target_configuration(project_root, uproject, platform)
  local choices = available_configuration_choices(project_root, uproject, platform)
  local preferred = { "Development Editor", "DebugGame Editor", "Development" }

  for _, want in ipairs(preferred) do
    for _, choice in ipairs(choices) do
      if choice == want then
        return choice
      end
    end
  end

  if #choices > 0 then
    return choices[1]
  end

  return "Development"
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

function find_engine_root(path)
  path = norm(path)
  if path == "" then
    return nil
  end

  local start_dir = is_file(path) and dirname(path) or path
  if CORE_RT.engine_root_cache[start_dir] ~= nil then
    local cached = CORE_RT.engine_root_cache[start_dir]
    return cached ~= false and cached or nil
  end

  local dir = start_dir
  local visited = {}
  while dir ~= "" do
    if CORE_RT.engine_root_cache[dir] ~= nil then
      local cached = CORE_RT.engine_root_cache[dir]
      local result = cached ~= false and cached or nil
      for _, v in ipairs(visited) do
        CORE_RT.engine_root_cache[v] = cached
      end
      return result
    end
    table.insert(visited, dir)
    if is_engine_root(dir) then
      for _, v in ipairs(visited) do
        CORE_RT.engine_root_cache[v] = dir
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
    CORE_RT.engine_root_cache[v] = false
  end
  return nil
end

local function current_engine_root(preferred_bufname)
  -- Prefer the buffer's own engine when explicitly provided. This is critical
  -- for multi-engine workflows: when cwd is in Engine A but we're resolving a
  -- buffer in Engine B, we MUST return B's engine, not A's.
  if preferred_bufname and preferred_bufname ~= "" then
    local engine_root = find_engine_root(preferred_bufname)
    if engine_root then
      return engine_root
    end
  end

  local current_cwd = cwd()
  if current_cwd ~= "" then
    local engine_root = find_engine_root(current_cwd)
    if engine_root then
      return engine_root
    end
  end

  local bufname = norm(vim.api.nvim_buf_get_name(0))
  if bufname ~= "" and bufname ~= preferred_bufname then
    return find_engine_root(bufname)
  end

  return nil
end

cache_paths = function(engine_root)
  local cache = join(engine_root, ".cache", "nvim-ue")
  local index_dir = join(cache, "index")
  local index_cdb_dir = join(index_dir, "compile_commands")
  local active_index_dir = join(engine_root, ".clangd-index")
  local project_name = vim.fn.fnamemodify(engine_root, ":t")
  return {
    cache = cache,
    state = join(cache, "state.json"),
    project_list = join(cache, "project_gtags.files"),
    engine_list = join(cache, "engine_gtags.files"),
    workspace_list = join(cache, "workspace_gtags.files"),
    workspace_all_list = join(cache, "workspace_all.files"),
    workspace_db = join(cache, "gtags", "workspace"),
    index_dir = index_dir,
    index_state = join(index_dir, "modules.json"),
    index_queue = join(index_dir, "queue.json"),
    index_cdb_dir = index_cdb_dir,
    index_current_cdb = join(index_cdb_dir, "current.json"),
    index_hot_cdb = join(index_cdb_dir, "hot.json"),
    index_full_cdb = join(index_cdb_dir, "full.json"),
    active_index_dir = active_index_dir,
    active_index = join(active_index_dir, project_name .. ".idx"),
    current_index = join(active_index_dir, project_name .. ".current.idx"),
    hot_index = join(active_index_dir, project_name .. ".hot.idx"),
    full_index = join(active_index_dir, project_name .. ".full.idx"),
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

-- ==========================================================================
-- CONTEXT RESOLUTION
-- ==========================================================================

local function resolve_context(opts)
  opts = opts or {}

  -- Cache key: cwd + bufname (covers the two inputs that vary).
  -- When an explicit bufname is passed (e.g. clangd_root(bufnr=42) for a
  -- non-current buffer), use it for both detection AND cache key so two
  -- different buffers can't share a stale entry.
  local cur_cwd = cwd()
  local explicit_buf = opts.bufname and norm(opts.bufname) or nil
  local cur_buf = explicit_buf or norm(vim.api.nvim_buf_get_name(0))
  local cache_key = cur_cwd .. "\0" .. cur_buf
  local now = vim.uv.hrtime() / 1e9
  local cached = CORE_RT.context_cache[cache_key]
  if cached and (now - cached.ts) < _CONTEXT_TTL then
    -- Stale-state guard: if state.json on disk is newer than when this
    -- ctx was built, drop the cache entry. Without this guard external
    -- writers (other nvim processes, build scripts) would be invisible
    -- for up to _CONTEXT_TTL seconds.
    if cached.ctx and cached.state_path then
      local mtime = vim.uv.fs_stat(cached.state_path)
      mtime = mtime and mtime.mtime and mtime.mtime.sec or 0
      if mtime <= (cached.state_mtime or 0) then
        return cached.ctx, cached.err
      end
    else
      return cached.ctx, cached.err
    end
  end

  local engine_root = current_engine_root(explicit_buf)
  if not engine_root then
    local err = "No Unreal Engine root found from current buffer or cwd"
    CORE_RT.context_cache[cache_key] = { ctx = nil, err = err, ts = now }
    return nil, err
  end

  local state = read_state(engine_root)
  local project_root, uproject
  local state_project_root, state_uproject
  local candidates = { cur_cwd }

  if cur_buf ~= "" and cur_buf ~= candidates[1] then
    table.insert(candidates, cur_buf)
  end

  if state.project_root then
    state_project_root, state_uproject = resolve_project_input(state.project_root)
  end

  if opts.detect_project ~= false then
    for _, candidate in ipairs(candidates) do
      project_root, uproject = detect_project_root_from_path(candidate)
      if project_root then
        break
      end
    end
  end

  if not project_root and state_project_root then
    for _, candidate in ipairs(candidates) do
      if candidate ~= "" and path_has_prefix(candidate, state_project_root) then
        project_root = state_project_root
        uproject = state_uproject
        break
      end
    end
  end

  local paths = cache_paths(engine_root)
  local state_stat = vim.uv.fs_stat(paths.state)
  local state_mtime = state_stat and state_stat.mtime and state_stat.mtime.sec or 0

  local ctx = {
    engine_root = engine_root,
    project_root = project_root,
    uproject = uproject,
    state = state,
    paths = paths,
  }
  CORE_RT.context_cache[cache_key] = {
    ctx = ctx,
    err = nil,
    ts = now,
    state_path = paths.state,
    state_mtime = state_mtime,
  }
  return ctx
end

-- ==========================================================================
-- FILE FILTERING + EXTENSION TABLES
-- ==========================================================================

local function path_has_extension(path, extensions)
  local normalized = norm(path):lower()
  for _, extension in ipairs(extensions or {}) do
    local ext = trim(extension):lower()
    if ext ~= "" and normalized:match("%." .. vim.pesc(ext) .. "$") then
      return true
    end
  end
  return false
end

local function filter_extensions(paths, extensions)
  local filtered = {}
  for _, path in ipairs(paths or {}) do
    local normalized = norm(path)
    if path_has_extension(normalized, extensions) then
      table.insert(filtered, normalized)
    end
  end
  table.sort(filtered)
  return filtered
end

local function filter_cpp(paths)
  return filter_extensions(paths, M.FT_CPP)
end

local function filter_shader(paths)
  return filter_extensions(paths, M.FT_SHADER)
end

local function filter_gtags_code(paths)
  return filter_cpp(paths)
end

local function filter_code(paths)
  return filter_extensions(paths, M.FT_CODE)
end

UE_CONST.PROJECT_INDEX_DIRS = {
  "Source",
  "Shaders",
  "Config",
  "Plugins",
  "CSharpScript",
  "Script",
  "TypeScript",
  "typescript",
}

UE_CONST.ENGINE_INDEX_DIRS = {
  "Engine/Source",
  "Engine/Plugins",
  "Engine/Shaders",
}

UE_CONST.PROJECT_SHADER_DIRS = {
  "Shaders",
  "Plugins",
}

UE_CONST.ENGINE_SHADER_DIRS = {
  "Engine/Shaders",
  "Engine/Plugins",
}

UE_CONST.GTAGS_EXCLUDE_SUBSTRINGS = {
  "Engine/Source/ThirdParty/MCPP/mcpp-2.7.2/",
}

UE_CONST.ENGINE_PICKER_DIRS = {
  "Engine/Source",
  "Engine/Plugins",
  "Engine/Shaders",
  "Engine/Config",
}

-- Simple directory names let fd (-E) and rg (-g '!') skip entire directory
-- trees instead of traversing then filtering, which is ~2x faster on Windows.
UE_CONST.PICKER_EXCLUDES = {
  ".git",
  ".vs",
  "Binaries",
  "Content",
  "DerivedDataCache",
  "Intermediate",
  "Saved",
  "ThirdParty",
}

local function picker_excludes(opts)
  local excludes = vim.deepcopy(UE_CONST.PICKER_EXCLUDES)
  if type(opts) == "table" and opts.include_third_party then
    excludes = vim.tbl_filter(function(pattern)
      return pattern ~= "ThirdParty"
    end, excludes)
  end
  return excludes
end

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

-- ==========================================================================
-- FILE SCANNING + GTAGS DATABASE
-- ==========================================================================

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
    for _, pattern in ipairs(UE_CONST.GTAGS_EXCLUDE_SUBSTRINGS) do
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

  for _, relative in ipairs(existing_relative_dirs(ctx.engine_root, UE_CONST.ENGINE_PICKER_DIRS)) do
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

local status_root_key, clear_index_dirty, mark_index_dirty, invalidate_status_cache, refresh_statusline

local INDEX_CORE_MODULES = {
  Core = true,
  CoreUObject = true,
  Engine = true,
  InputCore = true,
  Slate = true,
  SlateCore = true,
  RenderCore = true,
  RHI = true,
  Renderer = true,
  Projects = true,
  ApplicationCore = true,
  UnrealEd = true,
}

local INDEX_ALWAYS_COLD_MODULES = {
  VulkanRHI = true,
  OpenGLDrv = true,
  NullDrv = true,
}

local function unix_now()
  return os.time()
end

local function index_phase_label(phase)
  phase = trim(phase):lower()
  if phase == "current" then
    return "T0"
  elseif phase == "hot" then
    return "HOT"
  elseif phase == "full" then
    return "FULL"
  elseif phase == "idle" or phase == "" then
    return "IDLE"
  end
  return phase:upper()
end

local function module_tier_label(tier)
  tier = trim(tier):lower()
  if tier == "core" then
    return "CORE"
  elseif tier == "cold" then
    return "COLD"
  elseif tier == "warm" then
    return "WARM"
  end
  return tier ~= "" and tier:upper() or "-"
end

local function read_json_file(path, default)
  default = default or {}
  if not is_file(path) then
    return vim.deepcopy(default)
  end
  local content = read_all(path)
  if not content or content == "" then
    return vim.deepcopy(default)
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return vim.deepcopy(default)
  end
  return decoded
end

local function write_json_file(path, value)
  return write_all(path, vim.json.encode(value or {}))
end

local function module_scope_for_path(ctx, path)
  if not ctx then
    return nil
  end
  path = norm(path)
  if path == "" then
    return nil
  end
  return plugin_scope_from_root(ctx.project_root, path)
    or project_module_scope(ctx.project_root, path)
    or plugin_scope_from_root(join(ctx.engine_root, "Engine"), path)
    or engine_module_scope(ctx.engine_root, path)
end

local function module_key(scope)
  if not scope or not scope.root then
    return ""
  end
  return (scope.kind or "module") .. ":" .. norm(scope.root)
end

local function module_tier(scope)
  if not scope then
    return "warm"
  end
  local root = norm(scope.root)
  if INDEX_CORE_MODULES[scope.name or ""] then
    return "core"
  end
  if INDEX_ALWAYS_COLD_MODULES[scope.name or ""] then
    return "cold"
  end
  if root:find("/Developer/") or root:find("/Experimental/") then
    return "cold"
  end
  return "warm"
end

local function locate_engine_module_root(engine_root, name)
  if trim(name) == "" then
    return nil
  end
  local matches = vim.fn.globpath(join(engine_root, "Engine", "Source"), "*/" .. name, false, true)
  if type(matches) == "table" then
    for _, match in ipairs(matches) do
      local candidate = norm(match)
      if is_dir(candidate) then
        return candidate
      end
    end
  end
  return nil
end

local function index_state_default()
  return {
    version = 1,
    active_module = nil,
    root_dirty = false,
    modules = {},
    queue = {},
    build = {
      phase = "idle",
      status = "idle",
      started_at = 0,
      finished_at = 0,
      message = "",
      active_index = "",
    },
    stats = {
      current_runs = 0,
      hot_runs = 0,
      full_runs = 0,
    },
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
end

local function save_index_state(ctx, state)
  if not ctx or not state then
    return
  end
  state.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
  local key = status_root_key(ctx)
  INDEX_RT.module_state[key] = state
  INDEX_RT.contexts[key] = ctx
  ensure_dir(ctx.paths.index_dir)
  write_json_file(ctx.paths.index_state, state)
  write_json_file(ctx.paths.index_queue, state.queue or {})
end

local function ensure_index_state(ctx)
  local key = status_root_key(ctx)
  if key == "" then
    return index_state_default()
  end
  if INDEX_RT.module_state[key] then
    return INDEX_RT.module_state[key]
  end
  local state = read_json_file(ctx.paths.index_state, index_state_default())
  if type(state.modules) ~= "table" then
    state.modules = {}
  end
  if type(state.queue) ~= "table" then
    state.queue = {}
  end
  if state.root_dirty == nil then
    state.root_dirty = false
  end
  if type(state.build) ~= "table" then
    state.build = index_state_default().build
  end
  if type(state.stats) ~= "table" then
    state.stats = index_state_default().stats
  end
  INDEX_RT.module_state[key] = state
  return state
end

local function ensure_module_record(state, scope)
  if not state or not scope then
    return nil
  end
  local key = module_key(scope)
  if key == "" then
    return nil
  end
  local rec = state.modules[key] or {
    key = key,
    kind = scope.kind or "module",
    name = scope.name or vim.fs.basename(scope.root),
    root = norm(scope.root),
    label = scope.label or ((scope.kind == "plugin" and "Plugin " or "Module ") .. (scope.name or vim.fs.basename(scope.root))),
    tier = module_tier(scope),
    last_opened = 0,
    last_changed = 0,
    last_indexed = 0,
    dirty = false,
    dirty_reason = "",
    hot_score = 0,
  }
  rec.kind = rec.kind or scope.kind or "module"
  rec.name = rec.name or scope.name or vim.fs.basename(scope.root)
  rec.root = norm(rec.root or scope.root)
  rec.label = rec.label or scope.label or rec.name
  rec.tier = module_tier({ name = rec.name, root = rec.root, kind = rec.kind })
  state.modules[key] = rec
  return rec
end

local function seed_core_modules(ctx, state)
  for name, enabled in pairs(INDEX_CORE_MODULES) do
    if enabled then
      local root = locate_engine_module_root(ctx.engine_root, name)
      if root then
        ensure_module_record(state, {
          kind = "module",
          name = name,
          root = root,
          label = "Module " .. name,
        })
      end
    end
  end
end

local function module_record_from_path(ctx, path)
  local scope = module_scope_for_path(ctx, path)
  if not scope then
    return nil, nil
  end
  local state = ensure_index_state(ctx)
  seed_core_modules(ctx, state)
  local rec = ensure_module_record(state, scope)
  save_index_state(ctx, state)
  return rec, state
end

local function module_key_from_path(ctx, path)
  local scope = module_scope_for_path(ctx, path)
  return module_key(scope), scope
end

local function module_score(rec, state)
  if not rec then
    return -100000
  end
  local score = 0
  if rec.tier == "core" then
    score = score + 500
  elseif rec.tier == "cold" then
    score = score - 400
  end
  if state and state.active_module == rec.key then
    score = score + 1000
  end
  if rec.dirty then
    score = score + 300
  end
  local now = unix_now()
  if (tonumber(rec.last_opened) or 0) > 0 then
    local age = now - (tonumber(rec.last_opened) or 0)
    if age < 600 then
      score = score + 200
    elseif age < 3600 then
      score = score + 80
    end
  end
  if (tonumber(rec.last_changed) or 0) > 0 then
    local age = now - (tonumber(rec.last_changed) or 0)
    if age < 600 then
      score = score + 300
    elseif age < 3600 then
      score = score + 120
    end
  end
  score = score + (tonumber(rec.hot_score) or 0)
  return score
end

local function sorted_module_records(state)
  local items = {}
  for _, rec in pairs(state.modules or {}) do
    rec._score = module_score(rec, state)
    items[#items + 1] = rec
  end
  table.sort(items, function(a, b)
    if a._score == b._score then
      return (a.name or "") < (b.name or "")
    end
    return a._score > b._score
  end)
  return items
end

INDEX_FN.set_active_module = function(ctx, path)
  local rec, state = module_record_from_path(ctx, path)
  if not rec or not state then
    return nil
  end
  rec.last_opened = unix_now()
  rec.hot_score = math.min((tonumber(rec.hot_score) or 0) + 25, 1000)
  state.active_module = rec.key
  save_index_state(ctx, state)
  return rec
end

INDEX_FN.mark_module_dirty = function(ctx, path, reason)
  local rec, state = module_record_from_path(ctx, path)
  if not rec or not state then
    mark_index_dirty(ctx)
    return nil
  end
  rec.dirty = true
  rec.dirty_reason = trim(reason) ~= "" and trim(reason) or "buffer-write"
  rec.last_changed = unix_now()
  rec.hot_score = math.min((tonumber(rec.hot_score) or 0) + 50, 1000)
  mark_index_dirty(ctx)
  save_index_state(ctx, state)
  return rec
end

INDEX_FN.clear_module_dirty_flags = function(ctx, keys)
  local state = ensure_index_state(ctx)
  local changed = false
  for _, key in ipairs(keys or {}) do
    local rec = state.modules[key]
    if rec and rec.dirty then
      rec.dirty = false
      rec.dirty_reason = ""
      rec.last_indexed = unix_now()
      changed = true
    end
  end
  local has_dirty = false
  for _, rec in pairs(state.modules or {}) do
    if rec.dirty then
      has_dirty = true
      break
    end
  end
  if not has_dirty then
    clear_index_dirty(ctx)
  end
  if changed then
    save_index_state(ctx, state)
  end
end

INDEX_FN.index_phase_paths = function(ctx, phase)
  if phase == "current" then
    return ctx.paths.index_current_cdb, ctx.paths.current_index
  end
  if phase == "hot" then
    return ctx.paths.index_hot_cdb, ctx.paths.hot_index
  end
  return ctx.paths.index_full_cdb, ctx.paths.full_index
end

INDEX_FN.base_compile_commands_path = function(ctx)
  local path = join(ctx.engine_root, "compile_commands.json")
  if is_file(path) then
    return path
  end
  path = join(ctx.engine_root, "Engine", "compile_commands.json")
  if is_file(path) then
    return path
  end
  return nil
end

INDEX_FN.normalize_cdb_file = function(entry)
  if type(entry) ~= "table" then
    return ""
  end
  local file = norm(entry.file or "")
  local dir = norm(entry.directory or "")
  if file ~= "" and not is_absolute_path(file) and dir ~= "" then
    file = join(dir, file)
  end
  return norm(file)
end

INDEX_FN.select_phase_module_keys = function(ctx, state, phase)
  seed_core_modules(ctx, state)
  local selected = {}
  local seen = {}
  local ordered = sorted_module_records(state)
  local function add(key)
    if key and key ~= "" and not seen[key] and state.modules[key] then
      seen[key] = true
      selected[#selected + 1] = key
    end
  end

  for _, rec in ipairs(ordered) do
    if rec.tier == "core" then
      add(rec.key)
    end
  end

  if state.active_module then
    add(state.active_module)
  end

  if phase == "current" then
    for _, rec in ipairs(ordered) do
      if rec.dirty then
        add(rec.key)
      end
      if #selected >= 6 then
        break
      end
    end
  elseif phase == "hot" then
    for _, rec in ipairs(ordered) do
      if rec.tier ~= "cold" or rec.dirty or rec.key == state.active_module then
        add(rec.key)
      end
      if #selected >= 18 then
        break
      end
    end
  else
    for _, rec in ipairs(ordered) do
      add(rec.key)
    end
  end

  return selected
end

INDEX_FN.write_subset_compile_commands = function(ctx, phase)
  local state = ensure_index_state(ctx)
  local cdb_path = INDEX_FN.base_compile_commands_path(ctx)
  if not cdb_path then
    return nil, nil, "compile_commands.json not found"
  end
  local content = read_all(cdb_path)
  if not content or content == "" then
    return nil, nil, "compile_commands.json is empty"
  end
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return nil, nil, "Failed to parse compile_commands.json"
  end

  local selected_keys = INDEX_FN.select_phase_module_keys(ctx, state, phase)
  local selected_set = {}
  for _, key in ipairs(selected_keys) do
    selected_set[key] = true
  end

  local subset = {}
  for _, entry in ipairs(decoded) do
    local file = INDEX_FN.normalize_cdb_file(entry)
    local key = module_key_from_path(ctx, file)
    if phase == "full" then
      subset[#subset + 1] = entry
    elseif key ~= "" and selected_set[key] then
      subset[#subset + 1] = entry
    end
  end

  if #subset == 0 then
    return nil, nil, "No compile_commands entries matched selected modules"
  end

  local out_cdb = INDEX_FN.index_phase_paths(ctx, phase)
  ensure_dir(ctx.paths.index_cdb_dir)
  write_json_file(out_cdb, subset)
  return out_cdb, selected_keys, nil
end

INDEX_FN.maybe_restart_clangd_for_index = function()
  local now = unix_now()
  if (now - INDEX_RT.last_restart_at) < INDEX_RT.restart_debounce_s then
    return
  end
  INDEX_RT.last_restart_at = now
  local clients = vim.lsp.get_clients({ name = "clangd" })
  if #clients == 0 then
    return
  end
  for _, client in ipairs(clients) do
    client:stop()
  end
  vim.defer_fn(function()
    pcall(vim.cmd, "edit")
  end, 500)
end

INDEX_FN.promote_active_index = function(ctx, src_path)
  src_path = norm(src_path)
  if src_path == "" or not is_file(src_path) then
    return false
  end
  ensure_dir(ctx.paths.active_index_dir)
  local content = read_all(src_path)
  if not content or content == "" then
    return false
  end
  return write_all(ctx.paths.active_index, content)
end

INDEX_FN.build_phase_async = function(ctx, phase)
  local state = ensure_index_state(ctx)
  local root_key = status_root_key(ctx)
  if INDEX_RT.job then
    state.queue[phase] = unix_now()
    save_index_state(ctx, state)
    return false, "busy"
  end

  local subset_cdb, selected_keys, err = INDEX_FN.write_subset_compile_commands(ctx, phase)
  if not subset_cdb then
    state.build = {
      phase = phase,
      status = "error",
      started_at = unix_now(),
      finished_at = unix_now(),
      message = err,
      active_index = state.build and state.build.active_index or "",
    }
    save_index_state(ctx, state)
    invalidate_status_cache()
    refresh_statusline()
    return false, err
  end

  local python = is_native_windows() and "python" or "python3"
  local build_script = vim.fn.stdpath("config") .. "/tools/build_clangd_index.py"
  if not is_file(build_script) then
    return false, "build_clangd_index.py not found"
  end

  local _, out_idx = INDEX_FN.index_phase_paths(ctx, phase)
  if is_file(out_idx) then
    pcall(vim.fn.delete, out_idx)
  end
  local indexer = first_executable({
    "/mnt/c/Program Files/LLVM/bin/clangd-indexer.exe",
    "clangd-indexer",
    "clangd-indexer.exe",
    "C:/Program Files/LLVM/bin/clangd-indexer.exe",
  })
  local cmd = { python, build_script, subset_cdb, "--output", out_idx }
  if indexer then
    cmd[#cmd + 1] = "--indexer"
    cmd[#cmd + 1] = indexer
  end

  state.queue[phase] = nil
  state.build = {
    phase = phase,
    status = "running",
    started_at = unix_now(),
    finished_at = 0,
    message = string.format("%s modules=%d", phase, #selected_keys),
    active_index = state.build and state.build.active_index or "",
  }
  save_index_state(ctx, state)
  invalidate_status_cache()
  refresh_statusline()

  INDEX_RT.job = { root_key = root_key, phase = phase }
  vim.system(cmd, { text = true, cwd = ctx.engine_root }, function(result)
    vim.schedule(function()
      local live_state = ensure_index_state(ctx)
      INDEX_RT.job = nil
      local stderr = trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
      local ok_result = (result.code == 0) and is_file(out_idx)
      if ok_result and INDEX_FN.promote_active_index(ctx, out_idx) then
        INDEX_FN.clear_module_dirty_flags(ctx, selected_keys)
        live_state.stats[phase .. "_runs"] = (tonumber(live_state.stats[phase .. "_runs"]) or 0) + 1
        live_state.build = {
          phase = phase,
          status = "ready",
          started_at = live_state.build.started_at or unix_now(),
          finished_at = unix_now(),
          message = string.format("%s ready (%d modules)", phase, #selected_keys),
          active_index = ctx.paths.active_index,
        }
        save_index_state(ctx, live_state)
        INDEX_FN.maybe_restart_clangd_for_index()
      else
        live_state.build = {
          phase = phase,
          status = "error",
          started_at = live_state.build.started_at or unix_now(),
          finished_at = unix_now(),
          message = stderr ~= "" and stderr or (phase .. " index build failed"),
          active_index = live_state.build.active_index or "",
        }
        save_index_state(ctx, live_state)
      end
      invalidate_status_cache()
      refresh_statusline()
      INDEX_FN.try_start_queued_build()
    end)
  end)

  return true
end

INDEX_FN.try_start_queued_build = function()
  if INDEX_RT.job then
    return false
  end
  local started = false
  while not INDEX_RT.job do
    local picked_phase, picked_ctx, picked_state, picked_ts = nil, nil, nil, nil
    for _, phase_name in ipairs({ "current", "hot", "full" }) do
      for key, state in pairs(INDEX_RT.module_state or {}) do
        local queued_at = state and state.queue and state.queue[phase_name]
        local ctx = INDEX_RT.contexts[key]
        if queued_at and ctx and (picked_ts == nil or queued_at < picked_ts) then
          picked_phase = phase_name
          picked_ctx = ctx
          picked_state = state
          picked_ts = queued_at
        end
      end
      if picked_phase then
        break
      end
    end
    if not picked_phase or not picked_ctx or not picked_state then
      break
    end
    local ok_started = INDEX_FN.build_phase_async(picked_ctx, picked_phase)
    if ok_started then
      started = true
      break
    end
    picked_state.queue[picked_phase] = nil
    save_index_state(picked_ctx, picked_state)
  end
  return started
end

INDEX_FN.schedule_index_phase = function(ctx, phase, delay_ms)
  if not ctx then
    return
  end
  local state = ensure_index_state(ctx)
  state.queue[phase] = unix_now()
  save_index_state(ctx, state)
  local timer_key = status_root_key(ctx) .. "::" .. phase
  if INDEX_RT.timers[timer_key] then
    INDEX_RT.timers[timer_key]:stop()
    INDEX_RT.timers[timer_key]:close()
    INDEX_RT.timers[timer_key] = nil
  end
  local timer = vim.uv.new_timer()
  INDEX_RT.timers[timer_key] = timer
  timer:start(delay_ms, 0, vim.schedule_wrap(function()
    if INDEX_RT.timers[timer_key] then
      INDEX_RT.timers[timer_key]:stop()
      INDEX_RT.timers[timer_key]:close()
      INDEX_RT.timers[timer_key] = nil
    end
    INDEX_FN.build_phase_async(ctx, phase)
  end))
end

INDEX_FN.schedule_index_refresh = function(ctx, opts)
  opts = opts or {}
  if not ctx or not INDEX_FN.base_compile_commands_path(ctx) then
    return
  end
  if opts.current ~= false then
    INDEX_FN.schedule_index_phase(ctx, "current", opts.current_delay_ms or INDEX_RT.debounce_current_ms)
  end
  if opts.hot then
    INDEX_FN.schedule_index_phase(ctx, "hot", opts.hot_delay_ms or INDEX_RT.debounce_hot_ms)
  end
  if opts.full then
    INDEX_FN.schedule_index_phase(ctx, "full", opts.full_delay_ms or INDEX_RT.idle_cold_ms)
  end
end

INDEX_FN.index_status_summary = function(ctx)
  local state = ensure_index_state(ctx)
  local dirty = 0
  local total = 0
  local tier_counts = { core = 0, warm = 0, cold = 0 }
  for _, rec in pairs(state.modules or {}) do
    total = total + 1
    local tier = rec.tier or "warm"
    if tier_counts[tier] ~= nil then
      tier_counts[tier] = tier_counts[tier] + 1
    end
    if rec.dirty then
      dirty = dirty + 1
    end
  end
  local active_name = "-"
  local active_tier = "-"
  local active_kind = "-"
  if state.active_module and state.modules[state.active_module] then
    local active = state.modules[state.active_module]
    active_name = active.name or active_name
    active_tier = module_tier_label(active.tier)
    active_kind = active.kind or active_kind
  end
  local queued = {}
  for _, phase_name in ipairs({ "current", "hot", "full" }) do
    if state.queue and state.queue[phase_name] then
      queued[#queued + 1] = index_phase_label(phase_name)
    end
  end
  local phase = state.build and state.build.phase or "idle"
  return {
    active = active_name,
    active_tier = active_tier,
    active_kind = active_kind,
    dirty = dirty,
    total = total,
    core = tier_counts.core,
    warm = tier_counts.warm,
    cold = tier_counts.cold,
    queued = queued,
    queue_count = #queued,
    root_dirty = (state.root_dirty or false) or (CORE_RT.dirty_index_roots[status_root_key(ctx)] and true or false),
    phase = phase,
    phase_label = index_phase_label(phase),
    status = state.build and state.build.status or "idle",
    message = state.build and state.build.message or "",
    active_index = state.build and state.build.active_index or "",
    active_index_name = trim(vim.fs.basename(state.build and state.build.active_index or "")),
  }
end

local function index_output_paths(ctx)
  local outputs = {}
  local compile_commands = join(ctx.engine_root, "compile_commands.json")
  if compile_commands ~= "" then
    table.insert(outputs, compile_commands)
  end
  if ctx.paths and ctx.paths.active_index then
    table.insert(outputs, ctx.paths.active_index)
  end
  for _, name in ipairs({ "GTAGS", "GRTAGS", "GPATH" }) do
    table.insert(outputs, join(ctx.paths.workspace_db, name))
  end
  return outputs
end

status_root_key = function(ctx)
  if not ctx then
    return ""
  end
  return table.concat({
    norm(ctx.engine_root),
    norm(ctx.project_root),
  }, "\31")
end

clear_index_dirty = function(ctx)
  local key = status_root_key(ctx)
  if key ~= "" then
    CORE_RT.dirty_index_roots[key] = nil
    local state = ensure_index_state(ctx)
    state.root_dirty = false
    save_index_state(ctx, state)
  end
end

mark_index_dirty = function(ctx)
  local key = status_root_key(ctx)
  if key ~= "" then
    CORE_RT.dirty_index_roots[key] = true
    local state = ensure_index_state(ctx)
    state.root_dirty = true
    save_index_state(ctx, state)
  end
end

local function mode_token(ctx)
  if ctx and ctx.project_root and ctx.project_root ~= "" then
    return "PROJECT"
  end
  return "ENGINE"
end

local function count_cached_entries(path)
  if not is_file(path) then
    return 0
  end
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok or type(lines) ~= "table" then
    return 0
  end
  return #lines
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

local function prepare_cache_ready(ctx)
  if not ctx then
    return false
  end
  for _, path in ipairs({
    ctx.paths.project_list,
    ctx.paths.engine_list,
    ctx.paths.workspace_list,
    ctx.paths.workspace_all_list,
  }) do
    if not is_file(path) then
      return false
    end
  end
  if not db_ready(ctx.paths.workspace_db) then
    return false
  end
  local key = status_root_key(ctx)
  return key ~= "" and not CORE_RT.dirty_index_roots[key]
end

local function prepare_summary(ctx, compile_path, opts)
  opts = opts or {}
  local project_count = opts.project_count or count_cached_entries(ctx.paths.project_list)
  local engine_count = opts.engine_count or count_cached_entries(ctx.paths.engine_list)
  local workspace_count = opts.workspace_count or count_cached_entries(ctx.paths.workspace_list)
  local workspace_all_count = opts.workspace_all_count or count_cached_entries(ctx.paths.workspace_all_list)

  local summary = ("UEPrepare done:\nProject files: %d\nEngine files: %d\nGTAGS files: %d\nGrep files: %d")
    :format(project_count, engine_count, workspace_count, workspace_all_count)
  summary = summary .. "\nMode: " .. (mode_token(ctx) == "PROJECT" and "project" or "engine-only")
  if opts.reused_cache then
    summary = summary .. "\nIndex cache: reused"
  end
  if compile_path and compile_path ~= "" then
    summary = summary .. "\ncompile_commands: " .. compile_path
  end
  summary = summary .. "\nCache: " .. ctx.paths.cache
  return summary
end

local function index_status_token(ctx)
  if not ctx then
    return "UE?"
  end

  local key = status_root_key(ctx)
  local now = vim.uv.hrtime() / 1e9
  local summary = INDEX_FN.index_status_summary(ctx)
  local cached = INDEX_RT.status_cache[key]
  if cached and (now - cached.ts) < INDEX_RT.status_ttl then
    if summary.status == "running" then
      return cached.token
    end
    if summary.root_dirty then
      return summary.dirty > 0 and string.format("IDX!%d", summary.dirty) or "IDX!R"
    end
    return cached.token
  end

  local token
  if summary.status == "running" then
    token = "IDX:" .. summary.phase_label .. "*"
  elseif summary.root_dirty then
    token = summary.dirty > 0 and string.format("IDX!%d", summary.dirty) or "IDX!R"
  else
    local outputs = index_output_paths(ctx)
    for _, path in ipairs(outputs) do
      if file_mtime(path) <= 0 then
        token = "IDX?"
        break
      end
    end
    if not token and not db_ready(ctx.paths.workspace_db) then
      token = "IDX?"
    end
    if not token then
      if summary.active ~= "-" then
        token = "IDX:" .. summary.phase_label .. "/" .. summary.active
      else
        token = "IDX:" .. summary.phase_label
      end
    end
  end
  INDEX_RT.status_cache[key] = { token = token, ts = now }
  return token
end

local function short_scope_token(scope)
  if not scope or not scope.name then
    return "UE"
  end
  return (scope.kind == "plugin" and "P:" or "M:") .. scope.name
end

invalidate_status_cache = function()
  CORE_RT.status_cache = {}
  CORE_RT.context_cache = {}
  CORE_RT.engine_root_cache = {}
  INDEX_RT.status_cache = {}
end

refresh_statusline = function()
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

local function set_prepare_running(value)
  value = not not value
  if M._prepare_running == value then
    return
  end
  M._prepare_running = value
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

-- Async version: calls cb(lines, err) on vim.schedule when done.
local function scan_relative_files_async(root, search_paths, cb)
  local fd = first_executable({ "fd", "fdfind" })
  if not fd then
    vim.schedule(function() cb(nil, "fd/fdfind not found in PATH") end)
    return
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
    vim.schedule(function() cb({}, nil) end)
    return
  end

  local system_opts = { text = true, cwd = root }
  vim.system(cmd, system_opts, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        local output = (result.stdout or "") .. (result.stderr or "")
        cb(nil, output)
        return
      end
      local output = result.stdout or ""
      local lines = {}
      for line in output:gmatch("[^\r\n]+") do
        lines[#lines + 1] = line
      end
      cb(lines, nil)
    end)
  end)
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
  local cmd = { "global" }
  vim.list_extend(cmd, args)

  if vim.system then
    return run_lines(cmd, {
      cwd = root,
      env = {
        GTAGSROOT = root,
        GTAGSDBPATH = db_dir,
      },
    })
  end

  local prev_root = vim.env.GTAGSROOT
  local prev_db = vim.env.GTAGSDBPATH
  vim.env.GTAGSROOT = root
  vim.env.GTAGSDBPATH = db_dir
  local ok, code, lines = pcall(run_lines, cmd, { cwd = root })
  vim.env.GTAGSROOT = prev_root
  vim.env.GTAGSDBPATH = prev_db
  if not ok then
    error(code)
  end
  return code, lines
end

local function rg_code_definition_search(ctx, symbol)
  symbol = trim(symbol)
  if not ctx or symbol == "" then
    return false
  end

  local rg = first_executable({ "rg" })
  if not rg then
    return false
  end

  local dirs = {}
  local seen = {}
  local function add_dir(dir)
    dir = norm(dir)
    if dir ~= "" and is_dir(dir) and not seen[dir] then
      seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end

  if ctx.project_root and ctx.project_root ~= "" then
    for _, relative in ipairs(existing_relative_dirs(ctx.project_root, UE_CONST.PROJECT_INDEX_DIRS)) do
      add_dir(join(ctx.project_root, relative))
    end
  end
  for _, relative in ipairs(existing_relative_dirs(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS)) do
    add_dir(join(ctx.engine_root, relative))
  end

  if #dirs == 0 then
    return false
  end

  local cmd = {
    rg,
    "--color", "never",
    "--no-heading",
    "--line-number",
    "--column",
    "--fixed-strings",
    "--with-filename",
  }
  for _, ext in ipairs(M.FT_CPP) do
    cmd[#cmd + 1] = "-g"
    cmd[#cmd + 1] = "*." .. ext
  end
  cmd[#cmd + 1] = "--"
  cmd[#cmd + 1] = symbol
  vim.list_extend(cmd, dirs)

  local cwd = ctx.engine_root
  if ctx.project_root and ctx.project_root ~= "" then
    local root = common_ancestor({ ctx.engine_root, ctx.project_root })
    if root ~= "" then
      cwd = root
    end
  end
  local code, lines = run_lines(cmd, { cwd = cwd })
  if code ~= 0 and code ~= 1 then
    return false
  end

  return jump_to_grep_candidate_entries(symbol, parse_rg_entries(lines))
end

-- ==========================================================================
-- BUILD TARGETS + PLATFORM DETECTION
-- ==========================================================================

local function detect_target_names(project_root, uproject)
  local targets = vim.fn.globpath(join(project_root, "Source"), "*.Target.cs", false, true)
  local detected = {
    Editor = nil,
    Client = nil,
    Server = nil,
    Game = nil,
  }

  for _, target in ipairs(targets or {}) do
    local name = vim.fs.basename(target):gsub("%.Target%.cs$", "")
    local matched = false
    for _, kind in ipairs(UE_CONST.TARGET_KIND_SUFFIXES) do
      if name:match(kind .. "$") then
        detected[kind] = detected[kind] or name
        matched = true
        break
      end
    end
    if not matched then
      detected.Game = detected.Game or name
    end
  end

  local fallback = vim.fs.basename(uproject):gsub("%.uproject$", "")
  detected.Game = detected.Game or fallback
  return detected
end

local function detect_target_name(project_root, uproject, kind)
  local detected = detect_target_names(project_root, uproject)
  local fallback = vim.fs.basename(uproject):gsub("%.uproject$", "")
  kind = trim(kind or "")

  if kind == "Editor" then
    return detected.Editor or detected.Game or detected.Client or detected.Server or fallback
  end
  if kind == "Client" then
    return detected.Client or detected.Game or detected.Editor or detected.Server or fallback
  end
  if kind == "Server" then
    return detected.Server or detected.Game or detected.Editor or detected.Client or fallback
  end
  if kind == "Game" then
    return detected.Game or detected.Editor or detected.Client or detected.Server or fallback
  end

  return detected.Editor or detected.Game or detected.Client or detected.Server or fallback
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

local function selected_target_configuration(engine_root, project_root, uproject, platform)
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
  return default_target_configuration(project_root, uproject, platform)
end

local function target_configuration(engine_root, project_root, uproject, platform)
  local configuration = selected_target_configuration(engine_root, project_root, uproject, platform)
  local normalized = split_target_configuration_name(configuration)
  return normalized
end

local function target_kind(engine_root, project_root, uproject, platform)
  local configuration = selected_target_configuration(engine_root, project_root, uproject, platform)
  local _, kind = split_target_configuration_name(configuration)
  return kind
end

local function build_target_name(project_root, uproject, kind)
  local override = trim(vim.env.UE_BUILD_TARGET)
  if override ~= "" then
    return override
  end
  return detect_target_name(project_root, uproject, kind)
end

-- ==========================================================================
-- BUILD COMMANDS — Windows wrappers, UBT, Build.bat
-- ==========================================================================

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
    return (path:gsub("/", "\\"))
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

-- ==========================================================================
-- COMPILE_COMMANDS.JSON GENERATION
-- ==========================================================================

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

-- ==========================================================================
-- SHADER DEFINITION SEARCH + COMPILE COMMANDS AUGMENTATION
-- ==========================================================================

local function scan_shader_files(root, search_paths)
  root = norm(root)
  if root == "" then
    return {}
  end

  local files = {}
  local seen = {}
  for _, search_path in ipairs(existing_relative_dirs(root, search_paths)) do
    for _, extension in ipairs(M.FT_SHADER) do
      for _, pattern in ipairs({
        join(root, search_path, "*." .. extension),
        join(root, search_path, "**", "*." .. extension),
      }) do
        for _, absolute in ipairs(glob_paths(pattern)) do
          local normalized = norm(absolute)
          local key = normalized:lower()
          if is_file(normalized) and not seen[key] then
            seen[key] = true
            table.insert(files, normalized)
          end
        end
      end
    end
  end
  table.sort(files)
  return files
end

local function shader_search_dirs(ctx)
  local dirs = {}
  local seen = {}

  local function add(path)
    path = norm(path)
    local key = path:lower()
    if path ~= "" and is_dir(path) and not seen[key] then
      seen[key] = true
      table.insert(dirs, path)
    end
  end

  if ctx.project_root and ctx.project_root ~= "" then
    for _, relative in ipairs(UE_CONST.PROJECT_SHADER_DIRS) do
      add(join(ctx.project_root, relative))
    end
  end
  for _, relative in ipairs(UE_CONST.ENGINE_SHADER_DIRS) do
    add(join(ctx.engine_root, relative))
  end

  return dirs
end

local function shader_definition_entry(file, lnum, line, symbol)
  line = tostring(line or "")
  local trimmed = trim(line)
  if trimmed == "" or trimmed:match("^//") or trimmed:match("^#") then
    return nil
  end

  local start_col, end_col = trimmed:find(symbol, 1, true)
  if not start_col or not trimmed:sub(end_col + 1):match("^%s*%(") then
    return nil
  end

  local before = trimmed:sub(1, start_col - 1)
  if before:match("^%s*$") then
    return nil
  end
  if before:find("=", 1, true) or before:find(",", 1, true) or before:find("%(") then
    return nil
  end
  if before:match("%f[%a]return%f[%A]")
    or before:match("%f[%a]if%f[%A]")
    or before:match("%f[%a]for%f[%A]")
    or before:match("%f[%a]while%f[%A]")
    or before:match("%f[%a]switch%f[%A]") then
    return nil
  end

  before = trim(before)
  if before == "" then
    return nil
  end
  for token in before:gmatch("%S+") do
    if not token:match("^[%a_][%w_<>%[%],:%*&]*$") then
      return nil
    end
  end

  return {
    filename = file,
    lnum = lnum,
    col = math.max((line:find(symbol, 1, true) or 1), 1),
    text = trimmed,
  }
end

local function collect_shader_definition_entries(entries, seen, file, lines, symbol)
  for lnum, line in ipairs(lines or {}) do
    local entry = shader_definition_entry(file, lnum, line, symbol)
    if entry then
      add_quickfix_entry(entries, seen, entry)
    end
  end
end

local function rg_shader_definition_entries(dirs, symbol, seen_files)
  local rg = first_executable({ "rg" })
  if not rg or #dirs == 0 then
    return nil
  end

  local cmd = {
    rg,
    "--line-number",
    "--with-filename",
    "--no-heading",
    "--color",
    "never",
    "--no-ignore",
    "--max-count",
    "200",
  }

  for _, extension in ipairs(M.FT_SHADER) do
    table.insert(cmd, "-g")
    table.insert(cmd, "*." .. extension)
  end

  table.insert(cmd, [[\b]] .. symbol .. [[\s*\(]])
  vim.list_extend(cmd, dirs)

  local code, lines = run_lines(cmd)
  if code ~= 0 and code ~= 1 then
    return nil
  end

  local entries = {}
  local seen_entries = {}
  for _, line in ipairs(lines or {}) do
    local file, lnum, text = tostring(line):match("^(.-):(%d+):(.*)$")
    if file and lnum then
      file = norm(file)
      if not is_absolute_path(file) then
        file = norm(file)
      end
      local key = file:lower()
      if not (seen_files and seen_files[key]) then
        local entry = shader_definition_entry(file, tonumber(lnum), text, symbol)
        if entry then
          add_quickfix_entry(entries, seen_entries, entry)
        end
      end
    end
  end

  return entries
end

local function shader_definition_search(ctx, symbol)
  local current = norm(vim.api.nvim_buf_get_name(0))
  if current == "" or not path_has_extension(current, M.FT_SHADER) then
    return false
  end

  local function finalize(entries)
    if #entries == 0 then
      return false
    end
    if #entries == 1 then
      return jump_to_entry(entries[1])
    end
    return populate_quickfix_from_entries("Shader definitions: " .. symbol, entries)
  end

  local entries = {}
  local seen_entries = {}
  collect_shader_definition_entries(entries, seen_entries, current, vim.api.nvim_buf_get_lines(0, 0, -1, false), symbol)
  if #entries > 0 then
    return finalize(entries)
  end

  local current_dir = dirname(current)
  local seen_files = { [current:lower()] = true }
  local same_dir_entries = rg_shader_definition_entries({ current_dir }, symbol, seen_files) or {}
  if #same_dir_entries > 0 then
    return finalize(same_dir_entries)
  end

  local rest_entries = rg_shader_definition_entries(shader_search_dirs(ctx), symbol, seen_files) or {}
  return finalize(rest_entries)
end

local function shader_include_roots(shader_files)
  local roots = {}
  local seen = {}
  for _, path in ipairs(shader_files or {}) do
    local root = norm(path):match("^(.-/Shaders)/")
    if root and not seen[root] then
      seen[root] = true
      table.insert(roots, root)
    end
  end
  table.sort(roots)
  return roots
end

local function compile_commands_program(entry)
  if type(entry) == "table" and type(entry.arguments) == "table" and entry.arguments[1] then
    return trim(entry.arguments[1])
  end

  local command = type(entry) == "table" and trim(entry.command) or ""
  if command ~= "" then
    if command:sub(1, 1) == '"' then
      return command:match('^"([^"]+)"') or command:match("^(%S+)")
    end
    return command:match("^(%S+)")
  end

  return first_executable({ "clang++", "clang", "clang++.exe", "clang.exe", "cl.exe", "cl" }) or "clang++"
end

local function compile_commands_template_entry(entries)
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and type(entry.arguments) == "table" and entry.arguments[1] and entry.file then
      return entry
    end
  end
  for _, entry in ipairs(entries or {}) do
    if type(entry) == "table" and entry.file then
      return entry
    end
  end
  return {}
end

local function make_shader_compile_command_entry(shader_file, template, include_roots)
  local arguments = {
    compile_commands_program(template),
    "-x",
    "c++-header",
    "-fsyntax-only",
    "-Wno-pragma-once-outside-header",
  }
  for _, root in ipairs(include_roots or {}) do
    table.insert(arguments, "-I")
    table.insert(arguments, root)
  end
  table.insert(arguments, shader_file)

  return {
    directory = trim(template.directory or dirname(shader_file)),
    file = shader_file,
    arguments = arguments,
  }
end

local function augment_compile_commands_with_shaders(ctx, content)
  local ok, decoded = pcall(vim.json.decode, content)
  if not ok or type(decoded) ~= "table" then
    return content
  end

  local shader_files = {}
  if ctx.project_root and ctx.project_root ~= "" then
    vim.list_extend(shader_files, scan_shader_files(ctx.project_root, UE_CONST.PROJECT_INDEX_DIRS))
  end
  vim.list_extend(shader_files, scan_shader_files(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS))
  if #shader_files == 0 then
    return content
  end

  local include_roots = shader_include_roots(shader_files)
  local template = compile_commands_template_entry(decoded)
  local existing = {}
  for _, entry in ipairs(decoded) do
    if type(entry) == "table" and entry.file then
      existing[norm(entry.file):lower()] = true
    end
  end

  local added = false
  for _, shader_file in ipairs(shader_files) do
    local key = shader_file:lower()
    if not existing[key] then
      table.insert(decoded, make_shader_compile_command_entry(shader_file, template, include_roots))
      existing[key] = true
      added = true
    end
  end

  if not added then
    return content
  end

  return vim.json.encode(decoded)
end

-- ---------------------------------------------------------------------------
-- RSP-based compile_commands.json generation
-- ---------------------------------------------------------------------------

local generate_compile_commands_from_rsp
do

--- Tokenize a single line: split on unquoted whitespace, strip quotes.
local function tokenize_rsp_single_line(line)
  local tokens = {}
  local i = 1
  local len = #line
  while i <= len do
    local ch = line:sub(i, i)
    if ch == " " or ch == "\t" then
      i = i + 1
    else
      local buf = {}
      while i <= len do
        ch = line:sub(i, i)
        if ch == " " or ch == "\t" then
          break
        elseif ch == '"' then
          local j = line:find('"', i + 1, true)
          if j then
            buf[#buf + 1] = line:sub(i + 1, j - 1)
            i = j + 1
          else
            buf[#buf + 1] = line:sub(i + 1)
            i = len + 1
          end
        else
          local j = line:find('[" \t]', i)
          if j then
            buf[#buf + 1] = line:sub(i, j - 1)
            i = j
          else
            buf[#buf + 1] = line:sub(i)
            i = len + 1
          end
        end
      end
      if #buf > 0 then
        tokens[#tokens + 1] = table.concat(buf)
      end
    end
  end
  return tokens
end

--- Tokenize an entire rsp file content (multi-line, handles \r\n).
--- Also expands @"file" nested rsp references recursively.
--- base_dir is the directory for resolving relative @ references
--- (typically Engine/Source, since UBT runs from there).
local function tokenize_rsp_content(content, base_dir, depth)
  depth = depth or 0
  if depth > 5 then return {} end -- prevent infinite recursion
  local tokens = {}
  -- Split on \r\n or \n
  for line in content:gmatch("[^\r\n]+") do
    line = trim(line)
    if line ~= "" then
      local line_tokens = tokenize_rsp_single_line(line)
      for _, tok in ipairs(line_tokens) do
        -- Expand @"path" or @path nested rsp references
        local ref = tok:match("^@\"(.+)\"$") or tok:match("^@(.+)$")
        if ref then
          local ref_path
          if ref:match("^[A-Za-z]:") or ref:match("^/") then
            ref_path = ref
          else
            ref_path = join(base_dir, ref)
          end
          ref_path = norm(ref_path)
          local nested = read_all(ref_path)
          if nested then
            -- Keep the same base_dir for nested refs (all relative to UBT CWD)
            local nested_tokens = tokenize_rsp_content(nested, base_dir, depth + 1)
            for _, nt in ipairs(nested_tokens) do
              tokens[#tokens + 1] = nt
            end
          end
        else
          tokens[#tokens + 1] = tok
        end
      end
    end
  end
  return tokens
end

--- MSVC-style flag skip/conversion table.
--- Returns: "skip" (drop this token), "skip2" (drop this + next),
---          converted string, or nil (keep as-is).
local function convert_msvc_flag(tok, next_tok)
  -- Output file flags: skip
  if tok:match("^/Fo") or tok:match("^/Fp") or tok:match("^/Fd")
      or tok:match("^/Fe") then
    return "skip"
  end
  -- PCH usage: skip (/Yu, /Yc)
  if tok:match("^/Yu") or tok:match("^/Yc") then
    return "skip"
  end
  -- Linker-only flags: skip
  if tok:match("^/MANIFEST") or tok:match("^/NOLOGO") or tok:match("^/DEBUG")
      or tok:match("^/MACHINE") or tok:match("^/SUBSYSTEM") or tok:match("^/OUT:")
      or tok:match("^/PDB:") or tok:match("^/IGNORE:") or tok:match("^/NODEFAULTLIB")
      or tok:match("^/DEF") or tok:match("^/NAME:") or tok:match("^/errorReport")
      or tok:match("^/INCREMENTAL") or tok:match("^/OPT:") or tok:match("^/ENTRY:")
      or tok:match("^/IMPLIB:") or tok:match("^/MAP:") then
    return "skip"
  end
  -- Experimental log / source dependencies: skip
  if tok == "/experimental:log" then
    return "skip2"
  end
  if tok:match("^/sourceDependencies") then
    return "skip2"
  end
  -- /c (compile only) — clang++ uses -c but compile_commands entries don't need it
  if tok == "/c" or tok == "/nologo" then
    return "skip"
  end
  -- /I "path" → -I "path" (may be /I"path" or /I path)
  local ipath = tok:match("^/I\"(.+)\"$") or tok:match("^/I(.+)$")
  if ipath and ipath ~= "" then
    return "-I" .. ipath
  end
  if tok == "/I" then
    return "-I"
  end
  -- /external:I "path" → -isystem path
  local extpath = tok:match("^/external:I\"(.+)\"$") or tok:match("^/external:I(.+)$")
  if extpath and extpath ~= "" then
    return "-isystem" .. extpath
  end
  if tok == "/external:I" then
    return "-isystem"
  end
  -- /external:W0 — suppress external warnings — map to nothing meaningful for clang
  if tok:match("^/external:W") then
    return "skip"
  end
  -- /D → -D
  local dval = tok:match("^/D(.+)$")
  if dval then
    return "-D" .. dval
  end
  -- /FI"path" → -include path  (forced include)
  local fipath = tok:match("^/FI\"(.+)\"$") or tok:match("^/FI(.+)$")
  if fipath and fipath ~= "" then
    return "-include", fipath
  end
  -- /std:c++XX → -std=c++XX
  local std = tok:match("^/std:(.+)$")
  if std then
    return "-std=" .. std
  end
  -- /TP → -x c++, /TC → -x c
  if tok == "/TP" then
    return "-xc++"
  end
  if tok == "/TC" then
    return "-xc"
  end
  -- MSVC-only flags that clang should ignore: skip
  if tok:match("^/GR") or tok:match("^/Gw") or tok:match("^/Gy") or tok:match("^/Gs")
      or tok:match("^/guard:") or tok:match("^/Zp") or tok:match("^/Zo")
      or tok:match("^/Z7") or tok:match("^/Zi") or tok:match("^/ZI")
      or tok:match("^/FC$") or tok:match("^/bigobj$") or tok:match("^/fp:")
      or tok:match("^/Ob") or tok:match("^/O1") or tok:match("^/O2") or tok:match("^/Ox")
      or tok:match("^/Oi") or tok:match("^/MD") or tok:match("^/MT")
      or tok:match("^/diagnostics:") or tok:match("^/utf%-8$")
      or tok:match("^/we%d") or tok:match("^/wd%d") or tok:match("^/W%d")
      or tok:match("^/EH") or tok:match("^/RTC")
      or tok:match("^/Zc:")
      or tok:match("^/d2") or tok == "/Ot" or tok == "/GF" then
    return "skip"
  end
  -- /permissive- → -fpermissive (approximate)
  if tok == "/permissive-" then
    return "skip"
  end
  -- Pass-through clang-style flags unchanged
  return nil
end

--- Parse rsp tokens into clang-compatible args + source file.
--- Handles both MSVC (/I /D /FI /Fo) and clang (-o -I -D) styles.
local function parse_rsp_tokens(tokens)
  local args = {}
  local input_file = nil
  local i = 1
  while i <= #tokens do
    local tok = tokens[i]
    local next_tok = tokens[i + 1]

    -- Clang-style skips
    if tok == "-o" then
      i = i + 2
      goto continue
    elseif tok == "-MD" then
      i = i + 1
      goto continue
    elseif tok:match("^%-MF") then
      if tok == "-MF" then i = i + 2 else i = i + 1 end
      goto continue
    elseif tok == "-include-pch" then
      i = i + 2
      goto continue
    end

    -- MSVC conversion
    if tok:match("^/") then
      local result, extra = convert_msvc_flag(tok, next_tok)
      if result == "skip" then
        i = i + 1
        goto continue
      elseif result == "skip2" then
        i = i + 2
        goto continue
      elseif result then
        args[#args + 1] = result
        if extra then
          args[#args + 1] = extra
        end
        i = i + 1
        goto continue
      end
    end

    args[#args + 1] = tok
    i = i + 1
    ::continue::
  end

  -- Find input file: last non-flag token
  for j = #args, 1, -1 do
    local a = args[j]
    if not a:match("^%-") and (a:match("%.cpp$") or a:match("%.c$") or a:match("%.cc$") or a:match("%.cxx$")) then
      input_file = a
      table.remove(args, j)
      break
    end
  end

  return args, input_file
end

local function extract_unity_includes(unity_file, engine_source_dir)
  local content = read_all(unity_file)
  if not content then
    return nil
  end
  local includes = {}
  for inc_path in content:gmatch('#include%s+"([^"]+%.cpp)"') do
    local abs
    if inc_path:match("^[A-Za-z]:") or inc_path:match("^/") then
      abs = norm(inc_path)
    else
      abs = norm(join(engine_source_dir, inc_path))
      if not is_file(abs) then
        abs = norm(join(dirname(unity_file), inc_path))
      end
    end
    if is_file(abs) then
      includes[#includes + 1] = abs
    end
  end
  if #includes > 0 then
    return includes
  end
  return nil
end

local function collect_rsp_files(ctx)
  local fd = first_executable({ "fd", "fdfind" })
  if not fd then
    return nil, "fd/fdfind not found in PATH"
  end

  local search_roots = {}
  local engine_build = join(ctx.engine_root, "Engine", "Intermediate", "Build")
  if is_dir(engine_build) then
    search_roots[#search_roots + 1] = engine_build
  end
  if ctx.project_root and ctx.project_root ~= "" then
    local project_build = join(ctx.project_root, "Intermediate", "Build")
    if is_dir(project_build) then
      search_roots[#search_roots + 1] = project_build
    end
  end

  if #search_roots == 0 then
    return nil, "No Intermediate/Build directories found"
  end

  -- Only collect compile rsp files (Module.*.cpp.obj.rsp), skip link/lib/def rsp
  local cmd = { fd, "--no-ignore", "--type", "f", "-e", "rsp", "--glob", "*.cpp.obj.rsp" }
  for _, root in ipairs(search_roots) do
    cmd[#cmd + 1] = "--search-path"
    cmd[#cmd + 1] = root
  end

  local code, lines = run_lines(cmd, { cwd = ctx.engine_root })
  if code ~= 0 or not lines or #lines == 0 then
    return nil, "No .rsp files found"
  end

  -- Determine target filter from configuration.
  -- "Development Editor" → target=UnrealEditor, config=Development
  -- "Development" → target=UnrealGame, config=Development
  local target_filter = nil
  local config_filter = nil
  local config = ctx.state and trim(ctx.state.target_configuration or "") or ""
  if config ~= "" then
    if config:match(" Editor$") then
      target_filter = "UnrealEditor"
      config_filter = config:gsub(" Editor$", "")
    else
      target_filter = "UnrealGame"
      config_filter = config
    end
  end

  local rsp_files = {}
  for _, line in ipairs(lines) do
    local p = norm(trim(line))
    if p ~= "" then
      -- If target/config filter is set, only include matching paths.
      -- Path pattern: .../Build/Win64/x64/{TargetName}/{Configuration}/{Module}/...
      local dominated = true
      if target_filter then
        -- Check if path contains /{target_filter}/{config_filter}/
        local has_target = p:find("/" .. target_filter .. "/", 1, true)
        local has_config = config_filter and p:find("/" .. config_filter .. "/", 1, true)
        if not has_target or (config_filter and not has_config) then
          dominated = false
        end
      end
      if dominated then
        rsp_files[#rsp_files + 1] = p
      end
    end
  end

  if #rsp_files == 0 then
    -- Fallback: if filter was too strict, return all compile rsp files
    for _, line in ipairs(lines) do
      local p = norm(trim(line))
      if p ~= "" then
        rsp_files[#rsp_files + 1] = p
      end
    end
  end

  return rsp_files, nil
end

generate_compile_commands_from_rsp = function(ctx)
  local rsp_files, err = collect_rsp_files(ctx)
  if not rsp_files then
    return nil, err
  end

  local engine_source_dir = join(ctx.engine_root, "Engine", "Source")
  -- UBT runs with Engine/Source as CWD, so all relative paths in rsp files
  -- (../Intermediate/Build/..., Runtime/Core/Public, etc.) are relative to it.
  local compile_dir = engine_source_dir
  local entries = {}
  local seen_files = {}

  for _, rsp_path in ipairs(rsp_files) do
    local content = read_all(rsp_path)
    if content then
      content = trim(content)
      if content ~= "" then
        local tokens = tokenize_rsp_content(content, engine_source_dir)
        local args, input_file = parse_rsp_tokens(tokens)

        if input_file and input_file ~= "" then
          -- Resolve relative paths against Engine/Source (UBT's working dir)
          if not input_file:match("^[A-Za-z]:") and not input_file:match("^/") then
            input_file = norm(join(engine_source_dir, input_file))
          else
            input_file = norm(input_file)
          end

          table.insert(args, 1, "clang++")
          table.insert(args, "-D__INTELLISENSE__")

          local unity_includes = extract_unity_includes(input_file, engine_source_dir)
          if unity_includes then
            for _, real_file in ipairs(unity_includes) do
              local key = real_file:lower()
              if not seen_files[key] then
                seen_files[key] = true
                local entry_args = vim.list_extend({}, args)
                entry_args[#entry_args + 1] = real_file
                entries[#entries + 1] = {
                  directory = compile_dir,
                  file = real_file,
                  arguments = entry_args,
                }
              end
            end
          else
            local key = input_file:lower()
            if not seen_files[key] then
              seen_files[key] = true
              local entry_args = vim.list_extend({}, args)
              entry_args[#entry_args + 1] = input_file
              entries[#entries + 1] = {
                directory = compile_dir,
                file = input_file,
                arguments = entry_args,
              }
            end
          end
        end
      end
    end
  end

  if #entries == 0 then
    return nil, "No compile entries generated from .rsp files"
  end

  local json_content = vim.json.encode(entries)
  json_content = augment_compile_commands_with_shaders(ctx, json_content)

  local targets = compile_commands_targets(ctx)
  local preferred = targets[1]
  for _, target in ipairs(targets) do
    write_all(target, json_content)
  end

  return #entries, preferred
end

end -- do block

local function slim_compile_commands_file(path)
  -- Use external Python script to avoid 200MB JSON decode inside Neovim
  local script = vim.fn.stdpath("config") .. "/tools/slim_compile_commands.py"
  if not is_file(script) then
    vim.notify("slim_compile_commands.py not found: " .. script, vim.log.levels.WARN)
    return false
  end
  local python = (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and "python" or "python3"
  -- --keep-engine: preserve Engine C++ entries for goto-definition
  -- strips shaders, Intermediate, uetemp, NDK only
  local cmd = { python, script, path, "--keep-engine" }
  local result = vim.fn.system(cmd)
  if vim.v.shell_error == 0 then
    -- New script outputs "保留: N | 剔除: M (...%)"
    local removed = result:match("剔除: (%d+)")
    if removed and tonumber(removed) > 0 then
      vim.notify(result, vim.log.levels.INFO)
    end
  else
    vim.notify("slim_compile_commands failed: " .. (result or ""), vim.log.levels.WARN)
    return false
  end
  return true
end

--- Run PCH prebuild + include-dir unification in background after slim.
--- @param path string the compile_commands.json file to process
--- @param targets string[]|nil list of compile_commands targets; after pipeline
---        finishes the first target is copied to the others and clangd restarts.
local function run_compile_commands_pipeline(path, targets)
  local python = (vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1) and "python" or "python3"
  local pch_script = vim.fn.stdpath("config") .. "/tools/prebuild_pch_v2.py"
  local resolve_script = vim.fn.stdpath("config") .. "/tools/resolve_cdb_paths.py"
  local unify_script = vim.fn.stdpath("config") .. "/tools/unify_include_dirs.py"
  local prune_script = vim.fn.stdpath("config") .. "/tools/prune_include_dirs.py"
  local has_pch = is_file(pch_script)
  local has_resolve = is_file(resolve_script)
  local has_unify = is_file(unify_script)
  local has_prune = is_file(prune_script)

  if not has_pch and not has_unify and not has_prune then return end

  vim.notify("compile_commands pipeline: pch+resolve+unify+prune in background...", vim.log.levels.INFO)

  -- Record mtime before pipeline to detect actual changes
  local stat_before = vim.uv.fs_stat(path)
  local mtime_before = stat_before and stat_before.mtime.sec or 0

  -- Detect engine-only project for unify
  local path_lower = path:gsub("\\", "/"):lower()
  local is_engine_only = path_lower:find("/engine/") and true or false

  local cmds = {}
  if has_pch then
    table.insert(cmds, python .. ' "' .. pch_script .. '" "' .. path .. '"')
  end
  if has_resolve then
    -- Resolve relative -I paths to absolute AFTER PCH (PCH RSP uses absolute paths;
    -- CDB must match or clang cannot reuse PCH cache, causing 5-400x slower preamble)
    table.insert(cmds, python .. ' "' .. resolve_script .. '" "' .. path .. '"')
  end
  if has_unify then
    local extra = is_engine_only and " --include-engine" or ""
    table.insert(cmds, python .. ' "' .. unify_script .. '" "' .. path .. '" --max-overhead=200' .. extra)
  end
  if has_prune then
    -- Use python -I to isolate from PYTHONPATH pollution; sample 20 files per PCH group
    table.insert(cmds, python .. ' -I "' .. prune_script .. '" "' .. path .. '" --sample 20')
  end

  local shell_cmd = table.concat(cmds, " && ")
  vim.fn.jobstart(shell_cmd, {
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          vim.notify("compile_commands pipeline failed (exit " .. code .. ")", vim.log.levels.WARN)
          return
        end
        -- Check if CDB was actually modified
        local stat_after = vim.uv.fs_stat(path)
        local mtime_after = stat_after and stat_after.mtime.sec or 0
        if mtime_after == mtime_before then
          vim.notify("compile_commands pipeline: no changes, skipping clangd restart", vim.log.levels.INFO)
          return
        end
        -- Sync primary target to secondary targets
        if targets and #targets > 1 then
          for i = 2, #targets do
            local dst = targets[i]
            local cp_cmd
            if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
              cp_cmd = { "cmd", "/c", "copy", "/y", path:gsub("/", "\\"), dst:gsub("/", "\\") }
            else
              cp_cmd = { "cp", path, dst }
            end
            vim.fn.system(cp_cmd)
          end
        end
        vim.notify("compile_commands pipeline: done. Restarting clangd...", vim.log.levels.INFO)
        -- Auto-restart clangd to pick up the changes
        local clients = vim.lsp.get_clients({ name = "clangd" })
        for _, client in ipairs(clients) do
          local bufs = vim.lsp.get_buffers_by_client_id(client.id)
          client:stop()
          vim.defer_fn(function()
            for _, buf in ipairs(bufs) do
              if vim.api.nvim_buf_is_valid(buf) then
                vim.api.nvim_buf_call(buf, function()
                  vim.cmd("LspStart clangd")
                end)
                break
              end
            end
          end, 500)
        end
      end)
    end,
  })
end

local function write_compile_commands_targets(ctx, content)
  if not content or content == "" then
    return false, "compile_commands.json was empty"
  end

  content = augment_compile_commands_with_shaders(ctx, content)

  -- Slim: strip .generated.h / .init.gen.c / gen.cpp entries to speed up clangd indexing
  local ok_decode, decoded = pcall(vim.json.decode, content)
  if ok_decode and type(decoded) == "table" then
    local original_count = #decoded
    local kept = {}
    for _, entry in ipairs(decoded) do
      local f = (entry.file or ""):gsub("\\", "/")
      if not f:match("%.generated%.") and not f:match("%.init%.gen%.") and not f:match("gen%.cpp$") then
        kept[#kept + 1] = entry
      end
    end
    if #kept < original_count then
      vim.notify(
        ("compile_commands: %d → %d entries (-%d generated)"):format(original_count, #kept, original_count - #kept),
        vim.log.levels.INFO
      )
      content = vim.json.encode(kept)
    end
  end

  local preferred = compile_commands_targets(ctx)[1]
  for _, target in ipairs(compile_commands_targets(ctx)) do
    write_all(target, content)
    slim_compile_commands_file(target)
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
  -- Prefer UBT-generated compile_commands.json if it already exists at a target path.
  -- The UBT file is more complete (15k+ entries with full module resolution)
  -- vs RSP-based generation which may miss entries or have subtly wrong paths.
  local targets = compile_commands_targets(ctx)
  for _, target in ipairs(targets) do
    if is_file(target) and vim.fn.getfsize(target) > 1024 then
      slim_compile_commands_file(target)
      run_compile_commands_pipeline(target, targets)
      return true, target .. " (UBT, existing)"
    end
  end

  -- Try other candidate locations (Engine/Intermediate/Build/, project root, fd search)
  local ok_existing, existing_path = export_compile_commands_to_engine_root(ctx)
  if ok_existing then
    run_compile_commands_pipeline(targets[1], targets)
    return true, existing_path .. " (UBT)"
  end

  -- Fallback: generate from .rsp files (works without running GenerateClangDatabase)
  local rsp_count, rsp_path = generate_compile_commands_from_rsp(ctx)
  if rsp_count then
    run_compile_commands_pipeline(targets[1], targets)
    return true, rsp_path .. " (" .. rsp_count .. " entries from .rsp files)"
  end

  if not ctx.project_root or ctx.project_root == "" then
    return false,
      "No engine compile_commands source found. Need existing compile_commands.json, engine .rsp files, or a project via :UESetProject [path]"
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
  local plat
  local conf
  local kind
  if is_windows_path(ctx.engine_root) then
    local engine_root_win = windows_engine_root(ctx)
    if not engine_root_win or engine_root_win == "" then
      return false, "Failed to resolve Windows engine root for compile_commands export"
    end

    local build_bat_file = build_bat_path(engine_root_win)
    if not is_windows_path(build_bat_file) and not is_file(build_bat_file) then
      return false, "Build.bat not found under engine root: " .. build_bat_file
    end

    plat = target_platform(ctx.engine_root, { "Build.bat" })
    conf = target_configuration(ctx.engine_root, ctx.project_root, uproject, plat)
    kind = target_kind(ctx.engine_root, ctx.project_root, uproject, plat)
    cmd, cmd_err = build_bat_windows_command(engine_root_win, {
      "-Mode=GenerateClangDatabase",
      detect_target_name(ctx.project_root, uproject, kind),
      plat,
      conf,
      "-Project=" .. project_arg,
      "-Game",
      "-Engine",
    })
  else
    plat = target_platform(ctx.engine_root, { ubt_exe_path(ctx.engine_root) })
    conf = target_configuration(ctx.engine_root, ctx.project_root, uproject, plat)
    kind = target_kind(ctx.engine_root, ctx.project_root, uproject, plat)
    cmd, cmd_err = direct_ubt_command(ctx.engine_root, {
      "-Mode=GenerateClangDatabase",
      detect_target_name(ctx.project_root, uproject, kind),
      plat,
      conf,
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

  local ok_gen, gen_path = export_compile_commands_to_engine_root(ctx)
  if ok_gen then
    run_compile_commands_pipeline(targets[1], targets)
  end
  return ok_gen, gen_path
end

-- ==========================================================================
-- ANDROID BUILD
-- ==========================================================================

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
  local conf = target_configuration(ctx.engine_root, ctx.project_root, uproject, plat)
  local kind = target_kind(ctx.engine_root, ctx.project_root, uproject, plat)

  local build_args = {
    build_target_name(ctx.project_root, uproject, kind),
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

-- ==========================================================================
-- TERMINAL COMMAND RUNNER
-- ==========================================================================

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
    if CORE_RT.build_term_win and not vim.api.nvim_win_is_valid(CORE_RT.build_term_win) then
      CORE_RT.build_term_win = nil
    end
    if CORE_RT.build_term_buf and not vim.api.nvim_buf_is_valid(CORE_RT.build_term_buf) then
      CORE_RT.build_term_buf = nil
    end
  end

  local function track_state(buf, win)
    CORE_RT.build_term_buf = buf
    CORE_RT.build_term_win = win

    vim.api.nvim_create_autocmd("BufWipeout", {
      buffer = buf,
      once = true,
      callback = function(args)
        if CORE_RT.build_term_buf == args.buf then
          CORE_RT.build_term_buf = nil
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
      once = true,
      pattern = tostring(win),
      callback = function()
        if CORE_RT.build_term_win == win then
          CORE_RT.build_term_win = nil
        end
      end,
    })
  end

  local function job_running()
    if not CORE_RT.build_term_jobid then
      return false
    end
    local ok, result = pcall(vim.fn.jobwait, { CORE_RT.build_term_jobid }, 0)
    return ok and result and result[1] == -1
  end

  local function ensure_window()
    prune_state()

    if CORE_RT.build_term_win and focus_window(CORE_RT.build_term_win) then
      return CORE_RT.build_term_win
    end

    local height = opts.height or math.max(8, math.floor(vim.o.lines * 0.25))
    vim.cmd(("botright %dnew"):format(height))
    CORE_RT.build_term_win = vim.api.nvim_get_current_win()
    return CORE_RT.build_term_win
  end

  if job_running() then
    local running_win = ensure_window()
    if CORE_RT.build_term_buf and vim.api.nvim_buf_is_valid(CORE_RT.build_term_buf) then
      vim.api.nvim_win_set_buf(running_win, CORE_RT.build_term_buf)
    end
    startinsert_in_window(running_win)
    vim.notify("UE build is already running", vim.log.levels.WARN)
    return
  end

  local win = ensure_window()
  local previous_buf = CORE_RT.build_term_buf
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
        if CORE_RT.build_term_jobid == active_jobid then
          CORE_RT.build_term_jobid = nil
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
    CORE_RT.build_term_jobid = nil
    if opts.quickfix_title then
      set_build_status("BERR")
    end
    vim.notify("Failed to start UE build terminal", vim.log.levels.ERROR)
    return
  end

  CORE_RT.build_term_jobid = active_jobid
  startinsert_in_window(win)
end

-- ==========================================================================
-- PICKER INTEGRATION — workspace, cached files/grep
-- ==========================================================================

local function workspace_root(ctx)
  if ctx.project_root and ctx.project_root ~= "" then
    local root = common_ancestor({ ctx.engine_root, ctx.project_root })
    if root ~= "" then
      return root
    end
    -- No common ancestor (e.g. different drives on Windows).
    -- Fall back to engine_root because the GTAGS DB and most source
    -- files live under the engine tree.
    return ctx.engine_root
  end
  return ctx.engine_root
end

local function cached_file_list_info(opts, list_type)
  local ctx, err = resolve_context(opts)
  if not ctx then
    return nil, err
  end

  local list_path = list_type == "code" and ctx.paths.workspace_list or ctx.paths.workspace_all_list
  if list_type == "all" and not is_file(list_path) and is_file(ctx.paths.workspace_list) then
    -- Older caches may not have workspace_all.files yet. Fall back to the
    -- code-only list so picker startup stays fast until :UEPrepare refreshes.
    list_path = ctx.paths.workspace_list
  end
  if not is_file(list_path) then
    return nil, "No cached file list (run :UEPrepare first)"
  end

  return {
    list_path = list_path,
    root = workspace_root(ctx),
  }
end

local function read_cached_paths(list_path, root)
  local lines = vim.fn.readfile(list_path)
  if #lines == 0 then
    return nil, "Cached file list is empty"
  end

  local files = {}
  for _, line in ipairs(lines) do
    line = trim(line)
    if line ~= "" then
      if is_absolute_path(line) then
        files[#files + 1] = line
      else
        files[#files + 1] = join(root, line)
      end
    end
  end

  if #files == 0 then
    return nil, "Cached file list is empty"
  end

  return files
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
    exclude = picker_excludes(opts),
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
    exclude = picker_excludes(opts),
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
    exclude = picker_excludes(opts),
    follow = true,
  }, scope, nil
end

-- Read cached file list for fast grep (avoids NTFS directory traversal).
-- Returns { files = {abs_path, ...}, root = workspace_root } or nil.
function M.cached_grep_file_list(opts)
  local info, err = cached_file_list_info(opts, "all")
  if not info then
    return nil, err
  end

  local files, read_err = read_cached_paths(info.list_path, info.root)
  if not files then
    return nil, read_err
  end

  return { files = files, root = info.root, list_path = info.list_path }
end

-- Read cached code-only file list for files picker.
-- Returns { files = {abs_path, ...}, root = workspace_root } or nil.
function M.cached_code_file_list(opts)
  local info, err = cached_file_list_info(opts, "code")
  if not info then
    return nil, err
  end

  local files, read_err = read_cached_paths(info.list_path, info.root)
  if not files then
    return nil, read_err
  end

  return { files = files, root = info.root, list_path = info.list_path }
end

-- Files picker using cached file list (avoids fd traversal and streams results into Snacks).
-- list_type: "all" (default) or "code"
function M.cached_files(opts)
  opts = opts or {}
  local list_type = opts.list_type or "all"
  local info = cached_file_list_info(opts, list_type == "code" and "code" or "all")
  if not info then
    return nil
  end

  local rg = first_executable({ "rg" })
  if not rg then
    return nil
  end

  local snacks = require("snacks")
  local ok, proc = pcall(require, "snacks.picker.source.proc")
  if not ok then
    return nil
  end

  snacks.picker.pick({
    title = opts.title or "Find Files (cached)",
    source = "files",
    format = "file",
    layout = opts.layout,
    finder = function(_, ctx)
      return proc.proc(
        ctx:opts({
          notify = false,
          cmd = rg,
          args = { "--no-messages", "--color", "never", "--line-buffered", "--no-filename", "^", info.list_path },
          transform = function(item)
            local text = trim(item.text)
            if text == "" then
              return false
            end
            item.text = text
            item.file = text
            if is_absolute_path(text) then
              item.cwd = nil
            else
              item.cwd = info.root
            end
            return item
          end,
        }),
        ctx
      )
    end,
  })

  return true
end

-- Batched grep using cached file list.
-- Spawns rg with file paths as positional args instead of searching directories,
-- avoiding NTFS directory traversal (~20x faster on Windows).
--
-- WHEN A CSEARCH INDEX EXISTS (built by :UEPrepare via cindex-uefilter),
-- the picker uses a sub-second trigram-indexed grep instead. On a 100k-file
-- UE workspace, csearch returns FRDGBuilder (5k hits) in ~700ms vs ~14s
-- for the rg-batched path. See lua/utils/code_search/ for backend details.
function M.cached_grep(opts)
  opts = opts or {}
  local ctx = resolve_context(opts)
  if not ctx then
    return nil
  end

  local snacks = require("snacks")
  local code_search = require("utils.code_search")
  local cs_ctx = { workspace_root = workspace_root(ctx) }
  local has_index = code_search.is_indexed(cs_ctx)
  local backend_label = has_index and "csearch" or "rg"

  local title_default = ("Grep All Code [%s]"):format(backend_label)

  -- ─ Helpers shared by both csearch and rg paths ──────────────────────
  -- Dev toggle: lets us A/B compare against vanilla snacks behavior to
  -- isolate whether grouping/format/preview/throttle changes are the cause
  -- of perceived lag. When false, finder cb is unwrapped, format/preview/
  -- throttle are not installed, and Tab keeps snacks default behavior.
  -- Toggle at runtime with :UEGrepGroupingToggle.
  local grouping_enabled = (vim.g.ue_grep_grouping_enabled ~= false)

  -- Wrap a `cb(item)` so that whenever a new file appears in the stream
  -- (compared to the previous item), we first emit a header item for that
  -- file. csearch outputs in file-grouped order; rg --with-filename does
  -- too — so this gives a cheap "tree-like" grouping without buffering.
  -- The header item carries _is_grep_header=true so the format function
  -- and confirm hook can treat it specially.
  --
  -- DESIGN NOTE
  -- This is intentionally NOT a real recursive directory tree. Doing that
  -- would require buffering all matches, sorting by path, and emitting
  -- intermediate dir nodes — losing the live-streaming UX. The two-level
  -- grouping (file header + indented hit lines) covers ~90% of the value
  -- ("which files contain this") at a fraction of the complexity.
  local function make_grouping_cb(cb)
    local last_file = nil
    return function(item)
      -- Drop nil items defensively — snacks finder.add() does
      -- `item.idx, item.score = ...` and crashes on nil. We've seen this
      -- crop up rarely from upstream proc.proc transforms returning nil.
      if item == nil then return end
      if item.file and item.file ~= last_file then
        last_file = item.file
        cb({
          text = item.file,
          file = item.file,
          pos  = { 1, 0 },
          _is_grep_header = true,
        })
      end
      cb(item)
    end
  end

  -- Hoist snacks default formatter once (require cache is fast but per-item
  -- lookup adds up across thousands of redraws on every Tab press).
  local snacks_format_file = require("snacks.picker.format").file

  -- Format: file headers get a bold prefix + path; hit lines get a thin
  -- left margin so they visually nest under the preceding header.
  local function format_grouped(item, picker)
    if item._is_grep_header then
      return {
        { "▼ ", "SnacksPickerDir" },
        { tostring(item.file or item.text or "?"), "SnacksPickerFile" },
      }
    end
    -- Default grep format, but indented two spaces.
    local default = snacks_format_file(item, picker)
    table.insert(default, 1, { "  ", "SnacksPickerDir" })
    return default
  end

  -- Preview: header items have no useful preview (file line 1 is rarely
  -- where you want to start). Show a placeholder instead — this avoids the
  -- per-Tab cost of opening a fresh buffer + treesitter highlighting just
  -- to flash a line-1 view that the user is going to scroll past.
  local function preview_grouped(ctx)
    local item = ctx.item
    if item and item._is_grep_header then
      ctx.preview:reset()
      ctx.preview:set_lines({
        "── " .. (item.file or "?") .. " ──",
        "",
        "  (file header — press <CR> to open at line 1)",
      })
      ctx.preview:set_title(vim.fn.fnamemodify(item.file or "", ":t"))
      return
    end
    -- Default file preview for hit items.
    return require("snacks.picker.preview").file(ctx)
  end

  -- Per-picker keymap override:
  -- snacks default <Tab> = select_and_next (multi-select), which on huge
  -- grep result lists costs a full list redraw + selected-set highlight
  -- recompute on EVERY press — feels laggy when the user is just scanning
  -- with key-repeat. Override <Tab> to plain list_down here. Multi-select
  -- still available via <S-Tab> / <C-Space> (which we leave alone).
  local fast_tab_keys = {
    win = {
      input = { keys = { ["<Tab>"] = { "list_down", mode = { "i", "n" } } } },
      list  = { keys = { ["<Tab>"] = "list_down" } },
    },
  }

  -- Preview throttle: snacks default is 60ms which is faster than typical
  -- Tab key-repeat (30-50ms), so each Tab still fires a fresh preview build.
  -- For UE-scale files (.cpp 500KB+, 50-200ms TS highlight), this stacks up
  -- and feels laggy. Bump to 200ms — preview renders only after the user
  -- pauses scrolling.
  local function on_show_picker(picker)
    pcall(function()
      local snacks_util = require("snacks.util")
      local ref = picker:ref()
      picker._throttled_preview = snacks_util.throttle(function()
        local this = ref()
        if this then this:_show_preview() end
      end, { ms = 200, name = "preview" })
    end)
  end

  -- Confirm: header → jump to file line 1; hit → snacks default jump.
  -- snacks `confirm` callback signature is (picker, item, action) where
  -- action is the keymap entry (e.g. { cmd = "edit" }). When forwarding
  -- to snacks's own jump action we MUST pass it (or a sane default) —
  -- jump() does `action.cmd` at line 89 and crashes on nil.
  local function confirm_grouped(picker, item, action)
    if item and item._is_grep_header then
      picker:close()
      vim.schedule(function()
        vim.cmd("edit " .. vim.fn.fnameescape(item.file))
      end)
      return
    end
    return require("snacks.picker.actions").jump(picker, item, action or { cmd = "edit" })
  end

  -- ── csearch fast path ────────────────────────────────────────────────
  if has_index then
    snacks.picker.pick({
      source = "ue_grep_csearch",
      title = opts.title or title_default,
      search = opts.search or "",
      live = true,
      need_search = true,
      layout = { preset = "telescope" },
      format = grouping_enabled and format_grouped or nil,
      preview = grouping_enabled and preview_grouped or nil,
      on_show = grouping_enabled and on_show_picker or nil,
      win = grouping_enabled and fast_tab_keys.win or nil,
      confirm = grouping_enabled and confirm_grouped or nil,
      finder = function(_picker_opts, finder_ctx)
        local pattern = finder_ctx.filter.search
        if not pattern or pattern == "" then
          return function() end
        end
        return function(cb)
          -- Wrap cb to inject file-header items between file groups.
          if grouping_enabled then
            cb = make_grouping_cb(cb)
          end

          -- snacks finder protocol: this function MUST block until ALL
          -- callbacks have been emitted, otherwise snacks marks the finder
          -- "done" and any later cb call trips its "yielded after done"
          -- bug-trap. We start csearch in the background, queue items
          -- through a buffer, and use ctx.async:sleep() to yield to the
          -- picker until the csearch process reports done OR the picker
          -- aborts us (sleep returns early on abort).
          local done = false
          local pending = {}  -- items waiting to be drained on the main loop
          local stop = code_search.stream(cs_ctx, pattern, {
            code_only   = opts.code_only,
            smart_case  = true,
            max_count   = opts.max_count or 5000,
          }, {
            on_line = function(file, lnum, col, text)
              -- Buffer the item; we drain inside the sleep loop below
              -- where it's safe to call cb (we're guaranteed not yet done).
              pending[#pending + 1] = {
                text = file .. ":" .. lnum .. ":" .. col .. ":" .. text,
                pos  = { lnum, math.max(0, col - 1) },
                file = file,
              }
            end,
            on_done = function(code, err)
              done = true
              if err and code ~= 0 then
                vim.schedule(function()
                  vim.notify("UE grep [csearch]: " .. err, vim.log.levels.WARN, { title = "UE" })
                end)
              end
            end,
          })

          -- Drain loop: sleep in short slices so we can flush pending
          -- items frequently AND react to picker aborts (filter.search
          -- changing under us). Small slice (5ms) lets us notice aborts
          -- fast — when the user is typing, each keystroke aborts the
          -- prior finder, and a 30ms slice meant 30ms of dead csearch
          -- output kept landing in the picker. Per-tick cb count is also
          -- capped so we never hand snacks more than CB_BUDGET items in
          -- one frame (large bursts → snacks rebuilds list+highlight per
          -- batch and can stall the main loop for tens of ms).
          -- Tunables: smaller slice = faster abort response; smaller
          -- budget = lower per-tick stall on snacks redraw. Sweet spot
          -- found empirically at 2ms / 80 — abort after typing a key is
          -- ~imperceptible, and large result bursts (Render*, FName etc.)
          -- spread across ~10 frames at 16ms each instead of stalling
          -- one frame for 100ms+.
          local drain_slice_ms = 2
          local CB_BUDGET = 80  -- items per drain tick
          local max_total_ms = 30000  -- absolute upper bound, ~30s
          local elapsed = 0
          local read_idx = 1
          while not done and elapsed < max_total_ms do
            -- Abort detection: if the picker filter changed, snacks will
            -- abort our async task; ctx.async:sleep returns early. We
            -- check the running flag via filter identity. Kill the
            -- subprocess IMMEDIATELY (before break) so it stops producing
            -- items in the brief window before our outer cleanup runs —
            -- otherwise on slow grep workloads the dead csearch keeps
            -- writing stdout for tens of ms while we're already gone.
            if finder_ctx.filter.search ~= pattern then
              pcall(stop)
              break
            end
            -- Drain up to CB_BUDGET items accumulated since last slice.
            -- Use read_idx (not #pending) so we don't churn the array on
            -- every tick — set entries to nil so GC can reclaim text.
            local n = #pending
            if read_idx <= n then
              local stop_at = math.min(n, read_idx + CB_BUDGET - 1)
              for i = read_idx, stop_at do
                cb(pending[i])
                pending[i] = nil
              end
              read_idx = stop_at + 1
            end
            finder_ctx.async:sleep(drain_slice_ms)
            elapsed = elapsed + drain_slice_ms
          end

          -- Detect WHY we exited the loop. If the user aborted us
          -- (filter changed), we MUST NOT call cb anymore — snacks has
          -- marked our finder done and any further cb trips the
          -- "yielded after done" bug-trap. Just kill the subprocess and
          -- discard any pending items.
          local aborted = (finder_ctx.filter.search ~= pattern)

          if not aborted then
            -- Final drain after done (still safe — we haven't returned).
            -- Resume from read_idx so we don't double-cb earlier items.
            for i = read_idx, #pending do
              cb(pending[i])
            end
          end

          -- Stop the subprocess if it's still alive (timeout / abort path).
          if not done then
            stop()
          end
        end
      end,
    })
    return true
  end

  -- ── rg-batched fallback (v2): cached file list + per-batch rg ────────
  -- Used when no csearch index exists yet (UEPrepare hasn't been run, or
  -- cindex-uefilter isn't installed). This path is the legacy ~14-30s
  -- behavior on UE workspaces. To get sub-second grep, run :UEPrepare.

  local info = cached_file_list_info(opts, "all")
  if not info then
    -- No cached file list and no csearch index; let snacks fall back to
    -- its default grep over the directory tree (slowest path).
    return nil
  end

  local rg = first_executable({ "rg" })
  if not rg then
    return nil
  end

  local ok, proc = pcall(require, "snacks.picker.source.proc")
  if not ok then
    return nil
  end

  local files
  local files_ready = false
  local function ensure_files()
    if not files_ready then
      files = read_cached_paths(info.list_path, info.root) or false
      files_ready = true
    end
    return files ~= false and files or nil
  end

  local batch_size = 200
  local uv = vim.uv or vim.loop
  local spawn_arg_limit = uv and uv.os_uname().sysname == "Windows_NT" and 28000 or nil

  local function estimate_arg_cost(arg)
    return #tostring(arg) + 3
  end

  -- Hint the user that csearch would make this fast.
  if not vim.b._ue_grep_csearch_hint_shown then
    vim.b._ue_grep_csearch_hint_shown = true
    vim.notify(
      "UE grep: no csearch index. Run :UEPrepare for sub-second search.",
      vim.log.levels.INFO,
      { title = "UE" }
    )
  end

  snacks.picker.pick({
    source = "ue_grep_rg",
    title = opts.title or title_default,
    search = opts.search or "",
    live = true,
    need_search = true,
    layout = { preset = "telescope" },
    format = grouping_enabled and format_grouped or nil,
    preview = grouping_enabled and preview_grouped or nil,
    on_show = grouping_enabled and on_show_picker or nil,
    win = grouping_enabled and fast_tab_keys.win or nil,
    confirm = grouping_enabled and confirm_grouped or nil,
    finder = function(picker_opts, finder_ctx)
      local pattern = finder_ctx.filter.search
      if not pattern or pattern == "" then
        return function() end
      end

      local loaded_files = ensure_files()
      if not loaded_files then
        return function() end
      end

      return function(cb)
        -- Wrap cb to inject file-header items between file groups.
        if grouping_enabled then
          cb = make_grouping_cb(cb)
        end

        local base_args = {
          "--color=never",
          "--no-heading",
          "--with-filename",
          "--line-number",
          "--column",
          "--smart-case",
          "--max-columns=500",
          "--max-columns-preview",
          "-0",
          "--",
          pattern,
        }

        -- Windows CreateProcess hits a ~32k command-line ceiling, so split
        -- batches by both file count and estimated argument length.
        local args = vim.deepcopy(base_args)
        local current_arg_cost = 0
        for _, arg in ipairs(base_args) do
          current_arg_cost = current_arg_cost + estimate_arg_cost(arg)
        end
        local current_batch_size = 0

        local function flush_batch()
          if current_batch_size == 0 then
            return
          end

          local batch_args = args
          proc.proc(
            {
              notify = false,
              cmd = rg,
              args = batch_args,
              transform = function(item)
                local file_sep = item.text:find("\0")
                if not file_sep then
                  return false
                end
                local file = item.text:sub(1, file_sep - 1)
                local rest = item.text:sub(file_sep + 1)
                local line, col, text = rest:match("^(%d+):(%d+):(.*)$")
                if not (line and col and text) then
                  return false
                end
                item.text = file .. ":" .. rest
                item.pos = { tonumber(line), tonumber(col) - 1 }
                item.file = file
                return item
              end,
            },
            finder_ctx
          )(cb)

          args = vim.deepcopy(base_args)
          current_arg_cost = 0
          for _, arg in ipairs(base_args) do
            current_arg_cost = current_arg_cost + estimate_arg_cost(arg)
          end
          current_batch_size = 0
        end

        for _, file in ipairs(loaded_files) do
          local file_cost = estimate_arg_cost(file)
          local exceeds_batch_size = current_batch_size >= batch_size
          local exceeds_arg_limit = spawn_arg_limit and (current_arg_cost + file_cost) > spawn_arg_limit
          if current_batch_size > 0 and (exceeds_batch_size or exceeds_arg_limit) then
            flush_batch()
          end
          args[#args + 1] = file
          current_arg_cost = current_arg_cost + file_cost
          current_batch_size = current_batch_size + 1
        end

        flush_batch()
      end
    end,
  })

  return true
end

-- ==========================================================================
-- PUBLIC: STATUSLINE + ROOTS + GTAGS QUERIES
-- ==========================================================================

function M.statusline_status(opts)
  local ctx = resolve_context(opts)
  if not ctx then
    local build = trim(vim.g.ue_build_status or "")
    return build ~= "" and ("UE " .. build) or ""
  end

  local parts = { "UE" }
  local scope = current_scope_info_from_context(ctx)
  local summary = INDEX_FN.index_status_summary(ctx)
  parts[#parts + 1] = short_scope_token(scope)
  parts[#parts + 1] = mode_token(ctx)
  parts[#parts + 1] = index_status_token(ctx)

  if summary.queue_count > 0 then
    parts[#parts + 1] = "Q:" .. table.concat(summary.queued, "/")
  end

  if M._prepare_running then
    parts[#parts + 1] = "PREP*"
  end

  local build = trim(vim.g.ue_build_status or "")
  if build ~= "" then
    parts[#parts + 1] = build
  end

  return table.concat(parts, " ")
end

function M.index_status(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return nil
  end
  local summary = INDEX_FN.index_status_summary(ctx)
  local queue_text = (#summary.queued > 0) and table.concat(summary.queued, ", ") or "-"
  local lines = {
    "UE index status:",
    "  mode: " .. mode_token(ctx),
    "  phase: " .. summary.phase_label .. " (" .. summary.phase .. ")",
    "  build: " .. summary.status,
    "  active: " .. summary.active .. " [" .. summary.active_tier .. "/" .. summary.active_kind .. "]",
    "  dirty: root=" .. (summary.root_dirty and "yes" or "no") .. ", modules=" .. tostring(summary.dirty),
    "  queue: " .. queue_text,
    "  modules: total=" .. tostring(summary.total) .. ", core=" .. tostring(summary.core) .. ", warm=" .. tostring(summary.warm) .. ", cold=" .. tostring(summary.cold),
    "  index file: " .. (trim(summary.active_index_name) ~= "" and summary.active_index_name or "-"),
    "  message: " .. (trim(summary.message) ~= "" and trim(summary.message) or "-"),
  }
  local state = ensure_index_state(ctx)
  local ordered = sorted_module_records(state)
  if #ordered > 0 then
    lines[#lines + 1] = "  hot modules:"
    for i = 1, math.min(8, #ordered) do
      local rec = ordered[i]
      lines[#lines + 1] = string.format(
        "    %d. %s [%s] score=%d dirty=%s opened=%d changed=%d",
        i,
        rec.name or rec.key,
        module_tier_label(rec.tier),
        tonumber(rec._score) or 0,
        rec.dirty and "yes" or "no",
        tonumber(rec.last_opened) or 0,
        tonumber(rec.last_changed) or 0
      )
    end
  end
  local msg = table.concat(lines, "\n")
  vim.notify(msg, vim.log.levels.INFO)
  return msg
end

function M.index_now(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  local path = norm(vim.api.nvim_buf_get_name(0))
  if path ~= "" then
    INDEX_FN.set_active_module(ctx, path)
  end
  INDEX_FN.schedule_index_refresh(ctx, { current = true, hot = true, full = true, current_delay_ms = 50, hot_delay_ms = 2500 })
  invalidate_status_cache()
  refresh_statusline()
  return true
end

function M.index_hot(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  INDEX_FN.schedule_index_refresh(ctx, { current = false, hot = true, hot_delay_ms = 50, full = true })
  invalidate_status_cache()
  refresh_statusline()
  return true
end

function M.index_full(opts)
  local ctx, err = resolve_context(opts)
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return false
  end
  INDEX_FN.schedule_index_refresh(ctx, { current = false, hot = false, full = true, full_delay_ms = 50 })
  invalidate_status_cache()
  refresh_statusline()
  return true
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
  local engine_root = find_engine_root(bufname) or current_engine_root(bufname)
  if engine_root then
    if bufname == "" or path_has_prefix(bufname, engine_root) then
      return engine_root
    end
    -- Pass the bufname through so resolve_context picks up the buffer's
    -- own engine, not the cwd's engine. Critical for multi-engine setups
    -- and for background buffers (lsp may invoke clangd_root for a buf
    -- other than the current one).
    local ctx = resolve_context({ bufname = bufname })
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
    local code, lines = global_lines(root, ctx.paths.workspace_db, { "-r", "--literal", "--result=grep", symbol })
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

  if shader_definition_search(ctx, symbol) then
    return true
  end

  local root = workspace_root(ctx)
  if db_ready(ctx.paths.workspace_db) then
    local code, lines = global_lines(root, ctx.paths.workspace_db, { "-d", "--literal", "--result=grep", symbol })
    if (code == 0 or code == 1) and lines and #lines > 0 then
      return jump_to_global_result(root, lines, symbol)
    end

    code, lines = global_lines(root, ctx.paths.workspace_db, { "-g", "--literal", "--result=grep", symbol })
    if (code == 0 or code == 1) and lines and #lines > 0 then
      return jump_to_global_grep_candidate(root, symbol, lines)
    end
  end

  return rg_code_definition_search(ctx, symbol)
end

-- ---------------------------------------------------------------------------
-- Async GTAGS definition (does NOT block the main loop).
-- Calls on_done(true) if it jumped/populated qf, on_done(false) otherwise.
-- Wrapped in do-end to keep the helper locals out of the file's main-chunk
-- locals budget (Lua's 200-local limit per function).
-- ---------------------------------------------------------------------------

do
  local function global_lines_async(root, db_dir, args, on_done)
    local cmd = { "global" }
    vim.list_extend(cmd, args)
    return M._async.run_lines(cmd, {
      cwd = root,
      env = {
        GTAGSROOT = root,
        GTAGSDBPATH = db_dir,
      },
    }, on_done)
  end

  local function rg_code_definition_search_async(ctx, symbol, on_done)
    symbol = trim(symbol)
    if not ctx or symbol == "" then
      on_done(false)
      return
    end

    local rg = first_executable({ "rg" })
    if not rg then
      on_done(false)
      return
    end

    local dirs = {}
    local seen = {}
    local function add_dir(dir)
      dir = norm(dir)
      if dir ~= "" and is_dir(dir) and not seen[dir] then
        seen[dir] = true
        dirs[#dirs + 1] = dir
      end
    end

    if ctx.project_root and ctx.project_root ~= "" then
      for _, relative in ipairs(existing_relative_dirs(ctx.project_root, UE_CONST.PROJECT_INDEX_DIRS)) do
        add_dir(join(ctx.project_root, relative))
      end
    end
    for _, relative in ipairs(existing_relative_dirs(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS)) do
      add_dir(join(ctx.engine_root, relative))
    end

    if #dirs == 0 then
      on_done(false)
      return
    end

    local cmd = {
      rg, "--color", "never", "--no-heading",
      "--line-number", "--column", "--fixed-strings", "--with-filename",
    }
    for _, ext in ipairs(M.FT_CPP) do
      cmd[#cmd + 1] = "-g"
      cmd[#cmd + 1] = "*." .. ext
    end
    cmd[#cmd + 1] = "--"
    cmd[#cmd + 1] = symbol
    vim.list_extend(cmd, dirs)

    local cwd = ctx.engine_root
    if ctx.project_root and ctx.project_root ~= "" then
      local root = common_ancestor({ ctx.engine_root, ctx.project_root })
      if root ~= "" then
        cwd = root
      end
    end

    M._async.run_lines(cmd, { cwd = cwd }, function(code, lines)
      if code ~= 0 and code ~= 1 then
        on_done(false)
        return
      end
      local jumped = jump_to_grep_candidate_entries(symbol, parse_rg_entries(lines))
      on_done(jumped and true or false)
    end)
  end

  -- Public async API. Called by lsp_fallback.
  -- on_done(true) -> jumped or qf populated; on_done(false) -> nothing found.
  function M.gtags_definition_async(symbol, on_done)
    on_done = on_done or function() end
    local ctx, err = resolve_context()
    if not ctx then
      vim.notify(err, vim.log.levels.WARN)
      on_done(false)
      return
    end

    if shader_definition_search(ctx, symbol) then
      on_done(true)
      return
    end

    local root = workspace_root(ctx)
    local function rg_step()
      rg_code_definition_search_async(ctx, symbol, on_done)
    end

    if not db_ready(ctx.paths.workspace_db) then
      rg_step()
      return
    end

    global_lines_async(root, ctx.paths.workspace_db,
      { "-d", "--literal", "--result=grep", symbol },
      function(code, lines)
        if (code == 0 or code == 1) and lines and #lines > 0 then
          if jump_to_global_result(root, lines, symbol) then
            on_done(true)
            return
          end
        end
        global_lines_async(root, ctx.paths.workspace_db,
          { "-g", "--literal", "--result=grep", symbol },
          function(code2, lines2)
            if (code2 == 0 or code2 == 1) and lines2 and #lines2 > 0 then
              if jump_to_global_grep_candidate(root, symbol, lines2) then
                on_done(true)
                return
              end
            end
            rg_step()
          end)
      end)
  end
end

-- ---------------------------------------------------------------------------
-- Public platform query API (consumed by lsp_fallback for smart gd ranking).
-- Wrapped in do-end to avoid main-chunk local budget pressure.
-- ---------------------------------------------------------------------------

do
  -- Path keyword priority list for ranking implementation candidates.
  -- Earlier entries = higher preference. lsp_fallback scores hits by index.
  local PLATFORM_PATH_HINTS = {
    Win64    = { "D3D12RHI", "D3D11RHI", "VulkanRHI", "WindowsRHI", "WindowsPlatform", "Windows/" },
    Win32    = { "D3D11RHI", "D3D12RHI", "VulkanRHI", "WindowsRHI", "WindowsPlatform", "Windows/" },
    Android  = { "VulkanRHI", "OpenGLDrv", "AndroidRHI", "AndroidOpenGL", "AndroidVulkan", "Android/" },
    Mac      = { "MetalRHI", "MacRHI", "MacPlatform", "Mac/", "Apple/" },
    IOS      = { "MetalRHI", "IOSRHI", "IOSPlatform", "IOS/", "Apple/" },
    TVOS     = { "MetalRHI", "TVOSPlatform", "TVOS/", "Apple/" },
    Linux    = { "VulkanRHI", "LinuxRHI", "LinuxPlatform", "Linux/" },
    LinuxArm64 = { "VulkanRHI", "LinuxRHI", "LinuxPlatform", "Linux/" },
  }

  function M.current_platform()
    local ok, ctx = pcall(resolve_context)
    local engine = (ok and type(ctx) == "table") and ctx.engine_root or nil
    return target_platform(engine, nil)
  end

  function M.platform_path_priorities(platform)
    platform = platform or M.current_platform() or ""
    return PLATFORM_PATH_HINTS[platform] or {}
  end
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

-- ==========================================================================
-- USER COMMANDS — paths, cheatsheet, project, platform, build, prepare
-- ==========================================================================

local function show_paths()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    if vim.g.ue_prepare_headless == 1 then
      error(err)
    end
    return
  end

  local plat = target_platform(ctx.engine_root, nil)
  local selected_conf = selected_target_configuration(ctx.engine_root, ctx.project_root, ctx.uproject, plat)
  local conf = target_configuration(ctx.engine_root, ctx.project_root, ctx.uproject, plat)
  local plat_source = trim(ctx.state.target_platform or "") ~= "" and "set" or (trim(vim.env.UE_TARGET_PLATFORM or "") ~= "" and "env" or "auto")
  local conf_source = trim(ctx.state.target_configuration or "") ~= "" and "set" or (trim(vim.env.UE_TARGET_CONFIGURATION or "") ~= "" and "env" or "auto")

  local lines = {
    "Engine: " .. ctx.engine_root,
    "Project: " .. (ctx.project_root or "<unset>"),
    "Platform: " .. plat .. " (" .. plat_source .. ")",
    "Configuration: " .. selected_conf .. " (" .. conf_source .. ")",
    "GTAGS Root: " .. workspace_root(ctx),
    "Compile Commands: " .. compile_commands_targets(ctx)[1],
    "Compile Commands (Engine): " .. compile_commands_targets(ctx)[2],
    "State: " .. ctx.paths.state,
    "Project List: " .. ctx.paths.project_list,
    "Engine List: " .. ctx.paths.engine_list,
    "Workspace List: " .. ctx.paths.workspace_list,
    "Workspace All: " .. ctx.paths.workspace_all_list,
    "Workspace DB: " .. ctx.paths.workspace_db,
  }
  if selected_conf ~= conf then
    table.insert(lines, 5, "UBT Configuration: " .. conf)
  end
  vim.notify(table.concat(lines, "\n"))
end

local function cheatsheet_path()
  return join(vim.fn.stdpath("config"), "docs", "ue_lazyvim_cheatsheet.md")
end

local function open_cheatsheet(opts)
  opts = opts or {}
  local path = cheatsheet_path()
  ensure_dir(dirname(path))

  if not is_file(path) then
    vim.notify("Cheatsheet file missing: " .. path, vim.log.levels.WARN)
  end

  vim.cmd("tab drop " .. vim.fn.fnameescape(path))

  vim.bo.buftype = ""
  vim.bo.bufhidden = ""
  vim.bo.swapfile = false
  vim.bo.filetype = "markdown"
  vim.bo.readonly = false
  vim.bo.modifiable = true

  vim.wo.wrap = true
  vim.wo.linebreak = true
  vim.wo.number = false
  vim.wo.relativenumber = false
  vim.wo.signcolumn = "no"

  local preview = opts.preview ~= false
  if not preview then
    vim.wo.conceallevel = 0
  end

  local bufnr = vim.api.nvim_get_current_buf()
  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    pcall(vim.api.nvim_buf_call, bufnr, function()
      if preview then
        vim.cmd("silent! MarkdownPreview")
      else
        vim.cmd("silent! MarkdownEdit")
      end
    end)

    if not preview then
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        if vim.api.nvim_win_is_valid(win) then
          vim.wo[win].conceallevel = 0
        end
      end
    end
  end)

  if preview then
    vim.notify("Cheatsheet preview: normal mode renders, insert mode edits\n" .. path)
  else
    vim.notify("Editing cheatsheet (raw markdown): " .. path)
  end
end

local function edit_cheatsheet()
  open_cheatsheet({ preview = false })
end

local function show_cheatsheet()
  require("utils.cheatsheet").open()
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

local function platform_selection_context()
  local ctx = resolve_context({ detect_project = true })
  if ctx then
    return ctx.engine_root, ctx.project_root, ctx.uproject, ctx.state
  end

  local engine_root = current_engine_root()
  if not engine_root then
    return nil, nil, nil, {}
  end

  local state = read_state(engine_root)
  local project_root = norm(state.project_root or "")
  local uproject = norm(state.uproject or "")
  if uproject == "" and project_root ~= "" then
    uproject = find_uproject_in_dir(project_root) or ""
  end

  return engine_root, project_root, uproject, state
end

local function split_platform_input(input)
  input = trim(input or "")
  if input == "" then
    return nil, nil
  end

  local platform, configuration = input:match("^(%S+)%s+(.+)$")
  if platform then
    return trim(platform), trim(configuration)
  end

  return input, nil
end

local function set_platform_completions(arg_lead)
  local _, project_root, uproject = platform_selection_context()
  local all = {}
  local seen = {}

  for _, platform in ipairs(available_platform_choices(project_root, uproject)) do
    push_unique(all, seen, platform)
    for _, configuration in ipairs(available_configuration_choices(project_root, uproject, platform)) do
      push_unique(all, seen, platform .. " " .. configuration)
    end
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
end

local function set_platform(input)
  local engine_root, project_root, uproject, state = platform_selection_context()
  if not engine_root then
    vim.notify("No Unreal Engine root found from current buffer or cwd", vim.log.levels.WARN)
    return
  end

  local current_plat = trim(state.target_platform or "")
  local current_conf = trim(state.target_configuration or "")
  local default_plat = current_plat ~= "" and current_plat or target_platform(engine_root, nil)
  local default_conf = current_conf ~= "" and current_conf
    or selected_target_configuration(engine_root, project_root, uproject, default_plat)

  -- Direct input: "Win64 Development Editor" or "Win64" or "Android DebugGame"
  input = trim(input or "")
  if input ~= "" then
    local plat, conf = split_platform_input(input)
    if plat and plat ~= "" then
      update_state_field(engine_root, "target_platform", plat)
    end
    if conf and conf ~= "" then
      update_state_field(engine_root, "target_configuration", conf)
    end
    invalidate_status_cache()
    refresh_statusline()
    CORE_RT.context_cache = {}
    vim.notify(("UE platform: %s %s"):format(
      plat or default_plat or "(auto)",
      conf or default_conf
    ))
    return
  end

  -- Interactive: select platform then configuration
  vim.ui.select(available_platform_choices(project_root, uproject), {
    prompt = "Target Platform (current: " .. (current_plat ~= "" and current_plat or "auto") .. "):",
  }, function(plat)
    if not plat then
      return
    end

    local current_for_platform = current_conf ~= "" and current_conf
      or selected_target_configuration(engine_root, project_root, uproject, plat)
    vim.ui.select(available_configuration_choices(project_root, uproject, plat), {
      prompt = "Target Configuration (current: " .. current_for_platform .. "):",
    }, function(conf)
      if not conf then
        return
      end
      update_state_field(engine_root, "target_platform", plat)
      update_state_field(engine_root, "target_configuration", conf)
      invalidate_status_cache()
      refresh_statusline()
      CORE_RT.context_cache = {}
      vim.notify(("UE platform set: %s %s\nRun :UEPrepare to regenerate for this platform"):format(plat, conf))
    end)
  end)
end

-- export_compile_commands is now an alias for prepare_async (unified flow)
local export_compile_commands

local stop_android_debugger

local function build_android()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  if not ctx.project_root then
    vim.notify("No project configured for engine root. Run :UESetProject [path]", vim.log.levels.WARN)
    if vim.g.ue_prepare_headless == 1 then
      error("No project configured for engine root. Run :UESetProject [path]")
    end
    return
  end

  local plat = target_platform(ctx.engine_root, nil)
  local conf = selected_target_configuration(ctx.engine_root, ctx.project_root, ctx.uproject, plat)
  local title = ("UEBuild %s %s"):format(plat, conf)

  local cmd, build_err = android_build_command(ctx)
  if not cmd then
    set_build_status("BERR")
    vim.notify(title .. " failed: " .. build_err, vim.log.levels.ERROR)
    return
  end

  if plat == "Android" then
    local cleanup = stop_android_debugger({ kill_orphans = true })
    cleanup_gradle_debug_artifacts(ctx)
    if cleanup.disconnected or cleanup.adapter_killed or cleanup.orphan_killed > 0 then
      local parts = {}
      if cleanup.disconnected then
        table.insert(parts, "detached active DAP")
      end
      if cleanup.adapter_killed then
        table.insert(parts, "stopped CodeLLDB adapter")
      end
      if cleanup.orphan_killed > 0 then
        table.insert(parts, ("killed %d stale CodeLLDB process%s"):format(
          cleanup.orphan_killed,
          cleanup.orphan_killed == 1 and "" or "es"
        ))
      end
      vim.notify("Android build preflight: " .. table.concat(parts, ", "), vim.log.levels.INFO)
    end
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

local function ue_runtime_env()
  return {
    build_target_name = build_target_name,
    dirname = dirname,
    file_mtime = file_mtime,
    find_uproject_in_dir = find_uproject_in_dir,
    glob_paths = glob_paths,
    is_file = is_file,
    is_windows_path = is_windows_path,
    join = join,
    norm = norm,
    powershell_quote = powershell_quote,
    resolve_context = resolve_context,
    run_lines = run_lines,
    selected_target_configuration = selected_target_configuration,
    strip_ansi = strip_ansi,
    target_configuration = target_configuration,
    target_kind = target_kind,
    target_platform = target_platform,
    trim = trim,
    update_state_field = update_state_field,
  }
end

function M.launch_app()
  package.loaded["utils.ue_launch"] = nil
  return require("utils.ue_launch").launch(ue_runtime_env())
end

function M.toggle_log()
  return require("utils.ue_logs").toggle_main_log(ue_runtime_env())
end

function M.toggle_debug_log()
  return require("utils.ue_logs").toggle_debug_log(ue_runtime_env())
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

  if ctx.state.project_root ~= ctx.project_root then
    persist_project(ctx.engine_root, ctx.project_root, ctx.uproject)
  end

  ensure_dir(ctx.paths.cache)

  local root = workspace_root(ctx)
  if prepare_cache_ready(ctx) then
    local ok_compile, compile_path = generate_compile_commands(ctx)
    if not ok_compile then
      invalidate_status_cache()
      refresh_statusline()
      populate_quickfix_from_output("UEPrepare compile_commands", compile_path, { root = root })
      vim.notify("UEPrepare compile_commands failed: " .. compile_path, vim.log.levels.WARN)
      if vim.g.ue_prepare_headless == 1 then
        error("UEPrepare compile_commands failed: " .. compile_path)
      end
      return
    end
    clear_index_dirty(ctx)
    INDEX_FN.schedule_index_refresh(ctx, { current = true, hot = true, full = true, current_delay_ms = 50 })
    invalidate_status_cache()
    refresh_statusline()
    local summary = prepare_summary(ctx, compile_path, { reused_cache = true })
    if vim.g.ue_prepare_headless == 1 then
      print(summary)
      return
    end
    vim.notify(summary)
    return
  end

  local project_rel = {}
  if ctx.project_root and ctx.project_root ~= "" then
    local project_dirs = existing_relative_dirs(ctx.project_root, UE_CONST.PROJECT_INDEX_DIRS)
    local project_err
    project_rel, project_err = scan_relative_files(ctx.project_root, project_dirs)
    if not project_rel then
      invalidate_status_cache()
      refresh_statusline()
      populate_quickfix_from_output("UEPrepare project scan", project_err, { root = ctx.project_root })
      vim.notify("UEPrepare project scan failed: " .. project_err, vim.log.levels.ERROR)
      if vim.g.ue_prepare_headless == 1 then
        error("UEPrepare project scan failed: " .. project_err)
      end
      return
    end
  end

  local engine_rel, engine_err = scan_relative_files(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS)
  if not engine_rel then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEPrepare engine scan", engine_err, { root = ctx.engine_root })
    vim.notify("UEPrepare engine scan failed: " .. engine_err, vim.log.levels.ERROR)
    if vim.g.ue_prepare_headless == 1 then
      error("UEPrepare engine scan failed: " .. engine_err)
    end
    return
  end

  local project_code = filter_gtags_paths(filter_gtags_code(project_rel))
  local engine_code = filter_gtags_paths(filter_gtags_code(engine_rel))
  local workspace_code = {}
  local workspace_seen = {}

  for _, path in ipairs(project_code) do
    local absolute = join(ctx.project_root, path)
    local relative = relative_to(root, absolute)
    if not workspace_seen[relative] then
      workspace_seen[relative] = true
      table.insert(workspace_code, relative)
    end
  end

  for _, path in ipairs(engine_code) do
    local absolute = join(ctx.engine_root, path)
    local relative = relative_to(root, absolute)
    if not workspace_seen[relative] then
      workspace_seen[relative] = true
      table.insert(workspace_code, relative)
    end
  end

  table.sort(workspace_code)

  write_lines(ctx.paths.project_list, project_code)
  write_lines(ctx.paths.engine_list, engine_code)
  write_lines(ctx.paths.workspace_list, workspace_code)

  -- All-types file list (code + config) for cached grep
  local project_all = filter_gtags_paths(filter_extensions(project_rel, M.FT_ALL))
  local engine_all = filter_gtags_paths(filter_extensions(engine_rel, M.FT_ALL))
  local workspace_all = {}
  local workspace_all_seen = {}

  for _, path in ipairs(project_all) do
    local absolute = join(ctx.project_root, path)
    local relative = relative_to(root, absolute)
    if not workspace_all_seen[relative] then
      workspace_all_seen[relative] = true
      table.insert(workspace_all, relative)
    end
  end

  for _, path in ipairs(engine_all) do
    local absolute = join(ctx.engine_root, path)
    local relative = relative_to(root, absolute)
    if not workspace_all_seen[relative] then
      workspace_all_seen[relative] = true
      table.insert(workspace_all, relative)
    end
  end

  table.sort(workspace_all)
  write_lines(ctx.paths.workspace_all_list, workspace_all)

  local ok_workspace, workspace_err = build_gtags_db(root, ctx.paths.workspace_list, ctx.paths.workspace_db, "workspace")
  if not ok_workspace then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEPrepare GTAGS", workspace_err, { root = root })
    vim.notify("UEPrepare GTAGS failed: " .. workspace_err, vim.log.levels.ERROR)
    if vim.g.ue_prepare_headless == 1 then
      error("UEPrepare GTAGS failed: " .. workspace_err)
    end
    return
  end

  local ok_compile, compile_path = generate_compile_commands(ctx)
  if not ok_compile then
    invalidate_status_cache()
    refresh_statusline()
    populate_quickfix_from_output("UEPrepare compile_commands", compile_path, { root = root })
    vim.notify("UEPrepare compile_commands failed: " .. compile_path, vim.log.levels.WARN)
    if vim.g.ue_prepare_headless == 1 then
      error("UEPrepare compile_commands failed: " .. compile_path)
    end
    return
  end

  clear_index_dirty(ctx)
  INDEX_FN.schedule_index_refresh(ctx, { current = true, hot = true, full = true, current_delay_ms = 50 })
  invalidate_status_cache()
  refresh_statusline()

  -- ── csearch index (sync path) ───────────────────────────────────────
  -- Build the trigram index for sub-second grep. Same logic as the async
  -- path; we just block on the libuv callback here.
  do
    local cs_root = root
    local cs_ctx_p = { workspace_root = cs_root }
    local code_search_p = require("utils.code_search")
    if code_search_p.cindex_uefilter_exe() then
      local abs_list = ctx.paths.cache .. "/csearch_filelist.txt"
      local fout = io.open(abs_list, "w")
      if fout then
        for _, rel in ipairs(workspace_all) do
          fout:write(cs_root, "/", rel, "\n")
        end
        fout:close()
        local cs_done, cs_ok, cs_err = false, false, nil
        code_search_p.build_index(cs_ctx_p, abs_list, function(ok_cs, err_cs, _st)
          cs_ok, cs_err = ok_cs, err_cs
          cs_done = true
        end)
        vim.wait(180000, function() return cs_done end, 100)
        pcall(os.remove, abs_list)
        if not cs_ok then
          vim.notify("UEPrepare: csearch index failed: " .. (cs_err or "timeout"),
            vim.log.levels.WARN, { title = "UE" })
        end
      end
    else
      vim.notify(
        "UEPrepare: cindex-uefilter not found — grep will use slow rg fallback.\n" ..
        "  Build it via: cd " .. vim.fn.stdpath("config") .. "/tools/cindex-uefilter && go install ./...",
        vim.log.levels.WARN, { title = "UE" })
    end
  end

  local summary = prepare_summary(ctx, compile_path, {
    project_count = #project_code,
    engine_count = #engine_code,
    workspace_count = #workspace_code,
    workspace_all_count = #workspace_all,
  })
  if vim.g.ue_prepare_headless == 1 then
    print(summary)
    return
  end
  vim.notify(summary)
end


local function collect_trimmed_lines(lines, data)
  for _, line in ipairs(data or {}) do
    line = trim(line)
    if line ~= "" then
      table.insert(lines, line)
    end
  end
end

local function prepare_async()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  if CORE_RT.prepare_jobid then
    local ok_wait, result = pcall(vim.fn.jobwait, { CORE_RT.prepare_jobid }, 0)
    if ok_wait and result and result[1] == -1 then
      vim.notify("UEPrepare is already running", vim.log.levels.INFO)
      return
    end
    CORE_RT.prepare_jobid = nil
  end

  if ctx.state.project_root ~= ctx.project_root then
    persist_project(ctx.engine_root, ctx.project_root, ctx.uproject)
  end

  ensure_dir(ctx.paths.cache)

  -- ── Timing & ETA ─────────────────────────────────────────────────────
  -- Load previous run timings for ETA estimation
  local prev_timings = ctx.state.prepare_timings or {}
  local phase_start = vim.uv.hrtime()
  local total_start = phase_start
  local timings = {} -- { phase_name = seconds }

  local function elapsed_s()
    return math.max(1, math.floor((vim.uv.hrtime() - total_start) / 1e9))
  end

  local function phase_elapsed_s()
    return (vim.uv.hrtime() - phase_start) / 1e9
  end

  local function start_phase()
    phase_start = vim.uv.hrtime()
  end

  local function end_phase(name)
    timings[name] = phase_elapsed_s()
    phase_start = vim.uv.hrtime()
  end

  local function eta_str(phase_name, pct_done)
    -- Try to estimate from previous run timings
    local prev_total = 0
    for _, v in pairs(prev_timings) do prev_total = prev_total + (tonumber(v) or 0) end
    if prev_total > 0 then
      local el = elapsed_s()
      local progress = math.max(pct_done / 100, 0.01)
      local est_total = el / progress
      local remaining = math.max(0, math.floor(est_total - el))
      if remaining > 0 then
        return (" ~%ds left"):format(remaining)
      end
      return " finishing..."
    end
    return ""
  end

  -- ── Cache fast-path ──────────────────────────────────────────────────
  if prepare_cache_ready(ctx) then
    local root = workspace_root(ctx)
    local ok_compile, compile_path = generate_compile_commands(ctx)
    if not ok_compile then
      invalidate_status_cache()
      refresh_statusline()
      populate_quickfix_from_output("UEPrepare compile_commands", compile_path, { root = root })
      vim.notify("UEPrepare compile_commands failed: " .. compile_path, vim.log.levels.WARN)
      return
    end
    clear_index_dirty(ctx)
    INDEX_FN.schedule_index_refresh(ctx, { current = true, hot = true, full = true, current_delay_ms = 50, hot_delay_ms = 2500 })
    invalidate_status_cache()
    refresh_statusline()

    -- Build csearch index if missing or stale (older than workspace_all).
    -- Async; doesn't block the fast-path return.
    local code_search_fp = require("utils.code_search")
    local cs_ctx_fp = { workspace_root = root }
    local need_index = true
    do
      local idx_path = code_search_fp.index_path(cs_ctx_fp)
      local list_path = ctx.paths.workspace_all_list
      local idx_stat = idx_path and vim.loop.fs_stat(idx_path) or nil
      local list_stat = list_path and vim.loop.fs_stat(list_path) or nil
      if idx_stat and idx_stat.size > 1024 and list_stat then
        local idx_mt  = idx_stat.mtime  and idx_stat.mtime.sec  or 0
        local list_mt = list_stat.mtime and list_stat.mtime.sec or 0
        if idx_mt >= list_mt then need_index = false end
      end
    end
    if need_index and code_search_fp.cindex_uefilter_exe() then
      local abs_list = ctx.paths.cache .. "/csearch_filelist.txt"
      local fout = io.open(abs_list, "w")
      if fout then
        for line in io.lines(ctx.paths.workspace_all_list) do
          local trimmed = line:gsub("\r$", "")
          if trimmed ~= "" then
            fout:write(root, "/", trimmed, "\n")
          end
        end
        fout:close()
        vim.notify("UEPrepare: rebuilding csearch index in background...",
          vim.log.levels.INFO, { title = "UE", timeout = 3000, replace = "ue.csearch.build" })
        code_search_fp.build_index(cs_ctx_fp, abs_list, function(ok_cs, err_cs, stats)
          pcall(os.remove, abs_list)
          if ok_cs then
            local mb = math.floor((stats.index_size or 0) / 1024 / 1024)
            vim.notify(("✓ csearch index rebuilt: %d MB in %.1fs"):format(
              mb, (stats.ms or 0) / 1000),
              vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
          else
            vim.notify("UEPrepare: csearch rebuild failed: " .. (err_cs or "unknown"),
              vim.log.levels.WARN, { title = "UE", replace = "ue.csearch.build" })
          end
        end)
      end
    end

    vim.notify(prepare_summary(ctx, compile_path, { reused_cache = true }))
    return
  end

  -- ── fidget progress ──────────────────────────────────────────────────
  local ok_fidget, progress = pcall(require, "fidget.progress")
  local handle
  if ok_fidget then
    handle = progress.handle.create({
      title = "UEPrepare",
      message = "starting...",
      lsp_client = { name = "ue" },
      percentage = 0,
    })
  end

  local function update(msg, pct)
    local eta = eta_str(nil, pct or 0)
    local full_msg = msg .. eta .. ("  [%ds]"):format(elapsed_s())
    if handle then
      handle.message = full_msg
      if pct then handle.percentage = pct end
    end
  end

  local function fail(msg)
    invalidate_status_cache()
    refresh_statusline()
    set_prepare_running(false)
    if handle then
      handle.message = "FAILED: " .. msg
      handle:finish()
    end
    vim.notify("UEPrepare failed: " .. msg, vim.log.levels.ERROR)
  end

  set_prepare_running(true)
  start_phase()

  local function continue_after_scan(project_rel, engine_rel)
    end_phase("scan")

    -- ── Phase 2: build file lists ────────────────────────────────────
    update("building file lists...", 25)
    start_phase()

    local project_code = filter_gtags_paths(filter_gtags_code(project_rel))
    local engine_code = filter_gtags_paths(filter_gtags_code(engine_rel))
    local workspace_code = {}
    local workspace_seen = {}
    local root = workspace_root(ctx)

    for _, path in ipairs(project_code) do
      local absolute = join(ctx.project_root, path)
      local relative = relative_to(root, absolute)
      if not workspace_seen[relative] then
        workspace_seen[relative] = true
        table.insert(workspace_code, relative)
      end
    end

    for _, path in ipairs(engine_code) do
      local absolute = join(ctx.engine_root, path)
      local relative = relative_to(root, absolute)
      if not workspace_seen[relative] then
        workspace_seen[relative] = true
        table.insert(workspace_code, relative)
      end
    end

    table.sort(workspace_code)

    write_lines(ctx.paths.project_list, project_code)
    write_lines(ctx.paths.engine_list, engine_code)
    write_lines(ctx.paths.workspace_list, workspace_code)

    -- All-types file list (code + config) for cached grep
    local project_all = filter_gtags_paths(filter_extensions(project_rel, M.FT_ALL))
    local engine_all = filter_gtags_paths(filter_extensions(engine_rel, M.FT_ALL))
    local workspace_all = {}
    local workspace_all_seen = {}

    for _, path in ipairs(project_all) do
      local absolute = join(ctx.project_root, path)
      local relative = relative_to(root, absolute)
      if not workspace_all_seen[relative] then
        workspace_all_seen[relative] = true
        table.insert(workspace_all, relative)
      end
    end

    for _, path in ipairs(engine_all) do
      local absolute = join(ctx.engine_root, path)
      local relative = relative_to(root, absolute)
      if not workspace_all_seen[relative] then
        workspace_all_seen[relative] = true
        table.insert(workspace_all, relative)
      end
    end

    table.sort(workspace_all)
    write_lines(ctx.paths.workspace_all_list, workspace_all)

    end_phase("lists")

    -- ── Phase 3a: generate compile_commands (parallel with gtags) ────
    -- compile_commands doesn't depend on gtags, so start it immediately.
    -- The pipeline (slim → pch → unify) runs in background via jobstart.
    update("generating compile_commands...", 30)
    start_phase()

    local ok_compile, compile_path = generate_compile_commands(ctx)
    if not ok_compile then
      vim.notify("UEPrepare: compile_commands failed (non-fatal): " .. (compile_path or "unknown"), vim.log.levels.WARN)
    end

    end_phase("compile_commands")

    -- ── Phase 3b: build GTAGS (async, slow) ───────────────────────────
    update(("indexing %d files with gtags..."):format(#workspace_code), 35)
    start_phase()

    local gtags = first_executable({ "gtags" })
    if not gtags then
      fail("gtags not found in PATH")
      return
    end

    local db_dir = ctx.paths.workspace_db
    local filelist = ctx.paths.workspace_list
    clean_db_dir(db_dir)

    local gtags_cmd = { gtags, "-f", filelist, "--skip-unreadable", "--skip-symlink", db_dir }
    local gtags_output = {}
    local indexed_count = 0
    local gtags_started_at = vim.uv.hrtime()
    local gtags_timer = vim.uv.new_timer()
    local gtags_cwd = ctx.engine_root

    gtags_timer:start(2000, 2000, vim.schedule_wrap(function()
      if CORE_RT.prepare_jobid and CORE_RT.prepare_jobid > 0 then
        local gtags_elapsed = math.max(1, math.floor((vim.uv.hrtime() - gtags_started_at) / 1e9))
        local pct = indexed_count > 0
            and math.min(30 + math.floor(indexed_count / math.max(#workspace_code, 1) * 50), 80)
          or 35
        -- ETA based on gtags progress
        local gtags_eta = ""
        if indexed_count > 100 then
          local rate = indexed_count / gtags_elapsed
          local remaining_files = #workspace_code - indexed_count
          local remaining_s = math.max(0, math.floor(remaining_files / rate))
          -- Add estimate for compile_commands phase
          local cc_est = tonumber(prev_timings.compile_commands) or 10
          gtags_eta = (" ~%ds left"):format(remaining_s + math.floor(cc_est))
        end
        local msg = ("gtags: %d/%d files, %ds elapsed%s"):format(
          indexed_count, #workspace_code, gtags_elapsed, gtags_eta)
        if handle then
          handle.message = msg
          handle.percentage = pct
        end
      end
    end))

    CORE_RT.prepare_jobid = vim.fn.jobstart(gtags_cmd, {
      cwd = gtags_cwd,
      on_stdout = function(_, data)
        collect_trimmed_lines(gtags_output, data)
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data or {}) do
          line = trim(line)
          if line ~= "" then
            table.insert(gtags_output, line)
            if not line:match("^Warning:") then
              indexed_count = indexed_count + 1
            end
          end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          CORE_RT.prepare_jobid = nil
          if gtags_timer then
            gtags_timer:stop()
            gtags_timer:close()
            gtags_timer = nil
          end

          if code ~= 0 or not db_ready(db_dir) then
            fail("gtags exited with code " .. code .. "\n" .. table.concat(gtags_output, "\n"))
            return
          end

          end_phase("gtags")

          -- ── Phase 4: csearch index (sub-second grep) ─────────────
          -- We feed cindex-uefilter the same workspace_all list GTAGS used
          -- (with absolute paths). cindex-uefilter is a small fork of
          -- google/codesearch's cindex that adds a -files-from flag,
          -- letting us index exactly our pre-filtered file set instead
          -- of walking the dir tree (which would suck in graphify-out
          -- caches, Intermediate, etc.). See tools/cindex-uefilter/.
          start_phase()
          update("building csearch index...", 85)

          local code_search = require("utils.code_search")
          local function finalize_after_csearch()
            end_phase("csearch")

            -- ── Finalize ───────────────────────────────────────────
            clear_index_dirty(ctx)
            invalidate_status_cache()
            refresh_statusline()
            set_prepare_running(false)

            -- Persist timings for future ETA estimation
            timings.total = elapsed_s()
            update_state_field(ctx.engine_root, "prepare_timings", timings)

            local summary = prepare_summary(ctx, ok_compile and compile_path or nil, {
              project_count = #project_code,
              engine_count = #engine_code,
              workspace_count = #workspace_code,
              workspace_all_count = #workspace_all,
            })
            summary = summary .. ("\nElapsed: %ds (scan:%ds lists:%ds gtags:%ds cc:%ds csearch:%ds)"):format(
              timings.total,
              math.floor(timings.scan or 0),
              math.floor(timings.lists or 0),
              math.floor(timings.gtags or 0),
              math.floor(timings.compile_commands or 0),
              math.floor(timings.csearch or 0))

            update("done", 100)
            if handle then
              handle.message = ("done in %ds"):format(timings.total)
              handle:finish()
            end
            vim.notify(summary)
          end

          -- If cindex-uefilter is missing, skip silently (with a one-time
          -- hint). The grep picker will fall back to rg-batched mode.
          if not code_search.cindex_uefilter_exe() then
            vim.notify(
              "UEPrepare: cindex-uefilter not found — grep will use slow rg fallback.\n" ..
              "  Build it via: cd " .. vim.fn.stdpath("config") .. "/tools/cindex-uefilter && go install ./...",
              vim.log.levels.WARN, { title = "UE" })
            finalize_after_csearch()
            return
          end

          -- Materialize an absolute-path tmpfile from workspace_all (which
          -- holds workspace-root-relative paths).
          local cs_root = workspace_root(ctx)
          local cs_ctx = { workspace_root = cs_root }
          local abs_list = ctx.paths.cache .. "/csearch_filelist.txt"
          local fout = io.open(abs_list, "w")
          if not fout then
            vim.notify("UEPrepare: failed to write " .. abs_list, vim.log.levels.WARN, { title = "UE" })
            finalize_after_csearch()
            return
          end
          for _, rel in ipairs(workspace_all) do
            fout:write(cs_root, "/", rel, "\n")
          end
          fout:close()

          code_search.build_index(cs_ctx, abs_list, function(ok_cs, err_cs, stats)
            -- Tidy up the temp filelist regardless of outcome.
            pcall(os.remove, abs_list)

            if ok_cs then
              local mb = math.floor((stats.index_size or 0) / 1024 / 1024)
              vim.notify(("✓ csearch index: %d MB in %.1fs"):format(
                mb, (stats.ms or 0) / 1000),
                vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
            else
              vim.notify("UEPrepare: csearch index failed: " .. (err_cs or "unknown"),
                vim.log.levels.WARN, { title = "UE" })
            end
            finalize_after_csearch()
          end)
        end)
      end,
    })

    if CORE_RT.prepare_jobid <= 0 then
      CORE_RT.prepare_jobid = nil
      if gtags_timer then
        gtags_timer:stop()
        gtags_timer:close()
        gtags_timer = nil
      end
      fail("failed to start gtags process")
    end
  end

  -- ── Phase 1: scan files (async) ──────────────────────────────────────
  local function start_scan()
    if ctx.project_root and ctx.project_root ~= "" then
      update("scanning project files...", 5)
      local project_dirs = existing_relative_dirs(ctx.project_root, UE_CONST.PROJECT_INDEX_DIRS)
      scan_relative_files_async(ctx.project_root, project_dirs, function(project_rel, project_err)
        if not project_rel then
          fail(project_err)
          return
        end
        update("scanning engine files...", 15)
        scan_relative_files_async(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS, function(engine_rel, engine_err)
          if not engine_rel then
            fail(engine_err)
            return
          end
          continue_after_scan(project_rel, engine_rel)
        end)
      end)
    else
      update("engine-only: scanning engine files...", 10)
      scan_relative_files_async(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS, function(engine_rel, engine_err)
        if not engine_rel then
          fail(engine_err)
          return
        end
        continue_after_scan({}, engine_rel)
      end)
    end
  end

  start_scan()
end

-- export_compile_commands is now an alias for the unified prepare flow
export_compile_commands = prepare_async

function M.prepare_headless()
  local ok, err = xpcall(prepare, debug.traceback)
  if not ok then
    vim.api.nvim_err_writeln(err)
    vim.cmd("cquit 1")
    return
  end
  vim.cmd("qall!")
end

local function clear_cache(opts)
  opts = opts or {}
  local bang = opts.bang or false -- :UEClearCache! = full clean including clangd + LSP restart

  local ctx, err = resolve_context({ detect_project = false })
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  local removed = {}

  -- 1. nvim-ue own caches (gtags file lists, state, db)
  for _, f in ipairs({
    ctx.paths.project_list,
    ctx.paths.engine_list,
    ctx.paths.workspace_list,
    ctx.paths.workspace_all_list,
    ctx.paths.state,
    ctx.paths.index_state,
    ctx.paths.index_queue,
    ctx.paths.index_current_cdb,
    ctx.paths.index_hot_cdb,
    ctx.paths.index_full_cdb,
  }) do
    if vim.fn.filereadable(f) == 1 then
      pcall(vim.fn.delete, f)
      table.insert(removed, "  " .. f)
    end
  end
  local gtags_dir = join(ctx.paths.cache, "gtags")
  if is_dir(gtags_dir) then
    pcall(vim.fn.delete, gtags_dir, "rf")
    table.insert(removed, "  " .. gtags_dir .. "/ (gtags)")
  end

  -- 2. clangd index cache (.cache/clangd/ under engine and project roots)
  local clangd_roots = { ctx.engine_root }
  if ctx.project_root then
    table.insert(clangd_roots, ctx.project_root)
  end
  for _, root in ipairs(clangd_roots) do
    local clangd_cache = join(root, ".cache", "clangd")
    if is_dir(clangd_cache) then
      pcall(vim.fn.delete, clangd_cache, "rf")
      table.insert(removed, "  " .. clangd_cache .. "/ (clangd index)")
    end
  end

  if bang then
    for _, idx in ipairs({ ctx.paths.active_index, ctx.paths.current_index, ctx.paths.hot_index, ctx.paths.full_index }) do
      if is_file(idx) then
        pcall(vim.fn.delete, idx)
        table.insert(removed, "  " .. idx .. " (offline index)")
      end
    end
  end

  -- 3. compile_commands.json (only with bang)
  if bang then
    for _, root in ipairs(clangd_roots) do
      local cc = join(root, "compile_commands.json")
      if vim.fn.filereadable(cc) == 1 then
        pcall(vim.fn.delete, cc)
        table.insert(removed, "  " .. cc .. " (compile_commands)")
      end
    end
    -- PCH cache: invalidates after LLVM/clangd version bump where the
    -- old PCH format is rejected ("uses an older format that is no
    -- longer supported"). The error is silently dropped by clangd, so
    -- the only symptom is "all UE types unknown" — see :UEBuildPCH.
    for _, root in ipairs(clangd_roots) do
      local pch_dir = join(root, ".clangd-pch")
      if is_dir(pch_dir) then
        pcall(vim.fn.delete, pch_dir, "rf")
        table.insert(removed, "  " .. pch_dir .. "/ (PCH cache)")
      end
    end
  end

  -- summary
  if #removed == 0 then
    vim.notify("UE: no caches found to clean", vim.log.levels.INFO)
  else
    vim.notify("UE cache cleared:\n" .. table.concat(removed, "\n"), vim.log.levels.INFO)
  end

  invalidate_status_cache()
  local root_key = status_root_key(ctx)
  for timer_key, timer in pairs(INDEX_RT.timers or {}) do
    if vim.startswith(timer_key, root_key .. "::") then
      timer:stop()
      timer:close()
      INDEX_RT.timers[timer_key] = nil
    end
  end
  CORE_RT.dirty_index_roots[root_key] = nil
  INDEX_RT.module_state[root_key] = nil
  INDEX_RT.contexts[root_key] = nil
  refresh_statusline()

  -- 4. restart clangd LSP so it re-indexes cleanly
  if bang then
    local clients = vim.lsp.get_clients({ name = "clangd" })
    if #clients > 0 then
      -- Stop all clangd instances first, then restart after they exit
      for _, client in ipairs(clients) do
        client:stop()
      end
      vim.defer_fn(function()
        vim.cmd("edit")  -- re-trigger lspconfig attach on current buffer
        vim.notify("UE: clangd restarted", vim.log.levels.INFO)
      end, 500)
    end
  end
end

-- ---------------------------------------------------------------------------
-- Android DAP debugging — delegated to ue/dap.lua
-- ---------------------------------------------------------------------------
local dap_mod = require("ue.dap")

-- Inject core utilities that the DAP module needs
dap_mod.setup_core({
  trim = trim,
  norm = norm,
  join = join,
  dirname = dirname,
  is_file = is_file,
  ensure_dir = ensure_dir,
  run_lines = run_lines,
  file_stat = file_stat,
  file_mtime = file_mtime,
  glob_paths = glob_paths,
  is_native_windows = is_native_windows,
  resolve_context = resolve_context,
  invalidate_status_cache = invalidate_status_cache,
  refresh_statusline = refresh_statusline,
  first_executable = first_executable,
  path_has_prefix = path_has_prefix,
  relative_to = relative_to,
  update_state_field = update_state_field,
  read_state = read_state,
})

-- Re-export DAP state for backward compat (plugins/dap.lua calls M.setup_dap)
M._dap_session_state = dap_mod._dap_session_state
M._breakpoint_specs = dap_mod._breakpoint_specs
M._dap_attach_in_progress = dap_mod._dap_attach_in_progress
M._dap_run_state = dap_mod._dap_run_state
M._continue_debounce_until_ms = dap_mod._continue_debounce_until_ms
M._dap_source_file_cache = dap_mod._dap_source_file_cache

-- Delegate DAP public API
M.codelldb_paths = dap_mod.codelldb_paths
M._reapply_breakpoints = dap_mod._reapply_breakpoints
M._setup_aslr_listeners = dap_mod._setup_aslr_listeners
M._apply_aslr_fix = dap_mod._apply_aslr_fix
M._android_dap_config = dap_mod._android_dap_config
M._android_preflight_ps1 = dap_mod._android_preflight_ps1
M.android_dap_attach = dap_mod.android_dap_attach
M._android_launch_preflight_ps1 = dap_mod._android_launch_preflight_ps1
M.android_dap_launch = dap_mod.android_dap_launch
M._dap_eval_lldb = dap_mod._dap_eval_lldb
M._dap_make_breakpoint_spec = dap_mod._dap_make_breakpoint_spec
M._dap_try_set_breakpoint = dap_mod._dap_try_set_breakpoint
M._dap_clear_breakpoint = dap_mod._dap_clear_breakpoint
M._dap_filter_scopes = dap_mod._dap_filter_scopes
M.ensure_dap_loaded = dap_mod.ensure_dap_loaded
M.ensure_dapui_loaded = dap_mod.ensure_dapui_loaded
M.dap_toggle_breakpoint = dap_mod.dap_toggle_breakpoint
M.dap_continue = dap_mod.dap_continue
M.dap_pause = dap_mod.dap_pause
M.dap_step_over = dap_mod.dap_step_over
M.dap_step_into = dap_mod.dap_step_into
M.dap_step_out = dap_mod.dap_step_out
M.dap_toggle_ui = dap_mod.dap_toggle_ui
M.dap_reset_layout = dap_mod.dap_reset_layout
M.dap_toggle_repl = dap_mod.dap_toggle_repl
M.dap_diagnose = dap_mod.dap_diagnose
M.setup_dap = dap_mod.setup_dap

-- ==========================================================================
-- SETUP — user commands, autocmds, statusline timer
-- ==========================================================================

function M.setup()
  if CORE_RT.setup_done then
    return
  end
  CORE_RT.setup_done = true

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
    complete = set_platform_completions,
  })
  -- Legacy aliases (thin wrappers → UEPrepare)
  vim.api.nvim_create_user_command("UEExportCompileCommands", prepare_async, {})
  vim.api.nvim_create_user_command("UEGrepGroupingToggle", function()
    -- Default is true; flip the global. Affects subsequent grep picker
    -- invocations (already-open pickers stay as they were).
    vim.g.ue_grep_grouping_enabled = not (vim.g.ue_grep_grouping_enabled ~= false)
    local now = vim.g.ue_grep_grouping_enabled
    vim.notify(
      string.format("UE grep grouping/preview/Tab tweaks: %s",
        now and "ON (default)" or "OFF (vanilla snacks)"),
      vim.log.levels.INFO,
      { title = "UE", timeout = 4000 })
  end, { desc = "Toggle UE grep file-grouping + preview throttle + Tab=list_down" })
  vim.api.nvim_create_user_command("UEGenerateFromRSP", prepare_async, {})
  vim.api.nvim_create_user_command("UEBuild", build_android, {})
  vim.api.nvim_create_user_command("UEBuildAndroid", build_android, {})
  vim.api.nvim_create_user_command("UELaunch", function()
    M.launch_app()
  end, {})
  vim.api.nvim_create_user_command("UELogToggle", function()
    M.toggle_log()
  end, {})
  vim.api.nvim_create_user_command("UEDebugLogToggle", function()
    M.toggle_debug_log()
  end, {})
  vim.api.nvim_create_user_command("UEInstallAndroid", install_android, {})
  vim.api.nvim_create_user_command("UEPrepare", prepare_async, {})
  vim.api.nvim_create_user_command("UEPrepareSync", prepare, {})
  vim.api.nvim_create_user_command("UEIndexStatus", function()
    M.index_status()
  end, {})
  vim.api.nvim_create_user_command("UEIndexNow", function()
    M.index_now()
  end, {})
  vim.api.nvim_create_user_command("UEIndexHot", function()
    M.index_hot()
  end, {})
  vim.api.nvim_create_user_command("UEIndexFull", function()
    M.index_full()
  end, {})
  vim.api.nvim_create_user_command("UECheatsheet", show_cheatsheet, {})
  vim.api.nvim_create_user_command("UECheatsheetEdit", edit_cheatsheet, {})
  vim.api.nvim_create_user_command("UEBuildPCH", function()
    local ctx, err = resolve_context({ detect_project = false })
    if not ctx then
      vim.notify(err, vim.log.levels.WARN)
      return
    end
    local roots = { ctx.engine_root }
    if ctx.project_root then table.insert(roots, ctx.project_root) end
    local bat = nil
    for _, root in ipairs(roots) do
      local candidate = join(root, ".clangd-pch", "build_pch.bat")
      if is_file(candidate) then bat = candidate; break end
    end
    if not bat then
      vim.notify(
        "No build_pch.bat found. Run :UEPrepare first to generate the PCH pipeline.",
        vim.log.levels.WARN
      )
      return
    end
    -- Convert forward → backslash for cmd.exe
    local bat_win = bat:gsub("/", "\\")
    vim.notify("UE: rebuilding PCH (background) — " .. bat_win, vim.log.levels.INFO)
    vim.fn.jobstart({ "cmd.exe", "/c", bat_win }, {
      cwd = vim.fs.dirname(bat),
      detach = false,
      on_stdout = function(_, data)
        for _, line in ipairs(data or {}) do
          if line ~= "" then vim.schedule(function() vim.notify("[UEBuildPCH] " .. line, vim.log.levels.INFO) end) end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data or {}) do
          if line ~= "" then vim.schedule(function() vim.notify("[UEBuildPCH stderr] " .. line, vim.log.levels.WARN) end) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 then
            vim.notify("UE: PCH rebuild OK — restart clangd with :LspRestart", vim.log.levels.INFO)
          else
            vim.notify("UE: PCH rebuild FAILED (exit " .. code .. ")", vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end, { desc = "Rebuild clangd PCH cache (after LLVM/clangd version bump)" })
  vim.api.nvim_create_user_command("UEClearCache", function(cmd_opts)
    clear_cache({ bang = cmd_opts.bang })
  end, { bang = true, desc = "Clear UE caches (! = also clangd index, compile_commands, restart LSP)" })

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
      statusline_timer:start(500, 0, vim.schedule_wrap(refresh_statusline))

      local path = norm(vim.api.nvim_buf_get_name(0))
      if path == "" then
        return
      end
      local lower = path:lower()
      if not (lower:match("%.c$") or lower:match("%.cc$") or lower:match("%.cpp$") or lower:match("%.cxx$") or lower:match("%.h$") or lower:match("%.hh$") or lower:match("%.hpp$") or lower:match("%.hxx$") or lower:match("%.inl$") or lower:match("%.inc$") or lower:match("%.ipp$")) then
        return
      end
      local ctx = resolve_context()
      if not ctx then
        return
      end
      if INDEX_FN.set_active_module(ctx, path) then
        invalidate_status_cache()
        refresh_statusline()
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.c", "*.cc", "*.cpp", "*.cxx", "*.h", "*.hh", "*.hpp", "*.hxx", "*.inl", "*.inc", "*.ipp" },
    callback = function()
      local path = norm(vim.api.nvim_buf_get_name(0))
      if path == "" then
        return
      end
      local ctx = resolve_context()
      if not ctx then
        return
      end
      INDEX_FN.set_active_module(ctx, path)
      if INDEX_FN.mark_module_dirty(ctx, path, "buffer-write") then
        INDEX_FN.schedule_index_refresh(ctx, { current = true, hot = true, current_delay_ms = 150, hot_delay_ms = 2500 })
      end
      invalidate_status_cache()
      refresh_statusline()
    end,
  })
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    pattern = { "*.Build.cs", "*.Target.cs", "*.uproject", "*.uplugin" },
    callback = function()
      local ctx = resolve_context()
      if ctx then
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
