-- utils/lsp_fallback.lua
-- ============================================================================
-- gd orchestrator.
--
-- C/C++ is delegated to utils.ue_goto.semantic_navigation. This file keeps
-- public commands/API, trace plumbing, jump helpers, and the non-C++
-- compatibility chain (cache -> LSP -> csearch -> GTAGS).
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
local semantic_nav = require("utils.ue_goto.semantic_navigation")

local LSP_PROGRESS_NOTICE_MS = 600
local OVERALL_TIMEOUT_MS     = 30000
local CSEARCH_TIMEOUT_MS     = 4000

local MODULE_REVISION = "contextual-clang-v2"
local TRACE_MAX = 200
local trace_ring = {}
local trace_idx = 0
local DISK_LOG = vim.fn.stdpath("cache") .. ("/ue_def_trace.%d.log"):format(vim.fn.getpid())

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
    { "semantic_nav",  pcall(require, "utils.ue_goto.semantic_navigation") },
    { "transaction",   pcall(require, "utils.ue_goto.semantic_transaction") },
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

vim.api.nvim_create_user_command("UEDefTrace", function() M.dump_trace() end, {})
vim.api.nvim_create_user_command("UEDefSelfTest", function() M.self_test() end, {})
vim.api.nvim_create_user_command("UEDefReload", reload_ue_def, {
  desc = "Hot-reload ue_goto/lsp_fallback modules + run self-test",
})

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

local function jump_to_location(location)
  if not location then return false end
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

M._test_jump_to_location = jump_to_location

local function format_jump_msg(sym, loc, tag, n_more)
  local p = location_mod.location_path(loc)
  local short = p:match("([^/\\]+)$") or "?"
  local label = string.format("%s:%d", short, location_mod.location_line(loc))
  if n_more and n_more > 1 then
    return string.format("✓ %s → %s (%s, %d candidates)", sym or "?", label, tag, n_more)
  end
  return string.format("✓ %s → %s (%s)", sym or "?", label, tag)
end

local navigation = semantic_nav.install(M, {
  dtrace = dtrace,
  jump_to_location = jump_to_location,
  format_jump_msg = format_jump_msg,
})

vim.api.nvim_create_user_command("UEDefExplain", function() M.explain() end, {})

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
  if navigation.CPP_SOURCE_EXTS[ext] or navigation.CPP_HEADER_EXTS[ext] then
    navigation.cpp_definition(sym, bufnr, ref_file, ext)
    return
  end

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
    M._active_notice = notice
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

-- References: fully async.
--
-- WHY (measured 2026-08-25): the previous implementation blocked the main loop
-- twice on a single `gr`:
--   1. provider.sync_locations -> client:request_sync(..., 5000) — up to FIVE
--      SECONDS of frozen editor while clangd answers (or doesn't).
--   2. ue.gtags_references -> vim.system(...):wait() — the bare spawn floor on
--      this Windows host is 87ms p50, with `global -r` at 82ms p50 / 293ms max.
-- Both violate P6 (never block the UI) and C4-2 (async over blocking). Async
-- twins already existed for the heavy lifting; references was the last everyday
-- keystroke still on the blocking path.
--
-- Behaviour is preserved: same quickfix titles, same GTAGS fallback ordering,
-- same "nothing found" message. Only the waiting is no longer synchronous.
function M.references()
  local sym = symbol_mod.current_symbol()
  if not sym then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end

  local function gtags_fallback()
    local ok, ue = pcall(require, "ue")
    if ok and ue.gtags_references_async then
      ue.gtags_references_async(sym, function(jumped)
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
    if locations and #locations > 0
      and location_mod.populate_quickfix("LSP references: " .. sym, locations) then
      return
    end
    gtags_fallback()
  end)
end

return M
