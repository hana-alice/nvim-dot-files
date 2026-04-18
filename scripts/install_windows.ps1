#requires -Version 5.1
<#
.SYNOPSIS
  One-shot installer for the hana-alice nvim/UE workflow on Windows.

.DESCRIPTION
  Idempotent. Safe to re-run. Skips already-installed components.
  Installs (in order):
    1. scoop (package manager)
    2. scoop core: git, pwsh, neovim, neovide, llvm, fd, ripgrep,
       lazygit, fzf, zoxide, python, nodejs-lts, make, yazi, bat,
       gawk, sed, grep, less
    3. scoop extras bucket → gtags (GNU GLOBAL)
    4. ensure %LOCALAPPDATA%\nvim exists and points at this repo
    5. clone lazy.nvim and headless-bootstrap plugins
    6. headless-install treesitter parsers (c, cpp, hlsl)

.NOTES
  Run from any pwsh 7 / Windows PowerShell 5 prompt:
    powershell -ExecutionPolicy Bypass -File scripts\install_windows.ps1

  Re-run after adding new dependencies — only missing items are processed.
#>

[CmdletBinding()]
param(
  [switch]$SkipPlugins,    # don't bootstrap lazy.nvim / parsers
  [switch]$SkipScoop,      # assume scoop + packages already installed
  [string]$NvimConfigRoot  # override config root (default: this script's grandparent)
)

$ErrorActionPreference = 'Stop'
$InformationPreference  = 'Continue'
$ProgressPreference     = 'SilentlyContinue'  # speeds up Invoke-WebRequest

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Write-Step  ($msg) { Write-Host "▶ $msg" -ForegroundColor Cyan }
function Write-OK    ($msg) { Write-Host "✓ $msg" -ForegroundColor Green }
function Write-Skip  ($msg) { Write-Host "↷ $msg" -ForegroundColor DarkGray }
function Write-Warn2 ($msg) { Write-Host "⚠ $msg" -ForegroundColor Yellow }
function Write-Err2  ($msg) { Write-Host "✗ $msg" -ForegroundColor Red }

