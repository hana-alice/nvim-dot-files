# Syntax-Driven Overload Disambiguation Implementation Plan

> **For Hermes:** Use subagent-driven-development skill to implement this plan task-by-task.

**Goal:** Replace heuristic ranking-based winner selection with treesitter call-arity filtering, so `gd` on `DrawGeometry(8 args)` deterministically picks the 8-parameter `FRenderer::DrawGeometry` overload instead of bailing or jumping to the wrong location.

**Architecture:** Insert a *syntax filter* layer between `workspace/symbol` results and the existing pick logic. The filter parses the cursor's `call_expression` for argument arity K, then for each candidate location parses its `function_declarator` for parameter arity P and default count D, keeping only candidates where `K ∈ [P-D, P]` (or P is variadic). When filter reduces N→1, jump immediately. When N→multi, dump to quickfix in the order produced by the demoted ranking heuristics (platform/wrapper/same-module). When N→0 (filter eliminated everything, likely non-call cursor or parse failure), fall through to the pre-filter list. Heuristic ranking survives only as a *quickfix sort* — never as a winner picker.

**Tech Stack:** Lua, Neovim 0.10+, nvim-treesitter (cpp parser), `vim.treesitter.get_string_parser` for off-buffer parsing, snacks.notify, vim.lsp.

**Background context (read first):**

- Trace from real failure: `<LOCAL_APPDATA>\Temp\nvim\ue_def_trace.log` lines 1-46
- Skill reference: `racing-goto-definition` (architectural pattern)
- Existing modules:
  - `lua/utils/lsp_fallback.lua` (orchestrator, ~567 lines)
  - `lua/utils/ue_goto/ranking.lua` (165 lines — most of this gets deleted)
  - `lua/utils/ue_goto/symbol.lua` (treesitter cpp parsing patterns to mimic)
  - `lua/utils/ue_goto/provider.lua` (`reconcile_landing_to_definition`, `is_thin_header_only` consumer)
  - `lua/utils/ue_goto/location.lua` (Location utility primitives)

---

## Task 0: Branch + baseline trace capture

**Objective:** Lock in pre-fix behavior so regressions are detectable.

**Files:**
- Branch: `git switch -c syntax-overload-filter` in `~/AppData/Local/nvim`
- Capture: `~/AppData/Local/nvim/docs/plans/baselines/2026-04-20-pre-filter-trace.log`

**Step 1: Create branch**

```bash
cd /mnt<LOCAL_APPDATA>/nvim
git status   # confirm clean working tree
git switch -c syntax-overload-filter
```

**Step 2: Snapshot the failing trace as baseline**

```bash
mkdir -p docs/plans/baselines
cp /mnt<LOCAL_APPDATA>/Temp/nvim/ue_def_trace.log \
   docs/plans/baselines/2026-04-20-pre-filter-trace.log
git add docs/plans/baselines/
git commit -m "docs: capture pre-fix gd DrawGeometry trace baseline"
```

**Step 3: Verify**

```bash
git log --oneline -1
# Expected: docs: capture pre-fix gd DrawGeometry trace baseline
```

---

## Task 1: Add `M.call_arity_at_cursor` to symbol.lua

**Objective:** Extract the argument count K of the `call_expression` enclosing cursor (or `nil` if cursor is not in a call).

**Files:**
- Modify: `lua/utils/ue_goto/symbol.lua` (append to module, before `return M`)
- Test: `scripts/test_call_arity.lua`

**Step 1: Write failing test**

Create `scripts/test_call_arity.lua`:

```lua
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

print("PASS test_call_arity (5 cases)")
```

**Step 2: Run test to verify failure**

```bash
"/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
  -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
  -c 'luafile C:\\Users\\<USER>\\AppData\\Local\\nvim\\scripts\\test_call_arity.lua' \
  -c 'qa!' 2>&1 | tail -20
```

Expected: error like `attempt to call a nil value (field 'call_arity_at_cursor')`.

**Step 3: Implement `M.call_arity_at_cursor`**

Append to `lua/utils/ue_goto/symbol.lua` before `return M`:

