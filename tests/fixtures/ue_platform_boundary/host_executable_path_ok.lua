local M = {}

function M.build()
  return {
    executable = "cmd.exe",
    args = { "/c", "Build.bat" },
  }
end

return M
