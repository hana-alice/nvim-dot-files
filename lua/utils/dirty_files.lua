-- lua/utils/dirty_files.lua
-- ----------------------------------------------------------------------------
-- Collect the "dirty" file set for the rg-on-dirty grep overlay.
--
-- WHY this exists:
--   Google codesearch's `cindex` deduplicates by path key and SKIPS already-
--   indexed files even when their mtime is newer (proven via /c/temp/
--   csearch_modify_test/ POC, see memories). That means when the user
--   adds a class to MyFile.h and immediately tries `<leader>/MyNewClass`,
--   csearch returns 0 hits — the trigrams for the new code aren't in
--   the index yet, and append-mode cindex won't fix that.
--
--   Workaround ε: csearch (potentially-stale, whole-tree) PLUS a parallel
--   rg pass over JUST the dirty files. This module is the "JUST the dirty
--   files" half — three sources merged, deduped, filtered.
--
-- THREE SOURCES (v2, post 2026-04-27 — git source removed):
--   1. nvim modified buffers      — typed-but-unsaved (catches "in-flight"
--                                    edits before :w even fires fs_event)
--   2. ue_watch pending_add       — fs_event saw it, debounce timer hasn't
--                                    flushed yet, csearch hasn't ingested it
--   3. ue_watch persistent_dirty  — cumulative add-set since last :UEPrepare,
--                                    persisted to .cache/.../runtime/dirty.json
--                                    so it survives nvim restarts. THIS IS
--                                    THE ONE THAT MATTERS for the cindex
--                                    modify-no-op bug.
--
-- WHY git was removed:
--   `git status --porcelain` on the UE tree is 195-200ms (warm fs cache).
--   `<leader>/` runs the finder with live=true, so EVERY keystroke would
--   pay that cost. Worse, git status doesn't actually answer the right
--   question — it tells you "things uncommitted right now", but the cindex
--   modify-no-op affects "things modified since the last cindex -reset",
--   which is anchored on :UEPrepare, NOT on commits. The new dirty.json
--   tracks the right anchor.
--
-- DEDUPE KEY: forward-slash + lowercase absolute path. Windows is case-
-- insensitive on disk so "Foo.h" and "foo.h" must collapse to one entry,
-- otherwise rg gets duplicate file args and emits duplicate matches.
--
-- FILTERING: utils.ue_paths.is_searchable — same blocklist the watcher
-- uses (Intermediate/Build/Saved/.generated.h/.gen.cpp/...).
--
-- LIMITS:
--   * Windows command line cap is ~32K — we truncate to opts.max_files
--     (default 500) and log a notify if we hit the cap.
-- ----------------------------------------------------------------------------

local ue_paths = require("utils.ue_paths")

local M = {}

M.DEFAULT_MAX_FILES = 500

local function norm_abs(path)
  if not path or path == "" then return nil end
  local abs = vim.fn.fnamemodify(path, ":p")
  if not abs or abs == "" then return nil end
  abs = abs:gsub("\\", "/")
  abs = abs:gsub("/$", "")
  return abs
end

local function key_of(abs_path)
  if not abs_path then return nil end
  return abs_path:lower()
end

-- ── Source 1: nvim modified buffers ─────────────────────────────────────
local function buffer_dirty()
  local files = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf)
        and vim.bo[buf].modified
        and vim.bo[buf].buftype == "" then
      local name = vim.api.nvim_buf_get_name(buf)
      local abs = norm_abs(name)
      if abs then files[#files + 1] = abs end
    end
  end
  return files
end

-- ── Source 2: watcher pending_add ───────────────────────────────────────
-- In-flight: fs_event saw it, debounce hasn't fired yet.
local function watcher_pending()
  local ok, watch = pcall(require, "utils.ue_watch")
  if not ok then return {} end
  local snap = watch.snapshot_pending and watch.snapshot_pending() or nil
  if not snap then return {} end
  local files = {}
  for _, p in ipairs(snap.adds or {}) do
    local abs = norm_abs(p)
    if abs then files[#files + 1] = abs end
  end
  return files
end

-- ── Source 3: persistent dirty.json ─────────────────────────────────────
-- Cumulative since last :UEPrepare. Anchored correctly to the cindex -reset
-- moment. This is the source that actually fixes the modify-no-op bug.
local function persistent_dirty()
  local ok, watch = pcall(require, "utils.ue_watch")
  if not ok then return {} end
  if type(watch.snapshot_persistent_dirty) ~= "function" then return {} end
  local arr = watch.snapshot_persistent_dirty()
  local files = {}
  for _, p in ipairs(arr or {}) do
    local abs = norm_abs(p)
    if abs then files[#files + 1] = abs end
  end
  return files
end

-- ── Merge / filter / dedupe ─────────────────────────────────────────────
--
-- opts:
--   max_files       (int, default 500) — hard cap, see Windows cmdline note.
--   require_code_ext (bool, default true) — apply ue_paths.CODE_EXTS gate.
--   include         (table, optional) — { buffer=bool, watcher=bool, persistent=bool }
--                   defaults all true. Useful for tests.
--   root            (string, optional) — kept for back-compat / API stability;
--                   no longer used (git source removed).
--
-- Returns:
--   {
--     files = { abs_path, ... },     -- deduped, filtered, capped
--     truncated = bool,              -- true if max_files hit
--     stats = { buffer=N, watcher=N, persistent=N, dedup_in=N, filter_in=N },
--   }
function M.collect(opts)
  opts = opts or {}
  local include = opts.include or {}
  local want_buffer     = include.buffer ~= false
  local want_watcher    = include.watcher ~= false
  local want_persistent = include.persistent ~= false
  local max_files = opts.max_files or M.DEFAULT_MAX_FILES

  local stats = { buffer = 0, watcher = 0, persistent = 0, dedup_in = 0, filter_in = 0 }

  local seen = {}
  local merged = {}

  local function add_source(list, src_name)
    stats[src_name] = #list
    for _, abs in ipairs(list) do
      local k = key_of(abs)
      if k and not seen[k] then
        seen[k] = true
        merged[#merged + 1] = abs
      end
    end
  end

  -- Order matters for cap-truncation priority: buffer first (active edit
  -- right now), then in-flight watcher, then cumulative persistent.
  if want_buffer     then add_source(buffer_dirty(), "buffer") end
  if want_watcher    then add_source(watcher_pending(), "watcher") end
  if want_persistent then add_source(persistent_dirty(), "persistent") end

  stats.dedup_in = #merged

  local filtered = ue_paths.filter(merged, { require_code_ext = opts.require_code_ext })
  stats.filter_in = #filtered

  local truncated = false
  if #filtered > max_files then
    truncated = true
    local capped = {}
    for i = 1, max_files do capped[i] = filtered[i] end
    filtered = capped
  end

  return { files = filtered, truncated = truncated, stats = stats }
end

-- Convenience: returns just the files array, or nil if empty (caller can
-- short-circuit "no rg subprocess if no dirty files" with a nil check).
function M.collect_or_nil(opts)
  local r = M.collect(opts)
  if not r.files or #r.files == 0 then return nil, r end
  return r.files, r
end

-- Test hooks (exposed for headless smoke).
M._buffer_dirty = buffer_dirty
M._watcher_pending = watcher_pending
M._persistent_dirty = persistent_dirty
M._norm_abs = norm_abs
M._key_of = key_of

return M