```lua
-- ---------------------------------------------------------------------------
-- Call-site arity (treesitter, cpp grammar)
--
-- Goal: tell syntax_filter.lua how many arguments the cursor's call
-- expression takes, so candidate function definitions with mismatched
-- parameter count can be eliminated.
--
-- Returns (arity:int, callee_name:string) when cursor sits inside an
-- enclosing call_expression (or template_function whose parent is a
-- call_expression). Returns nil when cursor is not in a call (e.g. on a
-- declaration name, in a type expression).
-- ---------------------------------------------------------------------------
function M.call_arity_at_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local ok_parser, parser = pcall(vim.treesitter.get_parser, bufnr, "cpp")
  if not ok_parser or not parser then return nil end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil end

  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  row = row - 1  -- TS is 0-indexed
  local node = trees[1]:root():descendant_for_range(row, col, row, col)
  if not node then return nil end

  -- Walk up to the nearest call_expression. Stop at function_definition
  -- (we do NOT want to accept a nested call from a sibling, only the one
  -- that lexically encloses cursor).
  local call = nil
  local n = node
  while n do
    local t = n:type()
    if t == "call_expression" then call = n; break end
    if t == "function_definition" or t == "function_declarator" then
      return nil  -- cursor is on a declaration site, not a call
    end
    n = n:parent()
  end
  if not call then return nil end

  -- Extract argument_list and count direct children that are not punctuation.
  local args_field = call:field("arguments")
  local arglist = args_field and args_field[1]
  if not arglist then
    -- Some grammars expose arguments as second child without the field.
    for c in call:iter_children() do
      if c:type() == "argument_list" then arglist = c; break end
    end
  end
  if not arglist then return nil end

  local arity = 0
  for c in arglist:iter_children() do
    local ct = c:type()
    -- Skip punctuation: `(`, `)`, `,`. Count everything else as one arg.
    if ct ~= "(" and ct ~= ")" and ct ~= "," and ct ~= "comment" then
      arity = arity + 1
    end
  end

  -- Extract callee name (best-effort: identifier, qualified_identifier,
  -- field_expression, template_function).
  local function leaf_name(callee_node)
    if not callee_node then return nil end
    local t = callee_node:type()
    if t == "identifier" or t == "field_identifier" or t == "type_identifier" then
      return vim.treesitter.get_node_text(callee_node, bufnr)
    elseif t == "qualified_identifier" then
      -- rightmost identifier
      local nf = callee_node:field("name")
      if nf and nf[1] then return leaf_name(nf[1]) end
    elseif t == "field_expression" then
      local fld = callee_node:field("field")
      if fld and fld[1] then return leaf_name(fld[1]) end
    elseif t == "template_function" then
      local nm = callee_node:field("name")
      if nm and nm[1] then return leaf_name(nm[1]) end
    end
    -- Fallback: text
    local txt = vim.treesitter.get_node_text(callee_node, bufnr) or ""
    return txt:match("([%w_]+)%s*$")
  end

  local fn_field = call:field("function")
  local fn_node = fn_field and fn_field[1]
  local name = leaf_name(fn_node)

  return arity, name
end
```

**Step 4: Run test to verify pass**

Same command as Step 2.

Expected: `PASS test_call_arity (5 cases)`.

**Step 5: Commit**

```bash
git add lua/utils/ue_goto/symbol.lua scripts/test_call_arity.lua
git commit -m "feat(ue_goto): symbol.call_arity_at_cursor — TS extract enclosing call arity"
```

---

## Task 2: Add `M.declarator_arity_at` helper for off-buffer parsing

**Objective:** Given a file path + line number pointing at (or near) a function declarator/definition, return `(formal_count, default_count, is_variadic)` by parsing that file with treesitter without forcing it open as a listed buffer.

**Files:**
- Modify: `lua/utils/ue_goto/symbol.lua`
- Test: `scripts/test_declarator_arity.lua`

**Step 1: Write failing test**

Create `scripts/test_declarator_arity.lua`:

```lua
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

print("PASS test_declarator_arity (6 cases)")
```

**Step 2: Run test to verify failure**

```bash
"/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
  -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
  -c 'luafile C:\\Users\\<USER>\\AppData\\Local\\nvim\\scripts\\test_declarator_arity.lua' \
  -c 'qa!' 2>&1 | tail -20
```

Expected: nil-call error.

**Step 3: Implement `M.declarator_arity_at`**

Append to `lua/utils/ue_goto/symbol.lua`:

```lua
-- ---------------------------------------------------------------------------
-- Off-buffer function-declarator arity probe.
--
-- Reads file from disk, parses with vim.treesitter.get_string_parser (no
-- buffer side effect), locates the nearest function_declarator at or
-- straddling line_1b, and returns (formal_count, default_count, is_variadic).
--
-- Returns nil on parse failure / file missing — caller should treat nil as
-- "unknown, do not filter this candidate out".
--
-- Tolerance: clangd's index line numbers can be off by ±1 vs source (newline
-- normalization, multi-line declarators). We search a ±3 line window for
-- the nearest function_declarator node.
-- ---------------------------------------------------------------------------
function M.declarator_arity_at(path, line_1b)
  if not path or path == "" then return nil end
  local f = io.open(path, "rb")
  if not f then return nil end
  local content = f:read("*a"); f:close()
  if not content or content == "" then return nil end

  local ok_p, parser = pcall(vim.treesitter.get_string_parser, content, "cpp")
  if not ok_p or not parser then return nil end
  local trees = parser:parse()
  if not trees or not trees[1] then return nil end
  local root = trees[1]:root()

  local target_row = (line_1b or 1) - 1
  local LO = math.max(0, target_row - 3)
  local HI = target_row + 3

  -- Find the function_declarator whose start_row falls within [LO, HI],
  -- preferring the one closest to target_row.
  local best_decl = nil
  local best_dist = math.huge

  local function walk(node)
    local sr = node:start()
    local er = node:end_()
    if er < LO or sr > HI then
      -- entirely outside window — recurse only if node spans across (could contain a hit)
      if sr <= HI and er >= LO then
        for c in node:iter_children() do walk(c) end
      end
      return
    end
    local t = node:type()
    if t == "function_declarator" then
      local d = math.abs(sr - target_row)
      if d < best_dist then best_dist = d; best_decl = node end
    end
    for c in node:iter_children() do walk(c) end
  end
  walk(root)
  if not best_decl then return nil end

  -- parameters field
  local pf = best_decl:field("parameters")
  local plist = pf and pf[1]
  if not plist then
    for c in best_decl:iter_children() do
      if c:type() == "parameter_list" then plist = c; break end
    end
  end
  if not plist then return 0, 0, false end

  local count = 0
  local defaults = 0
  local variadic = false

  for c in plist:iter_children() do
    local t = c:type()
    if t == "parameter_declaration" or t == "optional_parameter_declaration" then
      count = count + 1
      if t == "optional_parameter_declaration" then defaults = defaults + 1 end
    elseif t == "variadic_parameter_declaration" or t == "..." then
      variadic = true
    end
  end

  return count, defaults, variadic
end
```

