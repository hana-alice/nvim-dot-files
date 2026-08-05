-- utils/lsp_fallback.lua
-- ============================================================================
-- gd orchestrator.
--
-- C/C++ is an isolated semantic-authority path. Source TUs must be proven by
-- the active compilation database before one precise clangd request is
-- accepted; its location must agree with the libclang-owned USR target.
-- Headers are evaluated by libclang inside an inherited or build-proven
-- source TU. No C++ result is selected by symbol cache, arity, ranking,
-- csearch, GTAGS, workspace symbol, or first-candidate ordering.
--
-- The legacy cache -> LSP -> csearch -> GTAGS chain below is retained only
-- for non-C++ compatibility and explicit reference/search surfaces.
--
-- Public surface (CALL-SITE COMPATIBLE):
--   M.definition()   gd entry
--   M.references()   <leader>gr / kept verbatim
--   M.status()       :UEDefStatus diagnostic
--   M.dump_trace()   :UEDefTrace dump ring buffer
--   M.self_test()    :UEDefSelfTest
-- ============================================================================

local M = {}

local symbol_mod   = require("utils.ue_goto.symbol")
local location_mod = require("utils.ue_goto.location")
local provider     = require("utils.ue_goto.provider")
local ui           = require("utils.ue_goto.ui")
local jumper       = require("utils.ue_goto.jumper")
local cache        = require("utils.ue_goto.cache")
local csearch_fb   = require("utils.ue_goto.csearch_fallback")
local semantic     = require("utils.ue_goto.semantic_client")

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
local LSP_PROGRESS_NOTICE_MS = 600
local OVERALL_TIMEOUT_MS     = 30000
local CSEARCH_TIMEOUT_MS     = 4000

-- ---------------------------------------------------------------------------
-- Persistent debug ring-buffer.
-- ---------------------------------------------------------------------------
local MODULE_REVISION = "contextual-clang-v1"
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

function M.self_test()
  local checks = {
    { "cache",         pcall(require, "utils.ue_goto.cache") },
    { "csearch_fb",    pcall(require, "utils.ue_goto.csearch_fallback") },
    { "jumper",        pcall(require, "utils.ue_goto.jumper") },
    { "provider",      pcall(require, "utils.ue_goto.provider") },
    { "symbol",        pcall(require, "utils.ue_goto.symbol") },
    { "location",      pcall(require, "utils.ue_goto.location") },
    { "ui",            pcall(require, "utils.ue_goto.ui") },
    { "semantic",      pcall(require, "utils.ue_goto.semantic_client") },
  }
  local lines = { "=== UEDefSelfTest  module_rev=" .. MODULE_REVISION }
  local all_ok = true
  for _, c in ipairs(checks) do
    local mark = c[2] and "✓" or "✗"
    table.insert(lines, string.format("  %s  %s", mark, c[1]))
    all_ok = all_ok and c[2]
  end
  table.insert(lines, all_ok and "result: PASS ✓" or "result: FAIL ✗")
  for _, l in ipairs(lines) do print(l) end
  return all_ok
end
vim.api.nvim_create_user_command("UEDefSelfTest", function() M.self_test() end, {})

