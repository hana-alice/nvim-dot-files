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

function M.default_lldb_dap_paths()
  -- Standard LLVM Windows install (winget LLVM.LLVM / installer .exe).
  -- PATH lookup is the final fallback inside ue.dap._common.find_lldb_dap.
  --
  -- C:/tools/lldb-21/bin/lldb-dap.exe is given top priority as a workaround
  -- for llvm/llvm-project#178155: LLVM 22.x lldb-dap.exe on Windows crashes
  -- with STATUS_STACK_BUFFER_OVERRUN (0xC0000409) at startup because
  -- NativeFile's ctor calls _get_osfhandle(fd) on a pipe fd whose CRT
  -- table lives in lldb-dap.exe's CRT, not liblldb.dll's CRT. The fix
  -- (PR #195855) is merged in main but NOT backported to release/22.x —
  -- 22.1.5 still crashes. 21.1.8's File.cpp predates the offending change
  -- and works fine. We side-load 21.1.8's lldb-dap.exe + liblldb.dll +
  -- python310.dll into a private directory; clang/clangd stay on 22.1.5.
  local pf = (vim.uv or vim.loop).os_getenv("ProgramFiles") or "C:/Program Files"
  return {
    "C:/tools/lldb-21/bin/lldb-dap.exe",
    pf .. "/LLVM/bin/lldb-dap.exe",
    "C:/Program Files/LLVM/bin/lldb-dap.exe",
    "C:/Program Files (x86)/LLVM/bin/lldb-dap.exe",
  }
end

function M.default_codelldb_paths()
  -- vadimcn/codelldb VSIX, unpacked. Used only by the Android route — see
  -- ue.dap.android and ue.dap._common.find_codelldb. The VSIX layout is:
  --   <root>/extension/adapter/codelldb.exe
  --   <root>/extension/lldb/bin/liblldb.dll  (loaded by codelldb.exe)
  -- We try a few common unpack locations. PATH lookup is the last fallback
  -- inside ue.dap._common.find_codelldb.
  local home = (vim.uv or vim.loop).os_getenv("USERPROFILE") or ""
  local lp   = (vim.uv or vim.loop).os_getenv("LOCALAPPDATA") or ""
  return {
    "C:/tools/codelldb/extension/adapter/codelldb.exe",
    home .. "/.local/share/codelldb/extension/adapter/codelldb.exe",
    lp   .. "/codelldb/extension/adapter/codelldb.exe",
    home .. "/.vscode/extensions/vadimcn.vscode-lldb-1.12.2/adapter/codelldb.exe",
  }
end

function M.default_lldb_server_paths()
  -- Android NDK / Android Studio side-by-side. Globs are resolved by
  -- callers because `vim.fs.find` semantics differ from shell globs.
  --
  -- CRITICAL ORDERING (see commit 144c28d): the lldb-server pushed to the
  -- device MUST match the NDK that built libUE4.so / libUnreal.so. UE 4.x/5.x
  -- ships with NDK 21.4.7075529 (clang 9.0.9). When a newer NDK is installed
  -- side-by-side and picked instead, the LLDB wire protocol (qLaunchGDBServer
  -- handshake) deadlocks against an LLVM 21+ lldb-dap client. Pin r21 first,
  -- then Android Studio's bundled lldb, then anything else as a fallback.
  local localappdata = (vim.uv or vim.loop).os_getenv("LOCALAPPDATA") or ""
  local out = {}
  if localappdata ~= "" then
    out[#out + 1] = localappdata
      .. "/Android/Sdk/ndk/21.*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server"
    out[#out + 1] = localappdata
      .. "/Programs/Android Studio*/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server"
    out[#out + 1] = localappdata
      .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server"
    -- NDK 26+ dropped the lib64 suffix.
    out[#out + 1] = localappdata
      .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux/aarch64/lldb-server"
  end
  return out
end

return M
