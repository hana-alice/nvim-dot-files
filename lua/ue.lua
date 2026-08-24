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
  target_launch_running = {}, -- target id -> true while one launch owns the route
  project_state = require("ue.project_state"),
  file_lock = require("ue.file_lock"),
  prepare_lease = nil,
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
-- F1 split phase-1: the clangd index subsystem now lives in lua/ue/index/.
-- INDEX_FN keeps its historical name so ~60 call sites below are unchanged;
-- INDEX_RT is the SAME table the module mutates (M._rt), so :UESetProject
-- cleanup and status-cache code below keep working on live state.
local INDEX_FN = require("ue.index")
-- Phase C: tunables sourced from `ue.config`. Literal fallbacks (`or 120000`
-- etc.) match the previous hard-coded values exactly so behaviour is
-- unchanged when no user override is provided. The fallbacks also keep this
-- chunk loadable if `ue.config` ever fails to require.
local _ue_cfg = require("ue.config")
local INDEX_RT = INDEX_FN._rt
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

local function dispatch_registered_workflow(target_id, operation, opts)
  require("ue.workflows.bootstrap").ensure_registered()
  local workflows = require("ue.workflows")
  if not workflows.lookup(target_id, operation) then
    return nil, nil, false
  end
  opts = opts or {}
  local result, err = workflows.dispatch(target_id, operation, {
    host_driver = opts.host_driver or require("utils.platform").driver(),
    snapshot = opts.snapshot,
    context = opts.context,
    payload = opts.payload,
    deps = opts.deps,
  })
  return result, err, true
end

function CORE_RT.invoke_workflow_api(target_id, operation, method, args, host_driver)
  return require("ue.workflows").invoke(
    target_id,
    operation,
    method,
    args,
    host_driver or require("utils.platform").driver()
  )
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

-- ==========================================================================
-- CLANGD / LSP
-- ==========================================================================

local function is_native_windows()
  return _uplat.is_windows
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

  vim.list_extend(candidates, _uplat.driver().default_clangd_candidates())

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

