-- LSP definition/references with GTAGS fallback.
-- Correctness-first design notes:
--   * Position params are computed PER CLIENT using that client's
--     offset_encoding (clangd is utf-16; mixing encodings silently
--     produces wrong positions on lines with multibyte chars).
--   * Async definition uses a request token so a stale callback from a
--     previous gd can never override a fresher one.
--   * filter_self_locations returns {} (not the original list) when
--     filtering removes everything; lets the next fallback step run
--     instead of jumping to the same line silently.
--   * try_jump treats a successful LSP result as terminal even if the
--     URI cannot be opened — we notify rather than fall through to
--     GTAGS which would jump to an unrelated symbol.
--   * gd is fully non-blocking. The main loop never waits on rg/global.
--     LSP and GTAGS race in parallel; LSP wins if it answers within
--     LSP_PRIMARY_WINDOW_MS, otherwise GTAGS jumps when ready.
--   * When LSP returns empty (preamble still building), we retry
--     LSP_RETRY_COUNT times with LSP_RETRY_INTERVAL_MS spacing before
--     accepting "no LSP result". Critical for cold clangd on UE.

local M = {}

-- ---------------------------------------------------------------------------
-- Tunables
-- ---------------------------------------------------------------------------
-- After this many ms with no LSP answer, surface a "still working" notice.
local LSP_PROGRESS_NOTICE_MS = 600
-- Hard cap: if LSP+GTAGS still nothing after this, declare failure.
-- Big TUs (e.g. NaniteCullRaster.cpp) can take 30-60s to build a fresh
-- preamble + AST after first edit; we'd rather wait than wrong-jump.
local OVERALL_TIMEOUT_MS = 30000
-- Empty-result retries (clangd preamble building).
local LSP_RETRY_COUNT = 20
local LSP_RETRY_INTERVAL_MS = 2000
-- Update the progress notice on every retry so the user sees forward motion.
local PROGRESS_TICK_INTERVAL_MS = LSP_RETRY_INTERVAL_MS

-- Instant path config ---------------------------------------------------
-- The instant path uses workspace/symbol (no AST required). If it returns
-- a single high-confidence match within INSTANT_DEADLINE_MS, we jump
-- immediately and skip the AST-bound path.
local INSTANT_DEADLINE_MS = 400      -- give ws/symbol up to 400ms before
                                     -- letting precise path take over UI
local INSTANT_MAX_CANDIDATES = 50    -- if more than this match by name,
                                     -- bail (almost certainly the wrong
                                     -- query, e.g. cursor on `int`)
-- When set, after instant jump we still run the precise path; if it
-- returns a different location we surface a small notice.
local INSTANT_PRECISE_RECONCILE = true

-- ---------------------------------------------------------------------------
-- Symbol / position helpers
-- ---------------------------------------------------------------------------

local function current_symbol()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return nil
  end
  return word
end

-- current_receiver():
--   For an expression like `RasterPipelines.GetBinCount(...)` or
--   `Ctx->GetBinCount(...)` with cursor on `GetBinCount`, return the
--   receiver identifier ("RasterPipelines" / "Ctx").
--
--   Used to disambiguate ws/symbol candidates that share the same method
--   name but live on different classes — we score candidates whose
--   container name overlaps the receiver name.
--
--   Returns "" if no clear receiver could be identified (free function,
--   start-of-line, after `::`, etc.).
local function current_receiver()
  local ok, line = pcall(vim.api.nvim_get_current_line)
  if not ok or not line or line == "" then return "" end
  local _, col = unpack(vim.api.nvim_win_get_cursor(0))
  -- walk left from the byte BEFORE the current word to find `.` / `->` / `::`
  -- skip over the cword first
  local i = col
  -- go past identifier chars under and after cursor (cword may be multi-byte
  -- but UE is ASCII identifiers in practice)
  while i > 0 and line:sub(i, i):match("[%w_]") do i = i - 1 end
  -- now line:sub(i,i) is the byte immediately before the identifier
  local prev = line:sub(i, i)
  if prev == "." then
    -- "<receiver>.cword"
    local j = i - 1
    while j > 0 and line:sub(j, j):match("[%w_]") do j = j - 1 end
    return line:sub(j + 1, i - 1)
  elseif prev == ">" and line:sub(i - 1, i - 1) == "-" then
    -- "<receiver>->cword"
    local j = i - 2
    while j > 0 and line:sub(j, j):match("[%w_]") do j = j - 1 end
    return line:sub(j + 1, i - 2)
  elseif prev == ":" and line:sub(i - 1, i - 1) == ":" then
    -- "<Class>::cword" — receiver is the class itself
    local j = i - 2
    while j > 0 and line:sub(j, j):match("[%w_]") do j = j - 1 end
    return line:sub(j + 1, i - 2)
  end
  return ""
end

-- normalize_class_name(name):
--   Strip UE/Hungarian-style class prefix so that "FNaniteRasterPipelines"
--   matches receiver "RasterPipelines" via simple substring containment.
--   Strips: F (struct), U (UObject), A (AActor), T (template), I (interface),
--   E (enum), S (Slate), G (global). Never strips if the result would be
--   empty or start with a lowercase letter (i.e. "Foo" → "oo" is wrong).
local function normalize_class_name(name)
  if not name or name == "" then return "" end
  local first = name:sub(1, 1)
  local rest = name:sub(2)
  if first:match("[FUATIESG]") and rest:sub(1, 1):match("[A-Z]") then
    return rest
  end
  return name
end

