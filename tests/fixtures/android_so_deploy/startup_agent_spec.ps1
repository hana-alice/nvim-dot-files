[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$DeployScript,
  [Parameter(Mandatory = $true)][string]$LaunchScript,
  [Parameter(Mandatory = $true)][string]$AgentSource
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

foreach ($path in @($DeployScript, $LaunchScript, $AgentSource)) {
  if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
    throw "required startup-agent file is missing: $path"
  }
}

foreach ($path in @($DeployScript, $LaunchScript)) {
  $tokens = $null
  $parseErrors = $null
  [void][Management.Automation.Language.Parser]::ParseFile(
    (Resolve-Path -LiteralPath $path),
    [ref]$tokens,
    [ref]$parseErrors
  )
  if ($parseErrors.Count -gt 0) {
    throw "PowerShell parse failed: $path"
  }
}

$deploy = Get-Content -LiteralPath $DeployScript -Raw
$launch = Get-Content -LiteralPath $LaunchScript -Raw
$agent = Get-Content -LiteralPath $AgentSource -Raw

foreach ($required in @(
  "Agent_OnAttach",
  "JVMTI_EVENT_CLASS_PREPARE",
  "addNativePath",
  "nativeLibraryPathElements",
  "findLibrary",
  "pthread_create",
  'write_status("redirected"',
  'write_status("mapped"',
  "maps_contains_exact_path",
  "for (int attempt = 0;; ++attempt)",
  "MAP_MONITOR_INTERVAL_US",
  'fail_process("private libUE4.so mapping did not appear before timeout")'
)) {
  if ($agent.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
    throw "startup agent contract is missing: $required"
  }
}

foreach ($forbidden in @(
  "dlopen(g_target",
  "JVM_NativeLoad",
  "RegisterNatives",
  "class_suffix",
  "strstr(line, path)",
  "API 34 contract"
)) {
  if ($agent.IndexOf($forbidden, [StringComparison]::Ordinal) -ge 0) {
    throw "startup agent uses a rejected preload/native-hook mechanism: $forbidden"
  }
}

foreach ($required in @(
  "function Build-StartupAgent",
  "function Assert-SourceSoName",
  "DT_SONAME is not libUE4.so",
  "run-as/startup-agent",
  "libnvim_ue_so_agent.so",
  "installed APK/signature unchanged; tool files are limited to app-private code_cache/nvim-ue-so",
  "Enter-OperationMutex",
  "published generation=",
  "installed_apk_fingerprint=",
  'if ($operationSucceeded -and $generationPublished',
  '$currentProbe = Invoke-AdbRunAs'
)) {
  if ($deploy.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
    throw "deploy contract is missing: $required"
  }
}

