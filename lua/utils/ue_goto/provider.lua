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

function M.async_lsp_request(bufnr, method, on_result, opts)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method }) or {}
  if opts and type(opts.client_ids) == "table" then
    local allowed = {}
    for _, id in ipairs(opts.client_ids) do allowed[id] = true end
    clients = vim.tbl_filter(function(client) return allowed[client.id] == true end, clients)
  end
  if not clients or vim.tbl_isempty(clients) then
    vim.schedule(function() on_result(nil) end)
    return
  end

  local pending = #clients
  local all_items = {}
  local done = false
  local ceiling_timer = nil

  local function finish()
    if done then return end
    done = true
    if ceiling_timer and not ceiling_timer:is_closing() then
      ceiling_timer:stop()
      ceiling_timer:close()
    end
    vim.schedule(function()
      on_result(#all_items > 0 and all_items or nil)
    end)
  end

  local function dec_pending()
    pending = pending - 1
    if pending <= 0 then finish() end
  end

  -- Hard ceiling: if any client never replies (clangd preamble crash,
  -- network LSP died, etc.) finish anyway with whatever we collected.
  ceiling_timer = vim.defer_fn(function()
    if not done then finish() end
  end, REQUEST_HARD_CEILING_MS)

  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local ok_make, params = pcall(vim.lsp.util.make_position_params, 0, enc)
    if not ok_make or not params then
      dec_pending()
    else
      local ok_req = pcall(function()
        client:request(method, params, function(err, result)
          if done then return end -- ceiling already fired
          if not err and result and type(result) == "table" then
            vim.list_extend(all_items, location.normalize_locations(result, enc))
          end
          dec_pending()
        end, bufnr)
      end)
      if not ok_req then
        dec_pending()
      end
    end
  end
end

-- clangd extension: return the unique USR for the exact cursor position plus
-- the ids of clients that returned that identity. Callers pass those ids into
-- async_lsp_request so an unrelated LSP client cannot contribute a location.
-- No rendered symbol text is used to choose a target.
function M.async_clangd_symbol_info(bufnr, on_result)
  local clients = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    if tostring(client.name or ""):lower():find("clangd", 1, true) then
      clients[#clients + 1] = client
    end
  end
  if #clients == 0 then
    vim.schedule(function() on_result(nil) end)
    return
  end

  local pending, done, usr_clients = #clients, false, {}
  local timer
  local function finish()
    if done then return end
    done = true
    if timer and not timer:is_closing() then timer:stop(); timer:close() end
    local values = vim.tbl_keys(usr_clients)
    local usr = #values == 1 and values[1] or nil
    local client_ids = {}
    if usr then
      client_ids = vim.tbl_keys(usr_clients[usr])
      table.sort(client_ids)
    end
    vim.schedule(function() on_result(usr, client_ids) end)
  end
  local function complete_one()
    pending = pending - 1
    if pending == 0 then finish() end
  end
  timer = vim.defer_fn(finish, 5000)

  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local ok_params, params = pcall(vim.lsp.util.make_position_params, 0, enc)
    if not ok_params or not params then
      complete_one()
    else
      local ok_request = pcall(function()
        client:request("textDocument/symbolInfo", params, function(err, result)
          if not done and not err and type(result) == "table" then
            local item = result.usr and result or result[1]
            if type(item) == "table" and type(item.usr) == "string" and item.usr ~= "" then
              usr_clients[item.usr] = usr_clients[item.usr] or {}
              if client.id ~= nil then usr_clients[item.usr][client.id] = true end
            end
          end
          complete_one()
        end, bufnr)
      end)
      if not ok_request then complete_one() end
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
