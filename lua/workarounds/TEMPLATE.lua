-- WORKAROUND
-- name: scope.short_name
-- scope: neovide|snacks|treesitter|clangd|lazyvim|windows|...
-- issue: https://github.com/.../issues/N   (or "internal: <one-line>")
-- symptom: one sentence describing what the user sees if missing
-- introduced: YYYY-MM-DD
-- removal_condition: when this can be deleted
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- Brief explanation of what the workaround does and why the proper fix
-- isn't possible right now (upstream PR pending, version too old, etc.)

local M = {}

local applied = false

function M.apply()
  if applied then return end
  applied = true

  -- ... the actual workaround code ...
end

function M.disable()
  -- Optional: undo runtime side effects. Leave as no-op if not applicable.
end

function M.status()
  return { applied = applied }
end

return M
