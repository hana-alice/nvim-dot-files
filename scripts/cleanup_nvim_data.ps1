#requires -Version 7
# Reset Neovim runtime to Windows defaults: kill any nvim/neovide procs,
# unset all XDG_* / NVIM_LOG_FILE User-scope env vars, and remove the legacy
# %LOCALAPPDATA%\nvim-main\ directory if present.
#
# After this runs, Neovim falls back to Windows defaults:
#   stdpath('config') = %LOCALAPPDATA%\nvim
#   stdpath('data')   = %LOCALAPPDATA%\nvim-data
#   stdpath('state')  = %LOCALAPPDATA%\nvim-data
#   stdpath('cache')  = %TEMP%\nvim
# i.e. the only persistent dirs under %LOCALAPPDATA% are nvim/ and nvim-data/.
#
# Idempotent: re-running on an already-clean machine is a no-op.

$ErrorActionPreference = 'Stop'

Write-Output "=== Step 1: Kill all nvim/neovide processes ==="
$procs = Get-CimInstance Win32_Process -Filter "Name='nvim.exe' OR Name='neovide.exe'" -ErrorAction SilentlyContinue
if ($procs) {
  foreach ($p in $procs) {
    Write-Output "  killing PID=$($p.ProcessId) name=$($p.Name)"
    Write-Output "    cmd=$($p.CommandLine)"
    Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
  }
  Start-Sleep -Milliseconds 800
  $still = Get-CimInstance Win32_Process -Filter "Name='nvim.exe' OR Name='neovide.exe'" -ErrorAction SilentlyContinue
  if ($still) {
    Write-Output "  WARN: still running:"
    $still | ForEach-Object { Write-Output "    PID=$($_.ProcessId) $($_.Name)" }
  } else {
    Write-Output "  all killed."
  }
} else {
  Write-Output "  no nvim/neovide processes."
}

Write-Output ""
Write-Output "=== Step 2: Remove User-scope XDG env vars + NVIM_LOG_FILE ==="
foreach ($name in 'XDG_DATA_HOME','XDG_STATE_HOME','XDG_CACHE_HOME','XDG_CONFIG_HOME','NVIM_LOG_FILE') {
  $cur = [Environment]::GetEnvironmentVariable($name, 'User')
  if ($cur) {
    Write-Output "  unsetting $name (was: $cur)"
    [Environment]::SetEnvironmentVariable($name, $null, 'User')
  } else {
    Write-Output "  $name already unset"
  }
}

Write-Output ""
Write-Output "=== Step 3: Verify env vars cleared ==="
foreach ($name in 'XDG_DATA_HOME','XDG_STATE_HOME','XDG_CACHE_HOME','XDG_CONFIG_HOME','NVIM_LOG_FILE') {
  $v = [Environment]::GetEnvironmentVariable($name, 'User')
  Write-Output "  $name = $(if ($v) { $v } else { '<unset>' })"
}

Write-Output ""
Write-Output "=== Step 4: Remove %LOCALAPPDATA%\nvim-main\ ==="
$nvimMain = 'C:\Users\hana-alice\AppData\Local\nvim-main'
if (Test-Path $nvimMain) {
  $size = (Get-ChildItem $nvimMain -Recurse -Force -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
  Write-Output "  removing $nvimMain  ($size bytes)"
  # On occupied files: try, then fall back to forcefully unlock
  try {
    Remove-Item -Recurse -Force $nvimMain
  } catch {
    Write-Output "  WARN: $_  retrying after sleep"
    Start-Sleep -Seconds 2
    Remove-Item -Recurse -Force $nvimMain -ErrorAction Stop
  }
  if (Test-Path $nvimMain) { Write-Output "FAIL: still exists"; exit 4 }
  Write-Output "  removed."
} else {
  Write-Output "  $nvimMain does not exist."
}

Write-Output ""
Write-Output "=== Step 5: Final %LOCALAPPDATA% nvim-* layout ==="
Get-ChildItem 'C:\Users\hana-alice\AppData\Local' -Directory |
  Where-Object { $_.Name -match 'nvim' } |
  Select-Object Name, LastWriteTime |
  Format-Table -AutoSize | Out-String | Write-Output

Write-Output "DONE."
