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

local function join_engine_path(engine_root, suffix)
  local root = to_windows_path(engine_root)
  if root:sub(-1) == "\\" then
    return root .. suffix
  end
  return root .. "\\" .. suffix
end

function M.cmd_quote(value)
  return '"' .. tostring(value or ""):gsub('"', '""') .. '"'
end

function M.host_path(path)
  return to_windows_path(path)
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
  -- 2. Program Files/LLVM/bin/lldb-dap.exe — system-wide LLVM, but it
  --    MUST be 22.1.6 or newer before use. Do not fall back to LLVM 21:
  --    Android platform-mode was debugged and fixed on 22.1.6, and future
  --    changes are allowed to move forward only after a fresh probe pass.
  --
  -- Version policy: host-side lldb-dap is forward-only. If 22.1.6 is
  -- unavailable or broken, fail loudly and install/fix a 22.1.6+ build;
  -- never silently downgrade to C:/tools/lldb-21 or another older adapter.
  local pf = (vim.uv or vim.loop).os_getenv("ProgramFiles") or "C:/Program Files"
  return {
    "C:/tools/lldb-22/install/bin/lldb-dap.exe",
    pf .. "/LLVM/bin/lldb-dap.exe",
    "C:/Program Files/LLVM/bin/lldb-dap.exe",
    "C:/Program Files (x86)/LLVM/bin/lldb-dap.exe",
  }
end

function M.default_lldb_server_paths()
  -- Android NDK / Android Studio side-by-side. Globs are resolved by
  -- callers because `vim.fs.find` semantics differ from shell globs.
  --
  -- ORDERING for PLATFORM MODE (docs/CONSTRAINTS.md K30, real-device verified
  -- 5/21 e51cbe6 + 2026-06-03): the device server runs `lldb-server platform
  -- --server --listen` and the host connects via
  -- `platform connect connect://[<serial>]:<port>`; lldb-server platform forks
  -- the per-target gdbserver itself. NDK 27 LLDB 18 is the verified-working
  -- platform server for this UE target on Android 16. (The earlier NDK-21-first
  -- ordering was for the abandoned `gdbserver --attach` route — K31, which never
  -- bound its listen port at all; version-matching mattered there but the route
  -- is dead.) Prefer NDK 27, then any NDK, then Android Studio bundled.
  local localappdata = (vim.uv or vim.loop).os_getenv("LOCALAPPDATA") or ""
  local out = {}
  if localappdata ~= "" then
    -- NDK 27 LLDB 18 — verified working platform server (2026-06-03).
    out[#out + 1] = localappdata
      .. "/Android/Sdk/ndk/27.*/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux/aarch64/lldb-server"
    -- Any NDK with the newer (no-lib64) layout.
    out[#out + 1] = localappdata
      .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib/clang/*/lib/linux/aarch64/lldb-server"
    -- Older NDKs (lib64 suffix, e.g. r21/r22).
    out[#out + 1] = localappdata
      .. "/Android/Sdk/ndk/*/toolchains/llvm/prebuilt/*/lib64/clang/*/lib/linux/aarch64/lldb-server"
    -- Android Studio bundled lldb — last-resort fallback.
    out[#out + 1] = localappdata
      .. "/Programs/Android Studio*/plugins/android-ndk/resources/lldb/android/arm64-v8a/lldb-server"
  end
  return out
end

function M.ue_build_entry(engine_root)
  local build_bat = join_engine_path(engine_root, "Engine\\Build\\BatchFiles\\Build.bat")
  return {
    executable = "cmd.exe",
    args = { "/d", "/c", "call " .. M.cmd_quote(build_bat) },
    cwd = to_windows_path(engine_root),
    metadata = { script = build_bat },
  }, nil
end

function M.ue_uat_entry(engine_root)
  local run_uat = join_engine_path(engine_root, "Engine\\Build\\BatchFiles\\RunUAT.bat")
  return {
    executable = "cmd.exe",
    args = { "/d", "/c", "call " .. M.cmd_quote(run_uat) },
    cwd = to_windows_path(engine_root),
    metadata = { script = run_uat },
  }, nil
end

function M.powershell_entry()
  return "powershell.exe", nil
end

return M
