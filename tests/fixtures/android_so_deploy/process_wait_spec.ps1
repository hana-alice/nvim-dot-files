[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$DeployScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path -LiteralPath $DeployScript),
  [ref]$tokens,
  [ref]$parseErrors
)
if ($parseErrors.Count -gt 0) {
  throw "deploy script parse failed"
}

$wanted = @(
  "Get-PackageProcessIds",
  "Wait-PackageStopped"
)
$functions = $ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $wanted -contains $node.Name
}, $true)
if ($functions.Count -ne $wanted.Count) {
  throw "process wait functions are incomplete"
}
foreach ($function in $functions) {
  Invoke-Expression $function.Extent.Text
}

$script:Package = "com.example.fixture"
$script:Mode = "stop"
$script:PidPolls = 0

function Invoke-Adb {
  param(
    [string[]]$Arguments,
    [switch]$AllowFailure
  )

  if ($Arguments[1] -eq "pidof") {
    $script:PidPolls += 1
    if ($script:Mode -eq "stop") {
      if ($script:PidPolls -lt 3) {
        return [PSCustomObject]@{ Code = 0; Text = "101" }
      }
      return [PSCustomObject]@{ Code = 1; Text = "" }
    }
    return [PSCustomObject]@{ Code = 0; Text = "101" }
  }
  throw "unexpected mock adb arguments"
}

Wait-PackageStopped -TimeoutSeconds 1 -PollMilliseconds 1
if ($script:PidPolls -lt 3) {
  throw "stop waiter did not poll until the old process disappeared"
}

$script:Mode = "stuck"
$script:PidPolls = 0
$timedOut = $false
try {
  Wait-PackageStopped -TimeoutSeconds 1 -PollMilliseconds 10
}
catch {
  if ($_.Exception.Message -like "*did not stop within 1s*") {
    $timedOut = $true
  }
  else {
    throw
  }
}
if (-not $timedOut) {
  throw "stop waiter did not enforce its bounded timeout"
}

Write-Output "PASS package stop polling + bounded timeout"
