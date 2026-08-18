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
--     async APIs and posts back via vim.schedule. No provider may :wait() on
--     the UI thread.
--   * csearch index is SINGLE-WRITER: this watcher MUST NOT write csearch.idx.
--     It only records adds into the persistent dirty set (bookkeeper, not
--     indexer). csearch index writing is owned exclusively by the user-initiated
--     prepare family. cindex hardcodes its staged path as `<idx>~`, so a second
--     concurrent writer corrupts the index in the merge/rename window
--     (`corrupt index: remove` + 0-byte death loop, 2026-06-17). New files stay
--     visible between prepares via persistent_dirty + the rg-on-dirty overlay.
--     See grep-cache-invalidation.md D9 + CONSTRAINTS K31g; a behavioral test
--     guards against re-adding a csearch writer here.
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
local file_lock = require("ue.file_lock")

-- Defined later via assignment so earlier closures bind this local rather than a
-- shadowing declaration (an undeclared name would instead resolve as a global).
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
  -- WHY: the watcher is record-only and never publishes csearch updates.
  -- The rg-on-dirty overlay therefore needs the full post-prepare cumulative
  -- set, not just the in-flight pre-flush queue.
  -- Keys: lowercased forward-slash abs path. Values: true.
  persistent_dirty = {},
  persistent_dirty_loaded = false,
  -- Content anchor for Windows fs_event noise suppression. libuv subscribes
  -- LAST_ACCESS / ATTRIBUTES / SECURITY as well as LAST_WRITE, then exposes
  -- all of them as the same `change` flag. An existing file whose content
  -- mtime is not newer than the current csearch index cannot contain a
  -- post-index edit, so that event must not enter the live dirty overlay.
  csearch_index_mtime = nil,
  csearch_index_checked_at = 0,
  ignored_preindex_changes = 0,
  dirty_save_retry = nil,
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

local function mtime_parts(value)
  local mtime = value and (value.mtime or value) or nil
  if type(mtime) ~= "table" or type(mtime.sec) ~= "number" then return nil end
  return mtime.sec, tonumber(mtime.nsec) or 0
end

local function mtime_is_after(file_stat, index_mtime)
  local file_sec, file_nsec = mtime_parts(file_stat)
  local index_sec, index_nsec = mtime_parts(index_mtime)
  if not file_sec or not index_sec then return nil end
  if file_sec ~= index_sec then return file_sec > index_sec end
  return file_nsec > index_nsec
end

-- On Windows, libuv maps content, last-access, attribute and security updates
-- to the same UV_CHANGE flag. Keep rename events unconditionally so a newly
-- created file with a preserved old timestamp is never lost. For an existing
-- change, the csearch index mtime is a direct content anchor: if the file's
-- LAST_WRITE is older/equal, the reported event did not introduce content
-- after that index. Missing evidence stays conservative and records the file.
local function should_track_existing_event(file_stat, events, index_mtime)
  if not events or events.rename or not events.change then return true end
  if not index_mtime then return true end
  local after = mtime_is_after(file_stat, index_mtime)
  if after == nil then return true end
  return after
end

local function refresh_csearch_index_mtime()
  local path = state.opts and state.opts.csearch_index or nil
  local stat = path and uv.fs_stat(path) or nil
  state.csearch_index_mtime = stat and stat.mtime or nil
  state.csearch_index_checked_at = uv.now()
end

local function refresh_csearch_index_mtime_if_stale()
  if uv.now() - (state.csearch_index_checked_at or 0) >= 2000 then
    refresh_csearch_index_mtime()
  end
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

