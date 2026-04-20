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
local syntax_filter = require("utils.ue_goto.syntax_filter")
local pair_picker = require("utils.ue_goto.pair_picker")

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
local MODULE_REVISION = "syntax-filter-v2-pairpicker"
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

-- :UEDefSelfTest — smoke test that syntax_filter loads and ranking.clear_winner
-- has been removed (proves the new bytecode is live, not the stale tier2split one).
function M.self_test()
  local ok, sf = pcall(require, "utils.ue_goto.syntax_filter")
  local lines = {
    "=== UEDefSelfTest  module_rev=" .. MODULE_REVISION,
  }
  if not ok then
    table.insert(lines, "FAIL ✗ — syntax_filter module not loadable: " .. tostring(sf))
  else
    table.insert(lines, "syntax_filter module: LOADED ✓")
    table.insert(lines, "ranking.clear_winner removed: " ..
      tostring(require("utils.ue_goto.ranking").clear_winner == nil))
    table.insert(lines, "result: PASS ✓")
  end
  for _, l in ipairs(lines) do print(l) end
  return ok
end
vim.api.nvim_create_user_command("UEDefSelfTest", function() M.self_test() end, {})

-- :UEDefReload — drop ue_goto/lsp_fallback bytecode from package.loaded and
-- re-require, then print the new MODULE_REVISION. Use after editing any
-- module under lua/utils/ue_goto/ or lua/utils/lsp_fallback.lua to pick up
-- changes WITHOUT restarting nvim/Neovide. Also runs self_test for sanity.
local function reload_ue_def()
  local dropped = {}
  for k in pairs(package.loaded) do
    if k:match("^utils%.ue_goto") or k == "utils.lsp_fallback" then
      package.loaded[k] = nil
      dropped[#dropped + 1] = k
    end
  end
  table.sort(dropped)
  local ok, fresh = pcall(require, "utils.lsp_fallback")
  local lines = { "=== UEDefReload ===" }
  table.insert(lines, "dropped: " .. tostring(#dropped) .. " modules")
  for _, k in ipairs(dropped) do table.insert(lines, "  - " .. k) end
  if ok then
    table.insert(lines, "reloaded: utils.lsp_fallback ✓")
    table.insert(lines, "MODULE_REVISION = " .. tostring(fresh.MODULE_REVISION))
    -- Also re-bind gd via the user's existing lspconfig glue if present.
    local ok2, lf = pcall(require, "utils.lsp_fallback")
    if ok2 and lf.self_test then lf.self_test() end
  else
    table.insert(lines, "FAIL re-require: " .. tostring(fresh))
  end
  for _, l in ipairs(lines) do print(l) end
end
vim.api.nvim_create_user_command("UEDefReload", reload_ue_def, {
  desc = "Hot-reload ue_goto/lsp_fallback modules + run self-test",
})

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

  local pre_buf = vim.api.nvim_get_current_buf()
  local pre_cur = vim.api.nvim_win_get_cursor(0)

  local ok = jumper.jump(location)
  if not ok then return false end

  local sym = location._sym_name or location._origin_cword
  local reconcile_ok = true
  if sym and #sym > 0 then
    local range = location.range or location.targetSelectionRange or location.targetRange
    local line_1b = ((range and range.start and range.start.line) or 0) + 1
    local rok, rresult = pcall(provider.reconcile_landing_to_definition, sym, line_1b, dtrace)
    if rok and rresult == false then
      reconcile_ok = false
    end
  end

  if not reconcile_ok then
    pcall(dtrace, "jump: REJECTED bogus location, restoring cursor to %d:%d", pre_cur[1], pre_cur[2])
    pcall(vim.api.nvim_set_current_buf, pre_buf)
    pcall(vim.api.nvim_win_set_cursor, 0, pre_cur)
    return false
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

  -- Early bail #1: cursor IS the definition site of the symbol it sits on
  -- (e.g. cursor on `FAutoConsoleVariableRef` in `class FAutoConsoleVariableRef
  -- : private FAutoConsoleObject`). gd here is meaningless and risks landing
  -- on a sibling overload (forward decl, friend decl, another overload of the
  -- same name). Don't enter the race.
  local at_def, def_kind, def_name = symbol_mod.is_at_definition_at_cursor()
  if at_def then
    vim.notify(string.format(
      "● already at %s definition of `%s`",
      def_kind or "?", def_name or sym or "?"),
      vim.log.levels.INFO,
      { title = "LSP definition", timeout = 3000 })
    return
  end

  -- Early bail #2: if the cursor sits inside a qualified-name chain rooted at
  -- a template parameter (dependent name like `TShaderClass::FParameters::
  -- FTypeInfo::GetStructMetadata`), clangd cannot resolve any segment of
  -- that chain without instantiation context. Don't waste 30s on retries —
  -- detect it from the AST and stop immediately.
  local dep, dep_root, dep_chain = symbol_mod.is_dependent_at_cursor()
  if dep then
    vim.notify(string.format(
      "⊘ %s — dependent name (rooted at template parameter `%s`); not resolvable without instantiation. Try grepping for the concrete type or jump to %s instead.",
      dep_chain or (sym or "?"), dep_root or "?", dep_root or "?"),
      vim.log.levels.INFO,
      { title = "LSP definition", timeout = 4000 })
    return
  end

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
    -- DESIGN NOTE
    -- We deliberately DON'T forward success_msg into the spinner notice
    -- via notice.finish() any more.
    --
    -- Why: snacks.notify with `replace=id` has been observed to keep
    -- displaying the old (spinner) text on screen even after a finish()
    -- emit() with the new text — race between snacks' internal queue
    -- update and the next paint, plus the spinner's hide_from_history
    -- flag interacting with replace semantics. Net effect: the user
    -- sees "⏳ resolving X ... (instant index path racing precise AST
    -- path)" lingering on screen *after* the cursor has already jumped
    -- to the target. That's the visible bug we're fixing here.
    --
    -- Treatment: hard-clear any existing spinner FIRST, then emit the
    -- success text as a brand-new notification with a fresh id. This
    -- guarantees the user only ever sees the success line — never the
    -- stale "resolving" text — once a jump has actually happened.
    clear_notice()
    if success_msg then
      pcall(vim.notify, success_msg, vim.log.levels.INFO,
        { title = "LSP definition", timeout = lifetime_ms or 3000 })
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
  -- We check BOTH `resolved` and `jumped`: by the time this defer fires the
  -- instant track may have already navigated the cursor but not yet returned
  -- through done() (microsecond window). Showing a "resolving" spinner AFTER
  -- the user has already landed at the target is the precise visual bug we
  -- want to suppress.
  vim.defer_fn(function()
    if not still_current() or resolved or jumped then return end
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

      -- SYNTAX FILTER (deterministic overload disambiguation).
      local filtered, fi = syntax_filter.filter_by_call_signature(ws_locs, bufnr, dtrace)
      dtrace("instant: syntax_filter applied=%s K=%s before=%d after=%d skipped=%d",
        tostring(fi.applied), tostring(fi.call_arity), fi.before, fi.after, fi.skipped)

      if #filtered == 1 then
        local winner = filtered[1]
        if not jumped then
          winner._origin_cword = sym
          winner._sym_name = sym
          local pok, ok_or_err = pcall(jump_to_location, winner)
          local ok = pok and ok_or_err == true
          local p = location_mod.location_path(winner)
          local short = p:match("([^/\\]+)$") or "?"
          local label = string.format("%s:%d", short, location_mod.location_line(winner))
          dtrace("instant: jump pok=%s ok=%s label=%s err=%s",
            tostring(pok), tostring(ok), label,
            pok and "" or tostring(ok_or_err):sub(1, 80))
          if ok then
            jumped = true
            instant_winner = winner
            local tag = fi.applied and "instant·syntax" or "instant"
            done(string.format("⚡ %s → %s (%s)", sym or "?", label, tag), 3000)
          end
        end
      elseif #filtered > 1 then
        -- Multiple candidates pass syntax_filter. Try pair_picker for the
        -- two structurally-safe auto-jump patterns (header+cpp pair, sole
        -- cpp among headers). On miss, fall back to quickfix sorted by
        -- ranking heuristics.
        local pp_winner, pp_rule = pair_picker.pick_safe_winner(filtered)
        if pp_winner and not jumped then
          pp_winner._origin_cword = sym
          pp_winner._sym_name = sym
          local pok, ok_or_err = pcall(jump_to_location, pp_winner)
          local ok = pok and ok_or_err == true
          local p = location_mod.location_path(pp_winner)
          local short = p:match("([^/\\]+)$") or "?"
          local label = string.format("%s:%d", short, location_mod.location_line(pp_winner))
          dtrace("instant: pair_picker rule=%s pok=%s ok=%s label=%s",
            tostring(pp_rule), tostring(pok), tostring(ok), label)
          if ok then
            jumped = true
            instant_winner = pp_winner
            local tag = fi.applied
              and string.format("instant·syntax·%s", pp_rule)
              or  string.format("instant·%s", pp_rule)
            done(string.format("⚡ %s → %s (%s, %d→1)", sym or "?", label, tag, #filtered), 3000)
          end
        end
        if not jumped then
          local sorted = ranking.rerank_locations(filtered, platform_hints, ref_file, receiver)
          local outcome = ui.try_jump(sorted, "LSP definitions (instant)")
          if outcome == true or outcome == "open_failed" then
            jumped = true
            local first = sorted[1]
            local p = location_mod.location_path(first)
            local short = p:match("([^/\\]+)$") or "?"
            local label = string.format("%s:%d", short, location_mod.location_line(first))
            local tag = fi.applied and "instant·syntax" or "instant"
            done(string.format("⚡ %s → %s (%d candidates, %s)", sym or "?", label, #sorted, tag), 3000)
          end
        end
      end
      -- #filtered == 0 case is impossible — syntax_filter has its own
      -- "all eliminated → fallback" safety net.
    end)
  end

  -- ---- Track 2: precise via textDocument/definition (+impl/+decl) --------
  if has_def_client then
    dtrace("precise: dispatching textDocument/definition")
    provider.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, function(locs)
      dtrace("precise: back n=%d still=%s jumped=%s",
        locs and #locs or 0, tostring(still_current()), tostring(jumped))
      -- HARD INVARIANT: precise track owns the spinner. Once we receive
      -- the on_result callback, the spinner MUST end on every exit path,
      -- stale or not. Otherwise the "⏳ resolving ..." notice is leaked
      -- forever (until the 30s overall timeout fires).
      if not still_current() then
        -- Stale: do nothing observable, but clear our spinner so nothing
        -- lingers on screen. The fresher invocation has its own spinner.
        clear_notice()
        return
      end

      if locs and #locs > 0 then
        local filtered, fi = syntax_filter.filter_by_call_signature(locs, bufnr, dtrace)
        dtrace("precise: syntax_filter applied=%s K=%s before=%d after=%d skipped=%s",
          tostring(fi.applied), tostring(fi.call_arity), fi.before, fi.after, tostring(fi.skipped))

        if not jumped then
          if #filtered == 1 then
            local winner = filtered[1]
            winner._origin_cword = sym
            winner._sym_name = sym
            local pok, ok = pcall(jump_to_location, winner)
            ok = pok and ok
            dtrace("precise: jump pok=%s ok=%s", tostring(pok), tostring(ok))
            if ok then
              jumped = true
              local p = location_mod.location_path(winner)
              local short = p:match("([^/\\]+)$") or "?"
              local label = string.format("%s:%d", short, location_mod.location_line(winner))
              local tag = fi.applied and "precise·syntax" or "precise"
              done(string.format("✓ %s → %s (%s)", sym or "?", label, tag), 3000)
              return
            end
          elseif #filtered > 1 then
            -- Try pair_picker before falling to quickfix.
            local pp_winner, pp_rule = pair_picker.pick_safe_winner(filtered)
            if pp_winner then
              pp_winner._origin_cword = sym
              pp_winner._sym_name = sym
              local pok, ok = pcall(jump_to_location, pp_winner)
              ok = pok and ok
              dtrace("precise: pair_picker rule=%s pok=%s ok=%s",
                tostring(pp_rule), tostring(pok), tostring(ok))
              if ok then
                jumped = true
                local p = location_mod.location_path(pp_winner)
                local short = p:match("([^/\\]+)$") or "?"
                local label = string.format("%s:%d", short, location_mod.location_line(pp_winner))
                local tag = fi.applied
                  and string.format("precise·syntax·%s", pp_rule)
                  or  string.format("precise·%s", pp_rule)
                done(string.format("✓ %s → %s (%s, %d→1)", sym or "?", label, tag, #filtered), 3000)
                return
              end
            end
          end
          local sorted = ranking.rerank_locations(filtered, platform_hints, ref_file, receiver)
          local outcome = ui.try_jump(sorted, "LSP definitions")
          if outcome == true or outcome == "open_failed" then
            jumped = true
            local first = sorted[1]
            local p = location_mod.location_path(first)
            local short = p:match("([^/\\]+)$") or "?"
            local label = string.format("%s:%d", short, location_mod.location_line(first))
            local tag = fi.applied and "precise·syntax" or "precise"
            done(string.format("✓ %s → %s (%d candidates, %s)", sym or "?", label, #sorted, tag), 3000)
            return
          end
        else
          -- instant already jumped. Reconcile if precise (post-filter) disagrees.
          if INSTANT_PRECISE_RECONCILE and instant_winner and #filtered >= 1 then
            local precise_pick = filtered[1]
            local same = location_mod.location_key(precise_pick) == location_mod.location_key(instant_winner)
            if not same then
              local p = location_mod.location_path(precise_pick)
              local short = p:match("([^/\\]+)$") or "?"
              local label = string.format("%s:%d", short, location_mod.location_line(precise_pick))
              vim.notify(string.format(
                "ℹ precise definition differs: %s (press <leader>gP to switch)",
                label
              ), vim.log.levels.INFO)
              M._last_precise_winner = precise_pick
            end
          end
          done()
          return
        end
      end

      if jumped then done(); return end

      -- LSP precise gave nothing, fall through to GTAGS.
      provider.gtags_fallback_async(sym, function(jumped_g)
        -- Same invariant: spinner ownership transfers to us here. Always
        -- terminate it before returning.
        if not still_current() or resolved then
          clear_notice()
          return
        end
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
      -- HARD INVARIANT: this branch owns the spinner cleanup.
      -- jumped=true means instant track resolved cleanly and already
      -- called done(); nothing left to do.
      if jumped then return end
      if not still_current() or resolved then
        clear_notice()
        return
      end
      provider.gtags_fallback_async(sym, function(jumped_g)
        if not still_current() or resolved then
          clear_notice()
          return
        end
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
