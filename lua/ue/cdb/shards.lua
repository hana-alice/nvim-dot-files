-- ue.cdb.shards — per-config compile_commands shards + priority-dedup merge.
--
-- Step 2 of the multi-platform CDB redesign (see skill
-- `ue-cdb-headless-prepare-and-rsp-glob-trap`, Trap 0c).
--
-- Why shards:
--   The monolithic compile_commands.json at <engine_root>/compile_commands.json
--   used to be rewritten in full every :UEPrepare. Cross-platform users hit
--   "I built Android, then switched to Win64, but clangd still has Android
--   args" because each prepare wiped the other platform's entries.
--
-- Per-config shard layout (under <cache>/cdb/shards/):
--   manifest.json                              -- { active = key, shards = {...} }
--   Win64-ClientEditor-Development.json        -- one shard per (plat,target,config)
--   Android-Client-Development.json
--   Linux-ClientEditor-Development.json
--   ...
--
-- Merge into top-level <engine_root>/compile_commands.json:
--   For each source.cpp that appears in multiple shards, dedup by:
--     1. active shard wins (state.target_platform)
--     2. platform tier: Win64 > Linux > Mac > Android > IOS
--     3. shard mtime (newest wins)
--   The merged result is what clangd actually consumes; individual shards
--   are the per-prepare snapshots.
--
-- A `:UESwitchPlatform` only flips `manifest.active` and re-merges — no
-- rsp/walk needed because every platform's shard is already on disk from
-- prior prepares.

local fs = require("ue.core.fs")

local M = {}

-- ==========================================================================
-- SHARD KEY DERIVATION
-- ==========================================================================

--- Extract platform/target/config segment triple from a UBT build artifact
--- path. UBT writes artifacts under:
---   <root>/Intermediate/Build/<Platform>/<Arch>/<Target>/<Config>/<Module>/...
---   <root>/Intermediate/Build/<Platform>/<Target>/<Config>/<Module>/...   (no arch dir)
--- Arch segments observed: `x64`, `arm64`, `arm32`, `armv7`. The function
--- accepts either layout and returns the first triple that looks
--- well-formed (Platform matches a known UBT platform name, Config matches
--- Debug/DebugGame/Development/Test/Shipping).
---
--- Returns: platform, target, config, or nil if the path doesn't match.
local KNOWN_PLATFORMS = {
  Win64 = true, Win32 = true, Linux = true, LinuxArm64 = true,
  Mac = true, IOS = true, Android = true, TVOS = true,
  HoloLens = true, PS4 = true, PS5 = true, XboxOne = true, XSX = true,
}
local KNOWN_CONFIGS = {
  Debug = true, DebugGame = true, Development = true,
  Test = true, Shipping = true,
}
local KNOWN_ARCHES = {
  x64 = true, arm64 = true, arm32 = true, armv7 = true,
  ["arm64-v8a"] = true, ["armeabi-v7a"] = true,
}