**Step 4: Run test to verify pass**

Same command as Step 2.

Expected: `PASS test_declarator_arity (6 cases)`.

**Step 5: Commit**

```bash
git add lua/utils/ue_goto/symbol.lua scripts/test_declarator_arity.lua
git commit -m "feat(ue_goto): symbol.declarator_arity_at — off-buffer TS parameter count"
```

---

## Task 3: Create `syntax_filter.lua` module

**Objective:** Glue Tasks 1+2 together as a single `M.filter_by_call_signature(locations, bufnr, dtrace) -> filtered_locations, info`. Conservative: any failure preserves the candidate (no false eliminations).

**Files:**
- Create: `lua/utils/ue_goto/syntax_filter.lua`
- Test: `scripts/test_syntax_filter.lua`

**Step 1: Write failing test**

Create `scripts/test_syntax_filter.lua`:

```lua
local symbol = require("utils.ue_goto.symbol")
local sf = require("utils.ue_goto.syntax_filter")
local TMPDIR = "C:/temp/ue_goto_test"
vim.fn.mkdir(TMPDIR, "p")

-- Build the DrawGeometry case as fixtures
local cpp_path = TMPDIR .. "/NaniteCullRaster.cpp"
local h_path = TMPDIR .. "/NaniteCullRaster.h"
local cpp_lines = {}
for i = 1, 6256 do cpp_lines[i] = "// pad " .. i end
cpp_lines[6257] = "void FRenderer::DrawGeometry(int a, int b, int c, int d, int e) {"
cpp_lines[6258] = "  call_into_8_arg_overload();"
cpp_lines[6259] = "}"
cpp_lines[6300] = "void FRenderer::DrawGeometry(int a, int b, int c, int d, int e, int f, int g, int h) {"
cpp_lines[6301] = "}"
local f = io.open(cpp_path, "w"); f:write(table.concat(cpp_lines, "\n")); f:close()

local h_lines = {}
for i = 1, 240 do h_lines[i] = "// pad " .. i end
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
  loc(h_path, 241),  -- 8-arg .h decl (also a match!)
  loc(cpp_path, 6257),  -- 5-arg .cpp def
  loc(cpp_path, 6300),  -- 8-arg .cpp def — primary target
}

local function dtrace(fmt, ...) print("[trace] " .. string.format(fmt, ...)) end
local filtered, info = sf.filter_by_call_signature(candidates, vim.api.nvim_get_current_buf(), dtrace)

-- Expected: 5-arg candidates eliminated, 8-arg candidates kept (h:241, cpp:6300)
assert(#filtered == 2, "expected 2 survivors, got " .. #filtered)
local got_lines = {}
for _, l in ipairs(filtered) do
  table.insert(got_lines, vim.uri_to_fname(l.uri):match("[^/\\]+$") .. ":" .. (l.range.start.line + 1))
end
table.sort(got_lines)
local expected = { "NaniteCullRaster.cpp:6300", "NaniteCullRaster.h:241" }
table.sort(expected)
assert(got_lines[1] == expected[1] and got_lines[2] == expected[2],
  "got " .. table.concat(got_lines, ",") .. " expected " .. table.concat(expected, ","))

assert(info.applied == true, "info.applied expected true")
assert(info.call_arity == 8, "info.call_arity expected 8, got " .. tostring(info.call_arity))
assert(info.before == 7 and info.after == 2, "info before/after wrong")

-- Negative case: cursor not in a call
vim.api.nvim_win_set_cursor(0, { 1, 0 })
local filtered2, info2 = sf.filter_by_call_signature(candidates, vim.api.nvim_get_current_buf(), dtrace)
assert(#filtered2 == #candidates, "no-call cursor should pass-through, got " .. #filtered2)
assert(info2.applied == false, "info.applied expected false on pass-through")

print("PASS test_syntax_filter (DrawGeometry 7→2 + pass-through)")
```

**Step 2: Run test to verify failure**

```bash
"/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
  -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
  -c 'luafile C:\\Users\\<USER>\\AppData\\Local\\nvim\\scripts\\test_syntax_filter.lua' \
  -c 'qa!' 2>&1 | tail -20
```

Expected: `module 'utils.ue_goto.syntax_filter' not found`.

**Step 3: Implement `syntax_filter.lua`**

Create `lua/utils/ue_goto/syntax_filter.lua`:

