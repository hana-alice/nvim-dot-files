local M = {}

function M.detect()
  if vim.fn.has("win32") == 1 then
    return "windows"
  end
  return "other"
end

return M
