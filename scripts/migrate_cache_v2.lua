--[[ Migrate .cache/nvim-ue/ to layout v2.

Run with:
  nvim --headless -u NONE -c "luafile scripts/migrate_cache_v2.lua" -c "qa"

Modes:
  --dry-run (default): print actions, don't move
  --apply             : actually move files

Argv passed via :luafile is awkward; use env var instead:
  CACHE_MIGRATE_APPLY=1 nvim --headless -u NONE -c "luafile scripts/migrate_cache_v2.lua" -c "qa"

The cache root is hard-coded for now (<PROJ_DRIVE>/UnrealEngine). Override
with NVIM_UE_CACHE_ROOT=/path/to/.cache/nvim-ue.

Idempotent: each move is "if old exists AND new doesn't -> mv". Re-running
on a v2 layout prints "all targets already migrated" and exits 0.
--]]

local M = {}

local APPLY = os.getenv("CACHE_MIGRATE_APPLY") == "1"
local CACHE = os.getenv("NVIM_UE_CACHE_ROOT") or "<PROJ_DRIVE>/UnrealEngine/.cache/nvim-ue"

local function exists(p) return vim.uv.fs_stat(p) ~= nil end
local function is_dir(p)
  local st = vim.uv.fs_stat(p)
  return st and st.type == "directory" or false
end

local function ensure_dir(p)
  if not exists(p) then
    if APPLY then
      vim.fn.mkdir(p, "p")
      print(("  mkdir  %s"):format(p))
    else
      print(("  [dry] mkdir  %s"):format(p))
    end
  end
end

local function move(src, dst)
  if not exists(src) then
    return false, "src missing"
  end
  if exists(dst) then
    return false, "dst already exists (skip)"
  end
  ensure_dir(vim.fn.fnamemodify(dst, ":h"))
  if APPLY then
    local ok, err = vim.uv.fs_rename(src, dst)
    if not ok then return false, "rename failed: " .. tostring(err) end
    return true, "moved"
  else
    return true, "[dry] would move"
  end
end

-- ── Migration plan ─────────────────────────────────────────────────────
-- Format: { src_relpath, dst_relpath, comment }
local PLAN = {
  -- csearch
  { "csearch.idx",                "csearch/csearch.idx",          "trigram index" },
  -- gtags inputs (renames + relocate under gtags/)
  { "engine_gtags.files",         "gtags/engine.files",           "gtags engine list" },
  { "project_gtags.files",        "gtags/project.files",          "gtags project list" },
  { "workspace_gtags.files",      "gtags/workspace.files",        "gtags workspace list" },
  { "workspace_all.files",        "gtags/workspace_all.files",    "all-files list (kept name)" },
  -- gtags DB stays at gtags/workspace/ (already correct)
  -- cdb (was: index/)
  { "index/modules.json",         "cdb/modules.json",             "cdb modules state" },
  { "index/queue.json",           "cdb/queue.json",               "cdb queue" },
  { "index/compile_commands",     "cdb/compile_commands",         "cdb directory" },
  -- legacy logs (pre-_logged_jobstart, kept for cold reference)
  { "ubt_genclangdb.log",         "legacy/ubt_genclangdb.log",    "old UBT log" },
  { "ubt2.log",                   "legacy/ubt2.log",              "old UBT log" },
}

local function run()
  print(("=== cache migrate v2 (apply=%s) ==="):format(tostring(APPLY)))
  print(("cache: %s"):format(CACHE))
  if not is_dir(CACHE) then
    print("ERROR: cache root not found: " .. CACHE)
    return 1
  end

  -- Always ensure new dirs exist (cheap, idempotent)
  -- NOTE: Do NOT pre-create cdb/compile_commands — if index/compile_commands
  -- still exists, we want the directory rename to succeed (rename fails if
  -- target dir exists, even if empty). Same goes for csearch/ and gtags/ when
  -- they don't yet hold v2 contents.
  for _, sub in ipairs({ "logs", "runtime", "legacy" }) do
    ensure_dir(CACHE .. "/" .. sub)
  end

  local moved, skipped, errored = 0, 0, 0
  for _, item in ipairs(PLAN) do
    local src = CACHE .. "/" .. item[1]
    local dst = CACHE .. "/" .. item[2]
    if not exists(src) then
      print(("  skip   %-32s  (src absent: nothing to migrate)"):format(item[1]))
      skipped = skipped + 1
    elseif exists(dst) then
      print(("  skip   %-32s  (dst exists: already at %s)"):format(item[1], item[2]))
      skipped = skipped + 1
    else
      local ok, msg = move(src, dst)
      if ok then
        print(("  %-6s %-32s -> %s   [%s]"):format(APPLY and "MOVE" or "(dry)", item[1], item[2], item[3]))
        moved = moved + 1
      else
        print(("  ERROR  %-32s : %s"):format(item[1], msg))
        errored = errored + 1
      end
    end
  end

  print(("\nsummary: moved=%d skipped=%d errored=%d (apply=%s)"):format(moved, skipped, errored, tostring(APPLY)))
  if not APPLY and moved > 0 then
    print("Re-run with CACHE_MIGRATE_APPLY=1 to actually move.")
  end
  return errored == 0 and 0 or 2
end

run()
