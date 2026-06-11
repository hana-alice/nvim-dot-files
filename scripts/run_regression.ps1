# scripts/run_regression.ps1
# ----------------------------------------------------------------------------
# nvim 配置 headless 全量回归本机一键入口（仅做转发，不含测试逻辑）。
#
# 用法 (pwsh 7):
#   pwsh -File scripts/run_regression.ps1
#   pwsh -File scripts/run_regression.ps1 -Filter dap     # 只跑匹配的用例
#
# 退出码透传自 nvim -l tests/run.lua（0 全绿 / 1 有失败）。
# 权威回归方式见 docs/testing-regression.md。
# ----------------------------------------------------------------------------

param(
  [string]$Filter = ""
)

$ErrorActionPreference = "Stop"

# 定位 nvim：优先 PATH，回退常见安装位置。
$nvim = (Get-Command nvim -ErrorAction SilentlyContinue)?.Source
if (-not $nvim) {
  $fallback = "C:\Program Files\Neovim\bin\nvim.exe"
  if (Test-Path $fallback) { $nvim = $fallback }
}
if (-not $nvim) {
  Write-Host "nvim not found in PATH or default install location." -ForegroundColor Red
  exit 2
}

# 配置根目录 = 本脚本上一级。
$cfgRoot = Split-Path -Parent $PSScriptRoot
$runner = Join-Path $cfgRoot "tests\run.lua"
if (-not (Test-Path $runner)) {
  Write-Host "runner not found: $runner" -ForegroundColor Red
  exit 2
}

Write-Host "nvim     : $nvim"
Write-Host "runner   : $runner"
if ($Filter) { Write-Host "filter   : $Filter" }
Write-Host ""

# 透传 filter：tests/run.lua 读取 _G.arg[1]。
if ($Filter) {
  & $nvim --headless -l $runner $Filter
} else {
  & $nvim --headless -l $runner
}
$code = $LASTEXITCODE

Write-Host ""
if ($code -eq 0) {
  Write-Host "Regression PASSED (exit 0)" -ForegroundColor Green
} else {
  Write-Host "Regression FAILED (exit $code)" -ForegroundColor Red
}
exit $code