-- Forward declaration for find_engine_root, which is defined further below.
-- clangd_cmd receives the root resolved by vim.lsp's dynamic cmd factory;
-- keep this chunk-local binding available before that factory can run.
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
    "--clang-tidy=false",               -- explicit because project/user config is disabled below
    "--enable-config=false",             -- reject stale project/user External.File fragments
    "--function-arg-placeholders=true",
    "--limit-results=200",
    "--limit-references=200",
    "--query-driver=" .. table.concat(_uplat.driver().query_driver_globs(), ","),
  }

  -- Point clangd at this process's project+platform CDB bucket. Without an
  -- explicit directory clangd may discover a different Neovim instance's
  -- legacy engine-root compile_commands.json.
  if root_dir and root_dir ~= "" then
    local engine_root = find_engine_root(root_dir)
    if engine_root then
      local state = CORE_RT.project_state.read(engine_root)
      local plat = trim(state.target_platform or "")
      local conf = trim(state.target_configuration or ""):gsub(" Editor$", "")
      local platform_key = plat ~= "" and (conf ~= "" and (plat .. "-" .. conf) or plat) or nil
      local scoped_paths = cache_paths(engine_root, platform_key)
      local cc_path = scoped_paths.active_cdb
      local cc_mtime = 0
      if _ufs.is_file(cc_path) then
        local st = vim.uv.fs_stat(cc_path)
        cc_mtime = st and st.mtime and st.mtime.sec or 0
      end
      -- Broad cross-TU coverage comes from controlled BackgroundIndex CDBs
      -- built from compiler-authored UBT unity membership plus exact per-file
      -- fallback. clangd 22's monolithic
      -- External.File path was independently proven to return only the header
      -- declaration even when its YAML Symbol has a .cpp Definition.  Prefer
      -- the generated CDB only while it is at least as fresh as the active CDB.
      -- Canonical-USR destination lookup additionally uses these same proven
      -- module AST contexts, so correctness does not depend on queue timing.
      local semantic_cdb = scoped_paths.semantic_cdb
      local semantic_stat = _ufs.is_file(semantic_cdb) and vim.uv.fs_stat(semantic_cdb) or nil
      local semantic_mtime = semantic_stat and semantic_stat.mtime and semantic_stat.mtime.sec or 0
      if semantic_mtime > 0 and (cc_mtime == 0 or semantic_mtime >= cc_mtime) then
        table.insert(cmd, "--compile-commands-dir=" .. vim.fs.dirname(semantic_cdb))
      elseif _ufs.is_file(cc_path) then
        table.insert(cmd, "--compile-commands-dir=" .. vim.fs.dirname(cc_path))
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
  local existing = io.open(path, "rb")
  if existing then
    local current = existing:read("*a")
    existing:close()
    if current == content then return true end
  end
  local temp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local file, err = io.open(temp, "wb")
  if not file then
    require("utils.log").notify_error("ue.io", "write_all failed: " .. (err or path))
    return false
  end
  file:write(content)
  file:flush()
  file:close()
  local ok, rename_err = vim.uv.fs_rename(temp, path)
  if not ok then
    pcall(os.remove, temp)
    require("utils.log").notify_error("ue.io", "atomic replace failed: " .. tostring(rename_err or path))
    return false
  end
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
  return write_all(path, table.concat(lines, "\n") .. "\n")
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

  -- Nested workspace layout: <workspace>/Source/<Project>/*.uproject.
  -- Reuse the unique-project detector instead of assuming a project name.
  local nested_dir = CORE_RT.project_module_anchor and CORE_RT.project_module_anchor(dir) or dir
  if nested_dir ~= norm(dir) and _ufs.is_dir(nested_dir) then
    local m2 = vim.fn.globpath(nested_dir, "*.uproject", false, true)
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

local function available_platform_choices(project_root, uproject, host_driver)
  local solution = solution_configuration_data(project_root, uproject)
  local candidates = {}
  local seen = {}
  for _, candidate in ipairs(solution and solution.platforms or {}) do
    push_unique(candidates, seen, candidate)
  end
  -- A checked-out .sln may describe a different host. Always merge canonical
  -- targets before applying the host matrix so macOS is not left with an empty
  -- picker merely because the repository also contains Win64/Android entries.
  for _, candidate in ipairs(UE_CONST.DEFAULT_PLATFORM_CHOICES) do
    push_unique(candidates, seen, candidate)
  end
  host_driver = host_driver or _uplat.driver()
  local supported = {}
  for _, candidate in ipairs(candidates) do
    if require("ue.targets").supports(candidate, "build", host_driver) then
      supported[#supported + 1] = candidate
    end
  end
  return supported
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
-- Stored in the selected project bucket under `uproject_relative_path` (e.g.
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

  -- Reject Windows drive-relative paths like "E:sample/..." (missing slash
  -- after the drive letter). vim.fn.isdirectory() may still resolve them
  -- via the per-drive cwd quirk, but they break downstream UBT/clangd
  -- invocations and confuse is_windows_path(). Force the caller to supply
  -- an absolute path.
  if path:match("^[A-Za-z]:[^\\/]") then
    return nil, nil,
      "Drive-relative path not allowed: " .. path ..
      " (missing slash after drive letter, e.g. use 'E:/sample/...' not 'E:sample/...')"
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

-- Cache layout v4 (multi-instance/project isolation):
--   .cache/nvim-ue/
--     selection.json                          -- startup default only
--     projects/<canonical-project-key>/       -- no basename collisions
--       state-fields/                         -- atomic field-level state
--       csearch/csearch.idx                   -- platform-independent per project
--     gtags/<platform_key>/                   -- gtags input lists + DB (per-platform, v3.1)
--       workspace/         (GTAGS DB)
--       workspace.files / workspace_all.files / engine.files / project.files
--     (v3.2: csearch index is shared across all platforms — its input file set
--      has no platform dimension. Users upgrading from the old per-platform
--      csearch/<key>/csearch.idx are handled by mark-stale → next :UEPrepare
--      rebuilds the shared index. gtags/*.files still migrate per-platform via
--      migrate_legacy_csearch_if_needed.)
--     cdb/                                    -- clangd compile-db assets
--       modules.json, queue.json
--       compile_commands/{current,hot,full,inject_full}.json
--     clangd/                                 -- clangd-consumed artifacts (was: $root/.clangd-{index,pch})
--       index/<project>.{idx,current.idx,hot.idx,full.idx}
--       pch/<*.pch + build_pch.bat>
--       clangd/<platform_key>/                 -- platform-isolated CDB/index/PCH
--       logs/                                  -- ue.lua job/indexer logs
--       runtime/dirty.json                     -- merge-safe watcher persistence
--       legacy/                                -- pre-v2 holdouts (manual prune)
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
-- The canonical project bucket is the primary isolation boundary. Within it,
-- gtags and clangd/CDB/PCH artifacts are platform-scoped; csearch is shared
-- only by platforms of that same project because its input set is platform
-- independent.
cache_paths = function(engine_root, platform_key, selection)
  local engine_cache = join(engine_root, ".cache", "nvim-ue")
  selection = selection or CORE_RT.project_state.current(engine_root)
  local cache = CORE_RT.project_state.project_cache_root(engine_root, selection) or engine_cache
  platform_key = (type(platform_key) == "string" and platform_key ~= "") and platform_key or nil
  -- csearch index is PLATFORM-INDEPENDENT within the selected project. Its
  -- input file set (workspace_all.files) is derived
  -- from engine_root + project_root + platform-agnostic constants/whitelist
  -- (ENGINE_PICKER_DIRS / SCAN_EXCLUDES / .ueprepare-scan-paths), so the
  -- trigram index has no platform dimension. The flat `csearch/` path also
  -- aligns with csearch_input_hash stored in the project state bucket.
  -- See change `refactor-search-system` (de-platforming) for the proof.
  -- gtags/cdb REMAIN per-platform (compile args/macros/includes differ).
  local csearch_dir = join(cache, "csearch")
  local gtags_root = platform_key and join(cache, "gtags", platform_key) or join(cache, "gtags")
  local cdb_dir = join(cache, "cdb")
  -- The shard catalog intentionally spans platforms so fast-swap can select
  -- existing shards. Index scheduling state and controlled subset CDBs do
  -- depend on platform/configuration and must not be shared by live instances.
  local cdb_shards_dir = join(cdb_dir, "compile_commands", "shards")
  local index_runtime_dir = join(cdb_dir, "index", platform_key or "default")
  local cdb_files_dir = join(index_runtime_dir, "compile_commands")
  local logs_dir = join(cache, "logs")
  local runtime_dir = join(cache, "runtime")
  local legacy_dir = join(cache, "legacy")
  local clangd_dir = join(cache, "clangd", platform_key or "default")
  local active_index_dir = join(clangd_dir, "index")
  local pch_dir = join(clangd_dir, "pch")
  local project_name = selection and vim.fn.fnamemodify(selection.project_root, ":t")
    or vim.fn.fnamemodify(engine_root, ":t")
  return {
    engine_cache = engine_cache,
    cache = cache,
    project_key = selection and selection.project_key or nil,
    state = CORE_RT.project_state.state_path(engine_root, selection) or join(engine_cache, "state.json"),
    state_revision = CORE_RT.project_state.revision_path(engine_root, selection) or join(engine_cache, "state.json"),
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
    index_state = join(index_runtime_dir, "modules.json"),
    index_queue = join(index_runtime_dir, "queue.json"),
    index_cdb_dir = cdb_files_dir,
    cdb_shards_dir = cdb_shards_dir,
    index_current_cdb = join(cdb_files_dir, "current.json"),
    index_hot_cdb = join(cdb_files_dir, "hot.json"),
    index_full_cdb = join(cdb_files_dir, "full.json"),
    index_inject_full_cdb = join(cdb_files_dir, "inject_full.json"),
    active_cdb = join(cdb_dir, "active", platform_key or "default", "compile_commands.json"),
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
    semantic_cdb_dir = join(clangd_dir, "background-cdb"),
    semantic_cdb = join(clangd_dir, "background-cdb", "compile_commands.json"),
    semantic_current_cdb = join(clangd_dir, "background-cdb", "current", "compile_commands.json"),
    semantic_hot_cdb = join(clangd_dir, "background-cdb", "hot", "compile_commands.json"),
    semantic_full_cdb = join(clangd_dir, "background-cdb", "full", "compile_commands.json"),
    pch_dir = pch_dir,
    pch_build_bat = join(pch_dir, "build_pch.bat"),
  }
end

-- Resolve the pre-v4 engine-wide cache layout without consulting the current
-- project selection. cache_paths() can no longer represent this layout once a
-- project is captured, because it correctly returns the canonical project
-- bucket. Migration must keep an explicit source model or it silently compares
-- the project bucket with itself and leaves every legacy artifact behind.
function CORE_RT.legacy_engine_cache_paths(engine_root, platform_key)
  local cache = join(engine_root, ".cache", "nvim-ue")
  local gtags_root = platform_key and platform_key ~= ""
      and join(cache, "gtags", platform_key) or join(cache, "gtags")
  local cdb = join(cache, "cdb")
  local controlled = join(cdb, "compile_commands")
  return {
    cache = cache,
    state = join(cache, "state.json"),
    csearch_idx = join(cache, "csearch", "csearch.idx"),
    platform_csearch_idx = platform_key and platform_key ~= ""
        and join(cache, "csearch", platform_key, "csearch.idx") or nil,
    gtags_root = gtags_root,
    project_list = join(gtags_root, "project.files"),
    engine_list = join(gtags_root, "engine.files"),
    workspace_list = join(gtags_root, "workspace.files"),
    workspace_all_list = join(gtags_root, "workspace_all.files"),
    workspace_db = join(gtags_root, "workspace"),
    flat_gtags_root = join(cache, "gtags"),
    active_cdb = join(engine_root, "compile_commands.json"),
    index_state = join(cdb, "modules.json"),
    index_queue = join(cdb, "queue.json"),
    index_current_cdb = join(controlled, "current.json"),
    index_hot_cdb = join(controlled, "hot.json"),
    index_full_cdb = join(controlled, "full.json"),
    index_inject_full_cdb = join(controlled, "inject_full.json"),
  }
end

-- Migrate legacy grep/CDB artifacts into the canonical project bucket and the
-- old flat gtags layout into its active platform directory.
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
  local active = cache_paths(engine_root, platform_key)
  local project_scoped = norm(active.cache) ~= norm(active.engine_cache)
  local legacy = project_scoped
      and CORE_RT.legacy_engine_cache_paths(engine_root, platform_key)
      or cache_paths(engine_root)                    -- pre-v3.1 flat layout

  -- An engine-wide v3 cache has no bucket in its path. Import it only when its
  -- persisted canonical project identity matches the selected v4 bucket.
  -- Otherwise a project switch could seed project B with project A's index.
  if project_scoped then
    local raw = read_all(legacy.state)
    local ok_state, legacy_state = pcall(vim.json.decode, raw or "")
    local legacy_key = ok_state and type(legacy_state) == "table"
        and CORE_RT.project_state.project_key(legacy_state.project_root, legacy_state.uproject) or nil
    if not legacy_key or legacy_key ~= active.project_key then
      return false
    end
  end

  local migration_lease = CORE_RT.file_lock.acquire(join(active.cache, "legacy-migration.lock"))
  if not migration_lease then return false end
  local moved = false

  local function move_if(src, dst)
    if not src or not dst or src == dst then return end
    if _ufs.is_file(src) and not _ufs.is_file(dst) then
      _ufs.ensure_dir(_ufs.dirname(dst))
      -- os.rename works within the same volume (cache always lives under one
      -- engine_root, so src/dst share a drive). Fall back to copy+remove only
      -- if rename fails (defensive; shouldn't happen on same volume).
      local called, renamed = pcall(os.rename, src, dst)
      local ok = called and renamed ~= nil
      if not ok then
        local data = nil
        local f = io.open(src, "rb")
        if f then data = f:read("*a"); f:close() end
        if data and write_all(dst, data) then
          pcall(os.remove, src)
          ok = true
        end
      end
      if ok then moved = true end
    end
  end

  -- v4 migration must not remove engine-wide files: an older Neovim process
  -- may still be using them. Source and destination are guaranteed to share a
  -- filesystem (both live below engine_root), so a hard link publishes even a
  -- multi-GB csearch/CDB artifact in O(1). Future writers atomically replace
  -- the project-bucket pathname and therefore do not mutate the legacy inode.
  local function link_if(src, dst)
    if not src or not dst or src == dst then return false end
    if not _ufs.is_file(src) or _ufs.is_file(dst) then return false end
    _ufs.ensure_dir(_ufs.dirname(dst))
    local temp = dst .. (".migrate.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
    local linked = vim.uv.fs_link(src, temp)
    if not linked then return false end
    -- A concurrent canonical writer wins; migration never overwrites it.
    if _ufs.is_file(dst) then
      pcall(vim.uv.fs_unlink, temp)
      return false
    end
    local published = vim.uv.fs_rename(temp, dst)
    if not published then
      pcall(vim.uv.fs_unlink, temp)
      return false
    end
    moved = true
    return true
  end

  local function first_existing(paths)
    for _, path in ipairs(paths) do
      if path and _ufs.is_file(path) then return path end
    end
    return nil
  end

  if project_scoped then
    local legacy_idx = first_existing({ legacy.csearch_idx, legacy.platform_csearch_idx })
    link_if(legacy_idx, active.csearch_idx)
    link_if(legacy_idx and (legacy_idx .. ".files") or nil, active.csearch_idx .. ".files")

    local function legacy_gtags_file(name)
      return first_existing({
        join(legacy.gtags_root, name),
        join(legacy.flat_gtags_root, name),
      })
    end
    link_if(legacy_gtags_file("project.files"), active.project_list)
    link_if(legacy_gtags_file("engine.files"), active.engine_list)
    link_if(legacy_gtags_file("workspace.files"), active.workspace_list)
    link_if(legacy_gtags_file("workspace_all.files"), active.workspace_all_list)
    for _, name in ipairs({ "GTAGS", "GPATH", "GRTAGS" }) do
      link_if(first_existing({
        join(legacy.workspace_db, name),
        join(legacy.flat_gtags_root, "workspace", name),
      }), join(active.workspace_db, name))
    end

    -- The engine-root compile_commands.json was the proven active consumer in
    -- v3. Preserve it as the v4 process-local active CDB; controlled subsets
    -- are imported independently when present.
    link_if(legacy.active_cdb, active.active_cdb)
    link_if(legacy.index_state, active.index_state)
    link_if(legacy.index_queue, active.index_queue)
    link_if(legacy.index_current_cdb, active.index_current_cdb)
    link_if(legacy.index_hot_cdb, active.index_hot_cdb)
    link_if(legacy.index_full_cdb, active.index_full_cdb)
    link_if(legacy.index_inject_full_cdb, active.index_inject_full_cdb)

    CORE_RT.file_lock.release(migration_lease)
    return moved
  end

  -- csearch index is now PLATFORM-INDEPENDENT (flat csearch/csearch.idx for
  -- all platforms — see cache_paths + change `refactor-search-system`). So
  -- legacy.csearch_idx == active.csearch_idx and there is nothing to migrate
  -- here. Users upgrading from the old per-platform csearch layout
  -- (csearch/<key>/csearch.idx) are handled by mark-stale: the flat index
  -- won't exist, prepare_freshness returns "stale", and the next :UEPrepare
  -- rebuilds the shared index. The old csearch/<key>/ dirs are left untouched
  -- (not deleted solely due to de-platforming).
  -- grep file lists (gtags — still per-platform)
  move_if(legacy.project_list, active.project_list)
  move_if(legacy.engine_list, active.engine_list)
  move_if(legacy.workspace_list, active.workspace_list)
  move_if(legacy.workspace_all_list, active.workspace_all_list)
  -- gtags DB files
  for _, name in ipairs({ "GTAGS", "GPATH", "GRTAGS" }) do
    move_if(join(legacy.workspace_db, name), join(active.workspace_db, name))
  end

  CORE_RT.file_lock.release(migration_lease)
  return moved
end

read_state = function(engine_root)
  return CORE_RT.project_state.read(engine_root)
end

local function persist_project(engine_root, project_root, uproject)
  local selection, err = CORE_RT.project_state.select(engine_root, project_root, uproject)
  if not selection then return nil, err end
  return read_state(engine_root)
end

update_state_field = function(engine_root, key, value)
  return CORE_RT.project_state.update(engine_root, key, value)
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
    -- Stale-state guard: if the project revision changed since this
    -- ctx was built, drop the cache entry. Without this guard external
    -- writers (other nvim processes, build scripts) would be invisible
    -- for up to _CONTEXT_TTL seconds.
    if cached.ctx and cached.state_revision_path then
      local revision = read_all(cached.state_revision_path) or ""
      if revision == (cached.state_revision or "") then
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

  local selection = CORE_RT.project_state.current(engine_root)
  local state = read_state(engine_root)
  local project_root, uproject

  -- Project selection is manual-only. Current cwd/buffers may belong to a
  -- different checkout and must never override :UESetProject state.
  if state.project_root then
    local persisted_root = norm(state.project_root)
    local persisted_uproject = norm(state.uproject or "")
    if _ufs.is_dir(persisted_root)
      and persisted_uproject ~= ""
      and _ufs.is_file(persisted_uproject)
    then
      project_root = persisted_root
      uproject = persisted_uproject
    else
      project_root, uproject = resolve_project_input(persisted_root, engine_root)
    end
  end

  local platform_key = CORE_RT.platform_key_from_state(state)
  -- v3.1: migrate legacy single-path grep caches into the active platform
  -- subdir once, so an existing index survives the layout change.
  if platform_key ~= "" then
    pcall(CORE_RT.migrate_legacy_csearch_if_needed, engine_root, platform_key)
  end
  local paths = cache_paths(engine_root, platform_key, selection)
  local state_revision = read_all(paths.state_revision) or ""

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
    state_revision_path = paths.state_revision,
    state_revision = state_revision,
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
  local seen = {}
  for _, search_path in ipairs(search_paths or {}) do
    local absolute = join(root, search_path)
    local key = _uplat.driver().path_key(absolute)
    if not seen[key] and _ufs.is_dir(absolute) then
      seen[key] = true
      table.insert(dirs, search_path)
    end
  end
  return dirs
end

function M._existing_relative_dirs_for_test(root, search_paths)
  return existing_relative_dirs(root, search_paths)
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
  -- Inspect exactly Source/*/*.uproject without editor glob options. globpath()
  -- can omit valid files under the test/runtime option set on Windows, while
  -- this shallow libuv walk is deterministic and avoids a recursive Source scan.
  local nested = {}
  local uvfs = vim.uv or vim.loop
  local source_scan = uvfs.fs_scandir(join(project_root, "Source"))
  while source_scan and #nested <= 1 do
    local dir_name, dir_type = uvfs.fs_scandir_next(source_scan)
    if not dir_name then break end
    if dir_type == "directory" then
      local child_root = join(project_root, "Source", dir_name)
      local child_scan = uvfs.fs_scandir(child_root)
      while child_scan do
        local file_name, file_type = uvfs.fs_scandir_next(child_scan)
        if not file_name then break end
        if file_type == "file" and file_name:lower():match("%.uproject$") then
          nested[#nested + 1] = join(child_root, file_name)
          if #nested > 1 then break end
        end
      end
    end
  end
  if #nested == 1 then
    anchor = norm(_ufs.dirname(nested[1]))
  end

  CORE_RT.project_module_anchor_cache[project_root] = anchor
  return anchor
end

-- Project-specific scan whitelist. Path = `<project_root>/.ueprepare-scan-paths`,
-- one entry per line, # for comments. Each entry is a root-relative directory
-- (e.g. `Source/SampleGame/Source`, `Source/Protocol`). When the file exists, it
-- REPLACES UE_CONST.PROJECT_INDEX_DIRS for this project. When absent, the
-- default PROJECT_INDEX_DIRS is used. For the supported nested layout
-- (<project_root>/Source/<Project>/<Project>.uproject), defaults are resolved
-- relative to the .uproject directory so a broad project_root/Source scan does
-- not pull sibling config tables, SDKs, and generated data into the index.
--
-- Why whitelist > blacklist (.ueprepare-scan-ignore was deleted): some
-- projects bury non-source data (config tables, SDK toolchains, art assets)
-- under `Source/`. Blacklist plays whack-a-mole; whitelist is declarative
-- and cuts scan input dramatically (verified 877k -> 116k on sample_dev).
--
-- Cached per-project on CORE_RT to avoid repeated disk reads. Use
-- :UEReloadScanPaths to invalidate (see command below).
CORE_RT.project_index_dirs_cache = CORE_RT.project_index_dirs_cache or {}

function CORE_RT.project_index_dirs(ctx)
  local project_root = norm(ctx and ctx.project_root or "")
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

  local result = dirs
  if not result then
    local anchor = CORE_RT.project_module_anchor(project_root)
    if anchor ~= project_root and _ufs.path_has_prefix(anchor, project_root) then
      local prefix = _ufs.relative_to(project_root, anchor)
      result = vim.tbl_map(function(relative)
        return join(prefix, relative)
      end, UE_CONST.PROJECT_INDEX_DIRS)
    else
      result = UE_CONST.PROJECT_INDEX_DIRS
    end
  end
  CORE_RT.project_index_dirs_cache[project_root] = result
  return result
end

-- Test seam: keep scan-root policy observable without exposing CORE_RT.
function M._project_index_dirs_for_test(ctx)
  return vim.deepcopy(CORE_RT.project_index_dirs(ctx))
end

function CORE_RT.project_scan_roots_match(ctx, recorded)
  return type(recorded) == "table"
    and vim.deep_equal(recorded, CORE_RT.project_index_dirs(ctx))
end

function M._project_scan_roots_match_for_test(ctx, recorded)
  return CORE_RT.project_scan_roots_match(ctx, recorded)
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

-- ── clangd index subsystem — extracted to lua/ue/index/ (F1 phase-1) ────────
-- The 1300-line INDEX block that lived here moved to lua/ue/index/
-- (_state / _clangd / _build). The subsystem needs late-bound closures over
-- chunk-locals that intentionally stay in this file (status/statusline
-- plumbing + raw IO). status_root_key etc. are forward-declared above and
-- assigned further below — the closures resolve the upvalues at CALL time,
-- so binding order is safe.
INDEX_FN.setup({
  core_rt = CORE_RT,
  plugin_scope_from_root = plugin_scope_from_root,
  project_module_scope = project_module_scope,
  engine_module_scope = engine_module_scope,
  status_root_key = function(ctx) return status_root_key(ctx) end,
  clear_index_dirty = function(ctx) return clear_index_dirty(ctx) end,
  mark_index_dirty = function(ctx) return mark_index_dirty(ctx) end,
  invalidate_status_cache = function() return invalidate_status_cache() end,
  refresh_statusline = function() return refresh_statusline() end,
  read_all = function(p) return read_all(p) end,
  write_all = function(p, c) return write_all(p, c) end,
})
-- Former file-locals still referenced below (clear/mark_index_dirty,
-- UEIndexModules listing, :UESetProject cleanup) — re-bound from the module.
local ensure_index_state = INDEX_FN.ensure_index_state
local save_index_state = INDEX_FN.save_index_state
local sorted_module_records = INDEX_FN.sorted_module_records
local module_tier_label = INDEX_FN.module_tier_label

local function index_output_paths(ctx)
  local outputs = {}
  local compile_commands = ctx.paths and ctx.paths.active_cdb or nil
  if compile_commands and compile_commands ~= "" then
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
    tostring(ctx.paths and ctx.paths.platform_key or "default"),
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
  -- Scan roots are part of the cache identity. This invalidates pre-fix lists
  -- that scanned project_root/Source broadly, and also makes whitelist/layout
  -- changes trigger one deliberate rebuild instead of reusing stale file sets.
  local state = read_state(ctx.engine_root)
  if not CORE_RT.project_scan_roots_match(ctx, state.project_scan_roots) then
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

-- True while the UEBuild/UEBuildAndroidSO terminal job is alive. Used to
-- enforce build ⇄ prepare mutual exclusion: the prepare family READS build
-- products (Module.*.rsp, receipts, binaries) that the build is WRITING —
-- running them concurrently is a write-after-write/read-during-write hazard
-- that yields torn CDBs and wastes CPU the build needs. Parked on CORE_RT
-- (LuaJIT 200-local cap, see CONSTRAINTS).
function CORE_RT.ue_build_running()
  if not CORE_RT.build_term_jobid then
    return false
  end
  local ok, result = pcall(vim.fn.jobwait, { CORE_RT.build_term_jobid }, 0)
  return ok and type(result) == "table" and result[1] == -1
end

local function set_prepare_running(value)
  value = not not value
  if M._prepare_running == value then
    return
  end
  M._prepare_running = value
  if not value and CORE_RT.prepare_lease then
    CORE_RT.file_lock.release(CORE_RT.prepare_lease)
    CORE_RT.prepare_lease = nil
  end
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
function CORE_RT.csearch_build_begin(label, index_path)
  if CORE_RT.csearch_build_running then
    vim.schedule(function()
      vim.notify(
        ("[ue] csearch build already in progress — %s skipped"):format(label or "build"),
        vim.log.levels.WARN, { title = "UE", replace = "ue.csearch.build" })
    end)
    return false
  end
  if index_path and index_path ~= "" then
    local lease, lease_err = CORE_RT.file_lock.acquire(index_path .. ".writer.lock")
    if not lease then
      vim.schedule(function()
        vim.notify(
          ("[ue] csearch build owned by another Neovim — %s skipped (%s)"):format(
            label or "build", tostring(lease_err)),
          vim.log.levels.WARN, { title = "UE", replace = "ue.csearch.build" })
      end)
      return false
    end
    CORE_RT.csearch_build_lease = lease
  end
  CORE_RT.csearch_build_running = true
  CORE_RT.csearch_build_started_at = os.time()
  local ok_watch, watch = pcall(require, "utils.ue_watch")
  CORE_RT.csearch_build_dirty_snapshot = ok_watch
      and type(watch.snapshot_persistent_dirty) == "function"
      and watch.snapshot_persistent_dirty() or {}
  return true
end

function CORE_RT.csearch_build_done()
  CORE_RT.csearch_build_running = false
  if CORE_RT.csearch_build_lease then
    CORE_RT.file_lock.release(CORE_RT.csearch_build_lease)
    CORE_RT.csearch_build_lease = nil
  end
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
function CORE_RT.clear_persistent_dirty_safe(reason, covered_paths, covered_before, remove_missing)
  local ok_watch, watch = pcall(require, "utils.ue_watch")
  if not ok_watch then return false end
  if type(covered_paths) == "table" and type(watch.remove_persistent_dirty) == "function" then
    return watch.remove_persistent_dirty(
      covered_paths, reason or "prepare", covered_before, remove_missing)
  end
  if type(watch.clear_persistent_dirty) == "function" then
    return watch.clear_persistent_dirty(reason or "prepare")
  end
  return false
end

-- Called once on EVERY full csearch build SUCCESS path (sync / cache fast-path /
-- cold full). Bundles the two post-success obligations so the three call sites
-- can't drift:
--   D-3b: subtract the dirty snapshot captured when this writer started. A
--         different Neovim may add paths while cindex is running; those must
--         remain visible after publication.
--   D10:  record the content fingerprint of the list we just indexed, so
--         prepare_freshness can compare future list bytes against it.
-- MUST only be called on SUCCESS. On failure neither obligation applies (dirty
-- files must stay visible; the fingerprint must not move ahead of a built index).
function CORE_RT.on_full_csearch_success(ctx, reason, stats)
  CORE_RT.clear_persistent_dirty_safe(
    reason,
    CORE_RT.csearch_build_dirty_snapshot or {},
    CORE_RT.csearch_build_started_at,
    stats and stats.mode == "reset")
  CORE_RT.csearch_build_dirty_snapshot = nil
  CORE_RT.csearch_build_started_at = nil
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

-- ── csearch smart incremental build (D11) ───────────────────────────────────
-- Every stale verdict used to trigger a FULL `-reset` rebuild (minutes on a UE
-- tree) even when the actual change was "3 files added". cindex natively
-- supports incremental `add` (re-index given paths, merge into the existing
-- idx) — what was missing is the DIFF: which files are new since the index was
-- last built. We record the exact absolute-path list fed to cindex on every
-- full-build success (snapshot at `<csearch_idx>.files`, per-platform since it
-- lives next to the idx — C5b) and diff against it on the next build.
--
-- Decision rules (pure, unit-tested via _csearch_build_mode_for_test):
--   * forced / no snapshot        → reset  (no basis for a diff)
--   * removed > 0                 → reset  (cindex CANNOT delete from an index;
--                                           ghost entries would serve hits for
--                                           dead files — correctness over speed)
--   * added + dirty == 0          → skip   (set unchanged; just refresh
--                                           bookkeeping)
--   * added + dirty > 30% of set  → reset  (merge cost approaches full build;
--                                           usually a branch switch)
--   * else                        → add    (feed ONLY the delta to cindex)
--
-- `dirty` = watcher's persistent set (modified existing files + new files).
-- Re-adding a modified file refreshes its trigrams, so content edits get folded
-- in on the cheap path too. An `add` that fails (corrupt/0-byte idx — the
-- build_index D9 guard refuses it) falls back to one reset automatically.
CORE_RT.CSEARCH_ADD_RATIO_MAX = 0.30

function CORE_RT.csearch_snapshot_path(ctx)
  local idx = ctx and ctx.paths and ctx.paths.csearch_idx
  if not idx or idx == "" then return nil end
  return idx .. ".files"
end

-- Pure decision. stats = { forced, has_snapshot, added_n, removed_n, dirty_n,
-- total_n }. Returns mode ("reset"|"add"|"skip") + human reason.
function CORE_RT.csearch_build_mode(stats)
  stats = stats or {}
  if stats.forced then return "reset", "forced" end
  if not stats.has_snapshot then return "reset", "no snapshot of last indexed set" end
  if (stats.removed_n or 0) > 0 then
    return "reset", ("%d removals (cindex cannot delete)"):format(stats.removed_n)
  end
  local work = (stats.added_n or 0) + (stats.dirty_n or 0)
  if work == 0 then return "skip", "indexed set unchanged" end
  local total = math.max(tonumber(stats.total_n) or 0, 1)
  if work > total * CORE_RT.CSEARCH_ADD_RATIO_MAX then
    return "reset", ("delta %d > %d%% of %d files"):format(
      work, math.floor(CORE_RT.CSEARCH_ADD_RATIO_MAX * 100), total)
  end
  return "add", ("+%d added, %d dirty"):format(stats.added_n or 0, stats.dirty_n or 0)
end

-- Read a list file into { set = {path=true}, list = {...}, n = count }.
local function read_list_file(path)
  local set, list, n = {}, {}, 0
  local f = path and io.open(path, "r") or nil
  if not f then return nil end
  for line in f:lines() do
    line = line:gsub("\r$", "")
    if line ~= "" and not set[line] then
      set[line] = true
      n = n + 1
      list[n] = line
    end
  end
  f:close()
  return { set = set, list = list, n = n }
end

-- Drop-in replacement for the three prepare-path build_index calls.
-- cb(ok, err, stats) — stats gains .mode ("reset"|"add"|"skip") and .delta.
-- Owns: diff, mode decision, add→reset fallback, snapshot refresh on success.
-- Does NOT own: csearch_build_begin/done (call sites keep that), fingerprint /
-- dirty-clear (call sites keep on_full_csearch_success — snapshot refresh here
-- is the only extra obligation, and it is idempotent).
function CORE_RT.csearch_smart_build(ctx, cs_ctx, abs_list, cb)
  local code_search = require("utils.code_search")
  local snap_path = CORE_RT.csearch_snapshot_path(ctx)
  local new_list = read_list_file(abs_list)
  if not new_list then
    vim.schedule(function() cb(false, "cannot read " .. tostring(abs_list), {}) end)
    return
  end

  local function snapshot_current()
    if not snap_path then return end
    pcall(function()
      local uvfs = vim.uv or vim.loop
      uvfs.fs_copyfile(abs_list, snap_path)
    end)
  end

  local function run_reset(reason, after_fallback)
    code_search.build_index(cs_ctx, abs_list, function(ok, err, stats)
      stats = stats or {}
      stats.mode = "reset"
      stats.delta = reason
      if ok then snapshot_current() end
      cb(ok, err, stats)
    end, { mode = "reset" })
    if after_fallback then
      vim.schedule(function()
        vim.notify("[ue] csearch incremental add failed — fell back to full rebuild ("
          .. tostring(after_fallback) .. ")", vim.log.levels.WARN,
          { title = "UE", replace = "ue.csearch.build" })
      end)
    end
  end

  -- Gather diff inputs.
  local old_list = snap_path and read_list_file(snap_path) or nil
  -- The sidecar predates the primary csearch index and can be absent after an
  -- upgrade or interrupted cleanup. Rebuild it without a full reset only when
  -- two independent facts agree: the primary index is usable, and the current
  -- canonical workspace list has the exact fingerprint recorded after the last
  -- successful build. The absolute temp list cannot be hashed for this check
  -- because workspace_all.files is workspace-relative on same-drive entries.
  if not old_list and snap_path and ctx and ctx.paths and ctx.paths.workspace_all_list then
    local state = read_state(ctx.engine_root)
    local recorded = state and state.csearch_input_hash or nil
    local current = CORE_RT.list_fingerprint(ctx.paths.workspace_all_list)
    local ok_indexed, indexed = pcall(code_search.is_indexed, cs_ctx)
    if ok_indexed and indexed and type(recorded) == "string" and recorded ~= ""
        and current == recorded then
      old_list = new_list
    end
  end
  local added, removed_n = {}, 0
  if old_list then
    for _, p in ipairs(new_list.list) do
      if not old_list.set[p] then added[#added + 1] = p end
    end
    for _, p in ipairs(old_list.list) do
      if not new_list.set[p] then removed_n = removed_n + 1 end
    end
  end
  -- Watcher dirty files still present in the new set (modified existing files;
  -- drop entries that vanished — they show up as removals instead).
  local dirty_in_set, dirty_seen = {}, {}
  do
    local ok_watch, watch = pcall(require, "utils.ue_watch")
    if ok_watch and type(watch.snapshot_persistent_dirty) == "function" then
      for _, p in ipairs(watch.snapshot_persistent_dirty() or {}) do
        if new_list.set[p] and not dirty_seen[p] then
          dirty_seen[p] = true
          dirty_in_set[#dirty_in_set + 1] = p
        end
      end
    end
  end
  -- added ∪ dirty without double-counting.
  local add_input, add_seen = {}, {}
  for _, p in ipairs(added) do
    if not add_seen[p] then add_seen[p] = true; add_input[#add_input + 1] = p end
  end
  for _, p in ipairs(dirty_in_set) do
    if not add_seen[p] then add_seen[p] = true; add_input[#add_input + 1] = p end
  end

  local mode, why = CORE_RT.csearch_build_mode({
    forced       = ctx and ctx._force_csearch or false,
    has_snapshot = old_list ~= nil,
    added_n      = #added,
    removed_n    = removed_n,
    dirty_n      = #dirty_in_set,
    total_n      = new_list.n,
  })

  -- Probe (D11 soak): record which mode each prepare takes, so the next
  -- session can verify the incremental path actually fires in daily use
  -- (report-first workflow — probe-feedback-loop spec #1).
  pcall(function()
    require("utils.probe").record("csearch-smart-build", mode, why)
  end)

  if mode == "skip" then
    snapshot_current()  -- ordering may differ; keep snapshot in lockstep with list
    vim.schedule(function()
      cb(true, nil, { mode = "skip", delta = why, ms = 0, index_size = 0, skipped = true })
    end)
    return
  end

  if mode == "reset" then
    run_reset(why)
    return
  end

  -- mode == "add": feed ONLY the delta.
  local add_list_path = abs_list .. (".add.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local fout = io.open(add_list_path, "w")
  if not fout then
    run_reset("cannot write add-list")
    return
  end
  for _, p in ipairs(add_input) do fout:write(p, "\n") end
  fout:close()
  code_search.build_index(cs_ctx, add_list_path, function(ok, err, stats)
    pcall(os.remove, add_list_path)
    if ok then
      stats = stats or {}
      stats.mode = "add"
      stats.delta = why
      snapshot_current()
      cb(true, nil, stats)
      return
    end
    -- Incremental refused/failed (typically D9 unusable-idx guard). One
    -- automatic reset — always safe — instead of surfacing a dead end.
    pcall(function()
      require("utils.probe").record("csearch-smart-build", "add-fallback-reset",
        tostring(err or "?"):sub(1, 120))
    end)
    run_reset("fallback after add failure", err or "?")
  end, { mode = "add" })
end

-- Test seams (D11).
function M._csearch_build_mode_for_test(stats) return CORE_RT.csearch_build_mode(stats) end
function M._csearch_snapshot_path_for_test(ctx) return CORE_RT.csearch_snapshot_path(ctx) end
function M._csearch_smart_build_for_test(ctx, cs_ctx, abs_list, cb)
  return CORE_RT.csearch_smart_build(ctx, cs_ctx, abs_list, cb)
end

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
-- build outputs live a few dirs down (`Source/<Project>/`). Using project_root
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
  --   2. Nested: <project_root>/Source/<Project>/<Project>.uproject
  --              + <project_root>/Source/<Project>/Source/*.Target.cs
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
  local driver = _uplat.driver()
  if type(driver.default_target) == "function" then
    local detected = trim(driver.default_target())
    if detected ~= "" then
      return detected
    end
  end
  -- A failed/unknown host driver must not silently masquerade as Linux.
  -- (2026-08-18 incident: the old bottom fallback returned "Linux" — a
  -- retired-WSL leftover — sending UBT after a Linux cross-compile SDK on a
  -- fresh checkout: `<Target> Linux Development` → "Unable to find valid
  -- SDK(s) for Linux" → exit 6. Main's platform-driver default_target()
  -- supersedes the inline drive-letter heuristic.)
  return ""
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

-- ==========================================================================
-- COMPILE_COMMANDS.JSON GENERATION
-- ==========================================================================

local function compile_commands_targets(ctx)
  return require("ue.cdb.paths").targets(ctx)
end

local function compile_commands_candidates(ctx, tuple)
  return require("ue.cdb.paths").candidates(ctx, {
    tuple = tuple,
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
  -- (and therefore Intermediate/Build) lives under <workspace>/Source/<Project>/.
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
  local rsp_driver = platform ~= "" and require("ue.targets").driver(platform) or nil
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

        -- Platform/config ownership is delegated to the selected Unreal
        -- target driver. Host OS and target platform are intentionally
        -- orthogonal; IOS never falls through to the Mac target classifier.
        if platform ~= "" then
          local classified = rsp_driver and rsp_driver.classify_rsp(p, {
            configuration = config_filter,
          }) or nil
          if classified and not classified.match then
            dominated = false
          elseif not classified and not p:find("/" .. platform .. "/", 1, true) then
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

        -- Unknown/legacy targets retain the old generic configuration guard.
        if dominated and not rsp_driver and config_filter and config_filter ~= "" then
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
--- @return string log_path
function M._logged_jobstart(cmd, tag, opts)
  opts = opts or {}
  local log_dir = vim.fn.stdpath("log") .. "/" .. tag
  vim.fn.mkdir(log_dir, "p")
  local log_path = log_dir .. ("/%s.%d.%s.log"):format(
    os.date("%Y%m%d-%H%M%S"), vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local log_lines = {}

  -- Stream the log to disk as lines arrive (open once, append + flush per
  -- batch) so a long-running job can be tailed LIVE. Previously the file was
  -- only written at exit, which made multi-minute pipelines look frozen: no
  -- log on disk, no output, until the process died. The exit code moves to a
  -- footer line since it is only known at the end.
  local log_file = io.open(log_path, "w")
  if log_file then
    log_file:write("# ue.lua " .. tag .. "\n")
    log_file:write("# cmd: " .. (type(cmd) == "table" and table.concat(cmd, " ") or tostring(cmd)) .. "\n")
    if opts.cdb then log_file:write("# cdb: " .. tostring(opts.cdb) .. "\n") end
    log_file:write(("# time: %s\n\n"):format(os.date("%Y-%m-%d %H:%M:%S")))
    log_file:flush()
  end

  -- jobstart on_stdout/on_stderr chunks are NOT line-aligned: data[1]
  -- continues the previous chunk's unfinished line and data[#data] may be an
  -- unfinished line ("" means the chunk ended exactly on a newline). Without
  -- stitching, one long print() lands in the log as several broken lines
  -- (observed in the ue_cdb behavioral test: "live-line-1" → "live-line"+
  -- "-1"). Keep one pending buffer per stream.
  local pending = { stdout = "", stderr = "" }

  local function emit(line)
    if line == "" then return end
    table.insert(log_lines, line)
    if log_file then
      log_file:write(line, "\n")
    end
  end

  local function on_data(stream)
    return function(_, data)
      if not data then return end
      local buf = pending[stream] .. (data[1] or "")
      for i = 2, #data do
        emit(buf)
        buf = data[i]
      end
      pending[stream] = buf
      if log_file then log_file:flush() end
    end
  end

  local function flush_log(code)
    -- Flush any unfinished trailing lines before the footer.
    emit(pending.stdout); pending.stdout = ""
    emit(pending.stderr); pending.stderr = ""
    if not log_file then return end
    log_file:write(("\n# exit: %s (%s)\n"):format(tostring(code), os.date("%Y-%m-%d %H:%M:%S")))
    log_file:close()
    log_file = nil
  end

  local job_opts = {
    stdout_buffered = false,
    stderr_buffered = false,
    on_stdout = on_data("stdout"),
    on_stderr = on_data("stderr"),
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

  local jobid = vim.fn.jobstart(cmd, job_opts)
  if (not jobid or jobid <= 0) and log_file then
    -- Job never spawned: close the streamed header so the handle doesn't leak.
    log_file:write("\n# exit: jobstart failed (" .. tostring(jobid) .. ")\n")
    log_file:close()
    log_file = nil
  end
  return jobid, log_path
end

--- Run PCH prebuild + include-dir unification in background after slim.
--- @param path string the compile_commands.json file to process
--- @param targets string[]|nil list of compile_commands targets; after pipeline
---        finishes the first target is copied to the others and clangd restarts.
--- @param on_done fun(ok:boolean, err:string?)? optional callback run AFTER the pipeline job completes.
---        CRITICAL: anything that reads/writes the base compile_commands.json
---        (e.g. cdb_partition) MUST run here, not concurrently with the async
---        pipeline — otherwise the two writers tear the file mid-write and the
---        pipeline's resolve stage hits a JSONDecodeError. See changelog
---        2026-06-25 "cdb_partition race".
local function run_compile_commands_pipeline(path, targets, on_done, opts)
  -- ue.cdb.pipeline drives the expand → pch → resolve → unify → prune
  -- chain. We inject `_logged_jobstart` here so the pipeline module stays
  -- import-safe (no circular require to ue.lua) and headlessly testable.
  local pipeline = require("ue.cdb.pipeline")
  pipeline.set_runtime({
    jobstart  = M._logged_jobstart,
    notify    = function(msg, level) vim.notify(msg, level) end,
    log_error = function(scope, msg) require("utils.log").notify_error(scope, msg) end,
  })
  return pipeline.run(path, targets, on_done, opts)
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
  local target_ctx, target_err, driver = CORE_RT.target_context(ctx)
  if not target_ctx then
    return false, "cannot validate compile_commands provenance: " .. tostring(target_err)
  end

  local source = require("ue.cdb.source")
  local rejected = {}
  local candidates = compile_commands_candidates(ctx, target_ctx)
  for _, candidate in ipairs(candidates) do
    local ok, info = source.read_valid(candidate, ctx, target_ctx, driver)
    if ok then
      return write_compile_commands_targets(ctx, info.content)
    end
    rejected[#rejected + 1] = candidate .. ": " .. tostring(info.reason)
  end

  if #rejected > 0 then
    return false, "no trusted compile_commands source for the active tuple; rejected "
      .. table.concat(rejected, " | ")
  end
  return false, "compile_commands.json not found at any controlled candidate path"
end

local function generate_compile_commands(ctx, progress, on_pipeline_done)
  local pipeline = require("ue.cdb.pipeline")
  if pipeline.is_running() then
    return false, "compile_commands pipeline is already running"
  end

  local targets = compile_commands_targets(ctx)
  on_pipeline_done = on_pipeline_done or function(ok_pipeline)
    if ok_pipeline then CORE_RT.start_deferred_clangd(ctx) end
  end

  local function start_pipeline(path)
    local jobid, pipeline_err = run_compile_commands_pipeline(path, targets, on_pipeline_done, {
      force_restart = ctx._force_cdb_restart == true,
    })
    if jobid == nil then
      return false, pipeline_err or "compile_commands pipeline failed to start"
    end
    return true
  end

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
    local ok_pipeline, pipeline_err = start_pipeline(targets[1])
    if not ok_pipeline then return false, pipeline_err end
    return true, rsp_path .. " (" .. rsp_count .. " entries from .rsp files)"
  end

  -- FALLBACK: reuse only a provenance-checked CDB from a controlled location.
  -- Apple semantic compilation stores its tuple-specific UBT database under
  -- .cache/nvim-ue/cdb/sources; arbitrary recursive fixtures are never eligible.
  local ok_existing, existing_path = export_compile_commands_to_engine_root(ctx)
  if ok_existing then
    local ok_pipeline, pipeline_err = start_pipeline(targets[1])
    if not ok_pipeline then return false, pipeline_err end
    return true, existing_path .. " (UBT)"
  end

  return false,
    "No engine compile_commands source found. Run :UECompileForNvim to build the active target and prepare its RSP-backed database, or place a compile_commands.json at the engine root."
end

-- ==========================================================================
-- BUILD COMMAND (UBT/Build.bat — platform from state.target_platform)
-- ==========================================================================

do
  local function target_runtime_state(ctx, platform)
    local runtime = ctx and ctx.state and ctx.state.target_runtime or {}
    return type(runtime) == "table" and type(runtime[platform]) == "table" and runtime[platform] or {}
  end

  function CORE_RT.target_context(ctx, platform_override, opts)
    opts = opts or {}
    local uproject = ctx.uproject or find_uproject_in_dir(ctx.project_root)
    if not uproject then
      return nil, "No .uproject found in project root: " .. tostring(ctx.project_root)
    end

    local platform = trim(platform_override or "")
    if platform == "" then
      platform = target_platform(ctx.engine_root, nil)
    end
    local driver = require("ue.targets").driver(platform)
    if not driver then
      return nil, "No Unreal target driver registered for platform: " .. platform
    end

    local configuration = target_configuration(
      ctx.engine_root, ctx.project_root, uproject, platform
    )
    local kind = target_kind(ctx.engine_root, ctx.project_root, uproject, platform)
    local target_name = build_target_name(ctx.project_root, uproject, kind)
    local project_dir = _ufs.dirname(uproject)
    local runtime = target_runtime_state(ctx, platform)
    local archive_dir = trim(opts.archive_dir or runtime.archive_dir or "")
    if archive_dir == "" then
      archive_dir = join(project_dir, "Saved", "Archives", platform, target_name .. "-" .. configuration)
    end

    return {
      engine_root = ctx.engine_root,
      project_root = ctx.project_root,
      project_dir = project_dir,
      project = uproject,
      uproject = uproject,
      target = target_name,
      platform = platform,
      target_platform = platform,
      configuration = configuration,
      cwd = ctx.engine_root,
      archive_dir = archive_dir,
      config_root = vim.fn.stdpath("config"),
      signing_identity = opts.signing_identity or (ctx.state and ctx.state.ios_signing_identity),
      device_id = opts.device_id or runtime.device_id,
      device_name = opts.device_name or runtime.device_name,
      device_backend = opts.device_backend or runtime.device_backend,
      device_transport = opts.device_transport or runtime.device_transport,
      bundle_id = opts.bundle_id or runtime.bundle_id,
      artifacts = opts.artifacts or runtime.artifacts,
      json_output = opts.json_output,
      skip_deploy = opts.skip_deploy == true,
      operation = opts.operation,
      legacy_launch_script = opts.legacy_launch_script,
      legacy_signing = opts.legacy_signing,
    }, nil, driver
  end

  function CORE_RT.target_plan(operation, ctx, platform_override, opts)
    local target_ctx, context_err, driver = CORE_RT.target_context(ctx, platform_override, opts)
    if not target_ctx then
      return nil, context_err
    end
    local host_driver = (opts and opts.host_driver) or require("utils.platform").driver()
    local platform = target_ctx.platform
    local resolved, unavailable = require("ue.targets").resolve(platform, operation, host_driver)
    if not resolved then
      return nil, ("%s %s unavailable on host %s: %s"):format(
        platform,
        operation,
        tostring(unavailable.host_id or "<unknown>"),
        tostring(unavailable.reason)
      )
    end
    driver = resolved
    local planner = driver[operation .. "_plan"]
    if type(planner) ~= "function" then
      return nil, ("Target %s does not implement %s"):format(driver.id, operation)
    end
    local plan = planner(target_ctx, host_driver)
    local command, plan_err = require("ue.target_tasks").command(plan)
    if not command then
      return nil, ("%s %s unavailable: %s"):format(driver.id, operation, plan_err)
    end
    return command, nil, plan, driver, target_ctx
  end

  function CORE_RT.update_target_runtime(engine_root, platform, values)
    local state = read_state(engine_root)
    local all = type(state.target_runtime) == "table" and vim.deepcopy(state.target_runtime) or {}
    local current = type(all[platform]) == "table" and vim.deepcopy(all[platform]) or {}
    for key, value in pairs(values or {}) do
      current[key] = value
    end
    current.updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    all[platform] = current
    local updated, update_err = update_state_field(engine_root, "target_runtime", all)
    if not updated then return nil, update_err end
    CORE_RT.context_cache = {}
    return current
  end

  function CORE_RT.target_context_matches(ctx, expected_engine_root, expected_project_root)
    if type(ctx) ~= "table" then return false end
    return norm(ctx.engine_root or "") == norm(expected_engine_root or "")
      and norm(ctx.project_root or "") == norm(expected_project_root or "")
  end
end

-- Build the platform+configuration persisted in state.json (set via
-- :UESetPlatform). The legacy public name remains, but executable selection is
-- host-owned (`Build.bat` on Windows, `Build.sh` on macOS/Linux) and target argv
-- comes exclusively from the selected target driver.
-- Kept as `android_build_command` for now to avoid breaking the public
-- M.android_build_command API surface; rename together when there are
-- no external callers left.
local function android_build_command(ctx, opts)
  opts = opts or {}
  local operation = opts.operation or (opts.skip_deploy == true and "so_build" or "build")
  opts.operation = operation
  local command, err = CORE_RT.target_plan(operation, ctx, nil, opts)
  return command, err
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
  -- Closing the terminal window is a presentation action, not task
  -- cancellation. `bufhidden=wipe` terminates a live terminal job (reported
  -- by Neovim as exit 143), so keep the buffer hidden while the build runs.
  -- The exit callback restores the old cleanup behavior once no process can
  -- be killed by wiping the buffer.
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].buflisted = false
  vim.bo[buf].swapfile = false

  if previous_buf and previous_buf ~= buf and vim.api.nvim_buf_is_valid(previous_buf) then
    pcall(vim.api.nvim_buf_delete, previous_buf, { force = true })
  end

  if opts.quickfix_title then
    set_build_status("B...")
  end

  local build_monitor
  local active_jobid
  active_jobid = vim.fn.termopen(cmd, {
    cwd = opts.cwd,
    env = opts.env,
    on_stdout = function(_, data)
      stdout_pending = append_job_output(output_lines, stdout_pending, data)
    end,
    on_stderr = function(_, data)
      stderr_pending = append_job_output(output_lines, stderr_pending, data)
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if build_monitor then
          build_monitor:stop()
          build_monitor = nil
        end
        if vim.api.nvim_buf_is_valid(buf) then
          vim.bo[buf].bufhidden = "wipe"
        end
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
        local msg = ("%s finished with exit code %d"):format(
          opts.finish_label or "UE build", code
        )
        vim.notify(msg, level)
        if code ~= 0 then require("utils.log").error("ue.build", msg) end
        if type(opts.on_exit) == "function" then
          opts.on_exit(code, vim.deepcopy(output_lines))
        end
      end)
    end,
  })
  if active_jobid <= 0 then
    CORE_RT.build_term_jobid = nil
    if opts.quickfix_title then
      set_build_status("BERR")
    end
    require("utils.log").notify_error("ue.build", "Failed to start UE build terminal")
    return nil
  end

  CORE_RT.build_term_jobid = active_jobid
  -- Register with the generic task registry (list/cancel via :Tasks). This is
  -- a pure side-path: only a register call AFTER job creation; on_exit above is
  -- untouched. Status is derived live from the channel (see task_registry).
  pcall(function()
    require("utils.task_registry").register({
      name = opts.quickfix_title or "build",
      group = "build",
      kind = "job",
      handle = active_jobid,
      started_at = os.time(),
    })
  end)
  pcall(function()
    build_monitor = require("ue.build_monitor").start({
      jobid = active_jobid,
      bufnr = buf,
    })
  end)
  startinsert_in_window(win)
  return active_jobid
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

-- ── Foreign-checkout buffer warning (one-shot per root) ───────────────────
-- Project selection is manual-only (:UESetProject, 2026-07-14): opening a
-- C++ file from a DIFFERENT checkout never switches the context. Correct,
-- but the symptom users actually see is "tons of diagnostics after
-- UEPrepare" — clangd finds no CDB entry for the foreign path and parses
-- with fallback flags (no UE defines/includes). Detect and say so, once
-- per foreign root per session.
CORE_RT.foreign_buffer_notified = CORE_RT.foreign_buffer_notified or {}

-- Pure classifier (unit-tested): is `path` outside BOTH the pinned
-- project_root and engine_root? Returns nil when inside; otherwise a stable
-- key for dedup (the first path segment two levels up, best effort).
function CORE_RT.foreign_buffer_key(path, project_root, engine_root)
  local p = tostring(path or ""):lower():gsub("\\", "/")
  if p == "" then return nil end
  local function inside(root)
    root = tostring(root or ""):lower():gsub("\\", "/"):gsub("/+$", "")
    if root == "" then return false end
    return p == root or p:sub(1, #root + 1) == root .. "/"
  end
  if inside(project_root) or inside(engine_root) then return nil end
  -- Dedup key: parent dir 3 levels up caps notification volume without a
  -- precise checkout-root heuristic.
  local dir = p
  for _ = 1, 3 do dir = dir:match("^(.*)/[^/]+$") or dir end
  return dir
end

function CORE_RT.notify_foreign_buffer(ctx, path)
  if not ctx then return end
  local key = CORE_RT.foreign_buffer_key(path, ctx.project_root, ctx.engine_root)
  if not key then return end
  if CORE_RT.foreign_buffer_notified[key] then return end
  CORE_RT.foreign_buffer_notified[key] = true
  -- Probe: how often users actually land in foreign checkouts decides
  -- whether this stays a warning or grows a quick-switch action.
  pcall(function()
    require("utils.probe").record("foreign-buffer", key,
      { pinned = tostring(ctx.project_root or "?") })
  end)
  vim.schedule(function()
    vim.notify(
      ("[ue] this buffer is OUTSIDE the pinned project:\n  file:    %s\n  project: %s\n" ..
       "clangd has no compile command for it (fallback flags → diagnostic noise).\n" ..
       "Run :UESetProject <its checkout> if you meant to work there.")
        :format(path, tostring(ctx.project_root or "?")),
      vim.log.levels.WARN, { title = "UE", timeout = 8000 })
  end)
end

-- Test seam.
function M._foreign_buffer_key_for_test(path, proot, eroot)
  return CORE_RT.foreign_buffer_key(path, proot, eroot)
end

function CORE_RT.grep_live_search_ready(pattern, min_chars, literal)
  min_chars = tonumber(min_chars) or 2
  local query = trim(tostring(pattern or ""))
  if query == "" then return false end
  if #query >= min_chars then return true end
  -- Single alphanumeric searches explode into thousands of results, but a
  -- single punctuation character is often the exact token being sought in
  -- source code. Permit it only in literal mode; regex "." must remain gated.
  return literal == true and query:find("[%w_]") == nil
end

function CORE_RT.grep_result_context(ctx, file)
  ctx = ctx or {}
  local path = norm(file)
  local compare_path = path:lower()

  local function classify(root, scope, token)
    root = norm(root)
    if root == "" then return nil end
    local compare_root = root:lower()
    if compare_path ~= compare_root
        and compare_path:sub(1, #compare_root + 1) ~= compare_root .. "/" then
      return nil
    end
    local relative = compare_path == compare_root and "." or path:sub(#root + 2)
    return { scope = scope, token = token, path = relative }
  end

  -- A project may live below the engine root, so the narrower project scope
  -- must win before the engine check.
  return classify(ctx.project_root, "Project", "P")
    or classify(ctx.engine_root, "Engine", "E")
    or classify(workspace_root(ctx), "Workspace", "W")
    or { scope = "External", token = "X", path = path }
end

function CORE_RT.grep_annotate_file_group(items, ctx)
  local count = #(items or {})
  local annotated = {}
  for index, item in ipairs(items or {}) do
    local copy = vim.tbl_extend("force", {}, item)
    local context = CORE_RT.grep_result_context(ctx, item.file)
    copy._grep_group = {
      index = index,
      count = count,
      scope = context.scope,
      token = context.token,
      path = context.path,
    }
    annotated[#annotated + 1] = copy
  end
  return annotated
end

function CORE_RT.grep_format_grouped(item)
  local group = item._grep_group or {
    index = 1,
    count = 1,
    scope = "Workspace",
    token = "W",
    path = norm(item.file),
  }
  local pos = item.pos or { 1, 0 }
  local line = tostring(item.line or ""):gsub("^%s+", "")
  local chunks = {}

  if group.index == 1 then
    chunks[#chunks + 1] = { "▼ ", "SnacksPickerDir" }
    chunks[#chunks + 1] = { group.scope, "SnacksPickerSpecial" }
    chunks[#chunks + 1] = { " " }
    chunks[#chunks + 1] = { group.path, "SnacksPickerFile" }
    chunks[#chunks + 1] = { (" (%d)  "):format(group.count), "SnacksPickerComment" }
  else
    chunks[#chunks + 1] = { "  ├ ", "SnacksPickerDir" }
  end

  chunks[#chunks + 1] = { tostring(pos[1] or 1), "SnacksPickerRow" }
  chunks[#chunks + 1] = { ":", "SnacksPickerDelim" }
  chunks[#chunks + 1] = { tostring((pos[2] or 0) + 1), "SnacksPickerCol" }
  chunks[#chunks + 1] = { " │ ", "SnacksPickerDelim" }
  chunks[#chunks + 1] = { line }
  return chunks
end

function CORE_RT.grep_hit_item(file, lnum, col, text, pattern, regex)
  local start_col = math.max(0, (tonumber(col) or 1) - 1)
  local item = {
    text = file .. ":" .. lnum .. ":" .. col .. ":" .. text,
    line = text,
    pos = { lnum, start_col },
    file = file,
  }
  if regex ~= true and tostring(pattern or "") ~= "" then
    item.end_pos = { lnum, start_col + #tostring(pattern) }
  end
  return item
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

  -- In-panel scope filter (change `refactor-search-system`): capture the
  -- current buffer's module/plugin scope at open time so <a-s> can restrict
  -- the search to it without leaving the picker. The scope's root path is
  -- escaped into an RE2 fragment passed to csearch's -f file-path filter.
  -- nil when the current file isn't inside any module/plugin (toggle no-ops).
  local grep_scope = current_scope_info_from_context(ctx)
  local function scope_path_regex(scope)
    if not scope or not scope.root then return nil end
    -- csearch indexes absolute paths with forward slashes (see UEPrepare
    -- filelist writer). Normalize + escape RE2 metachars in the root so the
    -- -f regex matches "<root>/..." literally.
    local root = norm(scope.root)
    local esc = root:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?%{%}%|%\\/])", "\\%1")
    return esc
  end

  local function grep_picker_title(scoped)
    local base = CORE_RT.grep_backend_title(opts.title or "Grep All Code", backend_label)
    if scoped and grep_scope then
      return base .. " [scope: " .. tostring(grep_scope.label or grep_scope.name or "current") .. "]"
    end
    return base .. " [scope: all]"
  end

  local title_default = CORE_RT.grep_backend_title("Grep All Code", backend_label)
  local live_min_chars = opts.live_min_chars or 2
  local live_max_count = opts.max_count or 5000
  local short_live_max_count = opts.short_live_max_count or 1200

  -- ─ Helpers shared by both csearch and rg paths ──────────────────────
  -- Dev toggle: lets us A/B compare against vanilla snacks behavior. The
  -- structured path/count formatter and preview throttle are disabled when
  -- false, while every picker item remains a real match in either mode.
  -- Toggle at runtime with :UEGrepGroupingToggle.
  local grouping_enabled = (vim.g.ue_grep_grouping_enabled ~= false)

  -- csearch emits hits grouped by file. Buffer only the current file so its
  -- count is known, then annotate and emit the original match rows. Unlike
  -- the old synthetic header design, this never creates a selectable item
  -- without a source location, so every cursor position has a code preview.
  local function make_file_grouping_cb(cb)
    local current_file = nil
    local current_items = {}

    local function flush()
      if #current_items == 0 then return end
      for _, item in ipairs(CORE_RT.grep_annotate_file_group(current_items, ctx)) do
        cb(item)
      end
      current_items = {}
    end

    local function push(item)
      if item == nil then return end
      if current_file ~= nil and item.file ~= current_file then
        flush()
      end
      current_file = item.file
      current_items[#current_items + 1] = item
    end

    return push, flush
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

  -- ─ Diagnostic trace (opt-in via vim.g.ue_grep_trace) ────────────────
  -- When enabled, write per-event lines to a stable log path so we can
  -- post-mortem WHY the picker felt laggy on a real human typing session.
  -- Zero overhead when disabled (single boolean check per event).
  --
  -- Toggle: :UEGrepTraceToggle  (or set vim.g.ue_grep_trace = true)
  -- Log:    vim.fn.stdpath("state") .. "/ue_grep_trace.log"
  local trace_enabled = vim.g.ue_grep_trace == true
  local trace_log_path = vim.fn.stdpath("state") .. ("/ue_grep_trace.%d.log"):format(vim.fn.getpid())
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

  -- Backend diagnostic — now OPT-IN (was always-on during the "<leader>/
  -- missing results" investigation; that's confirmed fixed). Gated on the same
  -- vim.g.ue_grep_trace flag so a normal grep writes nothing to disk (P5: no
  -- silent per-action side-effects). Enable with :UEGrepTraceToggle when
  -- debugging backend/mode/result-count.
  local debug_log_path = vim.fn.stdpath("state") .. ("/ue_grep_backend_debug.%d.log"):format(vim.fn.getpid())
  local function grep_debug(fmt, ...)
    if vim.g.ue_grep_trace ~= true then return end
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
      title = grep_picker_title(false),
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
      literal = true,
      word = false,
      case = false,
      scoped = false,
      toggles = {
        regex = { icon = "R", value = true },
        literal = { icon = "L", value = true },
        word  = { icon = "W", value = true },
        case  = { icon = "C", value = true },
        scoped = { icon = "S", value = true },
      },
      -- Keymaps: Alt-r/g/x/w/c = mode toggles, shown live as R/W/C icons in
      -- the picker title. <a-r> is the intuitive "regex" toggle (matches
      -- snacks' own default); <a-g> = "grep regex" mnemonic alias. Both flip
      -- the same regex flag. <a-w>/<a-x> = whole-word, <a-c> = case-sensitive.
      -- <a-s> = restrict to the current module/plugin scope (in-panel scope
      -- filter; shows an "S" icon when active).
      -- NOTE: <a-r> previously collided with NVIDIA App's global Performance
      -- Overlay hotkey; if it ever stops reaching nvim again, use <a-g>.
      win = vim.tbl_deep_extend("force", grouping_enabled and fast_tab_keys.win or {}, {
        input = { keys = {
          ["<a-r>"] = { "ue_grep_toggle_regex", mode = { "i", "n" } },
          ["<a-g>"] = { "ue_grep_toggle_regex", mode = { "i", "n" } },
          ["<a-x>"] = { "ue_grep_toggle_word",  mode = { "i", "n" } },
          ["<a-w>"] = { "ue_grep_toggle_word",  mode = { "i", "n" } },
          ["<a-c>"] = { "ue_grep_toggle_case",  mode = { "i", "n" } },
          ["<a-s>"] = { "ue_grep_toggle_scope", mode = { "i", "n" } },
        } },
      }),
      actions = {
        ue_grep_toggle_regex = function(picker)
          picker.opts.regex = not picker.opts.regex
          picker.opts.literal = not picker.opts.regex
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
        ue_grep_toggle_scope = function(picker)
          if not grep_scope then
            require("snacks").notify(
              "✗ no module/plugin scope (current file isn't inside one)",
              { title = "UE grep", level = "warn" })
            return
          end
          picker.opts.scoped = not picker.opts.scoped
          picker.title = grep_picker_title(picker.opts.scoped)
          picker:update_titles()
          require("snacks").notify(
            (picker.opts.scoped
              and ("✓ scope: " .. (grep_scope.label or grep_scope.name or "current"))
              or "✗ scope OFF (whole workspace)"),
            { title = "UE grep", level = "info" })
          picker.list:set_target(); picker:find()
        end,
      },
      format = grouping_enabled and CORE_RT.grep_format_grouped or nil,
      on_show = grouping_enabled and on_show_picker or nil,
      finder = function(_picker_opts, finder_ctx)
        local pattern = finder_ctx.filter.search
        local _picker = finder_ctx and finder_ctx.picker
        local _po = _picker and _picker.opts or {}
        if not CORE_RT.grep_live_search_ready(pattern, live_min_chars, _po.regex ~= true) then
          return function() end
        end
        trace("finder START pattern=%q", pattern)
        return function(cb)
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

          local function enqueue(item)
            pending_len = pending_len + 1
            pending[pending_len] = item
          end
          local queue_item = enqueue
          local flush_file_group = function() end
          if grouping_enabled then
            queue_item, flush_file_group = make_file_grouping_cb(enqueue)
          end

          local t_cs_spawn_0 = vim.loop.hrtime()
          local cs_first_line_logged = false
          -- Read mode toggles from picker.opts (Alt-r/Alt-x/Alt-c flip
          -- these in place via snacks auto-generated toggle_<name> actions,
          -- then picker:find() restarts this finder so we see the new values).
          local pattern_len = #trim(tostring(pattern or ""))
          local mode_case = _po.case == true
          local mode_ignore_case = not mode_case
          grep_debug("FINDER backend=csearch pattern=%q regex=%s word=%s case=%s ignore_case=%s max=%d",
            tostring(pattern), tostring(_po.regex == true), tostring(_po.word == true),
            tostring(mode_case), tostring(mode_ignore_case),
            pattern_len <= live_min_chars and short_live_max_count or live_max_count)
          local scope_re = (_po.scoped and grep_scope) and scope_path_regex(grep_scope) or nil
          local stop = code_search.stream(cs_ctx, pattern, {
            code_only   = opts.code_only,
            smart_case  = true,
            max_count   = pattern_len <= live_min_chars and short_live_max_count or live_max_count,
            regex       = _po.regex == true,   -- snacks default false = literal
            word        = _po.word == true,
            case        = mode_case,
            ignore_case = mode_ignore_case,
            path_filter = scope_re,            -- in-panel scope filter (<a-s>)
          }, {
            on_line = function(file, lnum, col, text)
              if not cs_first_line_logged then
                cs_first_line_logged = true
                trace("PHASE csearch_first_line=%.2fms after_spawn",
                  (vim.loop.hrtime() - t_cs_spawn_0) / 1e6)
              end
              -- Buffer only real match items. The literal path carries an
              -- exact end_pos so Snacks preview never reinterprets raw input
              -- such as "." as Vim regex syntax.
              queue_item(CORE_RT.grep_hit_item(
                file, lnum, col, text, pattern, _po.regex == true))
              items_received = items_received + 1
            end,
            on_done = function(code, err)
              -- csearch output is file-grouped. Close the final group before
              -- done=true so the normal budgeted drain sees every annotated
              -- real hit and never needs a synthetic header row.
              flush_file_group()
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
            flush_file_group()
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

  -- ── No csearch index: <leader>/ NEVER falls back to rg ─────────────
  -- Hard contract (change `refactor-search-system`): this entry is csearch-
  -- ONLY. We removed all three former rg back-doors (rg-batched fallback,
  -- return-nil -> snacks dir-walk, and the "ue_grep_rg" fast-path). When no
  -- csearch index is available we surface a visible error and open NO picker.
  -- rg lives on elsewhere: <leader>sG (ue_grep_all) is the explicit rg entry,
  -- and code_search.stream() keeps its rg branch for gd/gr fallback (P12).
  if not vim.b._ue_grep_no_index_warned then
    vim.b._ue_grep_no_index_warned = true
    vim.schedule(function()
      vim.notify(
        "UE grep: no csearch index — <leader>/ is csearch-only and will not " ..
        "fall back to rg. Run :UEPrepare to build the index. " ..
        "(For an explicit rg search use <leader>sG.)",
        vim.log.levels.ERROR, { title = "UE" })
    end)
  end
  return nil
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

  -- Generic background-task count segment (⏵N). Shown only when N>0; absent
  -- (no placeholder) when zero. Count is derived live from the task registry
  -- at this existing statusline eval — no new timer (config rule P5).
  local ok_tr, tr = pcall(require, "utils.task_registry")
  if ok_tr then
    local n = tr.running_count()
    if n and n > 0 then
      parts[#parts + 1] = ("⏵%d"):format(n)
    end
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
    "  coverage: " .. (trim(summary.coverage_level) ~= "" and summary.coverage_level or "-")
      .. " base=" .. (trim(summary.selected_phase) ~= "" and summary.selected_phase or "-")
      .. " freshness=" .. (trim(summary.freshness) ~= "" and summary.freshness or "-")
      .. " converging=" .. (summary.converging and "yes" or "no"),
    "  generation: " .. (trim(summary.generation_short) ~= "" and summary.generation_short or "-")
      .. ", selected modules=" .. tostring(summary.selected_module_count or 0),
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

-- Read-only semantic-navigation contract.  This deliberately exposes only
-- fingerprints, coverage, readiness and a module label: callers must never
-- learn cache/index absolute paths from diagnostic state.
function M.semantic_index_snapshot(opts)
  opts = opts or {}
  local ctx, err = resolve_context(opts)
  if not ctx then return nil, err end
  return INDEX_FN.semantic_index_snapshot(ctx, opts.subject_path or opts.bufname)
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

CORE_RT.clangd_deferred_notified = CORE_RT.clangd_deferred_notified or {}

local function clangd_artifact_key(ctx)
  if not ctx then return nil end
  local platform_scope = ctx.paths and ctx.paths.clangd_dir
    or target_platform(ctx.engine_root, nil)
  return table.concat({
    norm(ctx.engine_root or ""),
    norm(ctx.project_root or ""),
    norm(platform_scope or ""),
  }, "|")
end

function CORE_RT.clangd_gate_allows(path, project_root, engine_root, ready)
  path = trim(path)
  if path == "" then return true end
  local inside_ue_roots = CORE_RT.foreign_buffer_key(path, project_root, engine_root) == nil
  return not inside_ue_roots or ready == true
end

function CORE_RT.clangd_artifacts_ready(ctx, dependencies)
  local key = clangd_artifact_key(ctx)
  if not key then return false end

  dependencies = dependencies or {}
  local semantic_index_snapshot = dependencies.semantic_index_snapshot
    or INDEX_FN.semantic_index_snapshot
  local ok, snapshot = pcall(semantic_index_snapshot, ctx)
  local ready = ok and type(snapshot) == "table" and snapshot.readiness == "ready"
  if ready then CORE_RT.clangd_deferred_notified[key] = nil end
  return ready
end

function CORE_RT.wake_deferred_clangd_buffer(bufnr, dependencies)
  dependencies = dependencies or {}
  local buffer_ready = dependencies.buffer_ready or function(buffer)
    return vim.api.nvim_buf_is_valid(buffer) and vim.api.nvim_buf_is_loaded(buffer)
  end
  local get_clients = dependencies.get_clients or vim.lsp.get_clients
  local exec_autocmds = dependencies.exec_autocmds or vim.api.nvim_exec_autocmds
  local defer_fn = dependencies.defer_fn or vim.defer_fn
  local max_attempts = tonumber(dependencies.max_attempts) or 4
  local retry_delay_ms = tonumber(dependencies.retry_delay_ms) or 250

  local function clangd_attached()
    local ok, clients = pcall(get_clients, { bufnr = bufnr, name = "clangd" })
    return ok and type(clients) == "table" and #clients > 0
  end

  local function wake(attempt)
    if not buffer_ready(bufnr) or clangd_attached() then return end
    pcall(exec_autocmds, "FileType", {
      buffer = bufnr,
      modeline = false,
    })
    if attempt < max_attempts and not clangd_attached() then
      defer_fn(function() wake(attempt + 1) end, retry_delay_ms)
    end
  end

  wake(1)
end

function M._wake_deferred_clangd_for_test(bufnr, dependencies)
  return CORE_RT.wake_deferred_clangd_buffer(bufnr, dependencies)
end

function CORE_RT.start_deferred_clangd(ctx)
  if not CORE_RT.clangd_artifacts_ready(ctx) then return end
  if #vim.api.nvim_list_uis() == 0 then
    vim.api.nvim_create_autocmd("UIEnter", {
      once = true,
      callback = function() CORE_RT.start_deferred_clangd(ctx) end,
    })
    return
  end
  local allowed_filetypes = {
    c = true,
    cpp = true,
    objc = true,
    objcpp = true,
    cuda = true,
  }
  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_valid(bufnr)
          and vim.api.nvim_buf_is_loaded(bufnr)
          and allowed_filetypes[vim.bo[bufnr].filetype] then
        local path = vim.api.nvim_buf_get_name(bufnr)
        if CORE_RT.foreign_buffer_key(path, ctx.project_root, ctx.engine_root) == nil then
          CORE_RT.wake_deferred_clangd_buffer(bufnr)
        end
      end
    end
  end)
end

function M.clangd_start_root(bufnr)
  local root = M.clangd_root(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr or 0)
  local ctx = resolve_context({ bufname = path ~= "" and path or nil })
  if not ctx then return root end
  local key = clangd_artifact_key(ctx)
  local ready = CORE_RT.clangd_artifacts_ready(ctx)
  if CORE_RT.clangd_gate_allows(path, ctx.project_root, ctx.engine_root, ready) then
    return root
  end
  if key and not CORE_RT.clangd_deferred_notified[key] then
    CORE_RT.clangd_deferred_notified[key] = true
    vim.schedule(function()
      vim.notify(
        "clangd deferred because the current UE tuple has no valid prepared artifacts; "
          .. "run :UEPrepare once after the tuple or build evidence changes. "
          .. "Tree-sitter highlighting remains available.",
        vim.log.levels.INFO,
        { title = "UE", timeout = 5000, replace = "ue.clangd.deferred" }
      )
    end)
  end
  return nil
end

function M._clangd_artifacts_ready_for_test(ctx, dependencies)
  return CORE_RT.clangd_artifacts_ready(ctx, dependencies)
end

function M._clangd_gate_allows_for_test(path, project_root, engine_root, ready)
  return CORE_RT.clangd_gate_allows(path, project_root, engine_root, ready)
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
-- Public platform query API. Path priorities remain for API compatibility and
-- explicit platform-aware consumers; C++ gd never uses path ranking.
-- Wrapped in do-end to avoid main-chunk local budget pressure.
-- ---------------------------------------------------------------------------

do
  local path_hints = require("ue.targets.path_hints")

  function M.current_platform()
    local ok, ctx = pcall(resolve_context)
    local engine = (ok and type(ctx) == "table") and ctx.engine_root or nil
    return target_platform(engine, nil)
  end

  function M.platform_path_priorities(platform)
    platform = platform or M.current_platform() or ""
    return path_hints.for_target(platform)
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
  return android_build_command(ctx, opts)
end

function M._android_build_command_for_test(ctx, opts)
  return android_build_command(ctx, opts)
end

function M._target_plan_for_test(operation, ctx, platform, opts)
  return CORE_RT.target_plan(operation, ctx, platform, opts)
end

function M._target_platform_for_test(engine_root)
  return target_platform(engine_root, nil)
end

function M._update_target_runtime_for_test(engine_root, platform, values)
  return CORE_RT.update_target_runtime(engine_root, platform, values)
end

function M._available_platform_choices_for_test(host_driver, project_root, uproject)
  return available_platform_choices(project_root, uproject, host_driver)
end

function M._clangd_version_compatible_for_test(output)
  return CORE_RT.clangd_version_compatible(output)
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
    "Compile Commands Scope: " .. (ctx.paths.project_key or "legacy-engine"),
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

-- Reset only process-local consumers when the active project changes.
-- (Wrapped in do/end so neither this helper NOR set_project occupies a
-- LuaJIT main-chunk local slot — see skill luajit-200-local-cap-with-loader-cache-mask.
-- We expose set_project through CORE_RT instead.)
do
local function invalidate_project_scoped_cache(_, reason)
  -- Force prepare_freshness to re-read from disk on next call.
  CORE_RT.freshness_notified = {}
  CORE_RT.context_cache = {}

  -- Re-probe the csearch toolchain next time (a stale negative probe from a
  -- cold start would otherwise keep is_indexed() false for the session).
  pcall(function() require("utils.code_search")._reset_probe_cache() end)

  -- Stop the old process-local watcher. Persistent dirty state is already in
  -- the old project's bucket and must be preserved for that project.
  local ok_watch, watch = pcall(require, "utils.ue_watch")
  if ok_watch and type(watch.stop) == "function" then
    pcall(watch.stop)  -- old watch handle was rooted at previous project_root
  end

  return 0
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

  -- The previous selection is process-local; selection.json is only the
  -- startup default and may have been changed by another Neovim process.
  local prev = CORE_RT.project_state.current(engine_root) or {}
  local prev_project = prev and prev.project_root or nil
  local project_switched = prev_project and norm(prev_project) ~= norm(project_root) or false
  local switched = project_switched

  local persisted_bp = package.loaded["ue.dap._persist_bp"]
  if switched and persisted_bp and type(persisted_bp.save) == "function" then
    pcall(persisted_bp.save)
  end
  local persisted, persist_err = persist_project(engine_root, project_root, uproject)
  if not persisted then
    vim.notify("Failed to set UE project: " .. tostring(persist_err), vim.log.levels.ERROR)
    return
  end

  if switched then
    invalidate_project_scoped_cache(engine_root, "project-switch")
  end

  invalidate_status_cache()
  refresh_statusline()

  local msg = "UE project set for this Neovim session:\nEngine: " .. engine_root .. "\nProject: " .. project_root
  if switched then
    msg = msg .. ("\n\nProject CHANGED (was: %s)\n  → previous project caches preserved\n  → active cache bucket: %s"):format(
      prev_project or "?", cache_paths(engine_root).cache)
    vim.notify(msg, vim.log.levels.INFO, { title = "UE" })
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
-- to :UESetProject. Stored in the selected project's state bucket so it never
-- appears in source code or leaks to another project under the same engine.
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
-- configuration), select it from process-local state and re-merge into the
-- process's project+platform CDB
-- WITHOUT re-running :UEPrepare. Returns ok, new_active_key, stats|err.
--
-- Preconditions:
--   * state.target_platform / state.target_configuration ALREADY persisted
--     (set_platform calls update_state_field before invoking this).
--   * <cache>/cdb/compile_commands/shards/<plat>-<target>-<config>.json exists.
--
-- Side effects on success:
--   * manifest.active set in-memory only; active selection is process-local.
--   * The isolated ctx.paths.active_cdb is rewritten from all shards, with
--     the selected key winning conflicts.
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
  -- a synthetic ctx built from project state when called without a buffer in
  -- the project (rare, but happens for headless tests / engine-root cwd).
  local ctx = resolve_context({ detect_project = true })
  if not ctx or norm(ctx.engine_root or "") ~= norm(engine_root) then
    local state = read_state(engine_root)
    if not state.project_root or state.project_root == "" then
      return false, nil, "no project selected in this Neovim — open a project file or run :UESetProject"
    end
    ctx = {
      engine_root = engine_root,
      project_root = state.project_root,
      uproject = state.uproject or find_uproject_in_dir(state.project_root) or "",
      state = state,
      paths = cache_paths(engine_root, CORE_RT.platform_key_from_state(state)),
    }
  end
  -- ctx.state was loaded BEFORE set_platform's update_state_field calls
  -- (because resolve_context caches). Re-read so target_platform / config
  -- reflect what the user just selected — otherwise active_key() picks the
  -- stale platform's shard.
  ctx.state = read_state(engine_root)

  local pipeline = require("ue.cdb.pipeline")
  if pipeline.is_running() then
    return false, nil, "compile_commands pipeline is already running"
  end

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

  local swap_lease, swap_lease_err = CORE_RT.file_lock.acquire(
    join(ctx.paths.runtime_dir, "prepare.lock"))
  if not swap_lease then
    return false, nil, "project CDB is being written by another Neovim: " .. tostring(swap_lease_err)
  end

  -- Select in-memory only. Persisting one global `manifest.active` would let
  -- two live Neovim processes redirect each other across platforms.
  manifest.active = new_key

  local merged, stats = shards.merge_shards(ctx, manifest)
  local json = vim.json.encode(merged)

  local targets = compile_commands_targets(ctx)
  for _, target in ipairs(targets) do
    write_all(target, json)
  end

  -- Run the standard post-process chain (slim + PCH FI inject + resolve +
  -- unify + prune) so clangd sees the same cdb shape as after :UEPrepare.
  local pipeline_jobid, pipeline_err = run_compile_commands_pipeline(targets[1], targets, function()
    CORE_RT.file_lock.release(swap_lease)
  end)
  if pipeline_jobid == nil then
    CORE_RT.file_lock.release(swap_lease)
    return false, nil, pipeline_err or "compile_commands pipeline failed to start"
  end

  -- Tell clangd to reload. LspRestart is async — clangd reads the new cdb on
  -- attach, so any open buffer will pick up the swap within ~1s.
  pcall(vim.cmd, "LspRestart clangd")

  return true, new_key, stats
end

local function set_platform(input, opts)
  opts = opts or {}
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
      local _, unavailable = require("ue.targets").resolve(plat, "build", _uplat.driver())
      if unavailable then
        vim.notify(
          ("Target %s cannot build on host %s: %s"):format(
            plat,
            tostring(_uplat.driver().id),
            tostring(unavailable.reason)
          ),
          vim.log.levels.WARN
        )
        return
      end
    end
    local target_update = opts.stage_next == false
        and CORE_RT.project_state.update_target
      or CORE_RT.project_state.stage_target
    local ok_update, update_err = target_update(
      engine_root,
      (plat and plat ~= "") and plat or current_plat,
      (conf and conf ~= "") and conf or current_conf)
    if not ok_update then
      vim.notify("Failed to set target: " .. tostring(update_err), vim.log.levels.ERROR)
      return
    end
    invalidate_status_cache()
    refresh_statusline()
    CORE_RT.context_cache = {}
    CORE_RT.freshness_notified = {}
    if trim(project_root or "") == "" then
      vim.notify(("UE target staged for the next project: %s %s"):format(
        plat or default_plat or "(auto)", conf or default_conf),
        vim.log.levels.INFO, { title = "UE" })
      return true
    end
    -- Switching platform repoints gtags/cdb at their <new-key>/ shards, but
    -- the csearch index is PLATFORM-INDEPENDENT (v3.2) — the same shared
    -- csearch/csearch.idx serves every platform, so switching platform does
    -- NOT invalidate or rebuild it. (migrate_legacy_csearch_if_needed still
    -- migrates gtags lists/DB into the new platform dir.)
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
    return true
  end

  -- Interactive: select platform then configuration.
  -- Suggestion (not authority): float the engine-level last-used pair to the
  -- top of the picker so a fresh bucket is one <CR> away from the platform
  -- the user habitually builds on this engine. Selection is still explicit —
  -- nothing is inherited without a keypress.
  local suggestion = CORE_RT.project_state.engine_target_default
    and CORE_RT.project_state.engine_target_default(engine_root) or nil
  local platform_choices = available_platform_choices(project_root, uproject)
  if suggestion and suggestion.target_platform then
    for i, p in ipairs(platform_choices) do
      if p == suggestion.target_platform and i > 1 then
        table.remove(platform_choices, i)
        table.insert(platform_choices, 1, p)
        break
      end
    end
  end
  vim.ui.select(platform_choices, {
    prompt = "Target Platform (current: " .. (current_plat ~= "" and current_plat or "auto") .. "):",
    format_item = function(item)
      if suggestion and item == suggestion.target_platform then
        return item .. "  (last used on this engine)"
      end
      return item
    end,
  }, function(plat)
    if not plat then
      if opts.on_done then opts.on_done(false) end
      return
    end

    local current_for_platform = current_conf ~= "" and current_conf
      or selected_target_configuration(engine_root, project_root, uproject, plat)
    local config_choices = available_configuration_choices(project_root, uproject, plat)
    if suggestion and plat == suggestion.target_platform and suggestion.target_configuration then
      for i, c in ipairs(config_choices) do
        if c == suggestion.target_configuration and i > 1 then
          table.remove(config_choices, i)
          table.insert(config_choices, 1, c)
          break
        end
      end
    end
    vim.ui.select(config_choices, {
      prompt = "Target Configuration (current: " .. current_for_platform .. "):",
      format_item = function(item)
        if suggestion and plat == suggestion.target_platform
            and item == suggestion.target_configuration then
          return item .. "  (last used on this engine)"
        end
        return item
      end,
    }, function(conf)
      if not conf then
        if opts.on_done then opts.on_done(false) end
        return
      end
      local target_update = opts.stage_next == false
          and CORE_RT.project_state.update_target
        or CORE_RT.project_state.stage_target
      local ok_update, update_err = target_update(engine_root, plat, conf)
      if not ok_update then
        vim.notify("Failed to set target: " .. tostring(update_err), vim.log.levels.ERROR)
        if opts.on_done then opts.on_done(false) end
        return
      end
      invalidate_status_cache()
      refresh_statusline()
      CORE_RT.context_cache = {}
      if trim(project_root or "") == "" then
        vim.notify(("UE target staged for the next project: %s %s"):format(plat, conf),
          vim.log.levels.INFO, { title = "UE" })
        if opts.on_done then opts.on_done(true) end
        return
      end
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
      if opts.on_done then opts.on_done(true) end
    end)
  end)
end

-- export_compile_commands is now an alias for prepare_async (unified flow)
local export_compile_commands

-- stop_android_debugger lives in ue/dap.lua and is now accessed via
-- `require("ue.dap").stop_android_debugger(...)` directly. The previous
-- forward-declaration pattern relied on dap.lua doing a bare global write
-- to fill this local, which silently broke after the tiered split (different
-- main chunks don't share locals). See build_target() below.

local function build_target(opts)
  opts = opts or {}
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

  -- Fresh-bucket gate: never build on a silently-guessed platform. A project
  -- bucket that has NEVER had an explicit target set (fresh checkout after
  -- :UESetProject) previously fell through target_platform()'s default and
  -- built whatever that guessed (2026-08-18: Linux → UBT exit 6). Prompt the
  -- picker once — the engine-level last-used pair is floated to the top so
  -- it's a single <CR> — then resume this exact build. An explicit
  -- opts.platform (caller already chose) bypasses the gate.
  if not opts._platform_prompted
      and trim(opts.platform or "") == ""
      and vim.g.ue_prepare_headless ~= 1
      and CORE_RT.project_state.target_is_set
      and not CORE_RT.project_state.target_is_set(ctx.engine_root) then
    vim.notify("This project has no target platform set yet — choose one to build.",
      vim.log.levels.WARN, { title = "UE" })
    set_platform(nil, {
      on_done = function(ok)
        if ok then
          build_target(vim.tbl_extend("force", opts, { _platform_prompted = true }))
        end
      end,
    })
    return
  end

  local plat = trim(opts.platform or "")
  if plat == "" then plat = target_platform(ctx.engine_root, nil) end
  local conf = selected_target_configuration(ctx.engine_root, ctx.project_root, ctx.uproject, plat)
  local operation = opts.operation or (opts.skip_deploy == true and "so_build" or "build")
  opts.operation = operation
  local so_only = operation == "so_build"
  local title_prefix = opts.title or (so_only and "UEBuildAndroidSO" or "UEBuild")
  local title = (title_prefix .. " %s %s"):format(plat, conf)

  -- Build ⇄ prepare mutual exclusion (WAW): the cdb pipeline / UEPrepare
  -- READ build products (Module.*.rsp, receipts) that this build is about to
  -- REWRITE — a pipeline running across a build produces a CDB derived from
  -- half-old half-new inputs. The build wins: cancel the in-flight pipeline
  -- (its writer slot + cross-process lease are released through its normal
  -- on_fail path) and rerun :UEPrepare after the build succeeds.
  if require("ue.cdb.pipeline").cancel(title .. " started (build products are being rewritten)") then
    vim.notify("Re-run :UEPrepare after the build to refresh the CDB.",
      vim.log.levels.INFO, { title = "UE" })
  end

  local host_driver = opts.host_driver or require("utils.platform").driver()
  opts.host_driver = host_driver
  local cmd, build_err, plan, driver, target_ctx = CORE_RT.target_plan(operation, ctx, plat, opts)
  if not cmd then
    set_build_status("BERR")
    require("utils.log").notify_error("ue.build", title .. " failed: " .. build_err)
    return
  end

  local _, workflow_err = dispatch_registered_workflow(driver.id, operation, {
    host_driver = host_driver,
    payload = {
      context = ctx,
      configuration = target_ctx.configuration,
    },
    deps = {
      stop_debugger = function(cleanup_opts)
        return require("ue.dap").stop_android_debugger(cleanup_opts)
      end,
    },
  })
  if workflow_err then
    set_build_status("BERR")
    require("utils.log").notify_error("ue.build", title .. " failed: " .. tostring(workflow_err.reason or workflow_err))
    return
  end
  local function start_build()
    local function on_exit(code, output)
      if code == 0
          and require("ue.targets").supports(target_ctx.platform, "semantic_cdb", host_driver) then
        local recorded, record_err = update_state_field(ctx.engine_root, "apple_semantic_build", {
          project_root = ctx.project_root,
          uproject = ctx.uproject,
          target = target_ctx.target,
          platform = target_ctx.platform,
          configuration = target_ctx.configuration,
          completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        })
        if not recorded then
          require("utils.log").notify_error(
            "ue.build", "failed to record Apple build evidence: " .. tostring(record_err))
        end
      end
      if type(opts.on_exit) == "function" then opts.on_exit(code, output) end
    end
    return open_terminal_command(cmd, {
      cwd = plan.cwd or ctx.engine_root,
      quickfix_title = title,
      quickfix_root = workspace_root(ctx),
      tail_limit = 16,
      on_exit = on_exit,
    })
  end

  if type(driver.preflight_plans) == "function" and type(CORE_RT.run_target_preflight) == "function" then
    CORE_RT.run_target_preflight(driver, "build", target_ctx, host_driver, function(ok, preflight_err)
      if not ok then
        set_build_status("BERR")
        require("utils.log").notify_error("ue.build", title .. " failed: " .. tostring(preflight_err))
        return
      end
      start_build()
    end)
    return
  end

  return start_build()
end

function CORE_RT.clangd_version_compatible(output)
  local major, minor = tostring(output or ""):match("[Vv]ersion%s+(%d+)%.(%d+)")
  major, minor = tonumber(major), tonumber(minor)
  return major == 22 and minor == 1, major, minor
end

function CORE_RT.run_clangd_preflight(on_done)
  on_done = on_done or function() end
  local clangd_cmd = M.clangd_cmd()
  local executable = type(clangd_cmd) == "table" and clangd_cmd[1] or nil
  if not executable or executable == "" then
    on_done(false, "clangd executable is unavailable")
    return nil
  end

  local handle, run_err = require("ue.target_tasks").run({
    executable = executable,
    args = { "--version" },
    metadata = { operation = "clangd-version-preflight" },
  }, {
    name = "UEPrepare clangd preflight",
    on_exit = function(result)
      if result.code ~= 0 then
        on_done(false, require("ue.target_tasks").error_message(result))
        return
      end
      local version_output = result.stdout ~= "" and result.stdout or result.stderr
      local compatible, major, minor = CORE_RT.clangd_version_compatible(version_output)
      if not compatible then
        on_done(false, (
          "clangd %s.%s is incompatible; this repository requires LLVM clangd 22.1.x. "
            .. "Tree-sitter syntax highlighting remains available, but compiler semantics were not prepared."
        ):format(tostring(major or "?"), tostring(minor or "?")))
        return
      end
      on_done(true)
    end,
  })
  if not handle then on_done(false, run_err or "failed to start clangd preflight") end
  return handle
end

-- Apple toolchains do not reliably retain per-action response files after a
-- successful build. :UEPrepare asks the active target driver for a semantic
-- action-graph plan, publishes its tuple-scoped CDB only after validation,
-- then lets the ordinary preparation pipeline consume it.
function CORE_RT.apple_semantic_source_signature(path, fs_stat)
  local stat = (fs_stat or vim.uv.fs_stat)(path)
  if type(stat) ~= "table" or stat.type ~= "file" then return nil end
  local mtime = type(stat.mtime) == "table" and stat.mtime or {}
  return {
    path = norm(path),
    size = tonumber(stat.size) or 0,
    mtime_sec = tonumber(mtime.sec) or 0,
    mtime_nsec = tonumber(mtime.nsec) or 0,
  }
end

function CORE_RT.apple_semantic_source_marker(ctx, target_ctx, build_evidence, path, entry_count, fs_stat)
  local source = CORE_RT.apple_semantic_source_signature(path, fs_stat)
  if not source or trim(build_evidence and build_evidence.completed_at or "") == "" then return nil end
  return {
    project_root = ctx.project_root,
    uproject = ctx.uproject,
    target = target_ctx.target,
    platform = target_ctx.platform,
    configuration = target_ctx.configuration,
    build_completed_at = build_evidence.completed_at,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    entry_count = tonumber(entry_count) or 0,
    source = source,
  }
end

function CORE_RT.apple_semantic_source_reusable(ctx, target_ctx, path, build_evidence, dependencies)
  dependencies = dependencies or {}
  local state = (dependencies.read_state or read_state)(ctx.engine_root)
  local marker = type(state) == "table" and state.apple_semantic_cdb or nil
  local source = type(marker) == "table" and marker.source or nil
  local current = CORE_RT.apple_semantic_source_signature(path, dependencies.fs_stat)
  if type(source) ~= "table" or not current then return false end
  local reusable = norm(marker.project_root or "") == norm(ctx.project_root or "")
    and norm(marker.uproject or "") == norm(ctx.uproject or "")
    and marker.target == target_ctx.target
    and marker.platform == target_ctx.platform
    and marker.configuration == target_ctx.configuration
    and marker.build_completed_at == (build_evidence and build_evidence.completed_at)
    and norm(source.path or "") == current.path
    and tonumber(source.size) == current.size
    and tonumber(source.mtime_sec) == current.mtime_sec
    and tonumber(source.mtime_nsec) == current.mtime_nsec
  if not reusable then return false end
  return true, {
    path = current.path,
    entry_count = tonumber(marker.entry_count) or 0,
    no_op = true,
    reused = true,
  }
end

function M._apple_semantic_source_reusable_for_test(ctx, target_ctx, path, build_evidence, dependencies)
  return CORE_RT.apple_semantic_source_reusable(ctx, target_ctx, path, build_evidence, dependencies)
end

local ensure_ios_workflows
local ios_workflow_dependencies

function CORE_RT.generate_semantic_cdb_after_build(on_done, expected)
  on_done = on_done or function() end
  local ctx, context_err = resolve_context()
  if not ctx then
    on_done(false, context_err)
    return nil
  end
  if expected and not CORE_RT.target_context_matches(
      ctx, expected.engine_root, expected.project_root) then
    on_done(false, "project changed before Apple semantic CDB generation")
    return nil
  end

  local target_ctx, target_err = CORE_RT.target_context(ctx)
  if not target_ctx then
    on_done(false, target_err)
    return nil
  end

  local host_driver = require("utils.platform").driver()
  local targets = require("ue.targets")
  if not targets.supports(target_ctx.platform, "semantic_cdb", host_driver) then
    on_done(true, { skipped = true, reason = "target uses response-file evidence" })
    return true
  end

  local cdb_paths = require("ue.cdb.paths")
  local stable_path = cdb_paths.semantic_source(ctx, target_ctx)
  local build_evidence = read_state(ctx.engine_root).apple_semantic_build
  local reusable, reuse_info = CORE_RT.apple_semantic_source_reusable(
    ctx, target_ctx, stable_path, build_evidence
  )
  if reusable then
    vim.notify(
      ("Reusing validated %s semantic CDB for the current build (%d entries)."):format(
        target_ctx.platform, reuse_info.entry_count
      ),
      vim.log.levels.INFO,
      { title = "UEPrepare" }
    )
    on_done(true, reuse_info)
    return true
  end
  local output_dir = _ufs.dirname(stable_path)
  _ufs.ensure_dir(output_dir)
  local pending_name = ("compile_commands.pending-%d-%s.json"):format(
    vim.fn.getpid(), tostring(vim.uv.hrtime())
  )
  local pending_path = join(output_dir, pending_name)
  local semantic_ctx = vim.deepcopy(target_ctx)
  semantic_ctx.semantic_cdb_output_dir = output_dir
  semantic_ctx.semantic_cdb_output_filename = pending_name

  local plan = targets.plan(target_ctx.platform, "semantic_cdb", semantic_ctx, host_driver)
  local command, plan_err = require("ue.target_tasks").command(plan)
  if not command then
    on_done(false, plan_err)
    return nil
  end

  vim.notify(
    ("Generating %s semantic CDB (no cook/package/compile actions)..."):format(target_ctx.platform),
    vim.log.levels.INFO,
    { title = "UEPrepare" }
  )
  local jobid = open_terminal_command(command, {
    cwd = plan.cwd or ctx.engine_root,
    env = plan.env,
    quickfix_title = ("UEPrepare semantic CDB %s %s"):format(
      target_ctx.platform, target_ctx.configuration
    ),
    quickfix_root = workspace_root(ctx),
    tail_limit = 32,
    finish_label = "UE semantic CDB",
    on_exit = function(code)
      if code ~= 0 then
        pcall(os.remove, pending_path)
        local message = ("semantic CDB generation failed with exit code %d"):format(code)
        on_done(false, message)
        return
      end
      if expected and not CORE_RT.target_context_matches(
          resolve_context(), expected.engine_root, expected.project_root) then
        pcall(os.remove, pending_path)
        on_done(false, "project changed during Apple semantic CDB generation")
        return
      end

      local ok_publish, info = require("ue.cdb.source").promote(
        pending_path, stable_path, ctx, target_ctx, targets.must_get(target_ctx.platform)
      )
      if not ok_publish then
        pcall(os.remove, pending_path)
        on_done(false, info.reason)
        return
      end

      local marker = CORE_RT.apple_semantic_source_marker(
        ctx, target_ctx, build_evidence, stable_path, info.entry_count
      )
      local marker_ok, marker_err
      if marker then
        marker_ok, marker_err = update_state_field(ctx.engine_root, "apple_semantic_cdb", marker)
      else
        marker_err = "semantic CDB source signature is unavailable"
      end
      if not marker_ok then
        require("utils.log").notify_error(
          "ue.prepare", "failed to record reusable Apple semantic CDB evidence: " .. tostring(marker_err)
        )
      end

      vim.notify(
        ("Semantic CDB ready: %d entries%s"):format(
          info.entry_count, info.no_op and " (unchanged)" or ""
        ),
        vim.log.levels.INFO,
        { title = "UEPrepare" }
      )
      on_done(true, info)
    end,
  })
  if not jobid then
    pcall(os.remove, pending_path)
    on_done(false, "failed to start semantic CDB task")
  end
  return jobid
end

function CORE_RT.ios_setup_is_ready(ctx, dependencies)
  ensure_ios_workflows()
  local owned_dependencies = vim.tbl_extend("force", {
    read_state = read_state,
    resolve_legacy_install_script = function(...)
      return CORE_RT.invoke_workflow_api("IOS", "install", "resolve_legacy_install_script", { ... })
    end,
  }, dependencies or {})
  return CORE_RT.invoke_workflow_api("IOS", "semantic_cdb", "ios_setup_is_ready", { ctx, owned_dependencies })
end

function M._ios_setup_is_ready_for_test(ctx, dependencies)
  return CORE_RT.ios_setup_is_ready(ctx, dependencies)
end

function CORE_RT.apple_build_evidence_matches(ctx, target_ctx, dependencies)
  ensure_ios_workflows()
  local owned_dependencies = vim.tbl_extend("force", {
    read_state = read_state,
    update_state_field = update_state_field,
  }, dependencies or {})
  return CORE_RT.invoke_workflow_api(
    "IOS", "semantic_cdb", "apple_build_evidence_matches", { ctx, target_ctx, owned_dependencies }
  )
end

function M._apple_build_evidence_matches_for_test(ctx, target_ctx, dependencies)
  return CORE_RT.apple_build_evidence_matches(ctx, target_ctx, dependencies)
end

-- Apple-only prelude owned by :UEPrepare. It validates the pinned clangd,
-- performs one-time IOS setup when necessary, and publishes a tuple-scoped
-- semantic CDB. It deliberately never calls build_target: <leader>ub remains
-- the compile step, and UEPrepare continues to reject a build in progress.
function CORE_RT.prepare_apple_semantics(ctx, opts, on_done)
  ensure_ios_workflows()
  return CORE_RT.invoke_workflow_api(
    "IOS", "semantic_cdb", "prepare", { ctx, opts, on_done, ios_workflow_dependencies() }
  )
end

-- Compatibility convenience: compile once, then delegate all semantic/CDB
-- ownership to the same :UEPrepare path users invoke directly.
function CORE_RT.compile_for_nvim()
  return CORE_RT.run_clangd_preflight(function(ok, preflight_err)
    if not ok then
      require("utils.log").notify_error("ue.semantic", tostring(preflight_err))
      return
    end
    build_target({
      title = "UECompileForNvim",
      on_exit = function(code)
        if code ~= 0 then
          return
        end
        if type(CORE_RT.prepare_async) ~= "function" then
          require("utils.log").notify_error("ue.semantic", "UEPrepare entry is unavailable")
          return
        end
        CORE_RT.prepare_async({ _clangd_verified = true })
      end,
    })
  end)
end

local function find_apk(ctx)
  return require("ue.workflows").invoke(
    "Android", "install", "find_apk", { ctx }, require("utils.platform").driver()
  )
end

local function android_so_deploy_command(ctx, serial, package_name, host_driver)
  local selected_host = host_driver or require("utils.platform").driver()
  return require("ue.workflows").invoke(
    "Android", "so_deploy", "command", {
      ctx, serial, package_name, selected_host, {
        target_context = function(resolved, platform)
          return CORE_RT.target_context(resolved, platform)
        end,
      },
    }, selected_host
  )
end

function M.ai_context(engine_root)
  engine_root = norm(trim(engine_root or ""))
  if engine_root == "" then
    return nil, "Engine root not provided"
  end
  if not is_engine_root(engine_root) then
    return nil, "Not an Unreal Engine root: " .. engine_root
  end

  local state = read_state(engine_root)
  if not state.project_root or state.project_root == "" then
    return nil, "No project_root in " .. cache_paths(engine_root).state
  end

  local project_root = norm(state.project_root)
  local uproject = norm(state.uproject or "")
  if uproject == "" or not _ufs.is_file(uproject) then
    local resolved_root, resolved_uproject, project_err = resolve_project_input(project_root, engine_root)
    if not resolved_root then
      return nil, project_err
    end
    project_root = resolved_root
    uproject = resolved_uproject
  end

  local platform_key = CORE_RT.platform_key_from_state(state)
  local ctx = {
    engine_root = engine_root,
    project_root = project_root,
    uproject = uproject,
    state = state,
    paths = cache_paths(engine_root, platform_key),
  }
  local platform = target_platform(engine_root, nil)
  local selected_configuration = selected_target_configuration(engine_root, project_root, uproject, platform)
  local ubt_configuration = target_configuration(engine_root, project_root, uproject, platform)
  local kind = target_kind(engine_root, project_root, uproject, platform)
  local target_name = build_target_name(project_root, uproject, kind)
  local target_artifacts = require("ue.ai_context").resolve_target_artifacts(ctx, platform, state, {
    android_build_command = android_build_command,
    android_device = require("utils.android_device"),
    android_so_deploy_command = android_so_deploy_command,
    find_apk = find_apk,
    host_driver = _uplat.driver(),
    targets = require("ue.targets"),
    target_tasks = require("ue.target_tasks"),
  })

  return {
    schema_version = 1,
    generated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    engine_root = engine_root,
    project_root = project_root,
    uproject = uproject,
    state_path = ctx.paths.state,
    android_device_serial = target_artifacts.android_device_serial,
    state = {
      target_platform = state.target_platform,
      target_configuration = state.target_configuration,
      android_package = state.android_package,
      updated_at = state.updated_at,
    },
    target = {
      platform = platform,
      selected_configuration = selected_configuration,
      ubt_configuration = ubt_configuration,
      kind = kind,
      name = target_name,
      platform_source = trim(vim.env.UE_TARGET_PLATFORM) ~= "" and "environment" or "state/default",
      configuration_source = trim(vim.env.UE_TARGET_CONFIGURATION) ~= "" and "environment" or "state/default",
      target_source = trim(vim.env.UE_BUILD_TARGET) ~= "" and "environment" or "Target.cs/uproject",
    },
    artifacts = {
      build_command = target_artifacts.build_command,
      build_error = target_artifacts.build_error,
      so_build_command = target_artifacts.so_build_command,
      so_build_error = target_artifacts.so_build_error,
      so_deploy_command = target_artifacts.so_deploy_command,
      so_deploy_error = target_artifacts.so_deploy_error,
      latest_apk = target_artifacts.latest_apk,
      install_command = target_artifacts.install_command,
      compile_commands = ctx.paths.active_cdb,
      clangd_index = ctx.paths.active_index,
    },
    commands = {
      {
        key = "<Space>ub",
        nvim_command = ":UEBuild",
        purpose = "Build the active UE target using the persisted platform and configuration.",
        native_command = target_artifacts.build_command,
        native_action = target_artifacts.build_error,
      },
      {
        key = "<Space>us",
        nvim_command = ":UEBuildAndroidSO",
        purpose = "Compile and link the Android target without UBT's APK deployment phase.",
        native_command = target_artifacts.so_build_command,
        native_action = target_artifacts.so_build_error,
      },
      {
        key = "<Space>uq",
        nvim_command = ":UEDeployAndroidSO",
        purpose = "Strip and stage libUE4.so through root or a debuggable app-private ClassLoader startup agent, leaving the package stopped.",
        native_command = target_artifacts.so_deploy_command,
        native_action = target_artifacts.so_deploy_error,
      },
      {
        key = "<Space>ui",
        nvim_command = ":UEInstall",
        purpose = "Install for the active platform: replace the Android APK or update the signed IOS app in place.",
        native_command = target_artifacts.install_command,
        native_action = target_artifacts.install_native_action,
      },
      {
        key = "<Space>ul",
        nvim_command = ":UELaunch",
        purpose = "Launch the active project on the selected platform without attaching a debugger.",
        native_action = "Platform-specific launch assembled by lua/utils/ue_launch.lua.",
      },
      {
        key = "<Space>ug",
        nvim_command = ":UELogToggle",
        purpose = "Toggle the active application's runtime log view.",
        native_action = "Platform-specific log command assembled by lua/utils/ue_logs.lua.",
      },
      {
        key = "<Space>up",
        nvim_command = ":UEPaths",
        purpose = "Show resolved engine, project, platform, configuration, state, CDB, and index paths.",
        native_action = "Reads the resolved context; no external command.",
      },
      {
        key = "<Space>uB",
        nvim_command = ":UEPrepare",
        purpose = "Refresh file lists, compile_commands, GTAGS, csearch, and clangd index inputs.",
        native_action = "Asynchronous multi-stage pipeline; see lua/ue.lua prepare_async().",
      },
      {
        key = "<Space>uP",
        nvim_command = ":UESetProject",
        purpose = "Select and persist the project associated with this engine root.",
        native_action = "Updates this process and the startup-default selector; project state stays in its canonical bucket.",
      },
    },
  }
end

local function ue_runtime_env()
  return {
    build_target_name = build_target_name,
    dirname = _ufs.dirname,
    file_mtime = _ufs.file_mtime,
    find_uproject_in_dir = find_uproject_in_dir,
    glob_paths = glob_paths,
    is_file = _ufs.is_file,
    host_driver = require("utils.platform").driver(),
    join = join,
    norm = norm,
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

do
  local function target_error(scope, message)
    require("utils.log").notify_error(scope, tostring(message or "target operation failed"))
  end

  local function read_result_file(path)
    local content = read_all(path)
    pcall(os.remove, path)
    if not content or trim(content) == "" then
      return nil, "structured result file was not produced: " .. tostring(path)
    end
    return content
  end

  local function collect_existing_artifacts(driver, target_ctx)
    if type(driver.artifact_candidates) ~= "function" then
      return {}, nil
    end
    local result = driver.artifact_candidates(target_ctx)
    if type(result) ~= "table" or result.ok == false then
      return nil, result and result.reason or "artifact discovery unavailable"
    end
    local existing = {}
    for _, candidate in ipairs(result.candidates or {}) do
      local stat = vim.uv.fs_stat(candidate.path)
      if stat then
        local verified = vim.deepcopy(candidate)
        verified.evidence = {
          mtime = stat.mtime and stat.mtime.sec or nil,
          size = stat.size,
          type = stat.type,
        }
        existing[#existing + 1] = verified
      end
    end
    return existing
  end

  ensure_ios_workflows = function()
    return require("ue.workflows").lookup("IOS", "semantic_cdb")
  end

  ios_workflow_dependencies = function()
    ensure_ios_workflows()
    return {
      trim = trim,
      resolve_context = resolve_context,
      target_context = function(...) return CORE_RT.target_context(...) end,
      target_context_matches = function(...) return CORE_RT.target_context_matches(...) end,
      target_platform = target_platform,
      set_platform = set_platform,
      update_target_runtime = function(...) return CORE_RT.update_target_runtime(...) end,
      update_state_field = update_state_field,
      read_state = read_state,
      reset_context_cache = function() CORE_RT.context_cache = {} end,
      run_target_preflight = function(...) return CORE_RT.run_target_preflight(...) end,
      run_clangd_preflight = function(...) return CORE_RT.run_clangd_preflight(...) end,
      generate_semantic_cdb_after_build = function(...) return CORE_RT.generate_semantic_cdb_after_build(...) end,
      ue_build_running = function() return CORE_RT.ue_build_running() end,
      setup_ios = function(...) return CORE_RT.setup_ios(...) end,
      select_ios_signing_certificate = function(...) return CORE_RT.select_ios_signing_certificate(...) end,
      select_target_device = function(...) return CORE_RT.select_target_device(...) end,
      target_error = target_error,
      read_result_file = read_result_file,
      collect_existing_artifacts = collect_existing_artifacts,
      target_launch_running = CORE_RT.target_launch_running,
      resolve_legacy_install_script = function(...)
        return CORE_RT.invoke_workflow_api("IOS", "install", "resolve_legacy_install_script", { ... })
      end,
    }
  end

  function CORE_RT.run_target_preflight(driver, stage, target_ctx, host_driver, on_done)
    if type(driver.preflight_plans) ~= "function" then
      on_done(true, {})
      return
    end
    local descriptor = driver.preflight_plans(stage, target_ctx, host_driver)
    if type(descriptor) ~= "table" or descriptor.ok == false then
      on_done(false, descriptor and descriptor.reason or "preflight planning failed")
      return
    end

    local plans = descriptor.plans or {}
    local results = {}
    local index = 1
    local function advance()
      local plan = plans[index]
      if not plan then
        local validation = type(driver.validate_preflight) == "function"
            and driver.validate_preflight(stage, results, target_ctx)
          or { ok = true }
        on_done(validation.ok == true, validation.reason, results)
        return
      end
      local handle, run_err = require("ue.target_tasks").run(plan, {
        name = ("UE %s %s preflight"):format(driver.id, stage),
        on_exit = function(result)
          results[#results + 1] = result
          if result.code ~= 0 then
            on_done(false, require("ue.target_tasks").error_message(result), results)
            return
          end
          index = index + 1
          advance()
        end,
      })
      if not handle then
        on_done(false, run_err or "preflight task failed to start", results)
      end
    end
    advance()
  end

  function CORE_RT.package_target(platform)
    local ctx, err = resolve_context()
    if not ctx or not ctx.project_root then
      target_error("ue.package", err or "No project configured. Run :UESetProject [path]")
      return
    end
    local target_ctx, context_err, driver = CORE_RT.target_context(ctx, platform)
    if not target_ctx then
      target_error("ue.package", context_err)
      return
    end
    local host_driver = require("utils.platform").driver()
    local resolved, unavailable = require("ue.targets").resolve(driver.id, "package", host_driver)
    if not resolved then
      target_error("ue.package", unavailable.reason)
      return
    end
    driver = resolved
    CORE_RT.run_target_preflight(driver, "package", target_ctx, host_driver, function(ok, preflight_err)
      if not ok then
        target_error("ue.package", preflight_err)
        return
      end
      local command, plan_err, plan = CORE_RT.target_plan("package", ctx, platform, {
        host_driver = host_driver,
      })
      if not command then
        target_error("ue.package", plan_err)
        return
      end
      local package_job_id
      package_job_id = open_terminal_command(command, {
        cwd = plan.cwd or ctx.engine_root,
        quickfix_title = ("UEPackage %s %s"):format(target_ctx.platform, target_ctx.configuration),
        quickfix_root = workspace_root(ctx),
        tail_limit = 30,
        on_exit = function(code)
          if code ~= 0 then return end
          local artifacts, artifact_err = collect_existing_artifacts(driver, target_ctx)
          if not artifacts or #artifacts == 0 then
            target_error("ue.package", artifact_err or "package succeeded but no tuple-scoped artifact was found")
            return
          end
          local completed_at = os.date("!%Y-%m-%dT%H:%M:%SZ")
          for _, artifact in ipairs(artifacts) do
            artifact.metadata = type(artifact.metadata) == "table" and artifact.metadata or {}
            artifact.metadata.package_job_id = package_job_id
            artifact.metadata.package_completed_at = completed_at
            artifact.metadata.package_exit_code = 0
          end
          local runtime, update_err = CORE_RT.update_target_runtime(ctx.engine_root, driver.id, {
            artifacts = artifacts,
            target = target_ctx.target,
            configuration = target_ctx.configuration,
          })
          if not runtime then target_error("ue.package", update_err) end
        end,
      })
    end)
  end

  function CORE_RT.generate_target_symbols(platform)
    local ctx, err = resolve_context()
    if not ctx or not ctx.project_root then
      target_error("ue.symbols", err or "No project configured. Run :UESetProject [path]")
      return
    end
    local command, plan_err, plan, _, target_ctx = CORE_RT.target_plan("symbols", ctx, platform, {
      host_driver = require("utils.platform").driver(),
    })
    if not command then
      target_error("ue.symbols", plan_err)
      return
    end
    return open_terminal_command(command, {
      cwd = plan.cwd or ctx.engine_root,
      quickfix_title = ("UESymbols %s %s"):format(target_ctx.platform, target_ctx.configuration),
      quickfix_root = workspace_root(ctx),
      tail_limit = 20,
    })
  end

  function CORE_RT.select_ios_signing_certificate(query, clear, opts)
    ensure_ios_workflows()
    return dispatch_registered_workflow("IOS", "signing", {
      payload = { query = query, clear = clear, opts = opts },
      deps = ios_workflow_dependencies(),
    })
  end

  function CORE_RT.select_target_device(platform, opts)
    ensure_ios_workflows()
    return dispatch_registered_workflow("IOS", "device", {
      payload = { platform = platform, opts = opts },
      deps = ios_workflow_dependencies(),
    })
  end

  function CORE_RT.setup_ios(opts)
    ensure_ios_workflows()
    return dispatch_registered_workflow("IOS", "setup", {
      payload = { opts = opts },
      deps = ios_workflow_dependencies(),
    })
  end

  function M._with_target_bundle_id_for_test(ctx, driver, target_ctx, host_driver, on_done, dependencies)
    ensure_ios_workflows()
    return CORE_RT.invoke_workflow_api(
      "IOS",
      "install",
      "with_target_bundle_id",
      { ctx, driver, target_ctx, host_driver, on_done, dependencies },
      host_driver
    )
  end

  function M._ios_workflow_owner_for_test(operation)
    ensure_ios_workflows()
    local workflow = require("ue.workflows").lookup("IOS", operation)
    return workflow and workflow.owner or nil
  end

  function CORE_RT.install_target(platform)
    ensure_ios_workflows()
    return dispatch_registered_workflow("IOS", "install", {
      payload = { platform = platform },
      deps = ios_workflow_dependencies(),
    })
  end

  function CORE_RT.launch_target(platform, opts)
    ensure_ios_workflows()
    return dispatch_registered_workflow("IOS", "launch", {
      payload = { platform = platform, opts = opts },
      deps = ios_workflow_dependencies(),
    })
  end
end

function M.launch_app()
  local ctx = resolve_context()
  if ctx then
    local platform = target_platform(ctx.engine_root, nil)
    local host_driver = require("utils.platform").driver()
    local driver, unavailable = require("ue.targets").resolve(platform, "launch", host_driver)
    if not driver then
      require("utils.log").notify_error(
        "ue.launch",
        ("%s launch unavailable on %s: %s"):format(
          platform,
          tostring(host_driver.id),
          tostring(unavailable.reason)
        )
      )
      return
    end
    local capabilities = driver and driver.capabilities(ctx) or {}
    if capabilities.launch then
      return CORE_RT.launch_target(platform)
    end
  end
  package.loaded["utils.ue_launch"] = nil
  return require("utils.ue_launch").launch(ue_runtime_env())
end

function M.toggle_log()
  local ctx = resolve_context()
  if ctx then
    local platform = target_platform(ctx.engine_root, nil)
    local host_driver = require("utils.platform").driver()
    local _, unavailable = require("ue.targets").resolve(platform, "log", host_driver)
    if unavailable then
      require("utils.log").notify_error("ue.log", unavailable.reason)
      return
    end
  end
  return require("utils.ue_logs").toggle_main_log(ue_runtime_env())
end

function M.toggle_debug_log()
  local ctx = resolve_context()
  if ctx then
    local platform = target_platform(ctx.engine_root, nil)
    local host_driver = require("utils.platform").driver()
    local _, unavailable = require("ue.targets").resolve(platform, "debug_log", host_driver)
    if unavailable then
      require("utils.log").notify_error("ue.debug_log", unavailable.reason)
      return
    end
  end
  return require("utils.ue_logs").toggle_debug_log(ue_runtime_env())
end

local function deploy_android_so()
  local host_driver = require("utils.platform").driver()
  local dispatched, dispatch_err = dispatch_registered_workflow("Android", "so_deploy", {
    host_driver = host_driver,
    context = {
      resolve_context = resolve_context,
      read_state = read_state,
      target_context = function(ctx, platform)
        return CORE_RT.target_context(ctx, platform)
      end,
      open_terminal_command = open_terminal_command,
      workspace_root = workspace_root,
      reinvoke = deploy_android_so,
    },
  })
  if dispatched ~= nil then
    return dispatched
  end
  if dispatch_err then
    require("utils.log").notify_error("ue.android", dispatch_err.reason or dispatch_err)
  end
  return nil, dispatch_err
end

local function install_android()
  local host_driver = require("utils.platform").driver()
  local dispatched, dispatch_err = dispatch_registered_workflow("Android", "install", {
    host_driver = host_driver,
    context = {
      resolve_context = resolve_context,
      reinvoke = install_android,
    },
  })
  if dispatched ~= nil then
    return dispatched
  end
  if dispatch_err then
    require("utils.log").notify_error("ue.android", dispatch_err.reason or dispatch_err)
  end
  return nil, dispatch_err
end

local function install_active_target(opts)
  opts = opts or {}
  local ctx, err = (opts.resolve_context or resolve_context)()
  if not ctx then
    local message = err or "No project configured. Run :UESetProject [path]"
    if type(opts.notify_error) == "function" then
      opts.notify_error(message)
    else
      require("utils.log").notify_error("ue.install", message)
    end
    return nil, message
  end

  local platform = (opts.target_platform or target_platform)(ctx.engine_root, nil)
  local host_driver = type(opts.host_driver) == "table" and opts.host_driver or require("utils.platform").driver()
  local dispatched, dispatch_err, owner_found = (opts.dispatch_workflow or dispatch_registered_workflow)(
    platform,
    "install",
    {
      host_driver = host_driver,
      context = {
        resolve_context = opts.resolve_context or resolve_context,
        reinvoke = function()
          return install_active_target(opts)
        end,
      },
      payload = { platform = platform },
      deps = opts.workflow_dependencies or ios_workflow_dependencies(),
    }
  )
  if owner_found == true or dispatched ~= nil or dispatch_err ~= nil then
    return dispatched, dispatch_err
  end

  local message = ("install workflow owner is unavailable for active target %s")
    :format(platform ~= "" and tostring(platform) or "<unset>")
  if type(opts.notify_error) == "function" then
    opts.notify_error(message)
  else
    require("utils.log").notify_error("ue.install", message)
  end
  return nil, message
end

function M._install_active_target_for_test(opts)
  return install_active_target(opts)
end

local function prepare()
  local ctx, err = resolve_context()
  if not ctx then
    vim.notify(err, vim.log.levels.WARN)
    return
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
  update_state_field(ctx.engine_root, "project_scan_roots", CORE_RT.project_index_dirs(ctx))

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
          -- garbage like "D:/project/uetemp/E:/sample/...", which os.Stat rejects
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
        if not CORE_RT.csearch_build_begin("UEPrepare (sync)", ctx.paths.csearch_idx) then
          pcall(os.remove, abs_list)
        else
          local cs_done, cs_ok, cs_err, cs_stats = false, false, nil, nil
          CORE_RT.csearch_smart_build(ctx, cs_ctx_p, abs_list, function(ok_cs, err_cs, stats)
            cs_ok, cs_err, cs_stats = ok_cs, err_cs, stats
            cs_done = true
          end)
          vim.wait(180000, function() return cs_done end, 100)
          CORE_RT.csearch_build_done()
          pcall(os.remove, abs_list)
          if not cs_ok then
            vim.notify("UEPrepare: csearch index failed: " .. (cs_err or "timeout"),
              vim.log.levels.WARN, { title = "UE" })
          else
            -- Full build succeeded (D-3b + D10): retire covered dirty + record fingerprint.
            CORE_RT.on_full_csearch_success(ctx, "prepare:sync", cs_stats)
          end
        end
      end
    else
      vim.notify(
        "UEPrepare: cindex-uefilter not found — grep will use slow rg fallback.\n" ..
        "  Install it via: " .. code_search_p.install_hint(),
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

function CORE_RT.prepare_sync()
  local ctx, err = resolve_context()
  if not ctx then vim.notify(err, vim.log.levels.WARN); return false end
  local lease, lease_err = CORE_RT.file_lock.acquire(join(ctx.paths.runtime_dir, "prepare.lock"))
  if not lease then
    vim.notify("UEPrepare is running in another Neovim: " .. tostring(lease_err),
      vim.log.levels.WARN, { title = "UE" })
    return false
  end
  local ok, result = xpcall(prepare, debug.traceback)
  CORE_RT.file_lock.release(lease)
  if not ok then
    require("utils.log").notify_error("ue.prepare", tostring(result))
    return false
  end
  return result ~= false
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

  -- Build ⇄ prepare mutual exclusion (WAW): prepare's primary CDB source is
  -- the Module.*.rsp files UBT rewrites during a build — scanning them
  -- mid-build yields a CDB derived from a torn snapshot. Refuse (never
  -- queue, same policy as csearch_build_begin): the user reruns :UEPrepare
  -- once the build finishes, with final rsp/receipts on disk.
  if CORE_RT.ue_build_running() then
    vim.notify(
      "UE build is running — :UEPrepare reads build products (Module.*.rsp) the build is rewriting. "
        .. "Run :UEPrepare after the build finishes.",
      vim.log.levels.WARN, { title = "UE" })
    return
  end

  local cdb_pipeline = require("ue.cdb.pipeline")
  if M._prepare_running or cdb_pipeline.is_running() then
    vim.notify("UEPrepare is already running", vim.log.levels.INFO)
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

  -- Apple-only semantic prelude. The prepare lease begins before IOS setup /
  -- GenerateClangDatabase and is handed into the ordinary pipeline, so two
  -- Neovim instances cannot publish the same tuple source concurrently.
  -- Non-Apple targets skip this entire branch and retain their existing RSP
  -- path byte-for-byte.
  if not opts._semantic_ready then
    local target_ctx = CORE_RT.target_context(ctx)
    local targets = require("ue.targets")
    local host_driver = require("utils.platform").driver()
    if target_ctx and targets.supports(target_ctx.platform, "semantic_cdb", host_driver) then
      if CORE_RT.prepare_bootstrap_running then
        vim.notify("UEPrepare Apple semantic setup is already running", vim.log.levels.INFO)
        return
      end
      local bootstrap_lease, bootstrap_lease_err = CORE_RT.file_lock.acquire(
        join(ctx.paths.runtime_dir, "prepare.lock"))
      if not bootstrap_lease then
        vim.notify("UEPrepare is running in another Neovim: " .. tostring(bootstrap_lease_err),
          vim.log.levels.WARN, { title = "UE" })
        return
      end
      CORE_RT.prepare_bootstrap_running = true
      CORE_RT.prepare_apple_semantics(ctx, opts, function(ok, semantic_info, already_reported)
        CORE_RT.prepare_bootstrap_running = false
        if not ok then
          CORE_RT.file_lock.release(bootstrap_lease)
          if not already_reported then
            require("utils.log").notify_error(
              "ue.prepare", tostring(semantic_info or "Apple semantic preparation failed"))
          end
          return
        end
        local next_opts = vim.tbl_extend("force", opts, {
          _semantic_ready = true,
          _prepare_lease = bootstrap_lease,
          force_cdb_restart = type(semantic_info) == "table"
            and semantic_info.skipped ~= true
            and semantic_info.no_op ~= true,
        })
        prepare_async(next_opts)
      end)
      return
    end
  end

  -- Stash force flags so the cache fast-path csearch staleness check
  -- can honor :UEPrepareReindex (force a csearch rebuild even when the
  -- regular UEPrepare cache is fresh).
  ctx._force_csearch = opts.force_csearch and true or false
  -- The semantic source is published before UEPrepare starts.  Pipeline mtime
  -- comparison alone cannot observe that earlier replacement, so carry the
  -- provenance event across the async subprocess boundary and reload clangd
  -- after canonical publication even when post-processing is a no-op.
  ctx._force_cdb_restart = opts.force_cdb_restart and true or false

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

  -- Cover the entire fast path, including async CDB generation and the writer
  -- pipeline. Previously only the cold GTAGS phase set this flag, so two quick
  -- :UEPrepare calls could concurrently rewrite compile_commands.json.
  local prepare_lease = opts._prepare_lease
  local prepare_lease_err
  if not prepare_lease then
    prepare_lease, prepare_lease_err = CORE_RT.file_lock.acquire(
      join(ctx.paths.runtime_dir, "prepare.lock"))
  end
  if not prepare_lease then
    if handle then handle.message = "BUSY"; handle:finish() end
    vim.notify("UEPrepare is running in another Neovim: " .. tostring(prepare_lease_err),
      vim.log.levels.WARN, { title = "UE" })
    return
  end
  CORE_RT.prepare_lease = prepare_lease
  set_prepare_running(true)

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
          set_prepare_running(false)
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
        -- Partition MUST run AFTER the async pipeline completes — both rewrite
        -- the same base compile_commands.json, and running them concurrently
        -- tears the file mid-write (pipeline's resolve stage then hits a
        -- JSONDecodeError). Proven via timestamped race probe 2026-06-25:
        -- partition START fell inside [pipeline START, pipeline EXIT].
        -- Fix: hand partition to the pipeline's on_done so it is strictly
        -- serialized after expand→pch→resolve→unify→prune finishes.
        run_compile_commands_pipeline(targets_main[1], targets_main, function(ok_pipeline, pipeline_err)
          if not ok_pipeline then
            invalidate_status_cache()
            refresh_statusline()
            set_prepare_running(false)
            if handle then handle.message = "FAILED"; handle:finish() end
            vim.notify("UEPrepare compile_commands pipeline failed: " .. tostring(pipeline_err),
              vim.log.levels.ERROR, { title = "UE" })
            return
          end
          -- Partition base CDB by (plat, cfg) so clangd's gd on macros like
          -- UE_BUILD_DEVELOPMENT does not jump into stale Dev generated headers
          -- when the current build is Test. See INDEX_FN.partition_base_cdb.
          local ok_p, msg_p = INDEX_FN.partition_base_cdb(ctx)
          if not ok_p then
            vim.notify("UEPrepare: cdb_partition failed -- " .. tostring(msg_p),
              vim.log.levels.WARN, { title = "ue.cdb" })
          end
          clear_index_dirty(ctx)
          INDEX_FN.schedule_index_refresh(ctx,
            { current = true, hot = true, full = true, current_delay_ms = 50, hot_delay_ms = 2500 })
          invalidate_status_cache()
          refresh_statusline()
          set_prepare_running(false)
          CORE_RT.start_deferred_clangd(ctx)
          if handle then handle.message = "done"; handle.percentage = 100; handle:finish() end
          vim.notify(prepare_summary(ctx, compile_path, { reused_cache = true }))
        end, { force_restart = ctx._force_cdb_restart })

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
            if not CORE_RT.csearch_build_begin("UEPrepare (cache fast-path)", ctx.paths.csearch_idx) then
              pcall(os.remove, abs_list)
            else
              vim.notify(("UEPrepare: refreshing csearch index in background (reason: %s)..."):format(stale_reason),
                vim.log.levels.INFO, { title = "UE", timeout = 3000, replace = "ue.csearch.build" })
              CORE_RT.csearch_smart_build(ctx, cs_ctx_fp, abs_list, function(ok_cs, err_cs, stats)
                CORE_RT.csearch_build_done()
                pcall(os.remove, abs_list)
                if ok_cs then
                  local mode_str = stats.mode or "reset"
                  if mode_str == "skip" then
                    vim.notify("✓ csearch index already current (set unchanged)",
                      vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
                  else
                    local mb = math.floor((stats.index_size or 0) / 1024 / 1024)
                    vim.notify(("✓ csearch %s: %s — %d MB in %.1fs"):format(
                      mode_str == "add" and "incremental" or "rebuilt",
                      stats.delta or "", mb, (stats.ms or 0) / 1000),
                      vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
                  end
                  -- Successful build: retire its captured dirty snapshot + fingerprint.
                  CORE_RT.on_full_csearch_success(ctx, "prepare:fast-path", stats)
                else
                  vim.notify("UEPrepare: csearch rebuild failed: " .. (err_cs or "unknown"),
                    vim.log.levels.WARN, { title = "UE", replace = "ue.csearch.build" })
                end
              end)
            end
          end
        end

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
      update_state_field(ctx.engine_root, "project_scan_roots", CORE_RT.project_index_dirs(ctx))
    end)

    end_phase("lists")

    -- ── Phase 3a: generate compile_commands (parallel with gtags) ────
    -- compile_commands doesn't depend on gtags, so start it immediately.
    -- The pipeline (slim → pch → unify) runs in background via jobstart.
    update("generating compile_commands...", 30)
    start_phase()

    local cdb_pipeline_done = false
    local cdb_pipeline_ok = false
    local cdb_pipeline_err
    local finalize_waiting = false
    local finalize_after_csearch
    local function on_compile_pipeline_done(ok_pipeline, pipeline_err)
      cdb_pipeline_done = true
      cdb_pipeline_ok = ok_pipeline == true
      cdb_pipeline_err = pipeline_err
      if finalize_waiting and finalize_after_csearch then
        finalize_after_csearch()
      end
    end

    local ok_compile, compile_path = CORE_RT.trace_seg("cold.ccjson", function()
      return generate_compile_commands(ctx, nil, on_compile_pipeline_done)
    end)
    if not ok_compile then
      cdb_pipeline_done = true
      cdb_pipeline_ok = false
      cdb_pipeline_err = compile_path
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
          finalize_after_csearch = function()
            if not cdb_pipeline_done then
              finalize_waiting = true
              update("finishing compile_commands pipeline...", 95)
              return
            end
            end_phase("csearch")

            -- ── Finalize ───────────────────────────────────────────
            clear_index_dirty(ctx)
            invalidate_status_cache()
            refresh_statusline()
            set_prepare_running(false)
            if cdb_pipeline_ok then
              CORE_RT.start_deferred_clangd(ctx)
            else
              vim.notify(
                "UEPrepare finished non-clangd indexes, but the CDB pipeline failed; "
                  .. "clangd remains deferred: " .. tostring(cdb_pipeline_err or "unknown error"),
                vim.log.levels.WARN,
                { title = "UE" }
              )
            end

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
              "  Install it via: " .. code_search.install_hint(),
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

          if not CORE_RT.csearch_build_begin("UEPrepare (cold full build)", ctx.paths.csearch_idx) then
            pcall(os.remove, abs_list)
            finalize_after_csearch()
            return
          end
          CORE_RT.csearch_smart_build(ctx, cs_ctx, abs_list, function(ok_cs, err_cs, stats)
            CORE_RT.csearch_build_done()
            -- Tidy up the temp filelist regardless of outcome.
            pcall(os.remove, abs_list)

            if ok_cs then
              local mode_str = stats.mode or "reset"
              if mode_str == "skip" then
                vim.notify("✓ csearch index already current (set unchanged)",
                  vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
              else
                local mb = math.floor((stats.index_size or 0) / 1024 / 1024)
                vim.notify(("✓ csearch %s: %s — %d MB in %.1fs"):format(
                  mode_str == "add" and "incremental" or "index",
                  stats.delta or "", mb, (stats.ms or 0) / 1000),
                  vim.log.levels.INFO, { title = "UE", timeout = 4000, replace = "ue.csearch.build" })
              end
              -- Successful build: retire its captured dirty snapshot + fingerprint.
              CORE_RT.on_full_csearch_success(ctx, "prepare:cold-full", stats)
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
    else
      -- Register the gtags phase job for :Tasks list/cancel. Pure side-path:
      -- register only, after job creation; on_exit above is untouched. Status
      -- is derived live from the channel.
      pcall(function()
        require("utils.task_registry").register({
          name = "UEPrepare (index)",
          group = "ue",
          kind = "job",
          handle = CORE_RT.prepare_jobid,
          started_at = os.time(),
        })
      end)
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
CORE_RT.prepare_async = prepare_async

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
  if _ufs.is_dir(ctx.paths.semantic_cdb_dir) then
    pcall(vim.fn.delete, ctx.paths.semantic_cdb_dir, "rf")
    table.insert(removed, "  " .. ctx.paths.semantic_cdb_dir .. "/ (controlled background CDBs)")
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
      local manifest = idx .. ".manifest.json"
      if _ufs.is_file(manifest) then
        pcall(vim.fn.delete, manifest)
        table.insert(removed, "  " .. manifest .. " (offline index manifest)")
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
-- external probes, future plugins) can read/write the selected project's
-- persisted state without re-implementing canonical bucket resolution. These are forward-
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
M._grep_annotate_file_group_for_test = CORE_RT.grep_annotate_file_group
M._grep_format_grouped_for_test = CORE_RT.grep_format_grouped
M._grep_hit_item_for_test = CORE_RT.grep_hit_item
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
M.dap_stop_session      = dap_mod.dap_stop_session
M.dap_status_session    = dap_mod.dap_status_session
M.setup_dap = dap_mod.setup_dap

-- ==========================================================================
-- SETUP — user commands, autocmds, statusline timer
-- ==========================================================================

function M._android_install_argv_for_test(adb, serial, apk)
  local plan = require("ue.targets").plan("Android", "install", {
    adb = adb,
    apk = apk,
    cwd = vim.fn.getcwd(),
    device_id = serial,
  }, _uplat._driver_for_test("windows"))
  return require("ue.target_tasks").command(plan)
end

function M._target_platform_for_test(engine_root, cmd)
  return target_platform(engine_root, cmd)
end

function M._set_platform_for_test(input, opts)
  return set_platform(input, opts)
end

function M._android_so_deploy_command_for_test(ctx, serial, package_name)
  return android_so_deploy_command(
    ctx, serial, package_name, _uplat._driver_for_test("windows")
  )
end

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
  vim.api.nvim_create_user_command("UESetAndroidDevice", function()
    require("utils.android_device").select({
      prompt = "Select Android device for this Neovim:",
    }, function(serial, device)
      if serial then
        vim.notify(("Android device selected: %s"):format(
          require("utils.android_device").format_item(device)), vim.log.levels.INFO)
      end
    end)
  end, { desc = "Select the process-local Android device (name + serial)" })
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
      string.format("UE grep structured groups/preview throttle/Tab tweaks: %s",
        now and "ON (default)" or "OFF (vanilla snacks)"),
      vim.log.levels.INFO,
      { title = "UE", timeout = 4000 })
  end, { desc = "Toggle UE grep structured grouping + preview throttle + Tab=list_down" })

  vim.api.nvim_create_user_command("UEGrepTraceToggle", function()
    vim.g.ue_grep_trace = not (vim.g.ue_grep_trace == true)
    local on = vim.g.ue_grep_trace
    local path = vim.fn.stdpath("state") .. ("/ue_grep_trace.%d.log"):format(vim.fn.getpid())

    -- Error sink: poll :messages and tee Error/E5/attempt patterns to disk.
    -- We DO NOT override vim.notify (noice would warn about that and ding
    -- loudly). Lifecycle (F5, health-check 2026-07): the timer MUST die with
    -- the toggle — the previous version installed it forever on first ON
    -- (500ms `nvim_exec2("messages")` + `messages clear` even after OFF),
    -- a P5-adjacent leak. Handle lives on CORE_RT so repeated toggles reuse
    -- one slot; OFF stops AND closes it.
    if on and not CORE_RT.err_sink_timer then
      local err_log = vim.fn.stdpath("state") .. ("/ue_errors.%d.log"):format(vim.fn.getpid())
      local f = io.open(err_log, "w")
      if f then f:write("=== installed " .. os.date() .. " ===\n"); f:close() end
      local timer = vim.uv.new_timer()
      if timer then
        CORE_RT.err_sink_timer = timer
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
    elseif not on and CORE_RT.err_sink_timer then
      pcall(function() CORE_RT.err_sink_timer:stop() end)
      pcall(function() CORE_RT.err_sink_timer:close() end)
      CORE_RT.err_sink_timer = nil
    end

    vim.notify(string.format("UE grep trace: %s\nlog: %s",
      on and "ON" or "OFF", path),
      vim.log.levels.INFO, { title = "UE", timeout = 6000 })
  end, { desc = "Toggle UE grep finder trace logging + error sink" })

  vim.api.nvim_create_user_command("UEGrepTraceShow", function()
    local path = vim.fn.stdpath("state") .. ("/ue_grep_trace.%d.log"):format(vim.fn.getpid())
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
    local out_path = vim.fn.stdpath("state") .. ("/ue_grep_diag.%d.txt"):format(vim.fn.getpid())
    local trace_path = vim.fn.stdpath("state") .. ("/ue_grep_trace.%d.log"):format(vim.fn.getpid())
    local err_path = vim.fn.stdpath("state") .. ("/ue_errors.%d.log"):format(vim.fn.getpid())

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
  vim.api.nvim_create_user_command("UEBuild", build_target, {})
  vim.api.nvim_create_user_command("UEBuildAndroid", build_target, {})
  vim.api.nvim_create_user_command("UEBuildIOS", function()
    build_target({ platform = "IOS", title = "UEBuildIOS" })
  end, { desc = "Build the IOS target through the IOS target driver" })
  vim.api.nvim_create_user_command("UEBuildAndroidSO", function()
    build_target({ operation = "so_build" })
  end, {})
  vim.api.nvim_create_user_command("UECompileForNvim", CORE_RT.compile_for_nvim, {
    desc = "Compatibility entry: build the active target, then run the normal UEPrepare path",
  })
  vim.api.nvim_create_user_command("UEPackageIOS", function()
    CORE_RT.package_target("IOS")
  end, { desc = "Package the IOS target from existing cooked data without building or cooking" })
  vim.api.nvim_create_user_command("UEIOSSymbols", function()
    CORE_RT.generate_target_symbols("IOS")
  end, { desc = "Generate and UUID-verify the current IOS binary's dSYM on demand" })
  vim.api.nvim_create_user_command("UEIOSSetup", function()
    CORE_RT.setup_ios()
  end, {
    desc = "One-time IOS setup from PrepareIOSQADebug signing evidence and the connected device",
  })
  vim.api.nvim_create_user_command("UESetIOSSigningCertificate", function(cmd)
    CORE_RT.select_ios_signing_certificate(cmd.args, cmd.bang)
  end, {
    bang = true,
    nargs = "*",
    desc = "Select the current project's IOS code-sign identity; bang clears it",
  })
  vim.api.nvim_create_user_command("UESetIOSDevice", function()
    CORE_RT.select_target_device("IOS")
  end, { desc = "Select an available physical IOS device through its target driver" })
  vim.api.nvim_create_user_command("UEInstallIOS", function()
    CORE_RT.install_target("IOS")
  end, { desc = "Install the current tuple's staged IOS app through its target driver" })
  vim.api.nvim_create_user_command("UEDeployAndroidSO", deploy_android_so, {})
  vim.api.nvim_create_user_command("UELaunch", function()
    M.launch_app()
  end, {})
  vim.api.nvim_create_user_command("UELogToggle", function()
    M.toggle_log()
  end, {})
  vim.api.nvim_create_user_command("UEDebugLogToggle", function()
    M.toggle_debug_log()
  end, {})
  vim.api.nvim_create_user_command("UEInstall", install_active_target, {
    desc = "Install for the active Android or IOS target without launching",
  })
  vim.api.nvim_create_user_command("UEInstallAndroid", install_android, {})
  vim.api.nvim_create_user_command("UEPrepare", function(cmd)
    local bang = cmd.bang and true or false
    require("utils.async_launcher").launch({
      name  = bang and "UE: Prepare (FORCE full rebuild)" or "UE: Prepare (semantic + ccjson + index)",
      group = "ue",
      cancel = function()
        -- <C-c> on the launcher float cancels the prepare jobs registered in
        -- the task registry (gtags + ccjson). Pure side-path; uses public API.
        local ok_tr, tr = pcall(require, "utils.task_registry")
        if not ok_tr then return end
        for _, row in ipairs(tr.list()) do
          if row.status == "running" and row.group == "ue" then
            tr.cancel(row.id)
          end
        end
      end,
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
            -- Do not clear dirty state before the rebuild succeeds. The
            -- csearch writer captures a snapshot at start and subtracts only
            -- that covered snapshot after successful publication.
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
      vim.notify("cindex-uefilter not found — install it via: " .. code_search.install_hint(),
        vim.log.levels.WARN, { title = "UE" })
      return
    end
    if not CORE_RT.csearch_build_begin("UEPrepareIncremental", ctx.paths.csearch_idx) then
      return
    end
    local abs_list = ctx.paths.cache .. ("/csearch_incremental.%d.%s.txt"):format(
      vim.fn.getpid(), tostring(vim.uv.hrtime()))
    local fout = io.open(abs_list, "w")
    if not fout then
      CORE_RT.csearch_build_done()
      vim.notify("UEPrepareIncremental: cannot write " .. abs_list, vim.log.levels.WARN)
      return
    end
    for _, p in ipairs(dirty) do fout:write(p, "\n") end
    fout:close()
    vim.notify(("UEPrepareIncremental: adding %d dirty files to csearch index ..."):format(#dirty),
      vim.log.levels.INFO, { title = "UE", timeout = 3000, replace = "ue.csearch.build" })
    local cs_ctx = { workspace_root = workspace_root(ctx), csearch_idx = ctx.paths.csearch_idx }
    code_search.build_index(cs_ctx, abs_list, function(ok_cs, err_cs, stats)
      CORE_RT.csearch_build_done()
      pcall(os.remove, abs_list)
      if ok_cs then
        if type(watch.remove_persistent_dirty) == "function" then
          watch.remove_persistent_dirty(dirty, "UEPrepareIncremental", CORE_RT.csearch_build_started_at)
        end
        CORE_RT.csearch_build_started_at = nil
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
    CORE_RT.prepare_sync()
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
    -- overlay's source of truth until the next csearch publish).
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
    local host_driver = _uplat.driver()
    if type(host_driver.pch_build_plan) ~= "function" then
      vim.notify(
        "UEBuildPCH is unavailable on " .. tostring(host_driver.id) .. "; the PCH cache pipeline is Windows-only.",
        vim.log.levels.WARN
      )
      return
    end
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
    local plan = host_driver.pch_build_plan(bat)
    local command, command_err = require("ue.target_tasks").command(plan)
    if not command then
      vim.notify("UEBuildPCH: " .. tostring(command_err), vim.log.levels.WARN)
      return
    end
    vim.notify("UE: rebuilding PCH (background) — " .. bat, vim.log.levels.INFO)
    vim.fn.jobstart(command, {
      cwd = plan.cwd,
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
  -- Registration is filtered by the host-target compatibility matrix;
  -- importable foreign modules do not become executable capabilities.
  local dap_platforms = require("ue.dap.platforms")
  dap_platforms.register_supported(require("utils.platform").driver(), M)

  local function dap_dispatch(kind, platform)
    platform = (platform ~= "" and platform) or (M.current_platform() or "")
    local host_driver = require("utils.platform").driver()
    local operation = kind == "attach" and "dap_attach" or "dap_launch"
    local _, unavailable = require("ue.targets").resolve(platform, operation, host_driver)
    if unavailable then
      vim.notify(
        ("UEDAP%s: target %q is unavailable on host %q (%s)"):format(
          kind == "attach" and "Attach" or "Launch",
          platform,
          tostring(host_driver.id),
          tostring(unavailable.reason)
        ),
        vim.log.levels.WARN
      )
      return
    end
    local handler = (kind == "attach")
      and dap_platforms.attach_handler(platform)
      or  dap_platforms.launch_handler(platform)
    if handler then
      local started, start_err = dap_platforms.begin(kind, platform)
      if not started then
        vim.notify(
          ("UEDAP%s: %s"):format(
            kind == "attach" and "Attach" or "Launch",
            tostring(start_err and start_err.reason or "dispatch failed")
          ),
          vim.log.levels.WARN
        )
      end
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
  local function dap_lifecycle_dispatch(kind)
    local ok_dap, dap = pcall(require, "dap")
    local session = ok_dap and dap.session and dap.session() or nil
    local handled, lifecycle_err = dap_platforms.dispatch_lifecycle(kind, { session = session })
    if not handled then
      vim.notify(
        ("UEDAP%s unavailable: %s"):format(
          kind:sub(1, 1):upper() .. kind:sub(2),
          tostring(lifecycle_err and lifecycle_err.reason or "session owner is unavailable")
        ),
        vim.log.levels.WARN
      )
    end
    return handled
  end
  vim.api.nvim_create_user_command("UEDAPStop", function()
    if dap_lifecycle_dispatch("stop") then
      vim.notify("[ue.dap] session stopped", vim.log.levels.INFO)
    end
  end, { desc = "DAP: Stop through the frozen session owner" })
  vim.api.nvim_create_user_command("UEDAPReattach", function()
    dap_lifecycle_dispatch("reattach")
  end, { desc = "DAP: Reattach through the frozen session owner" })
  vim.api.nvim_create_user_command("UEDAPStatus", function()
    dap_lifecycle_dispatch("status")
  end, { desc = "DAP: Status of the frozen session owner" })

  -- ── Generic background-task management (:Tasks / :TaskStop / :TaskStopAll) ─
  -- Generic, non-UE feature: list and cancel any registered background job
  -- (build / prepare / launch / install / logcat / log-stream). State is
  -- derived live from each handle (see lua/utils/task_registry.lua). Registered
  -- here only to reuse ue.setup()'s idempotent command-registration + the
  -- commands_spec frozen list; the command NAMES are intentionally prefix-free.
  do
    local function task_label(row)
      local age = row.started_at and (os.time() - row.started_at) or nil
      local when
      if row.status == "running" and age then
        when = ("%dm%02ds"):format(math.floor(age / 60), age % 60)
      else
        when = row.status
      end
      local icon = ({ running = "●", done = "○", cancelled = "◌" })[row.status] or "?"
      return ("%s %-22s %-8s %s"):format(icon, row.name, row.group, when)
    end

    local function pick_and_cancel(rows, prompt)
      -- rows already filtered to running. vim.ui.select uses snacks backend.
      vim.ui.select(rows, {
        prompt = prompt or "Stop task:",
        format_item = task_label,
      }, function(choice)
        if not choice then return end
        local tr = require("utils.task_registry")
        if tr.cancel(choice.id) then
          vim.notify(("已停止 %s"):format(choice.name), vim.log.levels.INFO, { title = "Tasks" })
        else
          vim.notify(("%s 已结束"):format(choice.name), vim.log.levels.INFO, { title = "Tasks" })
        end
      end)
    end

    vim.api.nvim_create_user_command("Tasks", function()
      local tr = require("utils.task_registry")
      local rows = tr.list()
      if #rows == 0 then
        vim.notify("无后台任务", vim.log.levels.INFO, { title = "Tasks" })
        return
      end
      vim.ui.select(rows, {
        prompt = "Tasks (select to stop):",
        format_item = task_label,
      }, function(choice)
        if not choice then return end
        if choice.status ~= "running" then
          vim.notify(("%s 已结束（%s）"):format(choice.name, choice.status), vim.log.levels.INFO, { title = "Tasks" })
          return
        end
        if tr.cancel(choice.id) then
          vim.notify(("已停止 %s"):format(choice.name), vim.log.levels.INFO, { title = "Tasks" })
        else
          vim.notify(("%s 已结束"):format(choice.name), vim.log.levels.INFO, { title = "Tasks" })
        end
      end)
    end, { desc = "List background tasks; select to stop" })

    vim.api.nvim_create_user_command("TaskStop", function(opts)
      local tr = require("utils.task_registry")
      local arg = vim.trim(opts.args or "")
      if arg ~= "" then
        local id = tonumber(arg)
        if not id then
          vim.notify("TaskStop: id must be a number", vim.log.levels.WARN, { title = "Tasks" })
          return
        end
        local st = tr.status(id)
        if st ~= "running" then
          vim.notify(("task %s 不在运行（%s）"):format(arg, tostring(st)), vim.log.levels.INFO, { title = "Tasks" })
          return
        end
        if tr.cancel(id) then
          vim.notify(("已停止 %s"):format((tr.get(id) or {}).name or arg), vim.log.levels.INFO, { title = "Tasks" })
        end
        return
      end
      -- No id: collect running tasks.
      local running = {}
      for _, row in ipairs(tr.list()) do
        if row.status == "running" then running[#running + 1] = row end
      end
      if #running == 0 then
        vim.notify("无运行中的后台任务", vim.log.levels.INFO, { title = "Tasks" })
      elseif #running == 1 then
        local row = running[1]
        if tr.cancel(row.id) then
          vim.notify(("已停止 %s"):format(row.name), vim.log.levels.INFO, { title = "Tasks" })
        end
      else
        pick_and_cancel(running, "Stop task:")
      end
    end, { nargs = "?", desc = "Stop a background task (by id, or pick if multiple)" })

    vim.api.nvim_create_user_command("TaskStopAll", function()
      local tr = require("utils.task_registry")
      local n = 0
      for _, row in ipairs(tr.list()) do
        if row.status == "running" then n = n + 1 end
      end
      if n == 0 then
        vim.notify("无运行中的后台任务", vim.log.levels.INFO, { title = "Tasks" })
        return
      end
      local choice = vim.fn.confirm(("停掉 %d 个任务？"):format(n), "&Yes\n&No", 2)
      if choice ~= 1 then return end
      local stopped = tr.cancel_all()
      vim.notify(("已停止 %d 个任务"):format(stopped), vim.log.levels.INFO, { title = "Tasks" })
    end, { desc = "Stop all running background tasks (confirms first)" })
  end

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
      -- Foreign-checkout guard: project selection is manual-only (2026-07-14),
      -- so a C++ buffer from ANOTHER checkout (e.g. pinned project is
      -- E:/sample/A but the file lives in E:/sample/B) is never auto-switched.
      -- That is by design — but silently leaving it on clangd fallback flags
      -- reads as "UEPrepare broken, diagnostics everywhere". Warn once per
      -- foreign root so the user knows to :UESetProject (or that they opened
      -- the wrong checkout).
      CORE_RT.notify_foreign_buffer(ctx, path)
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
  progress("semantic_source", 45, "checking tuple-scoped semantic CDB...")
  local ok_existing, existing_path = export_compile_commands_to_engine_root(ctx)
  if ok_existing then
    return true, existing_path
  end
  return false, tostring(rsp_path or "no RSP entries for the active tuple")
    .. "; " .. tostring(existing_path)
    .. "; run :UECompileForNvim to build and prepare it"
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

  -- Register the ccjson subprocess for :Tasks list/cancel. Pure side-path:
  -- register only, after spawn; the completion callback above is untouched.
  -- Status is derived live from the vim.system handle.
  pcall(function()
    require("utils.task_registry").register({
      name = "UEPrepare (ccjson)",
      group = "ue",
      kind = "system",
      handle = handle,
      started_at = os.time(),
    })
  end)

  return handle
end

return M
