-- utils/ue_goto/cache.lua
-- ============================================================================
-- Per-project definition cache for the non-C++ compatibility fallback chain.
--
-- C/C++ gd MUST NOT call this module: a symbol/receiver location key cannot
-- encode overload resolution, macros, templates, ADL, or build context. The
-- C++ authority boundary in lsp_fallback reuses live compiler TUs instead.
--
-- Scoping:
--   * Per-project. Two different UE projects share NO cache entries (same
--     symbol name -> different file in different project trees).
--   * Project key = engine_root resolved by ue.clangd_root(bufnr). If we
--     can't resolve a project root, the cache is silently disabled for that
--     query (still works, just no caching benefit).
--
-- Key design:
--   * primary_key   = "<receiver>::<symbol>"  when we know the receiver
--                     (member functions / class statics / nested types)
--   * secondary_key = "<symbol>"              free functions / globals /
--                     fallback when receiver couldn't be inferred
--   On put: write both keys (when receiver is available).
--   On get: try primary first, then secondary.
--   Rationale: cross-platform same-name conflicts (FAndroidPlatformProcess::
--   CreateProc vs FWindowsPlatformProcess::CreateProc) are disambiguated by
--   receiver. Bare-name conflicts are accepted as a known limitation —
--   `validate_still_exists` catches the most pathological staleness.
--
-- Validation (anti-stale):
--   On cache hit, before returning, check each location:
--     1. file exists
--     2. line ±2 of the cached line still contains the symbol name
--   Failures are dropped from the cache permanently.
--
-- Persistence:
--   ~/AppData/Local/nvim-data/ue_def_cache/<hash8>-<basename>/cache.json
--   Debounced writes (2s) to avoid IO storm during burst of gd presses.
--   LRU bounded at 1000 entries.
--
-- Invalidation:
--   * Per-entry: validate failure
--   * Bulk: :UEDefCacheClear, or auto-detected when CDB mtime > cache mtime
-- ============================================================================

local M = {}

local LRU_MAX        = 1000
local PERSIST_DEBOUNCE_MS = 2000
local VALIDATE_LINE_WINDOW = 2  -- ±N lines around cached line

-- ---------------------------------------------------------------------------
-- Project root resolution
-- ---------------------------------------------------------------------------

local function project_root_for(bufnr)
  bufnr = bufnr or 0
  local ok, ue = pcall(require, "ue")
  if not ok or not ue.clangd_root then return nil end
  local root = ue.clangd_root(bufnr)
  if not root or root == "" then return nil end
  return root
end

-- Stable 8-char hex digest of an absolute path. Pure-Lua FNV-1a (no openssl
-- dep). Collision risk for a few dozen project roots is negligible.
-- Uses bit lib (LuaJIT global) — Neovim ships LuaJIT so this is always live.
local bit = require("bit")
local function hash8(s)
  local h = 2166136261
  for i = 1, #s do
    h = bit.band(bit.bxor(h, s:byte(i)), 0xFFFFFFFF)
    h = bit.band(h * 16777619, 0xFFFFFFFF)
  end
  -- format as %x can blow past 8 chars when h ~= 32-bit; clip explicitly
  return string.format("%08x", bit.band(h, 0xFFFFFFFF)):sub(-8)
end

local function project_dir_for(bufnr)
  local root = project_root_for(bufnr)
  if not root then return nil, nil end
  local norm = root:gsub("\\", "/"):gsub("/+$", "")
  local base = norm:match("([^/]+)$") or "unknown"
  -- sanitize basename for filesystem (drop weird chars)
  base = base:gsub("[^%w%-_.]", "_")
  local cache_root = vim.fn.stdpath("data") .. "/ue_def_cache"
  local dir = string.format("%s/%s-%s", cache_root, hash8(norm), base)
  return dir, norm
end

-- ---------------------------------------------------------------------------
-- In-memory store, keyed per project_dir.
-- entries[pdir] = {
--   data = { [key] = { locations = {...}, source = "lsp"|"gtags"|"csearch",
--                      ts = unix_seconds, last_hit = unix_seconds } },
--   order = { key1, key2, ... } -- LRU recency, head = most recent
--   loaded = bool,
--   dirty = bool,
--   timer = uv_timer | nil,
-- }
-- ---------------------------------------------------------------------------
local stores = {}

