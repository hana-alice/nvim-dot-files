-- WORKAROUND
-- name: clangd.friend_template_canonical
-- scope: clangd
-- issue: internal: clangd 22.1.5 friend-template canonical reference cache
-- symptom: Cached UE InternalConstructor references disappear or use specialization identities.
-- introduced: 2026-09-21
-- removal_condition: The cold/hot native references regression passes without the first forced declaration on a verified upstream version.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local enabled = false

function M.apply() enabled = true end
function M.disable() enabled = false end
function M.status() return { applied = enabled } end

-- The transaction supplies its resolved engine identity. The helper probes the
-- selected compiler and checks each actual command outside the UI thread.
function M.prepare_step(python, cdb, clangd, engine_root)
  if not enabled or type(engine_root) ~= "string" or engine_root == "" then return nil end
  return {
    name = "clangd_friend_template_canonical",
    command = { python, "-u", "-I",
      vim.fn.stdpath("config") .. "/lua/workarounds/clangd/friend_template_canonical.py",
      cdb, "--clangd", clangd or "", "--engine-root", engine_root },
  }
end

function M.configure_steps(steps, python, cdb, clangd, engine_root)
  local prefix = M.prepare_step(python, cdb, clangd, engine_root)
  if not prefix then return end
  local position = 1
  for index, step in ipairs(steps) do
    if step.name == "expand_response_cdb" or step.name == "clangd_diagnostic_compat" then position = index + 1 end
  end
  for index, step in ipairs(steps) do
    if step.name == "prebuild_pch_v2" then
      if index < position then
        vim.list_extend(prefix.command, { "--skip-reason", "unsupported-prepare-step-order" })
      end
      local wrapped = { python, "-u", "-I",
        vim.fn.stdpath("config") .. "/lua/workarounds/clangd/friend_template_canonical.py",
        cdb, "--pch-command" }
      vim.list_extend(wrapped, step.command)
      step.command = wrapped
    end
  end
  table.insert(steps, position, prefix)
end

return M
