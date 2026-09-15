-- Non-C++ definition policy and references compatibility; never used for C++ gd.
local M = {}
local location = require("utils.ue_goto.location")

function M.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, on_result, config)
  config = config or require("utils.ue_goto.provider").config
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
    require("utils.ue_goto.clangd_adapter").async_lsp_request(bufnr, "textDocument/definition", function(def_locs)
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
      if attempts < config.LSP_RETRY_COUNT + 1 and still_current() then
        vim.defer_fn(function()
          if still_current() then
            try_once()
          else
            -- Stopped while waiting on retry — fire now so caller cleans up.
            fire(nil)
          end
        end, config.LSP_RETRY_INTERVAL_MS)
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

function M.install(deps)
  local compat = {}
  local provider = require("utils.ue_goto.provider")
  local symbol_mod = require("utils.ue_goto.symbol")
  local location_mod = location
  local ui = require("utils.ue_goto.ui")
  local cache = require("utils.ue_goto.cache")
  local csearch_fb = require("utils.ue_goto.csearch_fallback")
  local dtrace, jump_to_location, format_jump_msg = deps.dtrace, deps.jump_to_location, deps.format_jump_msg
  local LSP_PROGRESS_NOTICE_MS, OVERALL_TIMEOUT_MS, CSEARCH_TIMEOUT_MS = 600, 30000, 4000
  local request_token = 0
  local generation = 0
  function compat.request_token() return request_token end
  function compat.dispose()
    request_token = request_token + 1
    generation = generation + 1
    if compat._active_notice then pcall(compat._active_notice.clear); compat._active_notice = nil end
  end
  function compat.definition(sym, receiver, bufnr, ref_file, ref_line, ext)
    local at_def, def_kind, def_name = symbol_mod.is_at_definition_at_cursor()
    if at_def then
      vim.notify(string.format("● already at %s definition of `%s`",
        def_kind or "?", def_name or sym or "?"),
        vim.log.levels.INFO, { title = "LSP definition", timeout = 3000 })
      return
    end

    local dep, dep_root, dep_chain = symbol_mod.is_dependent_at_cursor()
    if dep then
      vim.notify(string.format(
        "⊘ %s — dependent name (rooted at template param `%s`); not resolvable without instantiation.",
        dep_chain or sym or "?", dep_root or "?"),
        vim.log.levels.INFO, { title = "LSP definition", timeout = 4000 })
      return
    end

    local in_dead, dead_kind = symbol_mod.is_in_unresolvable_context_at_cursor()
    if in_dead then
      dtrace("dead-zone bail: kind=%s", tostring(dead_kind))
      vim.notify(string.format("⊘ cursor is inside %s — no definition lookup",
        dead_kind or "literal"),
        vim.log.levels.INFO, { title = "LSP definition", timeout = 2000 })
      return
    end

    if not sym or sym == "" then
      vim.notify("No symbol under cursor", vim.log.levels.WARN)
      return
    end

    if compat._active_notice then pcall(compat._active_notice.clear); compat._active_notice = nil end

    request_token = request_token + 1
    local my_token = request_token
    local function still_current() return my_token == request_token end

    local jumped = false
    local resolved = false
    local notice = nil

    local function clear_notice()
      local owned = notice
      if owned then pcall(owned.clear); notice = nil end
      if compat._active_notice == owned then compat._active_notice = nil end
    end

    local function done(success_msg, lifetime_ms)
      resolved = true
      clear_notice()
      if success_msg then
        pcall(vim.notify, success_msg, vim.log.levels.INFO,
          { title = "LSP definition", timeout = lifetime_ms or 3000 })
      end
    end

    local ch_locs, ch_key, ch_source = cache.get(sym, receiver, bufnr)
    if ch_locs and #ch_locs > 0 then
      dtrace("cache HIT key=%q source=%s n=%d",
        tostring(ch_key), tostring(ch_source), #ch_locs)
      ch_locs[1]._origin_cword = sym
      ch_locs[1]._sym_name     = sym
      if jump_to_location(ch_locs[1]) then
        jumped = true
        done(format_jump_msg(sym, ch_locs[1],
          string.format("cache·%s", ch_source or "?"), #ch_locs), 2000)
        return
      end
      dtrace("cache: jump failed; proceeding to live resolve")
    end

    if ui.NON_CLANGD_EXTS[ext] then
      dtrace("non-clangd ext=%s -> GTAGS direct", tostring(ext))
      provider.gtags_fallback_async(sym, function(ok)
        if not still_current() then return end
        done()
        if not ok then
          vim.notify("No definition (GTAGS empty): " .. (sym or "?"), vim.log.levels.INFO)
        end
      end)
      return
    end

    local has_def_client = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" }) > 0

    vim.defer_fn(function()
      if not still_current() or resolved or jumped then return end
      notice = ui.progress_notice(string.format("⏳ resolving %s ...", sym or "?"))
      compat._active_notice = notice
    end, LSP_PROGRESS_NOTICE_MS)

    vim.defer_fn(function()
      if not still_current() or resolved then return end
      done()
      if not jumped then
        vim.notify(string.format("Definition lookup timed out after %ds (%s)",
          math.floor(OVERALL_TIMEOUT_MS / 1000), sym or "?"), vim.log.levels.WARN)
      end
    end, OVERALL_TIMEOUT_MS)

    local function csearch_then_gtags()
      if jumped or resolved then return end
      dtrace("path-B: csearch dispatch sym=%q recv=%q", sym, tostring(receiver))
      csearch_fb.find(sym, {
        bufnr = bufnr,
        receiver = receiver,
        timeout_ms = CSEARCH_TIMEOUT_MS,
      }, function(locs, info)
        if not still_current() or resolved then clear_notice(); return end
        dtrace("path-B: csearch back n=%d took=%dms reason=%s indexed=%s",
          info.count or 0, info.took_ms or -1,
          tostring(info.reason), tostring(info.indexed))

        if locs and #locs > 0 then
          locs[1]._origin_cword = sym
          locs[1]._sym_name     = sym
          if jump_to_location(locs[1]) then
            jumped = true
            cache.put(sym, receiver, locs, "csearch", bufnr)
            done(format_jump_msg(sym, locs[1], "csearch", #locs), 3000)
            return
          end
          dtrace("path-B: csearch jump failed; falling through to GTAGS")
        end

        provider.gtags_fallback_async(sym, function(g_jumped)
          if not still_current() or resolved then clear_notice(); return end
          if g_jumped then
            jumped = true
            done(string.format("✓ %s (GTAGS fallback)", sym or "?"), 3000)
          else
            done()
            vim.notify(string.format(
              "No definition (clangd/csearch/GTAGS all empty): %s", sym or "?"),
              vim.log.levels.INFO)
          end
        end)
      end)
    end

    if not has_def_client then
      dtrace("no LSP def-client -> path-B directly")
      csearch_then_gtags()
      return
    end

    dtrace("path-A: dispatching textDocument/definition")
    provider.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, function(locs)
      if not still_current() then clear_notice(); return end
      dtrace("path-A: back n=%d", locs and #locs or 0)

      if not locs or #locs == 0 then
        csearch_then_gtags()
        return
      end

      if #locs == 1 then
        locs[1]._origin_cword = sym
        locs[1]._sym_name     = sym
        if jump_to_location(locs[1]) then
          jumped = true
          cache.put(sym, receiver, locs, "lsp", bufnr)
          done(format_jump_msg(sym, locs[1], "precise"), 3000)
          return
        end
        csearch_then_gtags()
        return
      end

      local outcome = ui.try_jump(locs, "LSP definitions")
      if outcome == true or outcome == "open_failed" then
        jumped = true
        done(format_jump_msg(sym, locs[1], "precise·picker", #locs), 3000)
      else
        done()
      end
    end)
  end
  function compat.references()
    local request_generation = generation
    local sym = symbol_mod.current_symbol()
    if not sym then
      vim.notify("No symbol under cursor", vim.log.levels.WARN)
      return
    end

    local function gtags_fallback()
      if request_generation ~= generation then return end
      local ok, ue = pcall(require, "ue")
      if ok and ue.gtags_references_async then
        ue.gtags_references_async(sym, function(jumped)
          if request_generation ~= generation then return end
          if not jumped then
            vim.notify("No references (LSP/GTAGS)", vim.log.levels.INFO)
          end
        end)
        return
      end
      vim.notify("No references (LSP/GTAGS)", vim.log.levels.INFO)
    end

    local bufnr = vim.api.nvim_get_current_buf()
    provider.async_lsp_request(bufnr, "textDocument/references", function(locations)
      if request_generation ~= generation then return end
      if locations and #locations > 0
        and location_mod.populate_quickfix("LSP references: " .. sym, locations) then
        return
      end
      gtags_fallback()
    end)
  end
  return compat
end

return M
