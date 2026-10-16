-- Shared history ownership: each project has one bounded collection. Writers
-- acquire ue.file_lock, reread, merge their pending uses, then atomically publish.
local M = {}
local recipes = require("utils.search_recipe")
local locks = require("ue.file_lock")
local MAX_ENTRIES, MAX_BYTES = 300, 2 * 1024 * 1024
local pending, scheduled, legacy_keys = {}, {}, {}

function M.key(project)
  project = project or recipes.context()
  local root = project.root
  local key = vim.fn.sha256(recipes.path_key(project.identity or root)):sub(1, 16)
  legacy_keys[key] = {}
  for _, previous in ipairs({ vim.fs.normalize(root), recipes.path_key(root) }) do
    local legacy = vim.fn.sha256(previous):sub(1, 16)
    if legacy ~= key then
      legacy_keys[key][#legacy_keys[key] + 1] = legacy
    end
  end
  return key
end

function M.path(key)
  key = key or M.key()
  if type(key) ~= "string" or not key:match("^[%w_+%.%-]+$") or #key > 96 then
    return nil, "invalid history project key"
  end
  return vim.fs.joinpath(vim.fn.stdpath("state"), "ue_search_history", key .. ".json")
end

local function clean_entry(entry)
  if
    type(entry) ~= "table"
    or type(entry.query) ~= "string"
    or entry.query == ""
    or #entry.query > recipes.limits.query
  then
    return
  end
  local out = {
    query = entry.query,
    kind = type(entry.kind) == "string" and entry.kind or "grep",
    count = math.min(1000000000, math.max(0, tonumber(entry.count) or 0)),
    last = tonumber(entry.last) or 0,
  }
  if entry.recipe then
    local recipe, err = recipes.validate(entry.recipe)
    out.recipe, out.unavailable = recipe, err
  elseif type(entry.unavailable) == "string" then
    out.unavailable = entry.unavailable:sub(1, 256)
  end
  return out
end

function M.load(key)
  key = key or M.key()
  local path, path_err = M.path(key)
  if not path then
    return {}, path_err
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then
    -- Old query-only history is imported read-only on the first publication.
    -- The old file remains intact; future reads use the canonical bucket.
    for _, legacy in ipairs(legacy_keys[key] or {}) do
      local legacy_path = M.path(legacy)
      if vim.uv.fs_stat(legacy_path) then
        return M.load(legacy)
      end
    end
    return {}
  end
  if stat.size > MAX_BYTES then
    return {}, "search history exceeds its byte budget"
  end
  local file, err = io.open(path, "rb")
  if not file then
    return {}, err
  end
  local raw = file:read(MAX_BYTES + 1)
  file:close()
  local ok, entries = pcall(vim.json.decode, raw or "")
  if not ok or type(entries) ~= "table" or not vim.islist(entries) then
    return {}, "search history is corrupt"
  end
  local out = {}
  for _, entry in ipairs(entries) do
    local cleaned = clean_entry(entry)
    if cleaned then
      out[#out + 1] = cleaned
    end
    if #out >= MAX_ENTRIES then
      break
    end
  end
  return out
end

local function identity(entry)
  if entry.recipe then
    return recipes.identity(entry.recipe)
  end
  return "legacy:" .. tostring(entry.kind) .. ":" .. entry.query:lower()
end

function M.merge(entries, entry)
  local newest = clean_entry(entry)
  if not newest then
    return entries or {}
  end
  local out, id = { newest }, identity(newest)
  for _, older in ipairs(entries or {}) do
    local cleaned = clean_entry(older)
    if cleaned then
      if identity(cleaned) == id then
        newest.count = newest.count + cleaned.count
      elseif #out < MAX_ENTRIES then
        out[#out + 1] = cleaned
      end
    end
  end
  local order = {}
  for index, item in ipairs(out) do
    order[item] = index
  end
  table.sort(out, function(a, b)
    return a.last == b.last and order[a] < order[b] or a.last > b.last
  end)
  return out
end

local function publish(path, entries)
  local raw = vim.json.encode(entries)
  while #raw > MAX_BYTES and #entries > 1 do
    table.remove(entries)
    raw = vim.json.encode(entries)
  end
  if #raw > MAX_BYTES then
    return nil, "search history entry exceeds its byte budget"
  end
  local temp = path .. ".tmp." .. tostring(vim.fn.getpid()) .. "." .. tostring(vim.uv.hrtime())
  local file, err = io.open(temp, "wb")
  if not file then
    return nil, err
  end
  local wrote, write_err = file:write(raw)
  local closed, close_err = file:close()
  if not wrote or not closed then
    vim.uv.fs_unlink(temp)
    return nil, write_err or close_err or "search history write failed"
  end
  local renamed, rename_err = vim.uv.fs_rename(temp, path)
  if not renamed then
    vim.uv.fs_unlink(temp)
    return nil, rename_err
  end
  return entries
end

local function flush(key)
  local queue = pending[key]
  if not queue or #queue == 0 then
    return M.load(key)
  end
  local path, path_err = M.path(key)
  if not path then
    return nil, path_err
  end
  local lease, lock_err = locks.acquire(path .. ".lock")
  if not lease then
    return nil, lock_err, true
  end
  local ok, entries, err = xpcall(function()
    local latest, load_err = M.load(key)
    if load_err then
      return nil, load_err
    end
    for _, entry in ipairs(queue) do
      latest = M.merge(latest, entry)
    end
    return publish(path, latest)
  end, debug.traceback)
  locks.release(lease)
  if not ok then
    return nil, entries
  end
  if entries then
    pending[key] = nil
  end
  return entries, err
end

local function retry(key, attempts)
  if scheduled[key] then
    return
  end
  scheduled[key] = true
  -- A bounded I/O retry belongs to this write, not a periodic task/status poll.
  vim.defer_fn(function()
    scheduled[key] = nil
    local entries, err, busy = flush(key)
    if entries then
      return
    end
    if busy and attempts > 0 then
      retry(key, attempts - 1)
    else
      pending[key] = nil
      vim.notify("Search history was not saved: " .. tostring(err), vim.log.levels.WARN)
    end
  end, 25)
end

function M.record(entry, key)
  key = key or (entry.recipe and M.key(entry.recipe.project)) or M.key()
  local path, path_err = M.path(key)
  if not path then
    return nil, path_err
  end
  local cleaned = clean_entry(entry)
  if not cleaned then
    return nil, "invalid search history entry"
  end
  pending[key] = pending[key] or {}
  if #pending[key] >= MAX_ENTRIES then
    return nil, "pending search history is full"
  end
  pending[key][#pending[key] + 1] = cleaned
  local entries, err, busy = flush(key)
  if busy then
    retry(key, 40)
  elseif not entries then
    pending[key] = nil
    vim.notify("Search history was not saved: " .. tostring(err), vim.log.levels.WARN)
  end
  return entries, err
end

function M.pending_count()
  local count = 0
  for _, entries in pairs(pending) do
    count = count + #entries
  end
  return count
end

M.limits = { entries = MAX_ENTRIES, bytes = MAX_BYTES }
return M
