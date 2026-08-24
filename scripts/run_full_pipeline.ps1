# Run full ue-pipeline on UnrealEngine CDB and report timings.
$ErrorActionPreference = 'Continue'

# CRITICAL: PYTHONHOME is set in this shell's process env to a uv 3.11
# prefix, which makes every python.exe (including 3.12/3.14) try to load
# 3.11 stdlib and crash with "SRE module mismatch" before user code
# runs. Clear it here so the system python below uses its own stdlib.
$env:PYTHONHOME = $null
$env:PYTHONPATH = $null

# Pin to a python that we know works. uv-managed 3.11 is the only one
# that boots in this env (its PYTHONHOME matches its install).
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
if (-not (Test-Path $python)) {
    $python = 'python'
}

$cdb = '<PROJ_DRIVE>\UnrealEngine\compile_commands.json'
$tools = '<LOCAL_APPDATA>\nvim\tools'

Set-Location '<PROJ_DRIVE>\UnrealEngine'
Copy-Item $cdb 'compile_commands.before-pipeline.bak' -Force
Write-Host ("backup written: {0:N0} bytes" -f (Get-Item 'compile_commands.before-pipeline.bak').Length)
Write-Host ("python: {0}" -f $python)

function Run-Step($name, $arglist) {
    Write-Host ("=== {0} ===" -f $name)
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $python @arglist 2>&1 | Out-String -Stream | Tee-Object -Variable out
    $rc = $LASTEXITCODE
    $sw.Stop()
    Write-Host ("[{0}] elapsed: {1:N1}s, exit={2}, cdb size: {3:N0} bytes" -f $name, $sw.Elapsed.TotalSeconds, $rc, (Get-Item $cdb).Length)
    if ($rc -ne 0) {
        Write-Host ("[{0}] FAILED — aborting pipeline" -f $name)
        exit $rc
    }
}

Run-Step 'expand'   @("$tools\expand_response_cdb.py", $cdb)
Run-Step 'resolve'  @("$tools\resolve_cdb_paths.py", $cdb)
Run-Step 'unify'    @("$tools\unify_include_dirs.py", $cdb, '--max-overhead=200', '--include-engine')
Run-Step 'prune'    @('-I', "$tools\prune_include_dirs.py", $cdb, '--sample', '20')

Write-Host '=== DONE ==='
