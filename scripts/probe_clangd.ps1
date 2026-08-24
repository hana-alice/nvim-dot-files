$env:PYTHONHOME = $null
$exes = @(
    'clangd', 'clangd-indexer', 'clangd-indexer.exe',
    'C:\Program Files\LLVM\bin\clangd.exe',
    'C:\Program Files\LLVM\bin\clangd-indexer.exe'
)
Write-Host "=== which ==="
foreach ($e in $exes) {
    $cmd = Get-Command $e -ErrorAction SilentlyContinue
    if ($cmd) { Write-Host ("OK  {0,-30} -> {1}" -f $e, $cmd.Source) }
    elseif (Test-Path $e) { Write-Host ("PATH {0,-30} -> {1}" -f $e, $e) }
}

Write-Host "=== clangd --version ==="
& 'C:\Program Files\LLVM\bin\clangd.exe' --version 2>&1
Write-Host "=== clangd-indexer help (first 60 lines) ==="
$h = & 'C:\Program Files\LLVM\bin\clangd-indexer.exe' --help 2>&1
$h | Select-Object -First 60
