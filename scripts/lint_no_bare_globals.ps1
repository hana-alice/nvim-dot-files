#requires -Version 5.1
<#
Run the bare-globals lint and propagate the real exit code, since `nvim -l`
swallows os.exit() / cquit. Detects FAIL marker in stderr.
#>
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ExtraArgs = @()
)

$ErrorActionPreference = 'Stop'

# Resolve nvim — prefer Win exe, fall back to PATH lookup.
$nvim = 'C:\Program Files\Neovim\bin\nvim.exe'
if (-not (Test-Path $nvim)) {
  $cmd = Get-Command nvim -ErrorAction SilentlyContinue
  if ($cmd) { $nvim = $cmd.Path } else { Write-Error 'nvim.exe not found'; exit 2 }
}

# Locate the lint script relative to this wrapper.
$lintScript = Join-Path $PSScriptRoot 'lint_no_bare_globals.lua'
if (-not (Test-Path $lintScript)) {
  Write-Error "lint script not found: $lintScript"; exit 2
}

# Run lint, capture combined output, dump it through, then inspect.
$cmdArgs = @('-l', $lintScript) + $ExtraArgs
$output = & $nvim @cmdArgs 2>&1
$output | ForEach-Object { Write-Host $_ }

# Detect failure marker. The lint always prints either:
#   "lint_no_bare_globals: N files scanned, OK"           (success)
#   "lint_no_bare_globals: FAIL — N offense(s) ..."       (failure)
#   "lint_no_bare_globals: <file> — <err>"                (parser/IO error)
$asString = ($output | Out-String)
if ($asString -match 'lint_no_bare_globals: FAIL') {
  exit 1
}
if ($asString -match 'lint_no_bare_globals: .*— (?!OK)') {
  # parser / IO error — not the same as offenses, but still non-zero
  if ($asString -notmatch 'files scanned, OK') {
    Write-Host '[wrapper] lint reported an error (parser/IO) — exit 2' -ForegroundColor Yellow
    exit 2
  }
}
exit 0
