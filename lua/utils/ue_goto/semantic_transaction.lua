local location = require("utils.ue_goto.location")

local M = {}

local TERMINAL_STATES = {
  resolved = true,
  ["ambiguous-context"] = true,
  ["invalid-semantic-context"] = true,
  unavailable = true,
}

local STAGES = {
  snapshot = true,
  environment = true,
  context = true,
  catalog = true,
  tu = true,
  entity = true,
  provider = true,
  index = true,
  destination = true,
  jump = true,
  stale = true,
}

local REASONS = {
  ["active-compile-command-missing"] = true,
  ["already-at-definition"] = true,
  ["context-not-member"] = true,
  ["context-resolution-failed"] = true,
  ["definition-not-found"] = true,
  ["definition-resolved"] = true,
  ["declaration-resolved"] = true,
  ["macro-no-source-definition"] = true,
  ["definition-absent-in-complete-index"] = true,
  ["identity-conflict"] = true,
  ["identity-missing"] = true,
  ["index-incomplete"] = true,
  ["index-provider-not-ready"] = true,
  ["index-stale-for-module"] = true,
  ["jump-failed"] = true,
  ["multiple-definitions"] = true,
  ["provider-error"] = true,
  ["provider-method-unsupported"] = true,
  ["provider-timeout"] = true,
  ["provider-unavailable"] = true,
  ["query-file-not-in-tu"] = true,
  ["semantic-cursor-invalid"] = true,
  ["semantic-sidecar-unavailable"] = true,
  ["semantic-tu-unavailable"] = true,
  ["stale-request"] = true,
  ["target-is-current-declaration"] = true,
  ["unknown"] = true,
}

local function snapshot_subject(snapshot, bufnr)
  if snapshot and snapshot.subject then
    return snapshot.subject
  end
  local path = location.normalize_path(
    (snapshot and snapshot.path) or vim.api.nvim_buf_get_name(bufnr))
  local uri = (snapshot and snapshot.uri) or vim.uri_from_fname(path)
  local cursor = snapshot and snapshot.cursor or vim.api.nvim_win_get_cursor(0)
  return {
    bufnr = bufnr,
    path = path,
    uri = uri,
    line = (snapshot and snapshot.line) or cursor[1],
    column0 = (snapshot and snapshot.column0) or cursor[2],
    line0 = (snapshot and snapshot.line0) or (cursor[1] - 1),
    document_version = snapshot and snapshot.document_version or vim.api.nvim_buf_get_changedtick(bufnr),
    changedtick = snapshot and snapshot.changedtick or vim.api.nvim_buf_get_changedtick(bufnr),
  }
end

local function owned_copy(value)
  if type(value) ~= "table" then return value end
  return vim.deepcopy(value)
end

local function make_subject(bufnr, snapshot)
  local subject = owned_copy(snapshot_subject(snapshot, bufnr))
  subject.bufnr = bufnr
  if subject.line_text == nil then
    subject.line_text = vim.api.nvim_buf_get_lines(bufnr, subject.line0, subject.line0 + 1, false)[1]
  end
  return subject
end

function M.create(opts)
  opts = opts or {}
  local snapshot = opts.snapshot or {}
  local bufnr = opts.bufnr or snapshot.bufnr or vim.api.nvim_get_current_buf()
  return {
    snapshot = owned_copy(snapshot),
    subject = make_subject(bufnr, snapshot),
    build = owned_copy(opts.build or {}),
    context = owned_copy(opts.context or {}),
    entity = owned_copy(opts.entity or {}),
    index = owned_copy(opts.index or {}),
    evidence = owned_copy(opts.evidence or {}),
    symbol = opts.symbol,
    _finished = false,
    _result = nil,
    result = nil,
  }
end

function M.make_position_params(tx, _bufnr, position_encoding)
  local subject = snapshot_subject(tx, _bufnr)
  return {
    textDocument = { uri = subject.uri },
    position = {
      line = subject.line0,
      character = subject.line_text and vim.str_utfindex(
        subject.line_text, position_encoding or "utf-16", subject.column0, false) or subject.column0,
    },
    _position_encoding = position_encoding,
  }
end

function M.same_subject_location(tx, value)
  if not tx or not value then return false end
  if location.normalize_path(location.location_path(value)):lower() ~= tx.subject.path:lower() then
    return false
  end
  local range = value.targetSelectionRange or value.targetRange or value.range
  if not range or not range.start then return false end
  local position = M.make_position_params(tx, tx.subject.bufnr, value._position_encoding).position
  local first, last = range.start, range["end"]
  local column = tonumber(first.character) or 0
  if first.line == position.line and column == position.character then return true end
  if not last then return false end
  return (position.line > first.line or (position.line == first.line and position.character >= column))
    and (position.line < last.line or (position.line == last.line and position.character < (last.character or 0)))
end

function M.subject_role(tx, declaration, definition)
  if definition and M.same_subject_location(tx, definition) then
    return "definition"
  end
  if declaration and M.same_subject_location(tx, declaration) then
    return "declaration"
  end
  return "reference"
end

function M.filter_definition_locations(tx, locations, declaration)
  local declaration_key = declaration and location.location_key(declaration):lower() or nil
  local filtered = {}
  for _, item in ipairs(locations or {}) do
    local is_subject = M.same_subject_location(tx, item)
    local is_declaration = declaration_key and location.location_key(item):lower() == declaration_key
    if not is_subject and not is_declaration then
      filtered[#filtered + 1] = item
    end
  end
  return filtered
end

function M.terminal(state, stage, reason, extra)
  vim.validate({
    state = { state, function(value) return TERMINAL_STATES[value] == true end, "terminal state" },
    stage = { stage, function(value) return STAGES[value] == true end, "transaction stage" },
    reason = { reason, function(value) return REASONS[value] == true end, "transaction reason" },
  })
  if stage == "stale" and reason ~= "stale-request" then
    error("stale stage must use stale-request")
  end
  if state == "resolved" and stage ~= "jump" then
    error("resolved terminal state must complete at jump stage")
  end
  if state == "resolved" then
    local evidence = extra or {}
    local target = evidence.location or {}
    local range = target.targetSelectionRange or target.targetRange or target.range or {}
    local position = range.start or {}
    assert(type(evidence.identity) == "string" and evidence.identity ~= "", "resolved identity evidence is required")
    assert(type(evidence.provider) == "string" and evidence.provider ~= "", "resolved provider evidence is required")
    assert(type(target.uri or target.targetUri) == "string" and (target.uri or target.targetUri) ~= ""
      and type(position.line) == "number" and position.line >= 0
      and type(position.character) == "number" and position.character >= 0, "resolved destination evidence is required")
    assert(evidence.destination_role == "definition" or evidence.destination_role == "declaration", "resolved role is required")
    assert(evidence.destination_role ~= "declaration" or reason ~= "definition-resolved", "a declaration is not a definition")
    assert(type(evidence.metrics) == "table" and type(evidence.metrics.source) == "string"
      and evidence.metrics.source ~= "", "resolved metric provenance is required")
  end
  local result = vim.tbl_extend("force", owned_copy(extra or {}), {
    state = state,
    stage = stage,
    reason = reason,
  })
  return result
end

function M.finish_once(tx, result, on_finish)
  if tx._finished then return false end
  tx._finished = true
  tx._result = owned_copy(result)
  tx.result = tx._result
  if on_finish then on_finish(tx._result) end
  return true
end

function M.last_result(tx)
  return tx and tx._result or nil
end

M.TERMINAL_STATES = TERMINAL_STATES
M.STAGES = STAGES
M.REASONS = REASONS

return M
