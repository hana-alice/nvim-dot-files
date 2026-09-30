-- clangd symbolInfo includes alias underlyings and macro expansions, whereas
-- definition follows the written referent. Preserve that compiler-owned relation.
local M = {}
local location = require("utils.ue_goto.location")
local transport = require("utils.ue_goto.lsp_transport")

local function covers_clients(records, expected)
  local seen = {}
  for _, record in ipairs(records or {}) do
    if not expected[record.client_id] or seen[record.client_id] then
      return false
    end
    seen[record.client_id] = true
  end
  return vim.tbl_count(seen) == vim.tbl_count(expected)
end

local function select_identity(result, usr)
  result.usr, result.client_ids = usr, {}
  result.declarations, result.definitions, result.exact_command = {}, {}, nil
  for _, record in ipairs(result.client_results or {}) do
    local selected = false
    for _, identity in ipairs(record.identities or {}) do
      if identity.usr == usr then
        selected = true
        vim.list_extend(result.declarations, identity.declarations)
        vim.list_extend(result.definitions, identity.definitions)
      end
    end
    if selected then
      result.client_ids[#result.client_ids + 1] = record.client_id
      result.exact_command = result.exact_command or record.exact_command
    end
  end
  result.declarations = location.dedup_locations(result.declarations)
  result.definitions = location.dedup_locations(result.definitions)
  result.reason = "ok"
end

function M.resolve(bufnr, result, callback, opts)
  if result.reason ~= "ok" and result.reason ~= "identity-conflict" then
    callback(result)
    return
  end
  local macros, all_ids = {}, {}
  for _, identity in ipairs(result.identities or {}) do
    -- USRGeneration.cpp: c: + optional filename@offset + @macro@ + name.
    -- A namespace called macro also appears in ordinary variable/function USRs.
    if identity.usr:match("^c:@macro@[^@#]+$") or identity.usr:match("^c:[^@]+@%d+@macro@[^@#]+$") then
      macros[#macros + 1] = identity.usr
    end
    for _, id in ipairs(identity.client_ids) do
      all_ids[id] = true
    end
  end
  if #macros == 1 then
    -- XRefs.cpp locateSymbolAt() returns the macro before inspecting its
    -- expansion. Macros have no separate declaration and no symbolInfo ranges.
    local usr = macros[1]
    local unanimous = true
    for _, record in ipairs(result.client_results or {}) do
      local found = false
      for _, identity in ipairs(record.identities or {}) do
        if identity.usr == usr then
          found = true
        end
      end
      if not found then
        unanimous = false
      end
    end
    if unanimous then
      select_identity(result, usr)
      result.entity_kind = "macro"
    end
    callback(result)
    return
  end
  if #macros > 1 or #(result.definitions or {}) > 0 then
    callback(result)
    return
  end
  local request_opts = vim.tbl_extend("force", {}, opts, { client_ids = vim.tbl_keys(all_ids) })
  transport.request(bufnr, "textDocument/ast", function(ast)
    if ast.reason == "provider-cancelled" then
      callback(ast)
      return
    end
    if not covers_clients(ast.client_results, all_ids) then
      callback(result)
      return
    end
    local kind
    for _, record in ipairs(ast.client_results or {}) do
      local node = record.result or {}
      local current = node.kind == "Typedef" and node.role == "type" and "type-alias"
        or node.kind == "Namespace" and node.role == "specifier" and "namespace"
      if record.error or not current or (kind and current ~= kind) then
        callback(result)
        return
      end
      kind = current
    end
    if not kind then
      callback(result)
      return
    end
    result.referent_ast = ast
    if result.usr then
      result.entity_kind = kind
      callback(result)
      return
    end
    -- The alias's declaration location, not response order or display name,
    -- must join the unique compiler destination to exactly one canonical USR.
    transport.async_lsp_request(bufnr, "textDocument/definition", function(definition)
      if definition.reason == "provider-cancelled" then
        callback(definition)
        return
      end
      if definition.reason ~= "ok" or #definition.locations ~= 1 then
        callback(result)
        return
      end
      if not covers_clients(definition.client_results, all_ids) then
        callback(result)
        return
      end
      local target = location.location_key(definition.locations[1]):lower()
      local matching, sources = {}, {}
      for _, record in ipairs(result.client_results or {}) do
        sources[record.client_id] = record
      end
      for _, record in ipairs(definition.client_results or {}) do
        local source = sources[record.client_id]
        local own_locations = record.locations or {}
        if
          record.error
          or not source
          or #own_locations ~= 1
          or location.location_key(own_locations[1]):lower() ~= target
        then
          callback(result)
          return
        end
        local own_usrs = {}
        for _, identity in ipairs(source.identities or {}) do
          for _, declaration in ipairs(identity.declarations) do
            if location.location_key(declaration):lower() == target then
              own_usrs[identity.usr] = true
            end
          end
        end
        if vim.tbl_count(own_usrs) ~= 1 then
          callback(result)
          return
        end
        matching[next(own_usrs)] = true
      end
      local usrs = vim.tbl_keys(matching)
      if #usrs == 1 then
        select_identity(result, usrs[1])
        result.entity_kind = kind
        result.referent_definition = definition
      end
      callback(result)
    end, request_opts)
  end, request_opts)
end

return M
