-- Code search dispatcher.
--
-- Delivers full <file>:<line>:<col>:<text> match results for live grep
-- in pickers. Backends in priority order; the first available wins.
--
--   csearch (trigram index, sub-second on 100k-file UE workspaces) ←
--     requires `cindex-uefilter` to have built an index, which UEPrepare
--     does automatically. See tools/cindex-uefilter/.
--   rg (walks the workspace; ~14-32s on UE — used as fallback only)
--
-- API:
--
--   require("utils.code_search").is_indexed(ctx) → boolean
--       Cheap probe: does a usable csearch index exist for this ctx?
--
--   require("utils.code_search").current_backend(ctx) → "csearch" | "rg" | nil
--
--   require("utils.code_search").csearch_exe() → executable path | nil
--   require("utils.code_search").cindex_uefilter_exe() → executable path | nil
--   require("utils.code_search").install_hint() → host-appropriate install command
--
--   require("utils.code_search").stream(ctx, pattern, opts, callbacks)
--       Spawn a search; callbacks = { on_line, on_done }.
--       on_line(file, lnum, col, text)
--       on_line's optional fifth argument proves a byte span or marks line-only;
--       col is nil when csearch cannot prove a literal span (including regex).
--       on_done(exit_code, err_msg | nil, terminal_metadata)
--       Returns a stop() function the caller can invoke to kill the proc.
--       stop(reason) returns canceled metadata and never calls back afterwards.
--
-- opts: { code_only = bool, max_count = int, smart_case = bool,
--         regex = bool (default true; false = literal/fixed-string),
--         word  = bool (whole-word match, wraps pattern in \b...\b),
--         case  = bool (case-sensitive; nil/false = smart-case behavior),
--         ignore_case = bool (force case-insensitive unless case=true),
--         require_index = bool (never permit rg even if the index disappears),
--         timeout_ms = int (default 30000) }

local M = {}

local platform = require("utils.platform")

-- ── csearch backend ──────────────────────────────────────────────────────

-- Resolve executable paths. We cache ONLY successful probes.
--
-- WHY no negative caching: a probe can fail transiently during a cold GUI
-- start (PATH / vim.env not yet fully populated) or while UEPrepare is
-- mid-rebuild. If we cached that nil for the whole session, is_indexed()
-- would return false forever, cached_grep() would silently fall through to
-- the slowest snacks directory-walk path, and the user would get incomplete
-- grep results with no signal. So: success → remember the path; failure →
-- return nil WITHOUT poisoning the next call. The lookup is cheap (a handful
-- of executable() checks), so re-probing on miss is acceptable.
--
-- _reset_probe_cache() lets UEPrepare's finalize step (and tests) force a
-- re-probe after the toolchain may have become available.
local _csearch_path = nil
local _cindex_path = nil
local INDEX_MAGIC = "csearch index 1\n"
local INDEX_TRAILER = "\ncsearch trailr\n"

function M._reset_probe_cache()
  _csearch_path = nil
  _cindex_path = nil
end

local function go_tool_candidates(base)
  return platform.go_tool_candidates(base, vim.env, platform.driver())
end

local function csearch_exe()
  if _csearch_path then return _csearch_path end
  local resolved = platform.resolve_tool({
    name = "csearch",
    driver_candidates = function()
      return go_tool_candidates("csearch")
    end,
  })
  if resolved.ok then
    _csearch_path = resolved.path  -- cache success only
    return resolved.path
  end
  return nil  -- do NOT cache the miss
end

function M.csearch_exe()
  return csearch_exe()
end

function M.cindex_uefilter_exe()
  if _cindex_path then return _cindex_path end
  local resolved = platform.resolve_tool({
    name = "cindex-uefilter",
    driver_candidates = function()
      return go_tool_candidates("cindex-uefilter")
    end,
  })
  if resolved.ok then
    _cindex_path = resolved.path  -- cache success only
    return resolved.path
  end
  return nil  -- do NOT cache the miss
end

function M.install_hint()
  local config = vim.fn.stdpath("config")
  return platform.driver().code_search_install_hint(config)
end

function M._go_tool_candidates_for_test(base)
  return go_tool_candidates(base)
end

