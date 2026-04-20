-- Tier 2 smoke test: load lsp_fallback in FULL user config and verify
-- the 6 leaf modules + orchestrator all wire up correctly.
-- Does NOT exercise actual LSP requests (no clangd in headless).

local function P(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  io.write(table.concat(parts, " ") .. "\n")
  io.flush()
end

P("=== ue_goto Tier 2 wire-up smoke test ===")
P("nvim version:", vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)

vim.opt.swapfile = false
vim.opt.shada = ""

local function check(name)
  local ok, mod = pcall(require, name)
  if not ok then
    P("FAIL require " .. name .. ":", tostring(mod):sub(1, 200))
    return nil
  end
  P("OK   require " .. name .. ":", type(mod))
  return mod
end

local symbol   = check("utils.ue_goto.symbol")
local location = check("utils.ue_goto.location")
local ranking  = check("utils.ue_goto.ranking")
local provider = check("utils.ue_goto.provider")
local ui       = check("utils.ue_goto.ui")
local jumper   = check("utils.ue_goto.jumper")
local lf       = check("utils.lsp_fallback")

if not (symbol and location and ranking and provider and ui and jumper and lf) then
  P("FAIL: not all modules loaded")
  vim.cmd("cq!")
end

P("\n--- public API surface check ---")
local public = {
  "definition", "references", "jump_to_precise", "status",
  "dump_trace", "self_test",
  "_test_jump_to_location", "_test_reconcile",
  "MODULE_REVISION",
}
local missing = {}
for _, k in ipairs(public) do
  local v = lf[k]
  if v == nil then
    missing[#missing + 1] = k
    P("MISSING", k)
  else
    P("OK     ", k, "=", type(v) == "function" and "function" or tostring(v):sub(1, 60))
  end
end

P("\n--- pure-logic invariants ---")
-- 1. ranking sorts .cpp before .h (winner-pick was removed in 2026-04
--    syntax-filter-v1; ranking is now sort-only, used as quickfix order
--    after syntax_filter narrows candidates).
do
  local cpp = { uri = "file:///c:/x/y.cpp", range = { start = { line = 0 } } }
  local h   = { uri = "file:///c:/x/y.h",   range = { start = { line = 0 } } }
  local sorted = ranking.rerank_locations({ h, cpp }, {}, "/c/x/z.cpp", "")
  if sorted[1] == cpp and sorted[2] == h then
    P("OK   .cpp sorts before .h (rerank_locations)")
  else
    P("FAIL .cpp sort: got",
      tostring(sorted[1] and sorted[1].uri),
      tostring(sorted[2] and sorted[2].uri))
    missing[#missing + 1] = "rank_cpp_sort"
  end
end
-- 2. self_test (synthetic GetBinCount header-only relax) returns true
do
  local ok = lf.self_test()
  if ok then
    P("OK   self_test returns true (header-only relaxation loaded)")
  else
    P("FAIL self_test returned false")
    missing[#missing + 1] = "self_test"
  end
end
-- 3. jumper still has same contract — call jump on a synthesized location
--    (we have no LSP, just verify it doesn't crash and returns a bool)
do
  local fixture = "C:/temp/tier2_smoke.txt"
  pcall(function()
    local f = io.open(fixture, "w")
    if f then for i = 1, 30 do f:write("line " .. i .. "\n") end; f:close() end
  end)
  vim.cmd("edit " .. fixture)
  local loc = {
    uri = vim.uri_from_fname(fixture),
    range = { start = { line = 9, character = 2 } },
  }
  local ok = jumper.jump(loc)
  local cur = vim.api.nvim_win_get_cursor(0)
  if ok and cur[1] == 10 then
    P("OK   jumper still navigates to (10, 2):", cur[1] .. ":" .. cur[2])
  else
    P("FAIL jumper:", tostring(ok), cur[1] .. ":" .. cur[2])
    missing[#missing + 1] = "jumper_basic"
  end
end

P("\n=== SUMMARY ===")
if #missing == 0 then
  P("RESULT: ALL PASSED — Tier 2 wire-up clean")
else
  P("RESULT: FAILED — missing/broken:", table.concat(missing, ", "))
end
vim.cmd(#missing == 0 and "qa!" or "cq!")
