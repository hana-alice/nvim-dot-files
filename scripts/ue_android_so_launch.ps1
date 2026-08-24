[CmdletBinding()]
param(
  [string]$Adb = "adb",

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[^\s]+$")]
  [string]$Serial,

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9._-]+$")]
  [string]$Package,

  [int]$LoadTimeoutSeconds = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-ExternalCapture {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally { $ErrorActionPreference = $previousErrorActionPreference }
  $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
  if (-not $AllowFailure -and $exitCode -ne 0) {
    throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')`n$text"
  }
  return [PSCustomObject]@{ Code = $exitCode; Text = $text }
}

function Invoke-Adb {
  param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowFailure)
  return Invoke-ExternalCapture -FilePath $script:Adb `
    -Arguments (@("-s", $script:Serial) + $Arguments) `
    -AllowFailure:$AllowFailure
}

function Enter-OperationMutex {
  $material = "$script:Serial`n$script:Package"
  $hasher = [Security.Cryptography.SHA256]::Create()
  try {
    $key = ([BitConverter]::ToString(
      $hasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($material))
    ) -replace "-", "").Substring(0, 24).ToLowerInvariant()
  }
  finally { $hasher.Dispose() }

  $mutex = [Activator]::CreateInstance(
    [Threading.Mutex],
    [object[]]@($false, "NvimUESO-$key")
  )
  $acquired = $false
  try { $acquired = $mutex.WaitOne(0) }
  catch [Threading.AbandonedMutexException] { $acquired = $true }
  if (-not $acquired) {
    $mutex.Dispose()
    throw "Another SO deploy/launch operation is active for serial/package; refusing a concurrent uq/ul operation."
  }
  return $mutex
}

function Exit-OperationMutex {
  param($Mutex)
  if ($null -eq $Mutex) { return }
  try { $Mutex.ReleaseMutex() }
  finally { $Mutex.Dispose() }
}

function Invoke-AdbRunAs {
  param([Parameter(Mandatory = $true)][string[]]$Arguments, [switch]$AllowFailure)
  return Invoke-Adb -Arguments (
    @("shell", "run-as", $script:Package) + $Arguments
  ) -AllowFailure:$AllowFailure
}

function Get-StringSha256 {
  param([Parameter(Mandatory = $true)][string]$Value)

  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString(
      $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($Value))
    ) -replace "-", "").ToLowerInvariant()
  }
  finally { $sha256.Dispose() }
}

function Get-InstalledApkFingerprint {
  param([Parameter(Mandatory = $true)][string]$PackageDump)

  $lastUpdateMatch = [regex]::Match(
    $PackageDump,
    "(?m)^\s*lastUpdateTime=(.+?)\s*$"
  )
  if (-not $lastUpdateMatch.Success) {
    throw "Installed package lastUpdateTime not found: $script:Package"
  }
  $pathResult = Invoke-Adb -Arguments @(
    "shell", "pm", "path", $script:Package
  )
  $apkPaths = @(
    $pathResult.Text -split "\r?\n" |
      ForEach-Object { if ($_ -match "^package:(/\S+)$") { $matches[1] } } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Sort-Object
  )
  if ($apkPaths.Count -eq 0) {
    throw "Installed APK paths not found for package: $script:Package"
  }
  $identity = @("lastUpdateTime=$($lastUpdateMatch.Groups[1].Value.Trim())")
  foreach ($apkPath in $apkPaths) {
    $stat = Invoke-Adb -Arguments @(
      "shell", "stat", "-c", "%n:%s:%Y:%i", $apkPath
    )
    if ([string]::IsNullOrWhiteSpace($stat.Text)) {
      throw "Installed APK stat is empty: $apkPath"
    }
    $identity += $stat.Text.Trim()
  }
  return Get-StringSha256 -Value ($identity -join "`n")
}

function Resolve-LauncherComponent {
  $result = Invoke-Adb -Arguments @(
    "shell", "cmd", "package", "resolve-activity", "--brief",
    "-a", "android.intent.action.MAIN",
    "-c", "android.intent.category.LAUNCHER",
    $script:Package
  )
  $matches = [regex]::Matches(
    $result.Text,
    "(?m)^([A-Za-z0-9._-]+/[A-Za-z0-9._$-]+)\s*$"
  )
  if ($matches.Count -eq 0) {
    throw "Launcher activity not resolved for package: $script:Package"
  }
  return $matches[$matches.Count - 1].Groups[1].Value
}

