$env:PYTHONHOME = $null
$env:PYTHONPATH = $null
$python = 'C:\Users\<USER>\AppData\Roaming\uv\python\cpython-3.11-windows-x86_64-none\python.exe'
& $python '<LOCAL_APPDATA>\nvim\scripts\make_preprune_smoke100.py'
