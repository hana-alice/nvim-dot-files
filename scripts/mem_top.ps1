Get-Process | Sort-Object WorkingSet -Descending | Select-Object -First 12 | Format-Table Name, @{N='WS_GB';E={[math]::Round($_.WorkingSet/1GB,2)}}, Id -AutoSize
Write-Host ""
Write-Host "=== Memory summary ==="
$os = Get-CimInstance Win32_OperatingSystem
$total = $os.TotalVisibleMemorySize / 1MB
$free = $os.FreePhysicalMemory / 1MB
Write-Host ("Total: {0:N1} GB, Free: {1:N1} GB, Used: {2:N1} GB" -f $total, $free, ($total - $free))
