local M = {}

M.VERSION = 1
M.MAX_LINE_BYTES = 1024 * 1024

local QUERY_STATES = {
  ["resolved"] = true,
  ["ambiguous-context"] = true,
  ["invalid-semantic-context"] = true,
  ["unavailable"] = true,
}

local REQUEST_OPS = {
  handshake = true,
  catalog = true,
  prove = true,
  query = true,
  stats = true,
  evict = true,
  shutdown = true,
}

local function is_array(value)
  if type(value) ~= "table" then return false end
  local n = #value
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key > n or key % 1 ~= 0 then
      return false
    end
  end
  return true
end

local function validate_location(loc)
  if type(loc) ~= "table" then
    return false, "location must be a table"
  end
  if type(loc.path) ~= "string" or loc.path == "" then
    return false, "location.path must be a non-empty string"
  end
  if type(loc.line) ~= "number" or loc.line < 1 then
    return false, "location.line must be >= 1"
  end
  if type(loc.column) ~= "number" or loc.column < 1 then
    return false, "location.column must be >= 1"
  end
  return true
end

local function validate_context(ctx)
  if type(ctx) ~= "table" then
    return false, "context must be a table"
  end
  if type(ctx.id) ~= "string" or ctx.id == "" then
    return false, "context.id must be a non-empty string"
  end
  if type(ctx.origin_tu) ~= "string" or ctx.origin_tu == "" then
    return false, "context.origin_tu must be a non-empty string"
  end
  if type(ctx.cdb_dir) ~= "string" or ctx.cdb_dir == "" then
    return false, "context.cdb_dir must be a non-empty string"
  end
  if ctx.compile ~= nil then
    if type(ctx.compile) ~= "table" then
      return false, "context.compile must be a table"
    end
    if type(ctx.compile.directory) ~= "string" or ctx.compile.directory == "" then
      return false, "context.compile.directory must be a non-empty string"
    end
    if type(ctx.compile.argv) ~= "table" or #ctx.compile.argv == 0 then
      return false, "context.compile.argv must be a non-empty array"
    end
    for _, arg in ipairs(ctx.compile.argv) do
      if type(arg) ~= "string" then return false, "context.compile.argv entries must be strings" end
    end
  end
  return true
end

local function validate_overlay(overlay)
  if type(overlay) ~= "table" then
    return false, "overlay must be a table"
  end
  if type(overlay.path) ~= "string" or overlay.path == "" then
    return false, "overlay.path must be a non-empty string"
  end
  if type(overlay.contents) ~= "string" then
    return false, "overlay.contents must be a string"
  end
  if overlay.version ~= nil and (type(overlay.version) ~= "number" or overlay.version < 0) then
    return false, "overlay.version must be nil or >= 0"
  end
  return true
end

function M.validate_request(frame)
  if type(frame) ~= "table" then
    return false, "frame must decode to a table"
  end
  if frame.v ~= M.VERSION then
    return false, "unsupported protocol version"
  end
  if frame.id == nil then
    return false, "request.id is required"
  end
  if type(frame.op) ~= "string" or not REQUEST_OPS[frame.op] then
    return false, "request.op is invalid"
  end

  if frame.op == "prove" then
    if type(frame.source) ~= "string" or frame.source == "" then
      return false, "prove.source must be a non-empty string"
    end
    if type(frame.cdb_dir) ~= "string" or frame.cdb_dir == "" then
      return false, "prove.cdb_dir must be a non-empty string"
    end
    if frame.cdb_path ~= nil and (type(frame.cdb_path) ~= "string" or frame.cdb_path == "") then
      return false, "prove.cdb_path must be nil or a non-empty string"
    end
    if frame.active_cdb_path ~= nil
        and (type(frame.active_cdb_path) ~= "string" or frame.active_cdb_path == "") then
      return false, "prove.active_cdb_path must be nil or a non-empty string"
    end
    if frame.active_manifest_path ~= nil
        and (type(frame.active_manifest_path) ~= "string" or frame.active_manifest_path == "") then
      return false, "prove.active_manifest_path must be nil or a non-empty string"
    end
  elseif frame.op == "catalog" then
    if type(frame.header) ~= "string" or frame.header == "" then
      return false, "catalog.header must be a non-empty string"
    end
    if type(frame.cdb_dir) ~= "string" or frame.cdb_dir == "" then
      return false, "catalog.cdb_dir must be a non-empty string"
    end
    if frame.active_cdb_path ~= nil
        and (type(frame.active_cdb_path) ~= "string" or frame.active_cdb_path == "") then
      return false, "catalog.active_cdb_path must be nil or a non-empty string"
    end
    if frame.active_manifest_path ~= nil
        and (type(frame.active_manifest_path) ~= "string" or frame.active_manifest_path == "") then
      return false, "catalog.active_manifest_path must be nil or a non-empty string"
    end
    if not is_array(frame.evidence_roots) or #frame.evidence_roots == 0 then
      return false, "catalog.evidence_roots must be a non-empty array"
    end
    for _, root in ipairs(frame.evidence_roots) do
      if type(root) ~= "string" or root == "" then
        return false, "catalog.evidence_roots entries must be non-empty strings"
      end
    end
  elseif frame.op == "query" then
    if type(frame.query) ~= "table" then
      return false, "query payload is required"
    end
    local ok, err = validate_location(frame.query)
    if not ok then return false, err end
    if frame.query.document_version ~= nil
      and (type(frame.query.document_version) ~= "number" or frame.query.document_version < 0)
    then
      return false, "query.document_version must be nil or >= 0"
    end
    if not is_array(frame.contexts) or #frame.contexts == 0 then
      return false, "query requires a non-empty contexts array"
    end
    for _, ctx in ipairs(frame.contexts) do
      local ctx_ok, ctx_err = validate_context(ctx)
      if not ctx_ok then return false, ctx_err end
    end
    if frame.overlays ~= nil then
      if not is_array(frame.overlays) then
        return false, "overlays must be an array"
      end
      for _, overlay in ipairs(frame.overlays) do
        local overlay_ok, overlay_err = validate_overlay(overlay)
        if not overlay_ok then return false, overlay_err end
      end
    end
  elseif frame.op == "evict" then
    if frame.context_ids ~= nil then
      if not is_array(frame.context_ids) then
        return false, "context_ids must be an array"
      end
      for _, id in ipairs(frame.context_ids) do
        if type(id) ~= "string" or id == "" then
          return false, "context_ids entries must be non-empty strings"
        end
      end
    end
  end

  return true
