-- WORKAROUND
-- name: snacks.smart_picker_dead_buffer
-- scope: snacks
-- issue: internal: snacks smart picker (buffers source) lists buffers whose underlying file was deleted on disk (e.g. branch switch, git rm) → selecting one drops you into an empty buffer with the stale name.
-- symptom: After switching git branches that drop files you had open, pressing <leader><leader> still shows those files in the picker; selecting them opens an empty buffer at the now-nonexistent path.
-- introduced: 2026-04-27
-- removal_condition: snacks.nvim ships per-source dead-buffer filtering, OR an upstream `existing=true` flag is added to buffers source.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Wrap the smart picker's `transform` (default: "unique_file") so that
-- items coming from the `buffers` source whose `.file` no longer exists
-- on disk are dropped silently. Keeps unique_file dedup intact, leaves
-- recent/files sources untouched (recent already fs_stats; files comes
-- from fd which never lists missing paths).
--
-- Why a transform (not a buffers-source override): smart is multi =
-- {buffers, recent, files} and snacks resolves transform per-picker, so
-- one hook covers every dead-buffer entry without monkey-patching each
-- source. unique_file runs first, then we apply the existence check.
--
-- Why scoped to buffers items only:
--   * recent items always exist (recent.lua already fs_stats).
--   * files items come from fd, also always exist.
--   * scratch / nofile / [Scratch] buffers (item.buf set, buftype != "")
--     legitimately have no file — never drop those.
--   * Only buffers with buftype=="" and a real path that's gone count
--     as "dead": exactly the branch-switch case the user reported.
--
-- Apply contract:
--   apply(opts) — opts is the snacks `opts` table at config-time.
--                 Returns the mutated opts (also mutates in-place).

local M = {}

local applied = false
local dropped_count = 0

local uv = vim.uv or vim.loop

local function is_dead_buffer_item(item)
  -- only items synthesized by buffers source carry .buf
  if not item or not item.buf then return false end
  -- only ordinary file buffers; spare scratch/help/term/quickfix/nofile
  if item.buftype and item.buftype ~= "" then return false end
  local file = item.file
  if not file or file == "" then return false end
  -- "[Scratch]" placeholder set by buffers.lua when name is empty
  if file:sub(1, 1) == "[" then return false end
  -- existence check; uv.fs_stat returns nil if the path is gone
  return uv.fs_stat(file) == nil
end

function M.apply(opts)
  applied = true
  opts = opts or {}
  opts.picker = opts.picker or {}
  opts.picker.sources = opts.picker.sources or {}
  local smart = opts.picker.sources.smart or {}

  -- Resolve any existing transform (string name → function, function as-is).
  -- Default for smart is "unique_file" if user/spec did not override.
  local prev = smart.transform or "unique_file"
  local prev_fn
  if type(prev) == "string" then
    local ok, transformers = pcall(require, "snacks.picker.transform")
    if ok and type(transformers[prev]) == "function" then
      prev_fn = transformers[prev]
    end
  elseif type(prev) == "function" then
    prev_fn = prev
  end

  smart.transform = function(item, ctx)
    -- Run the inner transform first (dedup etc). If it drops, we drop too.
    if prev_fn then
      local t = prev_fn(item, ctx)
      if t == false then return false end
      if type(t) == "table" then item = t end
    end
    if is_dead_buffer_item(item) then
      dropped_count = dropped_count + 1
      return false
    end
    return item
  end

  opts.picker.sources.smart = smart
  return opts
end

function M.disable()
  -- snacks reads transform at picker-open time; restart to revert,
  -- or set frontmatter enabled=false and reload config.
end

function M.status()
  return { applied = applied, dropped_count = dropped_count }
end

return M