```lua
-- ue_goto.syntax_filter — drop ws/symbol candidates that cannot match the
-- cursor's call signature.
--
-- This is the deterministic, syntax-driven replacement for
-- ranking.clear_winner's "guess by score margin" logic. Overload resolution
-- is a syntactic question (call arity vs. parameter arity); ranking is left
-- only as a quickfix-sort tiebreaker for the few candidates surviving the
-- filter.

local symbol = require("utils.ue_goto.symbol")
local location = require("utils.ue_goto.location")

local M = {}

-- Returns true if a candidate with arity (P, D, variadic) can plausibly
-- accept K arguments. Conservative: when any field is nil/unknown, accept.
local function arity_compatible(K, P, D, variadic)
  if K == nil then return true end           -- caller arity unknown — never reject
  if P == nil then return true end           -- candidate arity unknown — never reject
  if variadic then return K >= P end         -- variadic accepts at-least-P
  local minP = P - (D or 0)
  return K >= minP and K <= P
end

-- filter_by_call_signature(locations, bufnr, dtrace?)
--   locations : array of normalized Location candidates (from ws/symbol)
--   bufnr     : the buffer cursor lives in
--   dtrace    : optional log callback (printf-style)
--
-- Returns (filtered_locations, info_table).
--
-- info_table = {
--   applied    = bool,    -- true if filter ran (cursor was in a call_expression)
--   call_arity = int|nil, -- the K it computed
--   callee     = string|nil,
--   before     = int,
--   after      = int,
--   skipped    = int,     -- how many candidates we couldn't probe (kept anyway)
-- }
--
-- Contract: NEVER returns an empty list when input was non-empty unless
-- filter eliminated by-confident-mismatch. If parsing the cursor fails or
-- arity is unknowable, returns the input unchanged with applied=false.
function M.filter_by_call_signature(locations, bufnr, dtrace)
  local info = { applied = false, call_arity = nil, callee = nil,
                 before = locations and #locations or 0, after = 0, skipped = 0 }
  if not locations or #locations == 0 then
    info.after = 0; return locations or {}, info
  end

  -- Activate cursor's buffer for AST parse if needed.
  local prev_buf = vim.api.nvim_get_current_buf()
  if bufnr and bufnr ~= prev_buf then
    -- We don't switch buffers — the cursor API needs the actual current buffer.
    -- Caller (M.definition) already runs in the user's current buffer.
  end

  local K, callee = symbol.call_arity_at_cursor()
  if K == nil then
    info.after = #locations
    if dtrace then pcall(dtrace, "syntax_filter: cursor not in call_expression — pass-through (n=%d)", #locations) end
    return locations, info
  end
  info.applied = true
  info.call_arity = K
  info.callee = callee

  if dtrace then pcall(dtrace, "syntax_filter: K=%d callee=%q candidates=%d", K, tostring(callee), #locations) end

  local out = {}
  for i, loc in ipairs(locations) do
    local path = location.location_path(loc)
    local line = location.location_line(loc)
    local P, D, V = symbol.declarator_arity_at(path, line)
    if P == nil then
      info.skipped = info.skipped + 1
      out[#out + 1] = loc  -- conservative keep
      if dtrace then pcall(dtrace, "syntax_filter: cand[%d] %s:%d → unknown (kept)", i, vim.fn.fnamemodify(path, ":t"), line) end
    elseif arity_compatible(K, P, D, V) then
      out[#out + 1] = loc
      if dtrace then pcall(dtrace, "syntax_filter: cand[%d] %s:%d → P=%d D=%d V=%s KEEP", i, vim.fn.fnamemodify(path, ":t"), line, P, D or 0, tostring(V)) end
    else
      if dtrace then pcall(dtrace, "syntax_filter: cand[%d] %s:%d → P=%d D=%d V=%s DROP (K=%d)", i, vim.fn.fnamemodify(path, ":t"), line, P, D or 0, tostring(V), K) end
    end
  end

  -- Safety: if filter eliminated everything (should be rare — usually means
  -- arity is unknowable for all candidates), fall back to original list to
  -- avoid breaking gd entirely.
  if #out == 0 then
    if dtrace then pcall(dtrace, "syntax_filter: ALL eliminated → fallback to unfiltered (%d)", #locations) end
    info.after = #locations
    return locations, info
  end

  info.after = #out
  return out, info
end

return M
```

**Step 4: Run test to verify pass**

Same command as Step 2.

Expected: `PASS test_syntax_filter (DrawGeometry 7→2 + pass-through)`.

**Step 5: Commit**

```bash
git add lua/utils/ue_goto/syntax_filter.lua scripts/test_syntax_filter.lua
git commit -m "feat(ue_goto): syntax_filter — TS-driven overload disambiguation"
```

---

## Task 4: Demote `ranking.lua` to quickfix-sort only

**Objective:** Strip `clear_winner` and `pick_winner_with_label` from ranking.lua. Keep `score_location_for_platform` and `rerank_locations` as quickfix-sort utilities. Keep `is_thin_header_only` (provider.lua needs it).

**Files:**
- Modify: `lua/utils/ue_goto/ranking.lua`
- Test: `scripts/test_ranking_sort.lua`

**Step 1: Write failing test for the new sort-only API**

Create `scripts/test_ranking_sort.lua`:

```lua
local ranking = require("utils.ue_goto.ranking")

-- score_location_for_platform / rerank_locations / is_thin_header_only must remain.
assert(type(ranking.score_location_for_platform) == "function", "score_location_for_platform missing")
assert(type(ranking.rerank_locations) == "function", "rerank_locations missing")
assert(type(ranking.is_thin_header_only) == "function", "is_thin_header_only missing")

-- clear_winner and pick_winner_with_label must be GONE.
assert(ranking.clear_winner == nil, "clear_winner should be removed")
assert(ranking.pick_winner_with_label == nil, "pick_winner_with_label should be removed")

-- Sort should put .cpp before .h
local locs = {
  { uri = "file:///proj/A.h", range = { start = { line = 0 } } },
  { uri = "file:///proj/A.cpp", range = { start = { line = 0 } } },
}
local sorted = ranking.rerank_locations(locs, {}, "/proj/B.cpp", "")
assert(sorted[1].uri:match("%.cpp$"), "expected .cpp first, got " .. sorted[1].uri)

print("PASS test_ranking_sort")
```

**Step 2: Run test to verify failure**