function M.classify_rsp_path(rsp_path)
  if not rsp_path or rsp_path == "" then return nil end
  local p = rsp_path:gsub("\\", "/")
  -- Find the "/Intermediate/Build/" segment, then walk forward.
  local i = p:find("/Intermediate/Build/", 1, true)
  if not i then return nil end
  local rest = p:sub(i + #"/Intermediate/Build/")
  -- Split by `/`
  local segs = {}
  for seg in rest:gmatch("[^/]+") do segs[#segs + 1] = seg end
  if #segs < 3 then return nil end

  local platform = segs[1]
  if not KNOWN_PLATFORMS[platform] then return nil end

  -- segs[2] is either an arch (x64/arm64/...) or directly the target.
  local idx = 2
  if KNOWN_ARCHES[segs[idx]] then idx = idx + 1 end
  local target = segs[idx]
  local config = segs[idx + 1]
  if not target or not config then return nil end
  if not KNOWN_CONFIGS[config] then
    -- Some forks rename configs; fall through and trust whatever's there
    -- only when it's a single capitalized word. Otherwise reject.
    if not config:match("^[A-Z][%w]*$") then return nil end
  end
  return platform, target, config
end

--- "Win64-ClientEditor-Development" style key.
function M.shard_key(platform, target, config)
  return string.format("%s-%s-%s", platform, target, config)
end

--- Reverse of shard_key — return platform/target/config or nil.
function M.parse_shard_key(key)
  local plat, target, conf = key:match("^([^-]+)-([^-]+)-([^-]+)$")
  if not plat then return nil end
  return plat, target, conf
end

-- ==========================================================================
-- DEDUP PRIORITY
-- ==========================================================================

local PLATFORM_TIER = {
  Win64 = 1, Linux = 2, LinuxArm64 = 2, Mac = 3,
  Android = 4, IOS = 5, TVOS = 5, HoloLens = 6,
}

--- Score a shard for dedup — LOWER score wins.
--- active_key wins via the (0/1) offset; platform tier secondary;
--- newer mtime breaks ties.
function M.shard_priority(key, manifest, active_key)
  local plat = M.parse_shard_key(key) or ""
  local active_bonus = (key == active_key) and 0 or 1000
  local tier = PLATFORM_TIER[plat] or 99
  local mtime = ((manifest.shards or {})[key] or {}).mtime or 0
  -- Higher mtime is better; convert by subtracting from a large baseline
  -- so the score stays "lower wins".
  return active_bonus * 1000 + tier * 100 - math.min(mtime / 86400, 99)
end

-- ==========================================================================
-- MANIFEST IO
-- ==========================================================================

local function manifest_path(shards_dir)
  return fs.join(shards_dir, "manifest.json")
end

function M.shards_dir(ctx)
  return ctx.paths.cdb_shards_dir or fs.join(ctx.paths.index_cdb_dir, "shards")
end

function M.shard_path(ctx, key)
  return fs.join(M.shards_dir(ctx), key .. ".json")
end

local function read_json(path)
  local f = io.open(path, "rb")
  if not f then return nil end
  local data = f:read("*a")
  f:close()
  if not data or data == "" then return nil end
  local ok, decoded = pcall(vim.json.decode, data)
  if not ok then return nil end
  return decoded
end

local function write_json(path, value)
  fs.ensure_dir(fs.dirname(path))
  local raw = vim.json.encode(value)
  local current = io.open(path, "rb")
  if current then
    local old = current:read("*a")
    current:close()
    if old == raw then return true end
  end
  local temp = path .. (".tmp.%d.%s"):format(vim.fn.getpid(), tostring(vim.uv.hrtime()))
  local f = io.open(temp, "wb")
  if not f then return false, "cannot open " .. temp end
  f:write(raw)
  f:flush()
  f:close()
  local ok, err = vim.uv.fs_rename(temp, path)
  if not ok then
    pcall(os.remove, temp)
    return false, err or ("cannot replace " .. path)
  end
  return true
end

function M.read_manifest(ctx)
  local m = read_json(manifest_path(M.shards_dir(ctx)))
  if type(m) ~= "table" then
    return { active = nil, shards = {} }
  end
  m.shards = m.shards or {}
  return m
end

function M.write_manifest(ctx, manifest)
  return write_json(manifest_path(M.shards_dir(ctx)), manifest)
end

-- ==========================================================================
-- WRITE SHARD
-- ==========================================================================

--- Persist a shard with its (platform, target, config) metadata + source
--- roots used to discover it. Returns the shard key.
function M.write_shard(ctx, platform, target, config, entries, source_roots)
  local key = M.shard_key(platform, target, config)
  local path = M.shard_path(ctx, key)
  write_json(path, entries)
  local st = vim.uv.fs_stat(path)
  local manifest = M.read_manifest(ctx)
  manifest.shards[key] = {
    platform = platform,
    target = target,
    config = config,
    entry_count = #entries,
    mtime = (st and st.mtime and st.mtime.sec) or os.time(),
    source_roots = source_roots or {},
    updated_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
  }
  manifest.active = key
  M.write_manifest(ctx, manifest)
  return key, path
end

--- Load a single shard's entries from disk.
function M.read_shard(ctx, key)
  local entries = read_json(M.shard_path(ctx, key))
  if type(entries) ~= "table" then return {} end
  return entries
end

-- ==========================================================================
-- MERGE
-- ==========================================================================

--- Compute the active shard key from ctx.state and the manifest's explicit
--- selection. Returns "" when no shard exists.
function M.active_key(ctx, manifest)
  manifest = manifest or { active = nil, shards = {} }
  local state = ctx.state or {}
  local plat = (state.target_platform or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local conf_raw = (state.target_configuration or ""):gsub("^%s+", ""):gsub("%s+$", "")
  local conf = conf_raw:gsub(" Editor$", "")
  local target_value = state.target
  if target_value == nil or tostring(target_value):match("^%s*$") then
    target_value = state.target_name
  end
  local target = tostring(target_value or "")
    :gsub("^%s+", ""):gsub("%s+$", "")
  local wants_editor = conf_raw:match(" Editor$") ~= nil

  local function matches(meta)
    if type(meta) ~= "table" or meta.platform ~= plat or meta.config ~= conf then
      return false
    end
    if target ~= "" then return meta.target == target end
    local is_editor = tostring(meta.target or ""):lower():match("editor$") ~= nil
    return wants_editor == is_editor
  end

  if plat ~= "" and conf_raw ~= "" then
    -- `manifest.active` is an explicit selection written by prepare/switch.
    -- Preserve it when it still satisfies the requested build class. Picking
    -- the newest sibling here can select a one-file hot shard from another
    -- target and falsely make the real active CDB appear incomplete.
    local active_meta = manifest.shards and manifest.shards[manifest.active]
    if matches(active_meta) then return manifest.active end

    local best_key, best_mtime = nil, -1
    for key, meta in pairs(manifest.shards or {}) do
      if matches(meta) and (meta.mtime or 0) > best_mtime then
        best_key, best_mtime = key, meta.mtime or 0
      end
    end
    if best_key then return best_key end
  end
  return manifest.active or ""
end

--- Merge every shard into a single entries array, applying the dedup
--- priority rule. Returns entries, stats { total_in, total_out, dropped }.
function M.merge_shards(ctx, manifest)
  manifest = manifest or M.read_manifest(ctx)
  local active = M.active_key(ctx, manifest)

  -- Walk every shard, accumulate entries with their owning key.
  -- shard_key_for_file[lowercased file] = current winning key.
  local owner = {}
  local total_in = 0
  local out = {}

  -- Pre-rank shards: process winners FIRST so later shards skip cheaply.
  local keys = {}
  for k, _ in pairs(manifest.shards or {}) do keys[#keys + 1] = k end
  table.sort(keys, function(a, b)
    return M.shard_priority(a, manifest, active) < M.shard_priority(b, manifest, active)
  end)

  for _, key in ipairs(keys) do
    local entries = M.read_shard(ctx, key)
    total_in = total_in + #entries
    for _, e in ipairs(entries) do
      local f = (e.file or ""):gsub("\\", "/"):lower()
      if f ~= "" and not owner[f] then
        owner[f] = key
        out[#out + 1] = e
      end
    end
  end

  return out, {
    total_in = total_in,
    total_out = #out,
    dropped = total_in - #out,
    active = active,
    shard_count = #keys,
  }
end

-- ==========================================================================
-- LEGACY MIGRATION
-- ==========================================================================

--- One-shot: if shards dir is empty but a legacy compile_commands.json
--- exists at engine_root, treat it as the initial active shard. Lets
--- existing users upgrade without losing CDB on first run.
function M.migrate_legacy_if_needed(ctx, legacy_path)
  local sd = M.shards_dir(ctx)
  fs.ensure_dir(sd)
  local m = M.read_manifest(ctx)
  if next(m.shards or {}) then return false end
  if not legacy_path or not fs.is_file(legacy_path) then return false end
  local entries = read_json(legacy_path)
  if type(entries) ~= "table" or #entries == 0 then return false end
  -- Guess a key from ctx.state. Fall back to "Legacy-Unknown-Unknown".
  local state = ctx.state or {}
  local plat = (state.target_platform or "") ~= "" and state.target_platform or "Legacy"
  local conf_raw = (state.target_configuration or "") ~= "" and state.target_configuration or "Unknown"
  local target = "Unknown"
  local stripped = conf_raw:gsub(" Editor$", "")
  if stripped ~= conf_raw then target = "Editor" end
  M.write_shard(ctx, plat, target, stripped, entries, { "legacy:" .. legacy_path })
  return true
end

return M