function Test-CommandExists {
  param([Parameter(Mandatory)][string]$Name)
  return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Invoke-Native {
  param(
    [Parameter(Mandatory)][string]$File,
    [string[]]$Args = @(),
    [switch]$IgnoreExitCode
  )
  & $File @Args
  if (-not $IgnoreExitCode -and $LASTEXITCODE -ne 0) {
    throw "Command failed ($LASTEXITCODE): $File $($Args -join ' ')"
  }
}

# ---------------------------------------------------------------------------
# Resolve paths
# ---------------------------------------------------------------------------

if (-not $NvimConfigRoot) {
  $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
  $NvimConfigRoot = Split-Path -Parent $scriptDir
}
$NvimConfigRoot = (Resolve-Path $NvimConfigRoot).Path

$expectedConfigPath = Join-Path $env:LOCALAPPDATA 'nvim'
Write-Information ""
Write-Information "Config repo : $NvimConfigRoot"
Write-Information "Nvim config : $expectedConfigPath"
Write-Information ""

# ---------------------------------------------------------------------------
# Step 1: Scoop
# ---------------------------------------------------------------------------

if ($SkipScoop) {
  Write-Skip "Step 1: scoop install (skipped by flag)"
} else {
  Write-Step "Step 1: scoop"
  if (Test-CommandExists 'scoop') {
    Write-OK  "scoop already installed"
  } else {
    Write-Information "Installing scoop ..."
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
    Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
    if (-not (Test-CommandExists 'scoop')) {
      throw "scoop install failed — see https://scoop.sh"
    }
    Write-OK "scoop installed"
  }
}

# ---------------------------------------------------------------------------
# Step 2: Buckets
# ---------------------------------------------------------------------------

if (-not $SkipScoop) {
  Write-Step "Step 2: scoop buckets"

  $existingBuckets = (& scoop bucket list 2>$null | Out-String) -split "`n"
  $needBuckets = @('extras','versions','main')
  foreach ($b in $needBuckets) {
    if ($existingBuckets -match "^\s*$b\b") {
      Write-Skip "bucket: $b"
    } else {
      Write-Information "  scoop bucket add $b"
      try { Invoke-Native scoop @('bucket','add',$b) } catch { Write-Warn2 "bucket add $b failed: $_" }
    }
  }
}

# ---------------------------------------------------------------------------
# Step 3: Scoop packages
# ---------------------------------------------------------------------------

# Logical name → scoop package id (sometimes different)
$ScoopPackages = [ordered]@{
  'git'       = 'git'
  'pwsh'      = 'pwsh'        # PowerShell 7+
  'neovim'    = 'neovim'
  'neovide'   = 'neovide'
  'llvm'      = 'llvm'        # provides clang, clang-cl, lld, clangd
  'fd'        = 'fd'
  'rg'        = 'ripgrep'
  'lazygit'   = 'lazygit'
  'fzf'       = 'fzf'
  'zoxide'    = 'zoxide'
  'python'    = 'python'
  'node'      = 'nodejs-lts'
  'make'      = 'make'
  'yazi'      = 'yazi'
  'bat'       = 'bat'
  'gawk'      = 'gawk'
  'sed'       = 'sed'
  'grep'      = 'grep'
  'less'      = 'less'
  '7zip'      = '7zip'
  'gtags'     = 'global'      # GNU GLOBAL — provides gtags
  'go'        = 'go'          # for building cindex-uefilter (csearch fork)
}

if (-not $SkipScoop) {
  Write-Step "Step 3: scoop packages"

  $installed = (& scoop list 2>$null | Out-String) -split "`n"
  foreach ($entry in $ScoopPackages.GetEnumerator()) {
    $logical = $entry.Key
    $pkg     = $entry.Value
    if ($installed -match "^\s*$([regex]::Escape($pkg))\s") {
      Write-Skip "$logical ($pkg)"
      continue
    }
    Write-Information "  scoop install $pkg"
    try {
      Invoke-Native scoop @('install',$pkg)
      Write-OK "$logical installed"
    } catch {
      Write-Warn2 "$logical ($pkg) install failed: $_"
    }
  }
}

# ---------------------------------------------------------------------------
# Step 4: Verify nvim config root
# ---------------------------------------------------------------------------

Write-Step "Step 4: nvim config root"

if (Test-Path $expectedConfigPath) {
  $existing = (Resolve-Path $expectedConfigPath).Path
  if ($existing -ieq $NvimConfigRoot) {
    Write-OK "nvim config already at $expectedConfigPath"
  } else {
    Write-Warn2 "nvim config exists at $expectedConfigPath but does not match repo path"
    Write-Warn2 "  existing: $existing"
    Write-Warn2 "  repo    : $NvimConfigRoot"
    Write-Warn2 "  → leaving existing config as-is. If you want to switch, move/remove it manually."
  }
} else {
  $parent = Split-Path -Parent $expectedConfigPath
  if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }

  if ($NvimConfigRoot -ieq $expectedConfigPath) {
    Write-OK "config repo is already at $expectedConfigPath"
  } else {
    Write-Information "  Creating directory junction $expectedConfigPath -> $NvimConfigRoot"
    cmd.exe /c "mklink /J `"$expectedConfigPath`" `"$NvimConfigRoot`"" | Out-Null
    if (-not (Test-Path $expectedConfigPath)) {
      throw "Failed to create junction; create it manually."
    }
    Write-OK "junction created"
  }
}

# ---------------------------------------------------------------------------
# Step 5 + 6: lazy.nvim bootstrap + treesitter parsers
# ---------------------------------------------------------------------------

if ($SkipPlugins) {
  Write-Skip "Steps 5-6: plugin / parser bootstrap (skipped by flag)"
  Write-Information ""
  Write-OK "DONE — plugin bootstrap skipped"
  exit 0
}