```bash
"/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
  -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
  -c 'luafile C:\\Users\\<USER>\\AppData\\Local\\nvim\\scripts\\test_ranking_sort.lua' \
  -c 'qa!' 2>&1 | tail -10
```

Expected: `clear_winner should be removed` (assertion fails because functions still exist).

**Step 3: Edit `ranking.lua`**

Patch out `clear_winner` and `pick_winner_with_label` from the existing file. Update the module header comment from "score / pick_winner" to "score / sort (quickfix-only)".

```lua
-- ue_goto.ranking — pure scoring + sort utilities for quickfix display.
--
-- Stateless. NOTE (2026-04): the winner-pick functions (clear_winner /
-- pick_winner_with_label) have been REMOVED. Overload disambiguation now
-- lives in syntax_filter.lua (treesitter-driven). Ranking survives only
-- as a tiebreaker that orders the quickfix list when multiple candidates
-- pass the syntax filter.
```

Delete:
- `M.clear_winner` (lines ~131-140)
- `M.pick_winner_with_label` (lines ~147-163)

Keep:
- `M.score_location_for_platform`
- `M.rerank_locations`
- `M.is_thin_header_only`

**Step 4: Run test to verify pass**

Same command as Step 2.

Expected: `PASS test_ranking_sort`.

**Step 5: Commit**

```bash
git add lua/utils/ue_goto/ranking.lua scripts/test_ranking_sort.lua
git commit -m "refactor(ue_goto): demote ranking to quickfix-sort, remove winner-pick"
```

---

## Task 5: Rewire `M.definition()` instant track

**Objective:** Replace the ranking-based instant winner with: `ws/symbol → filter_self → syntax_filter → (1 → jump | N → quickfix sorted by ranking | 0 → defer to precise)`.

**Files:**
- Modify: `lua/utils/ue_goto/lsp_fallback.lua` (the `M.definition` function — the instant track block around line 328-380)

**Step 1: Read the current instant block**

```bash
# already reviewed in plan prep — lines 328-380 are the instant track.
```

**Step 2: Replace the instant block**

In `lua/utils/lsp_fallback.lua`, locate the require block at top and add:

```lua
local syntax_filter = require("utils.ue_goto.syntax_filter")
```

Replace the instant track (the block starting `-- ---- Track 1: instant via workspace/symbol --------` through the matching closing `end`):

```lua
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
        -- Multiple candidates pass the syntax filter — show quickfix
        -- sorted by ranking heuristics. Do NOT auto-pick.
        local sorted = ranking.rerank_locations(filtered, platform_hints, ref_file, receiver)
        if not jumped then
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
```

**Step 3: Verify lsp_fallback.lua syntax**

```bash
"/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
  -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
  -c 'lua local ok, err = pcall(loadfile, vim.fn.expand("~/AppData/Local/nvim/lua/utils/lsp_fallback.lua")); if not ok then print("LOAD ERR: " .. tostring(err)) else print("LOAD OK") end' \
  -c 'qa!' 2>&1 | tail -5
```

Expected: `LOAD OK`.

**Step 4: Commit**

```bash
git add lua/utils/lsp_fallback.lua
git commit -m "feat(ue_goto): instant track uses syntax_filter, ranking is sort-only"
```

---

## Task 6: Rewire `M.definition()` precise track

**Objective:** Same syntax_filter pass on `textDocument/definition` results. `>1` survivor → quickfix; `==1` → jump.

**Files:**
- Modify: `lua/utils/ue_goto/lsp_fallback.lua` (precise track block, ~line 382-461)

**Step 1: Replace the precise block**

