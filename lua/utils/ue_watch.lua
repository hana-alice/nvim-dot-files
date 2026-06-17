-- lua/utils/ue_watch.lua
-- ----------------------------------------------------------------------------
-- Incremental UE workspace index updater.
--
-- Watches the UE workspace tree with libuv fs_event and reacts to file
-- create/delete events by feeding the affected paths into the right index
-- subsystem (compile_commands.json, csearch trigram index, gtags shader DB).
--
-- Why this exists
--   :UEPrepare takes ~90s on a fresh tree (~2s with the FT_GTAGS shrink).
--   That's fine when the user explicitly asks for a refresh, but during
--   normal feature porting they create one .h + one .cpp and clangd reports
--   "file not in CDB" / csearch can't grep the new symbol / gtags fallback
--   misses the new shader. The user shouldn't have to re-run :UEPrepare for
--   every two-file delta.
--
-- Design constraints
--   * Coarse debounce (default 1500ms): git checkout / build can fire
--     hundreds of events per second; we want to batch them.
--   * Filetype gating: only react to extensions in M.WATCHED_EXTS — most of
--     the .uproject/.umap/.uasset noise is uninteresting and would spam
--     Hot Reload feedback loops.
--   * Per-source fan-out: a single delta may need to update CDB only,
--     csearch only, or both. The watcher decides; the providers are dumb.
--   * Idempotent providers: re-firing the same path is a no-op so we can be
--     liberal with retries.
--   * Never block UI: every disk operation goes through vim.system / vim.uv
--     async APIs (or code_search.build_index, itself async) and posts back via
--     vim.schedule. No provider may :wait() on the UI thread.
--   * Arbitrary-length path lists go to child processes via a -files-from temp
--     file, NEVER as argv elements — Windows' ~32 KiB command-line limit makes
--     argv fan-out (one path = one arg) overflow on big git-checkout/build
--     batches (ENAMETOOLONG). See provider_csearch_add.
--
-- Hard limits we accept (documented for future maintainers)
--   * codesearch can't delete a path from an index — see codesearch's Merge
--     bug. We mark removals as "stale" in state.json and the next
--     :UEPrepareReindex does the actual purge. Day-to-day this means stale
--     hits in csearch grep until the user reindexes; clangd and gtags are
--     authoritative for definitions so this is mostly cosmetic.
--   * libuv fs_event on Windows surfaces SMB/symlink/junction edge cases
--     differently than on Linux. We log unhandled events at DEBUG, never
--     ERROR, to keep the user's :messages clean.
--
-- Public API (called from ue.lua):
--   M.start(opts)   - opts = { root, csearch_index, cdb_path, gtags_db,
--                              shader_filelist, debounce_ms }
--   M.stop()
--   M.status()      - returns { running, pending_adds, pending_dels,
--                               last_event_at, watch_root }
-- ----------------------------------------------------------------------------

local uv = vim.uv or vim.loop
local M = {}

-- Forward declarations for helpers defined later in the file but referenced
-- earlier (Lua silently treats undeclared names as globals → nil at call time).
-- See skill `ue-lua-engine-only-maintenance` Pitfalls section: must be plain
-- assignment (`name = function(...)`) at the definition site, NOT
-- `local function name(...)` which creates a SECOND local that shadows this
-- forward-decl and leaves the upper closure bound to nil forever.
local add_to_persistent_dirty

-- ---------------------------------------------------------------------------
-- State
-- ---------------------------------------------------------------------------

local state = {
  handle = nil,
  opts = nil,
  pending_add = {},  -- normalized abs path -> true
  pending_del = {},  -- normalized abs path -> true
  timer = nil,
  last_event_at = 0,
  flush_running = false,
  -- Persistent dirty set (in-memory mirror of dirty.json on disk).
  -- Holds every add we've seen since the last :UEPrepare, even AFTER flush.
  -- WHY: cindex's modify-is-no-op bug means a flushed-into-csearch path may
  -- still have stale trigrams. The rg-on-dirty overlay needs the full
  -- post-prepare cumulative set, not just the in-flight pre-flush queue.
  -- Keys: lowercased forward-slash abs path. Values: true.
  persistent_dirty = {},
  persistent_dirty_loaded = false,
}

-- Files we care about. Anything else is dropped at the watcher boundary so
-- that a giant `git switch` over a content-heavy branch (.uasset / .umap
-- churn) doesn't keep the timer hot.
M.WATCHED_EXTS = {
  -- C/C++ for clangd CDB + csearch
  h = "code", hpp = "code", hh = "code", inl = "code", ipp = "code",
  c = "code", cc = "code", cpp = "code", cxx = "code", ["c++"] = "code",
  -- Shaders for gtags + csearch
  usf = "shader", ush = "shader",
  hlsl = "shader", hlsli = "shader",
}

