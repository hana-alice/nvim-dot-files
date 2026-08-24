$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-ue-unity'
$idx     = "$workDir\test.idx"
$logF    = "$workDir\test.log"

if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory $workDir | Out-Null

& python -I '<LOCAL_APPDATA>\nvim\scripts\build_ue_unity_cdb.py'

Write-Host ""
Write-Host "=== Index UE's Module.Renderer.15.cpp ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
& 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=all-TUs --execute-concurrency=1 "-p=$workDir" $workDir 2>$logF 1>$idx
$sw.Stop()

$idxSz = (Get-Item $idx).Length / 1MB
$log = Get-Content $logF
$ferrs = ($log | Where-Object { $_ -match 'fatal error|ambiguous' }).Count
$failed = ($log | Where-Object { $_ -match '^Failed to run' }).Count

Write-Host ""
Write-Host "=== Final ===" -ForegroundColor Green
Write-Host ("  Time:    {0:N1}s" -f $sw.Elapsed.TotalSeconds)
Write-Host ("  Idx:     {0:N1} MB" -f $idxSz)
Write-Host ("  Failed:  $failed")
Write-Host ("  Errors:  $ferrs")
Write-Host ""
Write-Host "First 5 errors:"
$log | Where-Object { $_ -match 'fatal error|ambiguous' } | Select-Object -First 5 | ForEach-Object { Write-Host "  $_" }