local function normalize_locations(result, position_encoding)
  if type(result) ~= "table" then
    return {}
  end

  local locations = {}
  local items = vim.islist(result) and result or { result }
  for _, location in ipairs(items) do
    if type(location) == "table" and (location.uri or location.targetUri) then
      local copy = vim.deepcopy(location)
      copy._position_encoding = position_encoding
      locations[#locations + 1] = copy
    end
  end
  return locations
end

local function normalize_path(path)
  path = tostring(path or ""):gsub("\\", "/")
  path = path:gsub("/+$", "")
  return path
end

local function location_path(location)
  local uri = location and (location.uri or location.targetUri)
  if not uri or uri == "" then
    return ""
  end
  return normalize_path(vim.uri_to_fname(uri))
end

local function location_line(location)
  local range = location and (location.targetSelectionRange or location.targetRange or location.range)
  local start = range and range.start or nil
  return start and (tonumber(start.line) or 0) + 1 or 0
end

local function location_key(location)
  local range = location and (location.targetSelectionRange or location.targetRange or location.range)
  local s = range and range.start or nil
  local line = s and tonumber(s.line) or 0
  local col = s and tonumber(s.character) or 0
  return string.format("%s:%d:%d", location_path(location), line, col)
end

local function dedup_locations(locations)
  if not locations or #locations <= 1 then
    return locations
  end
  local seen = {}
  local out = {}
  for _, loc in ipairs(locations) do
    local key = location_key(loc)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = loc
    end
  end
  return out
end

local function locations_to_items_grouped(locations)
  local by_enc = {}
  for _, loc in ipairs(locations or {}) do
    local enc = loc._position_encoding or "utf-16"
    by_enc[enc] = by_enc[enc] or {}
    table.insert(by_enc[enc], loc)
  end
  local items = {}
  for enc, group in pairs(by_enc) do
    local converted = vim.lsp.util.locations_to_items(group, enc)
    if converted and #converted > 0 then
      vim.list_extend(items, converted)
    end
  end
  return items
end

local function populate_quickfix(title, locations)
  local items = locations_to_items_grouped(locations)
  if not items or vim.tbl_isempty(items) then
    return false
  end
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("botright copen 10")
  return true
end

local function reconcile_landing_to_definition(sym, landed_line_1b)
  -- Verify cursor's landing line actually mentions the symbol. If not, the
  -- background-index gave us a stale line number — search the buffer for a
  -- real definition pattern near the landing point and silently reposition.
  if not sym or sym == "" then return end

  local bufnr = vim.api.nvim_get_current_buf()
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  if line_count == 0 then return end

  local cur_line_text = vim.api.nvim_buf_get_lines(
    bufnr, landed_line_1b - 1, landed_line_1b, false)[1] or ""

  -- Lua patterns can't do \b — fake word-boundary by checking neighbors.
  local function has_token(s, tok)
    if not s or s == "" then return false end
    local idx = 1
    while true do
      local a, b = s:find(tok, idx, true)
      if not a then return false end
      local before = (a > 1) and s:sub(a - 1, a - 1) or ""
      local after = s:sub(b + 1, b + 1)
      local function is_id_ch(c)
        return c ~= "" and c:match("[%w_]") ~= nil
      end
      if not is_id_ch(before) and not is_id_ch(after) then
        return true
      end
      idx = b + 1
    end
  end

  -- If the landing line literally contains the symbol token, trust it.
  if has_token(cur_line_text, sym) then return end

  -- Stale: search a window around the landing line for a definition site.
  -- Window grows in stages so we prefer near hits over far ones.
  local function escape_for_pattern(s)
    return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
  end
  local sym_pat = escape_for_pattern(sym)

  -- Definition-shaped patterns (ordered by specificity / likelihood).
  local def_patterns = {
    "class%s+" .. sym_pat .. "[%s:{<]",   -- class Foo : / { / <
    "class%s+" .. sym_pat .. "$",          -- class Foo (eol)
    "struct%s+" .. sym_pat .. "[%s:{<]",
    "struct%s+" .. sym_pat .. "$",
    "using%s+" .. sym_pat .. "%s*=",       -- using Foo =
    "typedef%s+.*%s" .. sym_pat .. "%s*;", -- typedef X Foo;
    "enum%s+class%s+" .. sym_pat,
    "enum%s+" .. sym_pat,
    "namespace%s+" .. sym_pat,
    "%f[%w_]" .. sym_pat .. "%s*::%s*" .. sym_pat .. "%s*%(", -- Foo::Foo(
  }

  -- Stage 1: ±200 line window. Stage 2: whole file fallback.
  local windows = {
    { math.max(1, landed_line_1b - 200), math.min(line_count, landed_line_1b + 200) },
    { 1, line_count },
  }

  local best_line = nil
  local best_dist = math.huge
  for _, win in ipairs(windows) do
    local lo, hi = win[1], win[2]
    local lines = vim.api.nvim_buf_get_lines(bufnr, lo - 1, hi, false)
    for i, text in ipairs(lines) do
      for _, pat in ipairs(def_patterns) do
        if text:find(pat) then
          local lineno = lo + i - 1
          local dist = math.abs(lineno - landed_line_1b)
          if dist < best_dist then
            best_dist = dist
            best_line = lineno
          end
          break
        end
      end
    end
    if best_line then break end -- found in narrow window, don't widen
  end

  if not best_line or best_line == landed_line_1b then
    if M._dtrace then pcall(M._dtrace, "reconcile: no def-pattern found for %q near line %d", sym, landed_line_1b) end
    return
  end

  -- Find column of symbol on the chosen line for a precise cursor.
  local target_text = vim.api.nvim_buf_get_lines(
    bufnr, best_line - 1, best_line, false)[1] or ""
  local col = 0
  local s = target_text:find(sym, 1, true)
  if s then col = s - 1 end

  pcall(vim.api.nvim_win_set_cursor, 0, { best_line, col })
  if M._dtrace then pcall(M._dtrace, "reconcile: %q drift %d -> %d (Δ=%d)", sym, landed_line_1b, best_line, best_line - landed_line_1b) end
end

local function jump_to_location(location)
  local uri = location.uri or location.targetUri
  local range = location.range or location.targetSelectionRange or location.targetRange
  if not uri or not range or not range.start then
    return false
  end

  local target_path = vim.uri_to_fname(uri)
  local bufnr = vim.fn.bufnr(target_path)
  if bufnr == -1 or not vim.api.nvim_buf_is_loaded(bufnr) then
    -- silent so it doesn't print "X lines" mid-callback
    local ok = pcall(vim.cmd, "silent! edit " .. vim.fn.fnameescape(target_path))
    if not ok then return false end
    bufnr = vim.fn.bufnr(target_path)
  end

  -- Push current cursor onto jumplist BEFORE switching buffer
  vim.cmd("normal! m'")

  -- We DO NOT use vim.lsp.util.show_document here. It has two failure modes
  -- on Windows + ws/symbol-synthesized locations:
  --   1. _position_encoding is unset on synthetic ws/symbol locations (we
  --      build them by hand from SymbolInformation). show_document falls
  --      back to utf-16 even when clangd is utf-8 → off-by-N column or
  --      a refusal to set cursor on what it thinks is an out-of-range pos.
  --   2. With reuse_win=true and BufReadCmd autocommands, the cursor set
  --      can race the BufRead and end up at line 1 col 0 (the user reports
  --      "jumped to top of file" on FDataDrivenShaderPlatformInfo).
  --
  -- Instead: switch to target buffer in the current window directly, then
  -- nvim_win_set_cursor with a clamped position. clangd's columns are 0-
  -- indexed UTF-16 codepoint offsets, but for the all-ASCII identifiers
  -- that gd lands on, that's identical to byte columns — and we clamp to
  -- line length so we never set an out-of-range cursor.
  if bufnr ~= -1 and vim.api.nvim_get_current_buf() ~= bufnr then
    vim.api.nvim_set_current_buf(bufnr)
  end

  local line_1b = (range.start.line or 0) + 1
  local line_count = vim.api.nvim_buf_line_count(0)
  if line_1b > line_count then line_1b = line_count end
  if line_1b < 1 then line_1b = 1 end

  local line_text = vim.api.nvim_buf_get_lines(0, line_1b - 1, line_1b, false)[1] or ""
  local col = range.start.character or 0
  if col > #line_text then col = #line_text end
  if col < 0 then col = 0 end

  -- Two-phase cursor set: synchronous now (so synchronous code observes the
  -- target line) AND deferred via vim.defer_fn (so any BufRead / FileType /
  -- LspAttach / treesitter-on-load autocmds — many of which reset cursor to
  -- line 1 by calling things like `keepjumps normal! 1G` or restoring '"'
  -- mark to (1,0) when the buffer was never visited — can't strand us at
  -- top-of-file). The deferred re-set only fires if cursor was reset; we
  -- never override a user-moved cursor.
  local function apply_cursor_if_stranded(target_buf)
    -- Only fix if we're still in the target buffer and cursor was reset.
    if vim.api.nvim_get_current_buf() ~= target_buf then return end
    local cur = vim.api.nvim_win_get_cursor(0)
    -- "Stranded" means cursor sits at (1, 0..1) — classic BufRead reset.
    -- If user moved deliberately we leave them alone.
    if cur[1] ~= 1 or cur[2] > 1 then return end
    -- Re-clamp in case the buffer mutated.
    local lc = vim.api.nvim_buf_line_count(0)
    local ln = math.min(math.max(line_1b, 1), lc)
    local lt = vim.api.nvim_buf_get_lines(0, ln - 1, ln, false)[1] or ""
    local cc = math.min(math.max(col, 0), #lt)
    pcall(vim.api.nvim_win_set_cursor, 0, { ln, cc })
    pcall(vim.cmd, "normal! zz")
    if M._dtrace then pcall(M._dtrace, "jump: deferred un-strand to %d:%d", ln, cc) end
  end

  local ok_cur = pcall(vim.api.nvim_win_set_cursor, 0, { line_1b, col })
  if not ok_cur then
    -- final safety net: try the original show_document path (best effort)
    pcall(vim.lsp.util.show_document, location,
      location._position_encoding or "utf-16",
      { reuse_win = true, focus = true })
  end

  -- Defer second cursor set (only if cursor was stranded). 30ms catches
  -- BufRead/FileType chains; 150ms catches slower late autocmds (treesitter
  -- region attach, LspAttach handlers, etc.). Both bail if user moved.
  local target_buf = vim.api.nvim_get_current_buf()
  vim.defer_fn(function() apply_cursor_if_stranded(target_buf) end, 30)
  vim.defer_fn(function()
    apply_cursor_if_stranded(target_buf)
    -- reconcile only if we're still in the target buf and at our line
    if vim.api.nvim_get_current_buf() ~= target_buf then return end
    local cur = vim.api.nvim_win_get_cursor(0)
    -- Run reconcile only if we ARE at the intended line (not user-moved).
    if cur[1] == line_1b then
      local sym = location._sym_name or location._origin_cword
      if sym and #sym > 0 then
        pcall(reconcile_landing_to_definition, sym, line_1b)
      end
    end
  end, 150)

  -- Reconcile against stale background-index line numbers. clangd's
  -- workspace/symbol returns positions from its persistent index, which lags
  -- behind file edits — symbols can drift dozens of lines. Verify that the
  -- landing line actually contains the symbol token; if not, search nearby
  -- for a definition pattern and silently reposition.
  -- Symbol comes from the location (ws/symbol path) or, for precise/definition
  -- locations that don't carry it, we fall back to the original cword captured
  -- before the jump (set on the location by the caller as _origin_cword).
  local sym = location._sym_name or location._origin_cword
  if sym and #sym > 0 then
    pcall(reconcile_landing_to_definition, sym, line_1b)
  end

  -- Center the new position so the user sees context
  pcall(vim.cmd, "normal! zz")
  return true
end

local function filter_self_locations(locations, ref_file, ref_line)
  if not locations or #locations == 0 then
    return locations
  end
  ref_file = ref_file or normalize_path(vim.api.nvim_buf_get_name(0))
  ref_line = ref_line or vim.api.nvim_win_get_cursor(0)[1]

  local filtered = {}
  for _, location in ipairs(locations) do
    if location_path(location) ~= ref_file or location_line(location) ~= ref_line then
      filtered[#filtered + 1] = location
    end
  end
  return filtered
end

-- ---------------------------------------------------------------------------
-- Sync helpers (used by references)
-- ---------------------------------------------------------------------------

local function sync_locations(method, timeout_ms)
  local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
  if not clients or vim.tbl_isempty(clients) then
    return nil, 0
  end

  local all = {}
  local errors = 0
  local timed_out = false
  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local params = vim.lsp.util.make_position_params(0, enc)
    if method == "textDocument/references" then
      params.context = { includeDeclaration = true }
    end
    local ok, response = pcall(function()
      return client:request_sync(method, params, timeout_ms or 5000, 0)
    end)
    if not ok or response == nil then
      timed_out = true
    elseif response.err then
      errors = errors + 1
    elseif response.result and type(response.result) == "table" then
      vim.list_extend(all, normalize_locations(response.result, enc))
    end
  end
  return dedup_locations(all), errors, timed_out
end

-- ---------------------------------------------------------------------------
-- Async LSP request
-- ---------------------------------------------------------------------------

local request_token = 0

-- Fire one LSP request round across all clients. Calls on_result(locations)
-- exactly once on the main thread. locations is nil iff every client failed
-- or returned no result.
local function async_lsp_request(bufnr, method, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  if not clients or vim.tbl_isempty(clients) then
    vim.schedule(function() on_result(nil) end)
    return
  end

  local pending = #clients
  local all_items = {}
  local done = false

  local function finish()
    if done then return end
    done = true
    vim.schedule(function()
      on_result(#all_items > 0 and all_items or nil)
    end)
  end

  local function dec_pending()
    pending = pending - 1
    if pending <= 0 then finish() end
  end

  for _, client in ipairs(clients) do
    local enc = client.offset_encoding or "utf-16"
    local ok_make, params = pcall(vim.lsp.util.make_position_params, 0, enc)
    if not ok_make or not params then
      dec_pending()
    else
      local ok_req = pcall(function()
        client:request(method, params, function(err, result)
          if not err and result and type(result) == "table" then
            vim.list_extend(all_items, normalize_locations(result, enc))
          end
          dec_pending()
        end, bufnr)
      end)
      if not ok_req then
        dec_pending()
      end
    end
  end
end

-- ---------------------------------------------------------------------------
-- Location ranking helpers (used by async_lsp_definition_with_retry below
-- and by M.definition's rerank). Defined here so they're visible to the
-- async retry logic which decides whether to also query implementation.
-- ---------------------------------------------------------------------------

-- Path-based ranking for "go to implementation" candidates. We trust LSP for
-- semantic correctness (it gave us the right symbol's overrides), but among
-- multiple overrides we want the one matching the current target platform —
-- e.g. RHICreateShaderBundle on Win64 should land in D3D12RHI, not the base
-- virtual declaration in DynamicRHI.h.
local function score_location_for_platform(loc, platform_hints, current_buf_path, receiver)
  local path = location_path(loc):lower()
  if path == "" then
    return -math.huge
  end

  local score = 0

  -- Receiver-aware container scoring (huge multiplier for the right one).
  -- ws/symbol attaches the symbol's container name as `_ws_container`. If the
  -- candidate's container shares meaningful substring with the call's
  -- receiver name, that's almost always the right method.
  if receiver and receiver ~= "" and loc._ws_container and loc._ws_container ~= "" then
    local recv_norm = normalize_class_name(receiver):lower()
    local cont_norm = normalize_class_name(loc._ws_container):lower()
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

local function rerank_locations(locations, platform_hints, current_buf_path, receiver)
  if not locations or #locations <= 1 then
    return locations
  end
  local scored = {}
  for _, loc in ipairs(locations) do
    table.insert(scored, {
      loc = loc,
      score = score_location_for_platform(loc, platform_hints, current_buf_path, receiver),
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
-- the implementation (.cpp) instead. We use this to decide whether to also
-- query textDocument/implementation and merge.
local function is_thin_header_only(locations)
  if not locations or #locations == 0 then return false end
  for _, loc in ipairs(locations) do
    local p = location_path(loc):lower()
    if p:match("%.cpp$") or p:match("%.mm$") or p:match("%.cc$") then
      return false
    end
  end
  return true
end

-- Decide whether a top-1 candidate clearly wins. If yes, jump directly even
-- when there are multiple results.
--
-- Strategy (conservative → aggressive):
--   1. Single candidate: trivially the winner.
--   2. Margin >= 200: confident pick (e.g. .cpp def vs .h decl).
--   3. Header-only result set: clangd workspace/symbol commonly only
--      returns headers (kind=Method on the declaration), not the .cpp
--      out-of-class definition. In that case ranks by same-module / platform
--      collapse to <200 margin and we'd ambiguous-bail. But the user is
--      almost always served better by jumping to top-1 and letting precise
--      reconcile if needed — much better than waiting 30s for AST.
--      So when ALL candidates are headers, we accept the top-1 even with
--      a small margin, as long as the top-1 has a score > 0 (i.e. matched
--      *something* — same module, platform hint, etc.) OR there are only
--      2 candidates (decl+sibling-decl, common for overloaded methods).
local function clear_winner(scored_locations, platform_hints, current_buf_path, receiver)
  if #scored_locations < 2 then return scored_locations[1] end
  local s1 = score_location_for_platform(scored_locations[1], platform_hints, current_buf_path, receiver)
  local s2 = score_location_for_platform(scored_locations[2], platform_hints, current_buf_path, receiver)
  if s1 - s2 >= 200 then return scored_locations[1] end
  -- Header-only relaxation: if no .cpp/.cc/.mm in the result set, the top-1
  -- header is already as good as the instant path can do; jumping there is
  -- strictly better than the 30s precise-track wait. Precise reconcile will
  -- fix it later if it disagrees.
  if is_thin_header_only(scored_locations) and #scored_locations <= 4 then
    return scored_locations[1]
  end
  return nil
end

-- ---------------------------------------------------------------------------
-- workspace/symbol path: AST-free, fast, fuzzy. We filter to exact name
-- match because gd semantics require it.
-- ---------------------------------------------------------------------------

-- SymbolInformation.kind values we want for goto-definition.
-- Filter out things like Module/File/Namespace which can't be a "definition".
local DEFINITION_KINDS = {
  [5] = true,   -- Class
  [6] = true,   -- Method
  [7] = true,   -- Property
  [8] = true,   -- Field
  [9] = true,   -- Constructor
  [10] = true,  -- Enum
  [11] = true,  -- Interface
  [12] = true,  -- Function
  [13] = true,  -- Variable
  [14] = true,  -- Constant
  [22] = true,  -- Struct
  [23] = true,  -- Event
  [24] = true,  -- Operator
  [25] = true,  -- TypeParameter
}

-- async_lsp_workspace_symbol(bufnr, query, exact, on_result):
--   Sends workspace/symbol to all clients on bufnr.
--   Calls on_result(locations|nil) once when all clients have replied
--   (or after 5s, whichever first).
--   When `exact` is true, filters results whose .name ~= query.
local function async_lsp_workspace_symbol(bufnr, query, exact, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" })
  if #clients == 0 then
    vim.schedule(function() on_result(nil) end)
    return
  end

  local pending = #clients
  local merged = {}
  local fired = false
  local timer = nil

  local function fire(arg)
    if fired then return end
    fired = true
    if timer and not timer:is_closing() then
      timer:stop()
      timer:close()
    end
    on_result(arg)
  end

  local function dec_pending()
    pending = pending - 1
    if pending == 0 then fire(#merged > 0 and merged or nil) end
  end

  -- Hard 5s ceiling — workspace/symbol should be < 200ms; if it's slower
  -- something is wrong (e.g. clangd is rebuilding its symbol DB) and we'd
  -- rather let the precise path / GTAGS take over.
  timer = vim.defer_fn(function() fire(#merged > 0 and merged or nil) end, 5000)

  for _, client in ipairs(clients) do
    local ok_req = pcall(function()
      client:request("workspace/symbol", { query = query }, function(err, result)
        if not err and type(result) == "table" then
          for _, sym in ipairs(result) do
            local keep = true
            if exact and sym.name ~= query then keep = false end
            if keep and sym.kind and not DEFINITION_KINDS[sym.kind] then keep = false end
            if keep and sym.location and sym.location.uri and sym.location.range then
              -- normalize SymbolInformation -> Location
              table.insert(merged, {
                uri = sym.location.uri,
                range = sym.location.range,
                -- carry kind for later ranking
                _ws_kind = sym.kind,
                _ws_container = sym.containerName,
                -- carry symbol name so post-jump reconcile can verify
                -- the landing line and silently fix stale-index drift
                _sym_name = sym.name,
              })
            end
          end
        end
        dec_pending()
      end, bufnr)
    end)
    if not ok_req then dec_pending() end
  end
end

-- Async LSP definition with built-in retry for empty results (clangd preamble
-- still building) AND smart implementation merging when definition only
-- returns headers (which usually means the user is on a virtual interface
-- declaration and wants the platform-specific override).
--
-- Calls on_result(locations|nil) exactly once.
local function async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, on_result)
  local attempts = 0

  -- Run definition + (conditionally) implementation, merge & dedup. Calls
  -- inner(merged|nil) once.
  local function def_plus_impl(inner)
    async_lsp_request(bufnr, "textDocument/definition", function(def_locs)
      if not still_current() then return end
      def_locs = filter_self_locations(def_locs, ref_file, ref_line)

      -- If definition gave us a real source file (not header-only), use it.
      if def_locs and #def_locs > 0 and not is_thin_header_only(def_locs) then
        inner(def_locs)
        return
      end

      -- Definition was empty OR header-only. Try implementation in parallel
      -- with declaration as a backup.
      local has_impl = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/implementation" }) > 0
      if not has_impl then
        -- No implementation method; fall back to declaration as before.
        local has_decl = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/declaration" }) > 0
        if has_decl then
          async_lsp_request(bufnr, "textDocument/declaration", function(decl_locs)
            if not still_current() then return end
            decl_locs = filter_self_locations(decl_locs, ref_file, ref_line)
            local merged = {}
            if def_locs then vim.list_extend(merged, def_locs) end
            if decl_locs then vim.list_extend(merged, decl_locs) end
            inner(#merged > 0 and merged or nil)
          end)
        else
          inner(def_locs and #def_locs > 0 and def_locs or nil)
        end
        return
      end

      async_lsp_request(bufnr, "textDocument/implementation", function(impl_locs)
        if not still_current() then return end
        impl_locs = filter_self_locations(impl_locs, ref_file, ref_line)

        -- Merge def + impl, dedup.
        local merged = {}
        if def_locs then vim.list_extend(merged, def_locs) end
        if impl_locs then vim.list_extend(merged, impl_locs) end
        merged = dedup_locations(merged)

        if #merged > 0 then
          inner(merged)
          return
        end

        -- Nothing useful from def or impl; try declaration as a last resort.
        local has_decl = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/declaration" }) > 0
        if has_decl then
          async_lsp_request(bufnr, "textDocument/declaration", function(decl_locs)
            if not still_current() then return end
            decl_locs = filter_self_locations(decl_locs, ref_file, ref_line)
            inner(decl_locs and #decl_locs > 0 and decl_locs or nil)
          end)
        else
          inner(nil)
        end
      end)
    end)
  end

  local function try_once()
    attempts = attempts + 1
    def_plus_impl(function(locs)
      if not still_current() then return end
      if locs and #locs > 0 then
        on_result(locs)
        return
      end
      if attempts < LSP_RETRY_COUNT + 1 then
        vim.defer_fn(function()
          if still_current() then try_once() end
        end, LSP_RETRY_INTERVAL_MS)
      else
        on_result(nil)
      end
    end)
  end

  try_once()
end

-- ---------------------------------------------------------------------------
-- Jump dispatch
-- ---------------------------------------------------------------------------

-- pick_winner_with_label(locs, platform_hints, ref_file):
--   Reranks, picks a clear winner, returns winner_loc + short label string
--   suitable for the success notice ("FooFile.h:42") + the ranked list.
--   Returns (nil, nil, ranked) if no clear winner — caller can populate
--   quickfix from `ranked`. Returns (nil, nil, nil) if locs is empty.
local function pick_winner_with_label(locs, platform_hints, ref_file, receiver)
  if not locs or #locs == 0 then return nil, nil, nil end
  local ranked = rerank_locations(locs, platform_hints, ref_file, receiver)
  local winner = clear_winner(ranked, platform_hints, ref_file, receiver)
  if not winner then return nil, nil, ranked end

  local p = location_path(winner)
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

local function try_jump(locations, title)
  if not locations or #locations == 0 then
    return false
  end
  locations = dedup_locations(locations)
  if #locations == 1 then
    local ok = jump_to_location(locations[1])
    if ok then return true end
    vim.notify("LSP location could not be opened: " .. tostring(locations[1].uri or locations[1].targetUri), vim.log.levels.WARN)
    return "open_failed"
  end
  return populate_quickfix(title, locations) and true or false
end

-- ---------------------------------------------------------------------------
-- GTAGS fallback (now async)
-- ---------------------------------------------------------------------------

local function gtags_fallback_async(symbol, on_done)
  if not symbol then
    on_done(false)
    return
  end
  local ok, ue = pcall(require, "ue")
  if not ok then
    on_done(false)
    return
  end
  if ue.gtags_definition_async then
    ue.gtags_definition_async(symbol, on_done)
    return
  end
  -- Backward-compat: schedule sync version off the immediate keystroke so
  -- the press itself still feels responsive.
  vim.schedule(function()
    local r = ue.gtags_definition and ue.gtags_definition(symbol) or false
    on_done(r and true or false)
  end)
end

-- ---------------------------------------------------------------------------
-- Shader-only fast path
-- ---------------------------------------------------------------------------

local SHADER_EXTS = { usf = true, ush = true, hlsl = true, hlsli = true, glsl = true, frag = true, vert = true, metal = true, comp = true }

local function buf_extension(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then return "" end
  return (name:match("%.([^./\\]+)$") or ""):lower()
end

-- ---------------------------------------------------------------------------
-- Progress notification helper
-- ---------------------------------------------------------------------------
-- Returns {update = fn(msg), clear = fn(), finish = fn(msg, lifetime_ms)}.
-- snacks/noice/nvim-notify all support replacing a notification by passing
-- the previous id back via opts.replace; we use that when available.
-- Module-level singleton: only ONE LSP-definition notice may be visible at
-- a time. A second gd while a first one is still resolving will reuse the
-- same notification slot (snacks: same id; nvim-notify: same handle), so the
-- top-right corner never accumulates a stack of spinners.
local _shared_notice_id = nil

local function progress_notice(initial_msg)
  local function emit(msg, opts_override)
    -- hide_from_history is set from the FIRST emit — without this, snacks
    -- writes every spinner update into :messages history even when we
    -- pass `replace=id`. This is what makes the top-right corner appear to
    -- accumulate "resolving..." entries across multiple gd invocations.
    local opts = {
      title = "LSP definition",
      timeout = false,
      hide_from_history = true,
    }
    if _shared_notice_id ~= nil then
      opts.replace = _shared_notice_id
      opts.id = _shared_notice_id            -- snacks key
    else
      opts.id = "ue_lsp_definition_progress"  -- stable snacks slot key
    end
    if opts_override then
      for k, v in pairs(opts_override) do opts[k] = v end
    end
    local ok, new_id = pcall(vim.notify,
      msg,
      opts_override and opts_override.level or vim.log.levels.INFO,
      opts)
    if ok then
      _shared_notice_id = new_id or _shared_notice_id
    end
  end
  emit(initial_msg)
  local current_id = _shared_notice_id
  return {
    update = function(msg) emit(msg) end,
    clear = function()
      pcall(function()
        if current_id ~= nil then
          if type(current_id) == "table" and current_id.hide then
            current_id:hide()
          elseif vim.notify and package.loaded["notify"] then
            pcall(vim.notify, "", vim.log.levels.INFO, { replace = current_id, timeout = 1 })
          end
        end
      end)
      -- Only clear the shared slot if we're still the active notice.
      if _shared_notice_id == current_id then _shared_notice_id = nil end
      current_id = nil
    end,
    -- Update the notice to a "done" message that auto-dismisses after
    -- lifetime_ms. Critically: the "done" message is allowed into history
    -- (hide_from_history=false) so the user can see the latest resolution
    -- in :messages — but spinner ticks remain history-suppressed.
    finish = function(msg, lifetime_ms, level)
      lifetime_ms = lifetime_ms or 3000
      emit(msg, {
        timeout = lifetime_ms,
        level = level or vim.log.levels.INFO,
        hide_from_history = false,
      })
      local id_at_finish = current_id
      vim.defer_fn(function()
        if _shared_notice_id == id_at_finish then
          pcall(function()
            if type(current_id) == "table" and current_id.hide then
              current_id:hide()
            elseif vim.notify and package.loaded["notify"] then
              pcall(vim.notify, "", vim.log.levels.INFO, { replace = current_id, timeout = 1 })
            end
          end)
          _shared_notice_id = nil
          current_id = nil
        end
      end, lifetime_ms + 200)
    end,
  }
end

-- ---------------------------------------------------------------------------
-- Persistent debug ring-buffer for goto-definition tracing.
-- Always-on, low-overhead (max 200 entries). View with :UEDefTrace.
-- ---------------------------------------------------------------------------
-- MODULE_REVISION bumps every time this file is meaningfully edited so we
-- can tell from a trace whether the user is running stale bytecode.
local MODULE_REVISION = "selftest+disklog+exportrev+canddump+receiver+singleton+jumpfix+reconcile+cwordcarry+unstrand"
local TRACE_MAX = 200
local trace_ring = {}
local trace_idx = 0
-- Disk-backed log (so trace survives even if :UEDefTrace itself errors).
local DISK_LOG = vim.fn.stdpath("cache") .. "/ue_def_trace.log"
-- Truncate on module load so each session starts clean.
pcall(function()
  local f = io.open(DISK_LOG, "w")
  if f then f:write(string.format("=== module loaded rev=%s at %s ===\n",
    MODULE_REVISION, os.date("%Y-%m-%d %H:%M:%S"))); f:close() end
end)
local function dtrace(fmt, ...)
  trace_idx = trace_idx + 1
  local line = string.format("[%s #%d] " .. fmt, os.date("%H:%M:%S"), trace_idx, ...)
  trace_ring[((trace_idx - 1) % TRACE_MAX) + 1] = line
  pcall(function()
    local f = io.open(DISK_LOG, "a")
    if f then f:write(line .. "\n"); f:close() end
  end)
end
-- Expose to early-defined functions like reconcile_landing_to_definition
M._dtrace = dtrace
-- Expose for headless e2e testing of stale-index recovery
M._test_reconcile = reconcile_landing_to_definition
function M.dump_trace()
  local lines = { string.format("=== UEDefTrace  module_rev=%s  trace_idx=%d ===",
    MODULE_REVISION, trace_idx) }
  -- Walk from oldest to newest
  local start = trace_idx > TRACE_MAX and trace_idx - TRACE_MAX + 1 or 1
  for i = start, trace_idx do
    local entry = trace_ring[((i - 1) % TRACE_MAX) + 1]
    if entry then table.insert(lines, entry) end
  end
  if #lines == 1 then
    print("(no def trace entries yet, module_rev=" .. MODULE_REVISION .. ")")
    return
  end
  -- Open a scratch buffer
  vim.cmd("vnew")
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
  vim.bo.buftype = "nofile"
  vim.bo.bufhidden = "wipe"
  vim.bo.swapfile = false
  vim.api.nvim_buf_set_name(0, "UEDefTrace")
end
vim.api.nvim_create_user_command("UEDefTrace", function() M.dump_trace() end, {})

-- :UEDefSelfTest — exercises pick_winner_with_label on synthetic GetBinCount-
-- like data (2 header hits in same module). PASS proves the header-only
-- relaxation in clear_winner is loaded; FAIL means stale module.
function M.self_test()
  -- Synthetic ws/symbol response: 2 .h declarations, same module.
  local ref_file = vim.fn.expand("~/dummy_module/foo.cpp"):gsub("\\", "/")
  -- Force ref_file to look like UE for same-module match.
  ref_file = "<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/foo.cpp"
  local hits = {
    {
      uri = "file:///<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteShared.h",
      range = { start = { line = 735, character = 12 }, ["end"] = { line = 735, character = 23 } },
      _ws_kind = 6,
    },
    {
      uri = "file:///<PROJ_DRIVE>/UEProj/Engine/Source/Runtime/Renderer/Private/Nanite/NaniteShared.h",
      range = { start = { line = 897, character = 12 }, ["end"] = { line = 897, character = 23 } },
      _ws_kind = 6,
    },
  }
  local winner, label, ranked = pick_winner_with_label(hits, {}, ref_file)
  local lines = {
    "=== UEDefSelfTest  module_rev=" .. MODULE_REVISION,
    "input: 2 header hits, same module (simulated GetBinCount)",
    "winner: " .. (winner and ("PICKED " .. (winner.uri or "?") ..
      ":" .. tostring(winner.range and winner.range.start and winner.range.start.line + 1 or "?"))
      or "NIL (ambiguous — header-only relaxation NOT loaded; module is stale)"),
    "label: " .. tostring(label),
    "ranked count: " .. tostring(#(ranked or {})),
    "result: " .. (winner and "PASS ✓" or "FAIL ✗ — restart nvim or :Lazy reload utils.lsp_fallback"),
  }
  for _, l in ipairs(lines) do print(l) end
  return winner ~= nil
end
vim.api.nvim_create_user_command("UEDefSelfTest", function() M.self_test() end, {})

-- ---------------------------------------------------------------------------
-- M.definition: LSP first (with empty-result retries), GTAGS only after LSP
-- has definitively given up. Never blocks the main loop.
-- ---------------------------------------------------------------------------
--
-- Design rationale:
--   * Correctness > speed. We never "jump now, correct later" — that creates
--     a confusing two-jump UX. We pick the best source we have, then jump.
--   * LSP semantic results beat GTAGS textual results, always. So we wait
--     for LSP to finish (including preamble-building retries) before
--     considering GTAGS.
--   * The user opted into "accept latency, async". Worst case is a multi-
--     second wait while preamble builds, with a progress notice. The buffer
--     is fully usable during that wait — no main-loop blocking.

function M.definition()
  local symbol = current_symbol()
  local receiver = current_receiver()
  local bufnr = vim.api.nvim_get_current_buf()
  local ref_file = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local ref_line = vim.api.nvim_win_get_cursor(0)[1]
  dtrace("M.definition() called sym=%q recv=%q file=%s:%d",
    symbol or "", receiver or "",
    vim.fn.fnamemodify(ref_file, ":t"), ref_line)

  -- Clear any stale precise-winner from a previous gd; it's no longer
  -- relevant once the user invokes gd on something else.
  M._last_precise_winner = nil
  request_token = request_token + 1
  local my_token = request_token
  local function still_current() return my_token == request_token end

  -- Three independent tracks; whichever produces a usable jump first wins.
  local jumped = false   -- some track has navigated the cursor
  local resolved = false -- terminal state, no more notices, no more work
  local notice = nil

  local function clear_notice()
    if notice then pcall(notice.clear); notice = nil end
  end
  local function done(success_msg, lifetime_ms)
    resolved = true
    if success_msg and notice then
      pcall(notice.finish, success_msg, lifetime_ms or 3000); notice = nil
    elseif success_msg then
      -- Resolved before the spinner appeared (fast path). Still show the
      -- result so the user can see whether instant or precise won.
      pcall(vim.notify, success_msg, vim.log.levels.INFO,
        { title = "LSP definition", timeout = lifetime_ms or 3000 })
    else
      clear_notice()
    end
  end

  -- Resolve platform hints once (cheap, cached state.json).
  local platform_hints = nil
  do
    local ok, ue = pcall(require, "ue")
    if ok and ue.platform_path_priorities then
      platform_hints = ue.platform_path_priorities()
    end
  end

  -- Shader files: still GTAGS-only, same as before.
  local ext = buf_extension(bufnr)
  if SHADER_EXTS[ext] then
    gtags_fallback_async(symbol, function(ok)
      if not still_current() then return end
      done()
      if not ok then
        vim.notify("No definition (GTAGS empty): " .. (symbol or "?"), vim.log.levels.INFO)
      end
    end)
    return
  end

  local has_def_client = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" }) > 0
  local has_ws_client  = #vim.lsp.get_clients({ bufnr = bufnr, method = "workspace/symbol" }) > 0

  if not has_def_client and not has_ws_client then
    gtags_fallback_async(symbol, function(ok)
      if not still_current() then return end
      done()
      if not ok then
        vim.notify("No definition (no LSP, GTAGS empty): " .. (symbol or "?"), vim.log.levels.INFO)
      end
    end)
    return
  end

  -- Progress notice (only after 600ms, so fast jumps don't flash a spinner).
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    notice = progress_notice(string.format(
      "⏳ resolving %s ... (instant index path racing precise AST path)",
      symbol or "?"
    ))
  end, LSP_PROGRESS_NOTICE_MS)

  -- Hard timeout: bail out. Only WARN if nothing has jumped — otherwise
  -- the instant track already navigated and the precise reconcile just
  -- couldn't finish in time, which is normal for very large UE TUs.
  vim.defer_fn(function()
    if not still_current() or resolved then return end
    done()
    if not jumped then
      vim.notify(string.format("Definition lookup timed out after %ds (%s)",
        math.floor(OVERALL_TIMEOUT_MS / 1000), symbol or "?"), vim.log.levels.WARN)
    end
  end, OVERALL_TIMEOUT_MS)

  -- ---- Track 1: instant via workspace/symbol -----------------------------
  local instant_winner = nil
  if has_ws_client and symbol and symbol ~= "" then
    dtrace("instant: dispatching ws/symbol q=%q", symbol)
    async_lsp_workspace_symbol(bufnr, symbol, true, function(ws_locs)
      local n = ws_locs and #ws_locs or 0
      dtrace("instant: ws/symbol back n=%d still=%s resolved=%s",
        n, tostring(still_current()), tostring(resolved))
      if not still_current() or resolved then return end
      if not ws_locs or #ws_locs == 0 then return end
      if #ws_locs > INSTANT_MAX_CANDIDATES then
        dtrace("instant: SKIP n>%d", INSTANT_MAX_CANDIDATES); return
      end
      ws_locs = filter_self_locations(ws_locs, ref_file, ref_line)
      dtrace("instant: after filter_self n=%d", ws_locs and #ws_locs or 0)
      if not ws_locs or #ws_locs == 0 then return end

      -- Dump candidate set for diagnosis
      for i, loc in ipairs(ws_locs) do
        local uri = loc.uri or (loc.targetUri or "?")
        local rng = loc.range or loc.targetSelectionRange or {}
        local ln = rng.start and rng.start.line or -1
        dtrace("instant: cand[%d] uri=%s line=%d kind=%s", i,
          tostring(uri):gsub("file:///", ""):sub(-80), ln, tostring(loc._ws_kind))
      end

      local winner, label = pick_winner_with_label(ws_locs, platform_hints, ref_file, receiver)
      dtrace("instant: pick_winner winner=%s label=%s",
        tostring(winner ~= nil), tostring(label))
      if not winner then return end -- ambiguous, let precise path handle

      -- Jump now if we haven't already.
      if not jumped then
        -- Carry origin cword so reconcile can verify the landing line and
        -- fix stale-index drift even on this synthetic ws/symbol location.
        winner._origin_cword = symbol
        local pok, ok_or_err = pcall(jump_to_location, winner)
        local ok = pok and ok_or_err == true
        dtrace("instant: jump pok=%s ok=%s err=%s",
          tostring(pok), tostring(ok), pok and "" or tostring(ok_or_err):sub(1,80))
        if ok then
          jumped = true
          instant_winner = winner
          done(string.format("⚡ %s → %s (instant)", symbol or "?", label or "?"), 3000)
          -- Note: done() sets resolved=true, but the precise track callback
          -- only gates on still_current() (not resolved) — so reconcile
          -- still runs and can post a "precise differs" hint.
          -- INSTANT_PRECISE_RECONCILE controls whether reconcile is shown
          -- (handled in precise track), not whether precise keeps running.
        else
          -- Instant jump failed — most likely show_document raised
          -- "Cursor position outside buffer" because the target file
          -- couldn't be loaded synchronously. Do NOT mark resolved here:
          -- let the precise track / GTAGS still try to deliver a real
          -- jump. Log at DEBUG so it's available via :messages but not
          -- noisy. The OVERALL_TIMEOUT_MS hard-stop guarantees we won't
          -- hang forever even in pathological cases.
          if not pok then
            vim.schedule(function()
              vim.notify(string.format(
                "⚠ instant jump errored, falling back: %s",
                tostring(ok_or_err):sub(1, 200)
              ), vim.log.levels.DEBUG)
            end)
          end
        end
      end
    end)
  end

  -- ---- Track 2: precise via textDocument/definition (+impl/+decl) --------
  if has_def_client then
    dtrace("precise: dispatching textDocument/definition")
    async_lsp_definition_with_retry(bufnr, ref_file, ref_line, still_current, function(locs)
      dtrace("precise: back n=%d still=%s jumped=%s",
        locs and #locs or 0, tostring(still_current()), tostring(jumped))
      if not still_current() then return end

      if locs and #locs > 0 then
        local winner, label, ranked = pick_winner_with_label(locs, platform_hints, ref_file, receiver)
        dtrace("precise: pick winner=%s label=%s n_ranked=%d",
          tostring(winner ~= nil), tostring(label), #(ranked or locs))

        if not jumped then
          -- precise won the race
          if winner then
            -- Carry origin cword so reconcile can fix stale-index drift.
            winner._origin_cword = symbol
            local pok, ok = pcall(jump_to_location, winner)
            ok = pok and ok
            dtrace("precise: jump pok=%s ok=%s", tostring(pok), tostring(ok))
            if ok then
              jumped = true
              done(string.format("✓ %s → %s (precise)", symbol or "?", label or "?"), 3000)
              return
            end
          end
          -- multi-candidate / no clear winner → quickfix
          local outcome = try_jump(ranked or locs, "LSP definitions")
          if outcome == true or outcome == "open_failed" then
            local first = (ranked or locs)[1]
            local _, lab2 = pick_winner_with_label({ first }, platform_hints, ref_file, receiver)
            jumped = true
            done(string.format("✓ %s → %s (%d candidates)", symbol or "?",
              lab2 or "?", #(ranked or locs)), 3000)
            return
          end
        else
          -- instant already jumped. Reconcile if precise disagrees.
          if INSTANT_PRECISE_RECONCILE and winner and instant_winner then
            local same = location_key(winner) == location_key(instant_winner)
            if not same then
              vim.notify(string.format(
                "ℹ precise definition differs: %s (press <leader>gP to switch)",
                label or "?"
              ), vim.log.levels.INFO)
              M._last_precise_winner = winner
            end
          end
          -- TODO(instant-goto): when winner is nil but ranked has multiple
          -- candidates AND instant_winner is set, surface a "precise found N
          -- candidates" hint and let <leader>gP open a quickfix. For v1 we
          -- silently keep the instant jump.
          done() -- clear spinner; instant message already shown
          return
        end
      end

      -- LSP precise gave nothing. If instant already jumped, we're done.
      if jumped then done(); return end

      -- Otherwise fall through to GTAGS.
      gtags_fallback_async(symbol, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", symbol or "?"), 3000)
        else
          done()
          vim.notify("No definition (LSP and GTAGS both empty): " .. (symbol or "?"),
            vim.log.levels.INFO)
        end
      end)
    end)
  else
    -- ws_client only, no def_client. Wait briefly for instant track,
    -- then fall back to GTAGS if it didn't pan out.
    vim.defer_fn(function()
      if not still_current() or resolved or jumped then return end
      gtags_fallback_async(symbol, function(jumped_g)
        if not still_current() or resolved then return end
        if jumped_g then
          jumped = true
          done(string.format("✓ %s (GTAGS fallback)", symbol or "?"), 3000)
        else
          done()
          vim.notify("No definition: " .. (symbol or "?"), vim.log.levels.INFO)
        end
      end)
    end, INSTANT_DEADLINE_MS + 100)
  end
end

-- Jump to the precise definition stored by the last reconcile, if any.
function M.jump_to_precise()
  local w = M._last_precise_winner
  if not w then
    vim.notify("No precise winner recorded yet", vim.log.levels.WARN)
    return
  end
  pcall(jump_to_location, w)
  M._last_precise_winner = nil
end

-- ---------------------------------------------------------------------------
-- References (sync — usually fast enough, results go to qf)
-- ---------------------------------------------------------------------------

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

-- Show current LSP client status for the current buffer plus our last token.
-- Useful when gd seems hung: tells you if clangd is even attached and what
-- its progress messages look like.
function M.status()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = {
    string.format("buffer: %d  name: %s", bufnr, vim.api.nvim_buf_get_name(bufnr)),
    string.format("request_token: %d", request_token),
    "",
    "LSP clients (definition method):",
  }
  local def_clients = vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" })
  if vim.tbl_isempty(def_clients) then
    table.insert(lines, "  (none)")
  else
    for _, c in ipairs(def_clients) do
      table.insert(lines, string.format("  - %s (id=%d, encoding=%s)",
        c.name, c.id, c.offset_encoding or "?"))
      -- progress messages
      local progress = c.progress
      if progress and progress.pending then
        for token, msg in pairs(progress.pending) do
          table.insert(lines, string.format("    progress[%s]: %s",
            tostring(token), vim.inspect(msg)))
        end
      end
    end
  end
  vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO, { title = "LSP fallback status" })
end

function M.references()
  local symbol = current_symbol()
  if not symbol then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end

  local locations, errors, timed_out = sync_locations("textDocument/references", 5000)
  if timed_out then
    vim.notify("LSP references timed out — falling back to GTAGS (results may be lower quality)", vim.log.levels.WARN)
  elseif errors and errors > 0 then
    vim.notify(string.format("LSP references: %d client(s) returned errors", errors), vim.log.levels.WARN)
  end

  if locations and #locations > 0 and populate_quickfix("LSP references: " .. symbol, locations) then
    return
  end

  local ok, ue = pcall(require, "ue")
  if ok and ue.gtags_references and ue.gtags_references(symbol) then
    return
  end

  vim.notify("No references (LSP/GTAGS)", vim.log.levels.INFO)
end

-- Export module revision so external probes can verify which build is
-- actually loaded (e.g. via `lua print(require('utils.lsp_fallback').MODULE_REVISION)`).
M.MODULE_REVISION = MODULE_REVISION

return M
