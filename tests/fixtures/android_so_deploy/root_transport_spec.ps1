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
  "Resolve-RootTransport",
  "Invoke-AdbRoot"
)
$functions = $ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $wanted -contains $node.Name
}, $true)
if ($functions.Count -ne $wanted.Count) {
  throw "root transport functions are incomplete"
}
foreach ($function in $functions) {
  Invoke-Expression $function.Extent.Text
}

$script:Mode = "direct"
$script:Calls = @()
$script:Serial = "SERIAL-FIXTURE"

function Invoke-Adb {
  param(
    [string[]]$Arguments,
    [switch]$AllowFailure
  )

  $key = $Arguments -join " "
  $script:Calls += $key
  if ($key -eq "shell id -u") {
    if ($script:Mode -eq "direct") {
      return [PSCustomObject]@{ Code = 0; Text = "0" }
    }
    return [PSCustomObject]@{ Code = 0; Text = "2000" }
  }
  if ($key -eq "shell su 0 id -u") {
    if ($script:Mode -eq "su0") {
      return [PSCustomObject]@{ Code = 0; Text = "0" }
    }
    return [PSCustomObject]@{ Code = 127; Text = "su: inaccessible or not found" }
  }
  if ($key -eq "shell getprop ro.build.type") {
    return [PSCustomObject]@{ Code = 0; Text = "user" }
  }
  if ($key -eq "shell getprop ro.debuggable") {
    return [PSCustomObject]@{ Code = 0; Text = "0" }
  }
  if ($key -like "shell stat *" -or $key -like "shell su 0 stat *") {
    return [PSCustomObject]@{ Code = 0; Text = "ok" }
  }
  throw "unexpected mock adb arguments: $key"
}

$script:RootTransport = Resolve-RootTransport -AllowUnavailable
if ($script:RootTransport -ne "adbd-root") {
  throw "direct root adbd was not selected"
}
Invoke-AdbRoot -Arguments @("stat", "-c", "%u", "/data/app/lib.so") | Out-Null
if ($script:Calls[-1] -ne "shell stat -c %u /data/app/lib.so") {
  throw "direct root command was unexpectedly wrapped"
}

$script:Mode = "su0"
$script:Calls = @()
$script:RootTransport = Resolve-RootTransport -AllowUnavailable
if ($script:RootTransport -ne "su-0") {
  throw "verified su 0 transport was not selected"
}
Invoke-AdbRoot -Arguments @("stat", "-c", "%u", "/data/app/lib.so") | Out-Null
if ($script:Calls[-1] -ne "shell su 0 stat -c %u /data/app/lib.so") {
  throw "su 0 root command shape is wrong"
}

$script:Mode = "unavailable"
$script:Calls = @()
$script:RootTransport = Resolve-RootTransport -AllowUnavailable
if ($null -ne $script:RootTransport) {
  throw "non-root device unexpectedly selected a root transport"
}
if ($script:Calls.Count -ne 4) {
  throw "root failure performed commands beyond the four read-only capability probes"
}

Write-Output "PASS root transport capability selection"
