-- ue_goto.provider — async + sync LSP location producers.
--
-- All "where can I find symbol X" plumbing lives here:
--   * async_lsp_request          — single-method scatter/gather
--   * async_clangd_symbol_info   — compiler-owned USR at the exact cursor
--   * async_lsp_definition_with_retry
--                                — non-C++ definition request with empty-result retries
--   * sync_locations             — for references (results go to qf)
--   * gtags_fallback_async       — explicit/non-C++ fallback
--
-- No UI. No notifications. No buffer mutation. Returns Locations or
-- nil; callers decide what to do.

local location = require("utils.ue_goto.location")
local transaction = require("utils.ue_goto.semantic_transaction")
local clangd_commands = require("ue.clangd_commands")

local M = {}

-- Tunables (consumed via M.config; init.lua may override).
M.config = {
  -- Empty-result retries for textDocument/definition (clangd preamble).
  LSP_RETRY_COUNT = 20,
  LSP_RETRY_INTERVAL_MS = 2000,
}

-- ---------------------------------------------------------------------------
-- Sync helpers (used by references)
-- ---------------------------------------------------------------------------

function M.sync_locations(method, timeout_ms)
  local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
  if not clients or vim.tbl_isempty(clients) then
    return nil, 0
  end

  local all = {}
  local errors = 0
  local timed_out = false
  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local params = vim.lsp.util.make_position_params(0, enc)
    if method == "textDocument/references" then
      params.context = { includeDeclaration = true }
    end
    local ok, response = pcall(function()
      return client:request_sync(method, params, timeout_ms or 5000, 0)
    end)
    if not ok or response == nil then
      timed_out = true
    elseif response.err then
      errors = errors + 1
    elseif response.result and type(response.result) == "table" then
      vim.list_extend(all, location.normalize_locations(response.result, enc))
    end
  end
  return location.dedup_locations(all), errors, timed_out
end

-- ---------------------------------------------------------------------------
-- Async LSP request (single method scatter/gather)
-- ---------------------------------------------------------------------------

-- Fire one LSP request round across all clients, or only the explicit
-- opts.client_ids subset when compiler-identity verification has already
-- selected the authoritative responders. Calls on_result(locations) exactly
-- once on the main thread. locations is nil iff every selected client failed
-- or returned no result.
--
-- HARD CONTRACT (Tier-2 hardening, 2026-04-18):
--   on_result is invoked EXACTLY ONCE within REQUEST_HARD_CEILING_MS, no
--   matter what:
--     * no clients         → on_result(nil) on next tick
--     * make_params fails  → counts as one pending slot
--     * client:request raises → counts as one pending slot
--     * client never replies (clangd hung mid-preamble, network LSP
--       died, etc.) → ceiling timer fires on_result(nil)
--   This makes the function safe to chain into spinner cleanup paths
--   without leaking notices when the LSP server misbehaves.
local REQUEST_HARD_CEILING_MS = 30000

local function supports_method(client, method)
  if type(client.supports_method) == "function" then
    local ok, supported = pcall(client.supports_method, client, method)
    if ok then return supported end
  end
  return true
end

local function make_position_params(bufnr, encoding, opts)
  if opts and opts.snapshot then
    return transaction.make_position_params(opts.snapshot, bufnr, encoding)
  end
  return vim.lsp.util.make_position_params(0, encoding)
end

local function structured_reason(records, has_value, empty_reason)
  if has_value then return "ok" end
  if #records == 0 then return "provider-method-unsupported" end
  local supported = 0
  for _, record in ipairs(records) do
    if record.status == "timeout" then return "provider-timeout" end
    if record.status == "compile-command-unavailable" then
      return record.error and record.error.reason or "compile-command-unavailable"
    end
    if record.status == "error" or record.status == "request-threw"
        or record.status == "make-params-failed" then
      return "provider-error"
    end
    if record.supported then supported = supported + 1 end
  end
  if supported == 0 then return "provider-method-unsupported" end
  return empty_reason
