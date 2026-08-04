[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$EngineRoot,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Project,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Target,

  [Parameter(Mandatory = $true)]
  [ValidateSet("Android")]
  [string]$Platform,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$Configuration,

  [switch]$WaitMutex,
  [switch]$FromMsBuild
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$buildBat = Join-Path $EngineRoot "Engine\Build\BatchFiles\Build.bat"
if (-not (Test-Path -LiteralPath $buildBat -PathType Leaf)) {
  throw "Build.bat not found: $buildBat"
}
if (-not (Test-Path -LiteralPath $Project -PathType Leaf)) {
  throw ".uproject not found: $Project"
}

$actionsPath = Join-Path ([IO.Path]::GetTempPath()) (
  "nvim-ue-so-actions-{0}-{1}.json" -f $PID, [Guid]::NewGuid().ToString("N")
)

function Invoke-Ubt {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [Parameter(Mandatory = $true)]
    [string]$Phase
  )

  & $script:buildBat @Arguments
  if ($LASTEXITCODE -ne 0) {
    throw "UBT $Phase failed with exit code $LASTEXITCODE"
  }
}

try {
  $exportArgs = @(
    $Target,
    $Platform,
    $Configuration,
    "-Project=$Project",
    "-WriteOutdatedActions=$actionsPath"
  )
  if ($WaitMutex) { $exportArgs += "-WaitMutex" }
  if ($FromMsBuild) { $exportArgs += "-FromMsBuild" }

  Write-Host "[UE SO] phase 1/2: exporting compile/link actions (deploy is not executed)"
  Invoke-Ubt -Arguments $exportArgs -Phase "action export"

  if (-not (Test-Path -LiteralPath $actionsPath -PathType Leaf)) {
    throw "UBT did not create the actions file: $actionsPath"
  }

  $executeArgs = @("-Mode=Execute", "-Actions=$actionsPath")
  if ($WaitMutex) { $executeArgs += "-WaitMutex" }

  Write-Host "[UE SO] phase 2/2: executing compile/link actions"
  Invoke-Ubt -Arguments $executeArgs -Phase "action execution"
  Write-Host "[UE SO] completed without Android deploy/APK packaging"
}
finally {
  Remove-Item -LiteralPath $actionsPath -Force -ErrorAction SilentlyContinue
}
