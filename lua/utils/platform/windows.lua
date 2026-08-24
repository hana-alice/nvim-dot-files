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

local shell = require("utils.platform.shell")

function M.shell_entry(kind)
  kind = kind or "default"
  if kind == "cmd" then
    return "cmd.exe"
  end
  if kind == "powershell" then
    return "powershell.exe"
  end
  if kind == "default" then
    if vim.fn.executable("pwsh") == 1 then return "pwsh" end
    return "cmd.exe"
  end
  return nil, "unsupported shell on Windows host: " .. tostring(kind)
end

function M.shell()
  return M.shell_entry("default")
end

function M.allows_osc52()
  return false
end

function M.mixed_eol_guard()
  return true
end

function M.treesitter_compiler_bin()
  return "C:\\Program Files\\LLVM\\bin"
end

function M.windows_ui_config()
  return true
end

function M.path_key(path)
  return tostring(path or ""):lower()
end

function M.query_driver_globs()
  return { "**/clang*.exe", "**/clang*", "**/gcc", "**/g++", "**/cc", "**/c++", "**/cl.exe" }
end

function M.cdb_compiler_candidates()
  return { "clang++", "clang", "clang++.exe", "clang.exe", "cl.exe", "cl" }
end

function M.lldb_python_relative_paths()
  return { "lib/site-packages/lldb", "Lib/site-packages/lldb" }
end

function M.restart_fallback_candidates(cwd, _)
  return {
    {
      client = "windows",
      bin = "nvim",
      args = {},
      cwd = cwd,
      reason = "Windows fallback; resolved to %s",
    },
  }
end

function M.restart_requires_spawn_reprobe()
  return true
end

function M.restart_shutdown_delay_ms()
  return 800
end

function M.code_search_install_hint(config_root)
  local script = tostring(config_root or "") .. "/scripts/install_windows.ps1"
  return "powershell -ExecutionPolicy Bypass -File " .. shell.quote("powershell", script)
end

local function to_windows_path(path)
  return tostring(path or ""):gsub("/", "\\")
end

local function to_windows_argument(value)
  value = tostring(value or "")
  if value:match("^[A-Za-z]:[/\\]") or value:match("^[/\\][/\\]") then
    return to_windows_path(value)
  end
  return value
end

local function join_engine_path(engine_root, suffix)
  local root = to_windows_path(engine_root)
  if root:sub(-1) == "\\" then
    return root .. suffix
  end
  return root .. "\\" .. suffix
end

function M.cmd_quote(value)
  return shell.quote("cmd", value)
end

function M.host_path(path)
  return to_windows_path(path)
end

function M.default_target()
  return "Win64"
end

