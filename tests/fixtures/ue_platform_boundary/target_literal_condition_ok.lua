local M = {}

function M.install(target)
  if target == "Android" then
    return true
  end
  return false
end

return M
