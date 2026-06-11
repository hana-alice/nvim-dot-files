-- tests/cases/ue_goto_behavior_spec.lua
-- utils.ue_goto 的纯函数行为（排序 / 配对 / 去重）。
-- 复刻自 scripts/test_ranking_sort.lua 与 test_pair_picker.lua 中
-- 不依赖 clangd 的输入→输出断言。

local t = require("tests.harness")
t.bootstrap()

local function loc(uri, line)
  return { uri = uri, range = { start = { line = line or 0 } } }
end

t.describe("ranking: rerank_locations 把 .cpp 排在 .h 前", function()
  local ranking = require("utils.ue_goto.ranking")
  t.it(".cpp 优先", function()
    local locs = {
      loc("file:///proj/A.h", 0),
      loc("file:///proj/A.cpp", 0),
    }
    local sorted = ranking.rerank_locations(locs, {}, "/proj/B.cpp", "")
    t.assert_match(sorted[1].uri, "%.cpp$")
  end)
  t.it("关键函数仍存在", function()
    t.assert_type(ranking.score_location_for_platform, "function")
    t.assert_type(ranking.is_thin_header_only, "function")
  end)
end)

t.describe("pair_picker: pick_safe_winner", function()
  local pp = require("utils.ue_goto.pair_picker")

  t.it("header+cpp 配对 → 该 cpp (pair_h_cpp)", function()
    local w, r = pp.pick_safe_winner({
      loc("file:///c:/u/x/Nanite.h", 196),
      loc("file:///c:/u/x/Nanite.cpp", 6299),
    })
    t.assert_true(w ~= nil, "应选出 winner")
    t.assert_match(w.uri, "Nanite%.cpp$")
    t.assert_eq(r, "pair_h_cpp")
  end)

  t.it("两个无关文件 → MISS (stem_mismatch)", function()
    local w, r = pp.pick_safe_winner({
      loc("file:///c:/u/x/Foo.h", 1),
      loc("file:///c:/u/x/Bar.cpp", 1),
    })
    t.assert_nil(w)
    t.assert_eq(r, "stem_mismatch")
  end)

  t.it("单个文件 → MISS (too_few)", function()
    local w, r = pp.pick_safe_winner({ loc("file:///c:/u/x/A.cpp", 1) })
    t.assert_nil(w)
    t.assert_eq(r, "too_few")
  end)
end)

t.describe("location: dedup_locations 去重", function()
  local location = require("utils.ue_goto.location")
  t.it("重复 location 被去除", function()
    local input = {
      loc("file:///proj/A.cpp", 10),
      loc("file:///proj/A.cpp", 10),
      loc("file:///proj/B.cpp", 20),
    }
    local out = location.dedup_locations(input)
    t.assert_true(#out <= 2, "期望 <=2 条，实际 " .. #out)
  end)
end)
