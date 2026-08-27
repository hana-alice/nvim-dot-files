-- ue.core.scan_roots — derive project scan roots from UE build metadata.
--
-- Extracted from `lua/ue.lua` to keep that file under its monotonically
-- decreasing line ratchet (tests/cases/stability_spec.lua). Behaviour contract:
-- openspec/specs/project-scan-root-discovery/spec.md
--
-- Why this exists: scan roots used to be GUESSED from directory names plus a
-- single `.uproject` anchor. In a nested layout that pinned the entire scan to
-- `Source/<Proj>/`, so a module a teammate added anywhere else was structurally
-- invisible to csearch and the file picker -- rerunning :UEPrepare could never
-- fix it, because the directory was never in the input set to begin with.
--
-- UnrealBuildTool itself discovers modules through declaration files, so this
-- module derives scan roots from the same source of truth. It only uses the FACT
-- that a declaration file exists -- it never parses contents (no C#/JSON
-- semantics), because "does this directory hold code" needs no more than that.

local fs = require("ue.core.fs")

local M = {}

-- Depth 6 covers the deepest real layout we ship against
-- (Source/<Proj>/Plugins/<P>/Source/<M>). Measured on a 320k-file project with
-- excludes applied: depth 4/5/6 = 4/7/10 ms walking 62/162/333 dirs, so cost is
-- bounded by depth+excludes, NOT by total file count.
M.MAX_DEPTH = 6

-- Matched against the LOWERCASED filename, so patterns must be written
-- lowercase: Windows/macOS filesystems are case-insensitive and real trees mix
-- `Foo.Build.cs` with `Foo.build.cs`.
M.DECL_PATTERNS = {
  "%.build%.cs$",
  "%.uplugin$",
  "%.uproject$",
}

