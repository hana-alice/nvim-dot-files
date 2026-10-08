-- Compiler provenance for explicit header reading. File pairing never selects
-- a semantic donor by basename, receipt order, or directory distance.
local M = {}
local ownership = require("utils.ue_goto.reading_owner")
local model = require("utils.ue_goto.semantic_context")

local function scope(owner)
  local semantic = require("utils.ue_goto.semantic_client")
  local snapshot = semantic.begin_action(owner.buf, {
    is_current = function() return ownership.current(owner, true) end,
  })
  local environment, reason = semantic.discover_toolchain(owner.buf, { route = "header" })
  if not environment then return nil, reason end
  ownership.add_cleanup(owner, function() semantic.cancel_action() end)
  local function current(response)
    return ownership.current(owner, true) and semantic.snapshot_is_current(snapshot, response)
      and semantic.index_snapshot_is_current(environment.index, owner.buf)
  end
  semantic.capture_overlays(snapshot, environment)
  return { semantic = semantic, snapshot = snapshot, environment = environment, current = current }
end

function M.resolve_header(owner, choose_context, callback)
  local request, reason = scope(owner)
  if not request then callback(nil, { state = "unavailable", reason = reason }); return end
  request.semantic.resolve_header({
    snapshot = request.snapshot, environment = request.environment,
    path = owner.path, line = owner.cursor[1], column = owner.cursor[2] + 1,
    choose_context = choose_context,
  }, function(response)
    if not request.current(response) then return end
    local context = response and response.state == "resolved" and response.origin_context
    if type(context) ~= "table" or type(context.compile) ~= "table"
        or not model.context_supports_subject(context, owner.path) then
      callback(nil, response or { state = "unavailable", reason = "header-origin-unproven" })
      return
    end
    context = vim.deepcopy(context)
    callback({
      context = context, response = vim.deepcopy(response),
      environment = request.environment,
      compile_digest = vim.fn.sha256(vim.json.encode(context.compile)),
      is_current = function() return request.current(response) end,
    })
  end)
end

-- These outcomes are emitted only after the native compiler inclusion guard. They prove
-- inclusion for file switching, but do not prove a navigable C++ entity.
local included_outcomes = {
  ["invalid-cursor"] = true,
  ["invalid-null-referenced-cursor"] = true,
  ["invalid-empty-usr"] = true,
  ["invalid-declaration-location-missing"] = true,
  ["invalid-tu-diagnostics"] = true,
}

function M.file_in_tu(response, context_id)
  for _, context in ipairs(type(response) == "table" and response.contexts or {}) do
    if context.context_id == context_id and type(context.compile_command_fingerprint) == "string"
        and context.compile_command_fingerprint ~= ""
        and (context.state == "resolved" or (context.state == "invalid-semantic-context"
          and included_outcomes[context.reason])) then
      return true
    end
  end
  return false
end

function M.prove_companion(owner, source, header, callback)
  local request, reason = scope(owner)
  if not request then callback(false, reason); return end
  local environment, semantic = request.environment, request.semantic
  local id = vim.fn.sha256(vim.json.encode({ environment.build_fingerprint, source, header }))
  semantic.request("prove", {
    source = source, context_id = id, cdb_dir = environment.cdb_dir, cdb_path = environment.cdb_path,
    active_cdb_path = environment.active_cdb_path, active_manifest_path = environment.active_manifest_path,
  }, function(proof)
    if not request.current() then return end
    if not proof or proof.state ~= "resolved" or type(proof.compile) ~= "table" then
      callback(false, proof and proof.reason or "companion-source-unproven")
      return
    end
    semantic.request("query", {
      query = { path = header, line = 1, column = 1, document_version = request.snapshot.document_version },
      contexts = { { id = id, origin_tu = source, cdb_dir = environment.cdb_dir, compile = proof.compile } },
      overlays = request.snapshot.overlays,
    }, function(response)
      if not request.current(response) then return end
      local session = semantic.status().session
      local proven = response and type(response.compiler_session) == "table" and session
        and vim.deep_equal(response.compiler_session, session) and M.file_in_tu(response, id)
      callback(proven == true, proven and "compiler-inclusion" or "companion-header-inclusion-unproven")
    end, environment, request.snapshot)
  end, environment, request.snapshot)
end

return M
