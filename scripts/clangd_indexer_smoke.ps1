# Smoke test clangd-indexer on a 100-entry CDB slice. Validates:
#  1. clangd-indexer 22.1 boots on this CDB format (post expand+resolve+unify+prune)
#  2. It produces a valid .idx output
#  3. We measure files-per-second so we can extrapolate full-run cost
$ErrorActionPreference = 'Continue'
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
$indexer = 'C:\Program Files\LLVM\bin\clangd-indexer.exe'
$cdb = '<PROJ_DRIVE>\UnrealEngine\compile_commands.json'
$smallCdb = '<PROJ_DRIVE>\UnrealEngine\compile_commands.smoke100.json'
$idxOut = '<PROJ_DRIVE>\UnrealEngine\smoke100.idx'
$logOut = '<PROJ_DRIVE>\UnrealEngine\smoke100.indexer.log'

Set-Location '<PROJ_DRIVE>\UnrealEngine'

Write-Host "=== slicing first 100 entries ==="
& $python -c "import json,sys; d=json.load(open(r'$cdb')); json.dump(d[:100], open(r'$smallCdb','w'), indent=2); print('wrote',len(d[:100]))"

if (-not (Test-Path $smallCdb)) { Write-Host "FAIL: small cdb not created"; exit 1 }
Write-Host ("smoke cdb size: {0:N0} bytes" -f (Get-Item $smallCdb).Length)

Write-Host "=== clangd-indexer smoke (executor=all-TUs, concurrency=8) ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
& $indexer `
    --executor=all-TUs `
    --execute-concurrency=8 `
    --format=binary `
    --extra-arg=-Wno-unused-command-line-argument `
    --extra-arg=-Wno-error `
    -p <PROJ_DRIVE>\UnrealEngine `
    $smallCdb 2>$logOut 1>$idxOut
$rc = $LASTEXITCODE
$sw.Stop()

$idxSize = if (Test-Path $idxOut) { (Get-Item $idxOut).Length } else { 0 }
$logSize = if (Test-Path $logOut) { (Get-Item $logOut).Length } else { 0 }
Write-Host ("[indexer] elapsed: {0:N1}s, exit={1}" -f $sw.Elapsed.TotalSeconds, $rc)
Write-Host ("idx size: {0:N0} bytes, log size: {1:N0} bytes" -f $idxSize, $logSize)
Write-Host ("rate: {0:N1} files/sec (extrapolate full 14334: {1:N0}s = {2:N1}min)" -f `
    (100 / $sw.Elapsed.TotalSeconds), (14334 * $sw.Elapsed.TotalSeconds / 100), `
    (14334 * $sw.Elapsed.TotalSeconds / 100 / 60))

Write-Host "=== indexer log (last 30 lines) ==="
if (Test-Path $logOut) { Get-Content $logOut -Tail 30 }
