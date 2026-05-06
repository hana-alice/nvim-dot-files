-- utils.platform.stub — empty driver returned when no concrete driver is
-- available for the running platform. Every method is a safe no-op so
-- callers fail soft instead of crashing nvim startup.

local M = {
  id          = "stub",
  path_sep    = package.config:sub(1, 1),
  list_sep    = (package.config:sub(1, 1) == "\\") and ";" or ":",
  exe_suffix  = "",
}

function M.shell()
  return vim.o.shell ~= "" and vim.o.shell or "sh"
end

function M.open_path(_) end
function M.reveal_file(_) end
function M.default_clangd_candidates() return {} end
function M.default_codelldb_paths() return {} end
function M.default_lldb_server_paths() return {} end
function M.cmd_quote(value) return tostring(value or "") end

return M
