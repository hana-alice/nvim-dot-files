-- WORKAROUND
-- name: neogit.codediff_v4
-- scope: neogit
-- issue: internal: Neogit 792c139 uses the pre-v4 CodeDiff SessionConfig API and commit^ for root commits
-- symptom: Neogit diffs fail with CodeDiff v4 or a root commit instead of opening full-file review
-- introduced: 2026-09-29
-- removal_condition: pinned Neogit supports CodeDiff v4 Path/panel sessions and root commit comparisons
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Keep Neogit's selection semantics and refresh callback, while delegating
-- session creation and root-commit handling to the shared review entry point.
local M = {}
local integration, original_open

local function reject(message)
  vim.notify("Neogit review: " .. message, vim.log.levels.ERROR)
  return false
end

local function reference(value)
  if type(value) ~= "string" then return nil end
  local trimmed = vim.trim(value)
  if trimmed == "" then return nil end
  return trimmed:match("(stash@{%d+})") or trimmed
end

function M.open(section, item, opts)
  local root = require("neogit.lib.git").repo.worktree_root
  if type(root) ~= "string" or root == "" then return reject("Git root is unavailable") end
  local review = require("utils.git_review")
  local args = { root = root }
  local action, first, second
  if section == "staged" or section == "unstaged" or section == "merge"
      or section == "worktree" or section == "conflict" or (section == nil and item == nil) then
    action = "open"
    args.path = type(item) == "table" and item[1] or item
    args.staged = section == "staged"
  elseif section == "range" then
    local range = reference(item)
    if not range then return reject("Invalid comparison range") end
    first, second = range:match("^(.-)%.%.%.(.-)$")
    if first then
      args.merge_base = true
      second = reference(second) or "HEAD"
    else
      first, second = range:match("^(.-)%.%.(.-)$")
    end
    first, second = reference(first), reference(second)
    if not first or not second then return reject("Invalid comparison range: " .. range) end
    action = "compare"
  elseif section == "recent" or section == "log" or (section and section:match("unmerged$")) then
    if type(item) == "table" then
      first, second = reference(item[1]), reference(item[#item])
      if not first or not second then return reject("Invalid commit selection") end
      action = "compare"
    else
      first = reference(item)
      first = first and first:match("^([0-9a-fA-F]+)")
      if not first then return reject("Invalid commit selection") end
      action = "commit"
    end
  elseif section == "commit" or section == "stashes" or section == nil then
    first = reference(item)
    if not first then return reject("Invalid commit reference") end
    action = "commit"
  else
    return reject("Unsupported section: " .. tostring(section))
  end

  -- Match Neogit's on_close contract: refresh once when its status buffer is
  -- re-entered, whether review closed normally or the user changed tabs.
  local on_close = opts and opts.on_close
  if on_close and type(on_close.handle) == "number" and vim.api.nvim_buf_is_valid(on_close.handle)
      and type(on_close.fn) == "function" then
    vim.api.nvim_create_autocmd("BufEnter", {
      buffer = on_close.handle,
      once = true,
      callback = on_close.fn,
    })
  end
  if action == "compare" then return review.compare(first, second, args) end
  if action == "commit" then return review.commit(first, args) end
  return review.open(args)
end

function M.apply()
  if integration then return end
  -- Registry discovery must not eagerly load the lazy Git UI on startup.
  if not package.loaded["neogit"] then return end
  integration = require("neogit.integrations.codediff")
  original_open = integration.open
  integration.open = M.open
end

function M.disable()
  if integration and integration.open == M.open then integration.open = original_open end
  integration, original_open = nil, nil
end

function M.status()
  return { applied = integration ~= nil and integration.open == M.open }
end

return M
