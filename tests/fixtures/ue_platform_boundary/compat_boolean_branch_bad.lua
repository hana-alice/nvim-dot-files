local platform = require("utils.platform")

if platform.is_windows then
  return "cmd"
end

return "posix"
