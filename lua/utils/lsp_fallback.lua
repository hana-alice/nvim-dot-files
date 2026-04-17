-- LSP definition/references with GTAGS fallback — orchestrator.
--
-- This module USED to be a 1410-line god module. It now delegates to:
--   utils.ue_goto.symbol    — cursor-context extraction (cword, receiver)
--   utils.ue_goto.location  — Location utility (path, line, dedup, qf)
--   utils.ue_goto.ranking   — score / pick_winner
--   utils.ue_goto.provider  — async LSP requests (ws/symbol, def, impl,
--                             decl, references), GTAGS, post-jump reconcile
--   utils.ue_goto.ui        — progress notice, try_jump, shader-ext detect
--   utils.ue_goto.jumper    — buffer switch + jumplist + cursor + zz with
--                             a strict contract (jumplist tail = source pos)
--
-- Public surface (UNCHANGED — call sites must not break):
--   M.definition(), M.references(), M.jump_to_precise(), M.status(),
--   M.dump_trace(), M.self_test()
--
-- Design rationale (why orchestrate at all instead of inlining):
--   * Correctness > speed. We never "jump now, correct later" — that
--     creates a confusing two-jump UX. We pick the best location we have,
--     then jump.
--   * LSP semantic results beat GTAGS textual results, always. So we wait
--     for LSP to finish (including preamble-building retries) before
--     considering GTAGS.
--   * The user opted into "accept latency, async". Worst case is a multi-
--     second wait while preamble builds, with a progress notice. The
--     buffer is fully usable during that wait — no main-loop blocking.
--   * Position params are computed PER CLIENT using that client's
--     offset_encoding (mixing encodings silently produces wrong positions
--     on multibyte lines).
--   * Async definition uses a request token so a stale callback from a
--     previous gd can never override a fresher one.

local M = {}

local symbol_mod   = require("utils.ue_goto.symbol")
local location_mod = require("utils.ue_goto.location")
local ranking      = require("utils.ue_goto.ranking")
local provider     = require("utils.ue_goto.provider")
local ui           = require("utils.ue_goto.ui")
local jumper       = require("utils.ue_goto.jumper")

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local LSP_PROGRESS_NOTICE_MS = 600
local OVERALL_TIMEOUT_MS     = 30000
local INSTANT_DEADLINE_MS    = 400
local INSTANT_MAX_CANDIDATES = 50
local INSTANT_PRECISE_RECONCILE = true

-- ---------------------------------------------------------------------------
-- Persistent debug ring-buffer (Tier 3: lift to ue_goto_dev/trace.lua).
-- ---------------------------------------------------------------------------
local MODULE_REVISION = "tier2split"
local TRACE_MAX = 200
local trace_ring = {}
local trace_idx = 0
local DISK_LOG = vim.fn.stdpath("cache") .. "/ue_def_trace.log"
pcall(function()
  local f = io.open(DISK_LOG, "w")
  if f then
    f:write(string.format("=== module loaded rev=%s at %s ===\n",
      MODULE_REVISION, os.date("%Y-%m-%d %H:%M:%S")))
    f:close()
  end
end)
local function dtrace(fmt, ...)
  trace_idx = trace_idx + 1
  local line = string.format("[%s #%d] " .. fmt, os.date("%H:%M:%S"), trace_idx, ...)
  trace_ring[((trace_idx - 1) % TRACE_MAX) + 1] = line
  pcall(function()
    local f = io.open(DISK_LOG, "a")
    if f then f:write(line .. "\n"); f:close() end
  end)
end
M._dtrace = dtrace
M.MODULE_REVISION = MODULE_REVISION

