-- Real-environment jumper validation.
-- Loads the FULL user nvim config (LazyVim, plugins, lsp_fallback, jumper)
-- and exercises jumper.jump() on real UE source files.
--
-- Run with the user's normal nvim (NOT -u NONE):
--   nvim --headless -S scripts/test_jumper_real.lua
--
-- This is the "no Neovide needed" path — same code, no UI overhead.

local function P(...) io.stdout:write(table.concat({...}, " ") .. "\n") io.stdout:flush() end

P("=== jumper real-env validation ===")
P("nvim version:", vim.version().major .. "." .. vim.version().minor .. "." .. vim.version().patch)
P("rtp head:", (vim.o.runtimepath):sub(1, 200))

-- Disable swapfile so we don't trip user's live Neovide buffers.
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- Pick real UE source + a header to jump to. Use cpp source with #include
-- of a known header so the gd target is well-defined.
local SRC = "<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteCullRaster.cpp"
local TGT = "<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteShared.h"

-- Sanity: files exist
for _, p in ipairs({ SRC, TGT }) do
  local f = io.open(p, "r")
  if not f then P("!! MISSING:", p); os.exit(1) end
  f:close()
end
P("fixtures ok")

-- Load lsp_fallback (which now requires jumper internally) — verify rev
local ok_lf, lf = pcall(require, "utils.lsp_fallback")
P("lsp_fallback loaded:", tostring(ok_lf), "rev=", ok_lf and lf.MODULE_REVISION or "n/a")

local ok_jp, jumper = pcall(require, "utils.ue_goto.jumper")
P("jumper loaded:", tostring(ok_jp), "type(jump)=", ok_jp and type(jumper.jump) or "n/a")
if not ok_jp then os.exit(1) end

-- ========== T1: cold target buffer ==========================================
P("\n--- T1: cold buffer (Nanite.h not loaded) ---")
vim.cmd("edit " .. SRC)
vim.api.nvim_win_set_cursor(0, { 100, 4 })
local src_buf = vim.api.nvim_get_current_buf()
local src_pos = vim.api.nvim_win_get_cursor(0)
P(string.format("source buf=%d pos=%d:%d", src_buf, src_pos[1], src_pos[2]))

local loc = {
  uri = vim.uri_from_fname(TGT),
  range = { start = { line = 49, character = 0 } },
}
local ok = jumper.jump(loc)
P("jump returned:", tostring(ok))
local tgt_buf = vim.api.nvim_get_current_buf()
local tgt_pos = vim.api.nvim_win_get_cursor(0)
P(string.format("now buf=%d pos=%d:%d (target_line=50)", tgt_buf, tgt_pos[1], tgt_pos[2]))

local jl = vim.fn.getjumplist()[1]
local n = #jl
P(string.format("jumplist size=%d, last 3:", n))
for i = math.max(1, n - 2), n do
  local e = jl[i]
  P(string.format("  [%d] bufnr=%d lnum=%d col=%d", i, e.bufnr, e.lnum, e.col))
end

local fail = false

-- Invariant 1: NO (target_buf, 1, 0) in last 2 entries
for i = math.max(1, n - 1), n do
  local e = jl[i]
  if e.bufnr == tgt_buf and e.lnum == 1 and e.col == 0 then
    P(string.format("!! FAIL: spurious (target_buf=%d, 1, 0) at jumplist[%d]", tgt_buf, i))
    fail = true
  end
end
if not fail then P("OK: no spurious (target,1,0)") end

-- Invariant 2: cursor at expected target line
if tgt_pos[1] == 50 then P("OK: cursor at line 50")
else P(string.format("!! FAIL: cursor at %d, expected 50", tgt_pos[1])); fail = true end

-- Invariant 3: last jumplist entry is source pos
local last = jl[n]
if last.bufnr == src_buf and last.lnum == src_pos[1] then
  P(string.format("OK: jumplist tail = source (buf=%d lnum=%d)", last.bufnr, last.lnum))
