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
-- THREE SOURCES:
--   1. git status --porcelain  — committed-but-modified, plus untracked
--   2. nvim modified buffers   — typed-but-unsaved (catches "in-flight"
--                                 edits before :w even fires fs_event)
--   3. ue_watch pending_add    — fs_event saw it, debounce timer hasn't
--                                 flushed yet, csearch hasn't ingested it
--
-- DEDUPE KEY: forward-slash + lowercase absolute path. Windows is case-
-- insensitive on disk so "Foo.h" and "foo.h" must collapse to one entry,
-- otherwise rg gets duplicate file args and emits duplicate matches.
--
-- FILTERING: utils.ue_paths.is_searchable — same blocklist the watcher
-- uses (Intermediate/Build/Saved/.generated.h/.gen.cpp/...). Keeps the
-- rg subprocess fast and prevents UE Hot Reload churn from polluting
-- the [LIVE] overlay column with thousands of generated headers.
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
  -- Strip trailing slash from dir-y paths (shouldn't happen for files but
  -- defensive — git can emit dir entries for submodules).
  abs = abs:gsub("/$", "")
  return abs
end

local function key_of(abs_path)
  if not abs_path then return nil end
  return abs_path:lower()
end

-- ── Source 1: git status --porcelain ────────────────────────────────────
-- Returns absolute paths. Includes untracked (??) and modified (M /AM/MM)
-- entries; excludes deleted (D ) — rg can't grep what's gone.
--
-- Synchronous: ~50ms on UE tree per memory note. If you want non-blocking,
-- call this from a coroutine yourself or use _git_dirty_async below.
local function git_dirty_sync(root, timeout_ms)
  if not root or root == "" then return {} end
  timeout_ms = timeout_ms or 1500
  local ok, res = pcall(vim.system, {
    "git", "-C", root, "status", "--porcelain", "--no-renames",
    "--untracked-files=normal",
  }, { text = true, timeout = timeout_ms })
  if not ok then return {} end
  local out = res:wait()
  if not out or out.code ~= 0 or not out.stdout then return {} end

  local files = {}
  for line in out.stdout:gmatch("[^\r\n]+") do
    -- Format: "XY path" where XY is 2-char status. Path starts at col 4.
    -- Quoted paths (spaces/unicode) start with " — strip outer quotes.
    if #line >= 4 then
      local status = line:sub(1, 2)
      local path = line:sub(4)
      -- Skip pure deletes: " D ..." or "D  ..." with no add half.
      local is_delete = (status:sub(1,1) == "D" and status:sub(2,2) ~= "M")
                     or (status:sub(2,2) == "D" and status:sub(1,1) == " ")
      if not is_delete then
        if path:sub(1,1) == '"' and path:sub(-1) == '"' then
          path = path:sub(2, -2):gsub('\\\\', '\\'):gsub('\\"', '"')
        end
        local abs = norm_abs(root .. "/" .. path)
        if abs then files[#files + 1] = abs end
      end
    end
  end
  return files
end

-- ── Source 2: nvim modified buffers ─────────────────────────────────────
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

-- ── Source 3: watcher pending_add ───────────────────────────────────────
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

-- ── Merge / filter / dedupe ─────────────────────────────────────────────
--
-- opts:
--   root            (string, optional) — repo root for git status. Falls
--                   back to cwd. Pass nil/empty to skip git source.
--   max_files       (int, default 500) — hard cap, see Windows cmdline note.
--   require_code_ext (bool, default true) — apply ue_paths.CODE_EXTS gate.
--   include         (table, optional) — { git=bool, buffer=bool, watcher=bool }
--                   defaults all true. Useful for tests.
--
-- Returns:
--   {
--     files = { abs_path, ... },     -- deduped, filtered, capped
--     truncated = bool,              -- true if max_files hit
--     stats = { git=N, buffer=N, watcher=N, dedup_in=N, filter_in=N },
--   }
function M.collect(opts)
  opts = opts or {}
  local include = opts.include or {}
  local want_git     = include.git ~= false
  local want_buffer  = include.buffer ~= false
  local want_watcher = include.watcher ~= false
  local max_files = opts.max_files or M.DEFAULT_MAX_FILES

  local stats = { git = 0, buffer = 0, watcher = 0, dedup_in = 0, filter_in = 0 }

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

  if want_git     then add_source(git_dirty_sync(opts.root or vim.fn.getcwd(), opts.git_timeout_ms), "git") end
  if want_buffer  then add_source(buffer_dirty(), "buffer") end
  if want_watcher then add_source(watcher_pending(), "watcher") end

  stats.dedup_in = #merged

  -- Filter against blocklist. Done AFTER dedup because most dupes come
  -- from git+buffer pointing at the same file — saves blocklist lookups.
  local filtered = ue_paths.filter(merged, { require_code_ext = opts.require_code_ext })
  stats.filter_in = #filtered

  local truncated = false
  if #filtered > max_files then
    truncated = true
    -- Keep the FIRST max_files. Since git list comes first, then buffer,
    -- then watcher, this prioritises committed-but-modified over
    -- newly-discovered fs_event adds — usually what the user wants
    -- (git changes are "things I'm actively working on").
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
M._git_dirty_sync = git_dirty_sync
M._buffer_dirty = buffer_dirty
M._watcher_pending = watcher_pending
M._norm_abs = norm_abs
M._key_of = key_of

return M
