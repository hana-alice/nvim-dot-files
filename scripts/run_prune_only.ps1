# Run only prune step on already-expanded CDB.
$ErrorActionPreference = 'Continue'
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
$cdb = '<PROJ_DRIVE>\UnrealEngine\compile_commands.json'
$tools = '<LOCAL_APPDATA>\nvim\tools'
$sample = if ($args.Count -ge 1) { $args[0] } else { '5' }

Set-Location '<PROJ_DRIVE>\UnrealEngine'
$beforeSize = (Get-Item $cdb).Length
Write-Host ("python: {0}" -f $python)
Write-Host ("cdb size before prune: {0:N0} bytes" -f $beforeSize)
Write-Host ("=== prune (sample={0}) ===" -f $sample)

$sw = [Diagnostics.Stopwatch]::StartNew()
& $python -I "$tools\prune_include_dirs.py" $cdb '--sample' $sample 2>&1 | Out-String -Stream | Tee-Object -Variable out
$rc = $LASTEXITCODE
$sw.Stop()

$afterSize = (Get-Item $cdb).Length
Write-Host ("[prune] elapsed: {0:N1}s, exit={1}, cdb size: {2:N0} -> {3:N0} bytes ({4:N1}% of orig)" -f `
    $sw.Elapsed.TotalSeconds, $rc, $beforeSize, $afterSize, ($afterSize/$beforeSize*100))
