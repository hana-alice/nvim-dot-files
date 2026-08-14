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
if ($parseErrors.Count -gt 0) { throw "deploy script parse failed" }

$wanted = @(
  "Resolve-RootTransport",
  "Resolve-RunAsTransport",
  "Resolve-DeployTransport",
  "Invoke-AdbRunAs"
)
$functions = $ast.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $wanted -contains $node.Name
}, $true)
if ($functions.Count -ne $wanted.Count) {
  throw "run-as transport functions are incomplete"
}
foreach ($function in $functions) { Invoke-Expression $function.Extent.Text }

$script:Mode = "run-as"
$script:Calls = @()
$script:Package = "com.example.samplegame"
$script:PreferRunAs = $false
$packageDump = @"
    appId=10123
    primaryCpuAbi=arm64-v8a
    legacyNativeLibraryDir=/data/app/example/lib
    flags=[ DEBUGGABLE HAS_CODE ]
"@

function Invoke-Adb {
  param([string[]]$Arguments, [switch]$AllowFailure)
  $key = $Arguments -join " "
  $script:Calls += $key
  if ($key -eq "shell id -u") {
    return [PSCustomObject]@{ Code = 0; Text = "2000" }
  }
  if ($key -eq "shell su 0 id -u") {
    return [PSCustomObject]@{ Code = 127; Text = "su: inaccessible or not found" }
  }
  if ($key -eq "shell getprop ro.build.type") {
    return [PSCustomObject]@{ Code = 0; Text = "user" }
  }
  if ($key -eq "shell getprop ro.debuggable") {
    return [PSCustomObject]@{ Code = 0; Text = "0" }
  }
  if ($key -eq "shell run-as com.example.samplegame id -u") {
    return [PSCustomObject]@{ Code = 0; Text = "10123" }
  }
  if ($key -eq "shell am help") {
    return [PSCustomObject]@{ Code = 1; Text = "--attach-agent-bind <agent>" }
  }
  if ($key -eq "shell getprop ro.build.version.sdk") {
    return [PSCustomObject]@{ Code = 0; Text = "35" }
  }
  if ($key -eq "shell getprop ro.product.cpu.abilist") {
    return [PSCustomObject]@{ Code = 0; Text = "arm64-v8a,armeabi-v7a" }
  }
  if ($key -eq "shell run-as com.example.samplegame stat code_cache/nvim-ue-so/libUE4.so") {
    return [PSCustomObject]@{ Code = 0; Text = "ok" }
  }
  throw "unexpected mock adb arguments: $key"
}

$transport = Resolve-DeployTransport -PackageDump $packageDump
if ($transport.Kind -ne "run-as-agent" -or $transport.AppUid -ne "10123" -or
    $transport.ApiLevel -ne "35") {
  throw "debuggable run-as transport was not selected on a capability-compatible API level"
}
Invoke-AdbRunAs -Arguments @("stat", "code_cache/nvim-ue-so/libUE4.so") | Out-Null
if ($script:Calls[-1] -ne "shell run-as com.example.samplegame stat code_cache/nvim-ue-so/libUE4.so") {
  throw "run-as command shape is wrong"
}

$script:Calls = @()
$script:PreferRunAs = $true
function Invoke-Adb {
  param([string[]]$Arguments, [switch]$AllowFailure)
  $key = $Arguments -join " "
  $script:Calls += $key
  if ($key -eq "shell run-as com.example.samplegame id -u") {
    return [PSCustomObject]@{ Code = 0; Text = "10123" }
  }
  if ($key -eq "shell am help") {
    return [PSCustomObject]@{ Code = 0; Text = "--attach-agent-bind <agent>" }
  }
  if ($key -eq "shell getprop ro.build.version.sdk") {
    return [PSCustomObject]@{ Code = 0; Text = "35" }
  }
  if ($key -eq "shell getprop ro.product.cpu.abilist") {
    return [PSCustomObject]@{ Code = 0; Text = "arm64-v8a,armeabi-v7a" }
  }
  throw "prefer-run-as unexpectedly probed root or used unsupported adb arguments: $key"
}
$preferred = Resolve-DeployTransport -PackageDump $packageDump
if ($preferred.Kind -ne "run-as-agent" -or $preferred.AppUid -ne "10123") {
  throw "PreferRunAs did not select app-private transport"
}
if (($script:Calls -join "|") -like "*shell id -u*" -or
    ($script:Calls -join "|") -like "*shell su 0 id -u*") {
  throw "PreferRunAs probed root transport"
}
$script:PreferRunAs = $false

$script:Calls = @()
$failed = $false
try {
  Resolve-RunAsTransport -PackageDump ($packageDump -replace "DEBUGGABLE ", "") | Out-Null
}
catch {
  if ($_.Exception.Message -like "*not debuggable*") { $failed = $true } else { throw }
}
if (-not $failed) { throw "non-debuggable package was accepted" }
if (($script:Calls -join "|") -like "*run-as*") {
  throw "non-debuggable package reached run-as"
}

$script:Calls = @()
$failed = $false
try {
  Resolve-RunAsTransport -PackageDump (
    $packageDump -replace "primaryCpuAbi=arm64-v8a", "primaryCpuAbi=x86_64"
  ) | Out-Null
}
catch {
  if ($_.Exception.Message -like "*primaryCpuAbi=arm64-v8a*") {
    $failed = $true
  }
  else { throw }
}
if (-not $failed) { throw "non-arm64 installed app was accepted" }

$script:Calls = @()
$failed = $false
try {
  function Invoke-Adb {
    param([string[]]$Arguments, [switch]$AllowFailure)
    $key = $Arguments -join " "
    $script:Calls += $key
    if ($key -eq "shell run-as com.example.samplegame id -u") {
      return [PSCustomObject]@{ Code = 0; Text = "10123" }
    }
    if ($key -eq "shell am help") {
      return [PSCustomObject]@{ Code = 0; Text = "no startup agent option" }
    }
    throw "unexpected mock adb arguments: $key"
  }
  Resolve-RunAsTransport -PackageDump $packageDump | Out-Null
}
catch {
  if ($_.Exception.Message -like "*--attach-agent-bind*") {
    $failed = $true
  }
  else { throw }
}
if (-not $failed) { throw "missing startup-agent capability was accepted" }

Write-Output "PASS debuggable run-as transport"
