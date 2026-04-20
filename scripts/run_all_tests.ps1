# Run all ue_goto headless tests sequentially.
# Usage (pwsh 7): pwsh -File scripts\run_all_tests.ps1
#
# Each test is a self-contained .lua that prints "PASS" or errors out.
# Invokes nvim headless w/ LazyVim init suppression so plugin manager
# doesn't drag in the whole runtime (only what test requires).

$ErrorActionPreference = "Stop"

$nvim = "C:\Program Files\Neovim\bin\nvim.exe"
$nvimDir = "<LOCAL_APPDATA>\nvim"
$scripts = Join-Path $nvimDir "scripts"

# Tests scoped to the syntax-overload-filter branch.
# (test_jumper_real / test_jumper_headless / test_jumplist_fix / test_dependent_name
#  / test_tier2_wireup are pre-existing — included to confirm no regression.)
$tests = @(
  "test_call_arity.lua",
  "test_declarator_arity.lua",
  "test_syntax_filter.lua",
  "test_ranking_sort.lua",
  "test_dependent_name.lua",
  "test_tier2_wireup.lua",
  "test_jumper_headless.lua"
  # test_jumper_real.lua intentionally excluded — needs running clangd against UEOff.
  # test_jumplist_fix.lua intentionally excluded — needs live nvim instance via socket.
)

$results = @()
$pass = 0
$fail = 0

foreach ($t in $tests) {
  $path = Join-Path $scripts $t
  if (-not (Test-Path $path)) {
    Write-Host "SKIP $t (not found)" -ForegroundColor Yellow
    $results += [pscustomobject]@{ name=$t; status="SKIP"; ms=0; tail="" }
    continue
  }
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  $out = & $nvim --headless `
    --cmd "lua vim.g.started_with_stdin=true" `
    -c "luafile $path" `
    -c "qall!" 2>&1 | Out-String
  $sw.Stop()
  $ms = [int]$sw.Elapsed.TotalMilliseconds

  $tail = ($out -split "`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join " | "
  if ($out -match "(PASS\b|ALL TESTS PASSED|cases passed)") {
    Write-Host ("PASS  {0,-32} {1,5} ms" -f $t, $ms) -ForegroundColor Green
    $pass++
    $results += [pscustomobject]@{ name=$t; status="PASS"; ms=$ms; tail=$tail }
  } else {
    Write-Host ("FAIL  {0,-32} {1,5} ms" -f $t, $ms) -ForegroundColor Red
    Write-Host "  └─ $tail" -ForegroundColor DarkRed
    $fail++
    $results += [pscustomobject]@{ name=$t; status="FAIL"; ms=$ms; tail=$tail }
  }
}

Write-Host ""
Write-Host ("Summary: {0} PASS / {1} FAIL / {2} total" -f $pass, $fail, $tests.Count) -ForegroundColor Cyan
if ($fail -gt 0) { exit 1 }