function M.launch_process_plan(spec)
  spec = spec or {}
  local executable = M.host_path(spec.executable or spec.exe)
  local working_dir = M.host_path(spec.cwd or "")
  local quoted_args = {}
  for _, arg in ipairs(spec.args or {}) do
    quoted_args[#quoted_args + 1] = shell.quote("powershell", to_windows_argument(arg))
  end

  local start_process = "Start-Process -FilePath " .. shell.quote("powershell", executable)
  if working_dir ~= "" then
    start_process = start_process .. " -WorkingDirectory " .. shell.quote("powershell", working_dir)
  end
  start_process = start_process .. " -ArgumentList $argsList -PassThru"
  local script = table.concat({
    "$ErrorActionPreference = 'Stop'",
    "$argsList = @(" .. table.concat(quoted_args, ", ") .. ")",
    "$proc = " .. start_process,
    "if (-not $proc -or -not $proc.Id) { throw 'Start-Process did not return a process id' }",
    "Start-Sleep -Milliseconds 200",
    "if (-not (Get-Process -Id $proc.Id -ErrorAction SilentlyContinue)) { throw ('Process exited immediately: ' + $proc.Id) }",
    "Write-Output ('pid=' + $proc.Id)",
  }, "; ")
  local plan = shell.command("powershell", M.shell_entry("powershell"), script, {
    cwd = working_dir ~= "" and working_dir or nil,
    no_logo = false,
    metadata = { launch_mode = "wait", pid_pattern = "pid=(%d+)" },
  })
  return plan
end

function M.follow_file_plan(path)
  local native = M.host_path(path)
  local cwd = M.host_path(vim.fs.dirname(tostring(path or "")))
  return shell.follow_file("powershell", M.shell_entry("powershell"), native, cwd)
end

function M.debug_log_plan(spec)
  spec = spec or {}
  local source_executable = spec.executable or spec.exe
  local executable = M.host_path(source_executable)
  local command_needle = M.host_path(spec.command_needle or ""):lower()
  local cwd = spec.cwd or vim.fs.dirname(tostring(source_executable or ""))
  local script = ([[$ErrorActionPreference = 'Continue'
$exePath = %s
$cmdNeedle = %s
function Write-Status($text) {
  if ($script:lastStatus -ne $text) {
    $script:lastStatus = $text
    Write-Output ('[' + (Get-Date -Format 'HH:mm:ss') + '] ' + $text)
  }
}
function Get-TargetPids {
  $query = Get-CimInstance Win32_Process | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant() -eq $exePath.ToLowerInvariant()
  }
  if ($cmdNeedle -ne '') {
    $query = $query | Where-Object {
      $cmd = '' + $_.CommandLine
      $cmd -and $cmd.ToLowerInvariant().Contains($cmdNeedle)
    }
  }
  @($query | Sort-Object CreationDate | Select-Object -ExpandProperty ProcessId)
}
$script:lastStatus = ''
$bufferReady = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'DBWIN_BUFFER_READY')
$dataReady = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'DBWIN_DATA_READY')
$mmf = [System.IO.MemoryMappedFiles.MemoryMappedFile]::CreateOrOpen('DBWIN_BUFFER', 4096)
$view = $mmf.CreateViewStream()
$reader = New-Object System.IO.BinaryReader($view, [System.Text.Encoding]::Default)
$encoding = [System.Text.Encoding]::Default
$targetPids = @()
$nextRefresh = Get-Date
Write-Output ('Listening for OutputDebugString: ' + $exePath)
while ($true) {
  if ((Get-Date) -ge $nextRefresh) {
    $targetPids = @(Get-TargetPids)
    if ($targetPids.Count -eq 0) {
      Write-Status 'waiting for target process...'
    } else {
      Write-Status ('attached to pid(s): ' + ($targetPids -join ', '))
    }
    $nextRefresh = (Get-Date).AddSeconds(2)
  }
  $null = $bufferReady.Set()
  if (-not $dataReady.WaitOne(200)) {
    continue
  }
  if ($targetPids.Count -eq 0) {
    continue
  }
  $null = $view.Seek(0, [System.IO.SeekOrigin]::Begin)
  $pid = $reader.ReadInt32()
  $bytes = $reader.ReadBytes(4092)
  if ($targetPids -notcontains $pid) {
    continue
  }
  $nul = [Array]::IndexOf($bytes, [byte]0)
  if ($nul -lt 0) {
    $nul = $bytes.Length
  }
  $text = $encoding.GetString($bytes, 0, $nul).TrimEnd("`r", "`n")
  if ([string]::IsNullOrWhiteSpace($text)) {
    continue
  }
  Write-Output ('[' + (Get-Date -Format 'HH:mm:ss.fff') + '] [' + $pid + '] ' + $text)
}]]):format(
    shell.quote("powershell", executable),
    shell.quote("powershell", command_needle)
  )
  return shell.command("powershell", M.shell_entry("powershell"), script, {
    cwd = M.host_path(cwd),
    no_logo = false,
    metadata = { stream = "debug-output" },
  })
end

local function start_with_explorer(path, select_file)
  path = to_windows_path(path)
  if path == "" then return end
  local arg = select_file and ("/select," .. M.cmd_quote(path)) or M.cmd_quote(path)
  local cmd = 'start "" explorer.exe ' .. arg
  local plan = shell.command("cmd", M.shell_entry("cmd"), cmd)
  local command = { plan.executable }
  vim.list_extend(command, plan.args)
  local job = vim.fn.jobstart(command, { detach = true })
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

function M.python_candidates()
  return {
    vim.fn.expand("~/AppData/Local/Programs/Python/Python312/python.exe"),
    vim.fn.expand("~/AppData/Local/Programs/Python/Python313/python.exe"),
    "C:/Python312/python.exe",
    "C:/Python313/python.exe",
    "python.exe",
    "python",
  }
end

function M.clangd_indexer_candidates()
  return {
    "C:/Program Files/LLVM/bin/clangd-indexer.exe",
    "clangd-indexer.exe",
    "clangd-indexer",
  }
end

function M.shared_library_extension()
  return ".dll"
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
    "lldb-dap.exe",
    "lldb-dap",
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
  return shell.command("cmd", M.shell_entry("cmd"), "call " .. M.cmd_quote(build_bat), {
    cwd = to_windows_path(engine_root),
    metadata = { script = build_bat },
  }), nil
end

function M.ue_uat_entry(engine_root)
  local run_uat = join_engine_path(engine_root, "Engine\\Build\\BatchFiles\\RunUAT.bat")
  return shell.command("cmd", M.shell_entry("cmd"), "call " .. M.cmd_quote(run_uat), {
    cwd = to_windows_path(engine_root),
    metadata = { script = run_uat },
  }), nil
end

function M.pch_build_plan(path)
  local native = M.host_path(path)
  return shell.command("cmd", M.shell_entry("cmd"), "call " .. M.cmd_quote(native), {
    cwd = M.host_path(vim.fs.dirname(tostring(path or ""))),
    metadata = { script = native, operation = "pch-build" },
  })
end

function M.powershell_entry()
  return M.shell_entry("powershell")
end

return M
