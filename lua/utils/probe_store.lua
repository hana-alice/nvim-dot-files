-- Probe persistence owner: locked delta merge and recoverable exit journals.
local M = {}
local lock = require("ue.file_lock")
local uv = vim.uv or vim.loop
local journals_written = {}
local sequence = 0

local function empty() return { version = 1, topics = {} } end
local function unique_id()
  sequence = sequence + 1
  return vim.fn.sha256(table.concat({ os.time(), vim.fn.getpid(), tostring(uv.hrtime()), sequence,
    math.random(1, 2147483646) }, ":"))
end

local function read_json(path, missing_ok)
  local file, err = io.open(path, "rb")
  if not file then
    if missing_ok then
      local stat, stat_err, code = uv.fs_stat(path)
      if not stat and (code == "ENOENT" or code == "ENOTDIR") then return empty() end
      err = stat_err or err
    end
    return nil, "read failed: " .. tostring(err)
  end
  local raw, read_err = file:read("*a")
  local closed, close_err = file:close()
  if not raw or not closed then return nil, "read failed: " .. tostring(read_err or close_err) end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return nil, "invalid JSON: " .. path end
  return decoded
end

local function checked_call(fn, ...)
  local ok, result, err = pcall(fn, ...)
  if not ok then return false, tostring(result) end
  return result ~= nil and result ~= false, err
end

local function atomic_write(path, value)
  local encoded, content = pcall(vim.json.encode, value)
  if not encoded then return false, "encode failed: " .. tostring(content) end
  local dir = vim.fs.dirname(path)
  local made, mkdir_err = pcall(vim.fn.mkdir, dir, "p")
  if not made then return false, "mkdir failed: " .. tostring(mkdir_err) end
  local staged = path .. ".tmp." .. unique_id()
  local file, open_err = io.open(staged, "wb")
  if not file then return false, "open failed: " .. tostring(open_err) end
  local wrote, write_err = checked_call(file.write, file, content)
  local flushed, flush_err = false, nil
  if wrote then flushed, flush_err = checked_call(file.flush, file) end
  local closed, close_err = checked_call(file.close, file)
  if not wrote or not flushed or not closed then
    pcall(uv.fs_unlink, staged)
    local phase = not wrote and "write" or not flushed and "flush" or "close"
    return false, phase .. " failed: " .. tostring(write_err or flush_err or close_err)
  end
  local renamed, rename_err = checked_call(uv.fs_rename, staged, path)
  if not renamed then pcall(uv.fs_unlink, staged); return false, "rename failed: " .. tostring(rename_err) end
  return true
end

local function failures(record)
  if record.failure_count ~= nil then return record.failure_count end
  local outcome = type(record.data) == "table" and record.data.state
  if outcome == "resolved" or outcome == "ok" or outcome == "cancelled" then return 0 end
  return record.count or 0
end

local function revision(topic)
  return topic and topic.observation and topic.observation.revision
end

local function same_lifecycle(left, right)
  return left.armed_until == right.armed_until and left.max_records == right.max_records
    and vim.deep_equal(left.observation, right.observation)
end

local function merge_stats(current, previous, target)
  if not current.stats then return end
  local old = previous.revision == current.revision and previous.stats or {}
  old = old or {}
  local merged = target.revision == current.revision and target.stats or nil
  merged = merged or { samples = 0, total_ms = 0, buckets = {}, outcomes = {} }
  for _, field in ipairs({ "samples", "total_ms" }) do
    merged[field] = (merged[field] or 0) + math.max(0, (current.stats[field] or 0) - (old[field] or 0))
  end
  for _, field in ipairs({ "buckets", "outcomes" }) do
    merged[field] = merged[field] or {}
    for key, value in pairs(current.stats[field] or {}) do
      merged[field][key] = (merged[field][key] or 0) + math.max(0, value - ((old[field] or {})[key] or 0))
    end
  end
  if current.stats.min_ms then merged.min_ms = math.min(merged.min_ms or current.stats.min_ms, current.stats.min_ms) end
  if current.stats.max_ms then merged.max_ms = math.max(merged.max_ms or current.stats.max_ms, current.stats.max_ms) end
  target.stats = merged
end

