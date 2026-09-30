-- WORKAROUND
-- name: clangd.header_path_case
-- scope: clangd
-- issue: internal: clangd 22.1.5 Windows header URI casing differs between SymbolCollector and IncludeGraph
-- symptom: A differently cased include silently leaves the real header shard without symbols or references.
-- introduced: 2026-09-21
-- removal_condition: The native mixed-case include regression preserves header symbols and references without this overlay on a verified upstream version.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local enabled = false
function M.apply() enabled = true end
function M.disable() enabled = false end
function M.status() return { applied = enabled } end

function M.configure_steps(steps, python, cdb, clangd, logical_cdb, engine_root, project_root)
  if not enabled or require("utils.platform").driver().id ~= "windows" then return end
  local command = { python, "-u", "-I", vim.fn.stdpath("config") .. "/lua/workarounds/clangd/header_path_case.py",
    cdb, "--clangd", clangd or "", "--logical-cdb", logical_cdb or cdb }
  for _, root in ipairs({ engine_root or "", project_root or "" }) do
    if root ~= "" then vim.list_extend(command, { "--scope-root", root }) end
  end
  local position = 1
  for i, step in ipairs(steps) do
    if step.name == "expand_response_cdb" or step.name == "clangd_diagnostic_compat" then position = i + 1 end
  end
  local strip = vim.deepcopy(command)
  strip[#strip + 1] = "--strip-owned"
  table.insert(steps, position, { name = "clangd_header_path_case_strip", command = strip })
  steps[#steps + 1] = { name = "clangd_header_path_case", command = command }
end

return M
