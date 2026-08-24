# Time unified Renderer indexing
$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-unified-Renderer'
$idx = "$workDir\unified.idx"
$logF = "$workDir\unified.log"
$src = "$workDir\unified.Renderer.cpp"

Write-Host "=== Unified Renderer (365 cpps in 1 TU) ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
& 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=all-TUs --execute-concurrency=1 "-p=$workDir" $workDir 2>$logF 1>$idx
$sw.Stop()

$idxSz = (Get-Item $idx).Length / 1MB
$log = Get-Content $logF
$processed = ($log | Where-Object { $_ -match '^\[' }).Count
$failed = ($log | Where-Object { $_ -match '^Failed to run' }).Count
$ferrs = ($log | Where-Object { $_ -match 'fatal error' }).Count

Write-Host ""
Write-Host "=== Final ===" -ForegroundColor Green
Write-Host ("  Time:        {0:N1}s ({1:N1} min)" -f $sw.Elapsed.TotalSeconds, $sw.Elapsed.TotalMinutes)
Write-Host ("  Idx:         {0:N1} MB" -f $idxSz)
Write-Host ("  Processed:   $processed")
Write-Host ("  Failed:      $failed")
Write-Host ("  Fatal errs:  $ferrs")
Write-Host ""
Write-Host "First 5 fail samples:"
$log | Where-Object { $_ -match 'fatal error' } | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
