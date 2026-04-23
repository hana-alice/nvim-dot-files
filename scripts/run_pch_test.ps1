$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
$pch    = '<LOCAL_APPDATA>\nvim\tools\prebuild_pch_v2.py'
$cdb    = '<PROJ_DRIVE>\UnrealEngine\compile_commands.pchtest.json'
& $python $pch $cdb
