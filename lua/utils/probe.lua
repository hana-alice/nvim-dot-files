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

local DEFAULT_ARM_DAYS = 14
local DEFAULT_MAX_RECORDS = 200
local RECORD_TTL_DAYS = 30
local SAVE_DEBOUNCE_MS = 2000

local state = {
  loaded = false,
  data = nil,      -- { version=1, topics={ [t]={armed_until,max_records,records={ [k]={count,first,last,data} }} } }
  save_timer = nil,
  path_override = nil, -- test seam
}

local function now()
  return os.time()
end

local function probe_path()
  return state.path_override or (vim.fn.stdpath("state") .. "/ue_probes.json")
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
      table.sort(keys, function(a, b) return (recs[a].last or 0) < (recs[b].last or 0) end)
      for i = 1, #keys - cap do recs[keys[i]] = nil end
    end
    -- Auto-sleep expired topics
    if t.armed_until and t.armed_until < now() then
      t.armed_until = nil
    end
    -- Drop empty dormant topics entirely
    if next(recs) == nil and not t.armed_until then
      store.topics[topic] = nil
    else
      t.records = recs
    end
  end
  return store
end

local function load()
  if state.loaded then return end
  state.loaded = true
  state.data = empty_store()
  local f = io.open(probe_path(), "r")
  if not f then return end
  local content = f:read("*a")
  f:close()
  local ok, decoded = pcall(vim.json.decode, content or "")
  if ok and type(decoded) == "table" and type(decoded.topics) == "table" then
    state.data = compact_store(decoded)
  end
end

local function save_now()
  if not state.data then return end
  compact_store(state.data)
  local p = probe_path()
  local dir = vim.fn.fnamemodify(p, ":h")
  if vim.fn.isdirectory(dir) == 0 then vim.fn.mkdir(dir, "p") end
  local tmp = p .. ".tmp"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(vim.json.encode(state.data))
  f:close()
  pcall(vim.uv.fs_rename, tmp, p)
end

local function schedule_save()
  -- One-shot debounce; always stop+close the previous timer (F5 lesson).
  if state.save_timer then
    pcall(function() state.save_timer:stop() end)
    pcall(function() state.save_timer:close() end)
    state.save_timer = nil
  end
  local timer = vim.uv.new_timer()
  if not timer then save_now(); return end
  state.save_timer = timer
  timer:start(SAVE_DEBOUNCE_MS, 0, vim.schedule_wrap(function()
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
  schedule_save()
end

function M.sleep(topic)
  load()
  local t = state.data.topics[topic]
  if t then t.armed_until = nil; schedule_save() end
end

function M.is_armed(topic)
  load()
  local t = state.data.topics[topic]
  return (t and t.armed_until and t.armed_until >= now()) and true or false
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
  end
  key = tostring(key or "?")
  local r = t.records[key]
  if r then
    r.count = (r.count or 0) + 1
    r.last = now()
    if data ~= nil then r.data = data end
  else
    -- Distinct-key budget: hitting max_records puts the topic to sleep
    -- (flood guard — same philosophy as ue_watch F2, but self-sleeping).
    local n = 0
    for _ in pairs(t.records) do n = n + 1 end
    if n >= (t.max_records or DEFAULT_MAX_RECORDS) then
      t.armed_until = nil
      t.records["_overflow"] = t.records["_overflow"]
        or { count = 0, first = now(), last = now(), data = "max_records hit; topic slept" }
      t.records["_overflow"].count = t.records["_overflow"].count + 1
      t.records["_overflow"].last = now()
      schedule_save()
      return false
    end
    t.records[key] = { count = 1, first = now(), last = now(), data = data }
  end
  schedule_save()
  return true
end

-- ── reading ────────────────────────────────────────────────────────────────
function M.report()
  load()
  compact_store(state.data)
  local lines = {}
  local topics = {}
  for name in pairs(state.data.topics) do topics[#topics + 1] = name end
  table.sort(topics)
  if #topics == 0 then
    return { "(no probe evidence recorded)" }
  end
  for _, name in ipairs(topics) do
    local t = state.data.topics[name]
    local armed = (t.armed_until and t.armed_until >= now())
    lines[#lines + 1] = ("## %s  [%s%s]"):format(
      name, armed and "armed" or "dormant",
      armed and (" until " .. os.date("%m-%d", t.armed_until)) or "")
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
    end
    lines[#lines + 1] = ""
  end
  return lines
end

function M.compact()
  load()
  compact_store(state.data)
  save_now()
end

-- Count of records whose topic is armed — the "unread feedback" signal
-- surfaced at session start (spec requirement #1).
function M.pending_summary()
  load()
  local topics, records = 0, 0
  for _, t in pairs(state.data.topics) do
    local n = 0
    for _ in pairs(t.records or {}) do n = n + 1 end
    if n > 0 then
      topics = topics + 1
      records = records + n
    end
  end
  return { topics = topics, records = records }
end

-- ── commands ───────────────────────────────────────────────────────────────
function M.setup()
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
    M.compact()
    vim.notify("probe log compacted", vim.log.levels.INFO)
  end, { desc = "Probe: prune TTL-expired / over-cap records now" })

  return M
end

-- ── test seams ─────────────────────────────────────────────────────────────
function M._set_path_for_test(p)
  state.path_override = p
  state.loaded = false
  state.data = nil
end
function M._flush_for_test() save_now() end
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
