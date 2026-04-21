# Full-run: build the real .idx for 11593 TUs after inject.
# Steps: backup CDB -> inject -> indexer -> stats
$ErrorActionPreference = 'Continue'
$cdbReal = '<PROJ_DRIVE>\UEProj\Engine\compile_commands.json'
$cdbWork = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\cdb_inject_full.json'
# Match ue.lua naming convention: <project_name>.full.idx where project_name = leaf dir of engine_root
$out = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\Engine.full.idx'
$indexer = 'C:\Program Files\LLVM\bin\clangd-indexer.exe'
$inject  = '<LOCAL_APPDATA>\nvim\tools\inject_definitions_to_cdb.py'
$logFile = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\full.log'

# Use a side copy of CDB so we don't disturb the live one
Write-Host "=== Step 1: Copy CDB to side location ===" -ForegroundColor Cyan
Copy-Item $cdbReal $cdbWork -Force
$origSz = (Get-Item $cdbWork).Length / 1MB
Write-Host ("  CDB: {0:N1} MB, copied to {1}" -f $origSz, $cdbWork)

Write-Host ""
Write-Host "=== Step 2: Inject Definitions + UHT dirs ===" -ForegroundColor Cyan
$sw1 = [Diagnostics.Stopwatch]::StartNew()
& python -I $inject $cdbWork
$sw1.Stop()
$newSz = (Get-Item $cdbWork).Length / 1MB
Write-Host ("  Inject took {0:N1}s, CDB now {1:N1} MB" -f $sw1.Elapsed.TotalSeconds, $newSz)

Write-Host ""
Write-Host "=== Step 3: Run clangd-indexer ===" -ForegroundColor Cyan
$sw2 = [Diagnostics.Stopwatch]::StartNew()
& $indexer --executor=all-TUs --execute-concurrency=24 $cdbWork 2>$logFile 1>$out
$exit = $LASTEXITCODE
$sw2.Stop()

$idxSz = (Get-Item $out).Length / 1MB
$log = Get-Content $logFile
$processed = ($log | Where-Object { $_ -match '^\[' }).Count
$failed = ($log | Where-Object { $_ -match '^Failed to run' }).Count

Write-Host ""
Write-Host "=== Final ===" -ForegroundColor Green
Write-Host ("  Indexer time:   {0:N1} min" -f $sw2.Elapsed.TotalMinutes)
Write-Host ("  Throughput:     {0:N1} TU/s" -f ($processed / $sw2.Elapsed.TotalSeconds))
Write-Host ("  Idx size:       {0:N1} MB" -f $idxSz)
Write-Host ("  Processed:      $processed")
Write-Host ("  Failed:         $failed")
Write-Host ("  Success rate:   {0:N1}%" -f (100.0 * ($processed - $failed) / [Math]::Max(1, $processed)))
Write-Host ""
Write-Host "Log: $logFile"
Write-Host "Idx: $out"
