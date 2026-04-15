@echo off
powershell -NoProfile -Command "$script = 'C:\\Users\\hana-alice\\AppData\\Local\\nvim\\tools\\capslock_to_esc.pyw'; Get-CimInstance Win32_Process -Filter \"Name = 'pythonw.exe'\" | Where-Object { $_.CommandLine -like ('*' + $script + '*') } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }"