function Resolve-PrivateDeployment {
  $rootExists = Invoke-AdbRunAs -Arguments @(
    "test", "-d", $script:PrivateRootRelative
  ) -AllowFailure
  $current = Invoke-AdbRunAs -Arguments @(
    "cat", $script:CurrentRelative
  ) -AllowFailure
  if ($current.Code -ne 0) {
    if ($rootExists.Code -eq 0) {
      throw "App-private SO staging is partial: managed directory exists without an atomic current generation. Run <Space>uq again before launching."
    }
    return $null
  }

  $generation = $current.Text.Trim()
  if ($generation -notmatch "^g-[0-9a-f]{32}$") {
    throw "App-private SO staging has an invalid generation pointer: $generation"
  }
  $generationRelative = "$script:PrivateRootRelative/$generation"
  $soRelative = "$generationRelative/libUE4.so"
  $agentRelative = "$generationRelative/libnvim_ue_so_agent.so"
  $manifestRelative = "$generationRelative/manifest"
  foreach ($required in @(
    @{ Path = $soRelative; Mode = "-r" },
    @{ Path = $agentRelative; Mode = "-x" },
    @{ Path = $manifestRelative; Mode = "-r" }
  )) {
    $probe = Invoke-AdbRunAs -Arguments @(
      "test", $required.Mode, $required.Path
    ) -AllowFailure
    if ($probe.Code -ne 0) {
      throw "App-private SO staging generation is incomplete: missing $($required.Path). Run <Space>uq again before launching."
    }
  }
  $manifest = (Invoke-AdbRunAs -Arguments @("cat", $manifestRelative)).Text
  if ($manifest -notmatch "(?m)^generation=$([regex]::Escape($generation))\s*$" -or
      $manifest -notmatch "(?m)^installed_version_code=(\d+)\s*$" -or
      $manifest -notmatch "(?m)^installed_apk_fingerprint=[0-9a-f]{64}\s*$" -or
      $manifest -notmatch "(?m)^so_sha256=[0-9a-f]{64}\s*$" -or
      $manifest -notmatch "(?m)^agent_sha256=[0-9a-f]{64}\s*$") {
    throw "App-private SO staging manifest is invalid for generation: $generation"
  }
  $installedVersionCode = [regex]::Match(
    $manifest,
    "(?m)^installed_version_code=(\d+)\s*$"
  ).Groups[1].Value
  $installedApkFingerprint = [regex]::Match(
    $manifest,
    "(?m)^installed_apk_fingerprint=([0-9a-f]{64})\s*$"
  ).Groups[1].Value
  $expectedSoHash = [regex]::Match(
    $manifest,
    "(?m)^so_sha256=([0-9a-f]{64})\s*$"
  ).Groups[1].Value
  $expectedAgentHash = [regex]::Match(
    $manifest,
    "(?m)^agent_sha256=([0-9a-f]{64})\s*$"
  ).Groups[1].Value
  foreach ($hashContract in @(
    @{ Path = $soRelative; Expected = $expectedSoHash; Label = "SO" },
    @{ Path = $agentRelative; Expected = $expectedAgentHash; Label = "agent" }
  )) {
    $hashResult = Invoke-AdbRunAs -Arguments @(
      "sha256sum", $hashContract.Path
    )
    $actualHash = ($hashResult.Text -split "\s+")[0].ToLowerInvariant()
    if ($actualHash -notmatch "^[0-9a-f]{64}$" -or
        $actualHash -ne $hashContract.Expected) {
      throw "App-private generation $($hashContract.Label) hash mismatch: generation=$generation"
    }
  }
  return [PSCustomObject]@{
    Generation = $generation
    InstalledVersionCode = $installedVersionCode
    InstalledApkFingerprint = $installedApkFingerprint
    SoRelative = $soRelative
    AgentRelative = $agentRelative
    StatusRelative = "$generationRelative/load-status"
  }
}

function Resolve-AppDataDirectory {
  $result = Invoke-AdbRunAs -Arguments @("pwd")
  $path = $result.Text.Trim().TrimEnd("/")
  if (-not $path.StartsWith("/", [StringComparison]::Ordinal) -or
      -not $path.EndsWith("/$script:Package", [StringComparison]::Ordinal)) {
    throw "Unexpected app data directory for $script:Package: $path"
  }
  return $path
}

function Resolve-InstalledLibrary {
  param([Parameter(Mandatory = $true)][string]$PackageDump)

  $nativeDirMatch = [regex]::Match(
    $PackageDump,
    "(?m)^\s*(?:legacyNativeLibraryDir|nativeLibraryDir)=(\S+)\s*$"
  )
  if (-not $nativeDirMatch.Success) {
    throw "nativeLibraryDir not found for package: $script:Package"
  }
  $nativeDir = $nativeDirMatch.Groups[1].Value
  foreach ($candidate in @(
    "$nativeDir/arm64/libUE4.so",
    "$nativeDir/libUE4.so"
  )) {
    $exists = Invoke-Adb -Arguments @("shell", "test", "-f", $candidate) -AllowFailure
    if ($exists.Code -eq 0) { return $candidate }
  }
  throw "Installed libUE4.so not found under: $nativeDir"
}

