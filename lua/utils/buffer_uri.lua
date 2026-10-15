-- Classify buffer identity before path normalization can collapse :// to :/.
local M = {}

function M.is_file_name(name)
  if type(name) ~= "string" or name == "" then return false end
  local path = name:gsub("\\", "/")
  if path:match("^%a:/") and path:sub(4, 4) ~= "/" then return true end
  local scheme = path:match("^(%a[%w+.-]*):")
  return not scheme or scheme:lower() == "file"
end

function M.is_file_buffer(buf)
  return vim.api.nvim_buf_is_valid(buf) and M.is_file_name(vim.api.nvim_buf_get_name(buf))
end

return M
