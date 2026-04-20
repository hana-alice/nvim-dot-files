local symbol = require("utils.ue_goto.symbol")
local TMPDIR = "C:/temp/ue_goto_test"
vim.fn.mkdir(TMPDIR, "p")

local function write(path, content)
  local f = io.open(path, "w")
  f:write(content); f:close()
end

-- Case 1: 5-param declaration on line 2
local f1 = TMPDIR .. "/d1.cpp"
write(f1, [[
void Foo(); // line 1 — wrong line, ignore
void Foo(int a, int b, int c, int d, int e); // line 2 — target
void Bar();
]])
local p, d, v = symbol.declarator_arity_at(f1, 2)
assert(p == 5, "case1 P expected 5, got " .. tostring(p))
assert(d == 0, "case1 D expected 0")
assert(v == false, "case1 variadic expected false")

-- Case 2: defaults
local f2 = TMPDIR .. "/d2.cpp"
write(f2, [[
void Foo(int a, int b = 1, int c = 2);
]])
p, d, v = symbol.declarator_arity_at(f2, 1)
assert(p == 3 and d == 2, "case2 expected P=3 D=2, got P=" .. tostring(p) .. " D=" .. tostring(d))

-- Case 3: variadic (C-style)
local f3 = TMPDIR .. "/d3.cpp"
write(f3, [[
void Logf(const char* fmt, ...);
]])
p, d, v = symbol.declarator_arity_at(f3, 1)
assert(v == true, "case3 variadic expected true")

-- Case 4: out-of-class definition
local f4 = TMPDIR .. "/d4.cpp"
write(f4, [[
void FRenderer::DrawGeometry(
  Pipelines& a,
  Query b,
  Buffer c,
  Buffer d,
  int e,
  Cull* f,
  const Draw* g,
  const Info* h)
{
}
]])
p, d, v = symbol.declarator_arity_at(f4, 1)
assert(p == 8 and d == 0 and v == false, "case4 expected P=8 D=0 V=false, got P=" .. tostring(p) .. " D=" .. tostring(d) .. " V=" .. tostring(v))

-- Case 5: line number is one off (line 2, real declarator on line 1) — tolerant
p, d, v = symbol.declarator_arity_at(f1, 1)  -- line 1 is `void Foo();`
assert(p == 0, "case5 expected P=0 (zero-arg) got " .. tostring(p))

-- Case 6: file does not exist
p = symbol.declarator_arity_at("C:/temp/does_not_exist.cpp", 1)
assert(p == nil, "case6 expected nil for missing file")

-- Case 7: empty file → nil
local f7 = TMPDIR .. "/d7_empty.cpp"
write(f7, "")
p = symbol.declarator_arity_at(f7, 1)
assert(p == nil, "case7 expected nil for empty file")

-- Case 8: garbage / unparseable content far from any declarator → nil
-- (we look in ±3 line window; declarator at line 50 should not match line 1)
local f8 = TMPDIR .. "/d8_far.cpp"
local lines = {}
for i = 1, 49 do lines[i] = "// noise " .. i end
lines[50] = "void Far(int x);"
write(f8, table.concat(lines, "\n"))
p = symbol.declarator_arity_at(f8, 1)
assert(p == nil, "case8 expected nil for declarator outside ±3 window, got " .. tostring(p))

-- Case 9: ERROR-node tolerance — malformed source, ensure no crash and graceful nil/0
-- (broken signature with mismatched braces)
local f9 = TMPDIR .. "/d9_broken.cpp"
write(f9, "void Broken(int a, int b // no closing paren\nint main() { return 0; }\n")
local ok9, _ = pcall(symbol.declarator_arity_at, f9, 1)
assert(ok9, "case9 should not throw on malformed source")

-- Case 10: parameter_list fallback path — ensure correctness when declarator
-- is found and counts come from iterating parameter_declaration children.
-- (Already exercised by cases 1/2/4 implicitly, but assert default-count
--  branch when only a single optional_parameter_declaration is present.)
local f10 = TMPDIR .. "/d10.cpp"
write(f10, "void OneDefault(int x = 42);\n")
p, d, v = symbol.declarator_arity_at(f10, 1)
assert(p == 1 and d == 1 and v == false,
  "case10 expected P=1 D=1 V=false, got P=" .. tostring(p) .. " D=" .. tostring(d) .. " V=" .. tostring(v))

print("PASS test_declarator_arity (6 cases)")
