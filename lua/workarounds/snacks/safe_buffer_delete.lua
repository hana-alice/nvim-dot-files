-- WORKAROUND
-- name: snacks.safe_buffer_delete
-- scope: snacks
-- issue: internal: Snacks 2.31.0 deletes revisions arriving during confirmation and window replacement
-- symptom: Closing a dirty buffer can silently discard text typed after the discard prompt opened
-- introduced: 2026-10-04
-- removal_condition: when upstream bufdelete protects confirmation and deletion-event revisions
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Patch the shared public owner, so inherited bd/all/other and buffer picker
-- deletion use the same protection as the local close key. No global API patch.
local M = {}
local target, original

function M.apply()
  if target then
    return
  end
  local ok, module = pcall(require, "snacks.bufdelete")
  if not ok then
    return
  end
  target, original = module, module.delete
  target.delete = require("utils.safe_buffer_close").delete
end

function M.disable()
  if target and target.delete == require("utils.safe_buffer_close").delete then
    target.delete = original
  end
  target, original = nil, nil
end

function M.status()
  return { applied = target ~= nil and target.delete == require("utils.safe_buffer_close").delete }
end

return M
