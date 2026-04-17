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

local M = {}

local function current_symbol()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return nil
  end
  return word
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

-- Group locations by their captured offset_encoding and call
-- vim.lsp.util.locations_to_items once per group (it groups by file
-- internally and avoids N readfile() round-trips).
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

local function jump_to_location(location)
  vim.cmd("normal! m'")
  return vim.lsp.util.show_document(location, location._position_encoding or "utf-16", {
    reuse_win = true,
    focus = true,
  })
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

  -- CRITICAL: when LSP returns ONLY the self-location (e.g. gd on a
  -- header decl whose definition is in a .cpp clangd hasn't indexed),
  -- return {} so the caller can fall through to declaration/GTAGS.
  -- Returning the original list would jump to the same line and bypass
  -- all fallback steps.
  return filtered
end

-- ---------------------------------------------------------------------------
-- Sync helpers (used by references)
-- ---------------------------------------------------------------------------

-- Per-client sync request: each client gets its own params built from its own
-- offset_encoding. Returns {locations, partial_error_count}.
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
-- Async definition: non-blocking LSP request with GTAGS fallback
-- ---------------------------------------------------------------------------

-- Module-level token: increments on every M.definition() call so stale
-- callbacks from older gd presses cannot override a fresher one.
local request_token = 0

--- Fire an async LSP request. Calls `on_result(locations)` on the main thread.
--- `locations` is nil when no client supports the method or the request fails.
--- Each client receives params built from its OWN offset_encoding.
local function async_lsp_request(bufnr, method, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  if not clients or vim.tbl_isempty(clients) then
    vim.schedule(function()
      on_result(nil)
    end)
    return
  end

  local pending = #clients
  local all_items = {}
  local done = false

  local function finish()
    if done then
      return
    end
    done = true
    vim.schedule(function()
      on_result(#all_items > 0 and all_items or nil)
    end)
  end

  local function dec_pending()
    pending = pending - 1
    if pending <= 0 then
      finish()
    end
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

--- Try to jump from a list of locations.
--- Returns:
---   true  on a successful jump or quickfix populate
---   "open_failed" when LSP returned a result we could NOT open (caller
---                 should NOT fall through to a different fallback)
---   false when there are no usable locations
local function try_jump(locations, title)
  if not locations or #locations == 0 then
    return false
  end
  -- Prefer clangd-style: dedup before counting.
  locations = dedup_locations(locations)
  if #locations == 1 then
    local ok = jump_to_location(locations[1])
    if ok then
      return true
    end
    vim.notify("LSP location could not be opened: " .. tostring(locations[1].uri or locations[1].targetUri), vim.log.levels.WARN)
    return "open_failed"
  end
  return populate_quickfix(title, locations) and true or false
end

--- GTAGS fallback (synchronous, fast enough for local DB).
local function gtags_fallback(symbol)
  if not symbol then
    return false
  end
  local ok, ue = pcall(require, "ue")
  if ok and ue.gtags_definition then
    return ue.gtags_definition(symbol)
  end
  return false
end

--- Shader file extensions — clangd can't handle these, go straight to GTAGS.
local SHADER_EXTS = { usf = true, ush = true, hlsl = true, hlsli = true, glsl = true, frag = true, vert = true, metal = true, comp = true }

local function buf_extension(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return ""
  end
  return (name:match("%.([^./\\]+)$") or ""):lower()
end

--- Async definition: definition -> declaration -> GTAGS, all non-blocking for
--- the LSP parts.
function M.definition()
  local symbol = current_symbol()
  local bufnr = vim.api.nvim_get_current_buf()
  local ref_file = normalize_path(vim.api.nvim_buf_get_name(bufnr))
  local ref_line = vim.api.nvim_win_get_cursor(0)[1]

  -- Bump token; capture our own.
  request_token = request_token + 1
  local my_token = request_token

  local function still_current()
    return my_token == request_token
  end

  -- Shader files: skip LSP entirely, clangd can't parse HLSL/USF properly.
  local ext = buf_extension(bufnr)
  if SHADER_EXTS[ext] then
    if not gtags_fallback(symbol) then
      vim.notify("No definition (LSP/GTAGS)", vim.log.levels.INFO)
    end
    return
  end

  -- Check if any LSP client supports definition at all.
  local has_def_client = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/definition" }) > 0

  if not has_def_client then
    -- No LSP — skip straight to GTAGS (sync, but very fast).
    if not gtags_fallback(symbol) then
      vim.notify("No definition (LSP/GTAGS)", vim.log.levels.INFO)
    end
    return
  end

  -- Async: textDocument/definition
  async_lsp_request(bufnr, "textDocument/definition", function(locations)
    if not still_current() then
      return
    end
    locations = filter_self_locations(locations, ref_file, ref_line)
    local jumped = try_jump(locations, "LSP definitions")
    if jumped == true then
      return
    end
    if jumped == "open_failed" then
      -- LSP gave us a real location; opening failed. Do NOT fall back —
      -- GTAGS would jump to an unrelated symbol.
      return
    end

    -- Async fallback: textDocument/declaration
    local has_decl_client = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/declaration" }) > 0
    if has_decl_client then
      async_lsp_request(bufnr, "textDocument/declaration", function(decl_locations)
        if not still_current() then
          return
        end
        decl_locations = filter_self_locations(decl_locations, ref_file, ref_line)
        local decl_jumped = try_jump(decl_locations, "LSP declarations")
        if decl_jumped == true then
          return
        end
        if decl_jumped == "open_failed" then
          return
        end
        if not gtags_fallback(symbol) then
          vim.notify("No definition (LSP/GTAGS)", vim.log.levels.INFO)
        end
      end)
      return
    end

    -- No declaration client — GTAGS fallback
    if not gtags_fallback(symbol) then
      vim.notify("No definition (LSP/GTAGS)", vim.log.levels.INFO)
    end
  end)
end

-- ---------------------------------------------------------------------------
-- References (sync — usually fast enough, results go to qf)
-- ---------------------------------------------------------------------------

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

return M
