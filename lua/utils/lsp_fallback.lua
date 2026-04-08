local M = {}

local function current_symbol()
  local word = vim.fn.expand("<cword>")
  if word == nil or word == "" then
    return nil
  end
  return word
end

local function sync_locations(method, timeout_ms)
  local clients = vim.lsp.get_clients({ bufnr = 0, method = method })
  if not clients or vim.tbl_isempty(clients) then
    return nil
  end

  local params = vim.lsp.util.make_position_params(0, "utf-8")
  if method == "textDocument/references" then
    params.context = { includeDeclaration = true }
  end

  local responses = vim.lsp.buf_request_sync(0, method, params, timeout_ms or 800)
  if not responses then
    return nil
  end

  local items = {}
  for _, response in pairs(responses) do
    if response.result and type(response.result) == "table" then
      vim.list_extend(items, response.result)
    end
  end
  return items
end

local function populate_quickfix(title, locations)
  local items = vim.lsp.util.locations_to_items(locations, "utf-8")
  if not items or vim.tbl_isempty(items) then
    return false
  end

  vim.fn.setqflist({}, " ", { title = title, items = items })
  vim.cmd("copen")
  return true
end

local function jump_to_location(location)
  local items = vim.lsp.util.locations_to_items({ location }, "utf-8")
  local item = items and items[1] or nil
  if not item then
    return false
  end

  vim.cmd("normal! m'")
  vim.cmd("edit " .. vim.fn.fnameescape(item.filename))
  vim.api.nvim_win_set_cursor(0, { item.lnum, math.max((item.col or 1) - 1, 0) })
  return true
end

local function jump_with_lsp(method, title, timeout_ms)
  local locations = sync_locations(method, timeout_ms)
  if not locations or #locations == 0 then
    return false
  end

  if #locations == 1 and jump_to_location(locations[1]) then
    return true
  end

  return populate_quickfix(title, locations)
end

function M.definition()
  for _, request in ipairs({
    { method = "textDocument/definition", title = "LSP definitions" },
    { method = "textDocument/declaration", title = "LSP declarations" },
  }) do
    if jump_with_lsp(request.method, request.title, 800) then
      return
    end
  end

  local symbol = current_symbol()
  if not symbol then
    vim.notify("No definition (LSP/GTAGS)", vim.log.levels.INFO)
    return
  end

  local ok, ue = pcall(require, "ue")
  if ok and ue.gtags_definition and ue.gtags_definition(symbol) then
    return
  end

  vim.notify("No definition (LSP/GTAGS)", vim.log.levels.INFO)
end

function M.references()
  local symbol = current_symbol()
  if not symbol then
    vim.notify("No symbol under cursor", vim.log.levels.WARN)
    return
  end

  local locations = sync_locations("textDocument/references", 800)
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
