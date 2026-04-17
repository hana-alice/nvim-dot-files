# Set Windows user-level environment variables so Neovim points all
# data/state/cache/log writes to %LOCALAPPDATA%\nvim-main BEFORE init.lua runs.
# This eliminates the dual-directory problem where nvim's pre-init paths
# (TUI log, swap on early errors) leak into the default %LOCALAPPDATA%\nvim-data.

$ErrorActionPreference = 'Stop'

$base = Join-Path $env:LOCALAPPDATA 'nvim-main'
$logFile = Join-Path $base 'log'

# Ensure target dirs exist
New-Item -ItemType Directory -Force -Path $base | Out-Null

$pairs = @{
    'XDG_DATA_HOME'  = $base
    'XDG_STATE_HOME' = $base
    'XDG_CACHE_HOME' = $base
    'NVIM_LOG_FILE'  = $logFile
}

foreach ($key in $pairs.Keys) {
    $val = $pairs[$key]
    Write-Host ("Setting User env: {0} = {1}" -f $key, $val)
    [Environment]::SetEnvironmentVariable($key, $val, 'User')
}

Write-Host "Done. Reboot of any nvim/neovide processes required to pick up new env."