-- Provider: csearch index — RECORD-ONLY (the watcher is a bookkeeper, not an
-- indexer). See grep-cache-invalidation.md D9 + CONSTRAINTS K31g.
--
-- The watcher MUST NOT write csearch.idx. cindex's atomic-write protocol hard-
-- codes the staged sibling path as `<idx>~`, so a watcher-driven incremental
-- build and a user-driven `:UEPrepare` full build race the SAME `idx~` and
-- corrupt each other in the merge/rename window — the symptom that retired this
-- writer was `corrupt index: remove` + a 0-byte idx death loop (2026-06-17).
--
-- Why record-only is sufficient: csearch index writing has exactly one owner,
-- the user-initiated prepare family (`:UEPrepare` / `:UEPrepareReindex` /
-- `:UEPrepareIncremental`). New files stay visible BETWEEN prepares via the
-- cumulative `persistent_dirty` set + the rg-on-dirty grep overlay — that
-- bookkeeping (add_to_persistent_dirty, called by flush()) is the watcher's
-- whole job here. Recognising new content only at the next manual prepare is a
-- deliberate, accepted tradeoff (the auto-incremental writer was never load-
-- bearing; it bought a narrow window at the cost of a permanent concurrent-write
-- hazard). Do NOT re-add a build_index / cindex call here — a behavioral test
-- guards against it.
local function provider_csearch_add(paths)
  -- Intentionally a no-op beyond bookkeeping: flush() records `paths` into the
  -- persistent dirty set separately (add_to_persistent_dirty). This provider
  -- exists so the dispatcher fan-out shape stays stable, but it writes nothing.
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
  local lease, lock_err = file_lock.acquire(stale_file .. ".lock")
  if not lease then return false, "stale-file writer busy: " .. tostring(lock_err) end
  -- Append one buffered chunk under a cross-process lease; leave dedup to the
  -- consumer. A watcher in another Neovim cannot interleave partial lines.
  local f, err = io.open(stale_file, "a")
  if not f then
    file_lock.release(lease)
    return false, "open stale file: " .. (err or "?")
  end
  f:write(table.concat(paths, "\n"), "\n")
  f:close()
  file_lock.release(lease)
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
  -- might race-trigger a goto), then csearch (record-only no-op — see D9),
  -- then gtags shaders.
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

  -- Track adds in the cumulative dirty set. This — NOT a csearch write — is how
  -- new files stay greppable between manual :UEPrepare runs: the rg-on-dirty
  -- overlay reads this set. The watcher is a bookkeeper here, never an indexer
  -- (D9). The set is cleared by :UEPrepare* on success.
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
  -- Refresh the index anchor at most once per debounce window so a build from
  -- another nvim process is observed without adding one stat per file event.
  refresh_csearch_index_mtime_if_stale()
  local st = uv.fs_stat(abs)
  if st then
    if not should_track_existing_event(st, events, state.csearch_index_mtime) then
      state.ignored_preindex_changes = state.ignored_preindex_changes + 1
      return
    end
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
  state.ignored_preindex_changes = 0
  refresh_csearch_index_mtime()
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
    ignored_preindex_changes = state.ignored_preindex_changes,
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

local function merge_persistent_dirty_from_disk(p)
  local fd = io.open(p, "rb")
  if not fd then return end
  local content = fd:read("*a")
  fd:close()
  local ok, decoded = pcall(vim.json.decode, content or "")
  if ok and type(decoded) == "table" then
    for _, abs in ipairs(decoded) do
      if type(abs) == "string" and abs ~= "" then
        state.persistent_dirty[abs:lower()] = abs
      end
    end
  end
end

