-- utils/ue_goto/pair_picker.lua
-- ============================================================================
-- Post-syntax-filter winner picker for the N>=2 case.
--
-- After syntax_filter narrows ws/symbol or textDocument/definition results
-- by call-arity, the survivors are typically:
--
--   2-element pair  =  one .h declaration + one .cpp out-of-class definition
--                      of the SAME symbol (most common UE case)
--   N-element set   =  >=2 .h decls (overrides across class hierarchy) +
--                      maybe one .cpp def
--
-- Heuristic ranking (.cpp boost) cannot SAFELY auto-pick the top one because
-- top-N may be unrelated overrides. But two structural patterns ARE safe to
-- auto-pick without semantic analysis:
--
--   Rule A (header+impl pair): N==2, one .h + one .cpp, same basename stem
--     (e.g. NaniteCullRaster.h + NaniteCullRaster.cpp). The user almost
--     always wants to land on the .cpp. False-positive cost is low (worst
--     case: lands on the right symbol's implementation).
--
--   Rule B (sole .cpp): N>=2, exactly one .cpp/.cc/.cxx, the rest are .h.
--     Same reasoning — header decls are forwarders, cpp is the real code.
--
-- Both rules return nil when their pattern doesn't match — caller falls back
-- to quickfix as before. The picker NEVER fabricates a wrong-symbol jump
-- because syntax_filter has already verified arity compatibility upstream.
--
-- Returns (winner_loc, rule_name) on hit, (nil, reason) on miss.
-- ============================================================================

local location_mod = require("utils.ue_goto.location")

local M = {}

-- Lowercase extension of a path. Returns "" if no extension.
local function ext_of(path)
  if not path then return "" end
  local e = path:match("%.([^.\\/]+)$")
  return e and e:lower() or ""
end

-- Basename without extension. "/x/y/Foo.cpp" → "Foo".
local function stem_of(path)
  if not path then return nil end
  local base = path:match("([^/\\]+)$") or path
  local stem = base:match("^(.+)%.[^.]+$") or base
  return stem
end

local CPP_EXTS = { cpp = true, cxx = true, cc = true, ["c++"] = true }
local HDR_EXTS = { h = true, hpp = true, hxx = true, ["h++"] = true, hh = true, inl = true }

local function is_cpp(path) return CPP_EXTS[ext_of(path)] == true end
local function is_hdr(path) return HDR_EXTS[ext_of(path)] == true end

-- Classify a location list by extension. Returns counts + buckets.
local function classify(locations)
  local cpps, hdrs, others = {}, {}, {}
  for _, loc in ipairs(locations) do
    local p = location_mod.location_path(loc) or ""
    if is_cpp(p) then
      table.insert(cpps, loc)
    elseif is_hdr(p) then
      table.insert(hdrs, loc)
    else
      table.insert(others, loc)
    end
  end
  return cpps, hdrs, others
end

-- Public API.
-- Args:
--   locations  : table of LSP Location-like records (after syntax_filter)
--   _opts      : reserved for future (e.g. trace fn). Currently unused.
-- Returns:
--   winner_loc, rule_name  on hit  (rule_name in {"pair_h_cpp", "sole_cpp"})
--   nil, reason            on miss (reason in {"too_few", "too_many_cpp",
--                                              "no_cpp", "stem_mismatch",
--                                              "has_other_ext"})
function M.pick_safe_winner(locations, _opts)
  if not locations or #locations < 2 then
    return nil, "too_few"
  end

  local cpps, hdrs, others = classify(locations)

  -- Disqualify if there are non-h/non-cpp survivors (.lua, .py, generated.cs
  -- — shouldn't happen but stay conservative).
  if #others > 0 then
    return nil, "has_other_ext"
  end

  -- ---- Rule A: exactly one .h and one .cpp, matching stems ----------------
  if #locations == 2 and #cpps == 1 and #hdrs == 1 then
    local cpp_stem = stem_of(location_mod.location_path(cpps[1]) or "")
    local hdr_stem = stem_of(location_mod.location_path(hdrs[1]) or "")
    if cpp_stem and hdr_stem and cpp_stem == hdr_stem then
      return cpps[1], "pair_h_cpp"
    end
    -- Stems differ: this is two unrelated symbols that happen to share a
    -- name. Fall through to quickfix — auto-jump would be wrong.
    return nil, "stem_mismatch"
  end

  -- ---- Rule B: exactly one .cpp among N>=2, rest are .h -------------------
  if #cpps == 1 and #hdrs == (#locations - 1) then
    return cpps[1], "sole_cpp"
  end

  -- Multiple .cpp survivors → ambiguous (e.g. Win64 vs Mac platform pair).
  -- Let ranking + quickfix handle that.
  if #cpps > 1 then
    return nil, "too_many_cpp"
  end

  -- All headers (no cpp at all): can't auto-pick safely. clangd may not
  -- have indexed the .cpp yet, or symbol is header-only (templates,
  -- inline). Surface to user as quickfix.
  return nil, "no_cpp"
end

-- Convenience for tests.
M._is_cpp = is_cpp
M._is_hdr = is_hdr
M._stem_of = stem_of
M._classify = classify

return M
