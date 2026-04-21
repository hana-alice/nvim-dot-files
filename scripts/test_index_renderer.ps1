# Index Renderer module only - validate post-prune+inject CDB
$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-newprune'
$idx = "$workDir\renderer.idx"
$logF = "$workDir\indexer.log"

Write-Host "=== Index Renderer module only ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
$cdbDir = $workDir
& 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=all-TUs --execute-concurrency=8 '--filter=.*Renderer.Private.*' "-p=$workDir" $cdbDir 2>$logF 1>$idx
$sw.Stop()

$idxSz = (Get-Item $idx).Length / 1MB
$log = Get-Content $logF
$processed = ($log | Where-Object { $_ -match '^\[' }).Count
$failed = ($log | Where-Object { $_ -match '^Failed to run' }).Count
$success = $processed - $failed
$rate = if ($processed -gt 0) { 100.0 * $success / $processed } else { 0 }

Write-Host ""
Write-Host "=== Final ===" -ForegroundColor Green
Write-Host ("  Indexer time:  {0:N1} s ({1:N1} min)" -f $sw.Elapsed.TotalSeconds, $sw.Elapsed.TotalMinutes)
Write-Host ("  Idx size:      {0:N1} MB" -f $idxSz)
Write-Host ("  Processed:     $processed")
Write-Host ("  Failed:        $failed")
Write-Host ("  Success rate:  {0:N1}%" -f $rate)
Write-Host ""
Write-Host "First 6 fail samples:"
$log | Where-Object { $_ -match 'fatal error' } | Select-Object -First 6 | ForEach-Object { Write-Host "  $_" }
