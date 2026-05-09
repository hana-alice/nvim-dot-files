-- ue_goto.provider — async + sync LSP location producers.
--
-- All "where can I find symbol X" plumbing lives here:
--   * async_lsp_request          — single-method scatter/gather
--   * async_lsp_workspace_symbol — instant-track index probe
--   * async_lsp_definition_with_retry
--                                — precise-track def+impl+decl with empty-result retries
--   * sync_locations             — for references (results go to qf)
--   * gtags_fallback_async       — Track 3 fallback
--   * reconcile_landing_to_definition
--                                — post-jump stale-index correction (Tier 2: still
--                                  invoked from init.lua's wrapper but lives here so
--                                  Tier 3 can lift it into the response path).
--
-- No UI. No notifications. No buffer mutation. Returns Locations or
-- nil; callers decide what to do.

local location = require("utils.ue_goto.location")

local M = {}

-- Tunables (consumed via M.config; init.lua may override).
M.config = {
  -- workspace/symbol cancel deadline. Index queries should be sub-200ms;
  -- if it's slower clangd is rebuilding its index — let other tracks win.
  WS_TIMEOUT_MS = 5000,
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

-- Fire one LSP request round across all clients. Calls on_result(locations)
-- exactly once on the main thread. locations is nil iff every client failed
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

function M.async_lsp_request(bufnr, method, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
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

-- ---------------------------------------------------------------------------
-- workspace/symbol — instant track probe
-- ---------------------------------------------------------------------------

-- SymbolInformation.kind values valid for goto-definition.
local DEFINITION_KINDS = {
  [5] = true,   -- Class
  [6] = true,   -- Method
  [7] = true,   -- Property
  [8] = true,   -- Field
  [9] = true,   -- Constructor
  [10] = true,  -- Enum
  [11] = true,  -- Interface
  [12] = true,  -- Function
  [13] = true,  -- Variable
  [14] = true,  -- Constant
  [22] = true,  -- Struct
  [23] = true,  -- Event
  [24] = true,  -- Operator
  [25] = true,  -- TypeParameter
}

-- async_lsp_workspace_symbol(bufnr, query, exact, on_result):
--   Sends workspace/symbol to all clients on bufnr. Calls on_result once
--   with merged Location list (nil if empty) on the main thread.
--   Hard 5s ceiling — workspace/symbol is supposed to be sub-200ms; if it
--   blows past that, clangd is rebuilding and we'd rather let precise win.
function M.async_lsp_workspace_symbol(bufnr, query, exact, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" })
  if #clients == 0 then
    vim.schedule(function() on_result(nil) end)
    return
  end

  local pending = #clients
  local merged = {}
  local fired = false
  local timer = nil

  local function fire(arg)
    if fired then return end
    fired = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    on_result(arg)
  end

  local function dec_pending()
    pending = pending - 1
    if pending == 0 then fire(#merged > 0 and merged or nil) end
  end

  timer = vim.defer_fn(function() fire(#merged > 0 and merged or nil) end, M.config.WS_TIMEOUT_MS)

  for _, client in ipairs(clients) do
    local ok_req = pcall(function()
      client:request("workspace/symbol", { query = query }, function(err, result)
        if not err and type(result) == "table" then
          for _, sym in ipairs(result) do
            local keep = true
            if exact and sym.name ~= query then keep = false end
            if keep and sym.kind and not DEFINITION_KINDS[sym.kind] then keep = false end
            if keep and sym.location and sym.location.uri and sym.location.range then
              -- normalize SymbolInformation -> Location
              table.insert(merged, {
                uri = sym.location.uri,
                range = sym.location.range,
                _ws_kind = sym.kind,
                _ws_container = sym.containerName,
                -- Carry symbol name so post-jump reconcile can verify
                -- the landing line and silently fix stale-index drift.
                _sym_name = sym.name,
              })
            end
          end
        end
        dec_pending()
      end, bufnr)
    end)
    if not ok_req then dec_pending() end
  end
end

-- ---------------------------------------------------------------------------
-- Precise track: textDocument/definition with retry (single request — impl
-- and decl merging removed; cache + csearch_fallback in lsp_fallback handle
-- the "definition empty" case instead of inflating the response).
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

  -- Single textDocument/definition request, self-filtered. The previous
  -- implementation merged def + impl + decl across three round-trips; that
  -- pulled in N implementations of virtual functions and turned single-
  -- answer cases (e.g. FGlobalShader -> FGlobalShader's class decl) into
  -- multi-candidate picker UIs because impl returned every override. The
  -- cache + csearch fallback chain in lsp_fallback now handles "def empty"
  -- without needing to inflate def with siblings.
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

-- ---------------------------------------------------------------------------
-- Post-jump reconcile (drift correction)
-- ---------------------------------------------------------------------------

-- reconcile_landing_to_definition(sym, landed_line_1b):
--   Verify the landed line actually contains the symbol. If it doesn't,
--   the LSP gave us a stale line number (clangd's persistent index lags
--   real edits) — search the buffer for a real definition pattern near the
--   landing point and silently reposition.
--
--   Pure side-effect on the current buffer's cursor. Caller (init.lua's
--   jump wrapper) invokes after a successful jump.
--
--   Tier 3: lift the search into the response path (so jumper sees only
--   already-corrected locations) and delete this function.
function M.reconcile_landing_to_definition(sym, landed_line_1b, dtrace)
  if not sym or sym == "" then return true end

  local bufnr = vim.api.nvim_get_current_buf()
  local actual = vim.api.nvim_win_get_cursor(0)
  if dtrace then
    pcall(dtrace, "reconcile: ENTER sym=%q landed=%d actual_cursor=%d:%d",
      sym, landed_line_1b, actual[1], actual[2])
  end
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then return true end

  local cur_line_text = vim.api.nvim_buf_get_lines(
    bufnr, landed_line_1b - 1, landed_line_1b, false)[1] or ""

  -- Lua patterns can't do \b — fake word-boundary by checking neighbors.
  local function has_token(s, tok)
    if not s or s == "" then return false end
    local idx = 1
    while true do
      local a, b = s:find(tok, idx, true)
      if not a then return false end
      local before = (a > 1) and s:sub(a - 1, a - 1) or ""
      local after = s:sub(b + 1, b + 1)
      local function is_id_ch(c)
        return c ~= "" and c:match("[%w_]") ~= nil
      end
      if not is_id_ch(before) and not is_id_ch(after) then
        return true
      end
      idx = b + 1
    end
  end

  if has_token(cur_line_text, sym) then return true end

  local function escape_for_pattern(s)
    return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
  end
  local sym_pat = escape_for_pattern(sym)

  local def_patterns = {
    "class%s+" .. sym_pat .. "[%s:{<]",
    "class%s+" .. sym_pat .. "$",
    "struct%s+" .. sym_pat .. "[%s:{<]",
    "struct%s+" .. sym_pat .. "$",
    "using%s+" .. sym_pat .. "%s*=",
    "typedef%s+.*%s" .. sym_pat .. "%s*;",
    "enum%s+class%s+" .. sym_pat,
    "enum%s+" .. sym_pat,
    "namespace%s+" .. sym_pat,
    "%f[%w_]" .. sym_pat .. "%s*::%s*" .. sym_pat .. "%s*%(",
  }

  local windows = {
    { math.max(1, landed_line_1b - 200), math.min(line_count, landed_line_1b + 200) },
    { 1, line_count },
  }

  local best_line = nil
  local best_dist = math.huge
  for _, win in ipairs(windows) do
    local lo, hi = win[1], win[2]
    local lines = vim.api.nvim_buf_get_lines(bufnr, lo - 1, hi, false)
    for i, text in ipairs(lines) do
      for _, pat in ipairs(def_patterns) do
        if text:find(pat) then
          local lineno = lo + i - 1
          local dist = math.abs(lineno - landed_line_1b)
          if dist < best_dist then
            best_dist = dist
            best_line = lineno
          end
          break
        end
      end
    end
    if best_line then break end
  end

  if not best_line or best_line == landed_line_1b then
    if dtrace then pcall(dtrace, "reconcile: HARD-MISS no def-pattern found for %q near line %d", sym, landed_line_1b) end
    return false
  end

  local target_text = vim.api.nvim_buf_get_lines(
    bufnr, best_line - 1, best_line, false)[1] or ""
  local col = 0
  local s = target_text:find(sym, 1, true)
  if s then col = s - 1 end

  pcall(vim.api.nvim_win_set_cursor, 0, { best_line, col })
  if dtrace then pcall(dtrace, "reconcile: %q drift %d -> %d (Δ=%d)", sym, landed_line_1b, best_line, best_line - landed_line_1b) end
  return true
end

return M