-- Path classification is delegated to utils.ue_paths so the watcher and
-- the rg-on-dirty grep overlay agree on what counts as noise.
local ue_paths = require("utils.ue_paths")

-- Back-compat alias: callers (and tests) that read M.PATH_BLOCKLIST still
-- get the same logical list.
M.PATH_BLOCKLIST = ue_paths.BLOCKLIST_FRAGMENTS

local function path_blocked(abs_lower)
  return ue_paths.is_blocked(abs_lower)
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

local function norm(p)
  if not p or p == "" then return "" end
  p = p:gsub("\\", "/")
  return p
end

local function ext_of(path)
  local e = path:match("%.([^./\\]+)$")
  return e and e:lower() or ""
end

local function classify(path)
  local e = ext_of(path)
  return M.WATCHED_EXTS[e]
end

local function log_debug(msg)
  -- Use the rotating debug logger if available; otherwise silently drop.
  local ok, log = pcall(require, "utils.log")
  if ok and log.debug then log.debug("ue.watch", msg) end
end

local function log_info(msg)
  local ok, log = pcall(require, "utils.log")
  if ok and log.info then log.info("ue.watch", msg) end
end

local function log_warn(msg)
  local ok, log = pcall(require, "utils.log")
  if ok and log.notify_warn then
    log.notify_warn("ue.watch", msg)
  else
    vim.notify("[ue.watch] " .. msg, vim.log.levels.WARN)
  end
end

-- ---------------------------------------------------------------------------
-- Providers — each one is responsible for ONE index. They MUST be
-- idempotent (calling with an already-indexed path is a no-op) and MUST
-- never throw — return ok, err so the dispatcher can log without breaking
-- the rest of the pipeline.
-- ---------------------------------------------------------------------------

