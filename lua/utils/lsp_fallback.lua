-- LSP definition/references with GTAGS fallback.
-- Correctness-first design notes:
--   * Position params are computed PER CLIENT using that client's
--     offset_encoding (clangd is utf-16; mixing encodings silently
--     produces wrong positions on lines with multibyte chars).
--   * Async definition uses a request token so a stale callback from a
--     previous gd can never override a fresher one.
--   * filter_self_locations returns {} (not the original list) when
--     filtering removes everything; lets the next fallback step run
--     instead of jumping to the same line silently.
--   * try_jump treats a successful LSP result as terminal even if the
--     URI cannot be opened — we notify rather than fall through to
--     GTAGS which would jump to an unrelated symbol.
--   * gd is fully non-blocking. The main loop never waits on rg/global.
--     LSP and GTAGS race in parallel; LSP wins if it answers within
--     LSP_PRIMARY_WINDOW_MS, otherwise GTAGS jumps when ready.
--   * When LSP returns empty (preamble still building), we retry
--     LSP_RETRY_COUNT times with LSP_RETRY_INTERVAL_MS spacing before
--     accepting "no LSP result". Critical for cold clangd on UE.

local M = {}

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
-- After this many ms with no LSP answer, surface a "still working" notice.
local LSP_PROGRESS_NOTICE_MS = 600
-- Hard cap: if LSP+GTAGS still nothing after this, declare failure.
-- Big TUs (e.g. NaniteCullRaster.cpp) can take 30-60s to build a fresh
-- preamble + AST after first edit; we'd rather wait than wrong-jump.
local OVERALL_TIMEOUT_MS = 90000
-- Empty-result retries (clangd preamble building).
local LSP_RETRY_COUNT = 20
local LSP_RETRY_INTERVAL_MS = 2000
-- Update the progress notice on every retry so the user sees forward motion.
local PROGRESS_TICK_INTERVAL_MS = LSP_RETRY_INTERVAL_MS

-- Instant path config ---------------------------------------------------
-- The instant path uses workspace/symbol (no AST required). If it returns
-- a single high-confidence match within INSTANT_DEADLINE_MS, we jump
-- immediately and skip the AST-bound path.
local INSTANT_DEADLINE_MS = 400      -- give ws/symbol up to 400ms before
                                     -- letting precise path take over UI
local INSTANT_MAX_CANDIDATES = 50    -- if more than this match by name,
                                     -- bail (almost certainly the wrong
                                     -- query, e.g. cursor on `int`)
-- When set, after instant jump we still run the precise path; if it
-- returns a different location we surface a small notice.
local INSTANT_PRECISE_RECONCILE = true

-- ---------------------------------------------------------------------------
-- Symbol / position helpers
-- ---------------------------------------------------------------------------

local function current_symbol()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return nil
  end
  return word
end

