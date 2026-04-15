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

-- ---------------------------------------------------------------------------
-- Sync helpers (used by the async fallback chain and by references)
-- ---------------------------------------------------------------------------

local function sync_locations(method, timeout_ms)
  local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
  if not clients or vim.tbl_isempty(clients) then
    return nil
  end

  local params = vim.lsp.util.make_position_params(0, "utf-8")
  if method == "textDocument/references" then
    params.context = { includeDeclaration = true }
  end

  local responses = vim.lsp.buf_request_sync(0, method, params, timeout_ms or 5000)
  if not responses then
    return nil
  end

  local items = {}
  for client_id, response in pairs(responses) do
    if response.result and type(response.result) == "table" then
      local client = vim.lsp.get_client_by_id(client_id)
      vim.list_extend(items, normalize_locations(response.result, client and client.offset_encoding or "utf-16"))
    end
  end
  return items
end

local function populate_quickfix(title, locations)
  local items = {}
  for _, location in ipairs(locations or {}) do
    local converted = vim.lsp.util.locations_to_items({ location }, location._position_encoding or "utf-16")
    if converted and #converted > 0 then
      vim.list_extend(items, converted)
    end
  end
  if not items or vim.tbl_isempty(items) then
    return false
  end

  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("copen")
  return true
end

local function jump_to_location(location)
  vim.cmd("normal! m'")
  return vim.lsp.util.show_document(location, location._position_encoding or "utf-16", {
    reuse_win = true,
    focus = true,
  })
end

-- ---------------------------------------------------------------------------
-- Async definition: non-blocking LSP request with GTAGS fallback
-- ---------------------------------------------------------------------------

--- Fire an async LSP request. Calls `on_result(locations)` on the main thread.
--- `locations` is nil when no client supports the method or the request fails.
local function async_lsp_request(bufnr, method, on_result)
  local clients = vim.lsp.get_clients({ bufnr = bufnr, method = method })
  if not clients or vim.tbl_isempty(clients) then
    on_result(nil)
    return
  end

  local params = vim.lsp.util.make_position_params(0, "utf-8")
  local pending = #clients
  local all_items = {}

  for _, client in ipairs(clients) do
    client:request(method, params, function(err, result)
      if not err and result and type(result) == "table" then
        vim.list_extend(all_items, normalize_locations(result, client.offset_encoding or "utf-16"))
      end
      pending = pending - 1
      if pending == 0 then
        vim.schedule(function()
          on_result(#all_items > 0 and all_items or nil)
        end)
      end
    end, bufnr)
  end
end

--- Try to jump from a list of locations. Returns true on success.
local function try_jump(locations, title)
  if not locations or #locations == 0 then
    return false
  end
  if #locations == 1 then
    return jump_to_location(locations[1])
  end
  return populate_quickfix(title, locations)
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

--- Async definition: definition -> declaration -> GTAGS, all non-blocking for
--- the LSP parts.
function M.definition()
  local symbol = current_symbol()
  local bufnr = vim.api.nvim_get_current_buf()

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
    if try_jump(locations, "LSP definitions") then
      return
    end

    -- Async fallback: textDocument/declaration
    local has_decl_client = #vim.lsp.get_clients({ bufnr = bufnr, method = "textDocument/declaration" }) > 0
    if has_decl_client then
      async_lsp_request(bufnr, "textDocument/declaration", function(decl_locations)
        if try_jump(decl_locations, "LSP declarations") then
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
-- References (kept synchronous — usually fast enough, and results go to qf)
-- ---------------------------------------------------------------------------

function M.references()
  local symbol = current_symbol()
  if not symbol then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end

  local locations = sync_locations("textDocument/references", 5000)
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
