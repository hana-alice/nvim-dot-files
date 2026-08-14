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

function M.shell_entry(kind)
  if kind == nil or kind == "default" then
    return M.shell()
  end
  return nil, "unsupported shell on stub host: " .. tostring(kind)
end

function M.open_path(_) end
function M.reveal_file(_) end
function M.default_clangd_candidates() return {} end
function M.python_candidates() return { "python3", "python" } end
function M.default_lldb_dap_paths() return {} end
function M.default_lldb_server_paths() return {} end
function M.cmd_quote(value) return tostring(value or "") end
function M.host_path(path) return tostring(path or "") end
function M.default_target() return "" end
function M.launch_process_plan(_)
  return { status = "unavailable", reason = "process launch unavailable on stub host" }
end
function M.follow_file_plan(_)
  return nil, "file following unavailable on stub host"
end
function M.ue_build_entry(_) return nil, "unavailable" end
function M.ue_uat_entry(_) return nil, "unavailable" end

return M
