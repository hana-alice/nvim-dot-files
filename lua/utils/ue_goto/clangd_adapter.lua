-- Exact-command preparation and compiler-owned identity/role evidence.
local M = {}
local transport = require("utils.ue_goto.lsp_transport")
local location = require("utils.ue_goto.location")

local function options(opts)
  local result = vim.tbl_extend("force", {}, opts or {})
  result.prepare_client = function(client, bufnr, callback, request_opts)
    require("ue.clangd_commands").ensure(client, bufnr, callback, request_opts)
  end
  return result
end

function M.async_lsp_request(bufnr, method, callback, opts)
  return transport.async_lsp_request(bufnr, method, function(result)
    if opts and opts.structured then
      for _, record in ipairs(result.client_results) do record.exact_command = record.context end
    end
    callback(result)
  end, options(opts))
end

function M.async_clangd_symbol_info(bufnr, callback, opts)
  local request_opts = options(opts)
  request_opts.client_filter = function(client)
    return tostring(client.name or ""):lower():find("clangd", 1, true) ~= nil
  end
  return transport.request(bufnr, "textDocument/symbolInfo", function(result)
    local usr_clients = {}
    for _, record in ipairs(result.client_results) do
      record.exact_command = record.context
      record.identities = {}
      local raw = record.result
      if not record.error and type(raw) == "table" then
        local local_usrs = {}
        for _, item in ipairs(raw.usr and { raw } or raw) do
          if type(item) == "table" and type(item.usr) == "string" and item.usr ~= "" then
            usr_clients[item.usr] = usr_clients[item.usr] or {}
            if record.client_id then usr_clients[item.usr][record.client_id] = true end
            local_usrs[item.usr] = true
            record.identities[#record.identities + 1] = {
              usr = item.usr, id = item.id,
              declarations = location.normalize_locations(item.declarationRange, record.position_encoding),
              definitions = location.normalize_locations(item.definitionRange, record.position_encoding),
            }
          end
        end
        if vim.tbl_count(local_usrs) == 1 then record.identity = record.identities[1] end
      end
    end
    result.identities, result.client_ids, result.declarations, result.definitions = {}, {}, {}, {}
    local usrs = vim.tbl_keys(usr_clients)
    table.sort(usrs)
    for _, usr in ipairs(usrs) do
      local ids = vim.tbl_keys(usr_clients[usr])
      table.sort(ids)
      result.identities[#result.identities + 1] = { usr = usr, client_ids = ids }
    end
    if result.reason == "provider-cancelled" then
      if opts and opts.structured then callback(result) else callback(nil, {}) end
      return
    end
    if #usrs == 1 then
      result.usr = usrs[1]
      result.client_ids = result.identities[1].client_ids
      result.reason = "ok"
      for _, record in ipairs(result.client_results) do
        for _, identity in ipairs(record.identities) do
          result.exact_command = result.exact_command or record.exact_command
          vim.list_extend(result.declarations, identity.declarations)
          vim.list_extend(result.definitions, identity.definitions)
        end
      end
      result.declarations = location.dedup_locations(result.declarations)
      result.definitions = location.dedup_locations(result.definitions)
    elseif #usrs > 1 then result.reason = "identity-conflict"
    elseif result.reason == "empty" then result.reason = "identity-missing" end
    if opts and opts.structured then callback(result) else callback(result.usr, result.client_ids) end
  end, request_opts)
end

return M
