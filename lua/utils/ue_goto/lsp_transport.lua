-- One bounded LSP request round. Compiler preparation is supplied by callers.
local M = { HARD_CEILING_MS = 30000 }
local location = require("utils.ue_goto.location")
local transaction = require("utils.ue_goto.semantic_transaction")

local function reason(records)
  local supported = false
  for _, record in ipairs(records) do
    if record.status == "timeout" then return "provider-timeout" end
    if record.status == "preparation-error" then return record.error or "provider-error" end
    if record.status == "error" then return "provider-error" end
    supported = supported or record.supported
  end
  return supported and "empty" or "provider-method-unsupported"
end

function M.request(bufnr, method, callback, opts)
  opts = opts or {}
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method }) or {}
  local allowed
  if opts.client_ids then
    allowed = {}
    for _, id in ipairs(opts.client_ids) do allowed[id] = true end
  end
  clients = vim.tbl_filter(function(client)
    return (not allowed or allowed[client.id]) and (not opts.client_filter or opts.client_filter(client))
  end, clients)
  local records, pending, done, timer = {}, #clients, false, nil
  local requests, unregister = {}, nil
  local handle = {}
  local started = vim.uv.hrtime()
  local subject = opts.snapshot and (opts.snapshot.subject or opts.snapshot) or {}
  local function finish(timed_out, terminal_reason)
    if done then return end
    done = true
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    if unregister then unregister(); unregister = nil end
    if timed_out or terminal_reason then
      for _, request in ipairs(requests) do
        if not request.record.status and type(request.client.cancel_request) == "function" then
          pcall(request.client.cancel_request, request.client, request.id)
        end
      end
    end
    if timed_out then
      for _, record in ipairs(records) do
        if not record.status then record.status = "timeout" end
      end
    end
    vim.schedule(function()
      callback({ method = method, client_results = records, reason = terminal_reason or reason(records),
        document_version = subject.document_version,
        elapsed_ms = math.floor((vim.uv.hrtime() - started) / 1000000) })
    end)
  end
  handle.cancel = function() finish(false, "provider-cancelled") end
  if opts.register_cancel then unregister = opts.register_cancel(handle.cancel) end
  if done then
    if unregister then unregister(); unregister = nil end
    return handle
  end
  if opts.is_current and not opts.is_current() then handle.cancel(); return handle end
  if pending == 0 then finish(); return handle end
  timer = vim.defer_fn(function() finish(true) end, M.HARD_CEILING_MS)
  for _, client in ipairs(clients) do
    if done then break end
    local enc = client.offset_encoding or "utf-16"
    local record = { client_id = client.id, client_name = client.name, method = method,
      position_encoding = enc, document_version = subject.document_version, supported = true }
    records[#records + 1] = record
    local function complete(status, err, result)
      if done or record.status then return end
      record.status, record.error, record.result = status, err, result
      pending = pending - 1
      if pending == 0 then finish() end
    end
    if type(client.supports_method) == "function" then
      local ok, supports = pcall(client.supports_method, client, method)
      if ok then record.supported = supports end
    end
    if not record.supported then
      complete("unsupported")
    else
      local ok_params, params = pcall(function()
        if opts.snapshot then return transaction.make_position_params(opts.snapshot, bufnr, enc) end
        return vim.lsp.util.make_position_params(0, enc)
      end)
      if not ok_params or not params then
        complete("error", "make-params-failed")
      else
        if method == "textDocument/references" then params.context = { includeDeclaration = true } end
        local function send(prepared, prepare_reason, context)
          if done or record.status then return end
          if opts.is_current and not opts.is_current() then handle.cancel(); return end
          if not prepared then complete("preparation-error", prepare_reason); return end
          record.context = context
          local request_started = vim.uv.hrtime()
          local ok, accepted, request_id = pcall(client.request, client, method, params, function(err, result)
            if done or record.status then return end
            record.elapsed_ms = math.floor((vim.uv.hrtime() - request_started) / 1000000)
            complete(err and "error" or (result and "ok" or "empty"), err, result)
          end, bufnr)
          if ok and accepted ~= false and request_id and not record.status then
            if done then
              if type(client.cancel_request) == "function" then pcall(client.cancel_request, client, request_id) end
            else
              requests[#requests + 1] = { client = client, id = request_id, record = record }
            end
          end
          if not ok or accepted == false then complete("error", "request-rejected") end
        end
        if opts.prepare_client then
          local prepare_opts = vim.tbl_extend("force", {}, opts, {
            is_current = function()
              return not done and (not opts.is_current or opts.is_current())
            end,
          })
          local ok, err = pcall(opts.prepare_client, client, bufnr, send, prepare_opts)
          if not ok then complete("preparation-error", tostring(err)) end
        else
          send(true)
        end
      end
    end
  end
  return handle
end

function M.async_lsp_request(bufnr, method, callback, opts)
  return M.request(bufnr, method, function(result)
    if result.reason == "provider-cancelled" then
      result.locations = {}
      if opts and opts.structured then callback(result) else callback(nil) end
      return
    end
    local all = {}
    for _, record in ipairs(result.client_results) do
      record.locations = location.normalize_locations(record.result, record.position_encoding)
      vim.list_extend(all, record.locations)
    end
    result.locations = location.dedup_locations(all)
    if #result.locations > 0 then result.reason = "ok" end
    if opts and opts.structured then callback(result)
    else callback(#result.locations > 0 and result.locations or nil) end
  end, opts)
end

function M.sync_locations(method, timeout_ms)
  local clients = vim.lsp.get_clients({ bufnr = 0, method = method }) or {}
  if #clients == 0 then return nil, 0 end
  local all, errors, timed_out = {}, 0, false
  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local params = vim.lsp.util.make_position_params(0, enc)
    if method == "textDocument/references" then params.context = { includeDeclaration = true } end
    local ok, response = pcall(client.request_sync, client, method, params, timeout_ms or 5000, 0)
    if not ok or not response then timed_out = true
    elseif response.err then errors = errors + 1
    else vim.list_extend(all, location.normalize_locations(response.result, enc)) end
  end
  return #clients > 0 and location.dedup_locations(all) or nil, errors, timed_out
end

return M
