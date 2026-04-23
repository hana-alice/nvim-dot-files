Write-Host "PYTHONPATH=$env:PYTHONPATH"
Write-Host "PYTHONHOME=$env:PYTHONHOME"
Write-Host "PYTHONSTARTUP=$env:PYTHONSTARTUP"
Write-Host "---User Env---"
[Environment]::GetEnvironmentVariables('User').GetEnumerator() | Where-Object { $_.Name -like "PYTHON*" } | ForEach-Object { "$($_.Name)=$($_.Value)" }
Write-Host "---Machine Env---"
[Environment]::GetEnvironmentVariables('Machine').GetEnumerator() | Where-Object { $_.Name -like "PYTHON*" } | ForEach-Object { "$($_.Name)=$($_.Value)" }