-- Per-workspace index path. Lives next to UEPrepare's other caches.
-- ctx must expose workspace_root either as a field OR via a wrapper —
-- callers typically pass { workspace_root = "...", ... }.
--
-- Layout v2: prefer ctx.csearch_idx if caller passed it (avoids duplicating
-- the layout knowledge here). Fall back to legacy in-cache location for
-- back-compat with non-ue.lua callers.
function M.index_path(ctx)
  -- v2: caller supplied an explicit path (single source of truth in ue.lua)
  if ctx.csearch_idx and ctx.csearch_idx ~= "" then
    return ctx.csearch_idx
  end
  local root = ctx.workspace_root or ctx.root
  if not root or root == "" then
    return nil
  end
  return root .. "/.cache/nvim-ue/csearch/csearch.idx"
end

local function usable_index_stat(path)
  local stat = path and vim.loop.fs_stat(path) or nil
  local trailer_size = 20 + #INDEX_TRAILER
  if not stat or stat.type ~= "file" or stat.size < #INDEX_MAGIC + trailer_size then return nil end
  -- Read bounded framing/offset metadata, never a whole multi-GB index.
  -- Size alone accepts both truncated writers and arbitrary unrelated files.
  local file = io.open(path, "rb")
  if not file then return nil end
  local magic = file:read(#INDEX_MAGIC)
  local trailer_at = file:seek("end", -trailer_size)
  local trailer = trailer_at and file:read(trailer_size)
  file:close()
  if magic ~= INDEX_MAGIC or not trailer or #trailer ~= trailer_size
      or trailer:sub(21) ~= INDEX_TRAILER then return nil end
  local offsets = {}
  local previous = #INDEX_MAGIC
  for at = 1, 20, 4 do
    local a, b, c, d = trailer:byte(at, at + 3)
    local offset = ((a * 256 + b) * 256 + c) * 256 + d
    if offset < previous or offset > trailer_at then return nil end
    offsets[#offsets + 1] = offset
    previous = offset
  end
  if offsets[1] ~= #INDEX_MAGIC or offsets[5] - offsets[4] < 4
      or (offsets[5] - offsets[4]) % 4 ~= 0
      or (trailer_at - offsets[5]) % 11 ~= 0 then return nil end
  return stat
end

-- Check that a usable csearch index file exists for this workspace.
function M.is_indexed(ctx)
  if not csearch_exe() then return false end
  local idx = M.index_path(ctx)
  if not idx then return false end
  -- Availability is read-only. Only a successful writer may publish staging;
  -- abandoned temporary files are never treated as committed search data.
  return usable_index_stat(idx) ~= nil
end

-- Test seam: "is this published index framed completely?" Backs the
-- D9 resilience guard that refuses incremental builds onto a corrupt/0-byte idx.
function M._usable_index_for_test(path)
  return usable_index_stat(path) ~= nil
end

function M.current_backend(ctx)
  if M.is_indexed(ctx) then return "csearch" end
  if vim.fn.executable("rg") == 1 then return "rg" end
  return nil
end

-- Stream csearch output. csearch's -n format:
--   /path/to/file.cpp:123:matched line text here
-- We reconstruct column by re-finding pattern (rough; sufficient for
-- picker preview placement). For exact column, use rg fallback.
-- Compose csearch's single `-f fileregexp` (RE2) from two independent
-- constraints. csearch accepts only ONE -f and RE2 has no lookahead, so we
-- fold both into a single linear regex:
--   code_only  → path ends in a source extension
--   path_filter (scope) → path is under a module/plugin/dir root (already an
--                         RE2-escaped fragment; caller escapes the literal root)
-- Result:
--   <scope> .* \.(exts)$   (both)   |   <scope>   (scope only)
--   \.(exts)$              (code_only only)        |   nil (neither)
-- Pure + side-effect-free so it can be unit-tested without spawning csearch.
M._FILE_EXT_RE =
  "\\.(cpp|c|cc|cxx|h|hpp|hh|hxx|inl|ipp|inc|m|mm|cs|usf|ush|hlsl|hlsli|glsl|comp|vert|frag|geom|tesc|tese|metal|ini|cfg|conf|ts|tsx|js|json|xml|yaml|yml|py|lua|uproject|uplugin|target\\.cs|build\\.cs)$"
function M._compose_file_regex(opts)
  opts = opts or {}
  local scope_re = type(opts.path_filter) == "string" and opts.path_filter ~= "" and opts.path_filter or nil
  if opts.code_only and scope_re then
    return scope_re .. ".*" .. M._FILE_EXT_RE
  elseif opts.code_only then
    return M._FILE_EXT_RE
  elseif scope_re then
    return scope_re
  end
  return nil
end

-- Quote literal input for csearch's RE2 parser. This mirrors Go's
-- regexp.QuoteMeta set exactly: punctuation such as slash, hyphen and percent
-- is already literal outside a character class and must not gain regex syntax.
local RE2_META = {
  ["\\"] = true,
  ["."] = true,
  ["+"] = true,
  ["*"] = true,
  ["?"] = true,
  ["("] = true,
  [")"] = true,
  ["|"] = true,
  ["["] = true,
  ["]"] = true,
  ["{"] = true,
  ["}"] = true,
  ["^"] = true,
  ["$"] = true,
}

local function escape_re2_literal(value)
  value = tostring(value or "")
  local escaped = {}
  for index = 1, #value do
    local byte = value:sub(index, index)
    escaped[#escaped + 1] = RE2_META[byte] and ("\\" .. byte) or byte
  end
  return table.concat(escaped)
end

M._escape_re2_literal_for_test = escape_re2_literal

local function stream_csearch(ctx, pattern, opts, callbacks)
  local reader_class = require("utils.code_search.stream_reader")
  local location = require("utils.code_search.location")
  local raw_needle = pattern
  local reader = reader_class.new({
    backend = "csearch",
    max_count = opts.max_count,
    timeout_ms = opts.timeout_ms,
    parse = function(line)
      if line == "" then
        return nil
      end
      local search_start = line:sub(2, 2) == ":" and 3 or 1
      local file_end = line:find(":", search_start, true)
      if not file_end then
        return nil
      end
      local lnum, text = line:sub(file_end + 1):match("^(%d+):(.*)$")
      if not lnum then
        return nil
      end
      local col, span = location.literal(text, raw_needle, opts)
      return { file = line:sub(1, file_end - 1), lnum = tonumber(lnum), col = col, text = text, location = span }
    end,
  }, callbacks)
  local cs = csearch_exe()
  if not cs then
    return reader:attach(nil, "csearch not found in PATH")
  end
  local args = { "-n" }
  local file_re = M._compose_file_regex(opts)
  if file_re then
    vim.list_extend(args, { "-f", file_re })
  end
  if opts.regex == false then
    pattern = escape_re2_literal(pattern)
  end
  if opts.word then
    pattern = "\\b" .. pattern .. "\\b"
  end
  if location.ignore_case(raw_needle, opts) then
    pattern = "(?i)" .. pattern
  end
  args[#args + 1] = pattern
  local env = {}
  for key, value in pairs(vim.fn.environ()) do
    if key ~= "CSEARCHINDEX" then
      env[#env + 1] = key .. "=" .. value
    end
  end
  env[#env + 1] = "CSEARCHINDEX=" .. M.index_path(ctx)
  local handle, err = vim.loop.spawn(cs, {
    args = args,
    env = env,
    stdio = { nil, reader.stdout, reader.stderr },
  }, function(code, signal)
    reader:exit(code, signal)
  end)
  return reader:attach(handle, err)
end

-- ── rg fallback ──────────────────────────────────────────────────────────

local function stream_rg(ctx, pattern, opts, callbacks)
  local location = require("utils.code_search.location")
  local reader = require("utils.code_search.stream_reader").new({
    backend = "rg",
    max_count = opts.max_count,
    timeout_ms = opts.timeout_ms,
    record_end = function(buffer)
      local nul = buffer:find("\0", 1, true)
      local newline = nul and buffer:find("\n", nul + 1, true)
      return newline, newline
    end,
    parse = function(record)
      local file_end = record:find("\0", 1, true)
      if not file_end then
        return nil
      end
      local lnum, col, text = record:sub(file_end + 1):match("^(%d+):(%d+):(.*)$")
      if not lnum then
        return nil
      end
      col = tonumber(col)
      local _, span = location.literal(text, pattern, opts)
      if not span or span.precision ~= "exact" or span.byte_start0 ~= col - 1 then
        span = { precision = "column", byte_start0 = col - 1, reason = "rg-column-without-end-span" }
      end
      return { file = record:sub(1, file_end - 1), lnum = tonumber(lnum), col = col, text = text, location = span }
    end,
  }, callbacks)
  local rg = vim.fn.exepath("rg")
  if rg == "" then
    return reader:attach(nil, "rg not found and no csearch index available")
  end
  local args = {
    "--color=never",
    "--no-heading",
    "--with-filename",
    "--line-number",
    "--column",
    "--max-columns=500",
    "-0",
    "-j",
    "32",
    "--mmap",
  }
  if opts.case == true then
    args[#args + 1] = "--case-sensitive"
  elseif opts.ignore_case == true then
    args[#args + 1] = "--ignore-case"
  else
    args[#args + 1] = "--smart-case"
  end
  if opts.regex == false then
    args[#args + 1] = "--fixed-strings"
  end
  if opts.word then
    args[#args + 1] = "--word-regexp"
  end
  for _, exclude in ipairs(opts.exclude_dirs or {}) do
    vim.list_extend(args, { "-g", "!**/" .. exclude .. "/**" })
  end
  if opts.code_only then
    for _, ext in ipairs({
      "cpp",
      "c",
      "cc",
      "cxx",
      "h",
      "hpp",
      "hh",
      "hxx",
      "inl",
      "cs",
      "usf",
      "ush",
      "hlsl",
      "hlsli",
    }) do
      vim.list_extend(args, { "-g", "*." .. ext })
    end
  end
  vim.list_extend(args, { "--", pattern })
  vim.list_extend(args, opts.search_dirs or {})
  local handle, err = vim.loop.spawn(rg, {
    args = args,
    cwd = ctx.workspace_root,
    stdio = { nil, reader.stdout, reader.stderr },
  }, function(code, signal)
    reader:exit(code, signal)
  end)
  return reader:attach(handle, err)
end

-- ── Public dispatcher ────────────────────────────────────────────────────

function M.stream(ctx, pattern, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  if not callbacks.on_line then
    callbacks.on_line = function() end
  end
  if not callbacks.on_done then
    callbacks.on_done = function() end
  end

  if M.is_indexed(ctx) then
    return stream_csearch(ctx, pattern, opts, callbacks)
  end
  if opts.require_index then
    local reader = require("utils.code_search.stream_reader").new({
      backend = "csearch",
      max_count = opts.max_count,
      parse = function() end,
    }, callbacks)
    reader.failure_state, reader.failure_reason = "index_unavailable", "index-unavailable"
    return reader:attach(nil, "csearch index unavailable; rebuild the search index")
  end
  return stream_rg(ctx, pattern, opts, callbacks)
end

-- ── Index build (called from UEPrepare) ──────────────────────────────────

-- Run cindex-uefilter -reset -files-from <abs_list>. Async; calls
-- cb(ok, err_msg, stats) on vim.schedule.
--
--   abs_list_path : a temp file containing absolute paths (one per line)
--   cb(ok, err, { count, ms, index_size })
--   opts.mode     : "reset" (default — wipe and rebuild) or "add" (incremental
--                   append to existing index; csearch's cindex semantics:
--                   "add the file or directory tree to the index").
--                   Use "add" for watcher-driven dirty file flushes so the
--                   trigram index stays current without re-walking the whole
--                   workspace.
-- Returns a stop() function for bounded callers; existing callers may ignore it.
function M.build_index(ctx, abs_list_path, cb, opts)
  opts = opts or {}

  -- Gate at the single cindex spawn seam so cold, cache-fast and incremental
  -- callers cannot drift. The existing csearch writer slot remains owned by
  -- the caller across queued+running states; no child exists while deferred.
  if opts._host_admitted ~= true then
    local admission = require("utils.host_admission")
    local started, stop, start_err, control = admission.run_when_allowed({
      name = "csearch index build",
      start = function()
        return M.build_index(ctx, abs_list_path, cb,
          vim.tbl_extend("force", opts, { _host_admitted = true }))
      end,
      on_defer = function(reason, reading, deferrals)
        pcall(function()
          require("utils.log").debug_ctx("host.admission", "deferred csearch build", {
            reason = reason,
            deferrals = deferrals,
            host_pct = reading and reading.host_pct or nil,
          })
        end)
      end,
      on_error = function(err)
        vim.schedule(function() cb(false, "csearch admission failed: " .. tostring(err), {}) end)
      end,
    })
    if started then
      if type(stop) == "function" then return stop end
      vim.schedule(function() cb(false, tostring(start_err or "csearch admission failed"), {}) end)
      return function() end
    end
    return function() control:cancel() end
  end

  local mode = opts.mode or "reset"
  local cindex = M.cindex_uefilter_exe()
  if not cindex then
    vim.schedule(function()
      cb(false,
         "cindex-uefilter not found. Install it via:\n" ..
         "  " .. M.install_hint(),
         {})
    end)
    return function() end
  end

  local idx = M.index_path(ctx)
  if not idx then
    vim.schedule(function() cb(false, "csearch index path is unavailable", {}) end)
    return function() end
  end
  local parent = vim.fn.fnamemodify(idx, ":h")
  local dir_ok = pcall(vim.fn.mkdir, parent, "p")
  if not dir_ok or vim.fn.isdirectory(parent) == 0 then
    vim.schedule(function() cb(false, "cannot create csearch index directory: " .. parent, {}) end)
    return function() end
  end

  -- Resilience (D9): an incremental "add" against an unusable target index
  -- (missing / 0-byte / corrupt) makes cindex `merge` read a broken header →
  -- `corrupt index: remove` → the idx is deleted → the next add hits a 0-byte
  -- idx again → death loop (2026-06-17). Refuse the add and point the user at a
  -- full rebuild. mode="reset" is always safe (it ignores the prior idx), so it
  -- is exempt from this guard.
  if mode == "add" and not usable_index_stat(idx) then
    vim.schedule(function()
      cb(false,
         "csearch index unusable (missing/0-byte/corrupt) — run :UEPrepare for a full rebuild",
         { index_size = 0 })
    end)
    return function() end
  end

  local env = {}
  for k, v in pairs(vim.fn.environ()) do
    if k ~= "CSEARCHINDEX" then
      table.insert(env, k .. "=" .. v)
    end
  end
  table.insert(env, "CSEARCHINDEX=" .. idx)

  local stderr = vim.loop.new_pipe(false)
  local stderr_buf = {}
  local handle
  local started = vim.loop.hrtime()
  local stopped = false

  local args = {}
  if mode == "reset" then
    table.insert(args, "-reset")
  end
  table.insert(args, "-files-from")
  table.insert(args, abs_list_path)
  -- Incremental only: vanished files leave the index in the same merge.
  if mode == "add" and opts.delete_list then vim.list_extend(args, { "-delete-from", opts.delete_list }) end

  handle = vim.loop.spawn(cindex, {
    args = args,
    env = env,
    stdio = { nil, nil, stderr },
  }, function(code)
    if stderr then pcall(stderr.close, stderr) end
    if handle then handle:close() end
    if stopped then return end
    local ms = math.floor((vim.loop.hrtime() - started) / 1e6)
    vim.schedule(function()
      if stopped then return end
      if code ~= 0 then
        cb(false, "cindex-uefilter exit=" .. code .. ": " .. table.concat(stderr_buf, ""), { ms = ms })
        return
      end
      local stat = usable_index_stat(idx)
      if not stat then
        cb(false, "cindex-uefilter completed but produced no usable csearch index at " .. idx, { ms = ms, index_size = 0 })
        return
      end
      cb(true, nil, {
        ms = ms,
        index_size = stat.size,
      })
    end)
  end)

  if not handle then
    if stderr then pcall(stderr.close, stderr) end
    vim.schedule(function() cb(false, "failed to spawn cindex-uefilter", {}) end)
    return function() end
  end

  stderr:read_start(function(_, data)
    if not stopped and data then table.insert(stderr_buf, data) end
  end)

  return function()
    if stopped then return end
    stopped = true
    if handle and not handle:is_closing() then
      pcall(handle.kill, handle, "sigterm")
    end
    if stderr and not stderr:is_closing() then
      pcall(stderr.read_stop, stderr)
    end
  end
end

return M