local function save_persistent_dirty()
  local p = persistent_dirty_path()
  if not p then return end
  local lease = file_lock.acquire(p .. ".lock")
  if not lease then
    if not state.dirty_save_retry then
      state.dirty_save_retry = vim.defer_fn(function()
        state.dirty_save_retry = nil
        save_persistent_dirty()
      end, 25)
    end
    return
  end
  -- The in-memory set may have been loaded before another Neovim wrote its
  -- changes. Re-read under the lease and union before publishing.
  merge_persistent_dirty_from_disk(p)
  -- Build sorted array (deterministic ordering -> no spurious git diffs if
  -- somebody ever puts this file under VCS for debugging).
  local arr = {}
  for _, abs in pairs(state.persistent_dirty) do arr[#arr + 1] = abs end
  table.sort(arr)
  -- Cap: drop oldest entries (= lex-smallest after sort, which is *not* truly
  -- LRU but close enough — UE paths share long prefixes so lex-sort is
  -- file-locality-friendly). Re-prepare resets this anyway.
  --
  -- F2 (health-check 2026-07): a cap hit means the overlay is now LOSSY —
  -- freshness may claim files greppable that were silently dropped. This
  -- MUST be loud (WARN, once per session until cleared), and the status()
  -- surface exposes `capped` so :UEWatchStatus / pickers can see it.
  -- Observed real flood: a bulk git operation dirtied 1000+ ThirdParty
  -- test files (openexr/zlib) in one shot; the set stayed pinned at cap
  -- with zero indication anywhere.
  if #arr > PERSISTENT_DIRTY_CAP then
    local dropped = #arr - PERSISTENT_DIRTY_CAP
    local trimmed = {}
    local start = dropped + 1
    for i = start, #arr do trimmed[#trimmed + 1] = arr[i] end
    arr = trimmed
    -- Rebuild in-memory set from the cap to keep the two views in sync.
    state.persistent_dirty = {}
    for _, abs in ipairs(arr) do state.persistent_dirty[abs:lower()] = abs end
    state._dirty_capped = true
    if not state._warned_dirty_capped then
      state._warned_dirty_capped = true
      -- Probe: cap-hit is the F2 signal the next session reads first.
      pcall(function()
        require("utils.probe").record("dirty-set-flood", "cap-hit",
          { dropped = dropped, cap = PERSISTENT_DIRTY_CAP })
      end)
      vim.schedule(function()
        log_warn(("dirty set hit cap=%d — %d oldest entries DROPPED; grep overlay is now lossy. "
          .. "Run :UEPrepare (or :UEPrepareIncremental) to reindex and reset.")
          :format(PERSISTENT_DIRTY_CAP, dropped))
      end)
    end
  end
  -- Atomic write: tmp + rename.
  local dir = vim.fn.fnamemodify(p, ":h")
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  local tmp = p .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local fd, err = io.open(tmp, "w")
  if not fd then
    file_lock.release(lease)
    log_debug("save dirty.json open failed: " .. tostring(err))
    return
  end
  fd:write(vim.json.encode(arr))
  fd:close()
  local ok, rename_err = vim.uv.fs_rename(tmp, p)
  if not ok then
    pcall(vim.fn.delete, tmp)
    log_debug("save dirty.json rename failed: " .. tostring(rename_err))
  end
  file_lock.release(lease)
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
  local p = persistent_dirty_path()
  if p then merge_persistent_dirty_from_disk(p) end
  local arr = {}
  for _, abs in pairs(state.persistent_dirty) do arr[#arr + 1] = abs end
  return arr
end

-- Remove only paths proven covered by a completed index operation. Re-read
-- and subtract under the same lease used by writers so dirty paths added by a
-- different Neovim while the build was running remain visible.
function M.remove_persistent_dirty(paths, reason, covered_before, remove_missing)
  local remove = {}
  for _, path in ipairs(paths or {}) do
    local normalized = tostring(path)
    local covered = true
    if covered_before then
      local stat = vim.uv.fs_stat(normalized)
      local modified_at = stat and stat.mtime and tonumber(stat.mtime.sec) or nil
      -- Missing/deleted files and files changed during the build stay dirty.
      -- A one-second equality is kept conservatively because os.time() has
      -- coarser resolution than filesystem mtimes on supported hosts.
      covered = (modified_at ~= nil and modified_at < covered_before)
        or (modified_at == nil and remove_missing == true)
    end
    if covered then remove[normalized:lower()] = true end
  end
  if not next(remove) then return true end
  local p = persistent_dirty_path()
  if not p then
    for key in pairs(remove) do state.persistent_dirty[key] = nil end
    return true
  end

  local lease, lock_err = file_lock.acquire(p .. ".lock")
  if not lease then
    log_warn("dirty.json remains conservative; another Neovim owns it: " .. tostring(lock_err))
    return false
  end
  merge_persistent_dirty_from_disk(p)
  for key in pairs(remove) do state.persistent_dirty[key] = nil end
  local arr = {}
  for _, abs in pairs(state.persistent_dirty) do arr[#arr + 1] = abs end
  table.sort(arr)

  local tmp = p .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local fd = io.open(tmp, "w")
  if not fd then
    file_lock.release(lease)
    return false
  end
  fd:write(vim.json.encode(arr))
  fd:close()
  local replaced = vim.uv.fs_rename(tmp, p)
  if not replaced then pcall(vim.fn.delete, tmp) end
  file_lock.release(lease)
  if not replaced then return false end
  state.persistent_dirty_loaded = true
  log_info(("persistent_dirty removed covered paths (reason=%s, remaining=%d)"):format(
    reason or "?", #arr))
  return true
end

-- Public API: clear the dirty set. Called from :UEPrepare on success.
-- 'reason' is logged for debugging — pass "prepare" / "reindex" / "manual".
function M.clear_persistent_dirty(reason)
  local p = persistent_dirty_path()
  if p then
    -- Empty array, serialized and atomically replaced. The prepare-family
    -- writer lease ensures only one index publication performs this reset.
    local dir = vim.fn.fnamemodify(p, ":h")
    if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
    local lease, lock_err = file_lock.acquire(p .. ".lock")
    if lease then
      local tmp = p .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
      local fd = io.open(tmp, "w")
      if not fd then
        file_lock.release(lease)
        log_warn("cannot create dirty.json reset file: " .. tmp)
        return false
      end
      fd:write("[]")
      fd:close()
      local replaced, replace_err = vim.uv.fs_rename(tmp, p)
      if not replaced then pcall(vim.fn.delete, tmp) end
      file_lock.release(lease)
      if not replaced then
        log_warn("cannot reset dirty.json: " .. tostring(replace_err))
        return false
      end
    else
      log_warn("dirty.json remains conservative; another Neovim owns it: " .. tostring(lock_err))
      return false
    end
  end
  state.persistent_dirty = {}
  state.persistent_dirty_loaded = true
  state._warned_dirty_high = false
  state._warned_dirty_capped = false
  state._dirty_capped = false
  -- A successful prepare calls this after the new index is installed. Advance
  -- the change-event anchor so queued/pre-index metadata notifications cannot
  -- immediately repopulate the set that was just cleared.
  refresh_csearch_index_mtime()
  log_info(("persistent_dirty cleared (reason=%s)"):format(reason or "?"))
  return true
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
    -- F2: true once the cap has trimmed entries since the last clear —
    -- the overlay is LOSSY until the next successful :UEPrepare.
    capped = state._dirty_capped or false,
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

-- Test seam: expose the csearch-add provider so the regression can assert it is
-- RECORD-ONLY — it must never call code_search.build_index / write csearch.idx
-- (D9 single-writer invariant; guards against re-introducing a second writer).
M._provider_csearch_add_for_test = provider_csearch_add
M._set_opts_for_test = function(opts) state.opts = opts end

-- Test seam: seed the in-memory persistent dirty set without a real fs_event,
-- so D-3b tests can verify clear_persistent_dirty zeroes it. Marks it loaded so
-- a later count read doesn't lazy-load over the top.
M._seed_persistent_dirty_for_test = function(paths)
  state.persistent_dirty_loaded = true
  state.persistent_dirty = {}
  for _, p in ipairs(paths or {}) do state.persistent_dirty[tostring(p):lower()] = p end
end

-- Test seam (F2): run the save path (cap trim + capped flag) on the current
-- in-memory set without needing a real dirty_json_path write target.
M._save_persistent_dirty_for_test = function()
  save_persistent_dirty()
end
M._should_track_existing_event_for_test = should_track_existing_event

return M
