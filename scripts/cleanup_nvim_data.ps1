$ErrorActionPreference = 'Stop'

Write-Output "=== Step 1: Kill orphan headless nvim PID 19212 ==="
$p = Get-Process -Id 19212 -ErrorAction SilentlyContinue
if ($p) {
  $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId=19212").CommandLine
  Write-Output "Found: $($p.Name) PID=$($p.Id)"
  Write-Output "  cmd=$cmd"
  if ($cmd -notmatch '--headless') {
    Write-Output "ABORT: PID 19212 cmdline does not contain --headless. Refusing to kill."
    exit 2
  }
  Stop-Process -Id 19212 -Force
  Start-Sleep -Milliseconds 500
  if (Get-Process -Id 19212 -ErrorAction SilentlyContinue) {
    Write-Output "FAIL: still running"; exit 3
  }
  Write-Output "killed."
} else {
  Write-Output "PID 19212 not running (already gone)."
}

Write-Output ""
Write-Output "=== Step 2: Remove orphan nvim-data directory ==="
$target = 'C:\Users\hana-alice\AppData\Local\nvim-data'
if (Test-Path $target) {
  $size = (Get-ChildItem $target -Recurse -Force -ErrorAction SilentlyContinue |
    Measure-Object -Property Length -Sum).Sum
  Write-Output "Removing $target  (size=$size bytes)"
  Remove-Item -Recurse -Force $target
  if (Test-Path $target) { Write-Output "FAIL"; exit 4 }
  Write-Output "removed."
} else {
  Write-Output "$target does not exist (already gone)."
}

Write-Output ""
Write-Output "=== Step 3: Verify final state ==="
Get-ChildItem 'C:\Users\hana-alice\AppData\Local' -Directory |
  Where-Object { $_.Name -match 'nvim' } |
  Select-Object Name, LastWriteTime |
  Format-Table -AutoSize | Out-String | Write-Output

Write-Output "=== Remaining nvim processes ==="
$procs = Get-CimInstance Win32_Process -Filter "Name='nvim.exe' OR Name='neovide.exe'"
if ($procs) {
  $procs | Select-Object ProcessId, Name, CommandLine | Format-List | Out-String | Write-Output
} else {
  Write-Output "  (none)"
}

Write-Output "DONE."
