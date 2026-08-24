$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
$prune  = '<LOCAL_APPDATA>\nvim\tools\prune_include_dirs.py'
$cdb    = '<PROJ_DRIVE>\UnrealEngine\compile_commands.smoke101_pruned_test.json'
& $python $prune $cdb --sample 2 --workers 8
