local M = {}

function M.setup()
  if _G.Snacks ~= nil then
    return
  end

  _G.Snacks = setmetatable({}, {
    __index = function(_, key)
      return require("snacks")[key]
    end,
  })
end

return M
