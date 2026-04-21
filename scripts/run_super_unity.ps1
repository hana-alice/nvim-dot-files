# Test super-unity (PCH-grouped) indexing
$ErrorActionPreference = 'Stop'
$srcUnityCdb = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-unity-full\compile_commands.json'
$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-super-unity'
$cdb     = "$workDir\compile_commands.json"
$idx     = "$workDir\Engine.super.idx"
$logF    = "$workDir\super.log"

Write-Host "=== Step 1: Build Super-Unity CDB ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& python -I '<LOCAL_APPDATA>\nvim\tools\build_super_unity_cdb.py' $srcUnityCdb $cdb 50 2>&1 | Out-Host
$sw.Stop()
Write-Host ("  Build CDB took {0:N1}s" -f $sw.Elapsed.TotalSeconds)

Write-Host ""
Write-Host "=== Step 2: Run clangd-indexer (8 cores - super-unity is heavy per TU) ===" -ForegroundColor Cyan
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
Write-Host ("  Super-unity TUs: $processed")
Write-Host ("  Failed TUs:    $failed")
Write-Host ("  Fatal errors:  $ferrs")
Write-Host ("  Success rate:  {0:N1}%" -f $rate)
Write-Host ""
Write-Host "First 10 fail samples:"
$log | Where-Object { $_ -match 'fatal error' } | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
