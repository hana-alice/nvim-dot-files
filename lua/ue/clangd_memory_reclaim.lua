-- ue/clangd_memory_reclaim.lua — give back clangd's indexing heap once the work is done.
--
-- WHY (measured 2026-10-26, clangd 22.1.5 on Windows, see docs/changelog.md)
-- Windows clangd has no malloc_trim (ClangdMain.cpp compiles it only under
-- __GLIBC__). In the measured run, memory stayed committed after BackgroundIndex
-- parsing. A 16-TU cold index left 3.32 GB private, 2.9 GB of it unaccounted by
-- $/memoryUsage; restarting over the same shards loaded in 15 s and held
-- 1.85 GB. Segment Heap (manifest or IFEO) did NOT help — falsified.
--
-- RULE: after a background-index run that actually indexed work (queue >=
-- min_tasks), wait until the editor is quiet, then restart that clangd once.
-- A shard reload reports a ~0/1 queue, so the restarted reader can never
-- trigger another reclaim (no restart loop). Restart itself goes through the
-- shared, debounced ue.index.maybe_restart_clangd_for_index path.

local M = {}

M.defaults = {
  enabled = true,
  min_tasks = 32,      -- smaller queues are edits, not a cold/large index
  quiet_ms = 60000,    -- wait after progress end before acting
  retries = 20,        -- re-check this many times while the editor is busy
  min_interval_ms = 30 * 60 * 1000, -- hard cap: at most one reclaim per window per session
}

local state = { group = nil, clients = {}, deps = nil, last_reclaim = nil }

local function options()
  local ok, cfg = pcall(require, "ue.config")
  local user = ok and cfg.get and cfg.get("clangd.memory_reclaim") or nil
  return vim.tbl_extend("force", M.defaults, type(user) == "table" and user or {})
end

--- Largest queue size from clangd's "done/total" progress message.
function M.queue_total(message)
  local total = type(message) == "string" and message:match("^%s*%d+%s*/%s*(%d+)") or nil
  return tonumber(total) or 0
end

local function probe(key, data)
  pcall(function()
    local record = (state.deps and state.deps.probe) or require("utils.probe").record
    record("clangd-memory-reclaim", key, data)
  end)
end

--- Why the reclaim must wait, or nil when it is safe to restart now.
function M.blocker(client, deps)
  deps = deps or {}
  if not client or (client.is_stopped and client:is_stopped()) then return "client-gone" end
  if (client.config or {})._ue_batch_scope then return "batch-scope-client" end
  local pending = client.progress and client.progress.pending
  if pending and pending.backgroundIndexProgress then return "indexing-again" end
  local mode = (deps.mode or vim.api.nvim_get_mode)().mode
  if mode ~= "n" then return "editor-busy" end
  if state.last_activity and (deps.now or vim.uv.now)() - state.last_activity < options().quiet_ms then
    return "editor-active"
  end
  local modified = deps.modified or function(buf) return vim.bo[buf].modified end
  local valid = deps.buffer_valid or vim.api.nvim_buf_is_valid
  for buf in pairs(client.attached_buffers or {}) do
    if valid(buf) and modified(buf) then return "unsaved-buffer" end
  end
  local index_job = deps.index_job or function() return require("ue.index")._rt.job end
  local prepare_running = deps.prepare_running or require("ue.index.prepare_observer").is_running
  if prepare_running() or index_job() ~= nil then return "prepare-running" end
  return nil
end

local function attempt(client_id, tries, epoch)
  local deps, opts = state.deps or {}, options()
  local entry = state.clients[client_id]
  if not entry or entry.done or entry.epoch ~= epoch then return end
  local client = (deps.get_client_by_id or vim.lsp.get_client_by_id)(client_id)
  local reason = M.blocker(client, deps)
  if reason == "client-gone" or reason == "indexing-again" then
    -- A new run will end again and re-arm with the accumulated queue.
    if reason == "client-gone" then state.clients[client_id] = nil end
    return
  end
  if reason then
    if tries < opts.retries then
      (deps.defer_fn or vim.defer_fn)(function() attempt(client_id, tries + 1, epoch) end, opts.quiet_ms)
    else
      probe("skipped:" .. reason, { tasks = entry.tasks, state = "failed" })
    end
    return
  end
  local restart = deps.restart or function(c)
    return require("ue.index").maybe_restart_clangd_for_index({
      get_clients = function() return { c } end, list_bufs = function() return {} end })
  end
  local now = (deps.now or vim.uv.now)()
  if state.last_reclaim and now - state.last_reclaim < opts.min_interval_ms then
    entry.done = true
    probe("skipped:interval", { tasks = entry.tasks, state = "ok" })
    return
  end
  local ok, started, delay = pcall(restart, client)
  if ok and started then
    entry.done, state.last_reclaim = true, now
    probe("restarted", { tasks = entry.tasks, state = "ok" })
  elseif ok and delay and tries < opts.retries then
    (deps.defer_fn or vim.defer_fn)(function() attempt(client_id, tries + 1, epoch) end, delay)
  else
    probe("restart-failed", { tasks = entry.tasks, error = not ok and tostring(started) or nil, state = "failed" })
  end
end

function M.on_activity()
  state.last_activity = ((state.deps or {}).now or vim.uv.now)()
end

--- LspProgress handler (public for headless tests).
function M.on_progress(client_id, client_name, params)
  if client_name ~= "clangd" or type(params) ~= "table" or params.token ~= "backgroundIndexProgress" then return end
  local value = params.value or {}
  local entry = state.clients[client_id] or { tasks = 0, done = false }
  state.clients[client_id] = entry
  entry.epoch = (entry.epoch or 0) + 1
  if value.kind == "report" or value.kind == "begin" then
    entry.tasks = math.max(entry.tasks, M.queue_total(value.message))
  elseif value.kind == "end" then
    local opts = options()
    if not opts.enabled or entry.done or entry.tasks < opts.min_tasks then return end
    local epoch = entry.epoch
    ;((state.deps or {}).defer_fn or vim.defer_fn)(function() attempt(client_id, 0, epoch) end, opts.quiet_ms)
  end
end

function M.setup(deps)
  state.deps = deps
  if state.group then return end
  state.group = vim.api.nvim_create_augroup("UEClangdMemoryReclaim", { clear = true })
  state.key_ns = vim.api.nvim_create_namespace("UEClangdMemoryReclaim")
  vim.on_key(M.on_activity, state.key_ns)
  pcall(function()
    require("utils.probe").observe("clangd-memory-reclaim", "quiet-prepare-guards-2026-10-27")
  end)
  vim.api.nvim_create_autocmd("LspProgress", { group = state.group, callback = function(event)
    local data = event.data or {}
    local client = vim.lsp.get_client_by_id(data.client_id)
    M.on_progress(data.client_id, client and client.name, data.params)
  end })
end

function M._reset_for_test()
  if state.group then pcall(vim.api.nvim_del_augroup_by_id, state.group) end
  if state.key_ns then vim.on_key(nil, state.key_ns) end
  state = { group = nil, clients = {}, deps = nil, last_reclaim = nil }
end

return M
