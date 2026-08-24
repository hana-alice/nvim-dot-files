-- lua/utils/ue_paths.lua
-- ----------------------------------------------------------------------------
-- Shared path classification for the UE workspace tooling.
--
-- Several call sites need the SAME "is this path noise?" decision:
--   * ue_watch.lua's fs_event handler (drop UE Hot Reload churn)
--   * dirty_files.lua's git/buffer/watcher merge (don't feed Intermediate
--     headers into rg-on-dirty)
--   * potentially future watchers / pickers
--
-- Keeping this in ONE place avoids the classic "added a new noise dir to
-- the watcher but forgot the picker" drift bug.
-- ----------------------------------------------------------------------------

local M = {}

-- Substrings (lowercased, /-normalized) that disqualify a path from any
-- index/grep operation. Match is plain `string.find(_, frag, 1, true)` so
-- patterns are literal, not regex.
M.BLOCKLIST_FRAGMENTS = {
  "/intermediate/",
  "/binaries/",
  "/build/",
  "/saved/",
  "/derivedatacache/",
  "/.git/",
  "/.vs/",
  "/.idea/",
  "/.vscode/",
  "/.cache/",
  -- Note: .clangd-index/ and .clangd-pch/ used to be top-level dirs that
  -- needed explicit ignore entries. Cache layout v3 (2026-05) collapses
  -- both under .cache/nvim-ue/clangd/, so the .cache/ entry above
  -- already covers them. Do NOT re-add them.
  "/.claude/",
}

-- Suffix patterns (lua patterns) that mark generated source. UHT emits
-- these into Intermediate/ usually but some module layouts mirror them
-- into the source tree, so suffix is the safer signal.
M.BLOCKLIST_SUFFIXES = {
  "%.generated%.h$",
  "%.gen%.cpp$",
}

-- Optional extensions filter: if non-nil, only paths matching one of these
-- ARE allowed through (whitelist). Pass nil to skip extension gating.
M.CODE_EXTS = {
  h = true, hpp = true, hh = true, inl = true, ipp = true,
  c = true, cc = true, cpp = true, cxx = true, ["c++"] = true,
  usf = true, ush = true, hlsl = true, hlsli = true,
  cs = true,
}

local function ext_of(path)
  local e = path:match("%.([^./\\]+)$")
  return e and e:lower() or ""
end

local function norm(p)
  if not p or p == "" then return "" end
  return (p:gsub("\\", "/"))
end

-- Returns true iff `path` should be IGNORED (matches any blocklist rule).
-- Accepts paths in any case / either slash flavour.
function M.is_blocked(path)
  if not path or path == "" then return true end
  local lower = norm(path):lower()
  for _, frag in ipairs(M.BLOCKLIST_FRAGMENTS) do
    if lower:find(frag, 1, true) then return true end
  end
  for _, pat in ipairs(M.BLOCKLIST_SUFFIXES) do
    if lower:find(pat) then return true end
  end
  return false
end

-- Returns true iff `path` is a file we'd ever want to index/grep.
-- `opts.require_code_ext` (default true) gates on M.CODE_EXTS.
function M.is_searchable(path, opts)
  opts = opts or {}
  if M.is_blocked(path) then return false end
  if opts.require_code_ext ~= false then
    local e = ext_of(path)
    if not M.CODE_EXTS[e] then return false end
  end
  return true
end

-- Filter helper: returns a NEW list of paths that pass is_searchable.
-- Order preserved.
function M.filter(paths, opts)
  local out = {}
  for _, p in ipairs(paths or {}) do
    if M.is_searchable(p, opts) then table.insert(out, p) end
  end
  return out
end

M._norm = norm
M._ext_of = ext_of

return M
