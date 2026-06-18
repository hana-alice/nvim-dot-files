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
  -- csearch build serialization (D9 Policy A): only one csearch build may run
  -- at a time. Every csearch build entry checks this flag and refuses (does NOT
  -- queue) if it is set; the build's completion callback clears it
  -- unconditionally (success AND failure) so a failed build can't wedge it.
  csearch_build_running = false,
  status_cache = {}, -- { key = string, value = string, tick = number }
  dirty_index_roots = {},
  engine_root_cache = {}, -- dir -> engine_root (or false)
  context_cache = {}, -- key -> { ctx, ts }
}
-- ── Trace API (permanently no-op) ────────────────────────────────────────
-- These were used during :UEPrepare main-thread blocking diagnosis. The
-- ccjson stage is now async (see M.async_generate_compile_commands), so the
-- writers are stubbed out. Call sites (~40, mostly in ccjson + shader
-- pipelines) remain as semantic segment markers — readable and zero-cost.
-- To re-enable file logging for a future regression hunt, restore the
-- original lazy-installed implementations from git history at this anchor:
--   git log -p -- lua/ue.lua | grep -n "function CORE_RT.trace_open"
function CORE_RT.trace_open(_label, _log_dir) end
function CORE_RT.trace_seg(_name, fn)
  return fn()
end
function CORE_RT.trace_mark(_name) end
CORE_RT.trace_path = nil
CORE_RT.trace_t0 = nil

local INDEX_FN = {}
-- Phase C: tunables sourced from `ue.config`. Literal fallbacks (`or 120000`
-- etc.) match the previous hard-coded values exactly so behaviour is
-- unchanged when no user override is provided. The fallbacks also keep this
-- chunk loadable if `ue.config` ever fails to require.
local _ue_cfg = require("ue.config")
local INDEX_RT = {
  job = nil,
  module_state = {},
  contexts = {},
  timers = {},
  idle_cold_ms        = _ue_cfg.get("index.idle_cold_ms")        or 120000,
  debounce_current_ms = _ue_cfg.get("index.debounce_current_ms") or 1200,
  debounce_hot_ms     = _ue_cfg.get("index.debounce_hot_ms")     or 8000,
  restart_debounce_s  = _ue_cfg.get("index.restart_debounce_s")  or 45,
  last_restart_at = 0,
  status_cache = {},
  status_ttl          = _ue_cfg.get("index.status_ttl_s")        or 30,
}
local cache_paths
local _CONTEXT_TTL = _ue_cfg.get("context.ttl_s") or 30 -- seconds (filesystem walks are expensive on NTFS)

-- ==========================================================================
-- CORE UTILITIES — paths, files, process, ANSI
-- ==========================================================================
--
-- The path/file/process helpers below were extracted to `lua/ue/core/{fs,proc}`
-- in Phase B of the multi-platform migration. Each helper is rebound here as
-- a `local function` whose body forwards to the extracted module — keeping
-- every existing call site (`norm(...)`, `join(...)`, `_ufs.is_file(...)`, etc.)
-- byte-for-byte equivalent.
--
-- Constraint: a single Lua chunk is capped at 200 locals, and the original
-- file already uses 202 locals (our wrappers re-occupy the same slots the
-- original `local function trim` etc. did, so the count is unchanged). To
-- stay under the cap we DO NOT introduce a top-level `_platform` or `_core`
-- local — module table lookups happen inside each wrapper body where they
-- do not occupy chunk-level slots.

-- Cached module tables (was 17 single-line wrappers; compacted to save LuaJIT local slots).
local _ufs = require("ue.core.fs")
local _uproc = require("ue.core.proc")
local _uplat = require("utils.platform")

-- High-frequency aliases (kept short for readability).
local trim = _ufs.trim
local norm = _ufs.norm
local cwd = _ufs.cwd
local join = _ufs.join


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

-- ==========================================================================
-- CLANGD / LSP
-- ==========================================================================

local function is_native_windows()
  return vim.fn.has("win32") == 1
end

local function clangd_candidates(root_dir)
  local candidates = {}

  -- Phase I priority order:
  --   1. UE_CLANGD env var (legacy, highest)
  --   2. ue.config.clangd.candidates_extra (user setup() override)
  --   3. PATH default + canonical /usr/{local/}bin
  --   4. WSL bridge path when running under /mnt/<drive>/
  --   5. Windows native LLVM install (Program Files)
  local override = trim(vim.env.UE_CLANGD)
  if override ~= "" then
    table.insert(candidates, override)
  end

  do
    local ok, cfg = pcall(require, "ue.config")
    if ok and cfg and cfg.get then
      local extra = cfg.get("clangd.candidates_extra")
      if type(extra) == "table" then
        vim.list_extend(candidates, extra)
      end
    end
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
      if not _ufs.is_absolute_path(file) then
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
  if not _ufs.is_absolute_path(path) and root and root ~= "" then
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
    if candidate and _ufs.is_absolute_path(candidate) then
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
  local clangd = _uproc.first_executable(clangd_candidates(root_dir or cwd())) or "clangd"

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
    "--background-index-priority=background",  -- nice 到最低，editing 不抢 UI 调度
    "-j=" .. tostring(jobs),
    "--completion-style=detailed",
    "--completion-parse=auto",          -- text-based completion while preamble builds
    "--header-insertion=never",
    "--pch-storage=memory",
    "--clang-tidy=false",               -- 显式关 tidy（.clangd 已 Remove '*'，cmdline 兜底防回归）
    "--function-arg-placeholders=true",
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
      if _ufs.is_file(cc_path) then
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
        if _ufs.is_file(idx_path) then
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

  -- Phase I: append user-configured extra clangd args, last so they can
  -- override anything ue.lua chose. Empty default = behaviour unchanged.
  do
    local ok, cfg = pcall(require, "ue.config")
    if ok and cfg and cfg.get then
      local extra = cfg.get("clangd.extra_args")
      if type(extra) == "table" then
        for _, a in ipairs(extra) do
          if type(a) == "string" and a ~= "" then
            table.insert(cmd, a)
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
    if cwd_path ~= "" and _ufs.is_dir(cwd_path) then
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
    if cwd_path ~= "" and _ufs.is_dir(cwd_path) then
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
  _ufs.ensure_dir(_ufs.dirname(path))
  local file, err = io.open(path, "wb")
  if not file then
    require("utils.log").notify_error("ue.io", "write_all failed: " .. (err or path))
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
  _ufs.ensure_dir(_ufs.dirname(path))
  vim.fn.writefile(lines, path)
end

-- ==========================================================================
-- PROJECT DETECTION — uproject, solutions, configurations, engine root
-- ==========================================================================

local function find_uproject_in_dir(dir)
  -- Top-level
  local matches = vim.fn.globpath(dir, "*.uproject", false, true)
  if type(matches) == "table" and #matches > 0 then
    table.sort(matches)
    return norm(matches[1])
  end

  -- P4 workspace fixed layout: <workspace>/Source/Client/*.uproject
  local client_dir = join(dir, "Source", "Client")
  if _ufs.is_dir(client_dir) then
    local m2 = vim.fn.globpath(client_dir, "*.uproject", false, true)
    if type(m2) == "table" and #m2 > 0 then
      table.sort(m2)
      return norm(m2[1])
    end
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
  if project_root == "" or not _ufs.is_dir(project_root) then
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

-- Build/persist the workspace -> .uproject relative-path hint. This lets the
-- user type just the workspace root with `:UESetProject` (e.g. an arbitrary
-- p4 workspace mount point) and have the .uproject located by joining a
-- previously-recorded relative subpath.
--
-- Stored per engine_root in state.json under `uproject_relative_path` (e.g.
-- "Source/Foo/Foo.uproject" -- never hard-coded here, the value comes from
-- whatever the user passes to `:UESetUprojectRelativePath`).
local function set_uproject_relative_path(engine_root, rel)
  rel = norm(trim(rel or ""))
  if rel == "" then
    update_state_field(engine_root, "uproject_relative_path", nil)
    return
  end
  -- Strip leading slashes/backslashes so join() works regardless of input form
  rel = rel:gsub("^[/\\]+", "")
  if not rel:match("%.uproject$") then
    return nil, "uproject_relative_path must end with .uproject"
  end
  update_state_field(engine_root, "uproject_relative_path", rel)
  return rel
end

-- Forward declarations: read_state / update_state_field are defined later
-- (~line 1247/1278) but referenced by resolve_project_input and the
-- set_uproject_relative_path block above. Without these, calls hit the global
-- nil and blow up E5108 ("attempt to call global 'read_state' (a nil value)").
local read_state
local update_state_field

local function resolve_project_input(path, engine_root)
  path = norm(trim(path))
  if path == "" then
    return nil, nil, "Project path not provided"
  end

  -- Reject Windows drive-relative paths like "E:aki/..." (missing slash
  -- after the drive letter). vim.fn.isdirectory() may still resolve them
  -- via the per-drive cwd quirk, but they break downstream UBT/clangd
  -- invocations and confuse is_windows_path(). Force the caller to supply
  -- an absolute path.
  if path:match("^[A-Za-z]:[^\\/]") then
    return nil, nil,
      "Drive-relative path not allowed: " .. path ..
      " (missing slash after drive letter, e.g. use 'E:/aki/...' not 'E:aki/...')"
  end

  if path:match("%.uproject$") then
    if not _ufs.is_file(path) then
      return nil, nil, "Project file not found: " .. path
    end
    return _ufs.dirname(path), path, nil
  end

  if not _ufs.is_dir(path) then
    return nil, nil, "Project directory not found: " .. path
  end

  -- Fast path: .uproject directly inside the dir.
  local uproject = find_uproject_in_dir(path)
  if uproject then
    return path, uproject, nil
  end

  -- Workspace shortcut: <workspace>/<rel> where <rel> was previously taught
  -- via :UESetUprojectRelativePath. Lets the user just type the workspace
  -- mount point. Per-engine_root, so different engines can have different
  -- conventions.
  if engine_root then
    local state = read_state(engine_root)
    local rel = state and state.uproject_relative_path
    if rel and rel ~= "" then
      local candidate = norm(join(path, rel))
      if _ufs.is_file(candidate) then
        return _ufs.dirname(candidate), candidate, nil
      end
      return nil, nil, "Workspace shortcut miss: expected " .. candidate ..
        " (set hint: :UESetUprojectRelativePath, or pass full .uproject)"
    end
  end

  return nil, nil, "Selected directory has no .uproject: " .. path ..
    "\nEither pass the full .uproject path, or run :UESetUprojectRelativePath" ..
    " <relative/path/to.uproject> once so the workspace root works in future."
end

local function detect_project_root_from_path(path)
  path = norm(path)
  if path == "" then
    return nil, nil
  end

  local dir = _ufs.is_file(path) and _ufs.dirname(path) or path
  while dir ~= "" do
    local uproject = find_uproject_in_dir(dir)
    if uproject then
      return dir, uproject
    end
    local parent = _ufs.dirname(dir)
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
    if not _ufs.is_dir(path) then
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

  local start_dir = _ufs.is_file(path) and _ufs.dirname(path) or path
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
    local parent = _ufs.dirname(dir)
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

-- Derive the per-platform cache subdir key from a state table.
-- Same shape as ue.cdb.shards.shard_key ("<Platform>-<Target>-<Config>") but
-- we only have platform + configuration in state (no target), so the key is
-- "<Platform>-<Config>" (config with " Editor" suffix stripped, matching the
-- shard config segment). Returns "" when no platform is set yet → callers
-- fall back to the legacy single-path cache layout.
--
-- Parked on CORE_RT (not a top-level local) to stay under the LuaJIT 200-local
-- cap. Pure function — safe to call from resolve_context / set_platform.
function CORE_RT.platform_key_from_state(state)
  state = state or {}
  local plat = (state.target_platform or ""):gsub("^%s+", ""):gsub("%s+$", "")
  if plat == "" then return "" end
  local conf = (state.target_configuration or ""):gsub("^%s+", ""):gsub("%s+$", "")
  conf = conf:gsub(" Editor$", "")
  if conf == "" then return plat end
  return plat .. "-" .. conf
end

-- Cache layout v3 (2026-05-09):
--   .cache/nvim-ue/                           -- single root, all cache lives here
--     state.json                              -- top-level (scanner-friendly)
--     csearch/<platform_key>/csearch.idx      -- trigram index (per-platform, v3.1)
--     gtags/<platform_key>/                   -- gtags input lists + DB (per-platform, v3.1)
--       workspace/         (GTAGS DB)
--       workspace.files / workspace_all.files / engine.files / project.files
--     (legacy single-path csearch/csearch.idx + gtags/*.files auto-migrated
--      into the active platform_key dir on first resolve — see
--      migrate_legacy_csearch_if_needed)
--     cdb/                                    -- clangd compile-db assets
--       modules.json, queue.json
--       compile_commands/{current,hot,full,inject_full}.json
--     clangd/                                 -- clangd-consumed artifacts (was: $root/.clangd-{index,pch})
--       index/<project>.{idx,current.idx,hot.idx,full.idx}
--       pch/<*.pch + build_pch.bat>
--     logs/                                   -- ue.lua _logged_jobstart sink + indexer logs
--     runtime/dirty.json                      -- watcher persistence
--     legacy/                                 -- pre-v2 holdouts (manual prune)
-- cache_paths(engine_root, platform_key)
--
-- platform_key (optional): a "<Platform>-<Target>-<Config>" string (same shape
-- as ue.cdb.shards.shard_key) used to give csearch + the grep file lists their
-- OWN per-platform subdirectory. Rationale: a user who builds Android then
-- switches to Win64 should keep BOTH csearch indices on disk — switching
-- platform must not wipe the other platform's grep index (matches the cdb
-- shard model). When platform_key is nil/"" we fall back to the legacy
-- single-path layout (csearch/csearch.idx, gtags/workspace_all.files); this
-- preserves backward compat AND is the migration source (see
-- migrate_legacy_csearch_if_needed).
--
-- Only the grep-facing artifacts (csearch index + workspace/project/engine
-- file lists + gtags DB) are sharded by platform. state.json, cdb shards
-- (already platform-keyed internally), clangd index, pch, logs, runtime stay
-- at the single top-level location.
cache_paths = function(engine_root, platform_key)
  local cache = join(engine_root, ".cache", "nvim-ue")
  platform_key = (type(platform_key) == "string" and platform_key ~= "") and platform_key or nil
  -- Per-platform subdir for grep artifacts; legacy single path when no key.
  local csearch_dir = platform_key and join(cache, "csearch", platform_key) or join(cache, "csearch")
  local gtags_root = platform_key and join(cache, "gtags", platform_key) or join(cache, "gtags")
  local cdb_dir = join(cache, "cdb")
  local cdb_files_dir = join(cdb_dir, "compile_commands")
  local logs_dir = join(cache, "logs")
  local runtime_dir = join(cache, "runtime")
  local legacy_dir = join(cache, "legacy")
  local clangd_dir = join(cache, "clangd")
  local active_index_dir = join(clangd_dir, "index")
  local pch_dir = join(clangd_dir, "pch")
  local project_name = vim.fn.fnamemodify(engine_root, ":t")
  return {
    cache = cache,
    state = join(cache, "state.json"),
    platform_key = platform_key,
    -- gtags (per-platform when platform_key set)
    gtags_root = gtags_root,
    project_list = join(gtags_root, "project.files"),
    engine_list = join(gtags_root, "engine.files"),
    workspace_list = join(gtags_root, "workspace.files"),
    workspace_all_list = join(gtags_root, "workspace_all.files"),
    workspace_db = join(gtags_root, "workspace"),
    -- csearch (per-platform when platform_key set)
    csearch_dir = csearch_dir,
    csearch_idx = join(csearch_dir, "csearch.idx"),
    -- cdb (was: index/)
    index_dir = cdb_dir,                   -- back-compat alias
    index_state = join(cdb_dir, "modules.json"),
    index_queue = join(cdb_dir, "queue.json"),
    index_cdb_dir = cdb_files_dir,
    index_current_cdb = join(cdb_files_dir, "current.json"),
    index_hot_cdb = join(cdb_files_dir, "hot.json"),
    index_full_cdb = join(cdb_files_dir, "full.json"),
    index_inject_full_cdb = join(cdb_files_dir, "inject_full.json"),
    -- logs / runtime / legacy
    logs_dir = logs_dir,
    runtime_dir = runtime_dir,
    dirty_json = join(runtime_dir, "dirty.json"),
    legacy_dir = legacy_dir,
    -- clangd-consumed artifacts (.idx + .pch). v3 collapses these under
    -- .cache/nvim-ue/clangd/ instead of two separate top-level dirs.
    clangd_dir = clangd_dir,
    active_index_dir = active_index_dir,
    active_index = join(active_index_dir, project_name .. ".idx"),
    current_index = join(active_index_dir, project_name .. ".current.idx"),
    hot_index = join(active_index_dir, project_name .. ".hot.idx"),
    full_index = join(active_index_dir, project_name .. ".full.idx"),
    pch_dir = pch_dir,
    pch_build_bat = join(pch_dir, "build_pch.bat"),
  }
end

-- Migrate the legacy single-path csearch + gtags caches into the active
-- per-platform subdir (v3.1). Parallels ue.cdb.shards.migrate_legacy_if_needed.
--
-- Before v3.1 grep caches lived at csearch/csearch.idx and gtags/*.files.
-- v3.1 shards them by platform_key (csearch/<key>/, gtags/<key>/). On first
-- resolve with a known platform_key, if the new subdir is empty but the old
-- flat files exist, MOVE them in (so the existing index isn't thrown away and
-- the user doesn't have to rerun :UEPrepare just because we changed layout).
--
-- Idempotent: once moved, the legacy files are gone so subsequent calls no-op.
-- A no-platform session (platform_key == "") uses the legacy path directly and
-- never migrates. Parked on CORE_RT to stay under the LuaJIT local cap.
function CORE_RT.migrate_legacy_csearch_if_needed(engine_root, platform_key)
  if not platform_key or platform_key == "" then return false end
  local legacy = cache_paths(engine_root)            -- platform_key=nil → flat layout
  local active = cache_paths(engine_root, platform_key)
  local moved = false

  local function move_if(src, dst)
    if not src or not dst or src == dst then return end
    if _ufs.is_file(src) and not _ufs.is_file(dst) then
      _ufs.ensure_dir(_ufs.dirname(dst))
      -- os.rename works within the same volume (cache always lives under one
      -- engine_root, so src/dst share a drive). Fall back to copy+remove only
      -- if rename fails (defensive; shouldn't happen on same volume).
      local ok = pcall(os.rename, src, dst)
      if not ok then
        local data = nil
        local f = io.open(src, "rb")
        if f then data = f:read("*a"); f:close() end
        if data then
          local o = io.open(dst, "wb")
          if o then o:write(data); o:close(); pcall(os.remove, src); ok = true end
        end
      end
      if ok then moved = true end
    end
  end

  -- csearch index (+ cindex tmp staging siblings)
  move_if(legacy.csearch_idx, active.csearch_idx)
  move_if(legacy.csearch_idx .. "~", active.csearch_idx .. "~")
  move_if(legacy.csearch_idx .. "~~", active.csearch_idx .. "~~")
  -- grep file lists
  move_if(legacy.project_list, active.project_list)
  move_if(legacy.engine_list, active.engine_list)
  move_if(legacy.workspace_list, active.workspace_list)
  move_if(legacy.workspace_all_list, active.workspace_all_list)
  -- gtags DB files
  for _, name in ipairs({ "GTAGS", "GPATH", "GRTAGS" }) do
    move_if(join(legacy.workspace_db, name), join(active.workspace_db, name))
  end

  return moved
end

read_state = function(engine_root)
  local paths = cache_paths(engine_root)
  if not _ufs.is_file(paths.state) then
    return {}
  end

  local ok, decoded = pcall(vim.json.decode, table.concat(vim.fn.readfile(paths.state), "\n"))
  if not ok or type(decoded) ~= "table" then
    return {}
  end

  if decoded.project_root then
    decoded.project_root = norm(decoded.project_root)
  end
  if decoded.engine_root then
    decoded.engine_root = norm(decoded.engine_root)
  end
  return decoded
end

local function persist_project(engine_root, project_root, uproject)
  local paths = cache_paths(engine_root)
  _ufs.ensure_dir(paths.cache)

  -- Merge into existing state to preserve extra fields (android_package, etc.)
  local existing = read_state(engine_root)
  existing.project_root = norm(project_root)
  -- Persist engine_root too. Without it the "did the engine change?"
  -- invalidation dimension has no on-disk anchor (engine_root used to be
  -- re-derived from the buffer every session, so a project pinned against a
  -- DIFFERENT engine could silently reuse stale caches). cache_paths is keyed
  -- by engine_root, so the engine that owns this state.json IS engine_root.
  existing.engine_root = norm(engine_root)
  existing.uproject = uproject and norm(uproject) or nil
  existing.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")

  write_all(paths.state, vim.json.encode(existing))
  return existing
end

update_state_field = function(engine_root, key, value)
  local paths = cache_paths(engine_root)
  _ufs.ensure_dir(paths.cache)
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
    state_project_root, state_uproject = resolve_project_input(state.project_root, engine_root)
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
      if candidate ~= "" and _ufs.path_has_prefix(candidate, state_project_root) then
        project_root = state_project_root
        uproject = state_uproject
        break
      end
    end
  end

  -- Fallback: when no buffer is open (dashboard / fresh nvim) and cwd is
  -- the engine root itself, the prefix check above can't possibly match
  -- (engine_root path will never be inside project_root, and the empty
  -- buffer name fails the `candidate ~= ""` guard). In this case the
  -- user has already explicitly run :UESetProject earlier — trust it.
  -- Without this, :UEBuild / :UEStatus etc all error with "No project
  -- configured" right after `z unrealen` until the user opens a project
  -- source file, which is surprising UX.
  --
  -- Extended fallback: when the user is browsing engine source (cwd or
  -- buffer is inside engine_root) and didn't auto-detect a project from
  -- the buffer path either, also trust state.project_root. Typical case:
  -- `z unrealen` (UnrealEngine bare engine repo, no .uproject anywhere
  -- nearby) + browsing Renderer/Engine sources to build a game project
  -- pinned earlier via :UESetProject pointing to a different drive.
  if not project_root and state_project_root then
    local has_real_buffer = cur_buf ~= "" and cur_buf ~= cur_cwd
    if not has_real_buffer then
      project_root = state_project_root
      uproject = state_uproject
    else
      local cwd_in_engine = cur_cwd ~= "" and _ufs.path_has_prefix(cur_cwd, engine_root)
      local buf_in_engine = cur_buf ~= "" and _ufs.path_has_prefix(cur_buf, engine_root)
      if cwd_in_engine or buf_in_engine then
        project_root = state_project_root
        uproject = state_uproject
      end
    end
  end

  local platform_key = CORE_RT.platform_key_from_state(state)
  -- v3.1: migrate legacy single-path grep caches into the active platform
  -- subdir once, so an existing index survives the layout change.
  if platform_key ~= "" then
    pcall(CORE_RT.migrate_legacy_csearch_if_needed, engine_root, platform_key)
  end
  local paths = cache_paths(engine_root, platform_key)
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
  -- GTAGS owns clangd's complement — see M.FT_GTAGS comment for rationale.
  return filter_extensions(paths, M.FT_GTAGS)
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
  "Engine/Config",
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

-- GTAGS-only exclusions: applied AFTER GTAGS_EXCLUDE_SUBSTRINGS, only to
-- the gtags input list. csearch / file picker / workspace_all are NOT
-- affected — those still see ThirdParty so the user can still grep into
-- them. Currently empty because FT_GTAGS is shader-only and shaders
-- under ThirdParty are negligible (see ue.lua FT_GTAGS comment).
-- Pre-populated patterns kept for the day we re-add cs/py to FT_GTAGS.
UE_CONST.GTAGS_ONLY_EXCLUDE_SUBSTRINGS = {
  "/ThirdParty/Python",
  "/site-packages/",
  "/Win64/Lib/",
  "/Linux/Lib/",
  "/Mac/Lib/",
  "/ThirdParty/",
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

-- Excludes for :UEPrepare's full-tree scan (gtags / clangd / csearch feed).
-- Diverges from PICKER_EXCLUDES in two ways:
--   1. ThirdParty is KEPT (we want to grep into vendored ThirdParty sources).
--   2. node_modules / obj / bin are added (these are pure cache trees that
--      regularly hit hundreds of thousands of files in shipped UE projects
--      that ship JS/TS tooling + .NET helpers alongside Source/).
-- Content is excluded mandatorily — it holds .uasset/.umap/.wem/.bnk binary
-- assets only, never anything clangd/gtags/csearch needs.
UE_CONST.SCAN_EXCLUDES = {
  ".git",
  ".vs",
  "Binaries",
  "Content",
  "DerivedDataCache",
  "Intermediate",
  "Saved",
  "node_modules",
  "obj",
  "bin",
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

-- Extensions GTAGS owns: clangd's complement.
-- C/C++ (.h/.cpp/...) is intentionally excluded — clangd already provides
-- richer goto/refs for those files. GTAGS only needs to cover what clangd
-- does NOT handle: shaders + glue/build languages.
--
-- Why .cs/.py: Build.cs / Target.cs / engine Python tooling are jumped to
-- often during UE feature porting and clangd has no parser for either.
-- Why .lua + .uproject/.uplugin omitted: low symbol density, ad-hoc grep
-- via :UEGrep is faster than maintaining tags.
-- Files where gtags is the primary indexer (because clangd can't help).
-- Strictly limited to shaders: GNU Global on Windows ships without a
-- self-contained language parser — its plug-in stub spawns an external
-- `ctags` for languages the bundled DLL doesn't natively handle. We
-- can route .usf/.ush/.hlsl/.hlsli through the C++ langmap (validated:
-- 100% definition-jump hit rate, zero deps), but .cs/.py would force
-- a hard dependency on a separately-installed ctags.exe.
--
-- For .cs (Build.cs/Target.cs) and .py the user falls back to csearch
-- grep — adequate during day-to-day porting. If we ever add the
-- universal-ctags binary to dev machines, extend this list.
M.FT_GTAGS = vim.list_extend({}, M.FT_SHADER)

-- Globs (for rg -g / grep picker)
M.GLOBS_CODE = vim.tbl_map(function(ext) return "*." .. ext end, M.FT_CODE)
M.GLOBS_ALL = vim.tbl_map(function(ext) return "*." .. ext end, M.FT_ALL)

-- ==========================================================================
-- FILE SCANNING + GTAGS DATABASE
-- ==========================================================================

local function existing_relative_dirs(root, search_paths)
  local dirs = {}
  for _, search_path in ipairs(search_paths or {}) do
    if _ufs.is_dir(join(root, search_path)) then
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

-- GTAGS-only filter: chained AFTER filter_gtags_paths, ONLY for the
-- gtags input list. Keeps ThirdParty visible to csearch / file picker
-- while preventing wall-clock blowup when indexing the workspace tree.
local function filter_gtags_only_paths(paths)
  local filtered = {}
  for _, path in ipairs(paths or {}) do
    local normalized = norm(path)
    local excluded = false
    for _, pattern in ipairs(UE_CONST.GTAGS_ONLY_EXCLUDE_SUBSTRINGS) do
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
    if path ~= "" and _ufs.is_dir(path) and not seen[path] then
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
  if not _ufs.path_has_prefix(path, plugins_root) then
    return nil
  end

  local parts = _ufs.split_path(_ufs.relative_to(plugins_root, path))
  if #parts == 0 then
    return nil
  end

  local plugin_root = join(plugins_root, parts[1])
  if not _ufs.is_dir(plugin_root) then
    return nil
  end

  return {
    kind = "plugin",
    name = parts[1],
    root = plugin_root,
    label = "Plugin " .. parts[1],
  }
end

-- Resolve where project modules / plugins actually live, given only the
-- workspace root the user supplied via :UESetProject.
--
-- Two layouts are supported:
--   1. Standard:    <project_root>/<Project>.uproject
--                   modules in <project_root>/Source/<Module>/
--                   plugins in <project_root>/Plugins/
--   2. P4 nested:   <project_root>/Source/<Project>/<Project>.uproject
--                   modules in <project_root>/Source/<Project>/Source/<Module>/
--                   plugins in <project_root>/Source/<Project>/Plugins/
--
-- Detection rule: if exactly one .uproject exists at <project_root>/Source/*/
-- we adopt nested layout, anchored at that .uproject's directory. Otherwise
-- we fall back to project_root (standard layout). Result is cached per
-- project_root so we glob disk at most once per workspace per session.
--
-- Parked on CORE_RT (not as top-level locals) because ue.lua is at the
-- LuaJIT 200-local cap. See skill luajit-200-local-cap-with-loader-cache-mask.
CORE_RT.project_module_anchor_cache = CORE_RT.project_module_anchor_cache or {}

