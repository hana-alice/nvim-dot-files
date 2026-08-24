$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-mini-Renderer-3'
$idx = "$workDir\mini.idx"
$logF = "$workDir\mini.log"
Write-Host "=== Mini-batch (3 cpp/batch) Renderer ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
& 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=all-TUs --execute-concurrency=8 "-p=$workDir" $workDir 2>$logF 1>$idx
$sw.Stop()
$idxSz = (Get-Item $idx).Length / 1MB
$log = Get-Content $logF
$processed = ($log | Where-Object { $_ -match '^\[' }).Count
$failed = ($log | Where-Object { $_ -match '^Failed to run' }).Count
$rate = if ($processed -gt 0) { 100.0 * ($processed - $failed) / $processed } else { 0 }
Write-Host ("Time: {0:N1}s, Idx: {1:N1} MB, Batches: $processed, Failed: $failed ({2:N1}% success)" -f $sw.Elapsed.TotalSeconds, $idxSz, $rate)
