-- WORKAROUND
-- name: dap.pid_scoped_logs
-- scope: dap
-- issue: https://github.com/mfussenegger/nvim-dap/blob/master/lua/dap/log.lua
-- symptom: Two Neovim processes open the same stdpath('cache')/dap*.log with w+ and truncate each other's diagnostics.
-- introduced: 2026-08-13
-- removal_condition: nvim-dap exposes a configurable log directory/name or scopes every logger by Neovim process.
-- owner: hana-alice
-- enabled: true
-- END WORKAROUND

-- nvim-dap creates every logger eagerly and opens its fixed cache path with
-- `w+`. Install this before `require("dap")`, so the upstream logger registry
-- receives PID-scoped names for the main, stdout and stderr logs.

local M = {}

local function scoped_name(filename, pid)
  filename = tostring(filename or "dap.log")
  pid = tostring(pid)
  if filename:match("%." .. vim.pesc(pid) .. "%.log$") then return filename end
  local stem = filename:match("^(.*)%.log$")
  return stem and (stem .. "." .. pid .. ".log") or (filename .. "." .. pid)
end

local function install(log, pid)
  if type(log) ~= "table" or type(log.create_logger) ~= "function" then
    return false, "dap.log.create_logger is unavailable"
  end
  if log._nvim_pid_scoped_logs then return true end
  local original = log.create_logger
  log.create_logger = function(filename)
    return original(scoped_name(filename, pid))
  end
  log._nvim_pid_scoped_logs = { pid = pid, original = original }
  return true
end

function M.apply(force_load)
  local log = package.loaded["dap.log"]
  if type(log) ~= "table" then
    -- Registry discovery happens before lazy nvim-dap is loaded. The plugin's
    -- config calls apply(true) at the safe point after its runtime path exists.
    if not force_load then return true end
    local ok, loaded = pcall(require, "dap.log")
    if not ok then return false, loaded end
    log = loaded
  end
  return install(log, vim.fn.getpid())
end

M._scoped_name_for_test = scoped_name
M._install_for_test = install

return M
