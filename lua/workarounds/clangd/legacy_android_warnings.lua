-- WORKAROUND
-- name: clangd.legacy_android_warnings
-- scope: clangd
-- issue: internal: LLVM 22.1 Wall diagnostics reject code accepted by Android Clang 9.0.9
-- symptom: NDK r21 C++17 builds succeed while clangd treats VLAs and assigned-only variables as errors.
-- introduced: 2026-09-22
-- removal_condition: The selected build compiler and clangd agree on these diagnostic groups, or native regressions prove the compatibility flags unnecessary.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

local M = {}
local enabled = false
function M.apply() enabled = true end
function M.disable() enabled = false end
function M.status() return { applied = enabled } end

function M.configure_steps(steps, python, cdb, clangd)
  if not enabled or type(clangd) ~= "string" or clangd == "" then return end
  steps[#steps + 1] = {
    name = "clangd_legacy_android_warnings",
    command = { python, "-u", "-I",
      vim.fn.stdpath("config") .. "/lua/workarounds/clangd/legacy_android_warnings.py",
      cdb, "--clangd", clangd },
  }
end

return M