local function now_s()
  return math.floor((vim.uv or vim.loop).hrtime() / 1e9)
end

local function ensure_store(pdir)
  if stores[pdir] then return stores[pdir] end
  stores[pdir] = { data = {}, order = {}, loaded = false, dirty = false, timer = nil }
  return stores[pdir]
end

local function load_from_disk(pdir)
  local store = ensure_store(pdir)
  if store.loaded then return store end
  store.loaded = true
  local path = pdir .. "/cache.json"
  local f = io.open(path, "r")
  if not f then return store end
  local txt = f:read("*a")
  f:close()
  if not txt or txt == "" then return store end
  local ok, decoded = pcall(vim.fn.json_decode, txt)
  if not ok or type(decoded) ~= "table" then return store end
  local data = decoded.data or {}
  local order = decoded.order or {}
  -- Sanitize: keep only entries that exist in both data and order.
  local seen = {}
  for _, k in ipairs(order) do
    if data[k] and not seen[k] then
      seen[k] = true
      table.insert(store.order, k)
      store.data[k] = data[k]
    end
  end
  return store
end

local function schedule_persist(pdir)
  local store = ensure_store(pdir)
  store.dirty = true
  if store.timer then
    pcall(function() store.timer:stop(); store.timer:close() end)
    store.timer = nil
  end
  local timer = (vim.uv or vim.loop).new_timer()
  store.timer = timer
  timer:start(PERSIST_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
    pcall(function() timer:stop(); timer:close() end)
    store.timer = nil
    if not store.dirty then return end
    store.dirty = false
    pcall(vim.fn.mkdir, pdir, "p")
    local payload = vim.fn.json_encode({ data = store.data, order = store.order, version = 1 })
    local f = io.open(pdir .. "/cache.json", "w")
    if f then f:write(payload); f:close() end
  end))
end

-- Move key to head of order (most-recent).
local function touch(store, key)
  for i, k in ipairs(store.order) do
    if k == key then
      if i == 1 then return end
      table.remove(store.order, i)
      table.insert(store.order, 1, key)
      return
    end
  end
  -- not found -> insert at head
  table.insert(store.order, 1, key)
  -- evict tail if over LRU_MAX
  while #store.order > LRU_MAX do
    local victim = table.remove(store.order)
    store.data[victim] = nil
  end
end

-- ---------------------------------------------------------------------------
-- Key construction
-- ---------------------------------------------------------------------------

local function make_keys(symbol, receiver)
  if not symbol or symbol == "" then return nil, nil end
  local primary = (receiver and receiver ~= "") and (receiver .. "::" .. symbol) or nil
  local secondary = symbol
  return primary, secondary
end

-- ---------------------------------------------------------------------------
-- Validation: prove a cached location still has the symbol nearby.
-- ---------------------------------------------------------------------------

-- Forward declaration so validate_and_filter (defined above) can call this
-- without needing to know which pdir owns `store`.
local schedule_persist_for_store

local location_mod = require("utils.ue_goto.location")

local function validate_one(loc, symbol)
  local path = location_mod.location_path(loc)
  if not path or path == "" then return false end
  local stat = (vim.uv or vim.loop).fs_stat(path)
  if not stat or stat.type ~= "file" then return false end
  local line = location_mod.location_line(loc) or 0
  if line <= 0 then return false end
  -- Read line ±VALIDATE_LINE_WINDOW
  local f = io.open(path, "r")
  if not f then return false end
  local lines = {}
  local i = 0
  local lo = math.max(1, line - VALIDATE_LINE_WINDOW)
  local hi = line + VALIDATE_LINE_WINDOW
  for l in f:lines() do
    i = i + 1
    if i >= lo and i <= hi then
      table.insert(lines, l)
    end
    if i > hi then break end
  end
  f:close()
  if #lines == 0 then return false end
  local pat = "%f[%w_]" .. vim.pesc(symbol) .. "%f[^%w_]"
  for _, l in ipairs(lines) do
    if l:find(pat) then return true end
  end
  return false