-- Directory basenames never entered by discovery: build output, VCS metadata and
-- vendored package trees. Mirrors `UE_CONST.SCAN_EXCLUDES` in `lua/ue.lua`,
-- which passes its own list in explicitly; this copy exists so the module (and
-- its tests) have a usable default without reaching back into the monolith.
M.DEFAULT_EXCLUDES = {
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

local function uvfs()
  return vim.uv or vim.loop
end

local function is_declaration(name)
  local lowered = name:lower()
  for _, pattern in ipairs(M.DECL_PATTERNS) do
    if lowered:match(pattern) then
      return true
    end
  end
  return false
end

--- Walk `project_root` and return project-root-relative directories that hold a
--- module/plugin/project declaration.
---
--- Bounded by MAX_DEPTH and by `excludes`, so a build-output tree
--- (Intermediate/, Binaries/, Content/) is never entered and never yields a scan
--- root even when it contains generated *.Build.cs copies.
---
--- Why not derive from compile_commands.json instead: the cdb records what was
--- COMPILED for one platform+configuration, not what code EXISTS. Measured on
--- the real failing project its project-side entries were 4662 Intermediate /
--- 3974 Plugins / 19 Source -- mostly generated TUs, with uncompiled modules,
--- shaders and Config absent entirely. Wrong direction for defining search scope.
---@param project_root string
---@param excludes string[]|nil directory basenames to skip (defaults to DEFAULT_EXCLUDES)
---@return string[] project-root-relative directories, sorted
function M.discover_module_dirs(project_root, excludes)
  project_root = fs.norm(project_root or "")
  if project_root == "" then
    return {}
  end
  local skip = {}
  for _, name in ipairs(excludes or M.DEFAULT_EXCLUDES) do
    skip[name] = true
  end
  local scandir = uvfs()
  local found = {}

  local function walk(absolute, relative, depth)
    if depth > M.MAX_DEPTH then
      return
    end
    local handle = scandir.fs_scandir(absolute)
    if not handle then
      return
    end
    while true do
      local name, kind = scandir.fs_scandir_next(handle)
      if not name then
        break
      end
      if kind == "file" then
        if is_declaration(name) then
          found[relative] = true
        end
      elseif kind == "directory" and not skip[name] then
        walk(
          fs.join(absolute, name),
          relative == "" and name or fs.join(relative, name),
          depth + 1
        )
      end
    end
  end

  walk(project_root, "", 0)

  local dirs = {}
  for relative in pairs(found) do
    dirs[#dirs + 1] = relative
  end
  table.sort(dirs)
  return dirs
end

--- Collapse candidates by path prefix: when A is an ancestor of B, keep only A.
--- Without this a large project yields one scan root per module (measured: 142
--- fragments collapsing to 1 real module root).
---
--- The root-level "" entry MUST be dropped. A standard-layout project keeps its
--- .uproject at project_root, so "" is always a candidate there; keeping it
--- would make convergence swallow every sibling into a single whole-root scan,
--- pulling Content/ (media) and .git/ into enumeration. That is a WORSE
--- regression than the bug being fixed, so it is structurally excluded rather
--- than merely avoided.
---@param candidates string[]
---@return string[]
function M.converge(candidates)
  local sorted = {}
  for _, relative in ipairs(candidates or {}) do
    if relative ~= nil and relative ~= "" then
      sorted[#sorted + 1] = relative
    end
  end
  -- Shallowest first so an ancestor is always seen before its descendants.
  table.sort(sorted, function(a, b)
    if #a ~= #b then
      return #a < #b
    end
    return a < b
  end)

  local kept = {}
  for _, relative in ipairs(sorted) do
    local covered = false
    for _, keep in ipairs(kept) do
      if relative == keep or relative:sub(1, #keep + 1) == keep .. "/" then
        covered = true
        break
      end
    end
    if not covered then
      kept[#kept + 1] = relative
    end
  end
  return kept
end

--- Distinguish an AMBIGUOUS NESTED layout from a STANDARD layout (project root
--- itself holds the `.uproject`). Both make the module anchor resolve to
--- project_root, so the anchor alone cannot tell them apart -- yet they need
--- opposite treatment: standard layout legitimately wants the root-level
--- defaults (Source/Shaders/Config/...), while the ambiguous case must not fall
--- back to a bare `Source` scan (that re-imports config tables, embedded SDKs
--- and packaging tools living under `Source/`).
---
--- Ambiguity mirrors the anchor's own rule: it only anchors when it finds
--- EXACTLY ONE `.uproject` under `Source/*/`. So we count uproject FILES, not
--- directories -- two uprojects inside a single `Source/<Proj>/` is just as
--- ambiguous as one each in two sibling directories, and both leave the anchor
--- at project_root.
---@param project_root string
---@return boolean
function M.is_ambiguous_nested(project_root)
  project_root = fs.norm(project_root or "")
  if project_root == "" then
    return false
  end
  local scandir = uvfs()

  local root_handle = scandir.fs_scandir(project_root)
  while root_handle do
    local name, kind = scandir.fs_scandir_next(root_handle)
    if not name then
      break
    end
    -- A root-level .uproject means standard layout: not ambiguous.
    if kind == "file" and name:lower():match("%.uproject$") then
      return false
    end
  end

  local nested = 0
  local source_handle = scandir.fs_scandir(fs.join(project_root, "Source"))
  while source_handle do
    local dir_name, dir_kind = scandir.fs_scandir_next(source_handle)
    if not dir_name then
      break
    end
    if dir_kind == "directory" then
      local child = scandir.fs_scandir(fs.join(project_root, "Source", dir_name))
      while child do
        local file_name, file_kind = scandir.fs_scandir_next(child)
        if not file_name then
          break
        end
        if file_kind == "file" and file_name:lower():match("%.uproject$") then
          nested = nested + 1
          if nested >= 2 then
            return true
          end
        end
      end
    end
  end
  return false
end

--- Read `<project_root>/.ueprepare-scan-paths`: one root-relative directory per
--- line, `#` starts a comment. Returns nil when the file is absent or has no
--- effective entries, so callers fall back to derivation.
---
--- This file is the highest-priority EXPLICIT override and is deliberately NOT
--- merged with discovery: its established meaning is "what I declare is the
--- final answer", used to NARROW scope (verified 877k -> 116k on one project).
--- Unioning discovery back in would silently re-widen a scope the user chose to
--- narrow, defeating the mechanism.
---@param project_root string
---@return string[]|nil
function M.read_whitelist(project_root)
  project_root = fs.norm(project_root or "")
  if project_root == "" then
    return nil
  end
  local handle = io.open(project_root .. "/.ueprepare-scan-paths", "r")
  if not handle then
    return nil
  end
  local dirs = {}
  for line in handle:lines() do
    local entry = line:gsub("\r$", ""):gsub("^%s+", ""):gsub("%s+$", "")
    entry = entry:gsub("%s+#.*$", "")
    if entry ~= "" and not entry:match("^#") then
      dirs[#dirs + 1] = entry
    end
  end
  handle:close()
  return #dirs > 0 and dirs or nil
end

--- Merge the legacy anchor/default scan roots with discovered module roots.
---
--- Union, never replace: discovery has blind spots (a pure `Shaders/` or
--- `Config/` tree declares no *.Build.cs), so replacing would trade one silent
--- gap for another -- exactly the failure class this mechanism exists to remove.
--- The union can therefore only ever WIDEN coverage.
---
--- The single exception is an ambiguous nested layout, where `base` has
--- degenerated to a bare `Source`: unioning that back in would re-import the
--- very non-source payload (config tables, embedded JDK, packaging tools) whose
--- presence under `Source/` motivated the whitelist in the first place.
--- Discovery already points at the concrete module subtrees, so it supersedes
--- `base` there. The suppression is deliberately narrow -- it requires discovery
--- to be non-empty -- so coverage is never reduced to nothing.
---@param project_root string
---@param base string[] anchor/default-derived roots
---@param defaults string[] fallback when the merge would be empty
---@param excludes string[] directory basenames to skip (UE_CONST.SCAN_EXCLUDES)
---@return string[]
function M.merge(project_root, base, defaults, excludes)
  local discovered = M.converge(M.discover_module_dirs(project_root, excludes))
  if #discovered > 0 and M.is_ambiguous_nested(project_root) then
    base = {}
  end

  local merged, seen = {}, {}
  for _, list in ipairs({ base or {}, discovered }) do
    for _, relative in ipairs(list) do
      if relative ~= "" and not seen[relative] then
        seen[relative] = true
        merged[#merged + 1] = relative
      end
    end
  end
  -- An empty merge would mean "scan nothing"; keep the defaults instead.
  return #merged > 0 and merged or defaults
end

return M
