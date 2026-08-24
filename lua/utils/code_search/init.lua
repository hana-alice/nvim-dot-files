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
--   require("utils.code_search").stream(ctx, pattern, opts, callbacks)
--       Spawn a search; callbacks = { on_line, on_done }.
--       on_line(file, lnum, col, text)
--       on_done(exit_code, err_msg | nil)
--       Returns a stop() function the caller can invoke to kill the proc.
--
-- opts: { code_only = bool, max_count = int, smart_case = bool,
--         regex = bool (default true; false = literal/fixed-string),
--         word  = bool (whole-word match, wraps pattern in \b...\b),
--         case  = bool (case-sensitive; nil/false = smart-case behavior),
--         ignore_case = bool (force case-insensitive unless case=true) }

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
local MIN_INDEX_SIZE = 1024

function M._reset_probe_cache()
  _csearch_path = nil
  _cindex_path = nil
end

local function csearch_exe()
  if _csearch_path then return _csearch_path end
  local candidates = {
    vim.fn.exepath("csearch"),
    vim.fn.exepath("csearch.exe"),
    vim.env.GOPATH and (vim.env.GOPATH .. (platform.is_windows and "\\bin\\csearch.exe" or "/bin/csearch")) or nil,
    vim.env.USERPROFILE and (vim.env.USERPROFILE .. "\\go\\bin\\csearch.exe") or nil,
    vim.env.HOME and (vim.env.HOME .. "/go/bin/csearch") or nil,
  }
  for _, c in ipairs(candidates) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      _csearch_path = c  -- cache success only
      return c
    end
  end
  return nil  -- do NOT cache the miss
end

function M.cindex_uefilter_exe()
  if _cindex_path then return _cindex_path end
  local candidates = {
    vim.fn.exepath("cindex-uefilter"),
    vim.fn.exepath("cindex-uefilter.exe"),
    vim.env.GOPATH and (vim.env.GOPATH .. (platform.is_windows and "\\bin\\cindex-uefilter.exe" or "/bin/cindex-uefilter")) or nil,
    vim.env.USERPROFILE and (vim.env.USERPROFILE .. "\\go\\bin\\cindex-uefilter.exe") or nil,
    vim.env.HOME and (vim.env.HOME .. "/go/bin/cindex-uefilter") or nil,
  }
  for _, c in ipairs(candidates) do
    if c and c ~= "" and vim.fn.executable(c) == 1 then
      _cindex_path = c  -- cache success only
      return c
    end
  end
  return nil  -- do NOT cache the miss
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
    local dir = vim.fn.fnamemodify(ctx.csearch_idx, ":h")
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    return ctx.csearch_idx
  end
  local root = ctx.workspace_root or ctx.root
  if not root or root == "" then
    return nil
  end
  local csearch_dir = root .. "/.cache/nvim-ue/csearch"
  if vim.fn.isdirectory(csearch_dir) == 0 then
    vim.fn.mkdir(csearch_dir, "p")
  end
  return csearch_dir .. "/csearch.idx"
end

local function usable_index_stat(path)
  local stat = path and vim.loop.fs_stat(path) or nil
  return stat and stat.size and stat.size > MIN_INDEX_SIZE and stat or nil
end

local function recover_staged_index(idx)
  if usable_index_stat(idx) then
    return true
  end

  for _, staged in ipairs({ idx .. "~~", idx .. "~" }) do
    if usable_index_stat(staged) then
      local cur = vim.loop.fs_stat(idx)
      if cur then
        pcall(vim.loop.fs_unlink, idx)
      end
      local ok = pcall(vim.loop.fs_rename, staged, idx)
      if ok and usable_index_stat(idx) then
        return true
      end
    end
  end

  return false
end

-- Check that a usable csearch index file exists for this workspace.
function M.is_indexed(ctx)
  if not csearch_exe() then return false end
  local idx = M.index_path(ctx)
  if not idx then return false end
  return recover_staged_index(idx)
end

M._recover_staged_index_for_test = recover_staged_index

