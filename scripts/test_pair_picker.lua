-- Unit tests for utils.ue_goto.pair_picker.
-- Run: nvim --headless --cmd "lua vim.g.started_with_stdin=true" -c "luafile scripts/test_pair_picker.lua" -c qall!

local function P(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring(select(i, ...)) end
  io.write(table.concat(parts, " ") .. "\n"); io.flush()
end

vim.opt.swapfile = false
vim.opt.shada = ""
vim.opt.runtimepath:append(vim.fn.getcwd())

local pp = require("utils.ue_goto.pair_picker")

local function loc(uri, line)
  return { uri = uri, range = { start = { line = line or 0 } } }
end

local fail = 0
local function assert_pick(name, locations, want_uri, want_rule)
  local w, r = pp.pick_safe_winner(locations)
  local got_uri = w and w.uri or "nil"
  if got_uri == want_uri and r == want_rule then
    P(string.format("OK   %-32s → %s (%s)", name, want_uri:match("([^/]+)$"), r))
  else
    P(string.format("FAIL %-32s want=%s/%s got=%s/%s",
      name, want_uri, want_rule, got_uri, tostring(r)))
    fail = fail + 1
  end
end
local function assert_miss(name, locations, want_reason)
  local w, r = pp.pick_safe_winner(locations)
  if w == nil and r == want_reason then
    P(string.format("OK   %-32s → MISS (%s)", name, r))
  else
    P(string.format("FAIL %-32s want=miss/%s got=%s/%s",
      name, want_reason, w and w.uri or "nil", tostring(r)))
    fail = fail + 1
  end
end

P("=== pair_picker tests ===")

-- ---- Rule A: pair_h_cpp ----
assert_pick("nanite header+cpp pair",
  { loc("file:///c:/u/x/NaniteCullRaster.h", 196), loc("file:///c:/u/x/NaniteCullRaster.cpp", 6299) },
  "file:///c:/u/x/NaniteCullRaster.cpp", "pair_h_cpp")

assert_pick("order swap (cpp first)",
  { loc("file:///c:/u/x/NaniteCullRaster.cpp", 6299), loc("file:///c:/u/x/NaniteCullRaster.h", 196) },
  "file:///c:/u/x/NaniteCullRaster.cpp", "pair_h_cpp")

-- ---- Rule A miss: stem mismatch ----
assert_miss("two unrelated h+cpp (different stems)",
  { loc("file:///c:/u/x/Foo.h", 1), loc("file:///c:/u/x/Bar.cpp", 1) },
  "stem_mismatch")

-- ---- Rule B: sole_cpp among N>=2 ----
assert_pick("3 hdrs + 1 cpp",
  { loc("file:///c:/u/x/A.h", 1), loc("file:///c:/u/x/B.h", 1),
    loc("file:///c:/u/x/C.h", 1), loc("file:///c:/u/x/Z.cpp", 1) },
  "file:///c:/u/x/Z.cpp", "sole_cpp")

assert_pick("hpp + cpp (Hungarian)",
  { loc("file:///c:/u/x/Foo.hpp", 1), loc("file:///c:/u/x/Foo.cpp", 1) },
  "file:///c:/u/x/Foo.cpp", "pair_h_cpp")

-- ---- Misses: ambiguous ----
assert_miss("too_few (n=1)",
  { loc("file:///c:/u/x/A.cpp", 1) },
  "too_few")

assert_miss("two cpp (Win64 vs Mac)",
  { loc("file:///c:/u/Win64/A.cpp", 1), loc("file:///c:/u/Mac/A.cpp", 1) },
  "too_many_cpp")

assert_miss("all headers (template/inline)",
  { loc("file:///c:/u/x/A.h", 1), loc("file:///c:/u/x/B.h", 1) },
  "no_cpp")

assert_miss("has weird ext",
  { loc("file:///c:/u/x/A.h", 1), loc("file:///c:/u/x/B.cs", 1) },
  "has_other_ext")

-- ---- Edge: .inl treated as header ----
assert_pick("inl + cpp pair",
  { loc("file:///c:/u/x/Vec.inl", 1), loc("file:///c:/u/x/Vec.cpp", 1) },
  "file:///c:/u/x/Vec.cpp", "pair_h_cpp")

-- ---- Edge: nil/empty ----
assert_miss("nil input", nil, "too_few")
assert_miss("empty input", {}, "too_few")

P("")
if fail == 0 then
  P("=== ALL PASS (12 cases) ===")
  vim.cmd("qa!")
else
  P(string.format("=== FAIL %d cases ===", fail))
  vim.cmd("cq!")
end