# Locate nvim — prefer scoop's, fall back to PATH lookup
$nvim = $null
foreach ($candidate in @(
  'C:\Program Files\Neovim\bin\nvim.exe',
  "$env:USERPROFILE\scoop\apps\neovim\current\bin\nvim.exe",
  'nvim'
)) {
  if (Test-Path $candidate -ErrorAction SilentlyContinue) { $nvim = $candidate; break }
  if ($candidate -eq 'nvim' -and (Test-CommandExists 'nvim')) { $nvim = (Get-Command nvim).Source; break }
}
if (-not $nvim) {
  Write-Err2 "nvim.exe not found — cannot bootstrap plugins. Install neovim manually then re-run with -SkipScoop."
  exit 1
}
Write-Information "Using nvim: $nvim"

# Step 5: lazy.nvim sync (idempotent — installs missing plugins)
Write-Step "Step 5: lazy.nvim sync (this can take a few minutes on first run)"
try {
  & $nvim --headless '+Lazy! sync' '+qa' 2>&1 | Out-Host
  Write-OK "lazy sync complete"
} catch {
  Write-Warn2 "lazy sync had issues: $_"
}

# Step 6: treesitter parsers — main branch needs cc on PATH
$llvmBin = 'C:\Program Files\LLVM\bin'
if (-not (Test-Path $llvmBin)) {
  $llvmBin = "$env:USERPROFILE\scoop\apps\llvm\current\bin"
}
if (Test-Path $llvmBin) {
  $env:PATH = "$llvmBin;$env:PATH"
  Write-Information "Added $llvmBin to PATH for parser compile"
} else {
  Write-Warn2 "LLVM bin not found — treesitter parser compile may fail"
}

Write-Step "Step 6: treesitter parsers (c, cpp, hlsl)"
$tsLua = @'
local TS = require('nvim-treesitter')
local done = false
TS.install({'c','cpp','hlsl'}, { summary = true }):await(function() done = true end)
vim.wait(180000, function() return done end, 200)
'@
try {
  & $nvim --headless '+Lazy! load nvim-treesitter' "+lua $tsLua" '+qa' 2>&1 | Out-Host
  Write-OK "treesitter parsers installed"
} catch {
  Write-Warn2 "treesitter install had issues: $_"
}

# ---------------------------------------------------------------------------
# Step 7: Build cindex-uefilter (csearch fork — sub-second :UEPrepare grep)
# ---------------------------------------------------------------------------

Write-Step "Step 7: cindex-uefilter (csearch fork for sub-second grep)"
$cindexUe = "$env:USERPROFILE\go\bin\cindex-uefilter.exe"
if (Test-Path $cindexUe) {
  Write-Skip "cindex-uefilter already built at $cindexUe"
} elseif (Test-CommandExists 'go') {
  $toolDir = Join-Path $NvimConfigRoot 'tools\cindex-uefilter'
  if (-not (Test-Path $toolDir)) {
    Write-Warn2 "tools/cindex-uefilter not found at $toolDir — skipping"
  } else {
    Write-Information "  building from $toolDir"
    Push-Location $toolDir
    try {
      $env:GOPROXY = 'https://goproxy.cn,direct'
      $env:GOSUMDB = 'off'
      Invoke-Native go @('install','./...')
      # Also ensure plain csearch is on PATH (used at query time).
      if (-not (Test-Path "$env:USERPROFILE\go\bin\csearch.exe")) {
        Invoke-Native go @('install','github.com/google/codesearch/cmd/csearch@latest')
      }
      Write-OK "cindex-uefilter built; csearch installed"
    } catch {
      Write-Warn2 "cindex-uefilter build failed: $_"
    } finally {
      Pop-Location
    }
  }
} else {
  Write-Warn2 "go not on PATH — skipping cindex-uefilter build (sub-second grep will be unavailable)"
}

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------

Write-Information ""
Write-Information "════════════════════════════════════════════════════════════════"
Write-OK "Installation complete."
Write-Information "════════════════════════════════════════════════════════════════"
Write-Information ""
Write-Information "Next steps:"
Write-Information "  1. Open a new pwsh 7 window so PATH picks up scoop apps"
Write-Information "  2. Launch Neovide:    neovide"
Write-Information "  3. Inside nvim:       :checkhealth   to verify everything"
Write-Information ""