-- Test seam: "is this index path usable?" (exists + above min size). Backs the
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
  local cs = csearch_exe()
  if not cs then
    callbacks.on_done(1, "csearch not found in PATH")
    return function() end
  end

  -- Keep the user's ORIGINAL untransformed text for column estimation
  -- below. Pattern rewrites (literal escape, \b wrap, (?i) prefix) only
  -- affect what we hand to csearch; column-finding still uses the raw
  -- needle, which is what actually appears in matched text.
  local raw_needle = pattern

  local args = { "-n" }
  -- csearch supports a SINGLE -f fileregexp; compose code_only + path_filter
  -- into one RE2 (see M._compose_file_regex). nil → no -f.
  local file_re = M._compose_file_regex(opts)
  if file_re then
    table.insert(args, "-f")
    table.insert(args, file_re)
  end

  -- Pattern rewrite pipeline. ORDER MATTERS: literal-escape first (so
  -- subsequent \b additions are not themselves escaped), then word-wrap,
  -- then case-flag injection.
  --
  -- regex defaults to TRUE (caller treats pattern as RE2). When false,
  -- the input is taken literally — every RE2 metachar is escaped. This
  -- is the fix for "\Pr" / "[1-9]" / "(foo|bar)" etc. silently exploding
  -- csearch's RE2 parser ("error parsing regexp: invalid character class
  -- range: `\Pr`"). Anything the user types is matched verbatim.
  local is_regex = opts.regex ~= false
  if not is_regex then
    pattern = escape_re2_literal(pattern)
  end

  if opts.word then
    pattern = "\\b" .. pattern .. "\\b"
  end

  -- Case sensitivity. opts.case=true → strict case-sensitive (no (?i)).
  -- opts.ignore_case=true → unconditional (?i), used by UE grep so
  -- camelCase queries like r.useLandscape still match r.UseLandscape...
  -- opts.case=nil/false without ignore_case keeps the legacy smart-case
  -- behavior (lowercase pattern ⇒ (?i)) for non-UE callers.
  local case_sensitive = opts.case == true
  if not case_sensitive and opts.ignore_case == true then
    pattern = "(?i)" .. pattern
  elseif not case_sensitive and opts.smart_case ~= false then
    -- Only inject (?i) when there's no uppercase in the ORIGINAL search
    -- text. After literal-escape "Foo.Bar" becomes "Foo\.Bar" which
    -- still has uppercase, so this still works correctly.
    if not pattern:match("%u") then
      pattern = "(?i)" .. pattern
    end
  end
  table.insert(args, pattern)

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local stderr_buf = {}
  local handle
  local closed = false
  local leftover = ""

  -- csearch uses CSEARCHINDEX env var. Pass per-workspace index.
  local env = {}
  for k, v in pairs(vim.fn.environ()) do
    if k ~= "CSEARCHINDEX" then
      table.insert(env, k .. "=" .. v)
    end
  end
  table.insert(env, "CSEARCHINDEX=" .. M.index_path(ctx))

  -- Stopped is set the moment the picker tells us to stop. From this
  -- point on we MUST NOT call any callback — the picker has marked its
  -- finder done and any further yield trips snacks' "yielded after done"
  -- bug-trap (which spams the user with red Snacks Picker Finder errors).
  local stopped = false

  local function safe_close()
    if closed then return end
    closed = true
    if stdout then pcall(stdout.read_stop, stdout) end
    if stderr then pcall(stderr.read_stop, stderr) end
    if stdout then pcall(stdout.close, stdout) end
    if stderr then pcall(stderr.close, stderr) end
  end

  local function safe_kill()
    if handle and not closed then
      pcall(handle.kill, handle, "sigterm")
    end
  end

  -- Pre-compile a Lua plain-find pattern for column estimation.
  -- Uses raw_needle (untransformed user text), not the post-rewrite
  -- pattern which may be \b-wrapped or backslash-escaped.
  local needle = raw_needle:lower()

  local emitted = 0
  local max_count = opts.max_count or 5000

  -- DELIVERY ORDERING (fix 2026-06-12 — "<leader>/ drops trailing hits"):
  -- We must guarantee on_done() fires STRICTLY AFTER every on_line() for this
  -- search. The old code did `vim.schedule(on_line)` per line AND
  -- `vim.schedule(on_done)` from the exit callback. libuv does not order the
  -- exit event after the final stdout-data event, and even when it does, the
  -- per-line schedules and the on_done schedule are independent queue entries
  -- whose relative order is not guaranteed — so on_done could run while the
  -- last few on_line callbacks were still queued. The ue.lua drain loop keys
  -- off on_done (done=true) to stop draining, so those late lines were never
  -- delivered → 2–4 trailing hits silently dropped.
  --
  -- Fix: parse lines SYNCHRONOUSLY in the read callback into `parsed` (no
  -- per-line schedule), and run a SINGLE scheduled flusher that (a) delivers
  -- all parsed-but-undelivered lines, then (b) calls on_done — but only once
  -- the process has exited. A flush is requested on every data chunk (to keep
  -- the picker streaming) and on exit; the flusher always drains the full
  -- backlog before signalling done, so no line can be stranded behind on_done.
  local parsed = {}        -- { {file,lnum,col,text}, ... } parsed, not yet delivered
  local delivered_idx = 0  -- high-water mark of parsed[] handed to on_line
  local proc_exited = false
  local exit_code = 0
  local exit_err = nil
  local flush_scheduled = false
  local done_called = false

  local function flush()
    flush_scheduled = false
    if stopped then return end
    -- Deliver every parsed line we haven't delivered yet.
    while delivered_idx < #parsed do
      delivered_idx = delivered_idx + 1
      local it = parsed[delivered_idx]
      if stopped then return end
      callbacks.on_line(it.file, it.lnum, it.col, it.text)
    end
    -- Only signal done after the process exited AND the full backlog is
    -- delivered. If more data is still arriving, proc_exited is false and we
    -- bail; the next flush (or the exit flush) will finish the job.
    if proc_exited and not done_called then
      done_called = true
      callbacks.on_done(exit_code, exit_err)
    end
  end

  local function request_flush()
    if flush_scheduled or stopped then return end
    flush_scheduled = true
    vim.schedule(flush)
  end

  handle = vim.loop.spawn(cs, {
    args = args,
    env = env,
    stdio = { nil, stdout, stderr },
  }, function(code)
    safe_close()
    if handle then handle:close() end
    if stopped then return end
    exit_code = code
    exit_err = code ~= 0 and table.concat(stderr_buf, "") or nil
    proc_exited = true
    -- Force a final flush even if one is already scheduled — the scheduled one
    -- may have run before proc_exited flipped, leaving done uncalled.
    flush_scheduled = true
    vim.schedule(flush)
  end)

  if not handle then
    safe_close()
    vim.schedule(function()
      if stopped then return end
      callbacks.on_done(1, "failed to spawn csearch")
    end)
    return function() stopped = true end
  end

  stdout:read_start(function(_, data)
    if stopped then return end
    if not data then return end
    leftover = leftover .. data
    while true do
      local nl = leftover:find("\n")
      if not nl then break end
      local line = leftover:sub(1, nl - 1):gsub("\r$", "")
      leftover = leftover:sub(nl + 1)
      if line ~= "" and emitted < max_count and not stopped then
        -- Format: <file>:<lnum>:<text>
        -- Files on Windows can start with C:\ — find the FIRST `:` AFTER
        -- the drive letter pair.
        local search_start = 1
        if line:sub(2, 2) == ":" then search_start = 3 end
        local file_end = line:find(":", search_start, true)
        if file_end then
          local file = line:sub(1, file_end - 1)
          local rest = line:sub(file_end + 1)
          local lnum_str, text = rest:match("^(%d+):(.*)$")
          if lnum_str and text then
            local lnum = tonumber(lnum_str) or 1
            local col = (text:lower():find(needle, 1, true) or 1)
            emitted = emitted + 1
            -- Parse synchronously; deliver via the single flusher. This keeps
            -- on_line strictly before on_done (see ordering note above).
            parsed[#parsed + 1] = { file = file, lnum = lnum, col = col, text = text }
          end
        end
      end
    end
    request_flush()
  end)
  stderr:read_start(function(_, data)
    if stopped then return end
    if data then table.insert(stderr_buf, data) end
  end)

  return function()
    -- Picker is done with us. Mark stopped FIRST so any in-flight
    -- vim.schedule callback short-circuits before touching the picker,
    -- THEN kill+close. Order matters: scheduled callbacks already on the
    -- main-loop queue would otherwise still call on_line.
    stopped = true
    safe_kill()
    safe_close()
  end
end

-- ── rg fallback ──────────────────────────────────────────────────────────

local function stream_rg(ctx, pattern, opts, callbacks)
  local rg = vim.fn.exepath("rg")
  if rg == "" then
    callbacks.on_done(1, "rg not found and no csearch index available")
    return function() end
  end

  local args = {
    "--color=never", "--no-heading", "--with-filename",
    "--line-number", "--column",
    "--max-columns=500", "-0",
    "-j", "32", "--mmap",
  }
  if opts.case == true then
    table.insert(args, "--case-sensitive")
  elseif opts.ignore_case == true then
    table.insert(args, "--ignore-case")
  else
    table.insert(args, "--smart-case")
  end
  for _, ex in ipairs(opts.exclude_dirs or {}) do
    table.insert(args, "-g"); table.insert(args, "!**/" .. ex .. "/**")
  end
  if opts.code_only then
    for _, ext in ipairs({ "cpp","c","cc","cxx","h","hpp","hh","hxx","inl",
                            "cs","usf","ush","hlsl","hlsli" }) do
      table.insert(args, "-g"); table.insert(args, "*." .. ext)
    end
  end
  table.insert(args, "--"); table.insert(args, pattern)
  for _, dir in ipairs(opts.search_dirs or {}) do
    table.insert(args, dir)
  end

  local stdout = vim.loop.new_pipe(false)
  local stderr = vim.loop.new_pipe(false)
  local stderr_buf = {}
  local handle
  local closed = false
  local leftover = ""
  local stopped = false

  local function safe_close()
    if closed then return end
    closed = true
    if stdout then pcall(stdout.read_stop, stdout) end
    if stderr then pcall(stderr.read_stop, stderr) end
    if stdout then pcall(stdout.close, stdout) end
    if stderr then pcall(stderr.close, stderr) end
  end

  local function safe_kill()
    if handle and not closed then
      pcall(handle.kill, handle, "sigterm")
    end
  end

  local emitted = 0
  local max_count = opts.max_count or 5000

  -- Same delivery-ordering fix as the csearch path: parse synchronously into
  -- `parsed`, deliver + signal on_done via a single flusher so on_done always
  -- runs after every on_line (no dropped trailing hits). All state declared
  -- BEFORE spawn so the exit callback can close over it.
  local parsed = {}
  local delivered_idx = 0
  local proc_exited = false
  local exit_code = 0
  local exit_err = nil
  local flush_scheduled = false
  local done_called = false

  local function flush()
    flush_scheduled = false
    if stopped then return end
    while delivered_idx < #parsed do
      delivered_idx = delivered_idx + 1
      local it = parsed[delivered_idx]
      if stopped then return end
      callbacks.on_line(it.file, it.lnum, it.col, it.text)
    end
    if proc_exited and not done_called then
      done_called = true
      callbacks.on_done(exit_code, exit_err)
    end
  end

  local function request_flush()
    if flush_scheduled or stopped then return end
    flush_scheduled = true
    vim.schedule(flush)
  end

  handle = vim.loop.spawn(rg, {
    args = args,
    cwd = ctx.workspace_root,
    stdio = { nil, stdout, stderr },
  }, function(code)
    safe_close()
    if handle then handle:close() end
    if stopped then return end
    exit_code = code
    exit_err = code ~= 0 and table.concat(stderr_buf, "") or nil
    proc_exited = true
    flush_scheduled = true
    vim.schedule(flush)
  end)

  if not handle then
    safe_close()
    vim.schedule(function()
      if stopped then return end
      callbacks.on_done(1, "failed to spawn rg")
    end)
    return function() stopped = true end
  end

  stdout:read_start(function(_, data)
    if stopped then return end
    if not data then return end
    leftover = leftover .. data
    while true do
      local nul = leftover:find("\0")
      if not nul then break end
      local rec = leftover:sub(1, nul - 1)
      -- After NUL comes "<lnum>:<col>:<text>\n"
      leftover = leftover:sub(nul + 1)
      local nl = leftover:find("\n")
      if not nl then
        -- Push the file part back; wait for more data.
        leftover = rec .. "\0" .. leftover
        break
      end
      local rest = leftover:sub(1, nl - 1):gsub("\r$", "")
      leftover = leftover:sub(nl + 1)
      local lnum_s, col_s, text = rest:match("^(%d+):(%d+):(.*)$")
      if lnum_s and col_s and text and emitted < max_count then
        emitted = emitted + 1
        parsed[#parsed + 1] = { file = rec, lnum = tonumber(lnum_s), col = tonumber(col_s), text = text }
      end
    end
    request_flush()
  end)
  stderr:read_start(function(_, data)
    if stopped then return end
    if data then table.insert(stderr_buf, data) end
  end)

  return function()
    stopped = true
    safe_kill()
    safe_close()
  end
end

-- ── Public dispatcher ────────────────────────────────────────────────────

function M.stream(ctx, pattern, opts, callbacks)
  opts = opts or {}
  callbacks = callbacks or {}
  if not callbacks.on_line then callbacks.on_line = function() end end
  if not callbacks.on_done then callbacks.on_done = function() end end

  if M.is_indexed(ctx) then
    return stream_csearch(ctx, pattern, opts, callbacks)
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
  local mode = opts.mode or "reset"
  local cindex = M.cindex_uefilter_exe()
  if not cindex then
    vim.schedule(function()
      cb(false,
         "cindex-uefilter not found. Build it via:\n" ..
         "  cd <nvim-config>/tools/cindex-uefilter && go install ./...",
         {})
    end)
    return function() end
  end

  local idx = M.index_path(ctx)

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
      recover_staged_index(idx)
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
