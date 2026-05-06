-- utils.platform.windows — Windows driver.
--
-- Concentrates every Windows-specific shell / path / process decision
-- that previously lived inline in `lua/config/windows.lua`, `lua/ue.lua`,
-- and `lua/ue/dap.lua`. Phase A keeps the original call sites working;
-- subsequent phases will route them through this driver.

local M = {
  id         = "windows",
  path_sep   = "\\",
  list_sep   = ";",
  exe_suffix = ".exe",
}

function M.shell()
  if vim.fn.executable("pwsh") == 1 then return "pwsh" end
  if vim.fn.executable("powershell") == 1 then return "powershell" end
  return vim.o.shell ~= "" and vim.o.shell or "cmd.exe"
end

local function to_windows_path(path)
  return tostring(path or ""):gsub("/", "\\")
end

function M.cmd_quote(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

local function start_with_explorer(path, select_file)
  path = to_windows_path(path)
  if path == "" then return end
  local arg = select_file and ("/select," .. M.cmd_quote(path)) or M.cmd_quote(path)
  local cmd = 'start "" explorer.exe ' .. arg
  local job = vim.fn.jobstart({ "cmd.exe", "/c", cmd }, { detach = true })
  if job <= 0 then
    local ok, log = pcall(require, "utils.log")
    if ok then log.notify_error("platform.windows", "explorer.exe failed: " .. path) end
  end
end

function M.open_path(path)
  start_with_explorer(path, false)
end

function M.reveal_file(path)
  start_with_explorer(path, true)
end

function M.default_clangd_candidates()
  -- Hot lookup; let upstream `ue.clangd_cmd` keep its own richer search,
  -- this is the platform-default fallback.
  return {
    "clangd.exe",
    "clangd",
  }
end

function M.default_codelldb_paths()
  -- Search: Mason install dir, scoop shim, then PATH.
  local data = vim.fn.stdpath("data")
  return {
    data .. "/mason/packages/codelldb/extension/adapter/codelldb.exe",
    "codelldb.exe",
    "codelldb",
  }
end

function M.default_lldb_server_paths()
  -- Android NDK / Android Studio side-by-side. Globs are resolved by
  -- callers because `vim.fs.find` semantics differ from shell globs.
  local localappdata = (vim.uv or vim.loop).os_getenv("LOCALAPPDATA") or ""
  local out = {}
  if localappdata ~= "" then
    out[#out + 1] = localappdata
      .. "/Programs/Android Studio*/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server"
    out[#out + 1] = localappdata
      .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server"
  end
  return out
end

return M
