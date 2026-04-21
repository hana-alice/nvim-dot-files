# Test rsp-driven -I replacement on Renderer
$ErrorActionPreference = 'Stop'
$src     = '<PROJ_DRIVE>\UEProj\Engine\compile_commands.json.before_prune'
$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-rsp'
$cdb     = "$workDir\compile_commands.json"
$idx     = "$workDir\renderer.idx"
$logF    = "$workDir\indexer.log"

if (Test-Path $workDir) { Remove-Item $workDir -Recurse -Force }
New-Item -ItemType Directory $workDir | Out-Null

Write-Host "=== Step 1: Copy original CDB ===" -ForegroundColor Cyan
Copy-Item $src $cdb
Write-Host ("  CDB: {0:N1} MB" -f ((Get-Item $cdb).Length / 1MB))

Write-Host ""
Write-Host "=== Step 2: Replace -I with UBT .rsp ground truth ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& python -I '<LOCAL_APPDATA>\nvim\tools\replace_i_with_rsp.py' $cdb 2>&1 | Out-Host
$sw.Stop()
Write-Host ("  Replace took {0:N1}s, CDB now {1:N1} MB" -f $sw.Elapsed.TotalSeconds, ((Get-Item $cdb).Length / 1MB))

Write-Host ""
Write-Host "=== Step 3: Inject defs+UHT (NO module-public, since rsp is ground truth) ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& python -I '<LOCAL_APPDATA>\nvim\tools\inject_definitions_to_cdb.py' $cdb 2>&1 | Select-Object -Last 10 | Out-Host
$sw.Stop()
Write-Host ("  Inject took {0:N1}s, CDB now {1:N1} MB" -f $sw.Elapsed.TotalSeconds, ((Get-Item $cdb).Length / 1MB))

Write-Host ""
Write-Host "=== Step 4: Index Renderer module ===" -ForegroundColor Cyan
$sw = [Diagnostics.Stopwatch]::StartNew()
& 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=all-TUs --execute-concurrency=8 '--filter=.*Renderer.Private.*' "-p=$workDir" $workDir 2>$logF 1>$idx
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
Write-Host "First 10 fail samples:"
$log | Where-Object { $_ -match 'fatal error' } | Select-Object -First 10 | ForEach-Object { Write-Host "  $_" }
