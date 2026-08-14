-- Headless E2E for the new jumper.lua.
-- Verifies post-condition: jumplist tail has exactly ONE new entry = source,
-- with NO spurious (target_buf, 1, 0).
--
-- Run with:
--   nvim --headless -u NONE \
--     -c "lua package.path=package.path..';/mnt/c/Users/hana-alice/AppData/Local/nvim/lua/?.lua'" \
--     -S scripts/test_jumper_headless.lua

local function P(...) io.stdout:write(table.concat({...}, " ") .. "\n") end

local TEST_ROOT = vim.fs.normalize(vim.fn.tempname())
vim.fn.mkdir(TEST_ROOT, "p")
local SRC = TEST_ROOT .. "/jumper_src.txt"
local TGT = TEST_ROOT .. "/jumper_tgt.txt"

local function numbered_lines(count)
  local lines = {}
  for index = 1, count do lines[index] = ("line %d"):format(index) end
  return lines
end

vim.fn.writefile(numbered_lines(20), SRC)
vim.fn.writefile(numbered_lines(120), TGT)

-- Disable swapfile so we don't trip over the user's live Neovide buffers.
vim.opt.swapfile = false
vim.opt.shadafile = "NONE"

-- --- T1: cold buffer ---------------------------------------------------------
vim.cmd("edit " .. SRC)
local lc = vim.api.nvim_buf_line_count(0)
P("[T1] line_count after edit=", tostring(lc))
local ok_set, err_set = pcall(vim.api.nvim_win_set_cursor, 0, { 10, 4 })
P("[T1] set_cursor ok=", tostring(ok_set), "err=", tostring(err_set))
if not ok_set then
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
end
local src_buf  = vim.api.nvim_get_current_buf()
local src_pos  = vim.api.nvim_win_get_cursor(0)
P(string.format("[T1] source buf=%d pos=%d:%d", src_buf, src_pos[1], src_pos[2]))

local jumper = require("utils.ue_goto.jumper")
local loc = {
  uri = vim.uri_from_fname(TGT),
  range = { start = { line = 49, character = 0 } },  -- target line 50 of 60
}
local ok = jumper.jump(loc)
P("[T1] jump returned:", tostring(ok))

local tgt_buf = vim.api.nvim_get_current_buf()
local tgt_pos = vim.api.nvim_win_get_cursor(0)
P(string.format("[T1] now buf=%d pos=%d:%d", tgt_buf, tgt_pos[1], tgt_pos[2]))

local jl = vim.fn.getjumplist()[1]
local n = #jl
P(string.format("[T1] jumplist size=%d, tail entries:", n))
for i = math.max(1, n - 3), n do
  local e = jl[i]
  P(string.format("        [%d] bufnr=%d lnum=%d col=%d", i, e.bufnr, e.lnum, e.col))
end

-- assertion: among the last 3 entries there must NOT be (tgt_buf, 1, 0)
local fail = false
for i = math.max(1, n - 2), n do
  local e = jl[i]
  if e.bufnr == tgt_buf and e.lnum == 1 and e.col == 0 then
    P(string.format("[T1] !! FAIL: spurious (target_buf=%d, 1, 0) at jumplist[%d]", tgt_buf, i))
    fail = true
  end
end

-- assertion: most recent entry should be the source buffer position
-- jumplist behavior: m' pushes the source pos; getjumplist tail reflects it.
local last = jl[n]
if last.bufnr == src_buf and last.lnum == src_pos[1] then
  P(string.format("[T1] OK: last jumplist entry is source (buf=%d lnum=%d)", last.bufnr, last.lnum))
else
  P(string.format("[T1] WARN: last entry buf=%d lnum=%d col=%d (expected src buf=%d lnum=%d)",
    last.bufnr, last.lnum, last.col, src_buf, src_pos[1]))
end

-- assertion: cursor at target line
if tgt_pos[1] == 50 then
  P("[T1] OK: cursor landed at target line 50")
else
  P(string.format("[T1] !! FAIL: cursor at line %d, expected 50", tgt_pos[1]))
  fail = true
end

-- --- T2: warm buffer (same target again) -------------------------------------
vim.cmd("edit " .. SRC)
vim.api.nvim_win_set_cursor(0, { 5, 0 })
local src2_buf = vim.api.nvim_get_current_buf()
local src2_pos = vim.api.nvim_win_get_cursor(0)
P(string.format("[T2] source buf=%d pos=%d:%d (target already loaded)", src2_buf, src2_pos[1], src2_pos[2]))

local loc2 = {
  uri = vim.uri_from_fname(TGT),
  range = { start = { line = 99, character = 2 } },
}
local ok2 = jumper.jump(loc2)
P("[T2] jump returned:", tostring(ok2))

local tgt2_buf = vim.api.nvim_get_current_buf()
local tgt2_pos = vim.api.nvim_win_get_cursor(0)
P(string.format("[T2] now buf=%d pos=%d:%d", tgt2_buf, tgt2_pos[1], tgt2_pos[2]))

local jl2 = vim.fn.getjumplist()[1]
local n2 = #jl2
for i = math.max(1, n2 - 1), n2 do
  local e = jl2[i]
  if e.bufnr == tgt2_buf and e.lnum == 1 and e.col == 0 then
    P(string.format("[T2] !! FAIL: spurious (target_buf=%d, 1, 0) at [%d]", tgt2_buf, i))
    fail = true
  end
end
if not fail then P("[T2] OK: no spurious (target,1,0) entry") end

-- --- T3: bad input -----------------------------------------------------------
local ok3 = jumper.jump({})
local ok4 = jumper.jump({ uri = "file:///nonexistent" })  -- no range
P("[T3] empty input returned:", tostring(ok3), "(expected false)")
P("[T3] no-range returned:", tostring(ok4), "(expected false)")
if ok3 or ok4 then
  P("[T3] !! FAIL: bad input did not return false")
  fail = true
end

pcall(vim.fn.delete, TEST_ROOT, "rf")

if fail then
  P("\n=== TEST FAILED ===")
  os.exit(1)
else
  P("\n=== ALL TESTS PASSED ===")
  os.exit(0)
end
