-- ue_goto.ranking — pure scoring + winner-pick on Location candidates.
--
-- Stateless. No vim.api except via location.lua. Used by provider.lua
-- to pick the instant-track winner from workspace/symbol results, and
-- by the precise track to rank textDocument/definition responses.

local location = require("utils.ue_goto.location")
local symbol = require("utils.ue_goto.symbol")

local M = {}

-- score_location_for_platform(loc, platform_hints, current_buf_path, receiver):
--   Composite ranking score. Higher = better candidate.
--
--   Inputs:
--     loc                — normalized Location (location.lua)
--     platform_hints     — {"vulkan","d3d12",...}; earlier = stronger boost
--     current_buf_path   — for same-module preference
--     receiver           — cword's receiver expression (symbol.current_receiver)
--                          enables container-name match for ws/symbol candidates
--                          carrying _ws_container.
function M.score_location_for_platform(loc, platform_hints, current_buf_path, receiver)
  local path = location.location_path(loc):lower()
  if path == "" then
    return -math.huge
  end

  local score = 0

  -- Receiver-aware container scoring (huge multiplier for the right one).
  -- ws/symbol attaches the symbol's container name as `_ws_container`. If the
  -- candidate's container shares meaningful substring with the call's
  -- receiver name, that's almost always the right method.
  if receiver and receiver ~= "" and loc._ws_container and loc._ws_container ~= "" then
    local recv_norm = symbol.normalize_class_name(receiver):lower()
    local cont_norm = symbol.normalize_class_name(loc._ws_container):lower()
    if recv_norm ~= "" and cont_norm ~= "" then
      -- Substring either way: container "naniterasterpipelines" contains
      -- receiver "rasterpipelines" (variable named after type) OR receiver
      -- "ctx" might be a typedef whose underlying type contains "ctx".
      if cont_norm:find(recv_norm, 1, true) or recv_norm:find(cont_norm, 1, true) then
        score = score + 1000
      end
    end
  end

  -- Strong preference: source files over headers (real implementation).
  if path:match("%.cpp$") or path:match("%.mm$") or path:match("%.cc$") then
    score = score + 500
  elseif path:match("%.inl$") or path:match("%.ipp$") then
    score = score + 200
  elseif path:match("%.h$") or path:match("%.hpp$") or path:match("%.hxx$") then
    score = score + 0
  end

  -- Penalize known wrappers / validation layers — they forward, they're not
  -- the actual implementation the user wants to read.
  if path:match("rhivalidation") then score = score - 800 end
  if path:match("rhi/public/dynamicrhi") then score = score - 400 end
  if path:match("/null") or path:match("nullrhi") then score = score - 600 end
  if path:match("/mock") or path:match("/stub") then score = score - 600 end

  -- Platform hint matching: earlier in the priority list = bigger boost.
  if platform_hints then
    for i, kw in ipairs(platform_hints) do
      if kw and kw ~= "" and path:find(kw:lower(), 1, true) then
        score = score + math.max(100, 1000 - (i - 1) * 100)
        break
      end
    end
  end

  -- Same-module preference: if the candidate lives in the same UE module
  -- directory as the current buffer (e.g. .../Renderer/...), nudge it.
  if current_buf_path and current_buf_path ~= "" then
    local cur_module = current_buf_path:lower():match("/source/[^/]+/([^/]+)/")
    local cand_module = path:match("/source/[^/]+/([^/]+)/")
    if cur_module and cand_module and cur_module == cand_module then
      score = score + 50
    end
  end

  return score
end

-- rerank_locations(locations, platform_hints, current_buf_path, receiver):
--   Sort by score descending. Stable for #<=1.
function M.rerank_locations(locations, platform_hints, current_buf_path, receiver)
  if not locations or #locations <= 1 then
    return locations
  end
  local scored = {}
  for _, loc in ipairs(locations) do
    table.insert(scored, {
      loc = loc,
      score = M.score_location_for_platform(loc, platform_hints, current_buf_path, receiver),
    })
  end
  table.sort(scored, function(a, b) return a.score > b.score end)
  local out = {}
  for _, e in ipairs(scored) do
    out[#out + 1] = e.loc
  end
  return out
end

-- A definition result is "thin" if every candidate is a .h file — likely a
-- forward/declaration/inline-trampoline, which means the user probably wants
-- the implementation (.cpp) instead. Used to decide whether to also query
-- textDocument/implementation and merge.
function M.is_thin_header_only(locations)
  if not locations or #locations == 0 then return false end
  for _, loc in ipairs(locations) do
    local p = location.location_path(loc):lower()
    if p:match("%.cpp$") or p:match("%.mm$") or p:match("%.cc$") then
      return false
    end
  end
  return true
end

-- clear_winner(scored_locations, platform_hints, current_buf_path, receiver):
--   Decide whether a top-1 candidate clearly wins. Strategy:
--     1. Single candidate: trivially the winner.
--     2. Margin >= 200: confident pick (e.g. .cpp def vs .h decl).
--     3. Header-only result set with <=4 candidates: accept top-1 anyway.
--        clangd workspace/symbol commonly returns only header decls (the
--        out-of-class .cpp def isn't indexed as a top-level symbol). Without
--        this relaxation we'd ambiguous-bail on `RasterPipelines.GetBinCount`
--        and force the user to wait 30s for the precise track.
function M.clear_winner(scored_locations, platform_hints, current_buf_path, receiver)
  if #scored_locations < 2 then return scored_locations[1] end
  local s1 = M.score_location_for_platform(scored_locations[1], platform_hints, current_buf_path, receiver)
  local s2 = M.score_location_for_platform(scored_locations[2], platform_hints, current_buf_path, receiver)
  if s1 - s2 >= 200 then return scored_locations[1] end
  if M.is_thin_header_only(scored_locations) and #scored_locations <= 4 then
    return scored_locations[1]
  end
  return nil
end

-- pick_winner_with_label(locs, platform_hints, ref_file, receiver):
--   Reranks, picks a clear winner, returns (winner_loc, label, ranked).
--   Returns (nil, nil, ranked) when no clear winner — caller populates
--   quickfix from ranked.
--   Returns (nil, nil, nil) when locs is empty.
function M.pick_winner_with_label(locs, platform_hints, ref_file, receiver)
  if not locs or #locs == 0 then return nil, nil, nil end
  local ranked = M.rerank_locations(locs, platform_hints, ref_file, receiver)
  local winner = M.clear_winner(ranked, platform_hints, ref_file, receiver)
  if not winner then return nil, nil, ranked end

  local p = location.location_path(winner)
  local short = (p ~= "" and (p:match("([^/\\]+)$") or p)) or "?"
  local lnum
  if winner.range and winner.range.start then
    lnum = winner.range.start.line + 1
  elseif winner.targetSelectionRange and winner.targetSelectionRange.start then
    lnum = winner.targetSelectionRange.start.line + 1
  end
  local label = lnum and string.format("%s:%d", short, lnum) or short
  return winner, label, ranked
end

return M
