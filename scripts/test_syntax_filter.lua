-- Run with:
-- "/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
--   -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
--   -c 'luafile C:\\Users\\<USER>\\AppData\\Local\\nvim\\scripts\\test_syntax_filter.lua' \
--   -c 'qa!'
local symbol = require("utils.ue_goto.symbol")
local sf = require("utils.ue_goto.syntax_filter")
local TMPDIR = "C:/temp/ue_goto_test"
vim.fn.mkdir(TMPDIR, "p")

local function write_file(path, content)
  local f = io.open(path, "w")
  f:write(content); f:close()
end

-- ---------------------------------------------------------------------------
-- DrawGeometry main case (plan's "happy path" scenario)
-- ---------------------------------------------------------------------------
local cpp_path = TMPDIR .. "/NaniteCullRaster.cpp"
local h_path = TMPDIR .. "/NaniteCullRaster.h"
local cpp_lines = {}
for i = 1, 6301 do cpp_lines[i] = "// pad " .. i end
cpp_lines[6257] = "void FRenderer::DrawGeometry(int a, int b, int c, int d, int e) {"
cpp_lines[6258] = "  call_into_8_arg_overload();"
cpp_lines[6259] = "}"
cpp_lines[6300] = "void FRenderer::DrawGeometry(int a, int b, int c, int d, int e, int f, int g, int h) {"
cpp_lines[6301] = "}"
local f = io.open(cpp_path, "w"); f:write(table.concat(cpp_lines, "\n")); f:close()

local h_lines = {}
for i = 1, 241 do h_lines[i] = "// pad " .. i end
h_lines[196] = "  void DrawGeometry(int, int, int, int, int);"
h_lines[209] = "  void DrawGeometry(int, int, int, int, int);"
h_lines[219] = "  void DrawGeometry(int, int, int, int, int);"
h_lines[229] = "  void DrawGeometry(int, int, int, int, int);"
h_lines[241] = "  void DrawGeometry(int, int, int, int, int, int, int, int);"
local fh = io.open(h_path, "w"); fh:write(table.concat(h_lines, "\n")); fh:close()

-- Set up a buffer mimicking the call site at line 6290 with 8 args
vim.cmd("enew")
vim.bo.filetype = "cpp"
local caller_lines = {}
for i = 1, 6300 do caller_lines[i] = "// pad " .. i end
caller_lines[6263] = "void FRenderer::DrawGeometry(int a1, int a2, int a3, int a4, int a5) {"
caller_lines[6290] = "  DrawGeometry(p1, p2, p3, p4, p5, p6, p7, nullptr);"
caller_lines[6298] = "}"
vim.api.nvim_buf_set_lines(0, 0, -1, false, caller_lines)
vim.treesitter.start(0, "cpp")
vim.api.nvim_win_set_cursor(0, { 6290, 4 })  -- on DrawGeometry

-- Build candidate locations (mimicking what ws/symbol returns)
local function loc(path, line_1b)
  return {
    uri = vim.uri_from_fname(path),
    range = { start = { line = line_1b - 1, character = 5 }, ["end"] = { line = line_1b - 1, character = 17 } },
  }
end
local candidates = {
  loc(h_path, 196),
  loc(h_path, 209),
  loc(h_path, 219),
  loc(h_path, 229),
  loc(h_path, 241),    -- 8-arg .h decl (also a match!)
  loc(cpp_path, 6257), -- 5-arg .cpp def
  loc(cpp_path, 6300), -- 8-arg .cpp def — primary target
}

local function dtrace(fmt, ...) print("[trace] " .. string.format(fmt, ...)) end
local filtered, info = sf.filter_by_call_signature(candidates, vim.api.nvim_get_current_buf(), dtrace)

-- Expected: 5-arg candidates eliminated, 8-arg candidates kept (h:241, cpp:6300)
assert(#filtered == 2, "case-main: expected 2 survivors, got " .. #filtered)
local got_lines = {}
for _, l in ipairs(filtered) do
  table.insert(got_lines, vim.uri_to_fname(l.uri):match("[^/\\]+$") .. ":" .. (l.range.start.line + 1))
end
table.sort(got_lines)
local expected = { "NaniteCullRaster.cpp:6300", "NaniteCullRaster.h:241" }
table.sort(expected)
assert(got_lines[1] == expected[1] and got_lines[2] == expected[2],
  "case-main: got " .. table.concat(got_lines, ",") .. " expected " .. table.concat(expected, ","))

assert(info.applied == true, "case-main: info.applied expected true")
assert(info.call_arity == 8, "case-main: info.call_arity expected 8, got " .. tostring(info.call_arity))
assert(info.before == 7 and info.after == 2, "case-main: info before/after wrong b=" .. info.before .. " a=" .. info.after)
assert(info.callee == "DrawGeometry", "case-main: callee expected DrawGeometry, got " .. tostring(info.callee))
assert(info.skipped == 0, "case-main: skipped expected 0, got " .. tostring(info.skipped))

-- ---------------------------------------------------------------------------
-- Pass-through case: cursor not in a call
-- ---------------------------------------------------------------------------
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local filtered2, info2 = sf.filter_by_call_signature(candidates, vim.api.nvim_get_current_buf(), dtrace)
assert(#filtered2 == #candidates, "case-passthrough: no-call cursor should pass-through, got " .. #filtered2)
assert(info2.applied == false, "case-passthrough: info.applied expected false")
assert(info2.before == 7 and info2.after == 7, "case-passthrough: before/after both 7, got b=" .. info2.before .. " a=" .. info2.after)

-- ---------------------------------------------------------------------------
-- Empty input
-- ---------------------------------------------------------------------------
local filtered3, info3 = sf.filter_by_call_signature({}, vim.api.nvim_get_current_buf(), dtrace)
assert(#filtered3 == 0, "case-empty: expected 0")
assert(info3.before == 0 and info3.after == 0, "case-empty: counts wrong")

-- ---------------------------------------------------------------------------
-- Nil input
-- ---------------------------------------------------------------------------
local filtered4, info4 = sf.filter_by_call_signature(nil, vim.api.nvim_get_current_buf(), dtrace)
assert(filtered4 ~= nil and #filtered4 == 0, "case-nil: expected empty list")
assert(info4.before == 0 and info4.after == 0, "case-nil: counts wrong")

-- ---------------------------------------------------------------------------
-- "All eliminated → fallback to original" safety net.
-- Call has K=2 but only candidate is a 0-arg declaration.
-- ---------------------------------------------------------------------------
local zero_path = TMPDIR .. "/zero.cpp"
write_file(zero_path, "void OnlyZero();\n")
vim.cmd("enew")
vim.bo.filetype = "cpp"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "void caller() {",
  "  OnlyZero(a, b);",
  "}",
})
vim.treesitter.start(0, "cpp")
vim.api.nvim_win_set_cursor(0, { 2, 4 })
local cands_all_drop = { loc(zero_path, 1) }
local f5, i5 = sf.filter_by_call_signature(cands_all_drop, vim.api.nvim_get_current_buf(), dtrace)
-- All eliminated → fallback to unfiltered list
assert(#f5 == 1, "case-allgone: expected fallback to keep 1, got " .. #f5)
assert(i5.applied == true, "case-allgone: applied true")
assert(i5.after == 1, "case-allgone: after expected 1 (fallback length), got " .. tostring(i5.after))

-- ---------------------------------------------------------------------------
-- EXTRA TEST a) Variadic candidate
--   void Logf(const char* fmt, ...);   P=1, V=true
--   call: Logf("%d %d %d", 1, 2, 3);   K=4 → KEEP (4 >= 1)
-- ---------------------------------------------------------------------------
local var_path = TMPDIR .. "/variadic.cpp"
write_file(var_path, "void Logf(const char* fmt, ...);\n")
vim.cmd("enew")
vim.bo.filetype = "cpp"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "void caller() {",
  "  Logf(\"%d %d %d\", 1, 2, 3);",
  "}",
})
vim.treesitter.start(0, "cpp")
vim.api.nvim_win_set_cursor(0, { 2, 4 })
local fv, iv = sf.filter_by_call_signature({ loc(var_path, 1) }, vim.api.nvim_get_current_buf(), dtrace)
assert(#fv == 1, "case-variadic: expected variadic kept, got " .. #fv)
assert(iv.applied == true and iv.call_arity == 4, "case-variadic: K=4")
assert(iv.callee == "Logf", "case-variadic: callee Logf got " .. tostring(iv.callee))

-- ---------------------------------------------------------------------------
-- EXTRA TEST b) Default parameters
--   void Foo(int a, int b = 1, int c = 2);   P=3 D=2  → accepts K∈[1,3]
--   K=1,2,3 → KEEP   K=0 / K=4 → DROP (fallback fires for single-cand list)
-- ---------------------------------------------------------------------------
local def_path = TMPDIR .. "/defaults.cpp"
write_file(def_path, "void Foo(int a, int b = 1, int c = 2);\n")

local function run_default_call(call_text)
  vim.cmd("enew")
  vim.bo.filetype = "cpp"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {
    "void caller() {",
    "  " .. call_text,
    "}",
  })
  vim.treesitter.start(0, "cpp")
  vim.api.nvim_win_set_cursor(0, { 2, 4 })
  return sf.filter_by_call_signature({ loc(def_path, 1) }, vim.api.nvim_get_current_buf(), dtrace)
