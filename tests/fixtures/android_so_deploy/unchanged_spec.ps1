param([Parameter(Mandatory = $true)][string]$DeployScript)
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$tokens = $null
$parseErrors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path -LiteralPath $DeployScript), [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) { throw "deploy script parse failed: $parseErrors" }
$helper = $ast.Find({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $node.Name -eq "Test-DeployedSoUnchanged"
}, $true)
Invoke-Expression $helper.Extent.Text
$script:Hash = "a" * 64
$script:AgentHash = "b" * 64
$script:Generation = "g-" + ("c" * 32)
$script:Root = [PSCustomObject]@{ Code = 0; Text = "$script:Hash /installed/libUE4.so" }
$script:Pointer = [PSCustomObject]@{ Code = 0; Text = $script:Generation }
$script:Manifest = [PSCustomObject]@{ Code = 0; Text = "" }
$script:ThrowProbe = $false
function Invoke-AdbRoot {
  param([string[]]$Arguments, [switch]$AllowFailure)
  if ($script:ThrowProbe) { throw "probe unavailable" }
  if (-not $AllowFailure -or $Arguments[0] -ne "sha256sum") { throw "unexpected root command" }
  return $script:Root
}
function Invoke-AdbRunAs {
  param([string[]]$Arguments, [switch]$AllowFailure)
  if ($script:ThrowProbe) { throw "probe unavailable" }
  if (-not $AllowFailure -or $Arguments[0] -ne "cat") { throw "unexpected run-as command" }
  if ($Arguments[1] -eq "code_cache/nvim-ue-so/current") { return $script:Pointer }
  if ($Arguments[1] -ne "code_cache/nvim-ue-so/$script:Generation/manifest") { throw "wrong generation" }
  return $script:Manifest
}
function Get-Sha256Hex { param([string]$Path) return $script:AgentHash }
function Check {
  param([string]$Kind, [bool]$Expected)
  $actual = Test-DeployedSoUnchanged -Transport @{Kind=$Kind} -TargetSo "/installed/libUE4.so" `
    -LocalHash $script:Hash -HostAgent "agent.so" -Current "code_cache/nvim-ue-so/current" `
    -VersionCode "1" -ApkFingerprint "apk-fingerprint"
  if ($actual -ne $Expected) { throw "unexpected unchanged=$actual kind=$Kind expected=$Expected" }
}
Check "root" $true
$script:Root.Text = ("d" * 64) + " /installed/libUE4.so"
Check "root" $false
$script:Root.Text = "bad hash"
Check "root" $false
$script:Root.Code = 1
Check "root" $false
$script:ThrowProbe = $true
Check "root" $false
Check "run-as-agent" $false
$script:ThrowProbe = $false
$valid = "generation=$script:Generation`ninstalled_version_code=1`ninstalled_apk_fingerprint=apk-fingerprint`nso_sha256=$script:Hash`nagent_sha256=$script:AgentHash`n"
$script:Manifest.Text = $valid
Check "run-as-agent" $true
foreach ($replacement in @(
  @("agent_sha256=$script:AgentHash", "agent_sha256=" + ("d" * 64)),
  @("so_sha256=$script:Hash", "so_sha256=" + ("d" * 64)),
  @("installed_version_code=1", "installed_version_code=2"),
  @("installed_apk_fingerprint=apk-fingerprint", "installed_apk_fingerprint=other"),
  @("generation=$script:Generation", "generation=g-" + ("d" * 32)),
  @("agent_sha256=$script:AgentHash", "agent_sha256=bad")
)) {
  $script:Manifest.Text = $valid.Replace($replacement[0], $replacement[1])
  Check "run-as-agent" $false
}
$script:Manifest.Text = $valid + "so_sha256=$script:Hash`n"
Check "run-as-agent" $false
$script:Manifest.Text = "bad format"
Check "run-as-agent" $false
$script:Manifest.Code = 1
Check "run-as-agent" $false
$script:Pointer.Text = "../escape"
Check "run-as-agent" $false
$script:Pointer.Code = 1
Check "run-as-agent" $false
Write-Output "PASS unchanged SO root + manifest + fail-open"
