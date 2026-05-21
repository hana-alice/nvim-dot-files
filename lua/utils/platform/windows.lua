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
  -- Ordering priorities (highest first):
  -- 1. C:/tools/lldb-22/install/bin/lldb-dap.exe — our locally-built
  --    LLVM 22.1.6 (commit fc4aad7b). Verified end-to-end against UE
  --    Android via platform mode (probe_bp_v13.py, 2026-05-21). The
  --    STATUS_STACK_BUFFER_OVERRUN (0xC0000409) startup crash described
  --    in llvm/llvm-project#178155 is NOT reproducible against this
  --    build — that issue was for the 22.1.4/5 distribution shipped on
  --    GitHub Releases; our self-built 22.1.6 is fine.
  -- 2. Program Files/LLVM/bin/lldb-dap.exe — whatever the user installed
  --    system-wide. May be 22.x or 21.x; LLVM Installer usually ships
  --    the latest stable.
  -- 3. C:/tools/lldb-21/bin/lldb-dap.exe — historic 21.1.8 fallback for
  --    hosts that DO hit the 22.x startup crash. Kept last so it doesn't
  --    accidentally win on an Android-platform-mode workflow (21.1.8's
  --    platform protocol handshake is incompatible with NDK 27 server,
  --    confirmed by reproducing "Connection shut down by remote side
  --    while waiting for reply to initial handshake packet" in headless
  --    e2e on 2026-05-21).
  local pf = (vim.uv or vim.loop).os_getenv("ProgramFiles") or "C:/Program Files"
  return {
    "C:/tools/lldb-22/install/bin/lldb-dap.exe",
    pf .. "/LLVM/bin/lldb-dap.exe",
    "C:/tools/lldb-21/bin/lldb-dap.exe",
    "C:/Program Files/LLVM/bin/lldb-dap.exe",
    "C:/Program Files (x86)/LLVM/bin/lldb-dap.exe",
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