else
  P(string.format("!! FAIL: tail buf=%d lnum=%d, expected src buf=%d lnum=%d",
    last.bufnr, last.lnum, src_buf, src_pos[1]))
  fail = true
end

-- ========== T2: simulated Ctrl-O ============================================
-- Now actually exercise the jumplist: press Ctrl-O equivalent
P("\n--- T2: verify jumplist semantics (Ctrl-O target = jl[idx-1]) ---")
-- nvim_input is async + no mainloop in headless, so simulate Ctrl-O by
-- inspecting the jumplist directly. After our jump, getjumplist() returns
-- {entries, idx} where idx is the position one PAST the last entry (i.e.
-- pressing Ctrl-O moves to entries[idx]). The entry that Ctrl-O would land
-- on must be the SOURCE position we recorded with m'.
local jl_info = vim.fn.getjumplist()
local entries, idx = jl_info[1], jl_info[2]
P(string.format("jumplist idx=%d (size=%d)", idx, #entries))
-- Ctrl-O lands on entries[idx] (1-indexed). When idx == #entries, we just
-- pushed a new entry and Ctrl-O would step back to that same entry.
local co_target = entries[idx] or entries[#entries]
P(string.format("Ctrl-O target: bufnr=%d lnum=%d col=%d (source was buf=%d lnum=%d col=%d)",
  co_target.bufnr, co_target.lnum, co_target.col, src_buf, src_pos[1], src_pos[2]))

if co_target.bufnr == src_buf and co_target.lnum == src_pos[1] then
  P("OK: Ctrl-O would return to source in ONE press")
else
  P("!! FAIL: Ctrl-O target is not source")
  fail = true
end

-- ========== T3: warm buffer (target already loaded) =========================
P("\n--- T3: warm buffer (target loaded) ---")
vim.cmd("edit " .. SRC)
vim.api.nvim_win_set_cursor(0, { 200, 0 })
local src2_buf = vim.api.nvim_get_current_buf()
local src2_pos = vim.api.nvim_win_get_cursor(0)
P(string.format("source buf=%d pos=%d:%d", src2_buf, src2_pos[1], src2_pos[2]))
local loc2 = {
  uri = vim.uri_from_fname(TGT),
  range = { start = { line = 99, character = 2 } },
}
local ok2 = jumper.jump(loc2)
local tgt2_buf = vim.api.nvim_get_current_buf()
local tgt2_pos = vim.api.nvim_win_get_cursor(0)
P(string.format("jump=%s now buf=%d pos=%d:%d (expected 100:2)",
  tostring(ok2), tgt2_buf, tgt2_pos[1], tgt2_pos[2]))

local jl2 = vim.fn.getjumplist()[1]
local n2 = #jl2
local t2_fail = false
for i = math.max(1, n2 - 1), n2 do
  local e = jl2[i]
  if e.bufnr == tgt2_buf and e.lnum == 1 and e.col == 0 then
    P(string.format("!! FAIL: spurious (target,1,0) at [%d]", i)); t2_fail = true
  end
end
if not t2_fail then P("OK: no spurious entry on warm path") end
if tgt2_pos[1] ~= 100 then
  P(string.format("!! FAIL: cursor at %d, expected 100", tgt2_pos[1])); fail = true
end

-- Verify Ctrl-O target on warm path too
local jl3 = vim.fn.getjumplist()
local e3, i3 = jl3[1], jl3[2]
local co3 = e3[i3] or e3[#e3]
P(string.format("warm Ctrl-O target: bufnr=%d lnum=%d (src was buf=%d lnum=%d)",
  co3.bufnr, co3.lnum, src2_buf, src2_pos[1]))
if co3.bufnr ~= src2_buf or co3.lnum ~= src2_pos[1] then
  P("!! FAIL: warm-path Ctrl-O target wrong"); fail = true
else
  P("OK: warm-path Ctrl-O would return to source")
end

-- ========== summary =========================================================
P("\n=== SUMMARY ===")
if fail then P("RESULT: FAILED"); os.exit(1) else P("RESULT: ALL PASSED"); os.exit(0) end
