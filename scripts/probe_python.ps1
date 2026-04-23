$exes = @(
    'python',
    'C:\Python314\python.exe',
    '<LOCAL_APPDATA>\Programs\Python\Python312\python.exe',
    'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
)
foreach ($e in $exes) {
    Write-Host "=== $e ==="
    try {
        & $e -c "import sys, re, json; print(sys.version); print(sys.executable); print('re ok')" 2>&1
    } catch { Write-Host "FAIL: $_" }
}
