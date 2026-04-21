# Full UE Unity cold-build pipeline
$ErrorActionPreference = 'Stop'
$srcCdb  = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-rsp\compile_commands.json'
$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-unity-full'
$cdb     = "$workDir\compile_commands.json"
$idx     = "$workDir\Engine.unity.idx"
$logF    = "$workDir\unity.log"

if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory $workDir | Out-Null

Write-Host "=== Step 1: Build Unity CDB ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& python -I '<LOCAL_APPDATA>\nvim\tools\build_unity_cdb.py' $srcCdb $cdb 2>&1 | Out-Host
$sw.Stop()
Write-Host ("  Build CDB took {0:N1}s, CDB {1:N1} MB" -f $sw.Elapsed.TotalSeconds, ((Get-Item $cdb).Length / 1MB))

Write-Host ""
Write-Host "=== Step 2: Run clangd-indexer (8 cores) ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=all-TUs --execute-concurrency=8 "-p=$workDir" $workDir 2>$logF 1>$idx
$sw.Stop()

$idxSz = (Get-Item $idx).Length / 1MB
$log = Get-Content $logF
$processed = ($log | Where-Object { $_ -match '^\[' }).Count
$failed = ($log | Where-Object { $_ -match '^Failed to run' }).Count
$ferrs = ($log | Where-Object { $_ -match 'fatal error' }).Count
$rate = if ($processed -gt 0) { 100.0 * ($processed - $failed) / $processed } else { 0 }

Write-Host ""
Write-Host "=== Final ===" -ForegroundColor Green
Write-Host ("  Indexer time:  {0:N1} min" -f $sw.Elapsed.TotalMinutes)
Write-Host ("  Idx size:      {0:N1} MB" -f $idxSz)
Write-Host ("  Unity TUs:     $processed")
Write-Host ("  Failed TUs:    $failed")
Write-Host ("  Fatal errors:  $ferrs")
Write-Host ("  Success rate:  {0:N1}%" -f $rate)
Write-Host ""
Write-Host "First 10 fail samples:"
$log | Where-Object { $_ -match 'fatal error' } | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }

# Copy result to active index name expected by ue.lua
$active = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\Engine.full.idx'
Write-Host ""
Write-Host "=== Step 3: Activate idx ===" -ForegroundColor Cyan
Copy-Item $idx $active -Force
Write-Host "  Copied -> $active"