function Test-MapsExactPath {
  param(
    [Parameter(Mandatory = $true)][string]$Maps,
    [Parameter(Mandatory = $true)][string]$Path
  )

  foreach ($line in @($Maps -split "\r?\n")) {
    if ($line -notmatch "^\S+\s+\S+\s+\S+\s+\S+\s+\S+\s+(.+?)\s*$") {
      continue
    }
    $mappedPath = $matches[1]
    if ($mappedPath.EndsWith(" (deleted)", [StringComparison]::Ordinal)) {
      $mappedPath = $mappedPath.Substring(0, $mappedPath.Length - 10)
    }
    if ($mappedPath.Equals($Path, [StringComparison]::Ordinal)) {
      return $true
    }
    # Android may canonicalize /data/user/0/<pkg> to its /data/data/<pkg>
    # symlink when the dynamic linker records the mapping in /proc/<pid>/maps.
    $dataUserPrefix = "/data/user/0/$script:Package/"
    $dataDataPrefix = "/data/data/$script:Package/"
    if ($Path.StartsWith($dataUserPrefix, [StringComparison]::Ordinal) -and
        $mappedPath.Equals($dataDataPrefix + $Path.Substring($dataUserPrefix.Length), [StringComparison]::Ordinal)) {
      return $true
    }
  }
  return $false
}

function Assert-PrivateMapping {
  $pidResult = Invoke-Adb -Arguments @("shell", "pidof", $script:Package) -AllowFailure
  $pids = @(
    $pidResult.Text.Trim() -split "\s+" |
      Where-Object { $_ -match "^\d+$" }
  )
  if ($pids.Count -eq 0) {
    throw "Package process disappeared after startup-agent load: $script:Package"
  }

  $readableMaps = 0
  $privateMapped = $false
  foreach ($processId in $pids) {
    $maps = Invoke-AdbRunAs -Arguments @("cat", "/proc/$processId/maps") -AllowFailure
    if ($maps.Code -ne 0) { continue }
    $readableMaps++
    if (Test-MapsExactPath -Maps $maps.Text -Path $script:InstalledSo) {
      throw "Installed APK libUE4.so was mapped despite app-private redirection: pid=$processId path=$script:InstalledSo"
    }
    if (Test-MapsExactPath -Maps $maps.Text -Path $script:SoAbsolute) {
      $privateMapped = $true
    }
  }
  if ($readableMaps -eq 0) {
    throw "Unable to read process maps as the debuggable app uid: $script:Package"
  }
  if (-not $privateMapped) {
    throw "Startup agent reported success but no process maps the app-private SO: $script:SoAbsolute"
  }
}

function Wait-AgentMapped {
  $timer = [Diagnostics.Stopwatch]::StartNew()
  $lastStatus = ""
  while ($timer.Elapsed.TotalSeconds -lt $LoadTimeoutSeconds) {
    $status = Invoke-AdbRunAs -Arguments @("cat", $script:StatusRelative) -AllowFailure
    if ($status.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($status.Text)) {
      $lastStatus = $status.Text.Trim()
      if ($lastStatus -match "(?m)^state=mapped\s*$" -and
          $lastStatus -match "(?m)^detail=([^\r\n]+)\s*$") {
        $resolved = $matches[1]
        if ($resolved -ne $script:SoAbsolute) {
          throw "Startup agent mapped unexpected SO: expected=$script:SoAbsolute actual=$resolved"
        }
        return $lastStatus
      }
      if ($lastStatus -match "(?m)^state=error\s*$") {
        throw "Startup agent failed:`n$lastStatus"
      }
    }
    Start-Sleep -Milliseconds 250
  }
  throw "Timed out waiting for startup agent to map $script:SoAbsolute. Last status:`n$lastStatus"
}

function Stop-FailedLaunch {
  Invoke-Adb -Arguments @(
    "shell", "am", "force-stop", $script:Package
  ) -AllowFailure | Out-Null
  $timer = [Diagnostics.Stopwatch]::StartNew()
  do {
    $running = Invoke-Adb -Arguments @(
      "shell", "pidof", $script:Package
    ) -AllowFailure
    if ($running.Code -ne 0 -or [string]::IsNullOrWhiteSpace($running.Text)) {
      return
    }
    Start-Sleep -Milliseconds 100
  } while ($timer.Elapsed.TotalSeconds -lt 10)
  throw "Failed SO launch could not be stopped within 10 seconds: $script:Package"
}

$script:Adb = $Adb
$script:Serial = $Serial
$script:Package = $Package
$script:PrivateRootRelative = "code_cache/nvim-ue-so"
$script:CurrentRelative = "$script:PrivateRootRelative/current"