end

-- Build a multi-candidate context so "all eliminated" fallback doesn't mask the assertion:
-- For the "should keep" cases, single-candidate is fine — kept means kept.
local fk1, ik1 = run_default_call("Foo(1);")
assert(#fk1 == 1 and ik1.call_arity == 1, "case-default K=1: kept")
local fk2, ik2 = run_default_call("Foo(1, 2);")
assert(#fk2 == 1 and ik2.call_arity == 2, "case-default K=2: kept")
local fk3, ik3 = run_default_call("Foo(1, 2, 3);")
assert(#fk3 == 1 and ik3.call_arity == 3, "case-default K=3: kept")

-- For drop cases, add a SECOND keepable candidate so the "all-eliminated fallback"
-- doesn't mask the drop. Use a P=4 candidate that accepts K=4 (and is dropped for K=0).
local p4_path = TMPDIR .. "/p4.cpp"
write_file(p4_path, "void Foo(int a, int b, int c, int d);\n")

-- K=4 → P=3 D=2 candidate dropped; P=4 candidate kept
vim.cmd("enew")
vim.bo.filetype = "cpp"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "void caller() {",
  "  Foo(1, 2, 3, 4);",
  "}",
})
vim.treesitter.start(0, "cpp")
vim.api.nvim_win_set_cursor(0, { 2, 4 })
local fdrop_hi, idrop_hi = sf.filter_by_call_signature(
  { loc(def_path, 1), loc(p4_path, 1) }, vim.api.nvim_get_current_buf(), dtrace)
assert(idrop_hi.call_arity == 4, "case-default K=4: K parsed")
assert(#fdrop_hi == 1, "case-default K=4: expected 1 survivor (the P=4), got " .. #fdrop_hi)
local kept_path = vim.uri_to_fname(fdrop_hi[1].uri):match("[^/\\]+$")
assert(kept_path == "p4.cpp", "case-default K=4: expected p4.cpp kept, got " .. tostring(kept_path))
assert(idrop_hi.before == 2 and idrop_hi.after == 1, "case-default K=4: counts b=2 a=1")

-- K=0 → P=3 D=2 candidate dropped (needs K>=1); also P=4 candidate dropped (needs K>=4)
-- → ALL eliminated → fallback returns full list of 2
vim.cmd("enew")
vim.bo.filetype = "cpp"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "void caller() {",
  "  Foo();",
  "}",
})
vim.treesitter.start(0, "cpp")
vim.api.nvim_win_set_cursor(0, { 2, 4 })
local fdrop_lo, idrop_lo = sf.filter_by_call_signature(
  { loc(def_path, 1), loc(p4_path, 1) }, vim.api.nvim_get_current_buf(), dtrace)
