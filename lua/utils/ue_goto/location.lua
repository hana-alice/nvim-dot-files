-- ue_goto.location — pure Location-object utilities.
--
-- Stateless. No vim.fn.* (only vim.uri_*, vim.deepcopy, vim.lsp.util
-- for quickfix grouping). Used by provider, UI, and semantic navigation.
--
-- Vocab:
--   Location: { uri | targetUri, range | targetRange | targetSelectionRange }
--   normalized Location: deepcopy + ._position_encoding stamped on.

local M = {}

-- normalize_locations(result, position_encoding):
--   Coerce a single Location or LocationLink (or array of either) into a
--   flat list of plain Location-shaped tables, each stamped with the
--   client's position_encoding so downstream code can convert to qf items
--   correctly. Drops malformed entries silently.
function M.normalize_locations(result, position_encoding)
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

-- normalize_path(path): collapse backslashes and trailing slashes.
function M.normalize_path(path)
  path = tostring(path or ""):gsub("\\", "/")
  path = path:gsub("/+$", "")
  return path
end

-- location_path(location): the absolute filesystem path, normalized.
function M.location_path(location)
  local uri = location and (location.uri or location.targetUri)
  if not uri or uri == "" then
    return ""
  end
  return M.normalize_path(vim.uri_to_fname(uri))
end

-- location_line(location): 1-based line number, or 0 if missing.
function M.location_line(location)
  local range = location
    and (location.targetSelectionRange or location.targetRange or location.range)
  local start = range and range.start or nil
  return start and (tonumber(start.line) or 0) + 1 or 0
end

-- location_key(location): "<path>:<line0>:<col0>" identity key.
function M.location_key(location)
  local range = location
    and (location.targetSelectionRange or location.targetRange or location.range)
  local s = range and range.start or nil
  local line = s and tonumber(s.line) or 0
  local col = s and tonumber(s.character) or 0
  return string.format("%s:%d:%d", M.location_path(location), line, col)
end

-- dedup_locations(locations): drop entries with duplicate location_key.
function M.dedup_locations(locations)
  if not locations or #locations <= 1 then
    return locations
  end
  local seen = {}
  local out = {}
  for _, loc in ipairs(locations) do
    local key = M.location_key(loc)
    if not seen[key] then
      seen[key] = true
      out[#out + 1] = loc
    end
  end
  return out
end

-- locations_to_items_grouped(locations):
--   vim.lsp.util.locations_to_items requires a uniform offset_encoding,
--   but mixed-client results have heterogeneous encodings. Group by
--   ._position_encoding, convert each group, concatenate.
function M.locations_to_items_grouped(locations)
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

-- populate_quickfix(title, locations): set the qf list and open it.
-- Returns true on success, false if the items list was empty.
function M.populate_quickfix(title, locations)
  local items = M.locations_to_items_grouped(locations)
  if not items or vim.tbl_isempty(items) then
    return false
  end
  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("botright copen 10")
  return true
end

-- filter_self_locations(locations, ref_file, ref_line):
--   Drop entries pointing at exactly (ref_file, ref_line) — typically
--   the cursor's own line, which is useless for goto-definition.
--
--   IMPORTANT: returns {} (not the original list) when filtering removes
--   everything. Lets the caller fall through to the next track instead
--   of jumping to the same line silently.
function M.filter_self_locations(locations, ref_file, ref_line)
  if not locations or #locations == 0 then
    return locations
  end
  ref_file = ref_file or M.normalize_path(vim.api.nvim_buf_get_name(0))
  ref_line = ref_line or vim.api.nvim_win_get_cursor(0)[1]

  local filtered = {}
  for _, location in ipairs(locations) do
    if M.location_path(location) ~= ref_file
      or M.location_line(location) ~= ref_line
    then
      filtered[#filtered + 1] = location
    end
  end
  return filtered
end

return M