local function normalize_locations(result, position_encoding)
  if type(result) ~= "table" then
    return {}
  end

  local locations = {}
  local items = vim.islist(result) and result or { result }
  for _, location in ipairs(items) do
    if type(location) == "table" and (location.uri or location.targetUri) then
      local copy = vim.deepcopy(location)
      copy._position_encoding = position_encoding
      locations[#locations + 1] = copy
    end
  end
  return locations
end

local function normalize_path(path)
  path = tostring(path or ""):gsub("\\", "/")
  path = path:gsub("/+$", "")
  return path
end

local function location_path(location)
  local uri = location and (location.uri or location.targetUri)
  if not uri or uri == "" then
    return ""
  end
  return normalize_path(vim.uri_to_fname(uri))
end

local function location_line(location)
  local range = location and (location.targetSelectionRange or location.targetRange or location.range)
  local start = range and range.start or nil
  return start and (tonumber(start.line) or 0) + 1 or 0
end

local function location_key(location)
  local range = location and (location.targetSelectionRange or location.targetRange or location.range)
  local s = range and range.start or nil
  local line = s and tonumber(s.line) or 0
  local col = s and tonumber(s.character) or 0
  return string.format("%s:%d:%d", location_path(location), line, col)
end

local function dedup_locations(locations)
  if not locations or #locations <= 1 then
    return locations
  end
  local seen = {}
  local out = {}
  for _, loc in ipairs(locations) do
    local key = location_key(loc)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = loc
    end
  end
  return out
end

local function locations_to_items_grouped(locations)
  local by_enc = {}
  for _, loc in ipairs(locations or {}) do
    local enc = loc._position_encoding or "utf-16"
    by_enc[enc] = by_enc[enc] or {}
    table.insert(by_enc[enc], loc)
  end
  local items = {}
  for enc, group in pairs(by_enc) do
    local converted = vim.lsp.util.locations_to_items(group, enc)
    if converted and #converted > 0 then
      vim.list_extend(items, converted)
    end
  end
  return items
end

local function populate_quickfix(title, locations)
  local items = locations_to_items_grouped(locations)
  if not items or vim.tbl_isempty(items) then
    return false
  end
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("botright copen 10")
  return true
end

local function jump_to_location(location)
  local uri = location.uri or location.targetUri
  if uri then
    -- Pre-load the target buffer so vim.lsp.util.show_document doesn't end
    -- up calling nvim_win_set_cursor on a still-empty (lazy bufadd'd)
    -- buffer, which would raise "Cursor position outside buffer" and
    -- strand the caller. We must use :edit (not just bufload) because
    -- bufload alone doesn't always trigger BufReadCmd autocommands that
    -- some configs rely on (treesitter, lsp attach, filetype, etc.).
    -- However, for files already loaded, :edit is a no-op-ish.
    local target_path = vim.uri_to_fname(uri)
    local bufnr = vim.fn.bufnr(target_path)
    if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
      -- Use silent :edit so it doesn't print "X lines" message during
      -- the async callback. Wrap in pcall in case the path is unreadable.
      pcall(vim.cmd, "silent! edit " .. vim.fn.fnameescape(target_path))
    end
  end
  vim.cmd("normal! m'")
  return vim.lsp.util.show_document(location, location._position_encoding or "utf-16", {
    reuse_win = true,
    focus = true,
  })
end

local function filter_self_locations(locations, ref_file, ref_line)
  if not locations or #locations == 0 then
    return locations
  end
  ref_file = ref_file or normalize_path(vim.api.nvim_buf_get_name(0))
  ref_line = ref_line or vim.api.nvim_win_get_cursor(0)[1]

  local filtered = {}
  for _, location in ipairs(locations) do
    if location_path(location) ~= ref_file or location_line(location) ~= ref_line then
      filtered[#filtered + 1] = location
    end
  end
  return filtered
end

-- ---------------------------------------------------------------------------
-- Sync helpers (used by references)
-- ---------------------------------------------------------------------------

local function sync_locations(method, timeout_ms)
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
      vim.list_extend(all, normalize_locations(response.result, enc))
    end
  end
  return dedup_locations(all), errors, timed_out
end

-- ---------------------------------------------------------------------------
-- Async LSP request
-- ---------------------------------------------------------------------------

local request_token = 0

-- Fire one LSP request round across all clients. Calls on_result(locations)
-- exactly once on the main thread. locations is nil iff every client failed
-- or returned no result.
local function async_lsp_request(bufnr, method, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  if not clients or vim.tbl_isempty(clients) then
    vim.schedule(function() on_result(nil) end)
    return
  end

  local pending = #clients
  local all_items = {}
  local done = false

  local function finish()
    if done then return end
    done = true
    vim.schedule(function()
      on_result(#all_items > 0 and all_items or nil)
    end)
  end

  local function dec_pending()
    pending = pending - 1
    if pending <= 0 then finish() end
  end

  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local ok_make, params = pcall(vim.lsp.util.make_position_params, 0, enc)
    if not ok_make or not params then
      dec_pending()
    else
      local ok_req = pcall(function()
        client:request(method, params, function(err, result)
          if not err and result and type(result) == "table" then
            vim.list_extend(all_items, normalize_locations(result, enc))
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
-- Location ranking helpers (used by async_lsp_definition_with_retry below
-- and by M.definition's rerank). Defined here so they're visible to the
-- async retry logic which decides whether to also query implementation.
-- ---------------------------------------------------------------------------

-- Path-based ranking for "go to implementation" candidates. We trust LSP for
-- semantic correctness (it gave us the right symbol's overrides), but among
-- multiple overrides we want the one matching the current target platform —
-- e.g. RHICreateShaderBundle on Win64 should land in D3D12RHI, not the base
-- virtual declaration in DynamicRHI.h.
local function score_location_for_platform(loc, platform_hints, current_buf_path)
  local path = location_path(loc):lower()
  if path == "" then
    return -math.huge
  end

  local score = 0

  -- Strong preference: source files over headers (real implementation).
  if path:match("%.cpp$") or path:match("%.mm$") or path:match("%.cc$") then
    score = score + 500
  elseif path:match("%.inl$") or path:match("%.ipp$") then
    score = score + 200
  elseif path:match("%.h$") or path:match("%.hpp$") or path:match("%.hxx$") then
    score = score + 0
  end

  -- Penalize known wrappers / validation layers — they forward, they're not
  -- the actual implementation the user wants to read.
  if path:match("rhivalidation") then score = score - 800 end
  if path:match("rhi/public/dynamicrhi") then score = score - 400 end
  if path:match("/null") or path:match("nullrhi") then score = score - 600 end
  if path:match("/mock") or path:match("/stub") then score = score - 600 end

  -- Platform hint matching: earlier in the priority list = bigger boost.
  if platform_hints then
    for i, kw in ipairs(platform_hints) do
      if kw and kw ~= "" and path:find(kw:lower(), 1, true) then
        score = score + math.max(100, 1000 - (i - 1) * 100)
        break
      end
    end
  end

  -- Same-module preference: if the candidate lives in the same UE module
  -- directory as the current buffer (e.g. .../Renderer/...), nudge it.
  if current_buf_path and current_buf_path ~= "" then
    local cur_module = current_buf_path:lower():match("/source/[^/]+/([^/]+)/")
    local cand_module = path:match("/source/[^/]+/([^/]+)/")
    if cur_module and cand_module and cur_module == cand_module then
      score = score + 50
    end
  end

  return score
end

local function rerank_locations(locations, platform_hints, current_buf_path)
  if not locations or #locations <= 1 then
    return locations
  end
  local scored = {}
  for _, loc in ipairs(locations) do
    table.insert(scored, {
      loc = loc,
      score = score_location_for_platform(loc, platform_hints, current_buf_path),
    })
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  local out = {}
  for _, e in ipairs(scored) do
    out[#out + 1] = e.loc
  end
  return out
end

-- A definition result is "thin" if every candidate is a .h file — likely a
-- forward/declaration/inline-trampoline, which means the user probably wants
-- the implementation (.cpp) instead. We use this to decide whether to also
-- query textDocument/implementation and merge.
local function is_thin_header_only(locations)
  if not locations or #locations == 0 then return false end
  for _, loc in ipairs(locations) do
    local p = location_path(loc):lower()
    if p:match("%.cpp$") or p:match("%.mm$") or p:match("%.cc$") then
      return false
    end
  end
  return true
end

-- Decide whether a top-1 candidate clearly wins. If yes, jump directly even
-- when there are multiple results. Margin >= 200 = a confident pick.
local function clear_winner(scored_locations, platform_hints, current_buf_path)
  if #scored_locations < 2 then return scored_locations[1] end
  local s1 = score_location_for_platform(scored_locations[1], platform_hints, current_buf_path)
  local s2 = score_location_for_platform(scored_locations[2], platform_hints, current_buf_path)
  if s1 - s2 >= 200 then return scored_locations[1] end
  return nil
end

-- ---------------------------------------------------------------------------
-- workspace/symbol path: AST-free, fast, fuzzy. We filter to exact name
-- match because gd semantics require it.
-- ---------------------------------------------------------------------------

-- SymbolInformation.kind values we want for goto-definition.
-- Filter out things like Module/File/Namespace which can't be a "definition".
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
--   Sends workspace/symbol to all clients on bufnr.
--   Calls on_result(locations|nil) once when all clients have replied
--   (or after 5s, whichever first).
--   When `exact` is true, filters results whose .name ~= query.
local function async_lsp_workspace_symbol(bufnr, query, exact, on_result)
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

  -- Hard 5s ceiling — workspace/symbol should be < 200ms; if it's slower
  -- something is wrong (e.g. clangd is rebuilding its symbol DB) and we'd
  -- rather let the precise path / GTAGS take over.
  timer = vim.defer_fn(function() fire(#merged > 0 and merged or nil) end, 5000)

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
                -- carry kind for later ranking
                _ws_kind = sym.kind,
                _ws_container = sym.containerName,
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

-- Async LSP definition with built-in retry for empty results (clangd preamble
-- still building) AND smart implementation merging when definition only
-- returns headers (which usually means the user is on a virtual interface
-- declaration and wants the platform-specific override).
--
-- Calls on_result(locations|nil) exactly once.
local function async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, on_result)
  local attempts = 0

  -- Run definition + (conditionally) implementation, merge & dedup. Calls
  -- inner(merged|nil) once.
  local function def_plus_impl(inner)
    async_lsp_request(bufnr, "textDocument/definition", function(def_locs)
      if not still_current() then return end
      def_locs = filter_self_locations(def_locs, ref_file, ref_line)

      -- If definition gave us a real source file (not header-only), use it.
      if def_locs and #def_locs > 0 and not is_thin_header_only(def_locs) then
        inner(def_locs)
        return
      end

      -- Definition was empty OR header-only. Try implementation in parallel
      -- with declaration as a backup.
      local has_impl = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/implementation" }) > 0
      if not has_impl then
        -- No implementation method; fall back to declaration as before.
        local has_decl = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/declaration" }) > 0
        if has_decl then
          async_lsp_request(bufnr, "textDocument/declaration", function(decl_locs)
            if not still_current() then return end
            decl_locs = filter_self_locations(decl_locs, ref_file, ref_line)
            local merged = {}
            if def_locs then vim.list_extend(merged, def_locs) end
            if decl_locs then vim.list_extend(merged, decl_locs) end
            inner(#merged > 0 and merged or nil)
          end)
        else
          inner(def_locs and #def_locs > 0 and def_locs or nil)
        end
        return
      end

      async_lsp_request(bufnr, "textDocument/implementation", function(impl_locs)
        if not still_current() then return end
        impl_locs = filter_self_locations(impl_locs, ref_file, ref_line)

        -- Merge def + impl, dedup.
        local merged = {}
        if def_locs then vim.list_extend(merged, def_locs) end
        if impl_locs then vim.list_extend(merged, impl_locs) end
        merged = dedup_locations(merged)

        if #merged > 0 then
          inner(merged)
          return
        end

        -- Nothing useful from def or impl; try declaration as a last resort.
        local has_decl = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/declaration" }) > 0
        if has_decl then
          async_lsp_request(bufnr, "textDocument/declaration", function(decl_locs)
            if not still_current() then return end
            decl_locs = filter_self_locations(decl_locs, ref_file, ref_line)
            inner(decl_locs and #decl_locs > 0 and decl_locs or nil)
          end)
        else
          inner(nil)
        end
      end)
    end)
  end

  local function try_once()
    attempts = attempts + 1
    def_plus_impl(function(locs)
      if not still_current() then return end
      if locs and #locs > 0 then
        on_result(locs)
        return
      end
      if attempts < LSP_RETRY_COUNT + 1 then
        vim.defer_fn(function()
          if still_current() then try_once() end
        end, LSP_RETRY_INTERVAL_MS)
      else
        on_result(nil)
      end
    end)
  end

  try_once()
end

-- ---------------------------------------------------------------------------
-- Jump dispatch
-- ---------------------------------------------------------------------------

-- pick_winner_with_label(locs, platform_hints, ref_file):
--   Reranks, picks a clear winner, returns winner_loc + short label string
--   suitable for the success notice ("FooFile.h:42") + the ranked list.
--   Returns (nil, nil, ranked) if no clear winner — caller can populate
--   quickfix from `ranked`. Returns (nil, nil, nil) if locs is empty.
local function pick_winner_with_label(locs, platform_hints, ref_file)
  if not locs or #locs == 0 then return nil, nil, nil end
  local ranked = rerank_locations(locs, platform_hints, ref_file)
  local winner = clear_winner(ranked, platform_hints, ref_file)
  if not winner then return nil, nil, ranked end

  local p = location_path(winner)
  local short = (p ~= "" and (p:match("([^/\\]+)$") or p)) or "?"
  local lnum
  if winner.range and winner.range.start then
    lnum = winner.range.start.line + 1
  elseif winner.targetSelectionRange and winner.targetSelectionRange.start then
    lnum = winner.targetSelectionRange.start.line + 1
  end
  local label = lnum and string.format("%s:%d", short, lnum) or short
  return winner, label, ranked
end

local function try_jump(locations, title)
  if not locations or #locations == 0 then
    return false
  end
  locations = dedup_locations(locations)
  if #locations == 1 then
    local ok = jump_to_location(locations[1])
    if ok then return true end
    vim.notify("LSP location could not be opened: " .. tostring(locations[1].uri or locations[1].targetUri), vim.log.levels.WARN)
    return "open_failed"
  end
  return populate_quickfix(title, locations) and true or false
end

-- ---------------------------------------------------------------------------
-- GTAGS fallback (now async)
-- ---------------------------------------------------------------------------

local function gtags_fallback_async(symbol, on_done)
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
-- Shader-only fast path
-- ---------------------------------------------------------------------------

local SHADER_EXTS = { usf = true, ush = true, hlsl = true, hlsli = true, glsl = true, frag = true, vert = true, metal = true, comp = true }

local function buf_extension(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "" end
  return (name:match("%.([^./\\]+)$") or ""):lower()
end

-- ---------------------------------------------------------------------------
-- Progress notification helper
-- ---------------------------------------------------------------------------
-- Returns {update = fn(msg), clear = fn(), finish = fn(msg, lifetime_ms)}.
-- snacks/noice/nvim-notify all support replacing a notification by passing
-- the previous id back via opts.replace; we use that when available.
local function progress_notice(initial_msg)
  local current_id = nil
  local function emit(msg, opts_override)
    local opts = { title = "LSP definition", timeout = false }
    if current_id ~= nil then
      opts.replace = current_id
      opts.id = current_id            -- snacks
      opts.hide_from_history = true
    end
    if opts_override then
      for k, v in pairs(opts_override) do opts[k] = v end
    end
    local ok, new_id = pcall(vim.notify, msg, opts_override and opts_override.level or vim.log.levels.INFO, opts)
    if ok then
      current_id = new_id or current_id
    end
  end
  emit(initial_msg)
  return {
    update = function(msg) emit(msg) end,
    clear = function()
      pcall(function()
        if current_id ~= nil then
          if type(current_id) == "table" and current_id.hide then
            current_id:hide()
          elseif vim.notify and package.loaded["notify"] then
            -- nvim-notify: re-emit with very short timeout to dismiss
            pcall(vim.notify, "", vim.log.levels.INFO, { replace = current_id, timeout = 1 })
          end
        end
      end)
      current_id = nil
    end,
    -- Update the notice to a "done" message that auto-dismisses after
    -- lifetime_ms. This gives the user a moment to see *what* resolved
    -- (especially after a long preamble wait) instead of the spinner just
    -- vanishing. After lifetime_ms we explicitly clear in case the notify
    -- backend ignored our timeout.
    finish = function(msg, lifetime_ms, level)
      lifetime_ms = lifetime_ms or 3000
      emit(msg, { timeout = lifetime_ms, level = level or vim.log.levels.INFO })
      local id_at_finish = current_id
      vim.defer_fn(function()
        -- Only clear if the notice is still ours (no newer request took over).
        if current_id == id_at_finish then
          pcall(function()
            if type(current_id) == "table" and current_id.hide then
              current_id:hide()
            elseif vim.notify and package.loaded["notify"] then
              pcall(vim.notify, "", vim.log.levels.INFO, { replace = current_id, timeout = 1 })
            end
          end)
          current_id = nil
        end
      end, lifetime_ms + 200)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- M.definition: LSP first (with empty-result retries), GTAGS only after LSP
-- has definitively given up. Never blocks the main loop.
-- ---------------------------------------------------------------------------
--
-- Design rationale:
--   * Correctness > speed. We never "jump now, correct later" — that creates
--     a confusing two-jump UX. We pick the best source we have, then jump.
--   * LSP semantic results beat GTAGS textual results, always. So we wait
--     for LSP to finish (including preamble-building retries) before
--     considering GTAGS.
--   * The user opted into "accept latency, async". Worst case is a multi-
--     second wait while preamble builds, with a progress notice. The buffer
--     is fully usable during that wait — no main-loop blocking.

function M.definition()
  local symbol = current_symbol()
  local bufnr = vim.api.nvim_get_current_buf()
  local ref_file = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local ref_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Clear any stale precise-winner from a previous gd; it's no longer
  -- relevant once the user invokes gd on something else.
  M._last_precise_winner = nil
  request_token = request_token + 1
  local my_token = request_token
  local function still_current() return my_token == request_token end

  -- Three independent tracks; whichever produces a usable jump first wins.
  local jumped = false   -- some track has navigated the cursor
  local resolved = false -- terminal state, no more notices, no more work
  local notice = nil

  local function clear_notice()
    if notice then pcall(notice.clear); notice = nil end
  end
  local function done(success_msg, lifetime_ms)
    resolved = true
    if success_msg and notice then
      pcall(notice.finish, success_msg, lifetime_ms or 3000); notice = nil
    elseif success_msg then
      -- Resolved before the spinner appeared (fast path). Still show the
      -- result so the user can see whether instant or precise won.
      pcall(vim.notify, success_msg, vim.log.levels.INFO,
        { title = "LSP definition", timeout = lifetime_ms or 3000 })
    else
      clear_notice()
    end
  end

  -- Resolve platform hints once (cheap, cached state.json).
  local platform_hints = nil
  do
    local ok, ue = pcall(require, "ue")
    if ok and ue.platform_path_priorities then
      platform_hints = ue.platform_path_priorities()
    end
  end

  -- Shader files: still GTAGS-only, same as before.
  local ext = buf_extension(bufnr)
  if SHADER_EXTS[ext] then
    gtags_fallback_async(symbol, function(ok)
      if not still_current() then return end
      done()
      if not ok then
        vim.notify("No definition (GTAGS empty): " .. (symbol or "?"), vim.log.levels.INFO)
      end
    end)
    return
  end

  local has_def_client = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" }) > 0
  local has_ws_client  = #vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" }) > 0

  if not has_def_client and not has_ws_client then
    gtags_fallback_async(symbol, function(ok)
      if not still_current() then return end
      done()
      if not ok then
        vim.notify("No definition (no LSP, GTAGS empty): " .. (symbol or "?"), vim.log.levels.INFO)
      end
    end)
    return
  end

  -- Progress notice (only after 600ms, so fast jumps don't flash a spinner).
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    notice = progress_notice(string.format(
      "⏳ resolving %s ... (instant index path racing precise AST path)",
      symbol or "?"
    ))
  end, LSP_PROGRESS_NOTICE_MS)

  -- Hard timeout: bail out. Only WARN if nothing has jumped — otherwise
  -- the instant track already navigated and the precise reconcile just
  -- couldn't finish in time, which is normal for very large UE TUs.
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    done()
    if not jumped then
      vim.notify(string.format("Definition lookup timed out after %ds (%s)",
        math.floor(OVERALL_TIMEOUT_MS / 1000), symbol or "?"), vim.log.levels.WARN)
    end
  end, OVERALL_TIMEOUT_MS)

  -- ---- Track 1: instant via workspace/symbol -----------------------------
  local instant_winner = nil
  if has_ws_client and symbol and symbol ~= "" then
    async_lsp_workspace_symbol(bufnr, symbol, true, function(ws_locs)
      if not still_current() or resolved then return end
      if not ws_locs or #ws_locs == 0 then return end
      -- > INSTANT_MAX_CANDIDATES means symbol is too generic (e.g. "i" or
      -- "Init"); skip instant entirely and let precise/quickfix handle it.
      if #ws_locs > INSTANT_MAX_CANDIDATES then return end
      ws_locs = filter_self_locations(ws_locs, ref_file, ref_line)
      if not ws_locs or #ws_locs == 0 then return end

      local winner, label = pick_winner_with_label(ws_locs, platform_hints, ref_file)
      if not winner then return end -- ambiguous, let precise path handle

      -- Jump now if we haven't already.
      if not jumped then
        local pok, ok_or_err = pcall(jump_to_location, winner)
        local ok = pok and ok_or_err == true
        if ok then
          jumped = true
          instant_winner = winner
          done(string.format("⚡ %s → %s (instant)", symbol or "?", label or "?"), 3000)
          -- Note: done() sets resolved=true, but the precise track callback
          -- only gates on still_current() (not resolved) — so reconcile
          -- still runs and can post a "precise differs" hint.
          -- INSTANT_PRECISE_RECONCILE controls whether reconcile is shown
          -- (handled in precise track), not whether precise keeps running.
        else
          -- Instant jump failed — most likely show_document raised
          -- "Cursor position outside buffer" because the target file
          -- couldn't be loaded synchronously. Do NOT mark resolved here:
          -- let the precise track / GTAGS still try to deliver a real
          -- jump. Log at DEBUG so it's available via :messages but not
          -- noisy. The OVERALL_TIMEOUT_MS hard-stop guarantees we won't
          -- hang forever even in pathological cases.
          if not pok then
            vim.schedule(function()
              vim.notify(string.format(
                "⚠ instant jump errored, falling back: %s",
                tostring(ok_or_err):sub(1, 200)
              ), vim.log.levels.DEBUG)
            end)
          end
        end
      end
    end)
  end

  -- ---- Track 2: precise via textDocument/definition (+impl/+decl) --------
  if has_def_client then
    async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, function(locs)
      if not still_current() then return end

      if locs and #locs > 0 then
        local winner, label, ranked = pick_winner_with_label(locs, platform_hints, ref_file)

        if not jumped then
          -- precise won the race
          if winner then
            local pok, ok = pcall(jump_to_location, winner)
            ok = pok and ok
            if ok then
              jumped = true
              done(string.format("✓ %s → %s (precise)", symbol or "?", label or "?"), 3000)
              return
            end
          end
          -- multi-candidate / no clear winner → quickfix
          local outcome = try_jump(ranked or locs, "LSP definitions")
          if outcome == true or outcome == "open_failed" then
            local first = (ranked or locs)[1]
            local _, lab2 = pick_winner_with_label({ first }, platform_hints, ref_file)
            jumped = true
            done(string.format("✓ %s → %s (%d candidates)", symbol or "?",
              lab2 or "?", #(ranked or locs)), 3000)
            return
          end
        else
          -- instant already jumped. Reconcile if precise disagrees.
          if INSTANT_PRECISE_RECONCILE and winner and instant_winner then
            local same = location_key(winner) == location_key(instant_winner)
            if not same then
              vim.notify(string.format(
                "ℹ precise definition differs: %s (press <leader>gP to switch)",
                label or "?"
              ), vim.log.levels.INFO)
              M._last_precise_winner = winner
            end
          end
          -- TODO(instant-goto): when winner is nil but ranked has multiple
          -- candidates AND instant_winner is set, surface a "precise found N
          -- candidates" hint and let <leader>gP open a quickfix. For v1 we
          -- silently keep the instant jump.
          done() -- clear spinner; instant message already shown
          return
        end
      end

      -- LSP precise gave nothing. If instant already jumped, we're done.
      if jumped then done(); return end

      -- Otherwise fall through to GTAGS.
      gtags_fallback_async(symbol, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", symbol or "?"), 3000)
        else
          done()
          vim.notify("No definition (LSP and GTAGS both empty): " .. (symbol or "?"),
            vim.log.levels.INFO)
        end
      end)
    end)
  else
    -- ws_client only, no def_client. Wait briefly for instant track,
    -- then fall back to GTAGS if it didn't pan out.
    vim.defer_fn(function()
      if not still_current() or resolved or jumped then return end
      gtags_fallback_async(symbol, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", symbol or "?"), 3000)
        else
          done()
          vim.notify("No definition: " .. (symbol or "?"), vim.log.levels.INFO)
        end
      end)
    end, INSTANT_DEADLINE_MS + 100)
  end
end

-- Jump to the precise definition stored by the last reconcile, if any.
function M.jump_to_precise()
  local w = M._last_precise_winner
  if not w then
    vim.notify("No precise winner recorded yet", vim.log.levels.WARN)
    return
  end
  pcall(jump_to_location, w)
  M._last_precise_winner = nil
end

-- ---------------------------------------------------------------------------
-- References (sync — usually fast enough, results go to qf)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- Show current LSP client status for the current buffer plus our last token.
-- Useful when gd seems hung: tells you if clangd is even attached and what
-- its progress messages look like.
function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = {
    string.format("buffer: %d  name: %s", bufnr, vim.api.nvim_buf_get_name(bufnr)),
    string.format("request_token: %d", request_token),
    "",
    "LSP clients (definition method):",
  }
  local def_clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" })
  if vim.tbl_isempty(def_clients) then
    table.insert(lines, "  (none)")
  else
    for _, c in ipairs(def_clients) do
      table.insert(lines, string.format("  - %s (id=%d, encoding=%s)",
        c.name, c.id, c.offset_encoding or "?"))
      -- progress messages
      local progress = c.progress
      if progress and progress.pending then
        for token, msg in pairs(progress.pending) do
          table.insert(lines, string.format("    progress[%s]: %s",
            tostring(token), vim.inspect(msg)))
        end
      end
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "LSP fallback status" })
end

function M.references()
  local symbol = current_symbol()
  if not symbol then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end

  local locations, errors, timed_out = sync_locations("textDocument/references", 5000)
  if timed_out then
    vim.notify("LSP references timed out — falling back to GTAGS (results may be lower quality)", vim.log.levels.WARN)
  elseif errors and errors > 0 then
    vim.notify(string.format("LSP references: %d client(s) returned errors", errors), vim.log.levels.WARN)
  end

  if locations and #locations > 0 and populate_quickfix("LSP references: " .. symbol, locations) then
    return
  end

  local ok, ue = pcall(require, "ue")
  if ok and ue.gtags_references and ue.gtags_references(symbol) then
    return
  end

  vim.notify("No references (LSP/GTAGS)", vim.log.levels.INFO)
end

return M