local function merge(latest, snapshot)
  local base = snapshot.base or empty()
  for name, local_topic in pairs(snapshot.data.topics or {}) do
    local base_topic = (base.topics or {})[name] or { records = {} }
    local target = latest.topics[name]
    local created = not target
    if created then target = { records = {} }; latest.topics[name] = target end
    target.records = target.records or {}
    local update = (snapshot.topic_updates or {})[name]
    local explicit = update == "arm" or update == "sleep"
    local compatible_revision = revision(target) == revision(base_topic) or revision(target) == revision(local_topic)
    -- Automatic observations compare the full lifecycle, so a delayed writer
    -- cannot revive an explicitly slept window of the same revision.
    if created or (update and ((explicit and compatible_revision)
        or same_lifecycle(target, base_topic) or same_lifecycle(target, local_topic))) then
      target.armed_until = local_topic.armed_until
      target.max_records = local_topic.max_records
      target.observation = vim.deepcopy(local_topic.observation)
    end
    for key, current in pairs(local_topic.records or {}) do
      local previous = (base_topic.records or {})[key] or {}
      local delta = math.max(0, (current.count or 0) - (previous.count or 0))
      if delta > 0 then
        local record = target.records[key]
        if not record then
          record = { count = 0, failure_count = 0, first = current.first, last = 0,
            data = vim.deepcopy(current.data), revision = current.revision }
          target.records[key] = record
        end
        record.failure_count = failures(record) + math.max(0, failures(current) - failures(previous))
        record.count = (record.count or 0) + delta
        record.first = math.min(record.first or current.first or os.time(), current.first or os.time())
        if current.revision == revision(target) then
          merge_stats(current, previous, record)
          if record.revision ~= current.revision or (current.last or 0) >= (record.last or 0) then
            record.last, record.data, record.revision = current.last, vim.deepcopy(current.data), current.revision
          end
        elseif record.revision == current.revision then
          record.last = math.max(record.last or 0, current.last or 0)
        end
      end
    end
  end
  for topic, updates in pairs(snapshot.record_updates or {}) do
    local records = latest.topics[topic] and latest.topics[topic].records or {}
    for key, update in pairs(updates) do
      local record = records[key]
      if record then
        record.seen_count = math.max(record.seen_count or 0, update.seen_count or 0)
        local incoming, previous = update.disposition, record.disposition
        if incoming and (not previous
            or (incoming.failures or incoming.count or 0) > (previous.failures or previous.count or 0)
            or ((incoming.failures or incoming.count or 0) == (previous.failures or previous.count or 0)
              and (incoming.at or 0) >= (previous.at or 0))) then
          record.disposition = vim.deepcopy(incoming)
        end
      end
    end
  end
end

local function pending_files(path)
  local dir = vim.fs.dirname(path)
  local prefix = vim.fs.basename(path) .. ".pending."
  local scan = uv.fs_scandir(dir)
  local files = {}
  if scan then
    while true do
      local name, kind = uv.fs_scandir_next(scan)
      if not name then break end
      if kind == "file" and name:sub(1, #prefix) == prefix and name:sub(-5) == ".json" then
        files[#files + 1] = { path = vim.fs.joinpath(dir, name), id = name:sub(#prefix + 1, -6) }
      end
    end
  end
  table.sort(files, function(a, b) return a.id < b.id end)
  return files
end

local function read_with_journals(path)
  local latest, err = read_json(path, true)
  if not latest then return nil, err end
  if type(latest.topics) ~= "table" then return nil, "invalid probe store topics" end
  local applied = latest.applied_journals or {}
  latest.applied_journals = applied
  local files, present = pending_files(path), {}
  for _, item in ipairs(files) do
    present[item.id] = true
    if not applied[item.id] then
      local journal, journal_err = read_json(item.path, false)
      if not journal then
        -- Another reader may have committed and removed this listed journal.
        if uv.fs_stat(item.path) then return nil, journal_err end
      elseif journal.id ~= item.id or type(journal.snapshot) ~= "table"
          or type(journal.snapshot.data) ~= "table" or type(journal.snapshot.data.topics) ~= "table" then
        return nil, "invalid probe journal: " .. item.path
      else
        merge(latest, journal.snapshot)
        applied[item.id] = true
      end
    end
  end
  for id in pairs(applied) do if not present[id] then applied[id] = nil end end
  if next(applied) == nil then latest.applied_journals = nil end
  return latest, nil, files
end

function M.read(path)
  local ok, latest, err = pcall(read_with_journals, path)
  if not ok then return nil, tostring(latest) end
  return latest, err
end

local function known_journal(path, snapshot)
  local known = journals_written[path]
  return known and vim.deep_equal(known.snapshot, snapshot) and known or nil
end

local function on_failure(path, snapshot, opts, reason)
  if not opts.exiting then return false, reason end
  local known = known_journal(path, snapshot)
  if known and known.durable then return false, reason, true end
  known = known or { id = unique_id(), snapshot = vim.deepcopy(snapshot) }
  local ok, err = atomic_write(path .. ".pending." .. known.id .. ".json", {
    version = 1, id = known.id, snapshot = known.snapshot,
  })
  if ok then known.durable = true; journals_written[path] = known end
  return false, ok and reason or (tostring(reason) .. "; journal: " .. tostring(err)), ok
end

function M.save(path, snapshot, opts)
  opts = opts or {}
  local acquired, lease, acquire_err = pcall(lock.acquire, path .. ".lock")
  if not acquired or not lease then
    return on_failure(path, snapshot, opts, "lock unavailable: " .. tostring(acquired and acquire_err or lease))
  end
  local called, saved, result = pcall(function()
    local latest, err, files = read_with_journals(path)
    if not latest then return false, err end
    if opts.compact then opts.compact(latest) end
    local known = known_journal(path, snapshot)
    if not known or not known.durable then merge(latest, snapshot) end
    if opts.compact then opts.compact(latest) end
    local ok, write_err = atomic_write(path, latest)
    if not ok then return false, write_err end
    -- IDs are committed with the merged counters before journal deletion.
    -- If deletion fails or the process exits here, replay sees the durable ID.
    for _, item in ipairs(files) do pcall(uv.fs_unlink, item.path) end
    return true, latest
  end)
  pcall(lock.release, lease)
  if not called then return on_failure(path, snapshot, opts, tostring(saved)) end
  if not saved then return on_failure(path, snapshot, opts, result) end
  return true, result
end

return M
