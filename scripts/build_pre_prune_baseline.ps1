# Rebuild the pre-prune baseline CDB (437MB after expand+resolve+unify)
# from the original UBT response-file form (7.3MB), then snapshot it as
# .pre-prune.bak so prune experiments can repeatedly start from the same
# state without re-running the slow upstream steps.
$ErrorActionPreference = 'Continue'
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
$cdb = '<PROJ_DRIVE>\UnrealEngine\compile_commands.json'
$bakOrig = '<PROJ_DRIVE>\UnrealEngine\compile_commands.before-pipeline.bak'
$bakPrePrune = '<PROJ_DRIVE>\UnrealEngine\compile_commands.pre-prune.bak'
$tools = '<LOCAL_APPDATA>\nvim\tools'

Set-Location '<PROJ_DRIVE>\UnrealEngine'
Write-Host ("=== restore from before-pipeline.bak ({0:N0} bytes) ===" -f (Get-Item $bakOrig).Length)
Copy-Item $bakOrig $cdb -Force

function Run-Step($name, $arglist) {
    Write-Host ("=== {0} ===" -f $name)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $python @arglist 2>&1 | Out-String -Stream | Tee-Object -Variable out
    $rc = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("[{0}] elapsed: {1:N1}s, exit={2}, cdb size: {3:N0} bytes" -f $name, $sw.Elapsed.TotalSeconds, $rc, (Get-Item $cdb).Length)
    if ($rc -ne 0) { Write-Host "ABORT"; exit $rc }
}

Run-Step 'expand'   @("$tools\expand_response_cdb.py", $cdb)
Run-Step 'resolve'  @("$tools\resolve_cdb_paths.py", $cdb)
Run-Step 'unify'    @("$tools\unify_include_dirs.py", $cdb, '--max-overhead=200', '--include-engine')

Write-Host "=== snapshotting pre-prune state ==="
Copy-Item $cdb $bakPrePrune -Force
Write-Host ("snapshot saved: {0} ({1:N0} bytes)" -f $bakPrePrune, (Get-Item $bakPrePrune).Length)
Write-Host '=== DONE ==='
