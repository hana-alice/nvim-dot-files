-- ue.core.proc — process / executable utilities lifted out of `lua/ue.lua`.
-- See ue.core.fs header for the Phase B "no behaviour change" rule.

local fs = require("ue.core.fs")

local M = {}

--- Locate the first runnable command from a list of candidates.
--- A candidate that contains a `/` is treated as a path and tested with
--- `fs.is_file`; otherwise it goes through `vim.fn.executable`.
---@param candidates string[]
---@return string? path
function M.first_executable(candidates)
  for _, candidate in ipairs(candidates or {}) do
    if candidate and candidate ~= "" then
      if candidate:find("/", 1, true) and fs.is_file(candidate) then
        return candidate
      end
      if vim.fn.executable(candidate) == 1 then
        return candidate
      end
    end
  end
  return nil
end

return M
