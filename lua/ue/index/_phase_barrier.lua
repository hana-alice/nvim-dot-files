-- Ordinary additive publications wait for the previous reader's background work.
return function(M, core)
  local records = {}
  local group
  local function key(ctx) return ctx and ctx.paths and ctx.paths.semantic_cdb end
  local function owns(client, ctx)
    if not client or client.name ~= "clangd" or (client.config or {})._ue_batch_scope
        or (M.phase_reader_eligible and not M.phase_reader_eligible(client))
        or (client.is_stopped and client:is_stopped()) then return false end
    local config = client.config or {}
    local cmd = config._ue_resolved_cmd or config.cmd
    if type(cmd) ~= "table" then return false end
    local directory
    for _, arg in ipairs(cmd) do
      if type(arg) == "string" and arg:find("compile-commands-dir", 1, true) then
        local value = arg:match("^%-%-compile%-commands%-dir=(.+)$")
        if not value or directory then return false end
        directory = value
      end
    end
    local path_key = require("utils.platform").driver().path_key
    return directory ~= nil and path_key(vim.fs.normalize(directory))
      == path_key(vim.fs.dirname(ctx.paths.semantic_cdb))
  end
  -- Evidence for the module-priority contract (hot finishes before full).
  -- Every terminal barrier outcome, and every full publication that had no
  -- barrier to wait on, is recorded with its reason; never notifies.
  local function probe(phase, status, reason, data)
    pcall(function()
      local record = core.deps.probe or require("utils.probe").record
      record("index-phase-barrier", phase .. ":" .. status .. ":" .. reason, vim.tbl_extend("force",
        { phase = phase, status = status, reason = reason,
          state = (status == "indexed" or status == "waited") and "ok" or "failed" }, data or {}))
    end)
  end
  local function finish(record, status, reason)
    if record.status ~= status or record.reason ~= reason then
      probe(record.phase or "?", status, reason, { generation = record.generation,
        waited_s = record.started_at and (vim.uv.now() - record.started_at) / 1000 or nil,
        began = record.began == true })
    end
    record.status, record.reason = status, reason
    if status == "indexed" and record.phase == "current" then record.first_stage_complete = true end
    local waiters = record.waiters
    record.waiters = {}
    for _, callback in ipairs(waiters) do vim.schedule(callback) end
    if core.deps.invalidate_status_cache then core.deps.invalidate_status_cache() end
    if core.deps.refresh_statusline then core.deps.refresh_statusline() end
  end
  local function valid(record)
    local state = core.h.ensure_index_state(record.ctx)
    if not state.index_selection or state.index_selection.generation_id ~= record.generation
        or not vim.deep_equal(record.signature, core.h.file_signature(key(record.ctx)))
        or not vim.deep_equal(record.base_signature, core.h.file_signature(record.base))
        or (M.source_refresh_pending and M.source_refresh_pending(record.ctx))
        or not require("ue.index.batch_metadata").is_ordinary(
          vim.fs.dirname(key(record.ctx)) .. "/batches.json") then return false end
    if record.client_id then
      return owns(vim.lsp.get_client_by_id(record.client_id), record.ctx)
    end
    return true
  end
  local function pending(record)
    return record and (record.status == "cdb-generated" or record.status == "indexing")
  end
  local function install()
    if group then return end
    group = vim.api.nvim_create_augroup("UEIndexPhaseBarrier", { clear = true })
    vim.api.nvim_create_autocmd("LspProgress", { group = group, callback = function(event)
      local data = event.data or {}
      local params = data.params or {}
      if params.token ~= "backgroundIndexProgress" then return end
      local client = vim.lsp.get_client_by_id(data.client_id)
      for _, record in pairs(records) do
        if pending(record) and record.observing and owns(client, record.ctx)
            and (not record.client_id or record.client_id == data.client_id) then
          if not valid(record) then finish(record, "bypassed", "inputs-or-reader-changed")
          elseif (params.value or {}).kind == "begin" then
            record.client_id, record.began, record.status = data.client_id, true, "indexing"
          elseif (params.value or {}).kind == "end" and record.began then
            finish(record, "indexed", "background-index-end")
          end
        end
      end
    end })
  end
  M.phase_publication_committed = function(ctx, generation, phase, publication)
    local scope = key(ctx)
    if not scope or not publication then return end
    if ctx._bypass_phase_barrier then M.bypass_phase_barrier(ctx); return end
    local old = records[scope]
    if old and old.generation ~= generation.generation_id then
      if pending(old) then finish(old, "bypassed", "generation-changed") end
      records[scope], old = nil, nil
    end
    if publication.changed == false and (old or phase ~= "current"
        or (core.h.ensure_index_state(ctx).index_selection or {}).coverage_level == "full") then return end
    if phase == "full" and publication.original_changed == true and not (old and (old.status == "indexed" or old.phase == "full")) then
      -- Full replaced the priority phase before its reader finished: priority lost.
      probe("full", "unordered", old and (old.reason or old.status) or "no-barrier-record",
        { generation = generation.generation_id, ordinary = publication.ordinary == true,
          previous_phase = old and old.phase or nil })
    end
    if publication.ordinary ~= true then
      if old and pending(old) then finish(old, "bypassed", "frozen-publication") end
      records[scope] = nil
      return
    end
    if publication.original_changed ~= true and (old or phase ~= "current") then return end
    if old and pending(old) then finish(old, "bypassed", "publication-replaced") end
    install()
    local base = M.base_compile_commands_path(ctx)
    local previous_reader = old and old.status == "indexed" and old.client_id
      and vim.lsp.get_client_by_id(old.client_id) or nil
    local previous_pending = previous_reader and previous_reader.progress and previous_reader.progress.pending
      and previous_reader.progress.pending.backgroundIndexProgress
    local record = { ctx = ctx, generation = generation.generation_id, phase = phase,
      status = "cdb-generated", started_at = vim.uv.now(), signature = core.h.file_signature(scope), base = base,
      base_signature = core.h.file_signature(base), waiters = {},
      observing = publication.original_append_only ~= true,
      completed_reader = previous_reader and not previous_pending and previous_reader.id or nil,
      first_stage_complete = old and old.generation == generation.generation_id and old.first_stage_complete or false }
    records[scope] = record
    -- A new session may reuse an unchanged partial CDB while its reader is
    -- already indexing. Absence of progress is never treated as completion.
    if publication.original_changed == false then
      for _, client in ipairs(vim.lsp.get_clients({ name = "clangd" })) do
        if owns(client, ctx) and client.progress and client.progress.pending
            and client.progress.pending.backgroundIndexProgress then
          record.client_id, record.began, record.status = client.id, true, "indexing"
          break
        end
      end
    end
    -- One fixed deadline per publication: repeated prepare cannot extend it.
    vim.defer_fn(function()
      if records[scope] == record and pending(record) then finish(record, "timeout", "background-index-timeout") end
    end, 180000)
  end
  M.phase_reader_loading = function(ctx, client)
    local record = records[key(ctx)]
    if pending(record) and owns(client, ctx) and (not record.client_id or record.client_id == client.id) then
      -- A matching reader may have consumed the append before the delayed reload.
      -- Adopt only a positive live begin after this same reader completed the
      -- previous stage; never adopt a timed-out stage's surviving progress.
      local active = record.completed_reader == client.id and client.progress and client.progress.pending
        and client.progress.pending.backgroundIndexProgress ~= nil
      record.observing, record.began, record.client_id = true, record.began or active == true, client.id
      if record.began then record.status = "indexing" end
    end
  end
  M.phase_barrier_pending = function(ctx)
    local record = records[key(ctx)]
    if ctx._bypass_phase_barrier and pending(record) then finish(record, "bypassed", "forced") end
    if pending(record) and not valid(record) then finish(record, "bypassed", "inputs-or-reader-changed") end
    return pending(record) == true
  end
  M.wait_phase_publication = function(ctx, callback)
    local record = records[key(ctx)]
    if not M.phase_barrier_pending(ctx) then callback(); return false end
    record.waiters[#record.waiters + 1] = callback
    local function check()
      if records[key(ctx)] ~= record or not pending(record) then return end
      if not valid(record) then finish(record, "bypassed", "inputs-or-reader-changed")
      else vim.defer_fn(check, 1000) end
    end
    vim.defer_fn(check, 1000)
    return true
  end
  M.bypass_phase_barrier = function(ctx)
    local record = records[key(ctx)]
    if record then finish(record, "bypassed", "forced") end
  end
  M.phase_barrier_status = function(ctx)
    local record = records[key(ctx)]
    if record and (core.h.ensure_index_state(ctx).index_selection or {}).generation_id ~= record.generation then
      return { phase = record.phase, status = "bypassed", first_stage_complete = false, reason = "generation-changed" }
    end
    if record then return { phase = record.phase, status = record.status,
      first_stage_complete = record.first_stage_complete, reason = record.reason } end
  end
  M.cancel_phase_barriers = function()
    for _, record in pairs(records) do finish(record, "bypassed", "cancelled") end
    records = {}
    if group then vim.api.nvim_del_augroup_by_id(group); group = nil end
  end
end
