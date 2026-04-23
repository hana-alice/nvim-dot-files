$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
$prune  = '<LOCAL_APPDATA>\nvim\tools\prune_include_dirs.py'
$cdb    = '<PROJ_DRIVE>\UnrealEngine\compile_commands.smoke100_pruned_test.json'

# Run prune with sample=2 (default), workers limited to 8 to keep noise low
& $python $prune $cdb --sample 2 --workers 8