$deviceState = Invoke-Adb -Arguments @("get-state")
if ($deviceState.Text.Trim() -ne "device") {
  throw "Android device is not ready: $Serial ($($deviceState.Text.Trim()))"
}

$operationMutex = Enter-OperationMutex
try {
  $deployment = Resolve-PrivateDeployment
  if ($null -eq $deployment) {
    $fallback = Invoke-Adb -Arguments @(
      "shell", "monkey", "-p", $Package,
      "-c", "android.intent.category.LAUNCHER", "1"
    )
    if ($fallback.Text) { Write-Host $fallback.Text }
    Write-Host "[UE launch] normal APK launch; no app-private SO deploy is staged"
    return
  }

  $script:SoRelative = $deployment.SoRelative
  $script:AgentRelative = $deployment.AgentRelative
  $script:StatusRelative = $deployment.StatusRelative
  $packageDump = Invoke-Adb -Arguments @("shell", "dumpsys", "package", $Package)
  if ($packageDump.Text -notmatch "flags=\[[^\]]*\bDEBUGGABLE\b") {
    throw "App-private SO is staged but the installed APK is not debuggable: $Package"
  }
  $primaryAbiMatch = [regex]::Match(
    $packageDump.Text,
    "(?m)^\s*primaryCpuAbi=(\S+)\s*$"
  )
  if (-not $primaryAbiMatch.Success -or
      $primaryAbiMatch.Groups[1].Value -ne "arm64-v8a") {
    throw "App-private startup-agent launch requires the installed app primaryCpuAbi=arm64-v8a."
  }
  $installedVersionMatch = [regex]::Match(
    $packageDump.Text,
    "(?m)^\s*versionCode=(\d+)\b"
  )
  if (-not $installedVersionMatch.Success -or
      $installedVersionMatch.Groups[1].Value -ne $deployment.InstalledVersionCode) {
    throw "Installed APK changed after app-private SO staging. Run <Space>uq again before launching."
  }
  $installedApkFingerprint = Get-InstalledApkFingerprint -PackageDump $packageDump.Text
  if ($installedApkFingerprint -ne $deployment.InstalledApkFingerprint) {
    throw "Installed APK filesystem identity changed after app-private SO staging. Run <Space>uq again before launching."
  }
  $abiList = (Invoke-Adb -Arguments @(
    "shell", "getprop", "ro.product.cpu.abilist"
  )).Text.Trim()
  if (@($abiList -split ",") -notcontains "arm64-v8a") {
    throw "App-private startup-agent launch requires arm64-v8a; device reports ABI list '$abiList'."
  }

  $script:InstalledSo = Resolve-InstalledLibrary -PackageDump $packageDump.Text
  $appDataDirectory = Resolve-AppDataDirectory
  $script:SoAbsolute = "$appDataDirectory/$script:SoRelative"
  $script:AgentAbsolute = "$appDataDirectory/$script:AgentRelative"
  $script:StatusAbsolute = "$appDataDirectory/$script:StatusRelative"
  $capability = Invoke-Adb -Arguments @("shell", "am", "help") -AllowFailure
  if ($capability.Text -notmatch "--attach-agent-bind") {
    throw "Device ActivityManager does not support --attach-agent-bind"
  }
  $running = Invoke-Adb -Arguments @("shell", "pidof", $Package) -AllowFailure
  if ($running.Code -eq 0 -and -not [string]::IsNullOrWhiteSpace($running.Text)) {
    throw "App-private SO injection requires a fresh process, but $Package is already running (pid=$($running.Text.Trim())). Run <Space>uq first; it stages the SO and leaves the package stopped."
  }

  Invoke-AdbRunAs -Arguments @("rm", "-f", $script:StatusRelative) | Out-Null
  $component = Resolve-LauncherComponent
  $agentSpec = "$script:AgentAbsolute=target=$script:SoAbsolute,original=$script:InstalledSo,status=$script:StatusAbsolute"
  $startAttempted = $false
  try {
    $startAttempted = $true
    $start = Invoke-Adb -Arguments @(
      "shell", "am", "start", "--attach-agent-bind", $agentSpec,
      "-n", $component
    )
    if ($start.Text) { Write-Host $start.Text }
    $status = Wait-AgentMapped
    Assert-PrivateMapping
    Start-Sleep -Milliseconds 1000
    Assert-PrivateMapping
  }
  catch {
    $failure = $_
    if ($startAttempted) {
      try { Stop-FailedLaunch }
      catch {
        throw "$($failure.Exception.Message)`nFailed launch cleanup also failed: $($_.Exception.Message)"
      }
    }
    throw $failure
  }
  Write-Host "[UE launch] app-private libUE4.so mapped through the app ClassLoader; APK/signing identity unchanged"
  Write-Host $status
}
finally {
  Exit-OperationMutex -Mutex $operationMutex
}
