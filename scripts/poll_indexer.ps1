$p = Get-Process clangd-indexer -ErrorAction SilentlyContinue
if (-not $p) { Write-Host "no indexer running"; return }
foreach ($x in $p) {
    $up = ((Get-Date) - $x.StartTime).TotalMinutes
    $cpu = $x.TotalProcessorTime.TotalSeconds
    $effPct = $cpu / ($up * 60) * 100
    Write-Host ("PID {0,5}  Uptime {1,5:N1}m  CPU {2,8:N0}s  Eff {3,5:N0}%  Threads {4,3}  WS {5,5:N0} MB" -f $x.Id, $up, $cpu, $effPct, $x.Threads.Count, ($x.WorkingSet64/1MB))
}
$log = '<PROJ_DRIVE>\UEProj\Engine\.cache\nvim-ue\logs\full.log'
$out = '<PROJ_DRIVE>\UEProj\Engine\.cache\nvim-ue\clangd\index\full.idx'
if (Test-Path $log) {
    $sz = (Get-Item $log).Length / 1MB
    Write-Host ("Log: {0:N1} MB" -f $sz)
    $last = Get-Content $log -Tail 1
    Write-Host ("Last line: {0}" -f $last)
}
if (Test-Path $out) {
    $sz = (Get-Item $out).Length / 1MB
    Write-Host ("Idx: {0:N2} MB" -f $sz)
}
