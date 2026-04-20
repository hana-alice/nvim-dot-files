-- Run with: nvim.exe --headless --noplugin -u NONE \
--   -c "set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim" \
--   -c "luafile scripts\\test_call_arity.lua"
local symbol = require("utils.ue_goto.symbol")

local function setup_buf(text)
  vim.cmd("enew")
  vim.bo.filetype = "cpp"
  vim.api.nvim_buf_set_lines(0, 0, -1, false, vim.split(text, "\n"))
  vim.treesitter.start(0, "cpp")
end

-- Case 1: simple 3-arg call
setup_buf([[
void caller() {
  Foo(a, b, c);
}
]])
vim.api.nvim_win_set_cursor(0, { 2, 4 })  -- on `Foo`
local arity, name = symbol.call_arity_at_cursor()
assert(arity == 3, "case1 arity expected 3, got " .. tostring(arity))
assert(name == "Foo", "case1 name expected Foo, got " .. tostring(name))

-- Case 2: 8-arg call (the DrawGeometry case)
setup_buf([[
void caller() {
  DrawGeometry(p1, p2, p3, p4, p5, p6, p7, nullptr);
}
]])
vim.api.nvim_win_set_cursor(0, { 2, 4 })
arity, name = symbol.call_arity_at_cursor()
assert(arity == 8, "case2 arity expected 8, got " .. tostring(arity))

-- Case 3: cursor NOT in a call (declaration site)
setup_buf([[
void Foo(int a, int b);
]])
vim.api.nvim_win_set_cursor(0, { 1, 6 })  -- on `Foo` in declaration
arity, name = symbol.call_arity_at_cursor()
assert(arity == nil, "case3 expected nil, got " .. tostring(arity))

-- Case 4: nested call — outer arity should win when cursor is on outer name
setup_buf([[
void caller() {
  Outer(Inner(1, 2), 3);
}
]])
vim.api.nvim_win_set_cursor(0, { 2, 4 })  -- on `Outer`
arity, name = symbol.call_arity_at_cursor()
assert(arity == 2 and name == "Outer", "case4 expected (2,Outer), got (" .. tostring(arity) .. "," .. tostring(name) .. ")")

-- Case 5: trailing comma (defensive — cpp normally rejects but fixture may have it)
setup_buf([[
void caller() {
  Foo(a, b,);
}
]])
vim.api.nvim_win_set_cursor(0, { 2, 4 })
arity = symbol.call_arity_at_cursor()
assert(arity == 2 or arity == 3, "case5 trailing comma should be tolerant, got " .. tostring(arity))

-- Case 6: 0-arg call
setup_buf("void caller() {\n  Foo();\n}\n")
vim.api.nvim_win_set_cursor(0, { 2, 4 })  -- on `Foo`
arity, name = symbol.call_arity_at_cursor()
assert(arity == 0, "case6 arity expected 0, got " .. tostring(arity))
assert(name == "Foo", "case6 name expected Foo, got " .. tostring(name))

-- Case 7: member call obj.Method
do
  local line = "struct S { void M(int,int); }; void f(){ S obj; obj.M(1,2); }"
  setup_buf(line)
  -- find the `M` of `obj.M(` (the call site, after `obj.`)
  local _, mcol = line:find("obj%.M")  -- mcol points at `M` (1-indexed)
  vim.api.nvim_win_set_cursor(0, { 1, mcol - 1 })
  arity, name = symbol.call_arity_at_cursor()
  assert(arity == 2, "case7 arity expected 2, got " .. tostring(arity))
  assert(name == "M", "case7 name expected M, got " .. tostring(name))
end

-- Case 8: pointer member call obj->Method
do
  local line = "struct S { void M(int); }; void f(){ S* p; p->M(7); }"
  setup_buf(line)
  local _, mcol = line:find("p%->M")
  vim.api.nvim_win_set_cursor(0, { 1, mcol - 1 })
  arity, name = symbol.call_arity_at_cursor()
  assert(arity == 1, "case8 arity expected 1, got " .. tostring(arity))
  assert(name == "M", "case8 name expected M, got " .. tostring(name))
end

-- Case 9: qualified call NS::Sub::Foo(a,b,c)
do
  local line = "namespace NS { namespace Sub { void Foo(int,int,int); } } void f(){ NS::Sub::Foo(1,2,3); }"
  setup_buf(line)
  -- rightmost `Foo` (at the call site)
  local _, fcol = line:find("Sub::Foo%(")
  -- fcol points at `(`; we want `Foo` which is 3 chars before
  vim.api.nvim_win_set_cursor(0, { 1, fcol - 1 - 3 })
  arity, name = symbol.call_arity_at_cursor()
  assert(arity == 3, "case9 arity expected 3, got " .. tostring(arity))
  assert(name == "Foo", "case9 name expected Foo, got " .. tostring(name))
end

-- Case 10: template call Foo<int>(a,b)
do
  local line = "template<class T> void Foo(T,T); void f(){ Foo<int>(1,2); }"
  setup_buf(line)
  -- the call-site `Foo` is after `f(){ `
  local fstart = line:find("Foo<int>%(")
  vim.api.nvim_win_set_cursor(0, { 1, fstart - 1 })
  arity, name = symbol.call_arity_at_cursor()
  assert(arity == 2, "case10 arity expected 2, got " .. tostring(arity))
  assert(name == "Foo", "case10 name expected Foo, got " .. tostring(name))
end

-- Case 11: innermost wins — cursor inside inner call argument
do
  setup_buf("void Inner(int,int); void Outer(int,int);\nvoid f(){ Outer(Inner(1,2), 3); }")
  local line2 = vim.api.nvim_buf_get_lines(0, 1, 2, false)[1]
  -- cursor on the `1` inside Inner(1,2)
  local onecol = line2:find("Inner%(1")
  -- onecol is start of `Inner`; `1` is 6 chars later (I-n-n-e-r-( )
  vim.api.nvim_win_set_cursor(0, { 2, onecol - 1 + 6 })
  arity, name = symbol.call_arity_at_cursor()
  assert(arity == 2, "case11 arity expected 2, got " .. tostring(arity))
  assert(name == "Inner", "case11 name expected Inner, got " .. tostring(name))
end

print("PASS test_call_arity (11 cases)")
