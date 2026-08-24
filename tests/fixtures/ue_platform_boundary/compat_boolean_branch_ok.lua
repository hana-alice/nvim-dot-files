local M = {}

function M.describe(platform)
  return platform.is_windows and "windows" or "other"
end

return M
