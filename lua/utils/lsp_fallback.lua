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
local ui           = require("utils.ue_goto.ui")
local jumper       = require("utils.ue_goto.jumper")
local semantic     = require("utils.ue_goto.semantic_client")
local semantic_nav = require("utils.ue_goto.semantic_navigation")

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
  if semantic.dispose then semantic.dispose() end
  if M._dispose_compat then M._dispose_compat() end
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
  local ok, st = pcall(require("utils.ue_goto.cache").stats, 0)
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
  local cache = require("utils.ue_goto.cache")
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

local compat
function M._dispose_compat() if compat then compat.dispose() end end
local function compatibility()
  if not compat then
    compat = require("utils.ue_goto.compat_navigation").install({
      dtrace = dtrace, jump_to_location = jump_to_location, format_jump_msg = format_jump_msg,
    })
  end
  return compat
end

function M.definition()
  local bufnr = vim.api.nvim_get_current_buf()
  local sym = symbol_mod.current_symbol()
  local path = location_mod.normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local ext = ui.buf_extension(bufnr)
  dtrace("M.definition() sym=%q file=%s:%d", sym or "", vim.fn.fnamemodify(path, ":t"),
    vim.api.nvim_win_get_cursor(0)[1])
  if navigation.CPP_SOURCE_EXTS[ext] or navigation.CPP_HEADER_EXTS[ext] then
    if compat then compat.dispose() end
    navigation.cpp_definition(sym, bufnr, path, ext)
    return
  end
  semantic.cancel_action()
  compatibility().definition(sym, symbol_mod.current_receiver(), bufnr, path, vim.api.nvim_win_get_cursor(0)[1], ext)
end

function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = {
    string.format("buffer: %d  name: %s", bufnr, vim.api.nvim_buf_get_name(bufnr)),
    string.format("request_token: %d", compat and compat.request_token() or 0),
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
  local ok, st = pcall(require("utils.ue_goto.cache").stats, bufnr)
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

function M.references()
  return compatibility().references()
end

return M