end

function M.async_lsp_request(bufnr, method, on_result, opts)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method }) or {}
  if opts and type(opts.client_ids) == "table" then
    local allowed = {}
    for _, id in ipairs(opts.client_ids) do allowed[id] = true end
    clients = vim.tbl_filter(function(client) return allowed[client.id] == true end, clients)
  end
  if not clients or vim.tbl_isempty(clients) then
    vim.schedule(function()
      if opts and opts.structured then
        on_result({
          method = method,
          locations = {},
          client_results = {},
          reason = "provider-method-unsupported",
          document_version = opts.snapshot and (
            opts.snapshot.subject and opts.snapshot.subject.document_version
              or opts.snapshot.document_version) or nil,
          elapsed_ms = 0,
        })
      else
        on_result(nil)
      end
    end)
    return
  end

  local pending = #clients
  local all_items = {}
  local client_results = {}
  local done = false
  local ceiling_timer = nil
  local started_at = vim.uv.hrtime()

  local function finish(timed_out)
    if done then return end
    done = true
    if timed_out then
      for _, record in ipairs(client_results) do
        if not record.status then record.status = "timeout" end
      end
    end
    if ceiling_timer and not ceiling_timer:is_closing() then
      ceiling_timer:stop()
      ceiling_timer:close()
    end
    vim.schedule(function()
      local deduped = location.dedup_locations(all_items)
      if opts and opts.structured then
        on_result({
          method = method,
          locations = (#deduped > 0) and deduped or {},
          client_results = client_results,
          reason = structured_reason(client_results, #deduped > 0, "empty"),
          document_version = opts.snapshot and (
            opts.snapshot.subject and opts.snapshot.subject.document_version
              or opts.snapshot.document_version) or nil,
          elapsed_ms = math.floor((vim.uv.hrtime() - started_at) / 1000000),
        })
      else
        on_result(#deduped > 0 and deduped or nil)
      end
    end)
  end

  local function dec_pending()
    pending = pending - 1
    if pending <= 0 then finish() end
  end

  -- Hard ceiling: if any client never replies (clangd preamble crash,
  -- network LSP died, etc.) finish anyway with whatever we collected.
  ceiling_timer = vim.defer_fn(function()
    if not done then finish(true) end
  end, REQUEST_HARD_CEILING_MS)

  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local record = {
      client_id = client.id,
      client_name = client.name,
      method = method,
      supported = supports_method(client, method),
      document_version = opts and opts.snapshot and (
        opts.snapshot.subject and opts.snapshot.subject.document_version
          or opts.snapshot.document_version) or nil,
    }
    client_results[#client_results + 1] = record
    if not record.supported then
      record.status = "unsupported"
      dec_pending()
    else
      local ok_make, params = pcall(make_position_params, bufnr, enc, opts)
      if not ok_make or not params then
        record.status = "make-params-failed"
        dec_pending()
      else
        clangd_commands.ensure(client, bufnr, function(command_ok, command_reason, exact_command)
          if done then return end
          if not command_ok then
            record.status = "compile-command-unavailable"
            record.error = { reason = command_reason }
            dec_pending()
            return
          end
          record.exact_command = exact_command
          local request_started = vim.uv.hrtime()
          local ok_req = pcall(function()
            client:request(method, params, function(err, result)
              if done then return end -- ceiling already fired
              record.elapsed_ms = math.floor((vim.uv.hrtime() - request_started) / 1000000)
              record.error = err
              if not err and result and type(result) == "table" then
                record.locations = location.normalize_locations(result, enc)
                vim.list_extend(all_items, record.locations)
                record.status = #record.locations > 0 and "ok" or "empty"
              else
                record.locations = {}
                record.status = err and "error" or "empty"
              end
              dec_pending()
            end, bufnr)
          end)
          if not ok_req then
            record.status = "request-threw"
            dec_pending()
          end
        end, opts)
      end
    end
  end
end

-- clangd extension: return the unique USR for the exact cursor position plus
-- the ids of clients that returned that identity. Callers pass those ids into
-- async_lsp_request so an unrelated LSP client cannot contribute a location.
-- No rendered symbol text is used to choose a target.
function M.async_clangd_symbol_info(bufnr, on_result, opts)
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if tostring(client.name or ""):lower():find("clangd", 1, true) then
      clients[#clients + 1] = client
    end
  end
  if #clients == 0 then
    vim.schedule(function()
      if opts and opts.structured then
        on_result({
          client_results = {},
          identities = {},
          usr = nil,
          client_ids = {},
          reason = "provider-method-unsupported",
          document_version = opts and opts.snapshot and (
            opts.snapshot.subject and opts.snapshot.subject.document_version
              or opts.snapshot.document_version) or nil,
          elapsed_ms = 0,
        })
      else
        on_result(nil)
      end
    end)
    return
  end

  local pending, done, usr_clients = #clients, false, {}
  local client_results = {}
  local timer
  local started_at = vim.uv.hrtime()
  local function finish(timed_out)
    if done then return end
    done = true
    if timed_out then
      for _, record in ipairs(client_results) do
        if not record.status then record.status = "timeout" end
      end
    end
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    local values = vim.tbl_keys(usr_clients)
    local usr = #values == 1 and values[1] or nil
    local client_ids = {}
    local exact_command
    if usr then
      client_ids = vim.tbl_keys(usr_clients[usr])
      table.sort(client_ids)
      for _, record in ipairs(client_results) do
        if record.identity and record.identity.usr == usr and record.exact_command then
          exact_command = record.exact_command
          break
        end
      end
    end
    vim.schedule(function()
      if opts and opts.structured then
        local identities = {}
        for known_usr, known_clients in pairs(usr_clients) do
          identities[#identities + 1] = {
            usr = known_usr,
            client_ids = vim.tbl_keys(known_clients),
          }
        end
        table.sort(identities, function(a, b) return a.usr < b.usr end)
        on_result({
          client_results = client_results,
          identities = identities,
          usr = usr,
          client_ids = client_ids,
          exact_command = exact_command,
          reason = usr and "ok" or (#values > 1 and "identity-conflict"
            or structured_reason(client_results, false, "identity-missing")),
          document_version = opts and opts.snapshot and (
            opts.snapshot.subject and opts.snapshot.subject.document_version
              or opts.snapshot.document_version) or nil,
          elapsed_ms = math.floor((vim.uv.hrtime() - started_at) / 1000000),
        })
      else
        on_result(usr, client_ids)
      end
    end)
  end
  local function complete_one()
    pending = pending - 1
    if pending == 0 then finish() end
  end
  timer = vim.defer_fn(function() finish(true) end, REQUEST_HARD_CEILING_MS)

  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local record = {
      client_id = client.id,
      client_name = client.name,
      method = "textDocument/symbolInfo",
      supported = supports_method(client, "textDocument/symbolInfo"),
      document_version = opts and opts.snapshot and (
        opts.snapshot.subject and opts.snapshot.subject.document_version
          or opts.snapshot.document_version) or nil,
    }
    client_results[#client_results + 1] = record
    if not record.supported then
      record.status = "unsupported"
      complete_one()
    else
      local ok_params, params = pcall(make_position_params, bufnr, enc, opts)
      if not ok_params or not params then
        record.status = "make-params-failed"
        complete_one()
      else
        clangd_commands.ensure(client, bufnr, function(command_ok, command_reason, exact_command)
          if done then return end
          if not command_ok then
            record.status = "compile-command-unavailable"
            record.error = { reason = command_reason }
            complete_one()
            return
          end
          record.exact_command = exact_command
          local request_started = vim.uv.hrtime()
          local ok_request = pcall(function()
            client:request("textDocument/symbolInfo", params, function(err, result)
              if done then return end
              record.elapsed_ms = math.floor((vim.uv.hrtime() - request_started) / 1000000)
              record.error = err
              record.identity = nil
              if not done and not err and type(result) == "table" then
                local item = result.usr and result or result[1]
                if type(item) == "table" and type(item.usr) == "string" and item.usr ~= "" then
                  usr_clients[item.usr] = usr_clients[item.usr] or {}
                  if client.id ~= nil then usr_clients[item.usr][client.id] = true end
                  record.identity = { usr = item.usr, id = item.id }
                  record.status = "ok"
                else
                  record.status = "empty"
                end
              else
                record.status = err and "error" or "empty"
              end
              complete_one()
            end, bufnr)
          end)
          if not ok_request then
            record.status = "request-threw"
            complete_one()
          end
        end, opts)
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Non-C++ compatibility path: textDocument/definition with retry. C++ callers
-- use the exact semantic path in lsp_fallback and never enter this fallback.
-- ---------------------------------------------------------------------------

-- async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, on_result):
--   Builds a definition response that's actually useful for navigation:
--     1. Issue textDocument/definition.
--     2. If response is empty OR header-only AND an implementation client
--        exists, also query implementation and merge.
--     3. As a last resort, query declaration.
--     4. If everything is empty and we still have retries left, wait
--        LSP_RETRY_INTERVAL_MS and try again (clangd preamble building).
--
--   HARD CONTRACT (Tier-2 hardening, 2026-04-18):
--     on_result(locations|nil) is invoked EXACTLY ONCE, full stop. This
--     holds even when:
--       * still_current() returns false at any point during the chain
--         (we still finish the chain, just stop retrying)
--       * any underlying LSP request hangs / never responds
--         (async_lsp_request enforces its own hard ceiling)
--     Caller should still test still_current() before acting on the
--     result (the request may be stale), but is GUARANTEED that any
--     spinner / progress notice it owns will get a definitive
--     terminating callback. No leaked spinners. Ever.
function M.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, on_result)
  local attempts = 0
  local on_result_fired = false
  local function fire(locs)
    if on_result_fired then return end
    on_result_fired = true
    on_result(locs)
  end

  -- Single textDocument/definition request, self-filtered. Non-C++ callers
  -- retain their existing empty-result fallback outside this provider.
  local function def_only(inner)
    M.async_lsp_request(bufnr, "textDocument/definition", function(def_locs)
      def_locs = location.filter_self_locations(def_locs, ref_file, ref_line)
      inner(def_locs and #def_locs > 0 and def_locs or nil)
    end)
  end

  local function try_once()
    attempts = attempts + 1
    def_only(function(locs)
      if locs and #locs > 0 then
        fire(locs)
        return
      end
      -- Empty result. Decide whether to retry, but ALWAYS fire eventually.
      -- still_current() controls "should we keep retrying" but does NOT
      -- silence the final on_result — callers depend on it for cleanup.
      if attempts < M.config.LSP_RETRY_COUNT + 1 and still_current() then
        vim.defer_fn(function()
          if still_current() then
            try_once()
          else
            -- Stopped while waiting on retry — fire now so caller cleans up.
            fire(nil)
          end
        end, M.config.LSP_RETRY_INTERVAL_MS)
      else
        fire(nil)
      end
    end)
  end

  try_once()
end

-- ---------------------------------------------------------------------------
-- GTAGS fallback (async)
-- ---------------------------------------------------------------------------

function M.gtags_fallback_async(symbol, on_done)
  if not symbol then
    on_done(false)
    return
  end
  local ok, ue = pcall(require, "ue")
  if not ok then
    on_done(false)
    return
  end
  if ue.gtags_definition_async then
    ue.gtags_definition_async(symbol, on_done)
    return
  end
  -- Backward-compat: schedule sync version off the immediate keystroke so
  -- the press itself still feels responsive.
  vim.schedule(function()
    local r = ue.gtags_definition and ue.gtags_definition(symbol) or false
    on_done(r and true or false)
  end)
end

return M