end

function M.validate_query_response(frame)
  if type(frame) ~= "table" then
    return false, "response must be a table"
  end
  if frame.v ~= M.VERSION then
    return false, "response version mismatch"
  end
  if frame.op ~= "query" then
    return false, "response.op must be query"
  end
  if not QUERY_STATES[frame.state] then
    return false, "response.state is invalid"
  end
  if type(frame.metrics) ~= "table" then
    return false, "response.metrics is required"
  end
  return true
end

function M.validate_response(frame)
  if type(frame) ~= "table" then
    return false, "response must be a table"
  end
  if frame.v ~= M.VERSION then
    return false, "response version mismatch"
  end
  if frame.id == nil then
    return false, "response.id is required"
  end
  if type(frame.op) ~= "string" then
    return false, "response.op is required"
  end
  if frame.op == "protocol-error" or frame.ok == false then
    if type(frame.error) ~= "table" then
      return false, "error response requires error payload"
    end
    return true, frame
  end
  if frame.op == "query" then
    local ok, err = M.validate_query_response(frame)
    if not ok then return false, err end
  elseif frame.op == "catalog" then
    if not QUERY_STATES[frame.state] then
      return false, "catalog response.state is invalid"
    end
    if not is_array(frame.contexts or {}) then
      return false, "catalog response.contexts must be an array"
    end
  elseif frame.op == "handshake" then
    if type(frame.ok) ~= "boolean" then
      return false, "handshake response.ok is required"
    end
  elseif frame.op == "prove" then
    if not QUERY_STATES[frame.state] then
      return false, "prove response.state is invalid"
    end
    if frame.state == "resolved" then
      if type(frame.context_id) ~= "string" or frame.context_id == "" then
        return false, "resolved prove response.context_id is required"
      end
      if type(frame.origin_tu) ~= "string" or frame.origin_tu == "" then
        return false, "resolved prove response.origin_tu is required"
      end
      local compile = frame.compile
      if type(compile) ~= "table"
          or type(compile.file) ~= "string" or compile.file == ""
          or type(compile.directory) ~= "string" or compile.directory == ""
          or not is_array(compile.argv) or #compile.argv == 0 then
        return false, "resolved prove response.compile is invalid"
      end
      for _, arg in ipairs(compile.argv) do
        if type(arg) ~= "string" then
          return false, "resolved prove response.compile.argv entries must be strings"
        end
      end
    end
  elseif frame.op ~= "stats" and frame.op ~= "evict" and frame.op ~= "shutdown" then
    return false, "response.op is invalid"
  end
  return true, frame
end

function M.encode(frame)
  return vim.json.encode(frame) .. "\n"
end

function M.protocol_error(id, code, message, detail)
  return {
    v = M.VERSION,
    id = id or vim.NIL,
    op = "protocol-error",
    ok = false,
    error = {
      code = code,
      message = message,
      detail = detail,
    },
  }
end

function M.request_error(request, code, message, detail)
  return {
    v = M.VERSION,
    id = request and request.id or vim.NIL,
    op = request and request.op or "unknown",
    ok = false,
    error = {
      code = code,
      message = message,
      detail = detail,
    },
  }
end

function M.new_decoder(opts)
  opts = opts or {}
  local state = {
    buffer = "",
    on_frame = assert(opts.on_frame, "on_frame is required"),
    on_error = assert(opts.on_error, "on_error is required"),
  }

  local function emit_error(id, code, message, detail)
    state.on_error(M.protocol_error(id, code, message, detail))
  end

  local function consume_line(line)
    if line == "" then return end
    local ok, decoded = pcall(vim.json.decode, line)
    if not ok then
      emit_error(nil, "invalid-json", "failed to decode NDJSON frame", {
        raw = line,
        decode_error = decoded,
      })
      return
    end
    local valid, err = M.validate_request(decoded)
    if not valid then
      emit_error(decoded.id, "invalid-request", err, { frame = decoded })
      return
    end
    state.on_frame(decoded)
  end

  local decoder = {}

  function decoder:push(chunk)
    if type(chunk) ~= "string" or chunk == "" then return end
    state.buffer = state.buffer .. chunk
    if #state.buffer > M.MAX_LINE_BYTES and not state.buffer:find("\n", 1, true) then
      emit_error(nil, "line-too-long", "protocol line exceeded max size", {
        max_bytes = M.MAX_LINE_BYTES,
      })
      state.buffer = ""
      return
    end
    while true do
      local newline = state.buffer:find("\n", 1, true)
      if not newline then break end
      local line = state.buffer:sub(1, newline - 1)
      if line:sub(-1) == "\r" then
        line = line:sub(1, -2)
      end
      state.buffer = state.buffer:sub(newline + 1)
      consume_line(line)
    end
  end

  function decoder:finish()
    if state.buffer == "" then return end
    local tail = state.buffer
    state.buffer = ""
    consume_line(tail)
  end

  return decoder
end

return M
