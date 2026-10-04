-- WorkspaceEdit input/URI identity normalization. No target buffers are changed.
local M = {}
local uv = vim.uv or vim.loop
local path_key = require("utils.platform").driver().path_key
local LIMIT = { files = 128, bytes = 2 * 1024 * 1024, total = 8 * 1024 * 1024, edits = 10000 }

local function same(a, b)
  return vim.deep_equal(a, b)
end
local function present(value)
  return value ~= nil and value ~= vim.NIL
end
local function integer(value)
  return type(value) == "number" and value >= 0 and value % 1 == 0
end

local function canonical(path)
  return path_key(uv.fs_realpath(path) or path)
end

function M.same_document(uri, path)
  if type(uri) ~= "string" or not uri:match("^file:") then
    return false
  end
  local ok, decoded = pcall(vim.uri_to_fname, uri)
  return ok and canonical(decoded) == canonical(path)
end

function M.documents(edit)
  if type(edit) ~= "table" then
    return nil, "workspace-edit-missing"
  end
  local result, count = {}, 0
  if present(edit.documentChanges) then
    if
      type(edit.documentChanges) ~= "table"
      or not vim.islist(edit.documentChanges)
      or (present(edit.changes) and next(edit.changes))
    then
      return nil, "invalid-workspace-edit"
    end
    for _, change in ipairs(edit.documentChanges) do
      if type(change) ~= "table" or present(change.kind) then
        return nil, "resource-operations-unsupported"
      end
      local doc = change.textDocument
      if type(doc) ~= "table" then
        return nil, "invalid-text-document-edit"
      end
      result[#result + 1] =
        { uri = doc.uri, version = present(doc.version) and doc.version or nil, edits = change.edits }
    end
  elseif present(edit.changes) then
    if type(edit.changes) ~= "table" then
      return nil, "invalid-workspace-edit"
    end
    for uri, edits in pairs(edit.changes) do
      result[#result + 1] = { uri = uri, edits = edits }
    end
  end
  if #result == 0 or #result > LIMIT.files then
    return nil, "empty-edit-or-file-limit"
  end
  local seen, unique = {}, {}
  for _, doc in ipairs(result) do
    if type(doc.uri) ~= "string" or not doc.uri:match("^file:") then
      return nil, "non-file-uri-unsupported"
    end
    local ok, path = pcall(vim.uri_to_fname, doc.uri)
    if not ok or path == "" then
      return nil, "invalid-file-uri"
    end
    doc.path = vim.fs.normalize(path)
    local key = canonical(doc.path)
    if doc.version ~= nil and not integer(doc.version) then
      return nil, "invalid-document-version"
    end
    if type(doc.edits) ~= "table" or not vim.islist(doc.edits) then
      return nil, "invalid-text-edits"
    end
    count = count + #doc.edits
    local previous = seen[key]
    if previous then
      -- A server can return both a native short-name URI and its real path.
      -- They are one file only when the exact edit/version agrees; applying
      -- both would shift ranges twice. Conflicting/sequential documents refuse.
      if previous.uri == doc.uri or previous.version ~= doc.version or not same(previous.edits, doc.edits) then
        return nil, "duplicate-text-document"
      end
    else
      seen[key], unique[#unique + 1] = doc, doc
    end
  end
  if count == 0 or count > LIMIT.edits then
    return nil, "empty-edit-or-edit-limit"
  end
  table.sort(unique, function(a, b)
    return a.path < b.path
  end)
  return unique
end

function M.limits()
  return vim.deepcopy(LIMIT)
end

M.canonical = canonical

return M