Locate the precise track block (`-- ---- Track 2: precise via textDocument/definition` through the closing `end)` of `def_plus_impl`'s callback). Replace with:

```lua
  -- ---- Track 2: precise via textDocument/definition (+impl/+decl) --------
  if has_def_client then
    dtrace("precise: dispatching textDocument/definition")
    provider.async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, function(locs)
      dtrace("precise: back n=%d still=%s jumped=%s",
        locs and #locs or 0, tostring(still_current()), tostring(jumped))
      if not still_current() then
        clear_notice()
        return
      end

      if locs and #locs > 0 then
        local filtered, fi = syntax_filter.filter_by_call_signature(locs, bufnr, dtrace)
        dtrace("precise: syntax_filter applied=%s K=%s before=%d after=%d skipped=%d",
          tostring(fi.applied), tostring(fi.call_arity), fi.before, fi.after, fi.skipped)

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
    -- (unchanged ws_client-only branch from current code)
  end
end
```

**Step 2: Update `self_test`**

The `M.self_test` (around line 102-129) calls `ranking.pick_winner_with_label` which we deleted. Replace with a syntax_filter smoke test:

```lua
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
end
```

**Step 3: Verify load**

```bash
"/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
  -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
  -c 'lua require("utils.lsp_fallback")' \
  -c 'lua require("utils.lsp_fallback").self_test()' \
  -c 'qa!' 2>&1 | tail -10
```

Expected:
```
=== UEDefSelfTest  module_rev=tier2split
syntax_filter module: LOADED ✓
ranking.clear_winner removed: true
result: PASS ✓
```

**Step 4: Bump MODULE_REVISION**

So the live RPC verification step (Task 8) can confirm the new bytecode loaded:

```lua
local MODULE_REVISION = "syntax-filter-v1"
```

**Step 5: Commit**

```bash
git add lua/utils/lsp_fallback.lua
git commit -m "feat(ue_goto): precise track uses syntax_filter, MODULE_REVISION=syntax-filter-v1"
```

---

## Task 7: Tier 3 — `reconcile_landing_to_definition` returns false on hard miss

**Objective:** When precise's location lands on a line that has no `sym` token AND the search window finds no def-pattern, return false. Caller (`jump_to_location`) refuses to leave cursor at the bogus line.

**Files:**
- Modify: `lua/utils/ue_goto/provider.lua` (`reconcile_landing_to_definition`)
- Modify: `lua/utils/lsp_fallback.lua` (`jump_to_location` wrapper around line 139-162)

**Step 1: Change reconcile return contract**

In `provider.lua`, modify `reconcile_landing_to_definition` to return:
- `true`  — landing is OK (token found on landing line, OR a nearby def-pattern was found and cursor was repositioned)
- `false` — bogus location (no token, no def-pattern in window) — caller should NOT keep cursor here

Currently the function does `vim.api.nvim_win_set_cursor(0, { best_line, ... })` when it finds a pattern, and silently returns when it doesn't. Change tail to:

```lua
  -- If we get here, no def-pattern found in either window.
  if dtrace then pcall(dtrace, "reconcile: HARD-MISS sym=%q landed=%d (no token, no pattern)", sym, landed_line_1b) end
  return false
end
```

And `return true` at every successful exit (token-on-line + post-reposition success).

**Step 2: Have `jump_to_location` honor the result**

In `lsp_fallback.lua`, the wrapper around line 139-162 currently calls reconcile and ignores result. Change to:

```lua
local function jump_to_location(location)
  if not location then return false end

  jumper._on_reassert = function(reason, prev_cur, ln, cc)
    pcall(dtrace, "jump: shada-race reassert (%s) %d:%d -> %d:%d",
      tostring(reason), prev_cur[1], prev_cur[2], ln, cc)
  end

  -- Save pre-jump state in case reconcile rejects this location.
  local pre_buf = vim.api.nvim_get_current_buf()
  local pre_cur = vim.api.nvim_win_get_cursor(0)

  local ok = jumper.jump(location)
  if not ok then return false end

  local sym = location._sym_name or location._origin_cword
  local reconcile_ok = true  -- assume OK if no sym to verify
  if sym and #sym > 0 then
    local range = location.range or location.targetSelectionRange or location.targetRange
    local line_1b = ((range and range.start and range.start.line) or 0) + 1
    local rok, rresult = pcall(provider.reconcile_landing_to_definition, sym, line_1b, dtrace)
    if rok and rresult == false then
      reconcile_ok = false
    end
  end

  if not reconcile_ok then
    -- Bogus precise location. Restore caller cursor + tell caller we failed
    -- so they can show quickfix instead of leaving user at the wrong place.
    pcall(dtrace, "jump: REJECTED bogus location, restoring cursor to %d:%d", pre_cur[1], pre_cur[2])
    pcall(vim.api.nvim_set_current_buf, pre_buf)
    pcall(vim.api.nvim_win_set_cursor, 0, pre_cur)
    return false
  end

  local cur = vim.api.nvim_win_get_cursor(0)
  pcall(dtrace, "jump: done cursor=%d:%d sym=%s", cur[1], cur[2], tostring(sym))
  return true
end
```

**Step 3: Verify**

```bash
"/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
  -c 'set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim' \
  -c 'lua require("utils.lsp_fallback")' \
  -c 'qa!' 2>&1 | tail -5
```

Expected: clean exit, no errors.

**Step 4: Commit**

```bash
git add lua/utils/ue_goto/provider.lua lua/utils/lsp_fallback.lua
git commit -m "feat(ue_goto): Tier3 — reconcile rejects bogus precise locations"
```

---

## Task 8: Live RPC verification on the user's running Neovim

**Objective:** Reproduce the original `gd DrawGeometry @ 6290` and confirm:

(a) `MODULE_REVISION = syntax-filter-v1` loaded
(b) trace contains `syntax_filter: ... before=7 after=N` where N ≤ 2
(c) cursor lands at NaniteCullRaster.cpp:6300 within ~300ms (instant) OR shows a 2-candidate quickfix

**Files:**
- Create: `scripts/verify_drawgeometry_live.ps1`

**Step 1: Find live nvim pipe**

```bash
pwsh.exe -NoProfile -Command '[System.IO.Directory]::GetFiles("\\\\.\\pipe\\","nvim*")'
```

Expected: one or more `\\.\pipe\nvim.<PID>.0` lines. Pick the one matching the user's editing session.

**Step 2: Drive the test via headless RPC**

Create `scripts/verify_drawgeometry_live.ps1`:

```powershell
param([Parameter(Mandatory)][string]$Pipe)

$nvim = "C:\Program Files\Neovim\bin\nvim.exe"
$config = "<LOCAL_APPDATA>\nvim"

# Use a headless nvim as RPC client to talk to the live one.
$lua = @"
local ch = vim.fn.sockconnect('pipe', [[$Pipe]], { rpc = true })

-- Force-reload the module so the live nvim picks up new code.
vim.rpcrequest(ch, 'nvim_exec_lua', [[
  for k in pairs(package.loaded) do
    if k:match('^utils%.ue_goto') or k == 'utils.lsp_fallback' then
      package.loaded[k] = nil
    end
  end
  require('utils.lsp_fallback')
  return require('utils.lsp_fallback').MODULE_REVISION
]], {})

-- Drive gd
vim.rpcrequest(ch, 'nvim_exec_lua', [[
  vim.cmd('edit <PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteCullRaster.cpp')
  vim.api.nvim_win_set_cursor(0, { 6290, 4 })
  require('utils.lsp_fallback').definition()
]], {})

vim.wait(8000)

-- Read back the trace tail
local tail = vim.rpcrequest(ch, 'nvim_exec_lua', [[
  local p = vim.fn.stdpath('cache') .. '/ue_def_trace.log'
  local f = io.open(p, 'r')
  if not f then return 'NO TRACE FILE' end
  local content = f:read('*a'); f:close()
  -- Last 60 lines
  local lines = vim.split(content, '\n')
  local tail = {}
  for i = math.max(1, #lines - 60), #lines do tail[#tail+1] = lines[i] end
  return table.concat(tail, '\n')
]], {})

print(tail)
print(string.format('cursor: %s', vim.inspect(vim.rpcrequest(ch, 'nvim_get_current_line', {}))))
"@

$tmpfile = [IO.Path]::GetTempFileName() + ".lua"
[IO.File]::WriteAllText($tmpfile, $lua)
& $nvim --headless --noplugin -u NONE `
  -c "set rtp+=$config" `
  -c "luafile $tmpfile" `
  -c "qa!" 2>&1
Remove-Item $tmpfile
```

**Step 3: Run verification**

```bash
PIPE=$(pwsh.exe -NoProfile -Command '[System.IO.Directory]::GetFiles("\\\\.\\pipe\\","nvim*")' | head -1 | tr -d '\r')
pwsh.exe -NoProfile -File C:\\Users\\<USER>\\AppData\\Local\\nvim\\scripts\\verify_drawgeometry_live.ps1 -Pipe $PIPE
```

**Expected output (success criteria):**

```
[HH:MM:SS #N] M.definition() called sym="DrawGeometry" recv="" file=NaniteCullRaster.cpp:6290
[HH:MM:SS #N] instant: dispatching ws/symbol q="DrawGeometry"
[HH:MM:SS #N] precise: dispatching textDocument/definition
[HH:MM:SS #N] instant: ws/symbol back n=7 ...
[HH:MM:SS #N] instant: after filter_self n=7
[HH:MM:SS #N] instant: cand[1..7] ...
[HH:MM:SS #N] syntax_filter: K=8 callee="DrawGeometry" candidates=7
[HH:MM:SS #N] syntax_filter: cand[1] NaniteCullRaster.h:196 → P=5 D=0 V=false DROP (K=8)
... (5-arg .h decls all DROP)
[HH:MM:SS #N] syntax_filter: cand[6] NaniteCullRaster.cpp:6256 → P=5 D=0 V=false DROP (K=8)
[HH:MM:SS #N] syntax_filter: cand[7] NaniteCullRaster.cpp:6299 → P=8 D=0 V=false KEEP
[HH:MM:SS #N] instant: syntax_filter applied=true K=8 before=7 after=1 skipped=0
[HH:MM:SS #N] instant: jump pok=true ok=true label=NaniteCullRaster.cpp:6300
```

And `cursor` line should be `void FRenderer::DrawGeometry(`.

**Step 4: If verification fails, dump full trace and triage**

```bash
cat /mnt<LOCAL_APPDATA>/Temp/nvim/ue_def_trace.log
```

Common failure → fix:
- `MODULE_REVISION` still old → reload didn't take, restart nvim
- `syntax_filter: K=nil` → call_arity_at_cursor returned nil; check cursor col was on the identifier
- `K=8 ... after=0 → fallback` → arity_compatible is wrong, check default/variadic logic
- `precise: REJECTED bogus location` for the SceneCullingRenderer.h:79 case → Tier 3 working ✓

**Step 5: Save the verification trace**

```bash
cp /mnt<LOCAL_APPDATA>/Temp/nvim/ue_def_trace.log \
   /mnt<LOCAL_APPDATA>/nvim/docs/plans/baselines/2026-04-20-post-filter-trace.log
git add docs/plans/baselines/2026-04-20-post-filter-trace.log scripts/verify_drawgeometry_live.ps1
git commit -m "docs: capture post-fix gd DrawGeometry verification trace"
```

---

## Task 9: Update racing-goto-definition skill

**Objective:** Document the syntax_filter as the new authoritative overload-disambiguation path; mark heuristic ranking as deprecated for winner selection.

**Files:**
- Modify: `<LOCAL_APPDATA>\hermes\skills\software-development\racing-goto-definition\SKILL.md`

**Step 1: Add new pitfall (after pitfall #11)**

```markdown
### 12. heuristic ranking can't disambiguate same-file overloads

Symptom: `gd` on a function call where the same .cpp defines multiple
overloads (e.g. UE renderer `DrawGeometry` with both 5-param and 8-param
overloads at lines 6257 and 6300 of NaniteCullRaster.cpp). Both .cpp
candidates score identically (.cpp boost + same-module bonus apply
equally), `clear_winner` margin check returns nil, instant bails. Precise
then takes 30s and clangd often gives a wildly wrong answer (e.g. some
unrelated `FSceneInstanceCullingQuery` class in a totally different
header) on huge TUs where AST is incomplete.

Root cause: ranking is the wrong layer. C++ overload resolution is
syntactic, not heuristic — the call's argument count uniquely identifies
which overload matches.

Fix: Insert a treesitter-driven syntax_filter layer between ws/symbol
results and the winner-pick logic. For each candidate, parse its
function_declarator and extract `(P, D, variadic)`; keep only candidates
where call arity K satisfies `K ∈ [P-D, P]` or P is variadic. After
filter:
  - 1 survivor → jump
  - N>1 survivors → quickfix (sorted by retained ranking heuristics)
  - 0 survivors → fallback to unfiltered (parse failure case)

Demote ranking to quickfix-sort only. Delete `clear_winner` /
`pick_winner_with_label`. Reference implementation:
`lua/utils/ue_goto/syntax_filter.lua` in
`<LOCAL_APPDATA>\nvim`.
```

**Step 2: Commit**

```bash
cd <LOCAL_APPDATA>\hermes\skills\software-development\racing-goto-definition
git add SKILL.md  # if hermes skills are git-tracked, otherwise just save
```

---

## Task 10: Sync cheatsheet & UX notes

**Objective:** Update both cheatsheets so the user knows `gd` may now show a quickfix when the syntax filter leaves multiple candidates.

**Files:**
- Modify: `~/.config/nvim/cheatsheet.md` (or wherever the user's two cheatsheets live)
- Search first: `search_files("cheatsheet", target="files", path="/mnt<LOCAL_APPDATA>/nvim")`

**Step 1: Locate cheatsheets**

```bash
search_files target=files pattern=cheatsheet path=/mnt<LOCAL_APPDATA>/nvim
```

**Step 2: Add a line under the gd entry**

```markdown
- `gd` — goto definition. Uses syntax_filter to pick the correct overload
  based on call argument count. When multiple overloads remain after
  filter (or when cursor isn't in a call), shows quickfix sorted by
  platform/wrapper/module heuristics. Spinner notice tag:
  ⚡ instant·syntax / ✓ precise·syntax indicates filter ran.
```

**Step 3: Commit**

```bash
cd ~/.config/nvim   # or actual path
git add docs/cheatsheet*.md
git commit -m "docs: cheatsheet — note syntax_filter behavior for gd"
```

---

## Task 11: Final review + merge prep

**Objective:** Squash review, run all tests one last time, prep for merge to main.

**Step 1: Run all tests**

```bash
cd /mnt<LOCAL_APPDATA>/nvim
for t in test_call_arity test_declarator_arity test_syntax_filter test_ranking_sort; do
  echo "=== $t ==="
  "/mnt/c/Program Files/Neovim/bin/nvim.exe" --headless --noplugin -u NONE \
    -c "set rtp+=C:\\Users\\<USER>\\AppData\\Local\\nvim" \
    -c "luafile C:\\Users\\<USER>\\AppData\\Local\\nvim\\scripts\\$t.lua" \
    -c "qa!" 2>&1 | tail -3
done
```

Expected: 4 × `PASS test_*`.

**Step 2: Diff summary**

```bash
git log --oneline main..HEAD
git diff --stat main..HEAD
```

**Step 3: Show user the diff before merge** (per CLAUDE.md / user preference)

```bash
git diff main..HEAD lua/utils/lsp_fallback.lua | head -200
git diff main..HEAD lua/utils/ue_goto/ranking.lua
git diff main..HEAD lua/utils/ue_goto/syntax_filter.lua | head -200
```

**Step 4: After user approval, merge to main**

```bash
git switch main
git merge --no-ff syntax-overload-filter -m "feat(ue_goto): TS-driven overload disambiguation"
```

**Step 5: Trigger live module reload notification to user**

`vim.notify("✓ syntax_filter merged. Reload nvim or :Lazy reload utils.lsp_fallback", vim.log.levels.INFO, { timeout = 8000 })`

---

## Verification Matrix

| Scenario | Expected behavior |
|---|---|
| `gd DrawGeometry @ 6290` (8 args) | ⚡ jump to 6300 (instant, 1 survivor) |
| `gd DrawGeometry @ 6258` (5 args) | ⚡ jump to 6257 (instant, 1 survivor) — but already at def, `is_at_definition_at_cursor` early-bails |
| `gd Foo @ NoDecl.h` (cursor on class name) | syntax_filter pass-through (not a call) → ranking sorts → quickfix or top-1 jump |
| `gd Logf("%s", x)` (variadic) | Variadic candidates (P-1 + variadic) ALL keep (K ≥ P-1) |
| `gd DrawGeometry()` with default args | Default-param candidates keep when K ∈ [P-D, P] |
| `gd FooTemplate<T>::Bar` (dependent name) | `is_dependent_at_cursor` early-bails — syntax_filter never runs ✓ |
| `gd OutOfClassMethod` from another module | filter_self_locations excludes self; syntax_filter on remaining; ranking sorts qf |
| Precise gives bogus `SceneCullingRenderer.h:79` | reconcile returns false → jump_to_location restores cursor → quickfix shown ✓ |

---

## Out of Scope (deliberately deferred)

- Full overload resolution (template argument deduction, SFINAE, ADL): too expensive without a real C++ frontend
- Receiver-type checking (`obj.method` where `obj` has known type): would require hooking into clangd's type info; current `_ws_container` substring match in ranking is left intact
- Removing `is_thin_header_only` from provider.lua: it's a query-routing decision (do we also ask `textDocument/implementation`?), not a winner-pick — stays
- Tier 4 spinner UX update ("⏳ instant done, waiting precise"): nice-to-have, separate plan

---

## Rollback

If verification fails catastrophically:

```bash
git switch main
git branch -D syntax-overload-filter
# Or if already merged:
git revert -m 1 HEAD
```

The architectural risk surface is small — syntax_filter is a pure addition that returns the input unchanged on any parse failure, so the worst-case regression is "behaves like before".
