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
local store = require("utils.search_history_store")
local recipes = require("utils.search_recipe")

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
  local intent = entry.unavailable and (" [unavailable: " .. entry.unavailable .. "]")
    or entry.recipe and (" [" .. recipes.describe(entry.recipe) .. "]")
    or " [legacy: query only; modes unknown]"
  return ("%-8s %s%s"):format(meta, entry.query, intent)
end

-- ── storage ────────────────────────────────────────────────────────────────

function M.load(key)
  return store.load(key)
end

--- Record that a query produced a result the user opened.
function M.record(query, kind, key)
  query = trim(query)
  if query == "" then return M.load(key) end
  return store.record({ query = query, kind = kind or "grep", count = 1, last = os.time() }, key)
end

function M.record_recipe_into(entries, recipe, now)
  local validated, err = recipes.validate(recipe)
  if not validated then return nil, err end
  return store.merge(entries, { query = validated.query, kind = validated.source, recipe = validated, count = 1, last = now or os.time() })
end

function M.record_recipe(recipe)
  local validated, err = recipes.validate(recipe)
  if not validated then return nil, err end
  return store.record({ query = validated.query, kind = validated.source, recipe = validated, count = 1, last = os.time() })
end

function M.resume_search()
  local resume = require("snacks.picker.resume")
  local sources = { "ue_grep_csearch", "grep", "ue_grep_rg" }
  local has_state = false
  for _, source in ipairs(sources) do if resume.state[source] then has_state = true; break end end
  if not has_state then return vim.notify("No search to resume in this session", vim.log.levels.INFO) end
  return resume.resume({ include = sources })
end

function M.rerun(entry)
  if entry.unavailable then return vim.notify(entry.unavailable, vim.log.levels.WARN) end
  if entry.recipe then
    local result, err = recipes.run(entry.recipe)
    if not result and err then vim.notify(err, vim.log.levels.WARN) end
    return result
  end
  -- Legacy data cannot claim to restore modes it never recorded. Keep it
  -- reachable as an explicitly described query-only search.
  return vim.ui.select({ "Search query with indexed literal defaults", "Cancel" }, {
    prompt = "Legacy history stores only the query; source and modes are unknown",
  }, function(choice)
    if choice == "Search query with indexed literal defaults" then
      require("ue").cached_grep({ search = entry.query, title = "Legacy query (default modes)" })
    end
  end)
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
--- opts.rerun_entry(entry): optional complete-entry handler.
function M.searches(opts)
  opts = opts or {}
  local used, load_err = M.load()
  if load_err then return vim.notify(load_err, vim.log.levels.WARN) end
  local items = M.merge(used, opts.legacy or {})
  if #items == 0 then
    return vim.notify("No search history yet for this project", vim.log.levels.INFO)
  end
  local now = os.time()
  pick("Search history — this project", items, function(entry) return M.format_entry(entry, now) end,
    function(entry)
      if opts.rerun_entry then opts.rerun_entry(entry)
      elseif opts.rerun and not entry.recipe then opts.rerun(entry.query, entry.kind, entry)
      else M.rerun(entry) end
    end)
end

--- Every "what did I do before" surface behind one key.
M.surfaces = {
  { label = "Searches that found something (this project)", key = "<leader>sH", run = function() vim.cmd("UESearchHistory") end },
  { label = "Resume last search with its results", key = "<leader>s/", run = function()
      return M.resume_search()
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
