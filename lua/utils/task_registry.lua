-- lua/utils/task_registry.lua
-- ----------------------------------------------------------------------------
-- Generic background-task registry: list and cancel any background job the
-- config spawns. Zero business dependency (no require("ue")).
--
-- ARCHITECTURE — derived state, single writer (see openspec change
-- ue-task-manager design.md "从架构消除竞态"):
--
--   * Records hold ONLY { id, name, group, kind, handle, started_at }.
--     There is NO `state` field. Task status is a DERIVED quantity, computed
--     on demand by M.status(id) by querying the live handle (jobwait / uv
--     handle liveness). No stored copy ⇒ no "copy vs truth" ⇒ no sync ⇒ no
--     sync race. (D1/D2)
--
--   * The ONLY routine writer of `tasks` is M.register, called on the main
--     loop when a job is created. There is NO on_exit→mark_done write-back
--     path, so the classic "callback write vs command write" race edge does
--     not exist — it is structurally deleted, not rule-suppressed. (D4)
--
--   * M.cancel checks M.status first (skip kill if already exited), then
--     operates the handle (jobstop / :kill), and writes NOTHING back. The
--     next status/list query reflects "exited" naturally. Cancelling is
--     idempotent because killing an already-dead handle is an OS no-op. (D3)
--
--   * M.list() is "query, then trim": each row's status is computed live,
--     and exited records beyond KEEP_DONE are GC'd as a side effect of the
--     query. No timer, no periodic ticker (config rule P5). (D5)
--
-- Behavioral-equivalence contract for callers (design.md C-INV-1/2):
--   To register an existing job, the ONLY allowed edit is a single
--   `pcall(task_registry.register, ...)` AFTER the job-creation statement.
--   Callers MUST NOT insert any task_registry call into on_exit / vim.system
--   completion callbacks.
--
-- Public API
-- ----------
--   M.register(spec) -> id      spec = { name, group, kind, handle }
--                               kind = "job" (jobstart/termopen channel)
--                                    | "system" (vim.system handle)
--   M.status(id) -> status, code  status = "running"|"done"|"cancelled"|nil
--   M.cancel(id) -> ok          true if a live handle was actually stopped
--   M.cancel_all() -> n         number actually stopped
--   M.get(id) -> rec|nil        shallow record (no derived status)
--   M.list() -> { row, ... }    rows = { id, name, group, kind, status,
--                                         code, started_at }, GC side effect
--   M.running_count() -> n      live count (for statusline)
--   Test seams: M._reset_for_test(), M._set_probe_for_test(fn)
-- ----------------------------------------------------------------------------

local M = {}

-- Hard cap on retained terminal (exited/cancelled) records. Running tasks are
-- never trimmed. The config's concurrent task count is tiny (single digits),
-- so this is generous. GC happens lazily in list().
local KEEP_DONE = 16

local state = {
  tasks = {},      -- id -> { id, name, group, kind, handle, started_at, cancelled }
  next_id = 0,     -- monotonic, never reused
}

-- ---------------------------------------------------------------------------
-- Liveness probe — the single source of truth for status.
--
-- Returns "running" | "done" for a record, by querying the live handle.
-- Injectable for headless tests (M._set_probe_for_test).
--
-- IMPORTANT: this is the ONLY place that decides running-vs-exited. There is
-- no stored state to disagree with it.
-- ---------------------------------------------------------------------------
local function default_probe(rec)
  if rec.kind == "job" then
    -- jobwait with timeout 0 is non-blocking: -1 = still running,
    -- >= 0 = exit code, -2 = interrupted, -3 = invalid job id.
    local ok, res = pcall(vim.fn.jobwait, { rec.handle }, 0)
    if not ok or type(res) ~= "table" then
      return "done", nil
    end
    local w = res[1]
    if w == -1 then
      return "running", nil
    end
    -- -3 (invalid id) / -2 (interrupted) / >=0 (exit code) all mean "no longer
    -- a live job we control" → treat as done. Surface a numeric exit code.
    return "done", (type(w) == "number" and w >= 0) and w or nil
  else -- "system"
    local h = rec.handle
    -- vim.system handle exposes is_closing(); a closed/closing handle means
    -- the process has finished. Be defensive across Neovim versions.
    if type(h) == "table" then
      local ok_c, closing = pcall(function() return h:is_closing() end)
      if ok_c and closing then
        return "done", nil
      end
      -- pid present + not closing ⇒ assume running. If we can't tell, lean
      -- "running" so we never claim a live task is dead.
      return "running", nil
    end
    return "done", nil
  end
end

local probe = default_probe

-- ---------------------------------------------------------------------------
-- Public API
-- ---------------------------------------------------------------------------

