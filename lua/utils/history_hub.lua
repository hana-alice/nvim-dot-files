-- utils.history_hub — one keyboard entry to everything "I did before".
--
-- Problem this solves: past searches were hard to find. The picker history
-- stores every intermediate keystroke pause ("shadeb", "shadebin", …), has no
-- notion of which queries actually led somewhere, and each kind of history
-- (searches, files, jumps, commands, notifications) lives behind a different
-- key. This module:
--   * records a query only when it was USED (a result was opened), with count
--     and last-used time, per project;
--   * cleans the legacy picker history for display (drop prefixes of a longer
--     query, dedupe case-insensitively);
--   * offers one hub that lists every history surface.
--
-- Storage: one small JSON file per project under stdpath("state"); written on
-- use only (no timers). Bounded by MAX_ENTRIES.

local M = {}

local MAX_ENTRIES = 300

local function trim(value)
  return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- ── pure helpers (unit-tested) ─────────────────────────────────────────────

--- Drop keystroke noise from an ordered (newest-first) query list: exact
--- case-insensitive duplicates, and queries that are a strict prefix of
--- another query in the list (typing "shadeb" on the way to "shadebin").
---@param queries string[]
---@return string[]
function M.clean_queries(queries)
  local lowered, seen, out = {}, {}, {}
  for index, query in ipairs(queries or {}) do lowered[index] = trim(query):lower() end
  for index, query in ipairs(queries or {}) do
    local low = lowered[index]
    if low ~= "" and not seen[low] then
      local is_prefix = false
      for other_index, other in ipairs(lowered) do
        if other_index ~= index and #other > #low and other:sub(1, #low) == low then
          is_prefix = true
          break
        end
      end
      seen[low] = true
      if not is_prefix then out[#out + 1] = trim(query) end
    end
  end
  return out
end

--- Record one use of `query` into `entries` (array of {query, count, last, kind}).
--- Returns a new array, most recent first, capped at MAX_ENTRIES.
function M.record_into(entries, query, kind, now)
  query = trim(query)
  if query == "" then return entries or {} end
  local out = { { query = query, kind = kind, count = 1, last = now } }
  for _, entry in ipairs(entries or {}) do
    if entry.query:lower() == query:lower() and entry.kind == kind then
      out[1].count = (entry.count or 1) + 1
    elseif #out < MAX_ENTRIES then
      out[#out + 1] = entry
    end
  end
  return out
end

--- Human age: "now", "5m", "3h", "2d".
function M.age(last, now)
  local seconds = math.max(0, (now or os.time()) - (last or 0))
  if seconds < 60 then return "now" end
  if seconds < 3600 then return math.floor(seconds / 60) .. "m" end
  if seconds < 86400 then return math.floor(seconds / 3600) .. "h" end
  return math.floor(seconds / 86400) .. "d"
end

--- Merge used entries (authoritative, ordered by recency) with cleaned legacy
--- queries that were never recorded as used.
function M.merge(used, legacy)
  local seen, out = {}, {}
  for _, entry in ipairs(used or {}) do
    seen[entry.query:lower()] = true
    out[#out + 1] = entry
  end
  for _, query in ipairs(M.clean_queries(legacy)) do
    if not seen[query:lower()] then
      seen[query:lower()] = true
      out[#out + 1] = { query = query, kind = "grep", count = 0 }
    end
  end
  return out
end

function M.format_entry(entry, now)
  local meta = entry.count and entry.count > 0
    and ("%3s ×%d"):format(M.age(entry.last, now), entry.count) or "  older"
  return ("%-8s %s"):format(meta, entry.query)
end

-- ── storage ────────────────────────────────────────────────────────────────

local function project_key()
  local ok, ue = pcall(require, "ue")
  local ctx
  if ok and type(ue.resolve_context) == "function" then
    local ok_ctx, resolved = pcall(ue.resolve_context)
    if ok_ctx then ctx = resolved end
  end
  local root = ctx and (ctx.project_root or ctx.engine_root) or vim.uv.cwd() or ""
  return vim.fn.sha256(vim.fs.normalize(root)):sub(1, 16)
end

local function store_path(key)
  return vim.fs.joinpath(vim.fn.stdpath("state"), "ue_search_history", (key or project_key()) .. ".json")
end

function M.load(key)
  local ok, lines = pcall(vim.fn.readfile, store_path(key))
  if not ok then return {} end
  local ok_json, data = pcall(vim.json.decode, table.concat(lines, "\n"))
  return ok_json and type(data) == "table" and data or {}
end

local function save(entries, key)
  local path = store_path(key)
  vim.fn.mkdir(vim.fs.dirname(path), "p")
  local temp = path .. ".tmp." .. vim.fn.getpid()
  if pcall(vim.fn.writefile, { vim.json.encode(entries) }, temp) then
    if not vim.uv.fs_rename(temp, path) then pcall(os.remove, temp) end
  end
end

--- Record that a query produced a result the user opened.
function M.record(query, kind, key)
  local entries = M.record_into(M.load(key), query, kind or "grep", os.time())
  save(entries, key)
  return entries
end

-- ── pickers ────────────────────────────────────────────────────────────────

local function pick(title, items, format, on_choice)
  local ok, snacks = pcall(require, "snacks")
  if ok and snacks.picker then
    return snacks.picker.pick({
      title = title,
      items = vim.tbl_map(function(item)
        return { text = format(item), data = item, query = item.query }
      end, items),
      format = "text",
      preview = "none",
      layout = { preset = "vscode" },
      confirm = function(picker, choice)
        picker:close()
        if choice then vim.schedule(function() on_choice(choice.data) end) end
      end,
    })
  end
  vim.ui.select(items, { prompt = title, format_item = format }, function(choice)
    if choice then on_choice(choice) end
  end)
end

--- Searches that led somewhere, newest first; then older cleaned history.
--- opts.legacy: string[] (newest first) from the picker's own history;
--- opts.rerun(query, kind): run the search again.
function M.searches(opts)
  opts = opts or {}
  local items = M.merge(M.load(), opts.legacy or {})
  if #items == 0 then
    return vim.notify("No search history yet for this project", vim.log.levels.INFO)
  end
  local now = os.time()
  pick("Search history — this project", items, function(entry) return M.format_entry(entry, now) end,
    function(entry) if opts.rerun then opts.rerun(entry.query, entry.kind) end end)
end

--- Every "what did I do before" surface behind one key.
M.surfaces = {
  { label = "Searches that found something (this project)", key = "<leader>sH", run = function() vim.cmd("UESearchHistory") end },
  { label = "Resume last search with its results", key = "<leader>s/", run = function()
      local picker = require("snacks").picker
      if not pcall(picker.resume, "ue_grep_csearch") then pcall(picker.resume, "ue_grep_rg") end
    end },
  { label = "Resume last picker of any kind", key = "<leader>sR", run = function() require("snacks").picker.resume() end },
  { label = "Recent files", key = "<leader>fr", run = function() require("snacks").picker.recent() end },
  { label = "Jump list (where the cursor has been)", key = "<leader>sj", run = function() require("snacks").picker.jumps() end },
  { label = "Command-line history", key = "<leader>sc", run = function() require("snacks").picker.command_history() end },
  { label = "Notifications", key = "<leader>uN", run = function() vim.cmd("NotificationHistory") end },
  { label = "Undo tree of this file", key = "<leader>su", run = function() require("snacks").picker.undo() end },
  { label = "Quickfix list (last build errors / crash frames)", key = "<leader>sq", run = function() require("snacks").picker.qflist() end },
  { label = "Earlier quickfix lists (older builds / searches / crashes)", key = ":chistory", run = function()
      local ok, out = pcall(vim.fn.execute, "chistory")
      local lists = {}
      for line in vim.gsplit(ok and out or "", "\n", { plain = true, trimempty = true }) do
        lists[#lists + 1] = line
      end
      if #lists == 0 then return vim.notify("No quickfix lists yet", vim.log.levels.INFO) end
      vim.ui.select(lists, { prompt = "Quickfix list" }, function(choice)
        local number = choice and choice:match("error list (%d+)")
        if number then vim.cmd(("silent %dchistory | copen"):format(tonumber(number))) end
      end)
    end },
  { label = "Commits that touched this file", key = "<leader>gl", run = function() require("snacks").picker.git_log_file() end },
}

function M.hub()
  pick("History", M.surfaces, function(surface)
    return ("%-50s %s"):format(surface.label, surface.key or "")
  end, function(surface) surface.run() end)
end

return M
