-- Shared platform detection flags. Require once, use everywhere.
-- Avoids scattering `vim.fn.has("win32")` checks across dozens of files.
local M = {}

M.is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

return M