--- Register a background task. Returns a monotonically increasing id.
--- Pure in-memory write — no vim.api/vim.fn/vim.notify/io/schedule (C-INV-2).
---@param spec table { name, group, kind, handle }
---@return integer|nil id, string? err
function M.register(spec)
  if type(spec) ~= "table" then
    return nil, "register: spec must be a table"
  end
  local kind = spec.kind
  if kind ~= "job" and kind ~= "system" then
    return nil, "register: kind must be 'job' or 'system'"
  end
  if spec.handle == nil then
    return nil, "register: handle is required"
  end
  state.next_id = state.next_id + 1
  local id = state.next_id
  state.tasks[id] = {
    id = id,
    name = spec.name or ("task#" .. id),
    group = spec.group or "task",
    kind = kind,
    handle = spec.handle,
    started_at = spec.started_at, -- caller may pass os.time(); optional
    cancelled = false,            -- only flips when WE issued the stop
  }
  return id
end

--- Derived status: queried live from the handle, never stored.
---@param id integer
---@return string|nil status ("running"|"done"|"cancelled"|nil), integer? code
function M.status(id)
  local rec = state.tasks[id]
  if not rec then
    return nil
  end
  local live, code = probe(rec)
  if live == "running" then
    return "running"
  end
  -- Exited. If we issued the cancel, report it as cancelled (display nicety);
  -- otherwise done. `cancelled` is NOT a state machine — it's a one-shot note
  -- of "who asked it to stop", set only on our own cancel path.
  if rec.cancelled then
    return "cancelled", code
  end
  return "done", code
end

--- Cancel a running task. Checks status first (skip kill if already exited),
--- then operates the handle. Writes no state back; idempotent.
---@param id integer
---@return boolean ok  true only when a live handle was actually stopped
function M.cancel(id)
  local rec = state.tasks[id]
  if not rec then
    return false
  end
  local live = probe(rec)
  if live ~= "running" then
    -- Already exited (or we already stopped it): nothing to do.
    return false
  end
  rec.cancelled = true
  if rec.kind == "job" then
    pcall(vim.fn.jobstop, rec.handle)
  else -- "system"
    pcall(function() rec.handle:kill(15) end)
  end
  return true
end

--- Cancel every currently-running task. Returns the number actually stopped.
---@return integer n
function M.cancel_all()
  local n = 0
  for id in pairs(state.tasks) do
    if M.cancel(id) then
      n = n + 1
    end
  end
  return n
end

--- Shallow record accessor (no derived status). Returns nil if absent.
---@param id integer
function M.get(id)
  return state.tasks[id]
end

--- List all tasks with live status, then GC exited records beyond KEEP_DONE.
--- Running tasks are never trimmed. The returned rows reflect the kept set
--- (trimmed records are excluded), so list() is the single "query + GC" path.
---@return table[] rows
function M.list()
  -- Pass 1: compute live status for every record; collect exited ids for GC.
  local status_of, code_of = {}, {}
  local exited = {}
  for id in pairs(state.tasks) do
    local status, code = M.status(id)
    status_of[id] = status
    code_of[id] = code
    if status ~= "running" then
      exited[#exited + 1] = id
    end
  end

  -- GC: keep only the newest KEEP_DONE exited records (highest id == newest,
  -- since id is monotonic). Drop the rest from the table.
  if #exited > KEEP_DONE then
    table.sort(exited) -- ascending id (oldest first)
    local drop = #exited - KEEP_DONE
    for i = 1, drop do
      state.tasks[exited[i]] = nil
    end
  end

  -- Pass 2: build rows from the surviving records.
  local rows = {}
  for id, rec in pairs(state.tasks) do
    rows[#rows + 1] = {
      id = id,
      name = rec.name,
      group = rec.group,
      kind = rec.kind,
      status = status_of[id],
      code = code_of[id],
      started_at = rec.started_at,
    }
  end

  -- Stable display order: running first, then by id descending (newest first).
  table.sort(rows, function(a, b)
    local ar = a.status == "running"
    local br = b.status == "running"
    if ar ~= br then
      return ar
    end
    return a.id > b.id
  end)
  return rows
end

--- Live count of running tasks (cheap; for statusline).
---@return integer n
function M.running_count()
  local n = 0
  for id in pairs(state.tasks) do
    if M.status(id) == "running" then
      n = n + 1
    end
  end
  return n
end

-- ---------------------------------------------------------------------------
-- Test seams
-- ---------------------------------------------------------------------------

function M._reset_for_test()
  state.tasks = {}
  state.next_id = 0
  probe = default_probe
end

--- Inject a custom liveness probe for headless tests. Pass nil to restore.
---@param fn fun(rec: table): string, integer?
function M._set_probe_for_test(fn)
  probe = fn or default_probe
end

M._KEEP_DONE = KEEP_DONE

return M
