# Test mini-batch unified Renderer
$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-mini-Renderer-5'
$idx = "$workDir\mini.idx"
$logF = "$workDir\mini.log"

Write-Host "=== Mini-batch (5 cpp/batch) Renderer ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
& 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=all-TUs --execute-concurrency=8 "-p=$workDir" $workDir 2>$logF 1>$idx
$sw.Stop()

$idxSz = (Get-Item $idx).Length / 1MB
$log = Get-Content $logF
$processed = ($log | Where-Object { $_ -match '^\[' }).Count
$failed = ($log | Where-Object { $_ -match '^Failed to run' }).Count
$success = $processed - $failed
$rate = if ($processed -gt 0) { 100.0 * $success / $processed } else { 0 }

Write-Host ""
Write-Host "=== Final ===" -ForegroundColor Green
Write-Host ("  Time:        {0:N1}s ({1:N1} min)" -f $sw.Elapsed.TotalSeconds, $sw.Elapsed.TotalMinutes)
Write-Host ("  Idx:         {0:N1} MB" -f $idxSz)
Write-Host ("  Batches:     $processed")
Write-Host ("  Failed:      $failed")
Write-Host ("  Success rate:{0:N1}% (of batches)" -f $rate)
Write-Host ""
Write-Host "First 5 fail samples:"
$log | Where-Object { $_ -match 'fatal error|ambiguous' } | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