foreach ($forbidden in @(
  "UEInstallAndroidSOBaseline",
  "wrap.sh",
  "adb install",
  "adb uninstall",
  '"am", "start"',
  '"monkey"'
)) {
  if ($deploy.IndexOf($forbidden, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw "deploy unexpectedly contains APK mutation or launch path: $forbidden"
  }
}

foreach ($required in @(
  "--attach-agent-bind",
  'original=$script:InstalledSo',
  "Resolve-LauncherComponent",
  "Resolve-AppDataDirectory",
  "Resolve-InstalledLibrary",
  "Resolve-PrivateDeployment",
  "Wait-AgentMapped",
  "Assert-PrivateMapping",
  "Stop-FailedLaunch",
  "Enter-OperationMutex",
  "Get-InstalledApkFingerprint",
  "normal APK launch; no app-private SO deploy is staged"
)) {
  if ($launch.IndexOf($required, [StringComparison]::Ordinal) -lt 0) {
    throw "launch contract is missing: $required"
  }
}

foreach ($scriptText in @($deploy, $launch)) {
  if ([regex]::IsMatch(
      $scriptText,
      '\$apiLevel\s+-(?:eq|ne|in|notin|gt|ge|lt|le|match|notmatch|like|notlike)\b',
      [Text.RegularExpressions.RegexOptions]::IgnoreCase)) {
    throw "startup-agent transport gates an observed capability on an API-level comparison"
  }
}

$combined = $deploy + "`n" + $launch + "`n" + $agent
foreach ($privateIdentity in @("com.private.forbidden", "PRIVATE_DEVICE_SERIAL")) {
  if ($combined.IndexOf($privateIdentity, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
    throw "runtime code hardcodes a private package/device identity: $privateIdentity"
  }
}

$launchTokens = $null
$launchErrors = $null
$launchAst = [Management.Automation.Language.Parser]::ParseFile(
  (Resolve-Path -LiteralPath $LaunchScript),
  [ref]$launchTokens,
  [ref]$launchErrors
)
$wantedFunctions = @(
  "Resolve-AppDataDirectory",
  "Resolve-InstalledLibrary",
  "Resolve-PrivateDeployment",
  "Get-StringSha256",
  "Get-InstalledApkFingerprint",
  "Test-MapsExactPath",
  "Assert-PrivateMapping",
  "Stop-FailedLaunch"
)
$functionAsts = $launchAst.FindAll({
  param($node)
  $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
    $wantedFunctions -contains $node.Name
}, $true)
if ($functionAsts.Count -ne $wantedFunctions.Count) {
  throw "launch helper functions are incomplete"
}
foreach ($functionAst in $functionAsts) {
  Invoke-Expression $functionAst.Extent.Text
}

$script:Package = "com.example.samplegame"
$script:InstalledSo = "/data/app/example/lib/arm64/libUE4.so"
$script:PrivateRootRelative = "code_cache/nvim-ue-so"
$script:CurrentRelative = "$script:PrivateRootRelative/current"
$script:MockGeneration = "g-0123456789abcdef0123456789abcdef"
$script:MockCurrentPresent = $true
$script:MockRunning = $true
$script:MockSoHash = "a" * 64
$script:MockAgentHash = "b" * 64
$script:SoAbsolute = "/data/user/0/com.example.samplegame/code_cache/nvim-ue-so/$script:MockGeneration/libUE4.so"
$script:MockMaps = @{
  "101" = "7000-8000 r-xp 0 00:00 0 $script:SoAbsolute"
  "202" = "9000-a000 r-xp 0 00:00 0 /system/lib64/libc.so"
}

function Invoke-Adb {
  param([string[]]$Arguments, [switch]$AllowFailure)
  $key = $Arguments -join " "
  if ($key -eq "shell test -f /data/app/example/lib/arm64/arm64/libUE4.so") {
    return [PSCustomObject]@{ Code = 1; Text = "" }
  }
  if ($key -eq "shell test -f /data/app/example/lib/arm64/libUE4.so") {
    return [PSCustomObject]@{ Code = 0; Text = "" }
  }
  if ($key -eq "shell pm path com.example.samplegame") {
    return [PSCustomObject]@{
      Code = 0
      Text = "package:/data/app/example/base.apk`npackage:/data/app/example/split_config.apk"
    }
  }
  if ($key -eq "shell stat -c %n:%s:%Y:%i /data/app/example/base.apk") {
    return [PSCustomObject]@{ Code = 0; Text = "/data/app/example/base.apk:100:10:1" }
  }
  if ($key -eq "shell stat -c %n:%s:%Y:%i /data/app/example/split_config.apk") {
    return [PSCustomObject]@{ Code = 0; Text = "/data/app/example/split_config.apk:200:20:2" }
  }
  if ($key -eq "shell pidof com.example.samplegame") {
    if (-not $script:MockRunning) {
      return [PSCustomObject]@{ Code = 1; Text = "" }
    }
    return [PSCustomObject]@{ Code = 0; Text = "101 202" }
  }
  if ($key -eq "shell am force-stop com.example.samplegame") {
    $script:MockRunning = $false
    return [PSCustomObject]@{ Code = 0; Text = "" }
  }
  throw "unexpected mock adb arguments: $key"
}

function Invoke-AdbRunAs {
  param([string[]]$Arguments, [switch]$AllowFailure)
  $key = $Arguments -join " "
  if ($key -eq "pwd") {
    return [PSCustomObject]@{ Code = 0; Text = "/data/user/0/com.example.samplegame" }
  }
  if ($key -eq "test -d code_cache/nvim-ue-so") {
    return [PSCustomObject]@{ Code = 0; Text = "" }
  }
  if ($key -eq "cat code_cache/nvim-ue-so/current") {
    if ($script:MockCurrentPresent) {
      return [PSCustomObject]@{ Code = 0; Text = $script:MockGeneration }
    }
    return [PSCustomObject]@{ Code = 1; Text = "missing" }
  }
  $generationRoot = "code_cache/nvim-ue-so/$script:MockGeneration"
  if ($key -eq "test -r $generationRoot/libUE4.so" -or
      $key -eq "test -x $generationRoot/libnvim_ue_so_agent.so" -or
      $key -eq "test -r $generationRoot/manifest") {
    return [PSCustomObject]@{ Code = 0; Text = "" }
  }
  if ($key -eq "cat $generationRoot/manifest") {
    return [PSCustomObject]@{
      Code = 0
      Text = "generation=$script:MockGeneration`ninstalled_version_code=12345`ninstalled_apk_fingerprint=$('c' * 64)`nso_sha256=$('a' * 64)`nagent_sha256=$('b' * 64)`n"
    }
  }
  if ($key -eq "sha256sum $generationRoot/libUE4.so") {
    return [PSCustomObject]@{ Code = 0; Text = "$script:MockSoHash  $generationRoot/libUE4.so" }
  }
  if ($key -eq "sha256sum $generationRoot/libnvim_ue_so_agent.so") {
    return [PSCustomObject]@{ Code = 0; Text = "$script:MockAgentHash  $generationRoot/libnvim_ue_so_agent.so" }
  }
  if ($key -match "^cat /proc/(\d+)/maps$") {
    $pidKey = $matches[1]
    if ($script:MockMaps.ContainsKey($pidKey)) {
      return [PSCustomObject]@{ Code = 0; Text = $script:MockMaps[$pidKey] }
    }
    return [PSCustomObject]@{ Code = 1; Text = "denied" }
  }
  throw "unexpected mock run-as arguments: $key"
}

if ((Resolve-AppDataDirectory) -ne "/data/user/0/com.example.samplegame") {
  throw "app data directory was not derived from run-as pwd"
}
$packageDump = "    nativeLibraryDir=/data/app/example/lib/arm64"
if ((Resolve-InstalledLibrary -PackageDump $packageDump) -ne $script:InstalledSo) {
  throw "installed libUE4.so was not resolved from package metadata"
}
$apkFingerprint = Get-InstalledApkFingerprint -PackageDump "lastUpdateTime=2026-08-06 12:00:00"
if ($apkFingerprint -notmatch "^[0-9a-f]{64}$" -or
    $apkFingerprint -eq (Get-InstalledApkFingerprint -PackageDump "lastUpdateTime=2026-08-06 12:00:01")) {
  throw "installed APK filesystem fingerprint is not stable/change-sensitive"
}
$deployment = Resolve-PrivateDeployment
if ($deployment.Generation -ne $script:MockGeneration -or
    $deployment.InstalledVersionCode -ne "12345" -or
    $deployment.InstalledApkFingerprint -ne ("c" * 64) -or
    $deployment.SoRelative -ne "code_cache/nvim-ue-so/$script:MockGeneration/libUE4.so") {
  throw "atomic app-private generation was not resolved"
}
$script:MockSoHash = "d" * 64
$hashMismatchRejected = $false
try { [void](Resolve-PrivateDeployment) }
catch {
  if ($_.Exception.Message -like "*SO hash mismatch*") {
    $hashMismatchRejected = $true
  }
  else { throw }
}
if (-not $hashMismatchRejected) { throw "generation hash mismatch was accepted" }
$script:MockSoHash = "a" * 64
$script:MockCurrentPresent = $false
$partialRejected = $false
try { [void](Resolve-PrivateDeployment) }
catch {
  if ($_.Exception.Message -like "*staging is partial*") { $partialRejected = $true }
  else { throw }
}
if (-not $partialRejected) { throw "partial staging silently fell back to the APK" }
$script:MockCurrentPresent = $true

if (Test-MapsExactPath -Maps "1000-2000 r-xp 0 00:00 0 $script:SoAbsolute.previous" -Path $script:SoAbsolute) {
  throw "maps path comparison accepted a substring match"
}
if (-not (Test-MapsExactPath -Maps "1000-2000 r-xp 0 00:00 0 $script:SoAbsolute (deleted)" -Path $script:SoAbsolute)) {
  throw "maps path comparison rejected an exact deleted mapping"
}
Assert-PrivateMapping

$script:MockMaps["202"] = "a000-b000 r-xp 0 00:00 0 $script:InstalledSo"
$installedMappedRejected = $false
try { Assert-PrivateMapping }
catch {
  if ($_.Exception.Message -like "*Installed APK libUE4.so was mapped*") {
    $installedMappedRejected = $true
  }
  else { throw }
}
if (-not $installedMappedRejected) {
  throw "installed APK mapping was accepted"
}

$redirectStatus = $agent.IndexOf('write_status("redirected"', [StringComparison]::Ordinal)
$redirectPublish = $agent.IndexOf(
  "__atomic_store_n(&g_redirected, 1, __ATOMIC_RELEASE)",
  [StringComparison]::Ordinal
)
if ($redirectStatus -lt 0 -or $redirectPublish -lt 0 -or
    $redirectStatus -gt $redirectPublish) {
  throw "redirected status can overwrite the terminal mapped status"
}

Stop-FailedLaunch
if ($script:MockRunning) { throw "failed launch cleanup left the process running" }

Write-Output "PASS app-private startup agent contract"
