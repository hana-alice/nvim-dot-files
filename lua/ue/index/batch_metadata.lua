-- Only a missing file or an explicitly empty legacy receipt list is ordinary.
local M = {}

function M.is_ordinary(path)
  local stat, _, code = vim.uv.fs_stat(path)
  if not stat then return code == "ENOENT" end
  local file = io.open(path, "rb")
  if not file then return false end
  local bytes = file:read("*a")
  file:close()
  local ok, info = pcall(vim.json.decode, bytes or "")
  return ok and type(info) == "table" and info.schema == 1
    and type(info.receipts) == "table" and next(info.receipts) == nil
end

return M
