local M = {}

function M.detect()
  if vim.fn.has("win32") == 1 then
    return false
  end
  return true
end

return M
