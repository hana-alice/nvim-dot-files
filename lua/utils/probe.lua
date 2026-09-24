-- utils/probe.lua — proactive evidence probes with self-compacting log.
--
-- WHY (2026-07-26): every landed change used to wait for USER feedback
-- ("真机浸泡几天再看") to learn whether it actually behaves. Probes flip
-- that: call sites record evidence at the moment something noteworthy
-- happens; the next session READS the probe report FIRST and fixes what
-- it shows (spec: openspec/specs/probe-feedback-loop — requirement #1).
--
-- Design constraints honored:
--   * P6: record() is cheap (table upsert) + debounced async save; no
--     synchronous IO on hot paths beyond a deferred small-JSON write.
--   * P5: probes never notify. Evidence goes to the JSON log only;
--     the user (or agent) pulls via :UEProbeReport.
--   * F5/K40 lessons: the save timer is one-shot and always closed.
--
-- Lifecycle (probes can iterate & sleep):
--   * A topic auto-arms on first record() with a default TTL. After
--     `armed_until` passes OR `max_records` distinct keys accumulate,
--     the topic goes DORMANT: record() becomes a no-op (zero cost, call
--     sites never need changing). Re-arm to iterate: :UEProbeArm <topic>.
--   * DORMANT topics keep their records for reading until pruned.
--
-- Log hygiene (定期精简 / 重复项压缩):
--   * Dedup at write time: (topic, key) upserts {count, first, last,
--     data=last-seen payload} — a 10k-repeat event is ONE record.
--   * Compaction at every load/save: records older than RECORD_TTL_DAYS
--     dropped; per-topic record count capped (oldest-by-last-seen dropped);
--     empty topics removed. No unbounded growth by construction.
--
-- Public API:
--   M.record(topic, key, data?)   -- upsert evidence (no-op when dormant)
--   M.arm(topic, opts?)           -- (re-)arm: {days=14, max_records=200}
--   M.sleep(topic)                -- force-dormant
--   M.is_armed(topic)
--   M.report()                    -- render lines (newest-first per topic)
--   M.compact()                   -- explicit prune (also runs on load/save)
--   M.setup()                     -- install :UEProbe* commands

local M = {}
local store = require("utils.probe_store")

local DEFAULT_ARM_DAYS = 14
local DEFAULT_MAX_RECORDS = 200
local RECORD_TTL_DAYS = 30
local SAVE_DEBOUNCE_MS = 2000
local MAX_SAVE_DELAY_MS = 10000

local state = {
  loaded = false,
  data = nil,      -- { version=1, topics={ [t]={armed_until,max_records,records={ [k]={count,first,last,data} }} } }
  base = nil,      -- disk snapshot used to turn local counts into deltas
  topic_updates = {},
  record_updates = {},
  first_dirty_ms = nil,
  dirty = false,
  exiting = false,
  retry_ms = nil,
  load_error = nil,
  save_error = nil,
  save_timer = nil,
  exit_autocmd = nil,
  path_override = nil, -- test seam
}

local function now()
  return os.time()
end

local function probe_path()
  return state.path_override
    or vim.env.NVIM_UE_PROBE_PATH
    or (vim.fn.stdpath("state") .. "/ue_probes.json")
end

local function empty_store()
  return { version = 1, topics = {} }
end

-- ── compaction (dedup is at write time; this prunes by TTL + cap) ─────────
local function compact_store(store)
  local cutoff = now() - RECORD_TTL_DAYS * 86400
  for topic, t in pairs(store.topics) do
    local recs = t.records or {}
    -- TTL prune
    for k, r in pairs(recs) do
      if (r.last or 0) < cutoff then recs[k] = nil end
    end
    -- Per-topic cap: drop oldest by last-seen
    local cap = t.max_records or DEFAULT_MAX_RECORDS
    local keys = {}
    for k in pairs(recs) do keys[#keys + 1] = k end
    if #keys > cap then
      table.sort(keys, function(a, b)
        local revision = t.observation and t.observation.revision
        local a_current = not revision or recs[a].revision == revision
        local b_current = not revision or recs[b].revision == revision
        if a_current ~= b_current then return not a_current end
        -- `_overflow` is the only durable evidence that a topic self-slept;
        -- never let same-second timestamp ties prune it immediately.
        if a == "_overflow" and a_current then return false end
        if b == "_overflow" and b_current then return true end
        local a_last, b_last = recs[a].last or 0, recs[b].last or 0
        if a_last == b_last then return a < b end
        return a_last < b_last
      end)
      for i = 1, #keys - cap do recs[keys[i]] = nil end
    end
    -- Auto-sleep expired topics
    if t.armed_until and t.armed_until < now() then
      t.armed_until = nil
    end
    -- Drop empty dormant topics entirely
    if next(recs) == nil and not t.armed_until and not t.observation then
      store.topics[topic] = nil
    else
      t.records = recs
    end
  end
  return store
end

local schedule_save
local function load()
  if state.loaded then return end
  state.loaded = true
  local snapshot, err = store.read(probe_path())
  state.load_error = err
  state.data = snapshot and compact_store(snapshot) or empty_store()
  state.base = vim.deepcopy(state.data)
  if snapshot and next(snapshot.applied_journals or {}) then schedule_save() end
end

local function failure_count(record)
  if record.failure_count ~= nil then return record.failure_count end
  local outcome = type(record.data) == "table" and record.data.state
  if outcome == "resolved" or outcome == "ok" or outcome == "cancelled" then return 0 end
  return record.count or 0
end

local function save_now()
  if not state.data or not state.dirty then return true end
  compact_store(state.data)
  local ok, latest, durable = store.save(probe_path(), {
    data = state.data, base = state.base or empty_store(),
    topic_updates = state.topic_updates, record_updates = state.record_updates,
  }, { compact = compact_store, exiting = state.exiting })
  if ok or durable then
    if ok then state.data = latest end
    -- A durable recovery journal owns these deltas even if the primary write failed.
    state.base = vim.deepcopy(state.data)
    state.topic_updates = {}
    state.record_updates = {}
    state.first_dirty_ms = nil
    state.dirty = false
    state.retry_ms = nil
  end
  if ok then
    state.load_error = nil
    state.save_error = nil
  else
    state.save_error = latest
    if not durable and not state.exiting then
      state.retry_ms = math.min((state.retry_ms or 125) * 2, 5000)
      schedule_save(state.retry_ms, true)
    end
  end
  return ok, state.save_error, durable
end

local function cancel_save_timer()
  if not state.save_timer then return end
  pcall(function() state.save_timer:stop() end)
  pcall(function() state.save_timer:close() end)
  state.save_timer = nil
end

local function ensure_persistence()
  if state.exit_autocmd then return end
  local group = vim.api.nvim_create_augroup("UEProbePersistence", { clear = false })
  state.exit_autocmd = vim.api.nvim_create_autocmd("VimLeavePre", { group = group, callback = function()
    state.exiting = true
    cancel_save_timer()
    save_now()
  end })
end

schedule_save = function(delay_ms, retry)
  state.dirty = true
  if state.exiting then return end
  ensure_persistence()
  -- One-shot debounce; always stop+close the previous timer (F5 lesson).
  cancel_save_timer()
  local timer = vim.uv.new_timer()
  if not timer then
    state.save_error = "probe save timer unavailable"
    return
  end
  state.save_timer = timer
  local current_ms = vim.uv.hrtime() / 1e6
  if retry then state.first_dirty_ms = nil end
  state.first_dirty_ms = state.first_dirty_ms or current_ms
  local delay = math.min(delay_ms or SAVE_DEBOUNCE_MS, math.max(1, MAX_SAVE_DELAY_MS - (current_ms - state.first_dirty_ms)))
  if state.retry_ms then delay = math.max(delay, state.retry_ms) end
  timer:start(math.floor(delay), 0, vim.schedule_wrap(function()
    if state.save_timer == timer then
      pcall(function() timer:stop() end)
      pcall(function() timer:close() end)
      state.save_timer = nil
    end
    save_now()
  end))
end

-- ── lifecycle ──────────────────────────────────────────────────────────────
local function topic_of(store, topic, create)
  local t = store.topics[topic]
  if not t and create then
    t = { armed_until = now() + DEFAULT_ARM_DAYS * 86400,
          max_records = DEFAULT_MAX_RECORDS, records = {} }
    store.topics[topic] = t
  end
  return t
end

function M.arm(topic, opts)
  opts = opts or {}
  load()
  local t = topic_of(state.data, topic, true)
  t.armed_until = now() + (opts.days or DEFAULT_ARM_DAYS) * 86400
  if opts.max_records then t.max_records = opts.max_records end
  state.topic_updates[topic] = "arm"
  schedule_save()
end

function M.sleep(topic)
  load()
  local t = state.data.topics[topic]
  if t then
    t.armed_until = nil
    state.topic_updates[topic] = "sleep"
    schedule_save()
  end
end

function M.is_armed(topic)
  load()
  local t = state.data.topics[topic]
  return (t and t.armed_until and t.armed_until >= now()) and true or false
end

-- A repair opens one bounded observation window; repeated use does not renew it.
function M.observe(topic, revision, opts)
  assert(type(revision) == "string" and revision ~= "", "observation revision is required")
  opts = opts or {}
  load()
  local t = topic_of(state.data, topic, true)
  if t.observation and t.observation.revision == revision then return M.is_armed(topic) end
  t.observation = { revision = revision, started = now() }
  t.armed_until = now() + (opts.days or DEFAULT_ARM_DAYS) * 86400
  compact_store(state.data)
  state.topic_updates[topic] = "observe"
  schedule_save()
  return true
end

function M.status(topic)
  load()
  local t = state.data.topics[topic]
  local storage_error = state.save_error or state.load_error
  if not t then return { armed = false, records = 0, storage_error = storage_error } end
  return { armed = M.is_armed(topic), armed_until = t.armed_until,
    records = vim.tbl_count(t.records or {}), observation = vim.deepcopy(t.observation),
    storage_error = storage_error }
end

local function update_record(topic, key, status, note)
  load()
  local t = state.data.topics[topic]
  local record = t and t.records[key]
  if not record then return false end
  record.seen_count = record.count or 0
  local update = { seen_count = record.seen_count }
  if status then
    record.disposition = { status = status, count = record.count, failures = failure_count(record), at = now(),
      note = tostring(note or ""):sub(1, 512), revision = t.observation and t.observation.revision }
    update.disposition = vim.deepcopy(record.disposition)
  end
  state.record_updates[topic] = state.record_updates[topic] or {}
  local existing = state.record_updates[topic][key]
  if existing and not update.disposition then update.disposition = existing.disposition end
  state.record_updates[topic][key] = update
  schedule_save()
  return true
end

function M.acknowledge(topic, key)
  load()
  if topic and key then return update_record(topic, key) end
  for name, entry in pairs(state.data.topics) do
    if not topic or name == topic then
      for record_key in pairs(entry.records or {}) do update_record(name, record_key) end
    end
  end
  return true
end

function M.resolve(topic, key, note)
  assert(type(note) == "string" and note ~= "", "resolution evidence is required")
  return update_record(topic, key, "resolved", note)
end

function M.defer(topic, key, note)
  assert(type(note) == "string" and note ~= "", "deferral reason is required")
  return update_record(topic, key, "deferred", note)
end

local OUTCOMES = { resolved = true, unavailable = true, cancelled = true,
  ["invalid-semantic-context"] = true, ["ambiguous-context"] = true }

local function sample_stats(record, data)
  if type(data) ~= "table" then return end
  local elapsed = tonumber(data.elapsed_ms)
  if not data.state and not elapsed then return end
  local stats = record.stats or { samples = 0, total_ms = 0, buckets = {}, outcomes = {} }
  record.stats = stats
  if data.state then
    local outcome = OUTCOMES[data.state] and data.state or "unknown"
    stats.outcomes[outcome] = (stats.outcomes[outcome] or 0) + 1
  end
  if elapsed and elapsed >= 0 and elapsed < math.huge then
    stats.samples = stats.samples + 1
    stats.total_ms = stats.total_ms + elapsed
    stats.min_ms = math.min(stats.min_ms or elapsed, elapsed)
    stats.max_ms = math.max(stats.max_ms or elapsed, elapsed)
    local bucket = elapsed < 10 and "lt_10" or elapsed < 100 and "lt_100"
      or elapsed < 1000 and "lt_1000" or elapsed < 10000 and "lt_10000" or "ge_10000"
    stats.buckets[bucket] = (stats.buckets[bucket] or 0) + 1
  end
end

-- ── recording (dedup-compressed) ───────────────────────────────────────────
function M.record(topic, key, data)
  load()
  local t = state.data.topics[topic]
  if t then
    -- Existing topic: respect dormancy (probe is asleep → zero cost).
    if not t.armed_until or t.armed_until < now() then return false end
  else
    -- First-ever record auto-arms the topic (proactive by default).
    t = topic_of(state.data, topic, true)
    state.topic_updates[topic] = true
  end
  key = tostring(key or "?")
  local r = t.records[key]
  if r then
    r.failure_count = failure_count(r)
    r.count = (r.count or 0) + 1
    r.last = now()
    if data ~= nil then r.data = data end
  else
    -- Distinct-key budget: hitting max_records puts the topic to sleep
    -- (flood guard — same philosophy as ue_watch F2, but self-sleeping).
    local n = 0
    for _, existing in pairs(t.records) do
      if not t.observation or existing.revision == t.observation.revision then n = n + 1 end
    end
    if n >= (t.max_records or DEFAULT_MAX_RECORDS) then
      t.armed_until = nil
      state.topic_updates[topic] = true
      t.records["_overflow"] = t.records["_overflow"]
        or { count = 0, first = now(), last = now(), data = "max_records hit; topic slept" }
      t.records["_overflow"].count = t.records["_overflow"].count + 1
      t.records["_overflow"].last = now()
      t.records["_overflow"].revision = t.observation and t.observation.revision
      schedule_save()
      return false
    end
    t.records[key] = { count = 1, failure_count = 0, first = now(), last = now(), data = data }
  end
  r = t.records[key]
  local outcome = type(data) == "table" and data.state
  if outcome ~= "resolved" and outcome ~= "ok" and outcome ~= "cancelled" then
    r.failure_count = r.failure_count + 1
  end
  local revision = t.observation and t.observation.revision
  if r.revision ~= revision then r.stats = nil end
  r.revision = revision
  sample_stats(r, data)
  schedule_save()
  return true
end

-- ── reading ────────────────────────────────────────────────────────────────
function M.report()
  load()
  compact_store(state.data)
  local lines = {}
  local storage_error = state.save_error or state.load_error
  if storage_error then lines[#lines + 1] = "Probe storage error: " .. tostring(storage_error) end
  local topics = {}
  for name in pairs(state.data.topics) do topics[#topics + 1] = name end
  table.sort(topics)
  if #topics == 0 then
    lines[#lines + 1] = "(no probe evidence recorded)"
    return lines
  end
  for _, name in ipairs(topics) do
    local t = state.data.topics[name]
    local armed = (t.armed_until and t.armed_until >= now())
    lines[#lines + 1] = ("## %s  [%s%s]"):format(
      name, armed and "armed" or "dormant",
      armed and (" until " .. os.date("%m-%d", t.armed_until)) or "")
    if t.observation then lines[#lines + 1] = "  observation: " .. t.observation.revision end
    local keys = {}
    for k in pairs(t.records or {}) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
      return (t.records[a].last or 0) > (t.records[b].last or 0)
    end)
    for _, k in ipairs(keys) do
      local r = t.records[k]
      local span = (r.first and r.last and r.last ~= r.first)
        and (os.date("%m-%d", r.first) .. "→" .. os.date("%m-%d %H:%M", r.last))
        or os.date("%m-%d %H:%M", r.last or now())
      lines[#lines + 1] = ("  %4dx  %-40s  %s%s"):format(
        r.count or 0, k:sub(1, 40), span,
        r.data ~= nil and ("  | " .. tostring(vim.inspect(r.data)):gsub("%s+", " "):sub(1, 80)) or "")
      local disposition = r.disposition
      if disposition and (disposition.failures or disposition.count or 0) >= failure_count(r) then
        lines[#lines + 1] = "      " .. disposition.status .. ": " .. tostring(disposition.note)
      end
      if r.stats and r.stats.samples > 0 then
        lines[#lines + 1] = ("      latency: n=%d mean=%.1fms max=%.1fms"):format(
          r.stats.samples, r.stats.total_ms / r.stats.samples, r.stats.max_ms)
      end
    end
    lines[#lines + 1] = ""
  end
  return lines
end

function M.compact()
  load()
  compact_store(state.data)
  state.dirty = true
  cancel_save_timer()
  return save_now()
end

-- Retained evidence, unread samples, unresolved failures and dormant coverage
-- remain separate; reading is not proof of a repair.
function M.pending_summary()
  load()
  local topics, records, unread, unresolved, dormant = 0, 0, 0, 0, 0
  for _, t in pairs(state.data.topics) do
    local n = 0
    for _, record in pairs(t.records or {}) do
      n = n + 1
      if (record.count or 0) > (record.seen_count or 0) then unread = unread + 1 end
      local disposition = record.disposition
      if failure_count(record) > 0 and (not disposition or disposition.status ~= "resolved"
          or (disposition.failures or disposition.count or 0) < failure_count(record)) then
        unresolved = unresolved + 1
      end
    end
    if t.observation and (not t.armed_until or t.armed_until < now()) then dormant = dormant + 1 end
    if n > 0 then
      topics = topics + 1
      records = records + n
    end
  end
  return { topics = topics, records = records, unread = unread, unresolved = unresolved, dormant = dormant }
end

-- ── commands ───────────────────────────────────────────────────────────────
function M.setup()
  ensure_persistence()
  vim.api.nvim_create_user_command("UEProbeReport", function()
    local lines = M.report()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "markdown"
    vim.cmd("botright split")
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, buf)
    vim.api.nvim_win_set_height(win, math.min(#lines + 1, 20))
    vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
    M.acknowledge()
  end, { desc = "Probe: show evidence report (read this FIRST, fix findings)" })

  vim.api.nvim_create_user_command("UEProbeArm", function(a)
    local topic, days = a.fargs[1], tonumber(a.fargs[2])
    if not topic then vim.notify("usage: UEProbeArm <topic> [days]", vim.log.levels.WARN); return end
    M.arm(topic, { days = days })
    vim.notify("probe armed: " .. topic, vim.log.levels.INFO)
  end, { nargs = "*", desc = "Probe: (re-)arm a topic for N days (iterate)" })

  vim.api.nvim_create_user_command("UEProbeSleep", function(a)
    if a.args == "" then vim.notify("usage: UEProbeSleep <topic>", vim.log.levels.WARN); return end
    M.sleep(a.args)
    vim.notify("probe slept: " .. a.args, vim.log.levels.INFO)
  end, { nargs = "?", desc = "Probe: put a topic to sleep" })

  vim.api.nvim_create_user_command("UEProbeCompact", function()
    local ok, err = M.compact()
    vim.notify(ok and "probe log compacted" or ("probe compaction pending: " .. tostring(err)),
      ok and vim.log.levels.INFO or vim.log.levels.WARN)
  end, { desc = "Probe: prune TTL-expired / over-cap records now" })

  for command, handler in pairs({ UEProbeResolve = M.resolve, UEProbeDefer = M.defer }) do
    vim.api.nvim_create_user_command(command, function(a)
      if #a.fargs < 3 then
        vim.notify("usage: " .. command .. " <topic> <key> <evidence-or-reason>", vim.log.levels.WARN)
        return
      end
      if not handler(a.fargs[1], a.fargs[2], table.concat(a.fargs, " ", 3)) then
        vim.notify("probe record not found", vim.log.levels.WARN)
      end
    end, { nargs = "+", desc = "Probe: record evidence disposition without deleting history" })
  end

  return M
end

-- ── test seams ─────────────────────────────────────────────────────────────
function M._set_path_for_test(p)
  -- Never let a delayed save outlive its test path and spill into the next
  -- path (especially the real stdpath('state') store).
  cancel_save_timer()
  if state.exit_autocmd then pcall(vim.api.nvim_del_autocmd, state.exit_autocmd) end
  state.exit_autocmd = nil
  state.path_override = p
  state.loaded = false
  state.data = nil
  state.base = nil
  state.topic_updates = {}
  state.record_updates = {}
  state.first_dirty_ms = nil
  state.dirty = false
  state.exiting = false
  state.retry_ms = nil
  state.load_error = nil
  state.save_error = nil
end
function M._flush_for_test()
  cancel_save_timer()
  save_now()
end
function M._has_pending_save_for_test()
  return state.save_timer ~= nil
end
function M._now_shift_for_test(topic, key, seconds)
  load()
  local t = state.data.topics[topic]
  local r = t and t.records and t.records[key]
  if r then
    r.last = r.last + seconds
    r.first = r.first + seconds
  end
end
function M._compact_for_test()
  load()
  compact_store(state.data)
end

return M
