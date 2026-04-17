[System.IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'nvim\.' }
