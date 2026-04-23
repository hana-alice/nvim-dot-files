# Time a single TU through clangd-indexer to find the bottleneck
$workDir = '<PROJ_DRIVE>\UEProj\Engine\.clangd-index\test-rsp'
$cdb = "$workDir\compile_commands.json"
# Pick a single Renderer cpp
$one = '<PROJ_DRIVE>\UEProj\Engine\Source\Runtime\Renderer\Private\ScreenPass.cpp'

Write-Host "=== Single TU timing: ScreenPass.cpp ==="
$sw = [Diagnostics.Stopwatch]::StartNew()
$out = & 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --executor=standalone "-p=$workDir" $one 2>&1 | Out-String
$sw.Stop()
Write-Host ("  Time: {0:N1}s" -f $sw.Elapsed.TotalSeconds)
Write-Host ""
Write-Host "Output (first 30 lines):"
$out -split "`n" | Select-Object -First 30 | ForEach-Object { Write-Host "  $_" }
