-- Shared platform detection flags. Require once, use everywhere.
-- Avoids scattering `vim.fn.has("win32")` checks across dozens of files.
local M = {}

M.is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1
M.is_mac     = vim.fn.has("mac") == 1 or vim.fn.has("macunix") == 1
M.is_linux   = (not M.is_windows) and (not M.is_mac) and (vim.fn.has("unix") == 1)

return M
