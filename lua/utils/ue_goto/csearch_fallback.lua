-- utils/ue_goto/csearch_fallback.lua
-- ============================================================================
-- Last-resort definition lookup via Google codesearch (csearch) index.
--
-- Used as path-B step 3 (after cache miss + gtags miss) before giving up.
-- Asynchronous, never blocks the editor.
--
-- Strategy:
--   csearch is an identifier-only trigram index, so we cannot push fancy
--   regex into the index lookup itself — we issue a definition-shaped
--   regex via M.stream() and let the underlying csearch+rg pipeline filter
--   for us. The pattern matches typical C++/HLSL definition forms anchored
--   to start-of-line:
--
--     ^\s*(class|struct|enum)\s+SYM\b           -- class/struct/enum decl
--     ^\s*[~]?SYM\s*\(                          -- ctor/dtor / free fn
--     ^[\w\s*&:<>,]+\bSYM\s*\(                  -- method/free fn (typed)
--     ^\s*#\s*define\s+SYM\b                    -- macro
--
-- We keep this list small and *biased toward false-negatives over false-
-- positives*: a missed result drops us into "not found" notify(WARN), which
-- the user can recover from; a wrong jump destroys their flow.
--
-- Receiver disambiguation (when caller knows a class context):
--   When `receiver` is provided, results are scored: a line that contains
--   "receiver::" or whose surrounding 80-line window contains "class
--   receiver" / "struct receiver" gets +1 weight. Final pick = highest.
-- ============================================================================

local M = {}

local CSEARCH_TIMEOUT_MS = 4000   -- hard cap; if csearch hasn't returned
                                  -- by now, abort and return what we have.
local MAX_RESULTS        = 200    -- cap to keep ranking cheap.

local code_search = require("utils.code_search")

-- LSP location factory. Inline (no helper in location.lua) — encode the
-- forward-slashed file path as a file:// URI; line/col are 0-indexed in
-- LSP's range model.
local function make_location(file, lnum, col)
  local norm = file:gsub("\\", "/")
  -- vim.uri_from_fname expects native sep; pass the original.
  local uri = vim.uri_from_fname(file:gsub("/", "\\"))
  -- vim.uri_from_fname on linux gives file:///path; on Windows file:///D:/...
  -- Either way it's a valid LSP uri.
  local line0 = math.max(0, (lnum or 1) - 1)
  local col0  = math.max(0, (col  or 1) - 1)
  return {
    uri = uri,
    range = {
      start  = { line = line0, character = col0 },
      ["end"] = { line = line0, character = col0 + 1 },
    },
    -- keep the normalized path on the side for debugging; jumper ignores it
    _path = norm,
  }
end

-- Try to require ue.csearch_ctx; if ue.lua isn't loaded yet (e.g. very early
-- startup), bail safely.
local function get_ctx(bufnr)
  local ok, ue = pcall(require, "ue")
  if not ok or type(ue.csearch_ctx) ~= "function" then return nil end
  return ue.csearch_ctx(bufnr)
end

-- Build the RE2 OR-pattern. We escape `sym` minimally — symbol names that
-- contain regex meta would already be invalid C++ identifiers, but we still
-- guard against accidents from operator overload-style lookups someday.
local function escape_re(s)
  return (s:gsub("([%%%^%$%(%)%[%]%.%+%*%?%-])", "%%%1"))
    -- the gsub above uses Lua patterns; csearch wants RE2, so do a separate
    -- pass for chars that ARE regex meta in RE2 but not Lua patterns:
    :gsub("\\", "\\\\")
end

local function build_pattern(sym)
  local s = escape_re(sym)
  -- One alternation, anchored to start-of-line via ^ inside each branch.
  -- RE2 syntax: \b for word boundary, \s for whitespace, [...] for class.
  local branches = {
    [[^\s*(class|struct|enum)\s+]] .. s .. [[\b]],
    [[^\s*~?]] .. s .. [[\s*\(]],
    [[^[A-Za-z_][\w\s\*&:<>,]*\b]] .. s .. [[\s*\(]],
    [[^\s*#\s*define\s+]] .. s .. [[\b]],
  }
  return "(?m)" .. table.concat(branches, "|")
end

-- ---------------------------------------------------------------------------
-- Score a result against the optional receiver hint.
-- Higher score = more likely to be the right definition.
-- ---------------------------------------------------------------------------
local function score_result(file, lnum, text, sym, receiver)
  local score = 0
  -- Class/struct/enum declarations are usually what gd users want first.
  if text:match("^%s*class%s") or text:match("^%s*struct%s") or text:match("^%s*enum%s") then
    score = score + 3
  end
  -- Macro defines — weight a notch lower.
  if text:match("^%s*#%s*define%s") then
    score = score + 1
  end
  -- Receiver match in the matched line (e.g. "void FFoo::Bar(...)").
  if receiver and receiver ~= "" then
    local needle = receiver .. "::"
    if text:find(needle, 1, true) then
      score = score + 5
    end
    -- Light path heuristic: file basename containing receiver gets +1.
    local base = file:match("([^/\\]+)$") or ""
    if base:find(receiver, 1, true) then
      score = score + 1
    end
  end
  -- Header files tend to hold class declarations; cpp tends to hold method
  -- bodies. Without a receiver we mildly prefer headers (more likely to be
  -- THE definition rather than an out-of-line body). With a receiver we
  -- mildly prefer cpp (out-of-line method definition).
  local ext = file:match("%.([%w]+)$") or ""
  ext = ext:lower()
  if receiver and receiver ~= "" then
    if ext == "cpp" or ext == "cc" or ext == "cxx" then score = score + 1 end
  else
    if ext == "h" or ext == "hpp" or ext == "hh" then score = score + 1 end
  end
  return score
end

-- ---------------------------------------------------------------------------
-- Public entry: async lookup.
--
--   M.find(symbol, opts, callback)
--
-- opts (table):
--   bufnr     : buffer that triggered the lookup (used for project ctx)
--   receiver  : optional class/struct context for scoring
--   timeout_ms: override CSEARCH_TIMEOUT_MS
--
-- callback(locations, info)
--   locations : array of LSP-style { uri = ..., range = ... } sorted by
--               descending score; empty table on miss
--   info      : { count = N, indexed = bool, took_ms = N, capped = bool }
-- ---------------------------------------------------------------------------
function M.find(symbol, opts, callback)
  opts = opts or {}
  callback = callback or function() end
  if not symbol or symbol == "" then
    return vim.schedule(function() callback({}, { count = 0, reason = "empty_symbol" }) end)
  end
  local bufnr = opts.bufnr or 0
  local cs_ctx = get_ctx(bufnr)
  if not cs_ctx then
    return vim.schedule(function() callback({}, { count = 0, reason = "no_project_ctx" }) end)
  end

  local pattern = build_pattern(symbol)
  local indexed = code_search.is_indexed(cs_ctx)
  local hits = {}  -- { file, lnum, col, text, score }
  local capped = false
  local started = (vim.uv or vim.loop).hrtime()
  local finalized = false
  local stop_fn

  local function finalize(reason)
    if finalized then return end
    finalized = true
    if stop_fn then pcall(stop_fn) end
    -- Sort by score desc, then by file (stable for snapshot diffing in
    -- tests). Ties further broken by line ascending so the earliest
    -- declaration wins among equal-scored candidates.
    table.sort(hits, function(a, b)
      if a.score ~= b.score then return a.score > b.score end
      if a.file ~= b.file then return a.file < b.file end
      return a.lnum < b.lnum
    end)
    local locations = {}
    for _, h in ipairs(hits) do
      table.insert(locations, make_location(h.file, h.lnum, h.col or 1))
    end
    local took_ms = math.floor(((vim.uv or vim.loop).hrtime() - started) / 1e6)
    callback(locations, {
      count = #locations,
      indexed = indexed,
      took_ms = took_ms,
      capped = capped,
      reason = reason,
    })
  end

  stop_fn = code_search.stream(cs_ctx, pattern, {
    smart_case = false,
    code_only  = true,
    max_count  = MAX_RESULTS,
  }, {
    on_line = function(file, lnum, col, text)
      if #hits >= MAX_RESULTS then
        capped = true
        return
      end
      table.insert(hits, {
        file = file, lnum = lnum, col = col, text = text,
        score = score_result(file, lnum, text or "", symbol, opts.receiver),
      })
    end,
    on_done = function()
      finalize("done")
    end,
  })

  -- Hard timeout in case csearch hangs.
  local timer = (vim.uv or vim.loop).new_timer()
  timer:start(opts.timeout_ms or CSEARCH_TIMEOUT_MS, 0, vim.schedule_wrap(function()
    pcall(function() timer:stop(); timer:close() end)
    finalize("timeout")
  end))
end

-- For tests / dtrace
M._build_pattern = build_pattern
M._score_result  = score_result

return M
