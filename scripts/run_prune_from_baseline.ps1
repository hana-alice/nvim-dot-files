# Run prune-only on the snapshotted pre-prune CDB. Restores state first
# so each run starts from the same 437MB baseline.
$ErrorActionPreference = 'Continue'
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
$cdb = '<PROJ_DRIVE>\UnrealEngine\compile_commands.json'
$bakPrePrune = '<PROJ_DRIVE>\UnrealEngine\compile_commands.pre-prune.bak'
$tools = '<LOCAL_APPDATA>\nvim\tools'
$sample = if ($args.Count -ge 1) { $args[0] } else { '5' }
$workers = if ($args.Count -ge 2) { $args[1] } else { '20' }

Set-Location '<PROJ_DRIVE>\UnrealEngine'
if (-not (Test-Path $bakPrePrune)) {
    Write-Host "ERROR: pre-prune baseline not found at $bakPrePrune. Run build_pre_prune_baseline.ps1 first."
    exit 1
}

Write-Host "=== restore from pre-prune.bak ==="
Copy-Item $bakPrePrune $cdb -Force
$beforeSize = (Get-Item $cdb).Length
Write-Host ("cdb size restored: {0:N0} bytes" -f $beforeSize)
Write-Host ("=== prune (sample={0}, workers={1}) ===" -f $sample, $workers)

$sw = [Diagnostics.Stopwatch]::StartNew()
& $python -I "$tools\prune_include_dirs.py" $cdb '--sample' $sample '--workers' $workers 2>&1 |
    Out-String -Stream | Tee-Object -Variable out
$rc = $LASTEXITCODE
$sw.Stop()

$afterSize = (Get-Item $cdb).Length
Write-Host ("[prune] elapsed: {0:N1}s, exit={1}, cdb size: {2:N0} -> {3:N0} bytes ({4:N1}% of orig)" -f `
    $sw.Elapsed.TotalSeconds, $rc, $beforeSize, $afterSize, ($afterSize/$beforeSize*100))