end

-- Filter out invalid entries; if a key becomes empty, remove it.
local function validate_and_filter(store, key, symbol)
  local entry = store.data[key]
  if not entry or not entry.locations then return nil end
  local kept = {}
  for _, loc in ipairs(entry.locations) do
    if validate_one(loc, symbol) then
      table.insert(kept, loc)
    end
  end
  if #kept == 0 then
    store.data[key] = nil
    for i, k in ipairs(store.order) do
      if k == key then table.remove(store.order, i); break end
    end
    return nil
  end
  if #kept ~= #entry.locations then
    entry.locations = kept
    schedule_persist_for_store(store)  -- forward decl
  end
  return kept
end

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

-- Get cached locations for (symbol, receiver) in current buffer's project.
-- Returns: locations (table), key_used (string), source (string)  on hit
--          nil                                                    on miss
function M.get(symbol, receiver, bufnr)
  local pdir = project_dir_for(bufnr)
  if not pdir then return nil end
  local store = load_from_disk(pdir)
  local primary, secondary = make_keys(symbol, receiver)
  local keys = {}
  if primary then table.insert(keys, primary) end
  if secondary then table.insert(keys, secondary) end
  for _, key in ipairs(keys) do
    if store.data[key] then
      local kept = validate_and_filter(store, key, symbol)
      if kept then
        store.data[key].last_hit = now_s()
        touch(store, key)
        schedule_persist(pdir)
        return kept, key, store.data[key].source
      end
    end
  end
  return nil
end

-- Forward-declared shim used by validate_and_filter.
schedule_persist_for_store = function(store)
  -- Walk back to pdir by reverse map
  for pdir, s in pairs(stores) do
    if s == store then schedule_persist(pdir); return end
  end
end

-- Put locations under both primary and secondary keys.
function M.put(symbol, receiver, locations, source, bufnr)
  if not symbol or symbol == "" or not locations or #locations == 0 then return end
  local pdir = project_dir_for(bufnr)
  if not pdir then return end
  local store = load_from_disk(pdir)
  local primary, secondary = make_keys(symbol, receiver)
  local ts = now_s()
  -- Strip transient fields off locations before persisting (jumper writes
  -- _origin_cword / _sym_name on the table; we don't want those bleeding
  -- across sessions).
  local clean = {}
  for _, loc in ipairs(locations) do
    table.insert(clean, {
      uri = loc.uri or loc.targetUri,
      range = loc.range or loc.targetSelectionRange or loc.targetRange,
    })
  end
  -- NOTE: cannot use ipairs({primary, secondary}) — when primary is nil,
  -- ipairs stops at index 1 and never visits secondary. Iterate explicitly.
  local keys = {}
  if primary then table.insert(keys, primary) end
  if secondary then table.insert(keys, secondary) end
  for _, key in ipairs(keys) do
    store.data[key] = {
      locations = clean,
      source = source or "unknown",
      ts = ts,
      last_hit = ts,
    }
    touch(store, key)
  end
  schedule_persist(pdir)
end

-- Drop ALL entries for current buffer's project.
function M.clear(bufnr)
  local pdir = project_dir_for(bufnr)
  if not pdir then return false, "no project root" end
  stores[pdir] = nil
  pcall(vim.fn.delete, pdir .. "/cache.json")
  return true
end

-- Diagnostics: snapshot of current project's cache.
function M.stats(bufnr)
  local pdir, root = project_dir_for(bufnr)
  if not pdir then return { project = nil, entries = 0 } end
  local store = load_from_disk(pdir)
  local by_source = {}
  for _, entry in pairs(store.data) do
    by_source[entry.source] = (by_source[entry.source] or 0) + 1
  end
  return {
    project = root,
    cache_dir = pdir,
    entries = #store.order,
    by_source = by_source,
    lru_max = LRU_MAX,
  }
end

-- For tests: drop in-memory state without touching disk.
function M._reset_memory()
  stores = {}
end

return M
