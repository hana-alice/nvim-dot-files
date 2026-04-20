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