-- :UEDefReload — drop ue_goto bytecode + utils.lsp_fallback, re-require.
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
  print("=== UEDefReload ===")
  print("dropped: " .. tostring(#dropped) .. " modules")
  for _, k in ipairs(dropped) do print("  - " .. k) end
  if ok then
    print("reloaded: utils.lsp_fallback ✓  rev=" .. tostring(fresh.MODULE_REVISION))
    if fresh.self_test then fresh.self_test() end
  else
    print("FAIL re-require: " .. tostring(fresh))
  end
end
vim.api.nvim_create_user_command("UEDefReload", reload_ue_def, {
  desc = "Hot-reload ue_goto/lsp_fallback modules + run self-test",
})

-- :UEDefDiag — cursor context + last 40 trace entries.
vim.api.nvim_create_user_command("UEDefDiag", function()
  local sym  = symbol_mod.current_symbol()
  local recv = symbol_mod.current_receiver()
  local at_def, dk, dn = symbol_mod.is_at_definition_at_cursor()
  local dep, droot, dchain = symbol_mod.is_dependent_at_cursor()
  local cur = vim.api.nvim_win_get_cursor(0)
  local bufname = vim.api.nvim_buf_get_name(0)
  print("=== UEDefDiag  rev=" .. MODULE_REVISION .. " ===")
  print(string.format("buf:    %s:%d", bufname, cur[1]))
  print(string.format("line:   %s", vim.api.nvim_get_current_line():sub(1, 100)))
  print(string.format("symbol: %q  receiver: %q", tostring(sym), tostring(recv)))
  print(string.format("at_def: %s (kind=%s name=%s)",
    tostring(at_def), tostring(dk), tostring(dn)))
  print(string.format("dependent: %s (root=%s chain=%s)",
    tostring(dep), tostring(droot), tostring(dchain)))
  -- cache stats
  local ok, st = pcall(cache.stats, 0)
  if ok and st then
    print(string.format("cache:  entries=%d project=%s",
      st.entries or 0, tostring(st.project)))
  end
  print("--- last 40 trace entries ---")
  local lines = {}
  for i = 1, TRACE_MAX do
    local idx = ((trace_idx - i) % TRACE_MAX) + 1
    local entry = trace_ring[idx]
    if entry then table.insert(lines, 1, entry) end
    if #lines >= 40 then break end
  end
  for _, l in ipairs(lines) do print(l) end
end, { desc = "Diagnose stuck gd: cursor context + last 40 trace lines" })

-- :UEDefCacheClear — drop the entire on-disk + memory cache for current project.
vim.api.nvim_create_user_command("UEDefCacheClear", function()
  if cache.clear then
    local ok, msg = pcall(cache.clear, 0)
    if ok then
      vim.notify("ue_goto cache cleared: " .. tostring(msg or "ok"),
        vim.log.levels.INFO, { title = "UEDefCacheClear" })
    else
      vim.notify("clear failed: " .. tostring(msg), vim.log.levels.ERROR)
    end
  end
end, {})

vim.api.nvim_create_user_command("UEDefCancel", function()
  semantic.cancel_action()
  vim.notify("C++ definition UI action cancelled; sidecar TU remains warm",
    vim.log.levels.INFO, { title = "C++ definition", timeout = 2500 })
end, { desc = "Cancel the active C++ definition UI action" })

vim.api.nvim_create_user_command("UEDefContextClear", function()
  semantic.clear_contexts()
  vim.notify("C++ translation-unit context selection cleared",
    vim.log.levels.INFO, { title = "C++ definition", timeout = 2500 })
end, { desc = "Forget inherited/selected C++ translation-unit contexts" })

-- ---------------------------------------------------------------------------
-- Internal helpers
-- ---------------------------------------------------------------------------

-- Wrap jumper.jump with the dtrace-friendly reassert hook.
local function jump_to_location(location)
  if not location then return false end
  -- Pre-jump trace: where we are + where we're aiming. Knowing the source
  -- file/line in the trace makes "wrong-place" reports trivial to triage.
  local pre_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
  local pre_pos = vim.api.nvim_win_get_cursor(0)
  local cw = vim.fn.expand("<cword>")
  local dst_uri = location.uri or location.targetUri or ""
  local dst_rng = location.range or location.targetSelectionRange or location.targetRange or {}
  local dst_line = (((dst_rng or {}).start) or {}).line or -1
  pcall(dtrace, "jump: pre  cur=%s:%d:%d cword=%q -> dst=%s:%d",
    pre_name, pre_pos[1], pre_pos[2], tostring(cw),
    vim.fn.fnamemodify(vim.uri_to_fname(dst_uri ~= "" and dst_uri or "file:///?"), ":t"),
    dst_line + 1)

  jumper._on_reassert = function(reason, prev_cur, ln, cc)
    pcall(dtrace, "jump: shada-race reassert (%s) %d:%d -> %d:%d",
      tostring(reason), prev_cur[1], prev_cur[2], ln, cc)
  end
  local ok = jumper.jump(location)
  if ok then
    local cur_name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(0), ":t")
    local cur = vim.api.nvim_win_get_cursor(0)
    pcall(dtrace, "jump: done cur=%s:%d:%d", cur_name, cur[1], cur[2])
  end
  return ok
end
M._test_jump_to_location = jump_to_location  -- regression tests

-- Format a one-line "✓ sym → file:line (tag)" status string.
local function format_jump_msg(sym, loc, tag, n_more)
  local p = location_mod.location_path(loc)
  local short = p:match("([^/\\]+)$") or "?"
  local label = string.format("%s:%d", short, location_mod.location_line(loc))
  if n_more and n_more > 1 then
    return string.format("✓ %s → %s (%s, %d candidates)", sym or "?", label, tag, n_more)
  end
  return string.format("✓ %s → %s (%s)", sym or "?", label, tag)
end

-- C/C++ gd has a separate authority contract: only the compiler-owned
-- semantic identity for the exact position may drive a jump.  The legacy
-- cache/csearch/GTAGS chain below remains solely for non-C++ compatibility.
local CPP_SOURCE_EXTS = {
  c = true, cc = true, cpp = true, cxx = true, m = true, mm = true,
}
local CPP_HEADER_EXTS = {
  h = true, hh = true, hpp = true, hxx = true, inl = true, ipp = true,
  ixx = true,
}

local function semantic_location(value)
  if type(value) ~= "table" then return nil end
  if value.uri and (value.range or value.targetSelectionRange or value.targetRange) then
    return value
  end
  local path = value.path or value.file or value.filename
  local line = tonumber(value.line)
  local column = tonumber(value.column or value.col or 1)
  if not path or not line then return nil end
  return {
    uri = vim.uri_from_fname(path),
    range = {
      start = { line = math.max(0, line - 1), character = math.max(0, column - 1) },
      ["end"] = { line = math.max(0, line - 1), character = math.max(0, column - 1) },
    },
  }
end

local function semantic_target(response)
  if type(response) ~= "table" then return nil end
  return semantic_location(response.definition)
    or semantic_location(response.declaration)
end

local function semantic_terminal_notice(sym, status, reason)
  vim.notify(string.format("C++ definition %s%s%s",
    tostring(status or "unavailable"),
    sym and sym ~= "" and (" for `" .. sym .. "`") or "",
    reason and reason ~= "" and (": " .. tostring(reason)) or ""),
    status == "unavailable" and vim.log.levels.WARN or vim.log.levels.INFO,
    { title = "C++ definition", timeout = 5000 })
end

local function setup_semantic_trace()
  semantic.set_trace(function(fields)
    dtrace(
      "semantic event=%s request=%s context=%s provider=%s usr=%s state=%s elapsed=%s stale=%s",
      tostring(fields.event or "?"), tostring(fields.request_id or "?"),
      tostring(fields.context_id or "?"), tostring(fields.provider or "?"),
      tostring(fields.usr or "?"), tostring(fields.terminal_state or "?"),
      tostring(fields.elapsed_ms or "?"), tostring(fields.stale_reason or "?"))
  end)
end

local function cpp_definition(sym, bufnr, ref_file, ext)
  setup_semantic_trace()
  local snapshot = semantic.begin_action(bufnr)
  local environment, env_err = semantic.discover_toolchain(bufnr)
  if not environment then
    dtrace("semantic state=unavailable reason=toolchain-or-context")
    semantic_terminal_notice(sym, "unavailable", env_err)
    return
  end

  if CPP_HEADER_EXTS[ext] then
    semantic.resolve_header({
      snapshot = snapshot,
      environment = environment,
      header = ref_file,
      line = snapshot.cursor[1],
      column = snapshot.cursor[2] + 1,
    }, function(response, stale_reason)
      if not response then
        if stale_reason then
          dtrace("semantic provider=libclang state=stale reason=%s", stale_reason)
        end
        return
      end
      if response.state ~= "resolved" then return end
      local target = semantic_target(response)
      if not target then
        semantic_terminal_notice(sym, "invalid-semantic-context",
          "resolved response has no location")
        return
      end
      if jump_to_location(target) then
        vim.notify(format_jump_msg(sym, target, "libclang·USR"), vim.log.levels.INFO,
          { title = "C++ definition", timeout = 3000 })
      end
    end)
    return
  end

  -- A clangd attachment is not proof that a source file is covered by the
  -- active CDB: clangd can silently use a fallback command.  Ask the sidecar
  -- to prove the exact compile command before accepting clangd's response.
  semantic.prove_source({
    source = ref_file,
    environment = environment,
    snapshot = snapshot,
    line = snapshot.cursor[1],
    column = snapshot.cursor[2] + 1,
  }, function(proof)
    local current, stale_reason = semantic.snapshot_is_current(snapshot, proof)
    if not current then
      dtrace("semantic provider=clangd state=stale reason=%s", stale_reason)
      return
    end
    if not proof or proof.state ~= "resolved" then
      semantic_terminal_notice(sym, proof and proof.state or "unavailable",
        proof and proof.reason or "source TU has no proven active compile command")
      return
    end
    local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" })
    if not clients or vim.tbl_isempty(clients) then
      semantic_terminal_notice(sym, "unavailable", "clangd definition provider unavailable")
      return
    end
    dtrace("semantic provider=clangd request=symbolInfo+definition context=%s",
      tostring(proof.context_id or "?"))
    provider.async_clangd_symbol_info(bufnr, function(usr)
      local identity_current, identity_stale = semantic.snapshot_is_current(snapshot)
      if not identity_current then
        dtrace("semantic provider=clangd state=stale reason=%s", identity_stale)
        return
      end
      if not usr then
        semantic_terminal_notice(sym, "invalid-semantic-context",
          "clangd did not expose one compiler-owned USR for this position")
        dtrace("semantic provider=clangd context=%s state=invalid-semantic-context usr=missing",
          tostring(proof.context_id or "?"))
        return
      end
      provider.async_lsp_request(bufnr, "textDocument/definition", function(locs)
      local still_current, reason = semantic.snapshot_is_current(snapshot)
      if not still_current then
        dtrace("semantic provider=clangd state=stale reason=%s", reason)
        return
      end
      locs = location_mod.dedup_locations(locs or {})
      if #locs ~= 1 then
        semantic_terminal_notice(sym, "invalid-semantic-context",
          #locs == 0 and "clangd returned no semantic target"
            or ("clangd returned " .. tostring(#locs) .. " targets"))
        dtrace("semantic provider=clangd state=invalid-semantic-context n=%d", #locs)
        return
      end
      local target_path = location_mod.location_path(locs[1]):lower()
      if CPP_HEADER_EXTS[target_path:match("%.([^./\\]+)$") or ""] then
        if proof.origin_context then
          semantic.note_origin(snapshot.winid, proof.origin_context,
            environment.build_fingerprint)
        end
      end
      if jump_to_location(locs[1]) then
        dtrace("semantic provider=clangd context=%s usr=%s state=resolved",
          tostring(proof.context_id or "?"), tostring(usr))
        vim.notify(format_jump_msg(sym, locs[1], "clangd·semantic"), vim.log.levels.INFO,
          { title = "C++ definition", timeout = 3000 })
      end
      end)
    end)
  end)
end

-- ---------------------------------------------------------------------------
-- M.definition — gd entry.
-- ---------------------------------------------------------------------------

local request_token = 0

function M.definition()
  local sym      = symbol_mod.current_symbol()
  local receiver = symbol_mod.current_receiver()
  local bufnr    = vim.api.nvim_get_current_buf()
  local ref_file = location_mod.normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local ref_line = vim.api.nvim_win_get_cursor(0)[1]
  dtrace("M.definition() sym=%q recv=%q file=%s:%d",
    sym or "", receiver or "",
    vim.fn.fnamemodify(ref_file, ":t"), ref_line)

  local ext = ui.buf_extension(bufnr)
  if CPP_SOURCE_EXTS[ext] or CPP_HEADER_EXTS[ext] then
    cpp_definition(sym, bufnr, ref_file, ext)
    return
  end

  -- Early bail #1: cursor sits ON the definition site itself.
  local at_def, def_kind, def_name = symbol_mod.is_at_definition_at_cursor()
  if at_def then
    vim.notify(string.format("● already at %s definition of `%s`",
      def_kind or "?", def_name or sym or "?"),
      vim.log.levels.INFO, { title = "LSP definition", timeout = 3000 })
    return
  end

  -- Early bail #2: dependent name rooted at template parameter.
  local dep, dep_root, dep_chain = symbol_mod.is_dependent_at_cursor()
  if dep then
    vim.notify(string.format(
      "⊘ %s — dependent name (rooted at template param `%s`); not resolvable without instantiation.",
      dep_chain or sym or "?", dep_root or "?"),
      vim.log.levels.INFO, { title = "LSP definition", timeout = 4000 })
    return
  end

  -- Early bail #3: cursor inside a syntactic dead-zone (comment / string /
  -- number / char literal). LSP cannot resolve these and would otherwise
  -- spend a 30s timeout returning empty. Toast + bail.
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

  if M._active_notice then pcall(M._active_notice.clear); M._active_notice = nil end

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
    clear_notice()
    if success_msg then
      pcall(vim.notify, success_msg, vim.log.levels.INFO,
        { title = "LSP definition", timeout = lifetime_ms or 3000 })
    end
  end

  -- ----- cache short-circuit -------------------------------------------------
  local ch_locs, ch_key, ch_source = cache.get(sym, receiver, bufnr)
  if ch_locs and #ch_locs > 0 then
    dtrace("cache HIT key=%q source=%s n=%d",
      tostring(ch_key), tostring(ch_source), #ch_locs)
    -- Stamp transient fields so downstream debug shows the right name.
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

  -- ----- non-clangd ext (shaders, Build.cs, Python) -> GTAGS direct ----------
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

  -- Spinner: only show after 600ms so fast precise / cache hits don't flash.
  vim.defer_fn(function()
    if not still_current() or resolved or jumped then return end
    notice = ui.progress_notice(string.format("⏳ resolving %s ...", sym or "?"))
    M._active_notice = notice
  end, LSP_PROGRESS_NOTICE_MS)

  -- Hard timeout: 30s ceiling.
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    done()
    if not jumped then
      vim.notify(string.format("Definition lookup timed out after %ds (%s)",
        math.floor(OVERALL_TIMEOUT_MS / 1000), sym or "?"), vim.log.levels.WARN)
    end
  end, OVERALL_TIMEOUT_MS)

  -- ----- the cache+csearch fallback chain ------------------------------------
  -- Tried in order when path-A returns empty:
  --   (1) csearch_fb.find  (RE2 def-shaped pattern, scored)
  --   (2) provider.gtags_fallback_async  (jumps internally)
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

      -- csearch empty or jump failed -> GTAGS (last resort).
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

  -- ----- path-A: textDocument/definition -------------------------------------
  dtrace("path-A: dispatching textDocument/definition")
  provider.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current,
    function(locs)
      if not still_current() then clear_notice(); return end
      dtrace("path-A: back n=%d", locs and #locs or 0)

      if not locs or #locs == 0 then
        csearch_then_gtags()
        return
      end

      -- N>=1 — pick first (locations from clangd are ordered: definition
      -- before declaration). On N>1 (overloads / virtuals), present a picker.
      if #locs == 1 then
        locs[1]._origin_cword = sym
        locs[1]._sym_name     = sym
        if jump_to_location(locs[1]) then
          jumped = true
          cache.put(sym, receiver, locs, "lsp", bufnr)
          done(format_jump_msg(sym, locs[1], "precise"), 3000)
          return
        end
        -- jump failed -> path-B
        csearch_then_gtags()
        return
      end

      -- N>1 candidates -> picker UI. User selects → ui.try_jump executes
      -- the jump itself; if successful, write the *picked* location back
      -- to cache (we don't know which one until the picker finishes, so
      -- ui.try_jump's outcome is "true"/"open_failed" but doesn't return
      -- the chosen location). We fallback to caching the entire candidate
      -- set under the same keys; cache.get's first-element semantics will
      -- replay locs[1] which may not be what the user picked. To avoid
      -- that footgun, we DON'T cache when N>1 — wait for an unambiguous
      -- next gd to record the right answer.
      local outcome = ui.try_jump(locs, "LSP definitions")
      if outcome == true or outcome == "open_failed" then
        jumped = true
        done(format_jump_msg(sym, locs[1], "precise·picker", #locs), 3000)
      else
        -- picker dismissed without a selection
        done()
      end
    end)
end

-- ---------------------------------------------------------------------------
-- M.status
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
    end
  end
  local ok, st = pcall(cache.stats, bufnr)
  if ok and st then
    table.insert(lines, "")
    table.insert(lines, string.format(
      "cache: entries=%d  lru_max=%d  project=%s",
      st.entries or 0, st.lru_max or 0, tostring(st.project)))
  end
  local semantic_status = semantic.status()
  table.insert(lines, "")
  table.insert(lines, string.format(
    "C++ semantic sidecar: running=%s ready=%s pending=%d queued=%d tus=%s last=%s",
    tostring(semantic_status.running), tostring(semantic_status.ready),
    semantic_status.pending or 0, semantic_status.queued or 0,
    tostring(semantic_status.tu_count or "?"), tostring(semantic_status.last_state or "?")))
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "LSP fallback status" })
end

-- ---------------------------------------------------------------------------
-- M.references — sync, qf-only. Unchanged from prior implementation.
-- ---------------------------------------------------------------------------

function M.references()
  local sym = symbol_mod.current_symbol()
  if not sym then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end
  local locations, errors, timed_out = provider.sync_locations("textDocument/references", 5000)
  if timed_out then
    vim.notify("LSP references timed out — falling back to GTAGS", vim.log.levels.WARN)
  elseif errors and errors > 0 then
    vim.notify(string.format("LSP references: %d client(s) errored", errors),
      vim.log.levels.WARN)
  end
  if locations and #locations > 0
    and location_mod.populate_quickfix("LSP references: " .. sym, locations) then
    return
  end
  local ok, ue = pcall(require, "ue")
  if ok and ue.gtags_references and ue.gtags_references(sym) then return end
  vim.notify("No references (LSP/GTAGS)", vim.log.levels.INFO)
end

return M