-- Provider: csearch index append (incremental).
--
-- Delegates to code_search.build_index(..., { mode = "add" }) — the SAME
-- vetted path :UEPrepareIncremental uses (introduced 2026-05-28). That helper:
--   * runs `cindex-uefilter -files-from <tempfile>` (NOT bare `cindex`):
--       - `cindex-uefilter` is the repo-wide canonical indexer (UE-path
--         filtering + the `-files-from` capability the fork exists for);
--       - `-files-from <tempfile>` is the ONLY correct way to feed an
--         arbitrary-length path list to a child process. Passing each path as
--         an argv element (the old impl did) blows Windows' ~32 KiB command-
--         line limit the instant a `git checkout` / build batches a few hundred
--         long UE paths into one flush → ENAMETOOLONG. argv length is an OS
--         contract, not a fixable upstream bug, so file-list input is the
--         permanent right answer here, not a workaround.
--   * is async (no `:wait()` on the UI thread — honours the never-block rule).
-- mode="add" drops `-reset` so the existing index is appended to, not rebuilt.
--
-- Failures are logged (not returned) because the call is fire-and-forget on the
-- scheduler; the cumulative persistent_dirty set + rg-on-dirty overlay already
-- cover any path that didn't make it into the trigram index this flush.
local function provider_csearch_add(paths)
  if #paths == 0 then return true end
  if not state.opts or not state.opts.csearch_index then
    return false, "no csearch_index configured"
  end
  local ok_cs, code_search = pcall(require, "utils.code_search")
  if not ok_cs or type(code_search.build_index) ~= "function" then
    return false, "utils.code_search.build_index unavailable"
  end
  if not code_search.cindex_uefilter_exe() then
    return false, "cindex-uefilter not found in PATH"
  end

  -- Write the dirty paths to a temp file fed via -files-from. Keeping it next
  -- to the index avoids cross-volume temp churn and self-documents intent.
  local list_path = state.opts.csearch_index .. ".incremental.txt"
  local fout, ferr = io.open(list_path, "w")
  if not fout then
    return false, "open incremental list: " .. (ferr or "?")
  end
  for _, p in ipairs(paths) do fout:write(p, "\n") end
  fout:close()

  -- build_index keys its index off ctx.csearch_idx (single source of truth in
  -- ue.lua's cache layout); pass the watcher's configured index path verbatim.
  local cs_ctx = { csearch_idx = state.opts.csearch_index }
  code_search.build_index(cs_ctx, list_path, function(ok_add, err_add, stats)
    pcall(os.remove, list_path)
    if ok_add then
      log_info(("csearch +%d files in %dms"):format(#paths, (stats and stats.ms) or 0))
    else
      log_warn("csearch_add: " .. tostring(err_add or "?"))
    end
  end, { mode = "add" })

  return true
end

-- Provider: csearch deletion → record-only (codesearch can't delete).
-- Persists the path list to <csearch_index>.stale so :UEPrepareReindex can
-- consume it. Never modifies the live index.
local function provider_csearch_mark_stale(paths)
  if #paths == 0 then return true end
  if not state.opts or not state.opts.csearch_index then
    return false, "no csearch_index configured"
  end
  local stale_file = state.opts.csearch_index .. ".stale"
  -- Append; leave dedup to the consumer. Crash-safety: open in append mode
  -- so a partial write is recoverable as truncation, not corruption.
  local f, err = io.open(stale_file, "a")
  if not f then return false, "open stale file: " .. (err or "?") end
  for _, p in ipairs(paths) do
    f:write(p, "\n")
  end
  f:close()
  return true
end

-- Provider: clangd CDB injection — relies on ue.lua already implementing
-- :UEAddFile semantics (entry synthesis + clangd LSP didChangeWatchedFiles).
-- We delegate via a soft require so this module stays usable in isolation.
local function provider_cdb_add(paths)
  if #paths == 0 then return true end
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.cdb_inject_paths) ~= "function" then
    -- Not a fatal — clangd will catch up on the next :UEPrepare. Log and
    -- skip so we don't block the csearch update.
    log_debug("cdb_inject_paths not implemented yet; skipping " .. #paths .. " adds")
    return true
  end
  return ue.cdb_inject_paths(paths)
end

local function provider_cdb_remove(paths)
  if #paths == 0 then return true end
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.cdb_remove_paths) ~= "function" then
    log_debug("cdb_remove_paths not implemented yet; skipping " .. #paths .. " dels")
    return true
  end
  return ue.cdb_remove_paths(paths)
end

-- Provider: gtags shader DB — only matters if any of the deltas is a
-- shader. Cheapest correct strategy is to rebuild the shader subset from
-- shader_filelist (1.1s for 1500 shaders), because gtags --single-update
-- requires the file to already be in the DB.
local function provider_gtags_shader_rebuild(paths)
  -- Filter to shaders only — adds for .h shouldn't trigger this.
  local has_shader = false
  for _, p in ipairs(paths) do
    if classify(p) == "shader" then has_shader = true break end
  end
  if not has_shader then return true end
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.gtags_rebuild_shaders) ~= "function" then
    log_debug("gtags_rebuild_shaders not implemented yet; skipping shader rebuild")
    return true
  end
  return ue.gtags_rebuild_shaders()
end

-- ---------------------------------------------------------------------------
-- Dispatcher — runs on the debounce timer.
-- ---------------------------------------------------------------------------

local function flush()
  if state.flush_running then
    -- Re-arm so we don't lose work that arrived during the previous flush.
    if state.timer then
      state.timer:start(state.opts.debounce_ms or 1500, 0, vim.schedule_wrap(flush))
    end
    return
  end
  state.flush_running = true

  -- Snapshot + clear pending so new events during the flush queue cleanly.
  local adds, dels = {}, {}
  for p in pairs(state.pending_add) do
    if not state.pending_del[p] then table.insert(adds, p) end
  end
  for p in pairs(state.pending_del) do
    if not state.pending_add[p] then table.insert(dels, p) end
  end
  state.pending_add = {}
  state.pending_del = {}

  if #adds == 0 and #dels == 0 then
    state.flush_running = false
    return
  end

  log_info(("flush: +%d -%d"):format(#adds, #dels))

  -- Fan out. Order: CDB first (so clangd has the file before csearch hits
  -- might race-trigger a goto), then csearch, then gtags shaders.
  local function step(who, fn, args)
    local ok, err = fn(args)
    if not ok then log_warn(who .. ": " .. tostring(err or "?")) end
  end
  step("cdb_add", provider_cdb_add, adds)
  step("cdb_remove", provider_cdb_remove, dels)
  step("csearch_add", provider_csearch_add, adds)
  step("csearch_mark_stale", provider_csearch_mark_stale, dels)
  step("gtags_shader", provider_gtags_shader_rebuild,
    vim.list_extend(vim.list_extend({}, adds), dels))

  -- Track adds in the cumulative dirty set so the rg-on-dirty overlay can
  -- compensate for cindex's modify-no-op bug (see persistent_dirty docs).
  -- Even successful flushes get tracked: csearch *will* skip any path that
  -- was already in the index regardless of mtime, so we stay paranoid until
  -- the next :UEPrepare clears the set.
  add_to_persistent_dirty(adds)

  state.flush_running = false
end

local function schedule_flush()
  state.last_event_at = uv.now()
  if state.timer then
    state.timer:stop()
    state.timer:start(state.opts.debounce_ms or 1500, 0, vim.schedule_wrap(flush))
  end
end

-- ---------------------------------------------------------------------------
-- Event handler
-- ---------------------------------------------------------------------------

local function on_event(err, filename, events)
  if err then
    log_debug("fs_event err: " .. tostring(err))
    return
  end
  if not filename or filename == "" then return end

  local abs = norm(state.opts.root .. "/" .. filename)
  local kind = classify(abs)
  if not kind then return end
  if path_blocked(abs:lower()) then
    log_debug("blocked path: " .. abs)
    return
  end

  -- libuv conflates create/modify/delete on Windows. We must stat to
  -- disambiguate. stat is cheap (fs metadata cache hot).
  local st = uv.fs_stat(abs)
  if st then
    -- Exists → treat as add (idempotent providers handle "already indexed").
    state.pending_add[abs] = true
  else
    state.pending_del[abs] = true
  end
  schedule_flush()
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

function M.start(opts)
  opts = opts or {}
  if not opts.root or opts.root == "" then
    log_warn("start: missing opts.root")
    return false
  end
  if state.handle then M.stop() end

  state.opts = vim.tbl_extend("force", { debounce_ms = 1500 }, opts)
  state.handle = uv.new_fs_event()
  if not state.handle then
    log_warn("start: uv.new_fs_event() returned nil")
    return false
  end
  state.timer = uv.new_timer()

  -- recursive=true is a no-op on Linux but mandatory on Windows (UE tree
  -- has thousands of subdirs; one watch per subdir would exhaust handles).
  local ok, start_err = pcall(state.handle.start, state.handle, opts.root, {
    watch_entry = false,
    stat = false,
    recursive = true,
  }, vim.schedule_wrap(on_event))
  if not ok then
    log_warn("start: " .. tostring(start_err))
    M.stop()
    return false
  end
  log_info("watching " .. opts.root)
  return true
end

function M.stop()
  if state.timer then
    state.timer:stop()
    state.timer:close()
    state.timer = nil
  end
  if state.handle then
    state.handle:stop()
    state.handle:close()
    state.handle = nil
  end
  state.pending_add = {}
  state.pending_del = {}
  state.flush_running = false
end

function M.status()
  local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
  end
  return {
    running = state.handle ~= nil,
    pending_adds = count(state.pending_add),
    pending_dels = count(state.pending_del),
    last_event_at = state.last_event_at,
    watch_root = state.opts and state.opts.root or nil,
  }
end

function M.flush_now()
  -- Test/debug helper: bypass the debounce timer.
  if state.timer then state.timer:stop() end
  vim.schedule(flush)
end

-- ---------------------------------------------------------------------------
-- Persistent dirty.json — cumulative add-set since last :UEPrepare.
-- ---------------------------------------------------------------------------

local PERSISTENT_DIRTY_CAP = 1000  -- LRU-ish hard cap; see save_persistent_dirty
local PERSISTENT_DIRTY_WARN = 500  -- nag threshold

local function persistent_dirty_path()
  return state.opts and state.opts.dirty_json_path or nil
end

local function load_persistent_dirty()
  if state.persistent_dirty_loaded then return end
  state.persistent_dirty_loaded = true
  local p = persistent_dirty_path()
  if not p then return end
  local fd, _ = io.open(p, "r")
  if not fd then return end
  local content = fd:read("*a")
  fd:close()
  if not content or content == "" then return end
  -- Two formats accepted:
  --   1) JSON array of paths (preferred for atomic write/read)
  --   2) Newline-separated paths (back-compat / hand-edit friendly)
  local ok, decoded = pcall(vim.json.decode, content)
  if ok and type(decoded) == "table" then
    for _, abs in ipairs(decoded) do
      if type(abs) == "string" and abs ~= "" then
        state.persistent_dirty[abs:lower()] = abs
      end
    end
  else
    for line in content:gmatch("[^\r\n]+") do
      state.persistent_dirty[line:lower()] = line
    end
  end
end

local function save_persistent_dirty()
  local p = persistent_dirty_path()
  if not p then return end
  -- Build sorted array (deterministic ordering -> no spurious git diffs if
  -- somebody ever puts this file under VCS for debugging).
  local arr = {}
  for _, abs in pairs(state.persistent_dirty) do arr[#arr + 1] = abs end
  table.sort(arr)
  -- Cap: drop oldest entries (= lex-smallest after sort, which is *not* truly
  -- LRU but close enough — UE paths share long prefixes so lex-sort is
  -- file-locality-friendly). Re-prepare resets this anyway.
  if #arr > PERSISTENT_DIRTY_CAP then
    local trimmed = {}
    local start = #arr - PERSISTENT_DIRTY_CAP + 1
    for i = start, #arr do trimmed[#trimmed + 1] = arr[i] end
    arr = trimmed
    -- Rebuild in-memory set from the cap to keep the two views in sync.
    state.persistent_dirty = {}
    for _, abs in ipairs(arr) do state.persistent_dirty[abs:lower()] = abs end
  end
  -- Atomic write: tmp + rename.
  local dir = vim.fn.fnamemodify(p, ":h")
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  local tmp = p .. ".tmp"
  local fd, err = io.open(tmp, "w")
  if not fd then
    log_debug("save dirty.json open failed: " .. tostring(err))
    return
  end
  fd:write(vim.json.encode(arr))
  fd:close()
  local ok, rename_err = vim.uv.fs_rename(tmp, p)
  if not ok then log_debug("save dirty.json rename failed: " .. tostring(rename_err)) end
  -- Nag once per crossing — caller can debounce externally if needed.
  if #arr >= PERSISTENT_DIRTY_WARN and not state._warned_dirty_high then
    state._warned_dirty_high = true
    vim.schedule(function()
      vim.notify(("[ue.watch] %d files dirty since last :UEPrepare. Consider :UEPrepareReindex."):format(#arr),
        vim.log.levels.INFO)
    end)
  end
end

add_to_persistent_dirty = function(paths)
  if #paths == 0 then return end
  load_persistent_dirty()
  local changed = false
  for _, abs in ipairs(paths) do
    local k = abs:lower()
    if not state.persistent_dirty[k] then
      state.persistent_dirty[k] = abs
      changed = true
    end
  end
  if changed then save_persistent_dirty() end
end

-- Public API: snapshot the cumulative dirty set.
-- Returns array of abs paths (forward-slash). Empty when no path configured /
-- file missing / cleared.
function M.snapshot_persistent_dirty()
  load_persistent_dirty()
  local arr = {}
  for _, abs in pairs(state.persistent_dirty) do arr[#arr + 1] = abs end
  return arr
end

-- Public API: clear the dirty set. Called from :UEPrepare on success.
-- 'reason' is logged for debugging — pass "prepare" / "reindex" / "manual".
function M.clear_persistent_dirty(reason)
  state.persistent_dirty = {}
  state.persistent_dirty_loaded = true
  state._warned_dirty_high = false
  local p = persistent_dirty_path()
  if p then
    -- Empty array, atomic write.
    local dir = vim.fn.fnamemodify(p, ":h")
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    local tmp = p .. ".tmp"
    local fd = io.open(tmp, "w")
    if fd then
      fd:write("[]")
      fd:close()
      vim.uv.fs_rename(tmp, p)
    end
  end
  log_info(("persistent_dirty cleared (reason=%s)"):format(reason or "?"))
end

-- Public API: stats for :UEDirtyStatus.
function M.persistent_dirty_status()
  load_persistent_dirty()
  local n = 0
  for _ in pairs(state.persistent_dirty) do n = n + 1 end
  return {
    count = n,
    path = persistent_dirty_path(),
    cap = PERSISTENT_DIRTY_CAP,
    warn_at = PERSISTENT_DIRTY_WARN,
  }
end

-- Snapshot the pending add/del sets as plain arrays of absolute paths.
-- Used by the rg-on-dirty grep overlay so it can treat "files the watcher
-- saw but haven't been re-indexed yet" as part of the dirty set.
--
-- Returns { adds = { path1, path2, ... }, dels = { ... } }. Empty arrays
-- when watcher isn't running / no pending events. NEVER touches the
-- internal sets so calling this is safe from any thread / scheduler ctx.
function M.snapshot_pending()
  local adds, dels = {}, {}
  if state.pending_add then
    for p in pairs(state.pending_add) do adds[#adds + 1] = p end
  end
  if state.pending_del then
    for p in pairs(state.pending_del) do dels[#dels + 1] = p end
  end
  return { adds = adds, dels = dels }
end

-- Test seam: expose the csearch-add provider so the regression can drive it
-- with a stubbed code_search backend and assert it routes through
-- build_index{mode="add"} (i.e. -files-from temp file, never argv fan-out).
-- Not part of the runtime API — providers stay "dumb" and the dispatcher owns
-- ordering; this is purely for headless verification.
M._provider_csearch_add_for_test = provider_csearch_add
M._set_opts_for_test = function(opts) state.opts = opts end

return M