function CORE_RT.project_module_anchor(project_root)
  project_root = norm(project_root or "")
  if project_root == "" then
    return ""
  end
  local cached = CORE_RT.project_module_anchor_cache[project_root]
  if cached ~= nil then
    return cached
  end

  local anchor = project_root
  local nested = vim.fn.globpath(join(project_root, "Source"), "*/*.uproject", false, true)
  if type(nested) == "table" and #nested == 1 then
    anchor = norm(_ufs.dirname(nested[1]))
  end

  CORE_RT.project_module_anchor_cache[project_root] = anchor
  return anchor
end

-- Project-specific scan whitelist. Path = `<project_root>/.ueprepare-scan-paths`,
-- one entry per line, # for comments. Each entry is a root-relative directory
-- (e.g. `Source/Client/Source`, `Source/Protocol`). When the file exists, it
-- REPLACES UE_CONST.PROJECT_INDEX_DIRS for this project. When absent, the
-- default PROJECT_INDEX_DIRS is used (legacy behavior).
--
-- Why whitelist > blacklist (.ueprepare-scan-ignore was deleted): some
-- projects bury non-source data (config tables, SDK toolchains, art assets)
-- under `Source/`. Blacklist plays whack-a-mole; whitelist is declarative
-- and cuts scan input dramatically (verified 877k -> 116k on aki_dev).
--
-- Cached per-project on CORE_RT to avoid repeated disk reads. Use
-- :UEReloadScanPaths to invalidate (see command below).
CORE_RT.project_index_dirs_cache = CORE_RT.project_index_dirs_cache or {}

function CORE_RT.project_index_dirs(ctx)
  local project_root = ctx and ctx.project_root or nil
  if not project_root or project_root == "" then
    return UE_CONST.PROJECT_INDEX_DIRS
  end
  local cached = CORE_RT.project_index_dirs_cache[project_root]
  if cached ~= nil then
    return cached
  end

  local dirs = nil
  local f = io.open(project_root .. "/.ueprepare-scan-paths", "r")
  if f then
    dirs = {}
    for line in f:lines() do
      local s = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
      s = s:gsub("%s+#.*$", "")
      if s ~= "" and not s:match("^#") then
        table.insert(dirs, s)
      end
    end
    f:close()
    if #dirs == 0 then dirs = nil end -- empty file -> fall back to default
  end

  local result = dirs or UE_CONST.PROJECT_INDEX_DIRS
  CORE_RT.project_index_dirs_cache[project_root] = result
  return result
end

local function project_module_scope(project_root, path)
  project_root = norm(project_root)
  path = norm(path)
  if project_root == "" then
    return nil
  end

  local source_root = join(CORE_RT.project_module_anchor(project_root), "Source")
  if not _ufs.path_has_prefix(path, source_root) then
    return nil
  end

  local parts = _ufs.split_path(_ufs.relative_to(source_root, path))
  if #parts == 0 then
    return nil
  end

  local module_root = join(source_root, parts[1])
  if not _ufs.is_dir(module_root) then
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
  if not _ufs.path_has_prefix(path, source_root) then
    return nil
  end

  local parts = _ufs.split_path(_ufs.relative_to(source_root, path))
  if #parts < 2 then
    return nil
  end

  local module_root = join(source_root, parts[1], parts[2])
  if not _ufs.is_dir(module_root) then
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
  if not _ufs.is_file(path) then
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

-- Reverse-map a unity TU path back to the originating module name.
-- UBT emits unity .cpp files at:
--   <root>/Intermediate/Build/<Plat>/<Target>/<Conf>/[<PlatGroup>/]<Module>/Module.<Module>[.gen][.N_of_M].cpp
-- where <root> is Engine/, the project root, or a plugin/platform plugin root.
-- Returns the bare module name (e.g. "AIGraph", "AIModule") or nil.
local function unity_tu_module_name(path)
  if not path or path == "" then
    return nil
  end
  if not path:find("/Intermediate/Build/", 1, true) then
    return nil
  end
  local raw = path:match("/Module%.([^/]+)%.cpp$")
  if not raw then
    return nil
  end
  -- Strip "N_of_M" slice suffix (any trailing ".<digits>_of_<digits>")
  raw = raw:gsub("%.%d+_of_%d+$", "")
  -- Strip ".gen" UHT suffix
  raw = raw:gsub("%.gen$", "")
  if raw == "" then
    return nil
  end
  return raw
end

-- name -> resolved root cache, populated on demand. Keyed by
-- "engine_root|project_root|name" so multiple workspaces don't collide.
local UNITY_MODULE_ROOT_CACHE = {}

local function unity_locate_module_root(engine_root, project_root, name)
  if not name or name == "" then
    return nil
  end
  local key = (engine_root or "") .. "|" .. (project_root or "") .. "|" .. name
  local cached = UNITY_MODULE_ROOT_CACHE[key]
  if cached ~= nil then
    if cached == false then
      return nil
    end
    return cached
  end

  local function check(candidate)
    candidate = norm(candidate)
    if candidate ~= "" and _ufs.is_dir(candidate) then
      return candidate
    end
    return nil
  end

  -- 1) Engine/Source/<Tier>/<Module>
  local hit = locate_engine_module_root(engine_root, name)

  -- 2) Engine plugin: Engine/Plugins/**/<Module>/Source/<Module>
  if not hit and engine_root and engine_root ~= "" then
    local matches = vim.fn.globpath(
      join(engine_root, "Engine", "Plugins"),
      "**/" .. name .. "/Source/" .. name,
      false,
      true
    )
    if type(matches) == "table" then
      for _, m in ipairs(matches) do
        hit = check(m)
        if hit then break end
      end
    end
  end

  -- 3) Engine platforms plugin: Engine/Platforms/*/Plugins/**/<Module>/Source/<Module>
  if not hit and engine_root and engine_root ~= "" then
    local matches = vim.fn.globpath(
      join(engine_root, "Engine", "Platforms"),
      "*/Plugins/**/" .. name .. "/Source/" .. name,
      false,
      true
    )
    if type(matches) == "table" then
      for _, m in ipairs(matches) do
        hit = check(m)
        if hit then break end
      end
    end
  end

  -- 4) Project module: <anchor>/Source/<Module>
  --    Anchor = CORE_RT.project_module_anchor(project_root). Equals project_root
  --    for standard layouts; equals <project_root>/Source/<ProjectName> for the
  --    P4 nested layout where the .uproject lives one level deeper.
  local project_anchor = project_root and project_root ~= "" and CORE_RT.project_module_anchor(project_root) or nil
  if not hit and project_anchor then
    hit = check(join(project_anchor, "Source", name))
  end

  -- 5) Project plugin: <anchor>/Plugins/**/<Module>/Source/<Module>
  if not hit and project_anchor then
    local matches = vim.fn.globpath(
      join(project_anchor, "Plugins"),
      "**/" .. name .. "/Source/" .. name,
      false,
      true
    )
    if type(matches) == "table" then
      for _, m in ipairs(matches) do
        hit = check(m)
        if hit then break end
      end
    end
  end

  UNITY_MODULE_ROOT_CACHE[key] = hit or false
  return hit
end

local function unity_scope_for_path(ctx, path)
  local name = unity_tu_module_name(path)
  if not name then
    return nil
  end
  local root = unity_locate_module_root(ctx.engine_root, ctx.project_root, name)
  if not root then
    return nil
  end
  -- Detect plugin vs module by whether root sits under any /Plugins/ chain
  local kind = "module"
  if norm(root):find("/Plugins/", 1, true) then
    kind = "plugin"
  end
  return {
    kind = kind,
    name = name,
    root = root,
    label = (kind == "plugin" and "Plugin " or "Module ") .. name,
  }
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
    or unity_scope_for_path(ctx, path)
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
      if _ufs.is_dir(candidate) then
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
  _ufs.ensure_dir(ctx.paths.index_dir)
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
  if _ufs.is_file(path) then
    return path
  end
  path = join(ctx.engine_root, "Engine", "compile_commands.json")
  if _ufs.is_file(path) then
    return path
  end
  return nil
end

-- CDB partition by (platform, config) -- see docs/changelog.md 2026-05-28 (#5)
-- UBT's compile_commands.json accumulates entries from every config + platform
-- that has ever been built in this checkout. clangd then walks all those
-- per-config -include Definitions.<Module>.h headers when servicing `gd` on
-- macros like UE_BUILD_DEVELOPMENT, jumping to whichever config's generated
-- header happens to be in the CDB (often a stale Dev one from days ago, even
-- though the current build is Test).
--
-- Fix: after every :UEPrepare we shell out to tools/cdb_partition.py, which
-- splits the base CDB into per-(plat, cfg) files under
-- <repo>/.cache/nvim-ue/cdb/active/compile_commands.<plat>-<cfg>.json and
-- rewrites the base to contain ONLY the active group + shaders. Active group
-- is auto-picked (largest cmd count) unless the caller passes an explicit
-- "Platform/Config" pair, e.g. :UECDBSwitch Win64 Development.
--
-- Pipeline placement: invoked right after run_compile_commands_pipeline (which
-- expands rsps / injects defs / unifies includes) and BEFORE
-- INDEX_FN.schedule_index_refresh -- so the per-phase subset CDBs and the
-- clangd-indexer feed all see the already-partitioned base. Failure here is
-- non-fatal: we surface a WARN and leave the base CDB untouched (clangd
-- continues to work, just with the old multi-group mix).
INDEX_FN.partition_base_cdb = function(ctx, opts)
  opts = opts or {}
  local base = INDEX_FN.base_compile_commands_path(ctx)
  if not base then
    return false, "no base compile_commands.json"
  end

  local nvim_root = vim.fn.fnamemodify(vim.fn.stdpath("config"), ":p")
  local script = join(nvim_root, "tools", "cdb_partition.py")
  if not _ufs.is_file(script) then
    return false, "cdb_partition.py missing at " .. script
  end

  -- Reuse the same Python probe sequence used elsewhere in this file for the
  -- ccjson / pch subprocesses (Python 3.12 absolute path on Windows to dodge
  -- PYTHONHOME contamination from outer shells).
  local python
  if _uplat.is_windows then
    local cands = {
      vim.env.UE_PYTHON,
      vim.fn.expand("~/AppData/Local/Programs/Python/Python312/python.exe"),
      vim.fn.expand("~/AppData/Local/Programs/Python/Python313/python.exe"),
      "C:/Python312/python.exe",
      "C:/Python313/python.exe",
    }
    for _, c in ipairs(cands) do
      if c and c ~= "" and _ufs.is_file(c) then python = c; break end
    end
    python = python or "python"
  else
    python = "python3"
  end

  local cmd = { python, script, base }
  if opts.active then
    table.insert(cmd, "--active")
    table.insert(cmd, opts.active)
  end
  if opts.out_dir then
    table.insert(cmd, "--out-dir")
    table.insert(cmd, opts.out_dir)
  end

  -- Scrub PYTHONPATH/PYTHONHOME (same reason as the ccjson subprocess).
  local env = vim.fn.environ()
  env.PYTHONPATH = nil
  env.PYTHONHOME = nil
  local env_list = {}
  for k, v in pairs(env) do
    table.insert(env_list, k .. "=" .. v)
  end

  local result = vim.system(cmd, { env = env_list, text = true, timeout = 120000 }):wait()
  if result.code == 0 then
    return true, (result.stdout or ""):gsub("%s+$", "")
  end
  if result.code == 3 then
    -- "no classifiable groups" -- single-config CDB, nothing to do.
    return true, "single-group CDB, no partition needed"
  end
  local msg = ("cdb_partition exit=%d stderr=%s"):format(
    result.code or -1,
    (result.stderr or ""):gsub("%s+$", ""))
  return false, msg
end

-- Read the partition manifest to know what groups exist + which is active.
-- Returns nil if no manifest (CDB never partitioned yet).
INDEX_FN.read_partition_manifest = function(ctx)
  local base = INDEX_FN.base_compile_commands_path(ctx)
  if not base then return nil end
  local mf_path = vim.fn.fnamemodify(base, ":h") .. "/compile_commands.partition.json"
  if not _ufs.is_file(mf_path) then return nil end
  local content = read_all(mf_path)
  if not content or content == "" then return nil end
  local ok, mf = pcall(vim.json.decode, content)
  if not ok or type(mf) ~= "table" then return nil end
  return mf, mf_path
end

INDEX_FN.normalize_cdb_file = function(entry)
  if type(entry) ~= "table" then
    return ""
  end
  local file = norm(entry.file or "")
  local dir = norm(entry.directory or "")
  if file ~= "" and not _ufs.is_absolute_path(file) and dir ~= "" then
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
  _ufs.ensure_dir(ctx.paths.index_cdb_dir)
  write_json_file(out_cdb, subset)
  return out_cdb, selected_keys, nil
end

INDEX_FN.maybe_restart_clangd_for_index = function()
  local now = unix_now()
  if (now - INDEX_RT.last_restart_at) < INDEX_RT.restart_debounce_s then
    return
  end
  INDEX_RT.last_restart_at = now

  -- Snapshot which buffers had clangd attached BEFORE we stop, so we can
  -- explicitly re-attach to each of them. The previous version only ran
  -- `:edit` on the *current* buffer, which silently no-op'd whenever the
  -- user was sitting in a picker / log / non-cpp buffer when the index
  -- finished. clangd then stayed dead until the user noticed `gd` was slow,
  -- by which time goto-def was falling back to treesitter or nothing.
  local clients = vim.lsp.get_clients({ name = "clangd" })
  if #clients == 0 then
    return
  end

  local cpp_bufs = {}
  for _, client in ipairs(clients) do
    for buf, _ in pairs(client.attached_buffers or {}) do
      if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
        cpp_bufs[buf] = true
      end
    end
    client:stop()
  end

  -- Also include any cpp/c/h buffers that exist but weren't attached (e.g.
  -- a fresh open during the restart window) — better to over-restart than
  -- miss them.
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(b) then
      local ft = vim.bo[b].filetype
      if ft == "cpp" or ft == "c" or ft == "h" or ft == "objcpp" or ft == "objc" then
        cpp_bufs[b] = true
      end
    end
  end

  vim.defer_fn(function()
    for buf, _ in pairs(cpp_bufs) do
      if vim.api.nvim_buf_is_valid(buf) then
        pcall(vim.api.nvim_buf_call, buf, function()
          vim.cmd("LspStart clangd")
        end)
      end
    end
  end, 500)
end

INDEX_FN.promote_active_index = function(ctx, src_path)
  src_path = norm(src_path)
  if src_path == "" or not _ufs.is_file(src_path) then
    return false
  end
  _ufs.ensure_dir(ctx.paths.active_index_dir)
  local content = read_all(src_path)
  if not content or content == "" then
    return false
  end
  return write_all(ctx.paths.active_index, content)
end

-- Keep `<engine_root>/.clangd`'s `Index.External.File` /
-- `Index.External.MountPoint` lines in sync with the authoritative
-- `cache_paths(engine_root).active_index` path. Called from the success
-- branch of build_phase_async right after promote_active_index, before
-- the LspRestart, so the restarted clangd reads the corrected file.
--
-- Surgical: only the `Index.External.{File,MountPoint}` keys are touched
-- (or an `Index:` block is appended if absent). All other content
-- (CompileFlags `/vctoolsdir` MSVC pin, Diagnostics, comments, etc.)
-- is preserved byte-for-byte. Idempotent: re-running with the same
-- paths is a no-op (no write, no clangd restart amplification).
--
-- Why this lives here: the v3 cache migration moved idx from
-- `<root>/.clangd-index/` to `<root>/.cache/nvim-ue/clangd/index/`, but
-- nobody rewrote existing `.clangd` files. Result: clangd silently fell
-- back to `--background-index`, burning 17 GB RAM / 32 min CPU per cold
-- open. The hot/full/current pipeline is now responsible for keeping
-- `.clangd` honest.
INDEX_FN.sync_dot_clangd = function(ctx)
  if not ctx or not ctx.engine_root or ctx.engine_root == "" then
    return false, "no engine_root"
  end
  local idx_path = ctx.paths and ctx.paths.active_index
  if not idx_path or idx_path == "" then
    return false, "no active_index path"
  end
  local clangd_path = ctx.engine_root .. "/.clangd"

  -- Native-slashes on Windows for consistency with how UBT writes paths
  -- elsewhere in the cdb. clangd accepts both, but pinning one form lets
  -- a textual diff stay clean across runs.
  local function native(p)
    if _uplat.is_windows then
      return (p:gsub("/", "\\"))
    end
    return p
  end
  local want_file = native(idx_path)
  local want_mount = native(ctx.engine_root)

  local existing = ""
  if _ufs.is_file(clangd_path) then
    existing = read_all(clangd_path) or ""
  end

  local new_content
  if existing == "" then
    -- No .clangd at all → write a minimal one. Background: Skip is
    -- required since we have an external idx and don't want clangd
    -- redoing the work.
    new_content = table.concat({
      "Index:",
      "  External:",
      "    File: " .. want_file,
      "    MountPoint: " .. want_mount,
      "  Background: Skip",
      "",
    }, "\n")
  else
    -- Find Index: block. If present, edit its External sub-block in place.
    -- If absent, append a fresh Index: block.
    local has_index = existing:match("\n?Index:%s*\n") or existing:match("^Index:%s*\n")
    if has_index then
      -- Replace `    File: ...` / `    MountPoint: ...` lines under
      -- `  External:` if present; inject an External: sub-block if not.
      local has_external = existing:match("\n%s*External:%s*\n") or existing:match("^%s*External:%s*\n")
      if has_external then
        -- gsub a single line at a time: tolerate any leading-whitespace
        -- indent, replace the trailing value.
        local edited = existing
        -- File: ...
        local file_replaced
        edited, file_replaced = edited:gsub("(\n%s*External:[^\n]*\n[^\n]-\n?)(%s*)File:%s*[^\n]*", function(prefix, indent)
          return prefix .. indent .. "File: " .. want_file
        end, 1)
        if file_replaced == 0 then
          -- External: existed but had no File: line; inject after External:
          edited = edited:gsub("(\n)(%s*)External:%s*\n", function(nl, indent)
            return nl .. indent .. "External:\n" .. indent .. "  File: " .. want_file .. "\n" .. indent .. "  MountPoint: " .. want_mount .. "\n"
          end, 1)
        else
          -- MountPoint: ...
          local mp_replaced
          edited, mp_replaced = edited:gsub("(\n%s*External:[^\n]*\n[^\n]-\n?)(%s*)MountPoint:%s*[^\n]*", function(prefix, indent)
            return prefix .. indent .. "MountPoint: " .. want_mount
          end, 1)
          if mp_replaced == 0 then
            -- File: was replaced but no MountPoint: line; inject right after File:
            edited = edited:gsub("(%s*)File:%s*" .. want_file:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"), function(indent)
              return indent .. "File: " .. want_file .. "\n" .. indent .. "MountPoint: " .. want_mount
            end, 1)
          end
        end
        new_content = edited
      else
        -- Index: exists but no External: sub-block. Inject one right
        -- after the Index: header line.
        new_content = existing:gsub("(\n?)(Index:%s*\n)", function(nl, hdr)
          return nl .. hdr .. "  External:\n    File: " .. want_file .. "\n    MountPoint: " .. want_mount .. "\n  Background: Skip\n"
        end, 1)
      end
    else
      -- No Index: block at all. Append one at EOF, separated by a blank line.
      local sep = (existing:sub(-1) == "\n") and "" or "\n"
      new_content = existing .. sep .. "\nIndex:\n  External:\n    File: " .. want_file .. "\n    MountPoint: " .. want_mount .. "\n  Background: Skip\n"
    end
  end

  if new_content == existing then
    return true, "unchanged"
  end

  -- Atomic write: tmp + rename. NTFS rename is atomic; clangd never sees
  -- a half-written file mid-read.
  local tmp_path = clangd_path .. ".tmp." .. tostring(vim.uv.hrtime())
  local ok = write_all(tmp_path, new_content)
  if not ok then
    pcall(vim.fn.delete, tmp_path)
    return false, "tmp write failed"
  end
  local rn_ok, rn_err = (vim.uv or vim.loop).fs_rename(tmp_path, clangd_path)
  if not rn_ok then
    pcall(vim.fn.delete, tmp_path)
    return false, "rename failed: " .. tostring(rn_err)
  end
  return true, "updated"
end