function M.dump_trace()
  local lines = { string.format("=== UEDefTrace  module_rev=%s  trace_idx=%d ===",
    MODULE_REVISION, trace_idx) }
  local start = trace_idx > TRACE_MAX and trace_idx - TRACE_MAX + 1 or 1
  for i = start, trace_idx do
    local entry = trace_ring[((i - 1) % TRACE_MAX) + 1]
    if entry then table.insert(lines, entry) end
  end
  if #lines == 1 then
    print("(no def trace entries yet, module_rev=" .. MODULE_REVISION .. ")")
    return
  end
  vim.cmd("vnew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.api.nvim_buf_set_name(0, "UEDefTrace")
end
vim.api.nvim_create_user_command("UEDefTrace", function() M.dump_trace() end, {})

-- :UEDefSelfTest — exercises ranking on synthetic GetBinCount-like data
-- to prove the header-only relaxation is loaded (vs. stale module).
function M.self_test()
  local ref_file = "<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/foo.cpp"
  local hits = {
    {
      uri = "file:///<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteShared.h",
      range = { start = { line = 735, character = 12 }, ["end"] = { line = 735, character = 23 } },
      _ws_kind = 6,
    },
    {
      uri = "file:///<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteShared.h",
      range = { start = { line = 897, character = 12 }, ["end"] = { line = 897, character = 23 } },
      _ws_kind = 6,
    },
  }
  local winner, label, ranked = ranking.pick_winner_with_label(hits, {}, ref_file, "")
  local lines = {
    "=== UEDefSelfTest  module_rev=" .. MODULE_REVISION,
    "input: 2 header hits, same module (simulated GetBinCount)",
    "winner: " .. (winner and ("PICKED " .. (winner.uri or "?") ..
      ":" .. tostring(winner.range and winner.range.start and winner.range.start.line + 1 or "?"))
      or "NIL (ambiguous — header-only relaxation NOT loaded; module is stale)"),
    "label: " .. tostring(label),
    "ranked count: " .. tostring(#(ranked or {})),
    "result: " .. (winner and "PASS ✓" or "FAIL ✗ — restart nvim or :Lazy reload utils.lsp_fallback"),
  }
  for _, l in ipairs(lines) do print(l) end
  return winner ~= nil
end
vim.api.nvim_create_user_command("UEDefSelfTest", function() M.self_test() end, {})

-- ---------------------------------------------------------------------------
-- Jump wrapper — jumper.jump + post-jump reconcile.
-- ---------------------------------------------------------------------------
-- Tier 3 will lift reconcile into the provider's response path so jumper
-- only ever sees already-reconciled locations. For now this thin wrapper
-- performs the jump, then runs the reconcile pass for ws/symbol-staleness
-- drift correction.
local function jump_to_location(location)
  if not location then return false end

  -- Surface jumper's shada-race re-asserts in the dtrace ring buffer so
  -- regressions are debuggable.
  jumper._on_reassert = function(reason, prev_cur, ln, cc)
    pcall(dtrace, "jump: shada-race reassert (%s) %d:%d -> %d:%d",
      tostring(reason), prev_cur[1], prev_cur[2], ln, cc)
  end

  local ok = jumper.jump(location)
  if not ok then return false end

  local sym = location._sym_name or location._origin_cword
  if sym and #sym > 0 then
    local range = location.range or location.targetSelectionRange or location.targetRange
    local line_1b = ((range and range.start and range.start.line) or 0) + 1
    pcall(provider.reconcile_landing_to_definition, sym, line_1b, dtrace)
  end

  local cur = vim.api.nvim_win_get_cursor(0)
  pcall(dtrace, "jump: done cursor=%d:%d sym=%s", cur[1], cur[2], tostring(sym))
  return true
end
-- Expose for jumplist regression tests (scripts/test_jumper_real.lua,
-- scripts/test_jumplist_fix.lua).
M._test_jump_to_location = jump_to_location
M._test_reconcile = function(sym, landed) provider.reconcile_landing_to_definition(sym, landed, dtrace) end

-- ---------------------------------------------------------------------------
-- M.definition: 3-track race (instant ws/symbol, precise td/definition, GTAGS)
-- ---------------------------------------------------------------------------

local request_token = 0

function M.definition()
  local sym = symbol_mod.current_symbol()
  local receiver = symbol_mod.current_receiver()
  local bufnr = vim.api.nvim_get_current_buf()
  local ref_file = location_mod.normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local ref_line = vim.api.nvim_win_get_cursor(0)[1]
  dtrace("M.definition() called sym=%q recv=%q file=%s:%d",
    sym or "", receiver or "",
    vim.fn.fnamemodify(ref_file, ":t"), ref_line)

  -- Clear any stale precise-winner from a previous gd; it's no longer
  -- relevant once the user invokes gd on something else.
  M._last_precise_winner = nil

  -- Aggressively dismiss any prior gd's lingering notice. The previous
  -- invocation's done()/clear path won't fire (its still_current() returns
  -- false now) so the spinner notice would visually persist on screen
  -- until snacks GC. Force-clear the shared slot here.
  if M._active_notice then
    pcall(M._active_notice.clear)
    M._active_notice = nil
  end

  request_token = request_token + 1
  local my_token = request_token
  local function still_current() return my_token == request_token end

  local jumped = false
  local resolved = false
  local notice = nil

  local function clear_notice()
    if notice then pcall(notice.clear); notice = nil end
    if M._active_notice then M._active_notice = nil end
  end
  local function done(success_msg, lifetime_ms)
    resolved = true
    if success_msg and notice then
      pcall(notice.finish, success_msg, lifetime_ms or 3000); notice = nil
      M._active_notice = nil
    elseif success_msg then
      -- Resolved before the spinner appeared (fast path).
      pcall(vim.notify, success_msg, vim.log.levels.INFO,
        { title = "LSP definition", timeout = lifetime_ms or 3000 })
    else
      clear_notice()
    end
  end

  -- Resolve platform hints once.
  local platform_hints = nil
  do
    local ok, ue = pcall(require, "ue")
    if ok and ue.platform_path_priorities then
      platform_hints = ue.platform_path_priorities()
    end
  end

  -- Shader files: GTAGS-only.
  local ext = ui.buf_extension(bufnr)
  if ui.SHADER_EXTS[ext] then
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
  local has_ws_client  = #vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" }) > 0

  if not has_def_client and not has_ws_client then
    provider.gtags_fallback_async(sym, function(ok)
      if not still_current() then return end
      done()
      if not ok then
        vim.notify("No definition (no LSP, GTAGS empty): " .. (sym or "?"), vim.log.levels.INFO)
      end
    end)
    return
  end

  -- Progress notice (only after 600ms, so fast jumps don't flash a spinner).
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    notice = ui.progress_notice(string.format(
      "⏳ resolving %s ... (instant index path racing precise AST path)",
      sym or "?"
    ))
    M._active_notice = notice
  end, LSP_PROGRESS_NOTICE_MS)

  -- Hard timeout: bail. WARN only if nothing has jumped — instant track may
  -- have already navigated and precise reconcile just timed out, which is
  -- normal on huge UE TUs.
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    done()
    if not jumped then
      vim.notify(string.format("Definition lookup timed out after %ds (%s)",
        math.floor(OVERALL_TIMEOUT_MS / 1000), sym or "?"), vim.log.levels.WARN)
    end
  end, OVERALL_TIMEOUT_MS)

  -- ---- Track 1: instant via workspace/symbol -----------------------------
  local instant_winner = nil
  if has_ws_client and sym and sym ~= "" then
    dtrace("instant: dispatching ws/symbol q=%q", sym)
    provider.async_lsp_workspace_symbol(bufnr, sym, true, function(ws_locs)
      local n = ws_locs and #ws_locs or 0
      dtrace("instant: ws/symbol back n=%d still=%s resolved=%s",
        n, tostring(still_current()), tostring(resolved))
      if not still_current() or resolved then return end
      if not ws_locs or #ws_locs == 0 then return end
      if #ws_locs > INSTANT_MAX_CANDIDATES then
        dtrace("instant: SKIP n>%d", INSTANT_MAX_CANDIDATES); return
      end
      ws_locs = location_mod.filter_self_locations(ws_locs, ref_file, ref_line)
      dtrace("instant: after filter_self n=%d", ws_locs and #ws_locs or 0)
      if not ws_locs or #ws_locs == 0 then return end

      for i, loc in ipairs(ws_locs) do
        local uri = loc.uri or (loc.targetUri or "?")
        local rng = loc.range or loc.targetSelectionRange or {}
        local ln = rng.start and rng.start.line or -1
        dtrace("instant: cand[%d] uri=%s line=%d kind=%s", i,
          tostring(uri):gsub("file:///", ""):sub(-80), ln, tostring(loc._ws_kind))
      end

      local winner, label = ranking.pick_winner_with_label(ws_locs, platform_hints, ref_file, receiver)
      dtrace("instant: pick_winner winner=%s label=%s",
        tostring(winner ~= nil), tostring(label))
      if not winner then return end

      if not jumped then
        winner._origin_cword = sym
        local pok, ok_or_err = pcall(jump_to_location, winner)
        local ok = pok and ok_or_err == true
        dtrace("instant: jump pok=%s ok=%s err=%s",
          tostring(pok), tostring(ok), pok and "" or tostring(ok_or_err):sub(1,80))
        if ok then
          jumped = true
          instant_winner = winner
          done(string.format("⚡ %s → %s (instant)", sym or "?", label or "?"), 3000)
        else
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
    dtrace("precise: dispatching textDocument/definition")
    provider.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, function(locs)
      dtrace("precise: back n=%d still=%s jumped=%s",
        locs and #locs or 0, tostring(still_current()), tostring(jumped))
      if not still_current() then return end

      if locs and #locs > 0 then
        local winner, label, ranked = ranking.pick_winner_with_label(locs, platform_hints, ref_file, receiver)
        dtrace("precise: pick winner=%s label=%s n_ranked=%d",
          tostring(winner ~= nil), tostring(label), #(ranked or locs))

        if not jumped then
          if winner then
            winner._origin_cword = sym
            local pok, ok = pcall(jump_to_location, winner)
            ok = pok and ok
            dtrace("precise: jump pok=%s ok=%s", tostring(pok), tostring(ok))
            if ok then
              jumped = true
              done(string.format("✓ %s → %s (precise)", sym or "?", label or "?"), 3000)
              return
            end
          end
          local outcome = ui.try_jump(ranked or locs, "LSP definitions")
          if outcome == true or outcome == "open_failed" then
            local first = (ranked or locs)[1]
            local _, lab2 = ranking.pick_winner_with_label({ first }, platform_hints, ref_file, receiver)
            jumped = true
            done(string.format("✓ %s → %s (%d candidates)", sym or "?",
              lab2 or "?", #(ranked or locs)), 3000)
            return
          end
        else
          -- instant already jumped. Reconcile if precise disagrees.
          if INSTANT_PRECISE_RECONCILE and winner and instant_winner then
            local same = location_mod.location_key(winner) == location_mod.location_key(instant_winner)
            if not same then
              vim.notify(string.format(
                "ℹ precise definition differs: %s (press <leader>gP to switch)",
                label or "?"
              ), vim.log.levels.INFO)
              M._last_precise_winner = winner
            end
          end
          done()
          return
        end
      end

      if jumped then done(); return end

      -- LSP precise gave nothing, fall through to GTAGS.
      provider.gtags_fallback_async(sym, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", sym or "?"), 3000)
        else
          done()
          vim.notify("No definition (LSP and GTAGS both empty): " .. (sym or "?"),
            vim.log.levels.INFO)
        end
      end)
    end)
  else
    -- ws_client only, no def_client. Wait briefly for instant track,
    -- then fall back to GTAGS if it didn't pan out.
    vim.defer_fn(function()
      if not still_current() or resolved or jumped then return end
      provider.gtags_fallback_async(sym, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", sym or "?"), 3000)
        else
          done()
          vim.notify("No definition: " .. (sym or "?"), vim.log.levels.INFO)
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
-- Diagnostics
-- ---------------------------------------------------------------------------

function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = {
    string.format("buffer: %d  name: %s", bufnr, vim.api.nvim_buf_get_name(bufnr)),
    string.format("request_token: %d", request_token),
    string.format("module_rev: %s", MODULE_REVISION),
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

-- ---------------------------------------------------------------------------
-- M.references — sync, qf-only.
-- ---------------------------------------------------------------------------

function M.references()
  local sym = symbol_mod.current_symbol()
  if not sym then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end

  local locations, errors, timed_out = provider.sync_locations("textDocument/references", 5000)
  if timed_out then
    vim.notify("LSP references timed out — falling back to GTAGS (results may be lower quality)",
      vim.log.levels.WARN)
  elseif errors and errors > 0 then
    vim.notify(string.format("LSP references: %d client(s) returned errors", errors),
      vim.log.levels.WARN)
  end

  if locations and #locations > 0
    and location_mod.populate_quickfix("LSP references: " .. sym, locations) then
    return
  end

  local ok, ue = pcall(require, "ue")
  if ok and ue.gtags_references and ue.gtags_references(sym) then
    return
  end

  vim.notify("No references (LSP/GTAGS)", vim.log.levels.INFO)
end

return M