assert(idrop_lo.call_arity == 0, "case-default K=0: K parsed")
-- Both dropped → fallback to original (length 2)
assert(#fdrop_lo == 2, "case-default K=0: expected fallback to 2, got " .. #fdrop_lo)
assert(idrop_lo.after == 2, "case-default K=0: after counts as fallback len")

-- ---------------------------------------------------------------------------
-- EXTRA TEST c) Parse failure fallback (file does not exist)
--   skipped should increment by 1; candidate should be kept (conservative).
-- ---------------------------------------------------------------------------
vim.cmd("enew")
vim.bo.filetype = "cpp"
vim.api.nvim_buf_set_lines(0, 0, -1, false, {
  "void caller() {",
  "  SomeFn(a, b);",
  "}",
})
vim.treesitter.start(0, "cpp")
vim.api.nvim_win_set_cursor(0, { 2, 4 })
local missing_loc = loc("C:/temp/__definitely_not_present__.cpp", 1)
local good_path = TMPDIR .. "/good_skip.cpp"
write_file(good_path, "void SomeFn(int a, int b);\n")
local fskip, iskip = sf.filter_by_call_signature(
  { missing_loc, loc(good_path, 1) }, vim.api.nvim_get_current_buf(), dtrace)
assert(iskip.applied == true, "case-skipped: applied true")
assert(iskip.call_arity == 2, "case-skipped: K=2")
assert(iskip.skipped == 1, "case-skipped: expected skipped=1, got " .. tostring(iskip.skipped))
assert(#fskip == 2, "case-skipped: expected both kept (skipped + match), got " .. #fskip)
assert(iskip.before == 2 and iskip.after == 2, "case-skipped: before/after = 2,2")

-- ---------------------------------------------------------------------------
-- EXTRA TEST d) info table completeness on the main DrawGeometry path
-- (re-verifies all info fields explicitly: applied/call_arity/callee/before/after/skipped)
-- ---------------------------------------------------------------------------
-- Reuse cpp_path/h_path created above
vim.cmd("enew")
vim.bo.filetype = "cpp"
local caller_lines2 = {}
for i = 1, 10 do caller_lines2[i] = "// pad " .. i end
caller_lines2[3] = "void caller() {"
caller_lines2[5] = "  DrawGeometry(p1, p2, p3, p4, p5, p6, p7, nullptr);"
caller_lines2[7] = "}"
vim.api.nvim_buf_set_lines(0, 0, -1, false, caller_lines2)
vim.treesitter.start(0, "cpp")
vim.api.nvim_win_set_cursor(0, { 5, 4 })
local fi_check_locs = {
  loc(h_path, 196),    -- P=5 → drop
  loc(h_path, 241),    -- P=8 → keep
  loc(cpp_path, 6300), -- P=8 → keep
  loc("C:/temp/__missing_for_info__.cpp", 1), -- skipped
}
local f_info, i_info = sf.filter_by_call_signature(fi_check_locs, vim.api.nvim_get_current_buf(), dtrace)
assert(type(i_info.applied) == "boolean" and i_info.applied == true, "info.applied bool true")
assert(type(i_info.call_arity) == "number" and i_info.call_arity == 8, "info.call_arity == 8")
assert(type(i_info.callee) == "string" and i_info.callee == "DrawGeometry", "info.callee string DrawGeometry")
assert(type(i_info.before) == "number" and i_info.before == 4, "info.before == 4")
assert(type(i_info.after) == "number" and i_info.after == 3, "info.after == 3 (2 keeps + 1 skipped)")
assert(type(i_info.skipped) == "number" and i_info.skipped == 1, "info.skipped == 1")
assert(#f_info == 3, "case-info: expected 3 survivors (2 match + 1 skipped), got " .. #f_info)

print("PASS test_syntax_filter (DrawGeometry 7→2 + pass-through)")
print("PASS test_syntax_filter extras (variadic, defaults, parse-fail, info-completeness)")