INDEX_FN.build_phase_async = function(ctx, phase)
  local state = ensure_index_state(ctx)
  local root_key = status_root_key(ctx)
  if INDEX_RT.job then
    state.queue[phase] = unix_now()
    save_index_state(ctx, state)
    return false, "busy"
  end

  -- Phase split:
  --   full       → build_full_cdb.py (single entry: rsp + inject + super-unity
  --                 sidecar + clangd-indexer). Operates on the engine-root
  --                 base CDB directly; no per-module subset because full == all.
  --   hot/current → build_clangd_index.py with a per-module subset CDB
  --                 (per-file entries only — small N, super-unity overhead
  --                 not worth it).
  local subset_cdb, selected_keys, err
  if phase == "full" then
    selected_keys = {}  -- full has no per-module selection; #selected_keys == 0 is fine
    local base = INDEX_FN.base_compile_commands_path(ctx)
    if not base then
      err = "base compile_commands.json not found at engine root"
    else
      subset_cdb = base  -- build_full_cdb.py reads/writes this in place
    end
  else
    subset_cdb, selected_keys, err = INDEX_FN.write_subset_compile_commands(ctx, phase)
  end
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

  -- Pin to Python 3.12 absolute path on Windows: relying on PATH `python`
  -- bites us when an outer shell (hermes-aux, uv, conda) injects PYTHONHOME
  -- pointing at a different minor (3.11/3.14) — child explodes with
  -- `_sre.MAGIC mismatch` from the stdlib loader. Absolute path + scrubbed
  -- env is the only reliable combo.
  local python
  if _uplat.is_windows then
    -- Probe well-known per-user / system Python 3.12 install locations.
    -- Falls back to PATH `python` if nothing matches (caller can override
    -- via UE_PYTHON env var for non-standard installs).
    local candidates = {
      vim.env.UE_PYTHON,
      vim.fn.expand("~/AppData/Local/Programs/Python/Python312/python.exe"),
      vim.fn.expand("~/AppData/Local/Programs/Python/Python313/python.exe"),
      "C:/Python312/python.exe",
      "C:/Python313/python.exe",
    }
    for _, p in ipairs(candidates) do
      if p and p ~= "" and _ufs.is_file(p) then python = p; break end
    end
    python = python or "python"
  else
    python = "python3"
  end

  local tools_dir = vim.fn.stdpath("config") .. "/tools"
  local build_script
  if phase == "full" then
    build_script = tools_dir .. "/build_full_cdb.py"
  else
    build_script = tools_dir .. "/build_clangd_index.py"
  end
  if not _ufs.is_file(build_script) then
    return false, build_script .. " not found"
  end

  local _, out_idx = INDEX_FN.index_phase_paths(ctx, phase)
  if _ufs.is_file(out_idx) then
    pcall(vim.fn.delete, out_idx)
  end
  local indexer = _uproc.first_executable({
    "/mnt/c/Program Files/LLVM/bin/clangd-indexer.exe",
    "clangd-indexer",
    "clangd-indexer.exe",
    "C:/Program Files/LLVM/bin/clangd-indexer.exe",
  })

  local cmd
  if phase == "full" then
    -- build_full_cdb.py <src> <dst_active> --idx-output <idx>
    -- Single entry that produces:
    --   * dst_active           (per-file CDB for LSP, == src in our wiring)
    --   * dst_active.indexer   (super-unity sidecar for indexer)
    --   * idx                  (clangd-indexer output, written from sidecar)
    cmd = { python, build_script, subset_cdb, subset_cdb, "--idx-output", out_idx }
    if indexer then
      cmd[#cmd + 1] = "--indexer"
      cmd[#cmd + 1] = indexer
    end
  else
    -- hot/current: per-file subset → indexer, no unity/super-unity.
    cmd = { python, build_script, subset_cdb, "--output", out_idx }
    if indexer then
      cmd[#cmd + 1] = "--indexer"
      cmd[#cmd + 1] = indexer
    end
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
  -- Defensive env scrub: if our parent (hermes/wt/IDE) injected PYTHONHOME
  -- pointing at a different python minor than `python` on PATH, the child
  -- explodes with `_sre.MAGIC mismatch` from the stdlib loader. Strip it.
  -- IMPORTANT: setting key=nil in vim.fn.environ() is NOT enough — vim.system
  -- on Windows has been observed inheriting the parent env even when the key
  -- is removed from the table. Force-overwrite to the empty string so the
  -- child sees an explicit blank, which Python's site.py treats as unset.
  local child_env = vim.fn.environ()
  child_env.PYTHONHOME = ""
  child_env.PYTHONPATH = ""
  child_env.PYTHONSTARTUP = ""
  local t_build_0 = vim.uv.hrtime()
  vim.system(cmd, { text = true, cwd = ctx.engine_root, env = child_env }, function(result)
    local elapsed_s = (vim.uv.hrtime() - t_build_0) / 1e9
    vim.schedule(function()
      local live_state = ensure_index_state(ctx)
      INDEX_RT.job = nil
      local stderr = trim((result.stderr or "") .. "\n" .. (result.stdout or ""))
      local ok_result = (result.code == 0) and _ufs.is_file(out_idx)
      -- Persist per-phase timing so :UEIndexTimings (and post-mortem
      -- inspection of state.json) can answer "how long did the last
      -- :UEIndexFull take" without relying on console output.
      live_state.index_timings = live_state.index_timings or {}
      live_state.index_timings[phase] = {
        elapsed_s = math.floor(elapsed_s * 100 + 0.5) / 100,
        modules = #selected_keys,
        status = ok_result and "ready" or "error",
        super_unity = (phase == "full"),
        finished_at = unix_now(),
      }
      if ok_result and INDEX_FN.promote_active_index(ctx, out_idx) then
        -- Keep .clangd's External.File in lockstep with the freshly
        -- promoted active_index. Without this, clangd reads a stale
        -- pre-v3-cache-migration path and silently falls back to
        -- --background-index (17 GB RAM / 32 min CPU symptom).
        pcall(INDEX_FN.sync_dot_clangd, ctx)
        INDEX_FN.clear_module_dirty_flags(ctx, selected_keys)
        live_state.stats[phase .. "_runs"] = (tonumber(live_state.stats[phase .. "_runs"]) or 0) + 1
        live_state.build = {
          phase = phase,
          status = "ready",
          started_at = live_state.build.started_at or unix_now(),
          finished_at = unix_now(),
          message = string.format("%s ready (%d modules) in %.1fs", phase, #selected_keys, elapsed_s),
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
  if not _ufs.is_file(path) then
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
    if not _ufs.is_file(path) or vim.fn.getfsize(path) <= 0 then
      return false
    end
  end
  return true
end

local prepare_freshness  -- forward-decl alias kept for in-module callers
do
  -- ── csearch freshness via content fingerprint (D10 / L2) ──────────────────
  --
  -- freshness answers ONE question: "did the indexed file SET change
  -- (add/remove/rename)?". The indexed set IS workspace_all.files (a sorted,
  -- deterministic list — table.sort'ed at both write sites). Its content hash is
  -- a DIRECT measurement of that question.
  --
  -- We deliberately do NOT use any mtime proxy (git index, git commit-state,
  -- dir mtime). Every proxy has a noise source that produced phantom "stale":
  --   * .git/index  → fsmonitor / TortoiseGit background touch   (K30g)
  --   * dir mtime   → compiler artifacts landing in the engine tree
  --   * git HEAD    → only reflects committed state; misses uncommitted adds
  -- Swapping one proxy for a quieter one (D8 did: index→commit-state) is endless
  -- whack-a-mole. The fix is to stop proxying and measure the object itself.
  --
  -- Content-level edits to EXISTING files are out of scope here — clangd handles
  -- those live (LSP didChange). csearch is a file-level trigram index; a file
  -- that still exists with changed content keeps working trigrams, so only set
  -- changes require a rebuild. (User-defined boundary.)
  --
  -- Two non-proxy signals remain alongside the fingerprint:
  --   * existence (no list → "never")
  --   * ue_watch persistent_dirty (event-driven, zero-noise; covers in-session
  --     set changes before the list is re-enumerated).
  -- Cross-session set changes (e.g. git pull while nvim was closed) are caught
  -- by the fingerprint: the next UEPrepare re-enumerates the list, its bytes
  -- differ, hash mismatches.
  function CORE_RT.prepare_freshness(ctx)
    if not ctx or not ctx.paths then return "never" end
    if CORE_RT.prepare_jobid then
      local ok_wait, result = pcall(vim.fn.jobwait, { CORE_RT.prepare_jobid }, 0)
      if ok_wait and result and result[1] == -1 then
        return "in_progress"
      end
    end
    local list_path = ctx.paths.workspace_all_list
    if not list_path or not vim.loop.fs_stat(list_path) then
      return "never"
    end

    -- Watcher overlay: dirty files observed since last :UEPrepare clear
    -- (in-session set changes not yet folded into the list). Event-driven,
    -- not a proxy.
    local ok_watch, watch = pcall(require, "utils.ue_watch")
    if ok_watch and type(watch.persistent_dirty_status) == "function" then
      local st = watch.persistent_dirty_status() or {}
      if (st.count or 0) > 0 then
        return "stale"
      end
    end

    -- Content fingerprint: the steady-state verdict. Compare the list's content
    -- hash against the hash recorded when the index was last built. Equal =
    -- fresh. (NOTE: list_fingerprint caches on the list's own (mtime,size) so
    -- this is a stat in steady state — the mtime is a cache key, never a
    -- verdict; the verdict is the content hash.)
    local recorded
    local ok_state, state = pcall(read_state, ctx.engine_root)
    if ok_state and type(state) == "table" then
      recorded = state.csearch_input_hash
    end
    if type(recorded) ~= "string" or recorded == "" then
      -- No fingerprint on record (fresh upgrade / never built): lean stale so
      -- the user runs :UEPrepare; the first successful full build records it.
      return "stale"
    end
    local cur = CORE_RT.list_fingerprint(list_path)
    if not cur then
      return "stale"  -- could not hash the list → conservative
    end
    if cur == recorded then
      return "fresh"
    end
    return "stale"
  end
  prepare_freshness = CORE_RT.prepare_freshness
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
    if not _ufs.is_file(path) then
      return false
    end
  end
  if not db_ready(ctx.paths.workspace_db) then
    return false
  end
  -- Worktree-drift check: if .git/index of either repo is newer than our
  -- cached list, the cache is structurally complete but logically stale
  -- (e.g. `git pull` brought in new files that don't show in <space><space>).
  -- Falling through to the slow path forces the lists to be regenerated.
  -- Mirrors the staleness logic the csearch fast-path already uses below.
  if prepare_freshness(ctx) == "stale" then
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
      if _ufs.file_mtime(path) <= 0 then
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

-- csearch build serialization (D9 Policy A). Returns true when the caller is
-- cleared to start a csearch build (and marks the slot busy); returns false +
-- emits a visible notice when a build is already running. The build's
-- completion callback MUST call CORE_RT.csearch_build_done() unconditionally
-- (success AND failure) so a failed build can't wedge the slot. Rejection —
-- never queueing: a concurrent full :UEPrepare already reindexes the whole file
-- list (including any incremental's dirty files), so queuing would be redundant
-- work that then races the next build.
--
-- Defined on CORE_RT (not a main-chunk local) to stay under LuaJIT's 200-local
-- cap on the main function (see CONSTRAINTS luajit-200-local-cap).
function CORE_RT.csearch_build_begin(label)
  if CORE_RT.csearch_build_running then
    vim.schedule(function()
      vim.notify(
        ("[ue] csearch build already in progress — %s skipped"):format(label or "build"),
        vim.log.levels.WARN, { title = "UE", replace = "ue.csearch.build" })
    end)
    return false
  end
  CORE_RT.csearch_build_running = true
  return true
end

function CORE_RT.csearch_build_done()
  CORE_RT.csearch_build_running = false
end

-- Clear the watcher's persistent dirty set after a SUCCESSFUL full csearch
-- build (D9 / D-3b). Soft-requires ue_watch so this is safe to call from any
-- prepare path. Since β made the watcher a bookkeeper (not a writer), clearing
-- the dirty set on build success is now the prepare family's sole job — and it
-- MUST happen on EVERY full-build success path (cache fast-path / cold full /
-- sync), not just one. A residual dirty set otherwise (1) makes
-- prepare_freshness' dirty gate return "stale" right after a successful prepare,
-- and (2) makes the rg-on-dirty overlay re-grep a huge stale set on every
-- <leader>/ / <space><space> (picker lag). Only call on SUCCESS — a failed
-- build leaves the dirty set so the overlay keeps those files visible.
function CORE_RT.clear_persistent_dirty_safe(reason)
  local ok_watch, watch = pcall(require, "utils.ue_watch")
  if ok_watch and type(watch.clear_persistent_dirty) == "function" then
    watch.clear_persistent_dirty(reason or "prepare")
  end
end

-- Called once on EVERY full csearch build SUCCESS path (sync / cache fast-path /
-- cold full). Bundles the two post-success obligations so the three call sites
-- can't drift:
--   D-3b: clear the watcher dirty set (it's logically empty — full build indexed
--         everything).
--   D10:  record the content fingerprint of the list we just indexed, so
--         prepare_freshness can compare future list bytes against it.
-- MUST only be called on SUCCESS. On failure neither obligation applies (dirty
-- files must stay visible; the fingerprint must not move ahead of a built index).
function CORE_RT.on_full_csearch_success(ctx, reason)
  CORE_RT.clear_persistent_dirty_safe(reason)
  local list_path = ctx and ctx.paths and ctx.paths.workspace_all_list
  if not list_path or not ctx.engine_root then return end
  local hash = CORE_RT.list_fingerprint(list_path)
  if hash then
    pcall(update_state_field, ctx.engine_root, "csearch_input_hash", hash)
  end
end

-- Test seams for the serialization guard (D9 Policy A).
function M._csearch_build_begin_for_test(label) return CORE_RT.csearch_build_begin(label) end
function M._csearch_build_done_for_test() return CORE_RT.csearch_build_done() end
function M._csearch_build_running_for_test() return CORE_RT.csearch_build_running end

-- Public alias for the D-3b dirty-clear helper (also used by tests).
function M.clear_persistent_dirty_safe(reason)
  return CORE_RT.clear_persistent_dirty_safe(reason)
end

-- ── csearch freshness content fingerprint (D10 / L2) ────────────────────────
-- Content hash of workspace_all.files = a DIRECT measurement of "did the
-- indexed file SET change (add/remove/rename)?". This replaces all mtime-proxy
-- anchors (git index, git commit-state D8, dir_mtime), which were polluted by
-- fsmonitor / TortoiseGit / compiler artifacts touching unrelated paths and
-- produced phantom "stale". The list is table.sort'ed at both write sites so its
-- bytes are deterministic for a given file set.
--
-- Cost: sha256 over the (~22 MB) list is ~46ms. We cache the hash keyed on the
-- list's OWN (mtime,size); steady-state freshness checks only stat (microseconds)
-- and reuse the cached hash. NOTE: this mtime is a cache-invalidation key for
-- "should we recompute the hash", NOT a freshness verdict — the verdict is
-- always the content hash comparison. That distinction is the whole point: a
-- proxy treats mtime AS truth; here truth is the bytes, mtime only hints when to
-- re-read them.
CORE_RT.list_fingerprint_cache = {}  -- path -> { mt, size, hash }
function CORE_RT.list_fingerprint(path)
  if not path or path == "" then return nil end
  local st = vim.loop.fs_stat(path)
  if not st then return nil end
  local mt = (st.mtime and st.mtime.sec) or 0
  local size = st.size or 0
  local cached = CORE_RT.list_fingerprint_cache[path]
  if cached and cached.mt == mt and cached.size == size then
    return cached.hash
  end
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data then return nil end
  local ok_h, hash = pcall(vim.fn.sha256, data)
  if not ok_h or type(hash) ~= "string" then return nil end
  CORE_RT.list_fingerprint_cache[path] = { mt = mt, size = size, hash = hash }
  return hash
end

-- Test seam for the fingerprint helper (D10).
function M._list_fingerprint_for_test(path) return CORE_RT.list_fingerprint(path) end
function M._reset_fingerprint_cache_for_test() CORE_RT.list_fingerprint_cache = {} end

local function scan_relative_files(root, search_paths)
  local fd = _uproc.first_executable({ "fd", "fdfind" })
  if not fd then
    return nil, "fd/fdfind not found in PATH"
  end

  local cmd = { fd, "--type", "f", "--hidden", "--follow" }
  local found = false
  for _, search_path in ipairs(search_paths) do
    if _ufs.is_dir(join(root, search_path)) then
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
  local fd = _uproc.first_executable({ "fd", "fdfind" })
  if not fd then
    vim.schedule(function() cb(nil, "fd/fdfind not found in PATH") end)
    return
  end

  local cmd = { fd, "--type", "f", "--hidden", "--follow" }
  -- Prune cache/asset/intermediate trees at fd level so we never even traverse
  -- them. Without this, shipped UE projects with Content/ + node_modules/ +
  -- Saved/ blow up to 5M+ files in Source/ subtree, and the downstream lists
  -- pass spent ~55s on the main thread doing dedup+sort+write of ~700k paths.
  -- See UE_CONST.SCAN_EXCLUDES for rationale (Content mandatory, ThirdParty
  -- intentionally KEPT for grep into vendored sources).
  for _, ex in ipairs(UE_CONST.SCAN_EXCLUDES) do
    table.insert(cmd, "--exclude")
    table.insert(cmd, ex)
  end
  -- (Removed: .ueprepare-scan-ignore blacklist. Replaced by per-project
  -- .ueprepare-scan-paths whitelist in CORE_RT.project_index_dirs.)
  local found = false
  for _, search_path in ipairs(search_paths) do
    if _ufs.is_dir(join(root, search_path)) then
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
  _ufs.ensure_dir(dir)
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

-- Resolve the directory that actually contains Binaries/ and Intermediate/.
-- In some workspaces (P4 layouts especially), `ctx.project_root` is the repo
-- root (e.g. `<repo-root>`) while the `.uproject` and ALL of its
-- build outputs live a few dirs down (`Source/Client/`). Using project_root
-- directly makes Binaries/Intermediate globs miss everything. Prefer the
-- directory containing the uproject; fall back to project_root for legacy
-- flat layouts where they coincide.
local function uproject_dir(ctx)
  if ctx and ctx.uproject and ctx.uproject ~= "" then
    local d = _ufs.dirname(ctx.uproject)
    if d and d ~= "" then return d end
  end
  return ctx and ctx.project_root or nil
end

local function cleanup_gradle_debug_artifacts(ctx)
  local pr = uproject_dir(ctx)
  if not pr or pr == "" then
    return
  end

  -- Wipe Gradle packaging-stage artifacts that AGP's incremental task tracker
  -- can desync against (last-build interrupted / shared cache stale). Symptoms:
  --   "Zip file 'app-*.apk' already contains entry 'META-INF/.../app-metadata.properties'"
  -- Root cause: the per-task incremental state thinks an entry is missing but
  -- the final APK on disk still has it, so PackageAndroidArtifact tries to
  -- re-add it and fails. Cleaning the output APKs PLUS the intermediates that
  -- feed into packaging (app_metadata, merged_manifest, packaged_manifests,
  -- incremental/packageDebug) forces AGP back to a clean packaging step.
  local debug_dir = join(pr, "Intermediate", "Android", "*", "gradle", "app", "build")
  local patterns = {
    -- output APKs (debug + release variants, with and without variant subdir)
    join(debug_dir, "outputs", "apk", "app-debug.apk"),
    join(debug_dir, "outputs", "apk", "debug", "app-debug.apk"),
    join(debug_dir, "outputs", "apk", "app-release.apk"),
    join(debug_dir, "outputs", "apk", "release", "app-release.apk"),
    join(debug_dir, "intermediates", "apk", "app-debug.apk"),
    join(debug_dir, "intermediates", "apk", "debug", "app-debug.apk"),
    -- packaging incremental state
    join(debug_dir, "intermediates", "incremental", "packageDebug"),
    join(debug_dir, "intermediates", "incremental", "debug", "packageDebug"),
    join(debug_dir, "intermediates", "incremental", "packageRelease"),
    join(debug_dir, "intermediates", "incremental", "release", "packageRelease"),
    -- packaging input intermediates that frequently drift and produce
    -- duplicate META-INF/com/android/build/gradle/app-metadata.properties
    join(debug_dir, "intermediates", "app_metadata"),
    join(debug_dir, "intermediates", "merged_manifest"),
    join(debug_dir, "intermediates", "packaged_manifests"),
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
  local gtags = _uproc.first_executable({ "gtags" })
  if not gtags then
    return false, "gtags not found in PATH"
  end

  if not _ufs.is_file(filelist) or vim.fn.getfsize(filelist) <= 0 then
    clean_db_dir(db_dir)
    return true, label .. ": no files to index"
  end

  clean_db_dir(db_dir)

  -- Use repo-bundled gtags.conf with the `hlsl-cpp` label so that
  -- .usf/.ush/.hlsl/.hlsli get parsed by the exuberant-ctags backend
  -- as C++. Without this, gtags only sees C/C++/C# and silently skips
  -- shaders (workspace_gtags.files contained 0 .usf entries before the
  -- FT_GTAGS expansion). Falls back to system defaults if the bundled
  -- file is missing — never hard-fails the indexer over config plumbing.
  local env = nil
  -- Resolve repo root from this very file's path (lua/ue.lua → ../..).
  local source = debug.getinfo(1, "S").source or ""
  if source:sub(1, 1) == "@" then source = source:sub(2) end
  local plugin_root = norm(vim.fn.fnamemodify(source, ":h:h"))
  local conf_path = plugin_root ~= "" and (plugin_root .. "/tools/gtags/gtags.conf") or ""
  if conf_path ~= "" and _ufs.is_file(conf_path) then
    env = {
      GTAGSCONF = conf_path,
      GTAGSLABEL = "hlsl-cpp",
    }
  end

  local cmd = { gtags, "-f", filelist, "--skip-unreadable", "--skip-symlink", db_dir }
  local code, lines = run_lines(cmd, { cwd = root, env = env })
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

  local rg = _uproc.first_executable({ "rg" })
  if not rg then
    return false
  end

  local dirs = {}
  local seen = {}
  local function add_dir(dir)
    dir = norm(dir)
    if dir ~= "" and _ufs.is_dir(dir) and not seen[dir] then
      seen[dir] = true
      dirs[#dirs + 1] = dir
    end
  end

  if ctx.project_root and ctx.project_root ~= "" then
    for _, relative in ipairs(existing_relative_dirs(ctx.project_root, CORE_RT.project_index_dirs(ctx))) do
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
    local root = _ufs.common_ancestor({ ctx.engine_root, ctx.project_root })
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
  -- Two layouts to support:
  --   1. Standard:  <project_root>/<Project>.uproject + <project_root>/Source/*.Target.cs
  --   2. P4 nested: <project_root>/Source/Client/Client.uproject
  --                 + <project_root>/Source/Client/Source/*.Target.cs
  --
  -- Prefer the directory next to the .uproject (matches what UBT itself
  -- does), fall back to <project_root>/Source for the standard layout.
  local search_dirs = {}
  if uproject and uproject ~= "" then
    table.insert(search_dirs, join(_ufs.dirname(uproject), "Source"))
  end
  table.insert(search_dirs, join(project_root, "Source"))

  local seen, targets = {}, {}
  for _, dir in ipairs(search_dirs) do
    if seen[dir] == nil then
      seen[dir] = true
      local found = vim.fn.globpath(dir, "*.Target.cs", false, true)
      if type(found) == "table" then
        for _, t in ipairs(found) do table.insert(targets, t) end
      end
    end
  end

  local detected = {
    Editor = nil,
    Client = nil,
    Server = nil,
    Game = nil,
  }

  for _, target in ipairs(targets) do
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

  -- Historical: this used to spawn `wslpath -w` to convert /mnt/d/... into
  -- D:\... when ue.lua ran inside WSL. WSL is no longer a supported host
  -- (Windows-native + Mac-native only), so a non-Windows path here means
  -- the caller passed a malformed path (e.g. drive-relative like "E:aki/"
  -- or a posix absolute that doesn't make sense on this host). Fail
  -- loudly instead of silently spawning a missing helper.
  return nil
end

local function windows_host_cwd()
  for _, candidate in ipairs({ "/mnt/c/Windows", "/mnt/c" }) do
    if _ufs.is_dir(candidate) then
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
  if not _ufs.is_file(exe) then
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

  if _uplat.is_windows then
    return { "cmd.exe", "/d", "/c", table.concat(direct_parts, " ") }
  end

  local parts = {
    "call " .. shell_cmd_token(build_bat_win),
  }

  for _, arg in ipairs(args or {}) do
    table.insert(parts, shell_cmd_token(arg))
  end

  local shell = _uproc.first_executable({ "zsh", "bash", "sh" })
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
  return require("ue.cdb.paths").targets(ctx)
end

local function windows_engine_root(ctx)
  local override = trim(vim.env.UE_WINDOWS_ENGINE_ROOT)
  if override ~= "" then
    return to_windows_path(override)
  end

  return to_windows_path(ctx.engine_root)
end

local function compile_commands_candidates(ctx)
  return require("ue.cdb.paths").candidates(ctx, {
    first_executable = first_executable,
    run_lines        = run_lines,
  })
end

-- ==========================================================================
-- SHADER DEFINITION SEARCH + COMPILE COMMANDS AUGMENTATION
-- ==========================================================================

local function scan_shader_files(root, search_paths)
  root = norm(root)
  if root == "" then
    return {}
  end

  -- Prefer `fd` (single multi-extension multi-search-path walk, ~100x faster
  -- than nested vim.fn.glob loops on Windows for large UE trees).
  -- vim.fn.glob path retained as a fallback when fd is unavailable.
  local existing = existing_relative_dirs(root, search_paths)
  if #existing == 0 then return {} end

  local files = {}
  local seen = {}

  if vim.fn.executable("fd") == 1 and vim.system then
    local cmd = { "fd", "--type", "f", "--hidden", "--no-ignore", "--absolute-path" }
    for _, ex in ipairs(UE_CONST.SCAN_EXCLUDES) do
      table.insert(cmd, "--exclude"); table.insert(cmd, ex)
    end
    for _, ext in ipairs(M.FT_SHADER) do
      table.insert(cmd, "-e"); table.insert(cmd, ext)
    end
    for _, sp in ipairs(existing) do
      table.insert(cmd, "--search-path"); table.insert(cmd, sp)
    end
    local ok, result = pcall(function()
      return vim.system(cmd, { text = true, cwd = root }):wait()
    end)
    if ok and result and result.code == 0 and result.stdout then
      for line in (result.stdout):gmatch("[^\r\n]+") do
        local normalized = norm(line)
        local key = normalized:lower()
        if not seen[key] then
          seen[key] = true
          table.insert(files, normalized)
        end
      end
      table.sort(files)
      return files
    end
    -- fall through to glob fallback on failure
  end

  for _, search_path in ipairs(existing) do
    for _, extension in ipairs(M.FT_SHADER) do
      for _, pattern in ipairs({
        join(root, search_path, "*." .. extension),
        join(root, search_path, "**", "*." .. extension),
      }) do
        for _, absolute in ipairs(glob_paths(pattern)) do
          local normalized = norm(absolute)
          local key = normalized:lower()
          if _ufs.is_file(normalized) and not seen[key] then
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
    if path ~= "" and _ufs.is_dir(path) and not seen[key] then
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
  local rg = _uproc.first_executable({ "rg" })
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
      if not _ufs.is_absolute_path(file) then
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

  local current_dir = _ufs.dirname(current)
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
  return require("ue.cdb.json").program(entry)
end

local function compile_commands_template_entry(entries)
  return require("ue.cdb.json").template_entry(entries)
end

local function make_shader_compile_command_entry(shader_file, template, include_roots)
  return require("ue.cdb.shaders").make_entry(shader_file, template, include_roots)
end

local function augment_compile_commands_with_shaders(ctx, content)
  -- Discovery stays here (captures UE_CONST + scan_shader_files); the
  -- augmentation primitive itself moved to lua/ue/cdb/shaders.lua.
  local shader_files = {}
  CORE_RT.trace_seg("shader.scan", function()
    if ctx.project_root and ctx.project_root ~= "" then
      vim.list_extend(shader_files, scan_shader_files(ctx.project_root, CORE_RT.project_index_dirs(ctx)))
    end
    vim.list_extend(shader_files, scan_shader_files(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS))
  end)
  CORE_RT.trace_mark(string.format("shader.count=%d", #shader_files))
  if #shader_files == 0 then
    return content
  end
  local include_roots = CORE_RT.trace_seg("shader.include_roots", function()
    return shader_include_roots(shader_files)
  end)
  CORE_RT.trace_mark(string.format("shader.include_roots_count=%d", #include_roots))
  return CORE_RT.trace_seg("shader.augment", function()
    return require("ue.cdb.shaders").augment(content, shader_files, include_roots)
  end)
end

-- Table variant: augments an in-memory entries table directly (no JSON round-trip).
-- Use when caller already has the parsed CDB in memory — saves a decode+encode
-- of the full CDB (~224 MB on UE5 projects, ~200s round-trip on the main thread).
local function augment_compile_commands_table_with_shaders(ctx, entries, progress)
  progress = progress or function() end
  progress("shader_scan", 70, "scanning shaders...")
  local shader_files = {}
  CORE_RT.trace_seg("shader.scan", function()
    if ctx.project_root and ctx.project_root ~= "" then
      vim.list_extend(shader_files, scan_shader_files(ctx.project_root, CORE_RT.project_index_dirs(ctx)))
    end
    vim.list_extend(shader_files, scan_shader_files(ctx.engine_root, UE_CONST.ENGINE_INDEX_DIRS))
  end)
  CORE_RT.trace_mark(string.format("shader.count=%d", #shader_files))
  if #shader_files == 0 then
    return entries
  end
  progress("shader_augment", 80, string.format("augmenting cdb with %d shaders...", #shader_files))
  local include_roots = CORE_RT.trace_seg("shader.include_roots", function()
    return shader_include_roots(shader_files)
  end)
  CORE_RT.trace_mark(string.format("shader.include_roots_count=%d", #include_roots))
  return CORE_RT.trace_seg("shader.augment_table", function()
    return require("ue.cdb.shaders").augment_table(entries, shader_files, include_roots)
  end)
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
      if not _ufs.is_file(abs) then
        abs = norm(join(_ufs.dirname(unity_file), inc_path))
      end
    end
    if _ufs.is_file(abs) then
      includes[#includes + 1] = abs
    end
  end
  if #includes > 0 then
    return includes
  end
  return nil
end

local function collect_rsp_files(ctx)
  local fd = _uproc.first_executable({ "fd", "fdfind" })
  if not fd then
    return nil, "fd/fdfind not found in PATH"
  end

  local search_roots = {}
  local seen_roots = {}
  local function add_root(p)
    if not p or p == "" then return end
    p = norm(p)
    if seen_roots[p] then return end
    if _ufs.is_dir(p) then
      seen_roots[p] = true
      search_roots[#search_roots + 1] = p
    end
  end

  add_root(join(ctx.engine_root, "Engine", "Intermediate", "Build"))
  if ctx.project_root and ctx.project_root ~= "" then
    add_root(join(ctx.project_root, "Intermediate", "Build"))
  end
  -- P4 workspace layout: project_root is the workspace mount, but the uproject
  -- (and therefore Intermediate/Build) lives under <workspace>/Source/Client/.
  -- Always include the .uproject parent dir so game-side rsp gets collected.
  if ctx.uproject and ctx.uproject ~= "" then
    add_root(join(_ufs.dirname(ctx.uproject), "Intermediate", "Build"))
  end

  if #search_roots == 0 then
    return nil, "No Intermediate/Build directories found"
  end

  -- Collect compile response-files. UBT emits one of two suffix families
  -- depending on the engine/toolchain combo:
  --
  --   UE5 (any toolchain) and UE4 NDK/Linux: `.rsp` extension
  --     MSVC:    Module.<Mod>.cpp.obj.rsp,  <Mod>.cpp.obj.rsp (single-TU modules)
  --     NDK arm64: Module.<Mod>.cppa8.o.rsp, <Mod>.cppa8.o.rsp, .ca8.o.rsp, .mma8.o.rsp
  --     NDK arm32: Module.<Mod>.cppa7.o.rsp variants
  --     Linux/Mac: Module.<Mod>.cpp.o.rsp,  <Mod>.cpp.o.rsp
  --
  --   UE4 Windows (MSVC): `.response` extension
  --     <Source>.cpp.obj.response,  Module.<Mod>.cpp.obj.response
  --     UBT keeps a `.response.old` backup alongside — must reject those.
  --
  -- We do NOT pre-filter by "Module.*" glob — UBT only emits the Module.
  -- prefix when a module is unity-split into N_of_M chunks; small/single-TU
  -- modules and third-party SDKs have no Module. prefix and would be
  -- silently dropped, killing every game-only entry in the resulting CDB.
  -- The .obj.{rsp,response} / .o.rsp suffix filter below is the real
  -- compile-vs-link discriminator.
  local cmd = {
    fd,
    "--no-ignore",
    "--type",
    "f",
    "-e",
    "rsp",
    "-e",
    "response",
  }
  for _, root in ipairs(search_roots) do
    cmd[#cmd + 1] = "--search-path"
    cmd[#cmd + 1] = root
  end

  local code, lines = run_lines(cmd, { cwd = ctx.engine_root })
  if code ~= 0 or not lines or #lines == 0 then
    return nil, "No .rsp/.response files found"
  end

  -- Determine target/platform filters from persisted state.
  --
  -- Target name resolution must NOT assume UE5 default names (UnrealEditor /
  -- UnrealGame). UE4 ships `UE4Editor.Target.cs` and most game projects use
  -- a custom name from `<Project>.Target.cs` (e.g. `Client`, `ClientEditor`).
  -- We build the filter set from (a) detect_target_names against the
  -- project's Source/ tree, plus (b) the engine's own *.Target.cs files
  -- found by globbing `<engine>/Engine/Source/*.Target.cs` and stripping
  -- the `.Target.cs` suffix. Any rsp path containing `/<Name>/` for a
  -- detected target name passes.
  --
  -- Platform filter additionally constrains by `/<Platform>/` segment so a
  -- stray Android-target rsp can't slip in when the user is on Win64.
  local config = ctx.state and trim(ctx.state.target_configuration or "") or ""
  local platform = ctx.state and trim(ctx.state.target_platform or "") or ""
  local config_filter = nil
  local kind_suffix = nil  -- "Editor"|"Client"|"Server"|"Game"|nil
  if config ~= "" then
    if config:match(" Editor$") then
      kind_suffix = "Editor"
      config_filter = config:gsub(" Editor$", "")
    elseif config:match(" Client$") then
      kind_suffix = "Client"
      config_filter = config:gsub(" Client$", "")
    elseif config:match(" Server$") then
      kind_suffix = "Server"
      config_filter = config:gsub(" Server$", "")
    else
      kind_suffix = "Game"
      config_filter = config
    end
  end

  -- Collect candidate target names from project + engine Source dirs.
  local target_names = {}
  local seen_target = {}
  local function add_target(name)
    name = trim(name or "")
    if name == "" or seen_target[name] then return end
    seen_target[name] = true
    target_names[#target_names + 1] = name
  end
  if ctx.project_root and ctx.uproject and ctx.uproject ~= "" then
    local detected = detect_target_names(ctx.project_root, ctx.uproject)
    -- Prefer the kind matching the configuration first, but include the
    -- others as best-effort (UBT may have built more than one variant).
    if kind_suffix and detected[kind_suffix] then
      add_target(detected[kind_suffix])
    end
    for _, k in ipairs({ "Editor", "Client", "Server", "Game" }) do
      add_target(detected[k])
    end
  end
  -- Engine-side targets (UE4Editor.Target.cs / UnrealEditor.Target.cs / ...).
  do
    local engine_source = join(ctx.engine_root, "Engine", "Source")
    local engine_targets = vim.fn.globpath(engine_source, "*.Target.cs", false, true)
    if type(engine_targets) == "table" then
      for _, t in ipairs(engine_targets) do
        add_target((vim.fs.basename(t):gsub("%.Target%.cs$", "")))
      end
    end
  end

  local rsp_files = {}
  local kept_by_target = false
  for _, line in ipairs(lines) do
    local p = norm(trim(line))
    if p ~= "" then
      -- Reject non-compile rsp (link / lib / def) and UBT `.response.old`
      -- backups. Compile artifacts end in .obj.rsp, .o.rsp, or .obj.response.
      local lp = p:lower()
      local is_compile = lp:match("%.obj%.rsp$")
        or lp:match("%.o%.rsp$")
        or lp:match("%.obj%.response$")
      local is_backup = lp:match("%.response%.old$") or lp:match("%.rsp%.old$")
      local is_linker = lp:match("%.link%.rsp$")
        or lp:match("%.lib%.rsp$")
        or lp:match("%.def%.rsp$")
        or lp:match("%.link%.response$")
        or lp:match("%.lib%.response$")
        or lp:match("%.def%.response$")
      if is_compile and not is_backup and not is_linker then
        local dominated = true

        -- Platform filter: `/<Platform>/` must appear in the path.
        if platform ~= "" then
          if not p:find("/" .. platform .. "/", 1, true) then
            dominated = false
          end
        end

        -- Target-name filter: at least one detected target name must
        -- appear as a path segment. Skipped silently if we somehow have
        -- no detected targets (rare; treated as "match anything" so we
        -- never lose entries on misconfigured trees).
        if dominated and #target_names > 0 then
          local target_hit = false
          for _, tn in ipairs(target_names) do
            if p:find("/" .. tn .. "/", 1, true) then
              target_hit = true
              break
            end
          end
          if not target_hit then
            dominated = false
          end
        end

        -- Configuration filter (Development / DebugGame / Shipping / Test).
        if dominated and config_filter and config_filter ~= "" then
          if not p:find("/" .. config_filter .. "/", 1, true) then
            dominated = false
          end
        end

        if dominated then
          rsp_files[#rsp_files + 1] = p
          kept_by_target = true
        end
      end
    end
  end

  if #rsp_files == 0 then
    -- No silent fallback: an empty filter result almost always means the
    -- user's selected platform/configuration has never been built, OR a
    -- detection bug. Returning "all rsp files" hides both and lets foreign
    -- target entries (e.g. Android .cppa8.o.rsp) win the dedup race in the
    -- caller, producing a CDB with the wrong toolchain for every cpp.
    local detail = string.format(
      "rsp filter matched 0 files (platform=%s config=%s kind=%s targets=[%s] roots=%d scanned=%d). "
        .. "Build the selected target at least once, or re-check :UESetPlatform / :UESetConfiguration.",
      platform == "" and "<unset>" or platform,
      config_filter or "<unset>",
      kind_suffix or "<unset>",
      table.concat(target_names, ","),
      #search_roots,
      #lines
    )
    return nil, detail
  end

  -- Suppress unused-var warning for the diagnostic-only flag.
  local _ = kept_by_target
  return rsp_files, nil
end

generate_compile_commands_from_rsp = function(ctx, progress)
  progress = progress or function() end
  progress("collect_rsp", 30, "collecting .rsp files...")
  local rsp_files, err = CORE_RT.trace_seg("ccjson.collect_rsp", function()
    return collect_rsp_files(ctx)
  end)
  if not rsp_files then
    return nil, err
  end
  CORE_RT.trace_mark(string.format("ccjson.rsp_count=%d", #rsp_files))
  progress("parse_loop", 40, string.format("parsing %d rsp files...", #rsp_files))

  local engine_source_dir = join(ctx.engine_root, "Engine", "Source")
  -- UBT runs with Engine/Source as CWD, so all relative paths in rsp files
  -- (../Intermediate/Build/..., Runtime/Core/Public, etc.) are relative to it.
  local compile_dir = engine_source_dir

  -- Per-shard bucketing: classify every rsp by (platform, target, config)
  -- and stuff its entries into a per-bucket array. This replaces the old
  -- single global `entries` table. See ue.cdb.shards.
  local shards_mod = require("ue.cdb.shards")
  local buckets = {}             -- buckets[key] = { plat, target, config, entries[], seen_files{}, roots{} }
  local UNKNOWN_KEY = "Unknown-Unknown-Unknown"
  local function get_bucket(rsp_path)
    local plat, target, config = shards_mod.classify_rsp_path(rsp_path)
    local key
    if plat then
      key = shards_mod.shard_key(plat, target, config)
    else
      key = UNKNOWN_KEY
      plat, target, config = "Unknown", "Unknown", "Unknown"
    end
    local b = buckets[key]
    if not b then
      b = {
        key = key,
        platform = plat,
        target = target,
        config = config,
        entries = {},
        seen_files = {},
        roots = {},
      }
      buckets[key] = b
    end
    return b
  end

  local _ccjson_read_ms = 0
  local _ccjson_unity_ms = 0
  local _ccjson_unity_calls = 0
  local total_entries = 0

  CORE_RT.trace_seg("ccjson.parse_loop", function()
  for _, rsp_path in ipairs(rsp_files) do
    local _t0 = vim.loop.hrtime()
    local content = read_all(rsp_path)
    _ccjson_read_ms = _ccjson_read_ms + (vim.loop.hrtime() - _t0) / 1e6
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

          local bucket = get_bucket(rsp_path)
          bucket.roots[_ufs.dirname(rsp_path)] = true

          local _u0 = vim.loop.hrtime()
          local unity_includes = extract_unity_includes(input_file, engine_source_dir)
          _ccjson_unity_ms = _ccjson_unity_ms + (vim.loop.hrtime() - _u0) / 1e6
          _ccjson_unity_calls = _ccjson_unity_calls + 1
          if unity_includes then
            for _, real_file in ipairs(unity_includes) do
              local key = real_file:lower()
              if not bucket.seen_files[key] then
                bucket.seen_files[key] = true
                local entry_args = vim.list_extend({}, args)
                entry_args[#entry_args + 1] = real_file
                bucket.entries[#bucket.entries + 1] = {
                  directory = compile_dir,
                  file = real_file,
                  arguments = entry_args,
                }
                total_entries = total_entries + 1
              end
            end
          else
            local key = input_file:lower()
            if not bucket.seen_files[key] then
              bucket.seen_files[key] = true
              local entry_args = vim.list_extend({}, args)
              entry_args[#entry_args + 1] = input_file
              bucket.entries[#bucket.entries + 1] = {
                directory = compile_dir,
                file = input_file,
                arguments = entry_args,
              }
              total_entries = total_entries + 1
            end
          end
        end
      end
    end
  end
  end)

  -- Bucket summary for tracing.
  do
    local pieces = {}
    for k, b in pairs(buckets) do
      pieces[#pieces + 1] = string.format("%s=%d", k, #b.entries)
    end
    table.sort(pieces)
    CORE_RT.trace_mark(string.format(
      "ccjson.read_total=%.0fms unity_total=%.0fms unity_calls=%d entries=%d shards=%d [%s]",
      _ccjson_read_ms, _ccjson_unity_ms, _ccjson_unity_calls, total_entries,
      vim.tbl_count(buckets), table.concat(pieces, ", ")))
  end

  if total_entries == 0 then
    return nil, "No compile entries generated from .rsp files"
  end

  -- Pick the *active* bucket: the one matching state.target_platform +
  -- state.target_configuration. Shader CDB augmentation is only attached
  -- to the active bucket (shader entries are platform-agnostic; merging
  -- them onto every shard would just duplicate work).
  local state = ctx.state or {}
  local want_plat = trim(state.target_platform or "")
  local want_conf = trim(state.target_configuration or "")
  local want_conf_stripped = want_conf:gsub(" Editor$", "")
  local active_bucket = nil
  for _, b in pairs(buckets) do
    if (want_plat == "" or b.platform == want_plat) and
       (want_conf == "" or b.config == want_conf_stripped) then
      active_bucket = b
      break
    end
  end
  if not active_bucket then
    -- Fall back to whichever bucket has the most entries.
    local best_count = -1
    for _, b in pairs(buckets) do
      if #b.entries > best_count then
        active_bucket, best_count = b, #b.entries
      end
    end
  end

  progress("shaders", 80, "augmenting active shard with shader entries...")
  active_bucket.entries = augment_compile_commands_table_with_shaders(
    ctx, active_bucket.entries, progress)

  -- Per-bucket structural fixups for clangd LSP:
  --   (a) synthesize .h CDB entries (UBT writes only .cpp; clangd header
  --       inference picks wrong donor for sibling-include headers).
  --   (b) re-inject /FI=SharedPCH.<X>.h on PCH-dependent .cpp (UBT strips
  --       it because cl.exe reads /Yu /Fp binary PCH; clangd needs text /FI).
  -- Must run BEFORE shard write so each on-disk shard is clangd-complete
  -- and fast-swap (:UESetPlatform) inherits the fix for free.
  -- NOTE: inline require inside trace_seg closure — ue.lua is at the
  --       LuaJIT 200 main-chunk local cap; do not add top-level locals.
  progress("inject", 82, "injecting .h entries + PCH /FI per bucket...")
  CORE_RT.trace_seg("ccjson.inject", function()
    local header_inject = require("ue.cdb.header_inject")
    local pch_fi_inject = require("ue.cdb.pch_fi_inject")
    for _, b in pairs(buckets) do
      local ok_h, h_stats = pcall(header_inject.run, b)
      if not ok_h then
        CORE_RT.trace_mark(string.format(
          "inject %s/%s/%s: header_inject ERROR: %s",
          b.platform, b.target, b.config, tostring(h_stats)))
        h_stats = { h_added = 0, donor_a = 0, donor_b = 0 }
      end
      local ok_f, fi_stats = pcall(pch_fi_inject.run, b)
      if not ok_f then
        CORE_RT.trace_mark(string.format(
          "inject %s/%s/%s: pch_fi_inject ERROR: %s",
          b.platform, b.target, b.config, tostring(fi_stats)))
        fi_stats = { fi_added = 0, response_missing = 0 }
      end
      CORE_RT.trace_mark(string.format(
        "inject %s/%s/%s: h_added=%d h_a=%d h_b=%d fi_added=%d fi_missing=%d",
        b.platform, b.target, b.config,
        h_stats.h_added or 0, h_stats.donor_a or 0, h_stats.donor_b or 0,
        fi_stats.fi_added or 0, fi_stats.response_missing or 0))
    end
  end)

  -- Write every bucket to its shard file + update manifest.
  progress("shards", 85, "writing per-config shards...")
  local active_key = nil
  CORE_RT.trace_seg("ccjson.write_shards", function()
    for _, b in pairs(buckets) do
      local roots = {}
      for r, _ in pairs(b.roots) do roots[#roots + 1] = r end
      local k = shards_mod.write_shard(ctx, b.platform, b.target, b.config, b.entries, roots)
      if b == active_bucket then active_key = k end
    end
  end)

  -- Ensure manifest.active reflects the bucket clangd should consume.
  if active_key then
    local manifest = shards_mod.read_manifest(ctx)
    manifest.active = active_key
    shards_mod.write_manifest(ctx, manifest)
  end

  -- Merge all shards (priority dedup) → final top-level CDB.
  progress("merge", 90, "merging shards into top-level CDB...")
  local merged, stats = CORE_RT.trace_seg("ccjson.merge", function()
    return shards_mod.merge_shards(ctx)
  end)
  CORE_RT.trace_mark(string.format(
    "ccjson.merge in=%d out=%d dropped=%d shards=%d active=%s",
    stats.total_in, stats.total_out, stats.dropped, stats.shard_count,
    stats.active or "(none)"))

  local json_content = CORE_RT.trace_seg("ccjson.encode", function()
    return vim.json.encode(merged)
  end)

  local targets = compile_commands_targets(ctx)
  local preferred = targets[1]
  progress("write", 92, string.format("writing cdb (%.1f MB x %d)...", #json_content / 1048576, #targets))
  CORE_RT.trace_seg("ccjson.write", function()
    for _, target in ipairs(targets) do
      write_all(target, json_content)
    end
  end)
  progress("done", 95, string.format("cdb written: %d entries (active=%s)", #merged, active_key or "?"))

  return #merged, preferred
end

end -- do block

local function slim_compile_commands_file(path)
  return require("ue.cdb.pipeline").slim(path)
end

--- Spawn a long-running shell job, capture stdout+stderr to a timestamped log
--- file under stdpath('log')/<tag>/, and notify on failure with the log path.
---
--- This is the standard pattern for any background job in ue.lua. When it fails,
--- the user can quote the log file path back to the agent for instant debugging
--- — no need to re-run to capture the failure.
---
--- @param cmd string|string[] command (string for shell, list for argv)
--- @param tag string subdirectory name under stdpath('log') (e.g. "ue-pipeline")
--- @param opts table {
---   cdb     = string?      -- optional context to record in log header
---   on_exit = fun(code:integer, log_lines:string[], log_path:string)
---                          -- called on success (code==0). On failure, helper
---                          -- handles notify + log flush; on_exit is NOT called.
---   on_fail = fun(code:integer, log_lines:string[], log_path:string)?
---                          -- optional override for failure handling
---   cwd     = string?
---   env     = table?
--- }
--- @return integer jobid
function M._logged_jobstart(cmd, tag, opts)
  opts = opts or {}
  local log_dir = vim.fn.stdpath("log") .. "/" .. tag
  vim.fn.mkdir(log_dir, "p")
  local log_path = log_dir .. "/" .. os.date("%Y%m%d-%H%M%S") .. ".log"
  local log_lines = {}

  local function on_data(_, data)
    if not data then return end
    for _, line in ipairs(data) do
      if line and line ~= "" then table.insert(log_lines, line) end
    end
  end

  local function flush_log(code)
    local f = io.open(log_path, "w")
    if not f then return end
    f:write("# ue.lua " .. tag .. "\n")
    f:write("# cmd: " .. (type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)) .. "\n")
    f:write("# exit: " .. tostring(code) .. "\n")
    if opts.cdb then f:write("# cdb: " .. tostring(opts.cdb) .. "\n") end
    f:write(("# time: %s\n\n"):format(os.date("%Y-%m-%d %H:%M:%S")))
    for _, line in ipairs(log_lines) do f:write(line, "\n") end
    f:close()
  end

  local job_opts = {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = on_data,
    on_stderr = on_data,
    on_exit = function(_, code)
      vim.schedule(function()
        flush_log(code)
        if code ~= 0 then
          if opts.on_fail then
            opts.on_fail(code, log_lines, log_path)
          else
            local tail = {}
            for i = math.max(1, #log_lines - 4), #log_lines do
              table.insert(tail, log_lines[i])
            end
            local msg = ("%s failed (exit %d)\nlog: %s\n--- last lines ---\n%s")
              :format(tag, code, log_path, table.concat(tail, "\n"))
            vim.notify(msg, vim.log.levels.ERROR, { timeout = 15000 })
            require("utils.log").error("ue.runner", msg)
          end
          return
        end
        if opts.on_exit then opts.on_exit(code, log_lines, log_path) end
      end)
    end,
  }
  if opts.cwd then job_opts.cwd = opts.cwd end
  if opts.env then job_opts.env = opts.env end

  return vim.fn.jobstart(cmd, job_opts)
end

--- Run PCH prebuild + include-dir unification in background after slim.
--- @param path string the compile_commands.json file to process
--- @param targets string[]|nil list of compile_commands targets; after pipeline
---        finishes the first target is copied to the others and clangd restarts.
local function run_compile_commands_pipeline(path, targets)
  -- ue.cdb.pipeline drives the expand → pch → resolve → unify → prune
  -- chain. We inject `_logged_jobstart` here so the pipeline module stays
  -- import-safe (no circular require to ue.lua) and headlessly testable.
  local pipeline = require("ue.cdb.pipeline")
  pipeline.set_runtime({
    jobstart  = M._logged_jobstart,
    notify    = function(msg, level) vim.notify(msg, level) end,
    log_error = function(scope, msg) require("utils.log").notify_error(scope, msg) end,
  })
  pipeline.run(path, targets)
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

  return false, "compile_commands.json not found at any candidate path"
end

local function generate_compile_commands(ctx, progress)
  local targets = compile_commands_targets(ctx)

  -- PRIMARY: generate from .rsp files. UBT writes one Module.<Mod>.{cpp.obj,cppa8.o}.rsp
  -- per unity TU at compile time, containing the exact clang/MSVC command line
  -- (sysroot, -I, -D, PCH, -c <unity.cpp>). This is the most complete and
  -- accurate source of truth — covers Engine + game modules uniformly across
  -- Win64 / Android / IOS / Linux.
  --
  -- Why rsp instead of `Build.bat -Mode=GenerateClangDatabase`:
  --   1. GenerateClangDatabase only emits modules the active *target* links;
  --      Engine modules used by the runtime are often missing.
  --   2. Re-running Build.bat costs 30-60s; reading rsp files costs <2s.
  --   3. The unity-rsp pipeline produces identical args to what the build
  --      actually used, so PCH/macro mismatches are eliminated by construction.
  local rsp_count, rsp_path = generate_compile_commands_from_rsp(ctx, progress)
  if rsp_count and rsp_count > 0 then
    run_compile_commands_pipeline(targets[1], targets)
    return true, rsp_path .. " (" .. rsp_count .. " entries from .rsp files)"
  end

  -- FALLBACK: an existing UBT-generated compile_commands.json at a target path.
  -- Only used if no rsp files are present (fresh clone / pre-build).
  for _, target in ipairs(targets) do
    if _ufs.is_file(target) and vim.fn.getfsize(target) > 1024 then
      slim_compile_commands_file(target)
      run_compile_commands_pipeline(target, targets)
      return true, target .. " (UBT, existing)"
    end
  end

  -- FALLBACK 2: search candidate locations (Engine/Intermediate/Build/, project root, fd search)
  local ok_existing, existing_path = export_compile_commands_to_engine_root(ctx)
  if ok_existing then
    run_compile_commands_pipeline(targets[1], targets)
    return true, existing_path .. " (UBT)"
  end

  return false,
    "No engine compile_commands source found. Build the project once (UBT writes Module.*.rsp under Intermediate/Build) or place a compile_commands.json at the engine root."
end

-- ==========================================================================
-- BUILD COMMAND (UBT/Build.bat — platform from state.target_platform)
-- ==========================================================================

-- Build a UBT/Build.bat command for the platform+configuration persisted in
-- state.json (set via :UESetPlatform). Despite the legacy name, this is
-- platform-agnostic — Win64/Android/IOS/Linux all flow through the same
-- "Build.bat <Target> <Platform> <Configuration> -Project=..." invocation.
-- Kept as `android_build_command` for now to avoid breaking the public
-- M.android_build_command API surface; rename together when there are
-- no external callers left.
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
    if not is_windows_path(build_bat_file) and not _ufs.is_file(build_bat_file) then
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
        local msg = ("UE build finished with exit code %d"):format(code)
        vim.notify(msg, level)
        if code ~= 0 then require("utils.log").error("ue.build", msg) end
      end)
    end,
  })
  if active_jobid <= 0 then
    CORE_RT.build_term_jobid = nil
    if opts.quickfix_title then
      set_build_status("BERR")
    end
    require("utils.log").notify_error("ue.build", "Failed to start UE build terminal")
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
    local root = _ufs.common_ancestor({ ctx.engine_root, ctx.project_root })
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
  if list_type == "all" and not _ufs.is_file(list_path) and _ufs.is_file(ctx.paths.workspace_list) then
    -- Older caches may not have workspace_all.files yet. Fall back to the
    -- code-only list so picker startup stays fast until :UEPrepare refreshes.
    list_path = ctx.paths.workspace_list
  end
  if not _ufs.is_file(list_path) then
    return nil, "No cached file list (run :UEPrepare first)"
  end

  return {
    list_path = list_path,
    root = workspace_root(ctx),
    ctx = ctx,
  }
end

-- ── Freshness notification: per-root, per-(state) deduped ────────────────
-- Picker / grep entrypoints call notify_prepare_freshness(ctx, surface_label)
-- to surface a one-shot warning when the cached lists are stale relative to
-- the worktree. Stays out of the way once acknowledged for that root+state.
-- Reset on :UEPrepare completion (handled in prepare_async's finalization).
-- State table lives on CORE_RT to avoid burning module-level local slots
-- (LuaJIT main function has a hard 200-local cap).
CORE_RT.freshness_notified = CORE_RT.freshness_notified or {}

do
  function CORE_RT.notify_freshness(ctx, surface)
    if not ctx then return end
    local state = prepare_freshness(ctx)
    if state == "fresh" or state == "unknown" then
      return  -- silence: trustworthy enough OR unable to judge (no .git/index)
    end
    local key = status_root_key(ctx)
    if not key or key == "" then return end
    local last = CORE_RT.freshness_notified[key]
    if last == state then return end  -- already warned for this state on this root
    CORE_RT.freshness_notified[key] = state

    local msg
    if state == "in_progress" then
      msg = ("[%s] :UEPrepare is still running — results may be incomplete"):format(surface or "ue")
    elseif state == "never" then
      msg = ("[%s] No cached file list yet — run :UEPrepare for accurate results"):format(surface or "ue")
    else  -- stale
      msg = ("[%s] :UEPrepare is stale (worktree changed since last run) — results may miss new files. Run :UEPrepare to refresh."):format(surface or "ue")
    end
    vim.schedule(function()
      vim.notify(msg, vim.log.levels.WARN, { title = "UE" })
    end)
  end

  function CORE_RT.clear_freshness(ctx)
    if not ctx then return end
    local key = status_root_key(ctx)
    if key and key ~= "" then
      CORE_RT.freshness_notified[key] = nil
    end
  end
end

function CORE_RT.grep_live_search_ready(pattern, min_chars)
  min_chars = tonumber(min_chars) or 2
  return #trim(tostring(pattern or "")) >= min_chars
end

function CORE_RT.grep_backend_title(base, backend_label)
  backend_label = trim(tostring(backend_label or ""))
  base = trim(tostring(base or ""))
  if base == "" then
    base = "Grep All Code"
  end
  if backend_label == "" then
    return base
  end
  if base:find("%[" .. vim.pesc(backend_label) .. "%]") then
    return base
  end
  return base .. " [" .. backend_label .. "]"
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
      if _ufs.is_absolute_path(line) then
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

  -- Lazy-start ue_watch so subsequent edits/adds get tracked into the
  -- persistent dirty set even if the user never runs :UEPrepare this session.
  -- Without this, freshness banners on <space><space> would only become
  -- truthful AFTER the first explicit :UEPrepare of the session (which is
  -- exactly the failure mode that landed us here). Idempotent — M.start
  -- early-returns when a handle is already live.
  do
    local ok_watch, watch = pcall(require, "utils.ue_watch")
    if ok_watch and type(watch.start) == "function" then
      local already = (type(watch.status) == "function") and (watch.status() or {}).running
      if not already and info.ctx and info.ctx.paths then
        pcall(watch.start, {
          root = info.root,
          csearch_index = info.ctx.paths.csearch_idx,
          shader_filelist = info.ctx.paths.workspace_list,
          gtags_db = info.ctx.paths.workspace_db,
          dirty_json_path = info.ctx.paths.dirty_json,
          debounce_ms = 1500,
        })
      end
    end
  end

  CORE_RT.notify_freshness(info.ctx, "find files")

  local rg = _uproc.first_executable({ "rg" })
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
            if _ufs.is_absolute_path(text) then
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
  CORE_RT.notify_freshness(ctx, "grep")

  local snacks = require("snacks")
  local code_search = require("utils.code_search")
  local cs_ctx = { workspace_root = workspace_root(ctx), csearch_idx = ctx.paths and ctx.paths.csearch_idx or nil }
  local has_index = code_search.is_indexed(cs_ctx)
  local backend_label = has_index and "csearch" or "rg"

  local title_default = CORE_RT.grep_backend_title("Grep All Code", backend_label)
  local live_min_chars = opts.live_min_chars or 2
  local live_max_count = opts.max_count or 5000
  local short_live_max_count = opts.short_live_max_count or 1200

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

  -- ─ Diagnostic trace (opt-in via vim.g.ue_grep_trace) ────────────────
  -- When enabled, write per-event lines to a stable log path so we can
  -- post-mortem WHY the picker felt laggy on a real human typing session.
  -- Zero overhead when disabled (single boolean check per event).
  --
  -- Toggle: :UEGrepTraceToggle  (or set vim.g.ue_grep_trace = true)
  -- Log:    vim.fn.stdpath("state") .. "/ue_grep_trace.log"
  local trace_enabled = vim.g.ue_grep_trace == true
  local trace_log_path = vim.fn.stdpath("state") .. "/ue_grep_trace.log"
  local trace_t0 = vim.loop.hrtime()
  local function trace(fmt, ...)
    if not trace_enabled then return end
    local ms = (vim.loop.hrtime() - trace_t0) / 1e6
    local line = string.format("[+%8.1fms] " .. fmt, ms, ...)
    local f = io.open(trace_log_path, "a")
    if f then f:write(line .. "\n"); f:close() end
  end
  if trace_enabled then
    -- Truncate at session start so each <leader>/ produces a clean timeline.
    local f = io.open(trace_log_path, "w")
    if f then
      f:write(string.format("=== UE grep trace  %s  backend=%s  grouping=%s  has_index=%s ===\n",
        os.date("%Y-%m-%d %H:%M:%S"), backend_label,
        tostring(grouping_enabled), tostring(has_index)))
      f:close()
    end
  end

  -- Temporary always-on diagnostic for the current "<leader>/ missing
  -- results" investigation. The user explicitly allowed logs; remove after
  -- they confirm the fix. This captures backend + mode + result counts
  -- without requiring the heavier trace toggle above.
  local debug_log_path = vim.fn.stdpath("state") .. "/ue_grep_backend_debug.log"
  local function grep_debug(fmt, ...)
    local ok, line = pcall(string.format, fmt, ...)
    if not ok then
      line = tostring(fmt)
    end
    local f = io.open(debug_log_path, "a")
    if f then
      f:write(os.date("%Y-%m-%d %H:%M:%S") .. " " .. line .. "\n")
      f:close()
    end
  end
  do
    local idx_size = nil
    if cs_ctx.csearch_idx then
      local st = vim.loop.fs_stat(cs_ctx.csearch_idx)
      idx_size = st and st.size or nil
    end
    grep_debug("OPEN backend=%s has_index=%s idx=%s idx_size=%s title=%s",
      tostring(backend_label), tostring(has_index), tostring(cs_ctx.csearch_idx),
      tostring(idx_size), tostring(CORE_RT.grep_backend_title(opts.title or title_default, backend_label)))
  end

  -- ── csearch fast path ────────────────────────────────────────────────
  if has_index then
    snacks.picker.pick({
      source = "ue_grep_csearch",
      title = CORE_RT.grep_backend_title(opts.title or title_default, backend_label),
      search = opts.search or "",
      live = true,
      need_search = true,
      limit = live_max_count,
      limit_live = live_max_count,
      layout = { preset = "telescope" },
      -- Search mode toggles. snacks auto-merges these with built-in toggles
      -- (regex, follow, hidden, ignored, modified — see snacks/picker/config/
      -- defaults.lua). For each entry it auto-generates a toggle_<name>
      -- action that flips picker.opts[name] then calls picker:find().
      --
      -- Title icon semantics: snacks renders icon when picker.opts[name] ==
      -- toggle.value. We want "icon visible = mode ENABLED" so:
      --   regex: value=true   → R shows when regex mode is ON (literal off)
      --   word:  value=true   → W shows when whole-word ON
      --   case:  value=true   → C shows when case-sensitive ON
      -- Without overriding regex here, snacks' default value=false would
      -- show R when LITERAL mode is on, which is reverse intuition.
      regex = false,
      word = false,
      case = false,
      toggles = {
        regex = { icon = "R", value = true },
        word  = { icon = "W", value = true },
        case  = { icon = "C", value = true },
      },
      -- Keymaps: Alt-r/g/x/w/c = mode toggles, shown live as R/W/C icons in
      -- the picker title. <a-r> is the intuitive "regex" toggle (matches
      -- snacks' own default); <a-g> = "grep regex" mnemonic alias. Both flip
      -- the same regex flag. <a-w>/<a-x> = whole-word, <a-c> = case-sensitive.
      -- NOTE: <a-r> previously collided with NVIDIA App's global Performance
      -- Overlay hotkey; if it ever stops reaching nvim again, use <a-g>.
      win = vim.tbl_deep_extend("force", grouping_enabled and fast_tab_keys.win or {}, {
        input = { keys = {
          ["<a-r>"] = { "ue_grep_toggle_regex", mode = { "i", "n" } },
          ["<a-g>"] = { "ue_grep_toggle_regex", mode = { "i", "n" } },
          ["<a-x>"] = { "ue_grep_toggle_word",  mode = { "i", "n" } },
          ["<a-w>"] = { "ue_grep_toggle_word",  mode = { "i", "n" } },
          ["<a-c>"] = { "ue_grep_toggle_case",  mode = { "i", "n" } },
        } },
      }),
      actions = {
        ue_grep_toggle_regex = function(picker)
          picker.opts.regex = not picker.opts.regex
          require("snacks").notify((picker.opts.regex and "✓ regex ON " or "✗ regex OFF (literal)"),
            { title = "UE grep", level = "info" })
          picker.list:set_target(); picker:find()
        end,
        ue_grep_toggle_word = function(picker)
          picker.opts.word = not picker.opts.word
          require("snacks").notify((picker.opts.word and "✓ whole-word ON " or "✗ whole-word OFF"),
            { title = "UE grep", level = "info" })
          picker.list:set_target(); picker:find()
        end,
        ue_grep_toggle_case = function(picker)
          picker.opts.case = not picker.opts.case
          require("snacks").notify((picker.opts.case and "✓ case-sensitive ON " or "✗ ignore-case"),
            { title = "UE grep", level = "info" })
          grep_debug("TOGGLE backend=csearch case=%s", tostring(picker.opts.case == true))
          picker.list:set_target(); picker:find()
        end,
      },
      format = grouping_enabled and format_grouped or nil,
      preview = grouping_enabled and preview_grouped or nil,
      on_show = grouping_enabled and on_show_picker or nil,
      confirm = grouping_enabled and confirm_grouped or nil,
      finder = function(_picker_opts, finder_ctx)
        local pattern = finder_ctx.filter.search
        if not CORE_RT.grep_live_search_ready(pattern, live_min_chars) then
          return function() end
        end
        trace("finder START pattern=%q", pattern)
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
          local pending_len = 0
          local items_received = 0
          local items_emitted = 0

          local t_cs_spawn_0 = vim.loop.hrtime()
          local cs_first_line_logged = false
          -- Read mode toggles from picker.opts (Alt-r/Alt-x/Alt-c flip
          -- these in place via snacks auto-generated toggle_<name> actions,
          -- then picker:find() restarts this finder so we see the new values).
          local _picker = finder_ctx and finder_ctx.picker
          local _po = _picker and _picker.opts or {}
          local pattern_len = #trim(tostring(pattern or ""))
          local mode_case = _po.case == true
          local mode_ignore_case = not mode_case
          grep_debug("FINDER backend=csearch pattern=%q regex=%s word=%s case=%s ignore_case=%s max=%d",
            tostring(pattern), tostring(_po.regex == true), tostring(_po.word == true),
            tostring(mode_case), tostring(mode_ignore_case),
            pattern_len <= live_min_chars and short_live_max_count or live_max_count)
          local stop = code_search.stream(cs_ctx, pattern, {
            code_only   = opts.code_only,
            smart_case  = true,
            max_count   = pattern_len <= live_min_chars and short_live_max_count or live_max_count,
            regex       = _po.regex == true,   -- snacks default false = literal
            word        = _po.word == true,
            case        = mode_case,
            ignore_case = mode_ignore_case,
          }, {
            on_line = function(file, lnum, col, text)
              if not cs_first_line_logged then
                cs_first_line_logged = true
                trace("PHASE csearch_first_line=%.2fms after_spawn",
                  (vim.loop.hrtime() - t_cs_spawn_0) / 1e6)
              end
              -- Buffer the item; we drain inside the sleep loop below
              -- where it's safe to call cb (we're guaranteed not yet done).
              pending_len = pending_len + 1
              pending[pending_len] = {
                text = file .. ":" .. lnum .. ":" .. col .. ":" .. text,
                pos  = { lnum, math.max(0, col - 1) },
                file = file,
              }
              items_received = items_received + 1
            end,
            on_done = function(code, err)
              done = true
              trace("csearch DONE pat=%q recv=%d code=%s err=%s elapsed=%.1fms",
                pattern, items_received, tostring(code),
                tostring(err and err:sub(1,80)),
                (vim.loop.hrtime() - t_cs_spawn_0) / 1e6)
              grep_debug("DONE backend=csearch pattern=%q recv=%d code=%s err=%s elapsed=%.1fms",
                tostring(pattern), items_received, tostring(code),
                tostring(err and err:sub(1, 120)),
                (vim.loop.hrtime() - t_cs_spawn_0) / 1e6)
              if err and code ~= 0 then
                vim.schedule(function()
                  vim.notify("UE grep [csearch]: " .. err, vim.log.levels.WARN, { title = "UE" })
                end)
              end
            end,
          })
          trace("PHASE cs_stream_call_returned=%.2fms",
            (vim.loop.hrtime() - t_cs_spawn_0) / 1e6)

          -- Watchdog timer: snacks aborts our async task by killing the
          -- coroutine — when that happens our drain loop never executes
          -- another iteration so its abort-detection branch never fires
          -- and stop() never runs. Result: csearch processes accumulate.
          --
          -- Fix: an independent vim.loop timer outside the coroutine.
          -- It checks the picker's filter every 30ms and kills csearch
          -- the moment we detect the user moved on. This survives
          -- coroutine death.
          local watchdog_killed = false
          local watchdog
          local ok_timer, timer = pcall(vim.loop.new_timer)
          if ok_timer and timer then
            watchdog = timer
            trace("WATCHDOG start pat=%q", pattern)
            local ok_start = pcall(function()
              watchdog:start(30, 30, vim.schedule_wrap(function()
                -- Snapshot reference; timer callback may fire after
                -- watchdog has been nilled by the outer cleanup path.
                local t = watchdog
                if watchdog_killed or done then
                  if t and not t:is_closing() then
                    pcall(function() t:stop() end)
                    pcall(function() t:close() end)
                  end
                  return
                end
                -- IMPORTANT: do NOT compare against finder_ctx.filter —
                -- snacks captures the filter REFERENCE at finder start
                -- and never updates it for this finder. Compare against
                -- the LIVE picker input value instead.
                local cur = nil
                local p = finder_ctx and finder_ctx.picker
                if p and p.input and p.input.filter then
                  cur = p.input.filter.search
                end
                if cur ~= nil and cur ~= pattern then
                  watchdog_killed = true
                  trace("WATCHDOG kill pat=%q new=%q recv=%d",
                    pattern, tostring(cur), items_received)
                  pcall(stop)
                  if t and not t:is_closing() then
                    pcall(function() t:stop() end)
                    pcall(function() t:close() end)
                  end
                end
              end))
            end)
            if not ok_start then
              trace("WATCHDOG start FAILED pat=%q", pattern)
            end
          else
            trace("WATCHDOG new_timer FAILED pat=%q", pattern)
          end
          local function kill_watchdog()
            watchdog_killed = true
            if watchdog and not watchdog:is_closing() then
              pcall(function() watchdog:stop() end)
              pcall(function() watchdog:close() end)
            end
          end

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
          local tick_count = 0
          local longest_drain_ms = 0
          while not done and elapsed < max_total_ms do
            tick_count = tick_count + 1
            -- Abort detection: compare against LIVE picker input, not the
            -- finder_ctx.filter snapshot (snacks captures the filter at
            -- finder start and never updates it for this finder, so
            -- finder_ctx.filter.search would always equal `pattern`).
            local cur_search = nil
            do
              local p = finder_ctx and finder_ctx.picker
              if p and p.input and p.input.filter then
                cur_search = p.input.filter.search
              end
            end
            if cur_search ~= nil and cur_search ~= pattern then
              trace("ABORT pat=%q new=%q tick=%d elapsed=%dms recv=%d emit=%d pending=%d",
                pattern, tostring(cur_search), tick_count, elapsed,
                items_received, items_emitted, pending_len - read_idx + 1)
              pcall(stop)
              break
            end
            -- Drain up to CB_BUDGET items accumulated since last slice.
            -- Use read_idx + pending_len rather than #pending: drained
            -- entries are set to nil below, and Lua's length operator is
            -- undefined on tables with holes. Using #pending here used to
            -- drop tail hits (e.g. backend recv=15 but picker emitted=12).
            local n = pending_len
            if read_idx <= n then
              local stop_at = math.min(n, read_idx + CB_BUDGET - 1)
              local drain_t0 = vim.loop.hrtime()
              for i = read_idx, stop_at do
                local item = pending[i]
                if item then
                  cb(item)
                  items_emitted = items_emitted + 1
                end
                pending[i] = nil
              end
              local drain_ms = (vim.loop.hrtime() - drain_t0) / 1e6
              if drain_ms > longest_drain_ms then longest_drain_ms = drain_ms end
              if drain_ms > 20 then
                trace("SLOW DRAIN tick=%d elapsed=%dms emitted=%d in %.1fms (budget=%d, queue_len=%d)",
                  tick_count, elapsed, stop_at - read_idx + 1, drain_ms, CB_BUDGET, n - stop_at)
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
          -- Detect WHY we exited the loop. Use LIVE picker input (not
          -- finder_ctx.filter snapshot — same reason as drain abort).
          local final_cur = nil
          do
            local p = finder_ctx and finder_ctx.picker
            if p and p.input and p.input.filter then
              final_cur = p.input.filter.search
            end
          end
          local aborted = (final_cur ~= nil and final_cur ~= pattern)

          if not aborted then
            -- Final drain after done (still safe — we haven't returned).
            -- Resume from read_idx so we don't double-cb earlier items.
            local final_drain_t0 = vim.loop.hrtime()
            local final_count = 0
            for i = read_idx, pending_len do
              local item = pending[i]
              if item then
                cb(item)
                final_count = final_count + 1
                items_emitted = items_emitted + 1
              end
              pending[i] = nil
            end
            local final_drain_ms = (vim.loop.hrtime() - final_drain_t0) / 1e6
            trace("FINAL DRAIN pat=%q count=%d in %.1fms", pattern, final_count, final_drain_ms)
            grep_debug("FINAL backend=csearch pattern=%q final_count=%d total_recv=%d emitted_before_final=%d",
              tostring(pattern), final_count, items_received, items_emitted)
          end

          -- Stop the subprocess if it's still alive (timeout / abort path).
          if not done then
            pcall(stop)
          end

          -- Watchdog cleanup: normal completion path. Abort path also
          -- kills it from inside the timer callback once it detects the
          -- abort; this is the catch-all for the "loop exited because
          -- done=true" path.
          kill_watchdog()

          trace("finder END pat=%q aborted=%s ticks=%d elapsed=%dms recv=%d emit=%d longest_drain=%.1fms",
            pattern, tostring(aborted), tick_count, elapsed,
            items_received, items_emitted, longest_drain_ms)
          grep_debug("END backend=csearch pattern=%q aborted=%s recv=%d emitted=%d longest_drain=%.1fms",
            tostring(pattern), tostring(aborted), items_received, items_emitted, longest_drain_ms)
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
    -- Make the fall-through VISIBLE: a silent nil here means ue_project_grep
    -- runs a plain dir-walk that excludes ThirdParty and is NOT index-backed,
    -- so the user gets incomplete results with no signal (the bug this whole
    -- change fixes). One-shot WARN per buffer (no ticker — see P5).
    if not vim.b._ue_grep_fallback_warned then
      vim.b._ue_grep_fallback_warned = true
      vim.schedule(function()
        vim.notify(
          "UE grep: no csearch index and no cached file list — falling back to a " ..
          "slow directory walk that may MISS files. Run :UEPrepare for complete, " ..
          "sub-second grep.",
          vim.log.levels.WARN, { title = "UE" })
      end)
    end
    return nil
  end

  local rg = _uproc.first_executable({ "rg" })
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
    title = CORE_RT.grep_backend_title(opts.title or title_default, backend_label),
    search = opts.search or "",
    live = true,
    need_search = true,
    limit = live_max_count,
    limit_live = live_max_count,
    layout = { preset = "telescope" },
    -- Same toggle wiring as csearch path (see comment there).
    regex = false,
    word = false,
    case = false,
    toggles = {
      regex = { icon = "R", value = true },
      word  = { icon = "W", value = true },
      case  = { icon = "C", value = true },
    },
    win = vim.tbl_deep_extend("force", grouping_enabled and fast_tab_keys.win or {}, {
      input = { keys = {
        ["<a-g>"] = { "ue_grep_toggle_regex", mode = { "i", "n" } },
        ["<a-x>"] = { "ue_grep_toggle_word",  mode = { "i", "n" } },
        ["<a-w>"] = { "ue_grep_toggle_word",  mode = { "i", "n" } },
        ["<a-c>"] = { "ue_grep_toggle_case",  mode = { "i", "n" } },
      } },
    }),
    actions = {
      ue_grep_toggle_regex = function(picker)
        picker.opts.regex = not picker.opts.regex
        require("snacks").notify((picker.opts.regex and "✓ regex ON " or "✗ regex OFF (literal)"),
          { title = "UE grep", level = "info" })
        picker.list:set_target(); picker:find()
      end,
      ue_grep_toggle_word = function(picker)
        picker.opts.word = not picker.opts.word
        require("snacks").notify((picker.opts.word and "✓ whole-word ON " or "✗ whole-word OFF"),
          { title = "UE grep", level = "info" })
        picker.list:set_target(); picker:find()
      end,
      ue_grep_toggle_case = function(picker)
        picker.opts.case = not picker.opts.case
        require("snacks").notify((picker.opts.case and "✓ case-sensitive ON " or "✗ ignore-case"),
          { title = "UE grep", level = "info" })
        grep_debug("TOGGLE backend=rg case=%s", tostring(picker.opts.case == true))
        picker.list:set_target(); picker:find()
      end,
    },
    format = grouping_enabled and format_grouped or nil,
    preview = grouping_enabled and preview_grouped or nil,
    on_show = grouping_enabled and on_show_picker or nil,
    confirm = grouping_enabled and confirm_grouped or nil,
    finder = function(picker_opts, finder_ctx)
      local pattern = finder_ctx.filter.search
      if not CORE_RT.grep_live_search_ready(pattern, live_min_chars) then
        return function() end
      end

      local loaded_files = ensure_files()
      if not loaded_files then
        return function() end
      end

      -- Read mode toggles from picker.opts (same wiring as csearch path).
      local _picker = finder_ctx and finder_ctx.picker
      local _po = _picker and _picker.opts or {}
      local mode_regex = _po.regex == true
      local mode_word  = _po.word == true
      local mode_case  = _po.case == true
      local mode_ignore_case = not mode_case
      grep_debug("FINDER backend=rg pattern=%q regex=%s word=%s case=%s ignore_case=%s files_ready=%s",
        tostring(pattern), tostring(mode_regex), tostring(mode_word), tostring(mode_case),
        tostring(mode_ignore_case), tostring(loaded_files ~= nil))

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
          "--max-columns=500",
          "--max-columns-preview",
          "-0",
        }
        -- Case mode: explicit case-sensitive ⇒ -s, else ignore-case. UE CVar
        -- searches are frequently typed as camelCase fragments (e.g.
        -- r.useLandscape) while source/config uses r.UseLandscape..., so the
        -- default must not be rg smart-case.
        if mode_case then
          table.insert(base_args, "--case-sensitive")
        else
          table.insert(base_args, "--ignore-case")
        end
        -- Regex mode: when off, take input literally. -F is rg's
        -- fixed-strings flag; combined with -w it still matches whole
        -- words (rg treats -F as the engine, -w as a wrapper).
        if not mode_regex then
          table.insert(base_args, "--fixed-strings")
        end
        if mode_word then
          table.insert(base_args, "--word-regexp")
        end
        table.insert(base_args, "--")
        table.insert(base_args, pattern)

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
    if bufname == "" or _ufs.path_has_prefix(bufname, engine_root) then
      return engine_root
    end
    -- Pass the bufname through so resolve_context picks up the buffer's
    -- own engine, not the cwd's engine. Critical for multi-engine setups
    -- and for background buffers (lsp may invoke clangd_root for a buf
    -- other than the current one).
    local ctx = resolve_context({ bufname = bufname })
    if ctx and ctx.project_root and _ufs.path_has_prefix(bufname, ctx.project_root) then
      return ctx.engine_root
    end
    if _ufs.path_has_prefix(cwd(), engine_root) then
      return engine_root
    end
  end
  return vim.fs.root(bufname ~= "" and bufname or cwd(), { "compile_commands.json", ".clangd", ".git" }) or cwd()
end

-- Build the minimum-viable ctx that utils.code_search.stream / .is_indexed
-- need: { workspace_root, csearch_idx }. Returns nil when bufnr is not in a
-- recognized UE project (so callers can short-circuit gracefully).
function M.csearch_ctx(bufnr)
  bufnr = bufnr or 0
  local bufname = norm(vim.api.nvim_buf_get_name(bufnr))
  local ctx = resolve_context({ bufname = bufname ~= "" and bufname or nil })
  if not ctx or not ctx.engine_root then return nil end
  return {
    workspace_root = workspace_root(ctx),
    csearch_idx = ctx.paths and ctx.paths.csearch_idx or nil,
  }
end

-- Public hook called by lua/utils/ue_watch.lua when a shader file is added
-- or deleted between :UEPrepare runs. Idempotent — safe to call repeatedly.
-- Returns (ok, message). On a project with ~1500 shaders this is ~1.1s wall.
function M.gtags_rebuild_shaders()
  local ctx, err = resolve_context()
  if not ctx then return false, err or "no UE context" end
  if not ctx.paths or not ctx.paths.workspace_list or not ctx.paths.workspace_db then
    return false, "ctx.paths missing workspace_list/workspace_db"
  end
  local root = workspace_root(ctx)
  local ok, msg = build_gtags_db(root, ctx.paths.workspace_list, ctx.paths.workspace_db, "workspace")
  return ok, msg
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

    local rg = _uproc.first_executable({ "rg" })
    if not rg then
      on_done(false)
      return
    end

    local dirs = {}
    local seen = {}
    local function add_dir(dir)
      dir = norm(dir)
      if dir ~= "" and _ufs.is_dir(dir) and not seen[dir] then
        seen[dir] = true
        dirs[#dirs + 1] = dir
      end
    end

    if ctx.project_root and ctx.project_root ~= "" then
      for _, relative in ipairs(existing_relative_dirs(ctx.project_root, CORE_RT.project_index_dirs(ctx))) do
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
      local root = _ufs.common_ancestor({ ctx.engine_root, ctx.project_root })
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
  _ufs.ensure_dir(_ufs.dirname(path))

  if not _ufs.is_file(path) then
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

-- Wipe all project-scoped cache artifacts when the active project changes.
-- (Wrapped in do/end so neither this helper NOR set_project occupies a
-- LuaJIT main-chunk local slot — see skill luajit-200-local-cap-with-loader-cache-mask.
-- We expose set_project through CORE_RT instead.)
do
-- Wipe all project-scoped cache artifacts when the active project changes.
-- Engine-only artifacts (engine.files, engine .git mtime probe) survive — the
-- engine tree itself hasn't moved. List files, csearch index, gtags DB, and
-- per-platform cdb shards all reflect the OLD project's content and would
-- silently feed `<space><space>` / grep stale results until the next full
-- :UEPrepare. We delete them eagerly so callers see "never" (not "fresh") and
-- get a loud `notify_freshness` banner until they rerun :UEPrepare manually.
--
-- NOTE: by design this does NOT auto-trigger UEPrepare. Per-user rule:
-- :UEPrepare runs only on explicit user request. Our job is to invalidate so
-- the staleness signal becomes truthful — not to second-guess timing.
local function invalidate_project_scoped_cache(engine_root, reason)
  local paths = cache_paths(engine_root)
  local victims = {
    -- legacy single-path file lists + csearch (pre-v3.1 layout)
    paths.project_list,
    paths.workspace_list,
    paths.workspace_all_list,
    paths.csearch_idx,
    paths.csearch_idx .. "~",
    paths.csearch_idx .. "~~",
    -- gtags DB (project-scoped; tags from old project tree are wrong)
    join(paths.gtags_root, "GTAGS"),
    join(paths.gtags_root, "GPATH"),
    join(paths.gtags_root, "GRTAGS"),
    join(paths.workspace_db, "GTAGS"),
    join(paths.workspace_db, "GPATH"),
    join(paths.workspace_db, "GRTAGS"),
    -- cdb shards (per-platform compile_commands referencing old project paths)
    paths.index_current_cdb,
    paths.index_hot_cdb,
    paths.index_full_cdb,
    paths.index_inject_full_cdb,
    paths.index_state,
    paths.index_queue,
    -- runtime dirty set tied to old project
    paths.dirty_json,
  }
  local removed = 0
  for _, p in ipairs(victims) do
    if p and _ufs.is_file(p) then
      if pcall(os.remove, p) then removed = removed + 1 end
    end
  end

  -- v3.1: csearch + gtags lists now live in per-platform subdirs
  -- (csearch/<key>/, gtags/<key>/). A PROJECT switch invalidates EVERY
  -- platform's grep cache (they all index the old project's files), so wipe
  -- the whole per-platform tree, not just the active one.
  for _, sub in ipairs({ "csearch", "gtags" }) do
    local dir = join(paths.cache, sub)
    if _ufs.is_dir(dir) then
      if pcall(vim.fn.delete, dir, "rf") then removed = removed + 1 end
    end
  end

  -- Also wipe per-shard cdb files (per-platform CDB shards reference old
  -- project source paths). The shards live under cdb/compile_commands/shards/.
  local shards_dir = join(paths.index_cdb_dir, "shards")
  if _ufs.is_dir(shards_dir) then
    if pcall(vim.fn.delete, shards_dir, "rf") then removed = removed + 1 end
  end

  -- Also nuke clangd index .idx files keyed by old project_name. Engine_root
  -- → project_name derivation is in cache_paths; the .idx filename embeds
  -- it. We list and rm by glob since multiple suffix variants exist.
  if _ufs.is_dir(paths.active_index_dir) then
    local glob = vim.fn.globpath(paths.active_index_dir, "*.idx", false, true)
    for _, f in ipairs(glob) do
      if pcall(os.remove, f) then removed = removed + 1 end
    end
  end

  -- Force prepare_freshness to re-read from disk on next call.
  CORE_RT.freshness_notified = {}
  CORE_RT.context_cache = {}

  -- Re-probe the csearch toolchain next time (a stale negative probe from a
  -- cold start would otherwise keep is_indexed() false for the session).
  pcall(function() require("utils.code_search")._reset_probe_cache() end)

  -- Tell ue_watch (if running) to flush its dirty set — it referred to old
  -- project's files. Best-effort; module may not be loaded yet.
  local ok_watch, watch = pcall(require, "utils.ue_watch")
  if ok_watch and type(watch.clear_persistent_dirty) == "function" then
    watch.clear_persistent_dirty("set_project:" .. (reason or "switch"))
  end
  if ok_watch and type(watch.stop) == "function" then
    pcall(watch.stop)  -- old watch handle was rooted at previous project_root
  end

  return removed
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

  local project_root, uproject, err = resolve_project_input(input, engine_root)
  if not project_root then
    vim.notify(err, vim.log.levels.WARN)
    return
  end

  -- Detect actual project switch BEFORE persisting (persist overwrites state).
  local prev = read_state(engine_root)
  local prev_project = prev and prev.project_root or nil
  local prev_engine = prev and prev.engine_root or nil
  -- Switch = project_root changed OR the engine_root recorded in this
  -- state.json no longer matches the live engine_root. The engine dimension
  -- matters because caches (csearch/gtags/cdb) index BOTH the project and the
  -- engine tree; pointing the same state.json at a different engine makes them
  -- stale even if the project path is unchanged.
  local project_switched = prev_project and norm(prev_project) ~= norm(project_root) or false
  local engine_switched = prev_engine and prev_engine ~= "" and norm(prev_engine) ~= norm(engine_root) or false
  local switched = project_switched or engine_switched

  persist_project(engine_root, project_root, uproject)

  local removed = 0
  if switched then
    removed = invalidate_project_scoped_cache(engine_root, project_switched and "project-switch" or "engine-switch")
  end

  invalidate_status_cache()
  refresh_statusline()

  local msg = "UE project set:\nEngine: " .. engine_root .. "\nProject: " .. project_root
  if switched then
    local what = project_switched and ("Project CHANGED (was: %s)"):format(prev_project or "?")
      or ("Engine CHANGED (was: %s)"):format(prev_engine or "?")
    msg = msg .. ("\n\n%s\n  → invalidated %d cache entries (lists / csearch / gtags / cdb shards, all platforms)\n  → run :UEPrepare to rebuild (or :UEPrepare! to force a clean full pass)"):format(what, removed)
    vim.notify(msg, vim.log.levels.WARN, { title = "UE" })
  else
    vim.notify(msg, vim.log.levels.INFO, { title = "UE" })
  end
end
CORE_RT.set_project = set_project
end -- close do-block opened above invalidate_project_scoped_cache

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

-- Tell ue.lua how to find the .uproject when only a workspace root is given
-- to :UESetProject. Stored per engine_root in state.json so different engines
-- can have different conventions and the value never appears in source code.
local function set_uproject_relative_path_command(input)
  local engine_root = current_engine_root()
  if not engine_root then
    vim.notify("No Unreal Engine root found from current buffer or cwd", vim.log.levels.WARN)
    return
  end

  input = trim(input)
  if input == "" then
    local state = read_state(engine_root)
    input = vim.fn.input(
      "uproject path relative to workspace root (e.g. Sub/Dir/Foo.uproject), empty to clear: ",
      state.uproject_relative_path or ""
    )
  end

  if input == "" then
    update_state_field(engine_root, "uproject_relative_path", nil)
    invalidate_status_cache()
    vim.notify("UE uproject_relative_path cleared (engine: " .. engine_root .. ")")
    return
  end

  local rel, err = set_uproject_relative_path(engine_root, input)
  if err then
    vim.notify(err, vim.log.levels.WARN)
    return
  end
  invalidate_status_cache()
  vim.notify("UE uproject_relative_path set:\nEngine: " .. engine_root .. "\nRelative: " .. (rel or input))
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

-- Fast platform swap: when shards already exist for the requested (platform,
-- configuration), flip manifest.active + re-merge into the top-level cdb
-- WITHOUT re-running :UEPrepare. Returns ok, new_active_key, stats|err.
--
-- Preconditions:
--   * state.target_platform / state.target_configuration ALREADY persisted
--     (set_platform calls update_state_field before invoking this).
--   * <cache>/cdb/compile_commands/shards/<plat>-<target>-<config>.json exists.
--
-- Side effects on success:
--   * manifest.active set to the best matching shard key + written to disk.
--   * Top-level engine_root/compile_commands.json (and Engine/compile_commands.json)
--     rewritten to be the merged result from all shards, with the new
--     active key winning conflicts.
--   * run_compile_commands_pipeline executes the standard slim/pch/resolve/
--     unify/prune chain so clangd sees the same shape it would after a full
--     :UEPrepare.
--   * vim.cmd("LspRestart clangd") so clangd reloads the swapped cdb.
--
-- Parked on CORE_RT (not declared as a top-level `local function`) to avoid
-- pushing this monolith past LuaJIT's 200-local cap. See skill
-- `luajit-200-local-cap-with-loader-cache-mask` Fix D.
function CORE_RT.fast_swap_active_platform(engine_root)
  -- Prefer resolve_context (gives full ctx with paths cached); fall back to
  -- a synthetic ctx built from state.json when called without a buffer in
  -- the project (rare, but happens for headless tests / engine-root cwd).
  local ctx = resolve_context({ detect_project = true })
  if not ctx or norm(ctx.engine_root or "") ~= norm(engine_root) then
    local state = read_state(engine_root)
    if not state.project_root or state.project_root == "" then
      return false, nil, "no project_root in state.json — open a file in the project first or run :UEPrepare"
    end
    ctx = {
      engine_root = engine_root,
      project_root = state.project_root,
      uproject = state.uproject or find_uproject_in_dir(state.project_root) or "",
      state = state,
      paths = cache_paths(engine_root),
    }
  end
  -- ctx.state was loaded BEFORE set_platform's update_state_field calls
  -- (because resolve_context caches). Re-read so target_platform / config
  -- reflect what the user just selected — otherwise active_key() picks the
  -- stale platform's shard.
  ctx.state = read_state(engine_root)

  local shards = require("ue.cdb.shards")
  local manifest = shards.read_manifest(ctx)
  if not manifest or not manifest.shards or not next(manifest.shards) then
    return false, nil, "no shards on disk yet — run :UEPrepare once to seed the per-platform cache"
  end

  local new_key = shards.active_key(ctx, manifest)
  if new_key == "" or not manifest.shards[new_key] then
    local have = {}
    for k, _ in pairs(manifest.shards) do have[#have + 1] = k end
    table.sort(have)
    return false, nil, string.format(
      "no shard for platform=%s config=%s (have: %s) — run :UEPrepare to build it",
      ctx.state.target_platform or "?",
      ctx.state.target_configuration or "?",
      table.concat(have, ", "))
  end

  -- Flip + persist BEFORE merge so merge_shards' active-bonus picks the new winner.
  manifest.active = new_key
  shards.write_manifest(ctx, manifest)

  local merged, stats = shards.merge_shards(ctx, manifest)
  local json = vim.json.encode(merged)

  local targets = compile_commands_targets(ctx)
  for _, target in ipairs(targets) do
    write_all(target, json)
  end

  -- Run the standard post-process chain (slim + PCH FI inject + resolve +
  -- unify + prune) so clangd sees the same cdb shape as after :UEPrepare.
  run_compile_commands_pipeline(targets[1], targets)

  -- Tell clangd to reload. LspRestart is async — clangd reads the new cdb on
  -- attach, so any open buffer will pick up the swap within ~1s.
  pcall(vim.cmd, "LspRestart clangd")

  return true, new_key, stats
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
    CORE_RT.freshness_notified = {}
    -- Per-platform grep cache: switching platform points csearch/workspace_all
    -- at csearch/<new-key>/ etc. We do NOT delete the previous platform's
    -- index (cross-platform users keep both). If the new platform has no
    -- csearch index yet, the next <leader>/ will surface the visible
    -- "run :UEPrepare" fallback (no silent stale results).
    pcall(function() require("utils.code_search")._reset_probe_cache() end)
    do
      local new_state = read_state(engine_root)
      local new_key = CORE_RT.platform_key_from_state(new_state)
      if new_key ~= "" then
        pcall(CORE_RT.migrate_legacy_csearch_if_needed, engine_root, new_key)
      end
    end

    -- Try the cheap path first: if a shard already exists for the new
    -- (platform,config), flip manifest.active + re-merge in-place (~1s)
    -- instead of forcing a full :UEPrepare (~30-60s).
    local ok, key, info = CORE_RT.fast_swap_active_platform(engine_root)
    if ok then
      vim.notify(("UE platform: %s %s\nFast-swapped to shard %s (%d entries, %d shards merged)"):format(
        plat or default_plat or "(auto)",
        conf or default_conf,
        key,
        info.total_out,
        info.shard_count), vim.log.levels.INFO, { title = "UE", timeout = 4000 })
    else
      vim.notify(("UE platform: %s %s\n%s"):format(
        plat or default_plat or "(auto)",
        conf or default_conf,
        info or "fast-swap failed — run :UEPrepare to generate this platform's shard"),
        vim.log.levels.WARN, { title = "UE", timeout = 6000 })
    end
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
      CORE_RT.freshness_notified = {}
      pcall(function() require("utils.code_search")._reset_probe_cache() end)
      do
        local new_state = read_state(engine_root)
        local new_key = CORE_RT.platform_key_from_state(new_state)
        if new_key ~= "" then
          pcall(CORE_RT.migrate_legacy_csearch_if_needed, engine_root, new_key)
        end
      end

      local ok, key, info = CORE_RT.fast_swap_active_platform(engine_root)
      if ok then
        vim.notify(("UE platform set: %s %s\nFast-swapped to shard %s (%d entries)"):format(
          plat, conf, key, info.total_out),
          vim.log.levels.INFO, { title = "UE", timeout = 4000 })
      else
        vim.notify(("UE platform set: %s %s\n%s"):format(
          plat, conf, info or "Run :UEPrepare to regenerate for this platform"),
          vim.log.levels.WARN, { title = "UE", timeout = 6000 })
      end
    end)
  end)
end

-- export_compile_commands is now an alias for prepare_async (unified flow)
local export_compile_commands

-- stop_android_debugger lives in ue/dap.lua and is now accessed via
-- `require("ue.dap").stop_android_debugger(...)` directly. The previous
-- forward-declaration pattern relied on dap.lua doing a bare global write
-- to fill this local, which silently broke after the tiered split (different
-- main chunks don't share locals). See build_android() below.

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
    require("utils.log").notify_error("ue.build", title .. " failed: " .. build_err)
    return
  end

  if plat == "Android" then
    local cleanup = require("ue.dap").stop_android_debugger({ kill_orphans = true })
    cleanup_gradle_debug_artifacts(ctx)
    if cleanup.disconnected or cleanup.adapter_killed or cleanup.orphan_killed > 0 then
      local parts = {}
      if cleanup.disconnected then
        table.insert(parts, "detached active DAP")
      end
      if cleanup.adapter_killed then
        table.insert(parts, "stopped lldb-dap adapter")
      end
      if cleanup.orphan_killed > 0 then
        table.insert(parts, ("killed %d stale lldb-dap process%s"):format(
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

-- Find the newest APK in project build outputs.
-- Searches under uproject's directory (NOT ctx.project_root — see uproject_dir
-- comment for why these can differ in P4 / Source/Client layouts).
local function find_apk(ctx)
  local pr = uproject_dir(ctx)
  if not pr or pr == "" then
    return nil
  end
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
    dirname = _ufs.dirname,
    file_mtime = _ufs.file_mtime,
    find_uproject_in_dir = find_uproject_in_dir,
    glob_paths = glob_paths,
    is_file = _ufs.is_file,
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
    require("utils.log").notify_error("ue.android", "No APK found in project build outputs")
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

  -- Accumulate full stdout / stderr so we can surface the REAL adb error on
  -- failure (the per-line message overwrite would otherwise leave you with
  -- just "Failed (exit 1)" and lose the actual "Failure [INSTALL_FAILED_*]"
  -- line that adb prints).
  local stdout_lines, stderr_lines = {}, {}
  vim.fn.jobstart({ "adb", "install", "-r", apk_win }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stdout_lines, line)
          vim.schedule(function()
            if handle then handle.message = line end
          end)
        end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then
          table.insert(stderr_lines, line)
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
          return
        end

        -- Failure path: keep the fidget handle alive long enough for the user
        -- to actually READ the adb error, then finish it. Show stderr first
        -- (where adb writes "Failure [INSTALL_FAILED_*]"), fall back to
        -- stdout, fall back to a placeholder. Full blob goes to utils.log
        -- so `:NvimLog` always has the post-mortem.
        local stderr_blob = table.concat(stderr_lines, "\n")
        local stdout_blob = table.concat(stdout_lines, "\n")

        -- Pick the most useful single line for the inline progress display:
        -- prefer a line containing "Failure [", then any stderr line, then
        -- the last stdout line. fidget collapses newlines so we keep it short.
        local function pick_summary()
          for _, line in ipairs(stderr_lines) do
            if line:find("Failure %[") or line:find("^adb: ") then
              return line
            end
          end
          if #stderr_lines > 0 then return stderr_lines[#stderr_lines] end
          if #stdout_lines > 0 then return stdout_lines[#stdout_lines] end
          return "(no output captured)"
        end

        local summary = pick_summary()

        -- Append a short hint for well-known failure codes so the user gets
        -- an actionable next step inline, without having to grep docs.
        local hint
        if summary:find("INSTALL_FAILED_UPDATE_INCOMPATIBLE") then
          hint = "→ run: adb uninstall <your.package.id>  (signature mismatch from leftover PMS record)"
        elseif summary:find("INSTALL_FAILED_INSUFFICIENT_STORAGE") then
          hint = "→ free space on /data or use adb install -r -d"
        elseif summary:find("INSTALL_FAILED_VERSION_DOWNGRADE") then
          hint = "→ downgrade blocked; use adb install -r -d (allow downgrade) or uninstall first"
        elseif summary:find("INSTALL_FAILED_NO_MATCHING_ABIS") then
          hint = "→ ABI mismatch (e.g. arm64 APK on x86 device); check device ABI with: adb shell getprop ro.product.cpu.abi"
        elseif summary:find("INSTALL_PARSE_FAILED") then
          hint = "→ APK corrupt or unsigned; rebuild + re-sign"
        elseif summary:find("device offline") or summary:find("no devices/emulators") then
          hint = "→ adb device gone; check: adb devices"
        end

        handle.message = ("✗ exit %d — %s%s"):format(code, summary, hint and ("  " .. hint) or "")

        -- Persist the full output to the rotating debug log BEFORE finishing
        -- the handle, so even if fidget vanishes the user can `:NvimLog`.
        local ok_log, log = pcall(require, "utils.log")
        if ok_log and log.error then
          log.error("ue.install", ("adb install failed (exit %d): %s\n--- stderr ---\n%s\n--- stdout ---\n%s\nLog: see :NvimLog"):format(
            code, vim.fn.fnamemodify(apk_win, ":t"), stderr_blob, stdout_blob
          ))
        end

        -- Delay finish() so the failure message stays on screen ~8s instead
        -- of fidget's default ~3s. handle:finish() is what triggers fade-out.
        vim.defer_fn(function()
          if handle then handle:finish() end
        end, 8000)
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

  _ufs.ensure_dir(ctx.paths.cache)

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
    local project_dirs = existing_relative_dirs(ctx.project_root, CORE_RT.project_index_dirs(ctx))
    local project_err
    project_rel, project_err = scan_relative_files(ctx.project_root, project_dirs)
    if not project_rel then
      invalidate_status_cache()
      refresh_statusline()
      populate_quickfix_from_output("UEPrepare project scan", project_err, { root = ctx.project_root })
      require("utils.log").notify_error("ue.prepare", "UEPrepare project scan failed: " .. project_err)
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
    require("utils.log").notify_error("ue.prepare", "UEPrepare engine scan failed: " .. engine_err)
    if vim.g.ue_prepare_headless == 1 then
      error("UEPrepare engine scan failed: " .. engine_err)
    end
    return
  end

  local project_code = filter_gtags_only_paths(filter_gtags_paths(filter_gtags_code(project_rel)))
  local engine_code = filter_gtags_only_paths(filter_gtags_paths(filter_gtags_code(engine_rel)))
  local workspace_code = {}
  local workspace_seen = {}

  for _, path in ipairs(project_code) do
    local absolute = join(ctx.project_root, path)
    local relative = _ufs.relative_to(root, absolute)
    if not workspace_seen[relative] then
      workspace_seen[relative] = true
      table.insert(workspace_code, relative)
    end
  end

  for _, path in ipairs(engine_code) do
    local absolute = join(ctx.engine_root, path)
    local relative = _ufs.relative_to(root, absolute)
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
    local relative = _ufs.relative_to(root, absolute)
    if not workspace_all_seen[relative] then
      workspace_all_seen[relative] = true
      table.insert(workspace_all, relative)
    end
  end

  for _, path in ipairs(engine_all) do
    local absolute = join(ctx.engine_root, path)
    local relative = _ufs.relative_to(root, absolute)
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
    require("utils.log").notify_error("ue.prepare", "UEPrepare GTAGS failed: " .. workspace_err)
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
    local cs_ctx_p = { workspace_root = cs_root, csearch_idx = ctx.paths and ctx.paths.csearch_idx or nil }
    local code_search_p = require("utils.code_search")
    if code_search_p.cindex_uefilter_exe() then
      local abs_list = ctx.paths.cache .. "/csearch_filelist.txt"
      local fout = io.open(abs_list, "w")
      if fout then
        for _, rel in ipairs(workspace_all) do
          -- workspace_all may contain absolute paths when relative_to() cannot
          -- compute a relative path (e.g. cross-drive on Windows: project on E:,
          -- engine on D:). Cross-drive entries fall through unchanged from
          -- _ufs.relative_to(). Naive cs_root.."/"..rel for those would produce
          -- garbage like "D:/project/uetemp/E:/aki/...", which os.Stat rejects
          -- and cindex silently skips, leaving the project-side tree entirely
          -- absent from the csearch index. Guard with is_absolute_path so we
          -- only prefix when rel is actually relative.
          if _ufs.is_absolute_path(rel) then
            fout:write(rel, "\n")
          else
            fout:write(cs_root, "/", rel, "\n")
          end
        end
        fout:close()
        if not CORE_RT.csearch_build_begin("UEPrepare (sync)") then
          pcall(os.remove, abs_list)
        else
          local cs_done, cs_ok, cs_err = false, false, nil
          code_search_p.build_index(cs_ctx_p, abs_list, function(ok_cs, err_cs, _st)
            cs_ok, cs_err = ok_cs, err_cs
            cs_done = true
          end)
          vim.wait(180000, function() return cs_done end, 100)
          CORE_RT.csearch_build_done()
          pcall(os.remove, abs_list)
          if not cs_ok then
            vim.notify("UEPrepare: csearch index failed: " .. (cs_err or "timeout"),
              vim.log.levels.WARN, { title = "UE" })
          else
            -- Full build succeeded (D-3b + D10): clear dirty + record fingerprint.
            CORE_RT.on_full_csearch_success(ctx, "prepare:sync")
          end
        end
      end
    else
      vim.notify(
        "UEPrepare: cindex-uefilter not found — grep will use slow rg fallback.\n" ..
        "  Build it via: cd " .. vim.fn.stdpath("config") .. "/tools/cindex-uefilter && go install ./...",
        vim.log.levels.WARN, { title = "UE" })
    end
    -- Index rebuilt (sync path): drop ctx cache + re-probe toolchain so the
    -- next grep sees is_indexed() fresh.
    CORE_RT.context_cache = {}
    CORE_RT.freshness_notified = {}
    pcall(function() require("utils.code_search")._reset_probe_cache() end)
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

local function prepare_async(opts)
  opts = opts or {}
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

  -- Stash force flags so the cache fast-path csearch staleness check
  -- can honor :UEPrepareReindex (force a csearch rebuild even when the
  -- regular UEPrepare cache is fresh).
  ctx._force_csearch = opts.force_csearch and true or false

  if ctx.state.project_root ~= ctx.project_root then
    persist_project(ctx.engine_root, ctx.project_root, ctx.uproject)
  end

  _ufs.ensure_dir(ctx.paths.cache)

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

  -- ── fidget progress (created BEFORE fast-path so async ccjson can stream
  --     progress events into it; previously this was only set up on the cold
  --     path after fast-path returned, so fast-path's 17s ccjson run looked
  --     like a silent freeze) ─────────────────────────────────────────────
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

  -- ── Cache fast-path ──────────────────────────────────────────────────
  if prepare_cache_ready(ctx) then
    CORE_RT.trace_mark("FAST_PATH_TAKEN")
    local root = workspace_root(ctx)
    update("generating compile_commands (async)...", 25)

    -- Async ccjson — runs in headless nvim subprocess, streams progress
    -- here, and continues with the rest of fast-path in on_done.
    M.async_generate_compile_commands(ctx,
      function(stage, pct, detail)
        update(detail, pct)
      end,
      function(ok_compile, compile_path)
        if not ok_compile then
          invalidate_status_cache()
          refresh_statusline()
          populate_quickfix_from_output("UEPrepare compile_commands", compile_path, { root = root })
          vim.notify("UEPrepare compile_commands failed: " .. compile_path, vim.log.levels.WARN)
          if handle then handle.message = "FAILED"; handle:finish() end
          return
        end
        update("indexing...", 95)
        -- Subprocess wrote compile_commands.json but did NOT run the
        -- expand+pch+resolve+unify+prune pipeline (those rely on jobstart
        -- whose lifetime is tied to the main nvim, not the subprocess).
        -- Start it here in the main nvim.
        local targets_main = compile_commands_targets(ctx)
        run_compile_commands_pipeline(targets_main[1], targets_main)
        -- Partition base CDB by (plat, cfg) so clangd's gd on macros like
        -- UE_BUILD_DEVELOPMENT does not jump into stale Dev generated headers
        -- when the current build is Test. See INDEX_FN.partition_base_cdb.
        do
          local ok_p, msg_p = INDEX_FN.partition_base_cdb(ctx)
          if not ok_p then
            vim.notify("UEPrepare: cdb_partition failed -- " .. tostring(msg_p),
              vim.log.levels.WARN, { title = "ue.cdb" })
          end
        end
        clear_index_dirty(ctx)
        INDEX_FN.schedule_index_refresh(ctx, { current = true, hot = true, full = true, current_delay_ms = 50, hot_delay_ms = 2500 })
        invalidate_status_cache()
        refresh_statusline()

        -- csearch index rebuild (same logic as before, just moved here).
        local code_search_fp = require("utils.code_search")
        local cs_ctx_fp = { workspace_root = root, csearch_idx = ctx.paths and ctx.paths.csearch_idx or nil }
        local need_index = true
        local stale_reason = "missing"
        do
          local idx_path = code_search_fp.index_path(cs_ctx_fp)
          local idx_stat = idx_path and vim.loop.fs_stat(idx_path) or nil
          if ctx._force_csearch then
            stale_reason = "forced"
          elseif not idx_stat or (idx_stat.size or 0) <= 1024 then
            stale_reason = "missing"
          else
            -- Reuse the canonical freshness oracle. It already considers
            -- worktree-aware git index mtime + dir mtimes
            -- and the watcher's persistent dirty set — all the things this
            -- fast-path used to half-implement and get wrong for git
            -- worktrees / projects without their own .git.
            local fr = prepare_freshness(ctx)
            if fr == "fresh" then
              need_index = false
            else
              stale_reason = "freshness=" .. fr
            end
          end
        end
        if need_index and code_search_fp.cindex_uefilter_exe() then
          local abs_list = ctx.paths.cache .. "/csearch_filelist.txt"
          local fout = io.open(abs_list, "w")
          if fout then
            local n_lines = 0
            for line in io.lines(ctx.paths.workspace_all_list) do
              local trimmed = line:gsub("\r$", "")
              if trimmed ~= "" then
                -- Guard against cross-drive absolute paths in workspace_all_list
                -- (see lengthy comment near the sync path for the full story).
                if _ufs.is_absolute_path(trimmed) then
                  fout:write(trimmed, "\n")
                else
                  fout:write(root, "/", trimmed, "\n")
                end
                n_lines = n_lines + 1
              end
            end
            fout:close()
            if not CORE_RT.csearch_build_begin("UEPrepare (cache fast-path)") then
              pcall(os.remove, abs_list)
            else
              vim.notify(("UEPrepare: rebuilding csearch index in background (reason: %s)..."):format(stale_reason),
                vim.log.levels.INFO, { title = "UE", timeout = 3000, replace = "ue.csearch.build" })
              code_search_fp.build_index(cs_ctx_fp, abs_list, function(ok_cs, err_cs, stats)
                CORE_RT.csearch_build_done()
                pcall(os.remove, abs_list)
                if ok_cs then
                  local mb = math.floor((stats.index_size or 0) / 1024 / 1024)
                  vim.notify(("✓ csearch index rebuilt: %d MB in %.1fs"):format(
                    mb, (stats.ms or 0) / 1000),
                    vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
                  -- Full build succeeded (D-3b + D10): clear dirty + fingerprint.
                  CORE_RT.on_full_csearch_success(ctx, "prepare:fast-path")
                else
                  vim.notify("UEPrepare: csearch rebuild failed: " .. (err_cs or "unknown"),
                    vim.log.levels.WARN, { title = "UE", replace = "ue.csearch.build" })
                end
              end)
            end
          end
        end

        if handle then handle.message = "done"; handle.percentage = 100; handle:finish() end
        vim.notify(prepare_summary(ctx, compile_path, { reused_cache = true }))
      end)
    return
  end

  local function fail(msg)
    invalidate_status_cache()
    refresh_statusline()
    set_prepare_running(false)
    if handle then
      handle.message = "FAILED: " .. msg
      handle:finish()
    end
    require("utils.log").notify_error("ue.prepare", "UEPrepare failed: " .. msg)
  end

  set_prepare_running(true)
  start_phase()

  local function continue_after_scan(project_rel, engine_rel)
    end_phase("scan")

    -- ── Phase 2: build file lists ────────────────────────────────────
    update("building file lists...", 25)
    start_phase()

    local workspace_code, workspace_all, project_code, engine_code
    CORE_RT.trace_seg("cold.lists_total", function()
      project_code = filter_gtags_only_paths(filter_gtags_paths(filter_gtags_code(project_rel)))
      engine_code = filter_gtags_only_paths(filter_gtags_paths(filter_gtags_code(engine_rel)))
      workspace_code = {}
      local workspace_seen = {}
      local root_local = workspace_root(ctx)

      for _, path in ipairs(project_code) do
        local absolute = join(ctx.project_root, path)
        local relative = _ufs.relative_to(root_local, absolute)
        if not workspace_seen[relative] then
          workspace_seen[relative] = true
          table.insert(workspace_code, relative)
        end
      end

      for _, path in ipairs(engine_code) do
        local absolute = join(ctx.engine_root, path)
        local relative = _ufs.relative_to(root_local, absolute)
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
      workspace_all = {}
      local workspace_all_seen = {}

      for _, path in ipairs(project_all) do
        local absolute = join(ctx.project_root, path)
        local relative = _ufs.relative_to(root_local, absolute)
        if not workspace_all_seen[relative] then
          workspace_all_seen[relative] = true
          table.insert(workspace_all, relative)
        end
      end

      for _, path in ipairs(engine_all) do
        local absolute = join(ctx.engine_root, path)
        local relative = _ufs.relative_to(root_local, absolute)
        if not workspace_all_seen[relative] then
          workspace_all_seen[relative] = true
          table.insert(workspace_all, relative)
        end
      end

      table.sort(workspace_all)
      write_lines(ctx.paths.workspace_all_list, workspace_all)
    end)

    end_phase("lists")

    -- ── Phase 3a: generate compile_commands (parallel with gtags) ────
    -- compile_commands doesn't depend on gtags, so start it immediately.
    -- The pipeline (slim → pch → unify) runs in background via jobstart.
    update("generating compile_commands...", 30)
    start_phase()

    local ok_compile, compile_path = CORE_RT.trace_seg("cold.ccjson", function()
      return generate_compile_commands(ctx)
    end)
    if not ok_compile then
      vim.notify("UEPrepare: compile_commands failed (non-fatal): " .. (compile_path or "unknown"), vim.log.levels.WARN)
    end

    end_phase("compile_commands")

    -- ── Phase 3b: build GTAGS (async, slow) ───────────────────────────
    update(("indexing %d files with gtags..."):format(#workspace_code), 35)
    start_phase()

    local gtags = _uproc.first_executable({ "gtags" })
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
          CORE_RT.clear_freshness(ctx)
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

            -- Index just rebuilt: drop the resolve_context cache so the next
            -- grep re-reads is_indexed() fresh, and re-probe the csearch
            -- toolchain in case a cold-start negative probe is cached.
            CORE_RT.context_cache = {}
            CORE_RT.freshness_notified = {}
            pcall(function() require("utils.code_search")._reset_probe_cache() end)

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

            -- Start the incremental watcher so adds/deletes between runs of
            -- :UEPrepare don't force a full rebuild. Soft require so that
            -- a syntax error in ue_watch.lua never breaks :UEPrepare.
            local watch_ok, watch = pcall(require, "utils.ue_watch")
            if watch_ok then
              local cs_ok, cs = pcall(require, "utils.code_search")
              local cs_index = cs_ok and cs.index_path
                and cs.index_path({ workspace_root = workspace_root(ctx), csearch_idx = ctx.paths and ctx.paths.csearch_idx or nil })
                or nil
              watch.start({
                root = workspace_root(ctx),
                csearch_index = cs_index,
                shader_filelist = ctx.paths and ctx.paths.workspace_list or nil,
                gtags_db = ctx.paths and ctx.paths.workspace_db or nil,
                dirty_json_path = ctx.paths and ctx.paths.dirty_json or nil,
                debounce_ms = 1500,
              })
              -- NOTE: dirty set is cleared in the csearch build SUCCESS callback
              -- below (D-3b), NOT here. Clearing here would wipe it before the
              -- cold full build has actually succeeded — if the build then fails,
              -- the overlay would have lost the very files it must keep visible.
            end
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
          local cs_ctx = { workspace_root = cs_root, csearch_idx = ctx.paths and ctx.paths.csearch_idx or nil }
          local abs_list = ctx.paths.cache .. "/csearch_filelist.txt"
          local fout = io.open(abs_list, "w")
          if not fout then
            vim.notify("UEPrepare: failed to write " .. abs_list, vim.log.levels.WARN, { title = "UE" })
            finalize_after_csearch()
            return
          end
          CORE_RT.trace_seg("cold.csearch_dump", function()
            for _, rel in ipairs(workspace_all) do
              -- Same cross-drive absolute-path guard as the sync path.
              if _ufs.is_absolute_path(rel) then
                fout:write(rel, "\n")
              else
                fout:write(cs_root, "/", rel, "\n")
              end
            end
            fout:close()
          end)

          if not CORE_RT.csearch_build_begin("UEPrepare (cold full build)") then
            pcall(os.remove, abs_list)
            finalize_after_csearch()
            return
          end
          code_search.build_index(cs_ctx, abs_list, function(ok_cs, err_cs, stats)
            CORE_RT.csearch_build_done()
            -- Tidy up the temp filelist regardless of outcome.
            pcall(os.remove, abs_list)

            if ok_cs then
              local mb = math.floor((stats.index_size or 0) / 1024 / 1024)
              vim.notify(("✓ csearch index: %d MB in %.1fs"):format(
                mb, (stats.ms or 0) / 1000),
                vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
              -- Full build succeeded (D-3b + D10): clear dirty + fingerprint.
              CORE_RT.on_full_csearch_success(ctx, "prepare:cold-full")
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
      local project_dirs = existing_relative_dirs(ctx.project_root, CORE_RT.project_index_dirs(ctx))
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
  if _ufs.is_dir(gtags_dir) then
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
    if _ufs.is_dir(clangd_cache) then
      pcall(vim.fn.delete, clangd_cache, "rf")
      table.insert(removed, "  " .. clangd_cache .. "/ (clangd index)")
    end
  end

  if bang then
    for _, idx in ipairs({ ctx.paths.active_index, ctx.paths.current_index, ctx.paths.hot_index, ctx.paths.full_index }) do
      if _ufs.is_file(idx) then
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
      local pch_dir = cache_paths(root).pch_dir
      if _ufs.is_dir(pch_dir) then
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
  dirname = _ufs.dirname,
  is_file = _ufs.is_file,
  ensure_dir = _ufs.ensure_dir,
  run_lines = run_lines,
  file_stat = _ufs.file_stat,
  file_mtime = _ufs.file_mtime,
  glob_paths = glob_paths,
  is_native_windows = is_native_windows,
  resolve_context = resolve_context,
  invalidate_status_cache = invalidate_status_cache,
  refresh_statusline = refresh_statusline,
  first_executable = _uproc.first_executable,
  path_has_prefix = _ufs.path_has_prefix,
  relative_to = _ufs.relative_to,
  update_state_field = update_state_field,
  read_state = read_state,
})

-- Re-export DAP state for backward compat (plugins/dap.lua calls M.setup_dap)
M._dap_session_state = dap_mod._dap_session_state
M._dap_attach_in_progress = dap_mod._dap_attach_in_progress
M._dap_run_state = dap_mod._dap_run_state
M._continue_debounce_until_ms = dap_mod._continue_debounce_until_ms
M._dap_source_file_cache = dap_mod._dap_source_file_cache

-- Delegate DAP public API.  We're back on codelldb (1.12.2) for the
-- Android route as of 2026-05; the lldb-dap experiment is retired.
-- The historical M.codelldb_paths / ASLR listeners / hand-written
-- breakpoint helpers stay deleted — codelldb handles all of that
-- natively, and persistence is owned by ue.dap._persist_bp instead.
M.lldb_dap_path = dap_mod.lldb_dap_path
M.android_dap_attach = dap_mod.android_dap_attach

-- Expose state helpers so peripheral modules (ue/dap/android.lua's pick_package,
-- external probes, future plugins) can read/write the persisted .cache/nvim-ue/
-- state.json without re-implementing the path resolution. These are forward-
-- declared locals upthread; they exist by the time setup_dap / require returns.
M.read_state = read_state
M.update_state_field = update_state_field
M.resolve_context = resolve_context
-- Test seams for grep-cache invalidation (grep_cache_spec.lua). cache_paths
-- is a forward-declared local; CORE_RT helpers are parked off the local cap.
M.cache_paths = cache_paths
M.platform_key_from_state = CORE_RT.platform_key_from_state
M.migrate_legacy_csearch_if_needed = CORE_RT.migrate_legacy_csearch_if_needed
M._grep_live_search_ready_for_test = CORE_RT.grep_live_search_ready
M._grep_backend_title_for_test = CORE_RT.grep_backend_title
M.android_dap_launch = dap_mod.android_dap_launch
M._dap_filter_scopes = dap_mod._dap_filter_scopes
M.ensure_dap_loaded = dap_mod.ensure_dap_loaded
M.ensure_dapui_loaded = dap_mod.ensure_dapui_loaded
M.dap_toggle_breakpoint = dap_mod.dap_toggle_breakpoint
M.dap_set_conditional_breakpoint = dap_mod.dap_set_conditional_breakpoint
M.dap_set_logpoint = dap_mod.dap_set_logpoint
M.dap_clear_breakpoints = dap_mod.dap_clear_breakpoints
M.dap_list_breakpoints = dap_mod.dap_list_breakpoints
M.dap_hover = dap_mod.dap_hover
M.dap_eval_prompt = dap_mod.dap_eval_prompt
M.dap_add_watch_cword = dap_mod.dap_add_watch_cword
M.dap_watch_template = dap_mod.dap_watch_template
M.dap_watch_fname = dap_mod.dap_watch_fname
M.dap_watch_uobject = dap_mod.dap_watch_uobject
M.dap_watch_actor = dap_mod.dap_watch_actor
M.dap_watch_tarray = dap_mod.dap_watch_tarray
M.dap_run_to_cursor = dap_mod.dap_run_to_cursor
M.dap_frame_up = dap_mod.dap_frame_up
M.dap_frame_down = dap_mod.dap_frame_down
M.dap_restart_frame = dap_mod.dap_restart_frame
M.dap_continue = dap_mod.dap_continue
M.dap_pause = dap_mod.dap_pause
M.dap_step_over = dap_mod.dap_step_over
M.dap_step_into = dap_mod.dap_step_into
M.dap_step_out = dap_mod.dap_step_out
M.dap_bottom_tab = dap_mod.dap_bottom_tab
M.dap_next_bottom_tab = dap_mod.dap_next_bottom_tab
M.dap_toggle_ui = dap_mod.dap_toggle_ui
M.dap_reset_layout = dap_mod.dap_reset_layout
M.dap_toggle_repl = dap_mod.dap_toggle_repl
M.dap_diagnose = dap_mod.dap_diagnose
M.stop_android_debugger = dap_mod.stop_android_debugger
M.android_dap_reattach  = dap_mod.android_dap_reattach
M.android_dap_status    = dap_mod.android_dap_status
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

  -- Wire persistent breakpoints eagerly (before nvim-dap is loaded).  This
  -- module only depends on dap.breakpoints lazily inside its callbacks, so
  -- the autocmds it installs (BufReadPost restore + VimLeavePre flush) can
  -- safely fire even if the user never triggers DAP this session.
  pcall(function()
    require("ue.dap._persist_bp").setup()
  end)

  vim.api.nvim_create_user_command("UEPaths", show_paths, {})
  vim.api.nvim_create_user_command("UESetProject", function(opts)
    CORE_RT.set_project(opts.args)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("UESetAndroidPackage", function(opts)
    set_android_package(opts.args)
  end, { nargs = "?" })
  vim.api.nvim_create_user_command("UESetUprojectRelativePath", function(opts)
    set_uproject_relative_path_command(opts.args)
  end, {
    nargs = "?",
    desc = "Set workspace -> .uproject relative path (used by :UESetProject when given only a workspace root)",
  })
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

  vim.api.nvim_create_user_command("UEGrepTraceToggle", function()
    vim.g.ue_grep_trace = not (vim.g.ue_grep_trace == true)
    local on = vim.g.ue_grep_trace
    local path = vim.fn.stdpath("state") .. "/ue_grep_trace.log"

    -- Also install a global error sink so any vim.notify(level=ERROR) or
    -- bare lua error that triggers Windows beep gets captured. We DO NOT
    -- override vim.notify (noice would warn about that and ding loudly);
    -- instead we just poll :messages periodically and tee Error/E5/attempt
    -- patterns to disk.
    if on and not vim.g._ue_err_sink_installed then
      vim.g._ue_err_sink_installed = true
      local err_log = vim.fn.stdpath("state") .. "/ue_errors.log"
      local f = io.open(err_log, "w")
      if f then f:write("=== installed " .. os.date() .. " ===\n"); f:close() end
      local timer = vim.loop.new_timer()
      timer:start(500, 500, vim.schedule_wrap(function()
        local m = vim.api.nvim_exec2("messages", { output = true }).output or ""
        if m:find("Error") or m:find("E5") or m:find("attempt")
           or m:find("aborted") then
          local fp = io.open(err_log, "a")
          if fp then
            fp:write("[poll @" .. os.date() .. "]\n" .. m:sub(-2000) .. "\n---\n")
            fp:close()
          end
          pcall(vim.cmd, "messages clear")
        end
      end))
    end

    vim.notify(string.format("UE grep trace: %s\nlog: %s",
      on and "ON" or "OFF", path),
      vim.log.levels.INFO, { title = "UE", timeout = 6000 })
  end, { desc = "Toggle UE grep finder trace logging + error sink" })

  vim.api.nvim_create_user_command("UEGrepTraceShow", function()
    local path = vim.fn.stdpath("state") .. "/ue_grep_trace.log"
    if vim.fn.filereadable(path) == 0 then
      vim.notify("no trace log at " .. path, vim.log.levels.WARN, { title = "UE" })
      return
    end
    -- Open trace log in a new tab so it doesn't blow away current layout.
    vim.cmd("tabnew " .. vim.fn.fnameescape(path))
    vim.bo.buftype = ""
    vim.bo.buflisted = false
    vim.cmd("normal! G")  -- jump to end (newest events)
  end, { desc = "Open the UE grep trace log in a new tab" })

  vim.api.nvim_create_user_command("UEGrepDiagDump", function()
    -- One-shot bundle: trace + errors + tail of :messages + Snacks notifier
    -- history into a single file the user can paste back in one go.
    local out_path = vim.fn.stdpath("state") .. "/ue_grep_diag.txt"
    local trace_path = vim.fn.stdpath("state") .. "/ue_grep_trace.log"
    local err_path = vim.fn.stdpath("state") .. "/ue_errors.log"

    local function read_file(p, max_bytes)
      max_bytes = max_bytes or 50000
      if vim.fn.filereadable(p) == 0 then return "(missing: " .. p .. ")" end
      local fp = io.open(p, "r"); if not fp then return "(open failed)" end
      local content = fp:read("*a") or ""; fp:close()
      if #content > max_bytes then
        content = "...[truncated, showing last " .. max_bytes .. " bytes]...\n"
                  .. content:sub(-max_bytes)
      end
      return content
    end

    local parts = {}
    table.insert(parts, "=== UEGrepDiagDump  " .. os.date("%Y-%m-%d %H:%M:%S") .. " ===")
    table.insert(parts, "trace_enabled=" .. tostring(vim.g.ue_grep_trace == true))
    table.insert(parts, "grouping_enabled=" .. tostring(vim.g.ue_grep_grouping_enabled ~= false))
    table.insert(parts, "err_sink_installed=" .. tostring(vim.g._ue_err_sink_installed == true))

    table.insert(parts, "\n========== TRACE  (" .. trace_path .. ") ==========")
    table.insert(parts, read_file(trace_path))

    table.insert(parts, "\n========== ERRORS  (" .. err_path .. ") ==========")
    table.insert(parts, read_file(err_path))

    table.insert(parts, "\n========== :messages tail ==========")
    local m = vim.api.nvim_exec2("messages", { output = true }).output or ""
    table.insert(parts, m:sub(-3000))

    if Snacks and Snacks.notifier and Snacks.notifier.get_history then
      table.insert(parts, "\n========== Snacks notifier (errors+warns last 30) ==========")
      local hist = Snacks.notifier.get_history() or {}
      local kept = {}
      for _, n in ipairs(hist) do
        if n.level == "error" or n.level == "warn" then table.insert(kept, n) end
      end
      for i = math.max(1, #kept - 29), #kept do
        local n = kept[i]
        table.insert(parts, string.format("[%s] %s",
          n.level, tostring(n.msg):sub(1, 400)))
      end
    end

    local body = table.concat(parts, "\n")
    local fp = io.open(out_path, "w")
    if fp then fp:write(body); fp:close() end
    vim.notify("UE grep diag → " .. out_path,
      vim.log.levels.INFO, { title = "UE", timeout = 5000 })
  end, { desc = "Bundle UE grep trace + errors + messages into one diag file" })
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
  vim.api.nvim_create_user_command("UEPrepare", function(cmd)
    local bang = cmd.bang and true or false
    require("utils.async_launcher").launch({
      name  = bang and "UE: Prepare (FORCE full rebuild)" or "UE: Prepare (rsp + ccjson + index)",
      group = "ue",
      run   = function(report)
        -- prepare_async already returns immediately and runs UBT/cindex
        -- in libuv jobs. The launcher placeholder + fidget handle here
        -- exist to give a unified visible-progress surface during the
        -- 100–500ms window where ueprepare itself spins up + first job
        -- spawn happens on the main thread.
        --
        -- :UEPrepare!  → force_csearch=true AND wipe the cache fast-path
        --                gates so EVERY phase rebuilds from scratch.
        --                Use after a confused state (project switch with
        --                stale lists, corrupted .idx, post-:UESetProject
        --                if the invalidation missed something). Always
        --                correct, just slow.
        -- :UEPrepare   → normal flow. Fast-path skips phases whose inputs
        --                still look fresh against external anchors.
        if bang then
          if report then report("BANG → forcing full clean rebuild ...") end
          -- Mark the engine_root as dirty so prepare_cache_ready returns
          -- false and we take the cold path (which rebuilds every phase).
          local ctx_b = resolve_context()
          if ctx_b then
            local key = status_root_key(ctx_b)
            if key and key ~= "" then
              CORE_RT.dirty_index_roots[key] = true
            end
            -- Also clear watcher dirty set; cold rebuild covers everything.
            local ok_watch, watch = pcall(require, "utils.ue_watch")
            if ok_watch and type(watch.clear_persistent_dirty) == "function" then
              watch.clear_persistent_dirty("UEPrepare!")
            end
          end
          prepare_async({ force_csearch = true })
        else
          if report then report("dispatching prepare_async ...") end
          prepare_async()
        end
      end,
    })
  end, { bang = true, desc = "UE prepare (bang = force full clean rebuild)" })
  vim.api.nvim_create_user_command("UEPrepareIncremental", function()
    -- Apply the watcher's accumulated dirty file set as a cindex INCREMENTAL
    -- add (no -reset). Fast (proportional to dirty count, not workspace size)
    -- and safe — cindex add is the documented way to incrementally extend
    -- the trigram index. After success we clear the dirty set so the
    -- "freshness" oracle stops warning.
    --
    -- Use this when freshness banner says stale but you don't want to pay
    -- for a full :UEPrepare. Doesn't refresh gtags or cdb — only csearch.
    -- For gtags/cdb drift, use :UEPrepare (normal) or :UEPrepare! (full).
    local ctx, err = resolve_context()
    if not ctx then vim.notify(err or "no ctx", vim.log.levels.WARN); return end
    local ok_watch, watch = pcall(require, "utils.ue_watch")
    if not ok_watch then vim.notify("ue_watch module missing", vim.log.levels.WARN); return end
    local dirty = (type(watch.snapshot_persistent_dirty) == "function")
      and watch.snapshot_persistent_dirty() or {}
    if #dirty == 0 then
      vim.notify("No dirty files since last :UEPrepare — nothing to add", vim.log.levels.INFO, { title = "UE" })
      return
    end
    local code_search = require("utils.code_search")
    if not code_search.cindex_uefilter_exe() then
      vim.notify("cindex-uefilter not found — build it first", vim.log.levels.WARN, { title = "UE" })
      return
    end
    local abs_list = ctx.paths.cache .. "/csearch_incremental.txt"
    local fout = io.open(abs_list, "w")
    if not fout then
      vim.notify("UEPrepareIncremental: cannot write " .. abs_list, vim.log.levels.WARN)
      return
    end
    for _, p in ipairs(dirty) do fout:write(p, "\n") end
    fout:close()
    if not CORE_RT.csearch_build_begin("UEPrepareIncremental") then
      pcall(os.remove, abs_list)
      return
    end
    vim.notify(("UEPrepareIncremental: adding %d dirty files to csearch index ..."):format(#dirty),
      vim.log.levels.INFO, { title = "UE", timeout = 3000, replace = "ue.csearch.build" })
    local cs_ctx = { workspace_root = workspace_root(ctx), csearch_idx = ctx.paths.csearch_idx }
    code_search.build_index(cs_ctx, abs_list, function(ok_cs, err_cs, stats)
      CORE_RT.csearch_build_done()
      pcall(os.remove, abs_list)
      if ok_cs then
        if type(watch.clear_persistent_dirty) == "function" then
          watch.clear_persistent_dirty("UEPrepareIncremental")
        end
        local mb = math.floor((stats.index_size or 0) / 1024 / 1024)
        vim.notify(("✓ csearch +%d files (%.1fs, idx now %d MB)"):format(
          #dirty, (stats.ms or 0) / 1000, mb),
          vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
      else
        vim.notify("UEPrepareIncremental failed: " .. (err_cs or "?"),
          vim.log.levels.WARN, { title = "UE" })
      end
    end, { mode = "add" })
  end, { desc = "Append watcher's dirty files to csearch index (no full rebuild)" })
  vim.api.nvim_create_user_command("UEPrepareReindex", function()
    -- Force csearch rebuild even when the cache fast-path would skip it.
    -- Useful after large branch switches / engine syncs that leave
    -- ghost entries in the existing index.
    require("utils.async_launcher").launch({
      name  = "UE: Prepare + force csearch rebuild",
      group = "ue",
      run   = function(report)
        if report then report("force_csearch=true → rebuilding index ...") end
        prepare_async({ force_csearch = true })
      end,
    })
  end, { desc = "UEPrepare + force csearch index rebuild (ghost cleanup)" })
  vim.api.nvim_create_user_command("UEPrepareSync", function()
    -- Synchronous escape hatch — debug only. Will block the UI for the
    -- full duration of prepare. Use :UEPrepare for the async path.
    vim.notify(
      "UEPrepareSync will block the UI; use :UEPrepare for async",
      vim.log.levels.WARN, { title = "ue" })
    prepare()
  end, { desc = "UEPrepare synchronous (blocks UI; debug only)" })
  vim.api.nvim_create_user_command("UECDBPartition", function(cmd)
    -- Manually re-run partition. Optional arg: "Android/Test" to also set active.
    local ctx = require_ctx_or_nil()
    if not ctx then
      vim.notify("UECDBPartition: no UE context (run :UESetProject first)",
        vim.log.levels.WARN, { title = "ue.cdb" }); return
    end
    local opts = {}
    local arg = (cmd.args or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if arg ~= "" then opts.active = arg end
    local ok, msg = INDEX_FN.partition_base_cdb(ctx, opts)
    local lvl = ok and vim.log.levels.INFO or vim.log.levels.WARN
    vim.notify("UECDBPartition: " .. (msg or (ok and "ok" or "failed")),
      lvl, { title = "ue.cdb" })
  end, { nargs = "?", desc = "Partition base CDB by (plat,cfg); optional Platform/Config arg" })
  vim.api.nvim_create_user_command("UECDBSwitch", function(cmd)
    -- Switch active (plat, cfg) group. Usage:
    --   :UECDBSwitch Android Test
    --   :UECDBSwitch Win64 Development
    local ctx = require_ctx_or_nil()
    if not ctx then
      vim.notify("UECDBSwitch: no UE context", vim.log.levels.WARN, { title = "ue.cdb" }); return
    end
    local args = cmd.fargs or {}
    if #args ~= 2 then
      vim.notify("Usage: :UECDBSwitch <Platform> <Config>  e.g. :UECDBSwitch Android Test",
        vim.log.levels.WARN, { title = "ue.cdb" }); return
    end
    local spec = args[1] .. "/" .. args[2]
    local ok, msg = INDEX_FN.partition_base_cdb(ctx, { active = spec })
    if not ok then
      vim.notify("UECDBSwitch failed: " .. tostring(msg), vim.log.levels.WARN, { title = "ue.cdb" }); return
    end
    -- After switching active, the base CDB content changed -- re-kick clangd
    -- so it re-reads. We piggy-back on the index refresh's existing restart.
    INDEX_FN.maybe_restart_clangd_for_index()
    vim.notify("UECDBSwitch: active=" .. spec, vim.log.levels.INFO, { title = "ue.cdb" })
  end, { nargs = "*", desc = "Switch CDB active (plat, cfg) group" })
  vim.api.nvim_create_user_command("UECDBStatus", function()
    local ctx = require_ctx_or_nil()
    if not ctx then
      vim.notify("UECDBStatus: no UE context", vim.log.levels.WARN, { title = "ue.cdb" }); return
    end
    local mf, mf_path = INDEX_FN.read_partition_manifest(ctx)
    if not mf then
      vim.notify("UECDBStatus: no partition manifest yet (run :UEPrepare or :UECDBPartition)",
        vim.log.levels.INFO, { title = "ue.cdb" }); return
    end
    local lines = { "Manifest: " .. mf_path }
    if mf.active then
      table.insert(lines, ("Active: %s/%s/%s (%d cmds)"):format(
        mf.active.platform or "?", mf.active.project or "?", mf.active.config or "?",
        mf.active.cmd_count or 0))
    end
    if mf.unclassified_in_base then
      table.insert(lines, ("Shaders kept in base: %d"):format(mf.unclassified_in_base))
    end
    table.insert(lines, "Groups:")
    for _, g in ipairs(mf.groups or {}) do
      table.insert(lines, ("  %s  %s/%s/%s  %d cmds"):format(
        g.active and "*" or " ",
        g.platform or "?", g.project or "?", g.config or "?",
        g.cmd_count or 0))
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "ue.cdb" })
  end, { desc = "Show CDB partition status" })
  vim.api.nvim_create_user_command("UEWatchStatus", function()
    local ok, watch = pcall(require, "utils.ue_watch")
    if not ok then vim.notify("ue_watch module missing", vim.log.levels.WARN); return end
    local s = watch.status()
    vim.notify(("UEWatch: running=%s root=%s pending(+%d/-%d) last=%s"):format(
      tostring(s.running), s.watch_root or "?",
      s.pending_adds, s.pending_dels,
      s.last_event_at == 0 and "never" or tostring(s.last_event_at)))
  end, { desc = "Show ue_watch incremental indexer status" })
  vim.api.nvim_create_user_command("UEWatchStop", function()
    local ok, watch = pcall(require, "utils.ue_watch")
    if ok then watch.stop(); vim.notify("UEWatch stopped") end
  end, {})
  vim.api.nvim_create_user_command("UEWatchFlush", function()
    local ok, watch = pcall(require, "utils.ue_watch")
    if ok and watch.flush_now then watch.flush_now(); vim.notify("UEWatch flush triggered") end
  end, { desc = "Bypass debounce; immediately apply pending watcher events" })
  vim.api.nvim_create_user_command("UEDirtyStatus", function()
    -- Show the cumulative-since-last-:UEPrepare dirty set (rg-on-dirty
    -- overlay's source of truth for the cindex modify-no-op workaround).
    local ok, watch = pcall(require, "utils.ue_watch")
    if not ok then vim.notify("ue_watch module missing", vim.log.levels.WARN); return end
    local st = (watch.persistent_dirty_status and watch.persistent_dirty_status()) or { count = 0 }
    local lines = {
      ("UEDirty: %d files in cumulative dirty set"):format(st.count or 0),
      ("  cap=%d  warn_at=%d"):format(st.cap or 0, st.warn_at or 0),
      ("  path=%s"):format(st.path or "(unconfigured)"),
    }
    -- Also show the dirty_files.collect breakdown so the user can see what
    -- the rg-on-dirty overlay would actually use right now.
    local df_ok, df = pcall(require, "utils.dirty_files")
    if df_ok then
      local r = df.collect({})
      table.insert(lines, ("  collect: buffer=%d watcher=%d persistent=%d -> dedup=%d filter=%d -> %d files%s"):format(
        r.stats.buffer or 0, r.stats.watcher or 0, r.stats.persistent or 0,
        r.stats.dedup_in or 0, r.stats.filter_in or 0,
        #r.files, r.truncated and " (TRUNCATED)" or ""))
    end
    vim.notify(table.concat(lines, "\n"))
  end, { desc = "Show cumulative dirty set + dirty_files.collect breakdown" })
  vim.api.nvim_create_user_command("UEDirtyClear", function()
    local ok, watch = pcall(require, "utils.ue_watch")
    if not ok then vim.notify("ue_watch module missing", vim.log.levels.WARN); return end
    if type(watch.clear_persistent_dirty) ~= "function" then
      vim.notify("clear_persistent_dirty unavailable (old ue_watch?)", vim.log.levels.WARN); return
    end
    watch.clear_persistent_dirty("manual")
    vim.notify("UEDirty cleared")
  end, { desc = "Manually clear the cumulative dirty set (use after manual reindex)" })
  vim.api.nvim_create_user_command("UECachePaths", function()
    -- Dump the v2 cache layout that ue.lua's cache_paths() resolved for
    -- the current ctx. Useful to verify migration / debug missing-path
    -- bugs without `:lua print(vim.inspect(...))` gymnastics.
    local ctx, err = resolve_context()
    if not ctx then
      vim.notify("UECachePaths: " .. (err or "no ctx"), vim.log.levels.WARN)
      return
    end
    if not ctx.paths then
      vim.notify("UECachePaths: ctx.paths missing", vim.log.levels.WARN)
      return
    end
    local lines = { "UECachePaths (layout v2):" }
    -- Sort for deterministic display.
    local keys = {}
    for k in pairs(ctx.paths) do keys[#keys + 1] = k end
    table.sort(keys)
    for _, k in ipairs(keys) do
      local v = ctx.paths[k]
      if type(v) == "string" then
        local exists = (vim.uv or vim.loop).fs_stat(v) ~= nil
        table.insert(lines, ("  %-22s %s  %s"):format(k, exists and "[ok]" or "[--]", v))
      end
    end
    vim.notify(table.concat(lines, "\n"))
  end, { desc = "Dump cache_paths() result + existence check" })
  vim.api.nvim_create_user_command("UEIndexStatus", function()
    M.index_status()
  end, {})
  vim.api.nvim_create_user_command("UEIndexNow", function()
    -- Single-buffer reindex; usually <100ms, no placeholder needed.
    M.index_now()
  end, {})
  vim.api.nvim_create_user_command("UEIndexHot", function()
    require("utils.async_launcher").launch({
      name  = "UE: GTAGS hot reindex",
      group = "ue",
      run   = function(report)
        if report then report("scheduling hot + full passes ...") end
        M.index_hot()
      end,
    })
  end, {})
  vim.api.nvim_create_user_command("UEIndexFull", function()
    require("utils.async_launcher").launch({
      name  = "UE: GTAGS full reindex",
      group = "ue",
      run   = function(report)
        if report then report("scheduling full pass ...") end
        M.index_full()
      end,
    })
  end, {})
  vim.api.nvim_create_user_command("UEIndexTimings", function()
    local ctx, err = resolve_context()
    if not ctx then vim.notify("UEIndexTimings: " .. (err or "no ctx"), vim.log.levels.WARN); return end
    local state = ensure_index_state(ctx)
    local timings = state.index_timings or {}
    local lines = { "UEIndexTimings (last run per phase):" }
    local phases = { "current", "hot", "full" }
    local any = false
    for _, p in ipairs(phases) do
      local t = timings[p]
      if t then
        any = true
        local age = "?"
        if t.finished_at and t.finished_at > 0 then
          local secs = os.time() - t.finished_at
          if secs < 60 then age = secs .. "s ago"
          elseif secs < 3600 then age = math.floor(secs / 60) .. "m ago"
          else age = math.floor(secs / 3600) .. "h ago" end
        end
        table.insert(lines, ("  %-7s %7.2fs  modules=%d  unity=%s  %s  (%s)"):format(
          p, t.elapsed_s or 0, t.modules or 0, tostring(t.unity), t.status or "?", age))
      else
        table.insert(lines, ("  %-7s (never run)"):format(p))
      end
    end
    if not any then table.insert(lines, "  (no phase has completed yet)") end
    vim.notify(table.concat(lines, "\n"))
  end, { desc = "Show last per-phase clangd-indexer wall-clock time" })
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
      local candidate = cache_paths(root).pch_build_bat
      if _ufs.is_file(candidate) then bat = candidate; break end
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
            require("utils.log").notify_error("ue.pch", "UE: PCH rebuild FAILED (exit " .. code .. ")")
          end
        end)
      end,
    })
  end, { desc = "Rebuild clangd PCH cache (after LLVM/clangd version bump)" })
  vim.api.nvim_create_user_command("UEClearCache", function(cmd_opts)
    clear_cache({ bang = cmd_opts.bang })
  end, { bang = true, desc = "Clear UE caches (! = also clangd index, compile_commands, restart LSP)" })

  vim.api.nvim_create_user_command("UEDAPDiag", function()
    M.dap_diagnose()
  end, {})
  vim.api.nvim_create_user_command("UEResetLayout", function()
    M.dap_reset_layout()
  end, {})

  -- ─ Phase F.1+F.2+H: platform-neutral UEDAP* aliases via dispatch table ─
  -- F.1 introduced the UEDAP* command names with hard-coded android branch.
  -- F.2 moved the per-platform handler decision into ue.dap.platforms.
  -- H registers concrete handlers for win64 / mac / linux / ios alongside
  -- the existing android implementation. New platforms still register here
  -- — this is the single seam the dispatch flows through.
  local dap_platforms = require("ue.dap.platforms")
  dap_platforms.register_attach("android", function() M.android_dap_attach() end)
  dap_platforms.register_launch("android", function() M.android_dap_launch() end)
  for _, id in ipairs({ "win64", "mac", "linux", "ios" }) do
    local ok, plat_mod = pcall(require, "ue.dap." .. id)
    if ok and type(plat_mod) == "table" then
      if type(plat_mod.attach) == "function" then dap_platforms.register_attach(id, plat_mod.attach) end
      if type(plat_mod.launch) == "function" then dap_platforms.register_launch(id, plat_mod.launch) end
    end
  end

  local function dap_dispatch(kind, platform)
    platform = (platform ~= "" and platform) or (M.current_platform() or "")
    local handler = (kind == "attach")
      and dap_platforms.attach_handler(platform)
      or  dap_platforms.launch_handler(platform)
    if handler then
      handler()
      return
    end
    local known = dap_platforms.known_platforms()
    vim.notify(
      ("UEDAP%s: platform %q has no handler (registered: %s). Pass one of these as the argument."):format(
        kind == "attach" and "Attach" or "Launch", platform, table.concat(known, ", ")),
      vim.log.levels.WARN
    )
  end

  vim.api.nvim_create_user_command("UEDAPAttach", function(opts)
    dap_dispatch("attach", opts.args or "")
  end, { nargs = "?", desc = "DAP: Attach (optional: platform)" })
  vim.api.nvim_create_user_command("UEDAPLaunch", function(opts)
    dap_dispatch("launch", opts.args or "")
  end, { nargs = "?", desc = "DAP: Launch (optional: platform)" })
  vim.api.nvim_create_user_command("UEDAPContinue",        function() M.dap_continue()         end, { desc = "DAP: Continue" })
  vim.api.nvim_create_user_command("UEDAPPause",           function() M.dap_pause()            end, { desc = "DAP: Pause" })
  vim.api.nvim_create_user_command("UEDAPToggleBreakpoint",function() M.dap_toggle_breakpoint()end, { desc = "DAP: Toggle breakpoint" })
  vim.api.nvim_create_user_command("UEDAPCondBreakpoint",  function() M.dap_set_conditional_breakpoint() end, { desc = "DAP: Conditional breakpoint (prompt)" })
  vim.api.nvim_create_user_command("UEDAPLogpoint",        function() M.dap_set_logpoint() end, { desc = "DAP: Logpoint (prompt)" })
  vim.api.nvim_create_user_command("UEDAPClearBreakpoints",function() M.dap_clear_breakpoints() end, { desc = "DAP: Clear all breakpoints" })
  vim.api.nvim_create_user_command("UEDAPListBreakpoints", function() M.dap_list_breakpoints() end, { desc = "DAP: List persisted breakpoints" })
  vim.api.nvim_create_user_command("UEDAPHover",           function() M.dap_hover() end,
    { desc = "DAP: Hover (eval cword or selection)", range = true })
  vim.api.nvim_create_user_command("UEDAPEval",            function() M.dap_eval_prompt() end, { desc = "DAP: Evaluate expression (prompt)" })
  vim.api.nvim_create_user_command("UEDAPWatchAdd",        function() M.dap_add_watch_cword() end,
    { desc = "DAP: Add cword/selection to Watches", range = true })
  vim.api.nvim_create_user_command("UEDAPWatchUE", function(opts)
    -- Args: <type> [expression]. If expression omitted, use cword/visual.
    -- type one of: fname uobject actor tarray raw
    local args = opts.fargs or {}
    local template = args[1] or ""
    local expr = #args >= 2 and table.concat(args, " ", 2) or ""
    M.dap_watch_template(template, expr)
  end, {
    nargs = "+",
    range = true,
    complete = function(_arg_lead, _cmd_line, _cursor_pos)
      return { "fname", "uobject", "actor", "tarray", "raw" }
    end,
    desc = "DAP: Add UE-aware watch (fname/uobject/actor/tarray/raw)",
  })
  vim.api.nvim_create_user_command("UEDAPRunToCursor",     function() M.dap_run_to_cursor() end, { desc = "DAP: Run to cursor" })
  vim.api.nvim_create_user_command("UEDAPFrameUp",         function() M.dap_frame_up() end, { desc = "DAP: Stack frame up" })
  vim.api.nvim_create_user_command("UEDAPFrameDown",       function() M.dap_frame_down() end, { desc = "DAP: Stack frame down" })
  vim.api.nvim_create_user_command("UEDAPRestartFrame",    function() M.dap_restart_frame() end, { desc = "DAP: Restart current frame" })
  vim.api.nvim_create_user_command("UEDAPStepOver",        function() M.dap_step_over()        end, { desc = "DAP: Step over" })
  vim.api.nvim_create_user_command("UEDAPStepIn",          function() M.dap_step_into()        end, { desc = "DAP: Step in" })
  vim.api.nvim_create_user_command("UEDAPStepOut",         function() M.dap_step_out()         end, { desc = "DAP: Step out" })
  vim.api.nvim_create_user_command("UEDAPTab", function(opts)
    M.dap_bottom_tab(opts.args)
  end, {
    nargs = 1,
    complete = function()
      return { "repl", "console", "breakpoints", "logcat" }
    end,
    desc = "DAP: switch right-bottom tab",
  })
  vim.api.nvim_create_user_command("UEDAPNextTab", function() M.dap_next_bottom_tab(1) end,
    { desc = "DAP: next right-bottom tab" })
  vim.api.nvim_create_user_command("UEDAPPrevTab", function() M.dap_next_bottom_tab(-1) end,
    { desc = "DAP: previous right-bottom tab" })
  vim.api.nvim_create_user_command("UEDAPToggleUI",        function() M.dap_toggle_ui()        end, { desc = "DAP: Toggle UI" })
  vim.api.nvim_create_user_command("UEDAPREPL",            function() M.dap_toggle_repl()      end, { desc = "DAP: Toggle REPL" })
  vim.api.nvim_create_user_command("UEDAPStop", function()
    M.stop_android_debugger({ kill_orphans = true })
    vim.notify("[ue.dap] session stopped", vim.log.levels.INFO)
  end, { desc = "DAP: Stop / detach (Android: keeps app running)" })
  vim.api.nvim_create_user_command("UEDAPReattach", function()
    if type(M.android_dap_reattach) == "function" then
      M.android_dap_reattach()
    else
      vim.notify("UEDAPReattach unavailable", vim.log.levels.WARN)
    end
  end, { desc = "DAP: Reattach Android using last pkg/serial/symbol_lib" })
  vim.api.nvim_create_user_command("UEDAPStatus", function()
    if type(M.android_dap_status) == "function" then
      M.android_dap_status()
    else
      vim.notify("UEDAPStatus unavailable", vim.log.levels.WARN)
    end
  end, { desc = "DAP: One-line status of the current Android session" })

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

-- ==========================================================================
-- ASYNC COMPILE_COMMANDS SUBPROCESS
-- ==========================================================================
-- Generating compile_commands.json on the main thread freezes nvim for 17s+
-- on UE5 projects (parse 11k .rsp files, scan 2k shaders, encode/write 224MB
-- JSON x2). To eliminate that freeze we re-run the entire pipeline in a
-- headless nvim subprocess and stream progress events back via stderr.

-- Subprocess entry: called by lua/ue/ccjson_subprocess.lua after it loaded
-- ctx from a JSON file passed on argv. Re-runs the same generate_compile_commands
-- the in-process path would, but with the progress callback wired to stderr.
function M._ccjson_subprocess_run(ctx, progress)
  -- We only run generate_compile_commands_from_rsp here, NOT the full
  -- generate_compile_commands. The latter also kicks off run_compile_commands_pipeline
  -- which uses vim.fn.jobstart — those jobs would be killed when this short-lived
  -- headless nvim exits. The main nvim must start the pipeline itself after
  -- it receives DONE.
  local rsp_count, rsp_path = generate_compile_commands_from_rsp(ctx, progress)
  if rsp_count and rsp_count > 0 then
    return true, rsp_path
  end
  return false, rsp_path or "no rsp entries"
end

-- Spawn a headless nvim subprocess that runs the ccjson pipeline.
--   ctx          — same ctx table the in-process path would pass
--   on_progress  — function(stage, pct, detail) called per PROGRESS line
--   on_done      — function(ok, msg) called once when the subprocess exits
-- Returns the vim.system handle so caller can keep a reference if needed.
function M.async_generate_compile_commands(ctx, on_progress, on_done)
  on_progress = on_progress or function() end
  on_done = on_done or function() end

  -- 1. Dump ctx to a temp JSON file (argv has size limits on Windows).
  local tmp = vim.fn.tempname() .. ".ccjson-ctx.json"
  local ok_enc, ctx_json = pcall(vim.json.encode, ctx)
  if not ok_enc then
    on_done(false, "ctx encode failed: " .. tostring(ctx_json))
    return nil
  end
  local fh, ferr = io.open(tmp, "wb")
  if not fh then
    on_done(false, "tmp ctx write failed: " .. tostring(ferr))
    return nil
  end
  fh:write(ctx_json)
  fh:close()

  -- 2. Build the headless nvim command.
  --    -u NONE skips init.lua so LazyVim/plugins don't load (saves ~3s startup).
  --    --cmd 'set rtp+=... | lua package.path=...' wires our config's lua/ dir
  --    so `require("ue")` finds this file and its submodules.
  local nvim_exe = vim.v.progpath
  local config_lua = vim.fn.stdpath("config") .. "/lua"
  local sub_entry = config_lua .. "/ue/ccjson_subprocess.lua"
  local rtp_cmd = string.format(
    "lua package.path=%q..';'..%q..';'..package.path",
    config_lua .. "/?.lua",
    config_lua .. "/?/init.lua"
  )

  local cmd = {
    nvim_exe,
    "--headless",
    "-u", "NONE",
    "--cmd", rtp_cmd,
    "-l", sub_entry,
    tmp,
  }

  -- 3. Stream stderr — one progress event per line.
  local stderr_buf = ""
  local last_stage, last_pct, last_detail = "starting", 25, "spawning subprocess..."
  local function consume_stderr(chunk)
    if not chunk or chunk == "" then return end
    stderr_buf = stderr_buf .. chunk
    while true do
      local nl = stderr_buf:find("\n", 1, true)
      if not nl then break end
      local line = stderr_buf:sub(1, nl - 1):gsub("\r$", "")
      stderr_buf = stderr_buf:sub(nl + 1)
      if line ~= "" then
        local stage, pct, detail = line:match("^PROGRESS|([^|]+)|(%-?%d+)|(.*)$")
        if stage then
          last_stage, last_pct, last_detail = stage, tonumber(pct) or 0, detail
          vim.schedule(function()
            on_progress(stage, tonumber(pct) or 0, detail)
          end)
        else
          local preferred = line:match("^DONE|([^|]*)|")
          if preferred then
            last_stage = "done"
          else
            -- Anything else (ERROR|..., or stray output) — keep for failure msg.
            last_detail = line
          end
        end
      end
    end
  end

  -- 4. Spawn.
  local handle = vim.system(cmd, {
    text = true,
    stderr = function(_, data) consume_stderr(data) end,
    stdout = function(_, _) end, -- subprocess only writes progress to stderr
  }, function(obj)
    -- Final flush in case stderr didn't end with \n.
    if stderr_buf ~= "" then
      consume_stderr("\n")
    end
    pcall(os.remove, tmp)
    vim.schedule(function()
      if obj.code == 0 then
        on_done(true, "compile_commands.json (async subprocess)")
      else
        local msg = string.format("ccjson subprocess exit=%d: %s", obj.code or -1, last_detail)
        on_done(false, msg)
      end
    end)
  end)

  return handle
end

return M
