-- Event-driven promotion. Proof authority stays in batch_runtime.
local M = {}
local platform = require("utils.platform")
local documents = require("ue.index.batch_documents")
local document_failure = { ["live-document-modified"] = true, ["live-document-changed"] = true }

local function key(path) return platform.driver().path_key(vim.fs.normalize(path)) end

local function directory(client)
  local config = client.config or {}
  local cmd = config._ue_resolved_cmd or config.cmd
  if type(cmd) ~= "table" then return end
  for _, arg in ipairs(cmd) do
    local path = type(arg) == "string" and arg:match("^%-%-compile%-commands%-dir=(.+)$")
    if path then return key(path) end
  end
end

local function stamp(path)
  local value = vim.uv.fs_stat(path)
  if not value or value.type ~= "file" then return end
  return table.concat({ value.size, value.mtime.sec, value.mtime.nsec, value.ctime.sec, value.ctime.nsec }, ":")
end

local function stop_timer(entry)
  entry.timer_token = nil
  if entry.timer then pcall(entry.timer.stop, entry.timer); pcall(entry.timer.close, entry.timer); entry.timer = nil end
end

function M.new(deps)
  deps = deps or {}
  local runtime = deps.runtime or require("ue.index.batch_runtime")
  local schedule = deps.schedule or vim.schedule
  local defer = deps.defer or vim.defer_fn
  local now = deps.now_ms or function() return vim.uv.hrtime() / 1000000 end
  local clients = deps.get_clients or function() return vim.lsp.get_clients({ name = "clangd" }) end
  local restart = deps.restart or function(selected)
    return require("ue.index").maybe_restart_clangd_for_index({
      get_clients = function() return selected end, list_bufs = function() return {} end,
    })
  end
  local owner, entries, active, unsubscribe, stopped = {}, {}, nil, nil, false
  local evaluate, queue

  local function owns(entry, client)
    return directory(client) == key(vim.fs.dirname(entry.original))
      and not (client.config or {})._ue_batch_scope
  end

  local function reader(entry)
    local found
    for _, client in ipairs(clients()) do
      if owns(entry, client) and client.initialized and not (client.is_stopped and client:is_stopped()) then
        local attached = false
        for buf in pairs(client.attached_buffers or {}) do
          if vim.api.nvim_buf_is_loaded(buf) then attached = true; break end
        end
        if attached then if found then return end; found = client end
      end
    end
    return found
  end

  local function context(entry)
    if not vim.api.nvim_buf_is_loaded(entry.bufnr) then
      local selected = reader(entry)
      for buffer in pairs(selected and selected.attached_buffers or {}) do
        if vim.api.nvim_buf_is_loaded(buffer) then entry.bufnr = buffer; break end
      end
      if not vim.api.nvim_buf_is_loaded(entry.bufnr) then return end
    end
    local opts = entry.opts
    local ctx = (opts.resolve_context or function(buf)
      return require("ue").resolve_context({ bufname = vim.api.nvim_buf_get_name(buf) })
    end)(entry.bufnr)
    if not ctx or not ctx.paths or not ctx.paths.semantic_cdb or key(ctx.paths.semantic_cdb) ~= entry.scope then return end
    local config = opts.get_config and opts.get_config() or opts.config or {}
    return ctx, config
  end

  local function dirty(entry, ctx, config)
    return documents.modified(entry.bufnr, ctx, config.filetypes, function(client) return owns(entry, client) end)
  end

  local function identity(entry, ctx, config)
    local cmd = (entry.opts.get_command or function(root) return require("ue").clangd_cmd(root) end)(entry.root)
    local profile, reason = runtime.server_profile(cmd, config)
    if reason then return end
    local generation = (entry.opts.get_generation or function(value)
      return require("ue.index").generation_for_context(value).generation_id
    end)(ctx)
    local published = (entry.opts.fingerprint or stamp)(vim.fs.joinpath(vim.fs.dirname(entry.original), "batches.json"))
    if not generation or generation == "" or not published then return end
    local canonical = vim.deepcopy(cmd)
    for position, argument in ipairs(canonical) do
      if argument:match("^%-%-compile%-commands%-dir=") then
        canonical[position] = "--compile-commands-dir=" .. vim.fs.dirname(entry.original)
      end
    end
    return { generation = generation, stamp = published, profile = profile, command = canonical,
      environment = runtime.process_environment(config), cwd = config.cmd_cwd or vim.uv.cwd() }
  end

  local function client_identity(client)
    return vim.deepcopy({ cmd = client.config._ue_resolved_cmd or client.config.cmd,
      cwd = client.config.cmd_cwd, env = client.config.cmd_env })
  end

  local function wake_all(except)
    for _, entry in pairs(entries) do if entry ~= except and (entry.waiting or entry.busy) then queue(entry) end end
  end

  local function release(entry)
    entry.busy = false
    if active == entry then active = nil; wake_all(entry) end
  end

  local function abandon(entry)
    stop_timer(entry)
    entry.ticket = entry.ticket + 1
    entry.waiting, entry.phase = false, "idle"
    if entry.owned and entry.attempt then runtime.cancel_activation(entry.original, entry.attempt) end
    local state = runtime.activation(entry.original)
    if not entry.busy or (state and state.attempt == entry.attempt and state.pending_helpers == 0) then release(entry) end
    entry.owned = false
  end

  local function arm(entry, delay)
    if entry.timer or stopped then return end
    local ticket, token = entry.ticket, {}
    entry.timer_token = token
    entry.timer = defer(function()
      if entry.timer_token ~= token then return end
      entry.timer_token = nil
      entry.timer = nil
      if not stopped and entry.ticket == ticket then
        if entry.phase == "promoting" then evaluate(entry) else queue(entry) end
      end
    end, math.max(1, math.ceil(delay)))
  end

  local function observe(entry, state)
    -- Old helpers still own the serial slot even if a manual request replaced
    -- their activation. Their drain notification grants no new authority.
    if entry.busy and entry.attempt == state.attempt and state.failed and state.pending_helpers == 0 then release(entry) end
    local current = runtime.activation(entry.original)
    if not current or current.attempt ~= state.attempt then return end
    if stopped or entries[entry.scope] ~= entry then return end
    if document_failure[state.reason] then
      entry.waiting, entry.phase = true, "waiting"
    elseif state.failed then
      entry.waiting, entry.phase = false, "idle"
      stop_timer(entry)
    end
    if entry.waiting then queue(entry) end
  end

  local function promote(entry)
    local ctx, config = context(entry)
    local current = runtime.activation(entry.original)
    local selected = reader(entry)
    if not ctx or dirty(entry, ctx, config) or selected ~= entry.client
        or not vim.deep_equal(client_identity(selected), entry.client_identity)
        or not vim.deep_equal(identity(entry, ctx, config), entry.identity)
        or not current or not current.ready or current.attempt ~= entry.attempt then
      abandon(entry); return
    end
    entry.phase = "promoting"
    local ok, started, delay = pcall(restart, { selected })
    if not ok then abandon(entry); return end
    if not started then
      if type(delay) == "number" and delay > 0 then entry.phase = "ready"; arm(entry, delay)
      else abandon(entry) end
      return
    end
    -- The new client, not a successful stop request, confirms promotion.
    entry.waiting = false
    arm(entry, 15000)
  end

  local function finished(entry, ticket)
    if entry.ticket ~= ticket or stopped or entries[entry.scope] ~= entry then return end
    local current = runtime.activation(entry.original)
    if not current or current.attempt ~= entry.attempt then abandon(entry); return end
    if current.pending_helpers == 0 then release(entry) end
    if not current or not current.ready then
      if current and document_failure[current.reason] then entry.waiting, entry.phase = true, "waiting"
      else entry.waiting, entry.phase = false, "idle" end
      return
    end
    if current.pending_helpers > 0 then return end
    entry.phase = "ready"
    promote(entry)
  end

  evaluate = function(entry)
    if stopped or entries[entry.scope] ~= entry then return end
    if entry.phase == "promoting" then abandon(entry); return end -- one-shot attach deadline
    if not entry.waiting then return end
    local ctx, config = context(entry)
    if not ctx then abandon(entry); return end
    if dirty(entry, ctx, config) then
      stop_timer(entry)
      if entry.busy or entry.phase == "ready" then
        entry.ticket = entry.ticket + 1
        -- Use the existing dirty gate to revoke immediately, without another validator.
        runtime.prepare(entry.bufnr, entry.root, function() end, entry.opts)
      end
      entry.phase = "waiting"
      return
    end
    if entry.busy then
      if reader(entry) ~= entry.client or not vim.deep_equal(client_identity(entry.client), entry.client_identity)
          or not vim.deep_equal(identity(entry, ctx, config), entry.identity) then abandon(entry) end
      return
    end
    if entry.timer then return end
    if entry.phase == "ready" then promote(entry); return end
    if active then return end
    if entry.phase == "waiting" then entry.phase = "settling"; arm(entry, 200); return end
    local selected = reader(entry)
    if not selected then return end -- clean can precede the fallback reader's attachment
    local state = runtime.activation(entry.original)
    if state and state.pending_helpers > 0 then return end
    if state and state.retry_after and now() < state.retry_after then arm(entry, state.retry_after - now()); return end
    local snapshot = identity(entry, ctx, config)
    if not snapshot then abandon(entry); return end
    entry.identity, entry.client, entry.client_identity = snapshot, selected, client_identity(selected)
    entry.busy, active, entry.phase = true, entry, "validating"
    local ticket, before = entry.ticket, state and state.attempt
    local ok = pcall(runtime.prepare, entry.bufnr, entry.root, function()
      schedule(function() finished(entry, ticket) end)
    end, entry.opts)
    state = runtime.activation(entry.original)
    entry.attempt = state and state.attempt
    entry.owned = state and state.attempt ~= before or false
    if not ok then abandon(entry) end
  end

  queue = function(entry)
    if entry.queued or stopped then return end
    entry.queued = true
    schedule(function()
      entry.queued = false
      if entry.phase ~= "promoting" then evaluate(entry) end
    end)
  end

  local function subscribe()
    if unsubscribe then return end
    local callback = function() wake_all() end
    if deps.subscribe then unsubscribe = deps.subscribe(callback)
    else
      local id = vim.api.nvim_create_autocmd({ "BufModifiedSet", "BufWritePost", "BufDelete", "BufUnload", "LspAttach", "LspDetach" }, { callback = callback })
      unsubscribe = function() pcall(vim.api.nvim_del_autocmd, id) end
    end
  end

  function owner:prepare(bufnr, root, on_dir, opts)
    opts = opts or {}
    if stopped or opts.no_auto_recovery then return runtime.prepare(bufnr, root, on_dir, opts) end
    if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
    local ctx = (opts.resolve_context or function(buf) return require("ue").resolve_context({ bufname = vim.api.nvim_buf_get_name(buf) }) end)(bufnr)
    local original = ctx and ctx.paths and ctx.paths.semantic_cdb
    if not original then return runtime.prepare(bufnr, root, on_dir, opts) end
    local scope = key(original)
    local entry = entries[scope]
    if not entry then
      if vim.tbl_count(entries) >= 8 then return runtime.prepare(bufnr, root, on_dir, opts) end
      entry = { scope = scope, original = original, ticket = 1, phase = "idle" }
      entries[scope] = entry
      subscribe()
    end
    entry.bufnr, entry.root = bufnr, root
    local previous = opts.on_state
    entry.opts = vim.tbl_extend("force", opts, { on_state = function(state)
      if previous then pcall(previous, state) end
      observe(entry, state)
    end })
    local value, reason = runtime.prepare(bufnr, root, on_dir, entry.opts)
    if reason == "live-document-modified" then entry.waiting, entry.phase = true, "waiting"; queue(entry) end
    return value, reason
  end

  function owner:attach(client, bufnr)
    local accepted = runtime.attach(client, bufnr)
    local config = client.config or {}
    local entry = config._ue_batch_scope and entries[config._ue_batch_scope]
    if accepted and entry and entry.identity and config._ue_batch_attempt == entry.attempt
        and config._ue_batch_stamp == entry.identity.stamp then
      local state = runtime.activation(entry.original)
      if state and state.ready and state.attempt == entry.attempt then
        entry.ticket = entry.ticket + 1
        stop_timer(entry); entry.phase, entry.waiting, entry.owned = "idle", false, false
        if state.pending_helpers == 0 then release(entry) end
      end
    end
    wake_all()
  end

  function owner:status()
    local result = {}
    for scope, entry in pairs(entries) do result[#result + 1] = { scope = scope, phase = entry.phase,
      waiting = entry.waiting == true, busy = entry.busy == true, attempt = entry.attempt, timer = entry.timer ~= nil } end
    return result
  end

  function owner:stop()
    stopped = true
    if unsubscribe then unsubscribe(); unsubscribe = nil end
    for _, entry in pairs(entries) do abandon(entry) end
    entries = {}
  end
  return owner
end

local singleton
function M.prepare(...) singleton = singleton or M.new(); return singleton:prepare(...) end
function M.attach(...) singleton = singleton or M.new(); return singleton:attach(...) end
function M.status() return singleton and singleton:status() or {} end
function M.stop() if singleton then singleton:stop(); singleton = nil end end
return M
