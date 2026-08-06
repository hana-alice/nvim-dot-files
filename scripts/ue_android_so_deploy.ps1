[CmdletBinding()]
param(
  [string]$Adb = "adb",

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[^\s]+$")]
  [string]$Serial,

  [Parameter(Mandatory = $true)]
  [ValidatePattern("^[A-Za-z0-9._-]+$")]
  [string]$Package,

  [Parameter(Mandatory = $true)]
  [ValidateNotNullOrEmpty()]
  [string]$SourceSo,

  [string]$NdkRoot = $env:NDKROOT,

  [switch]$PreflightOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-ExternalCapture {
  param(
    [Parameter(Mandatory = $true)]
    [string]$FilePath,

    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [switch]$AllowFailure
  )

  $previousErrorActionPreference = $ErrorActionPreference
  $ErrorActionPreference = "Continue"
  try {
    $output = & $FilePath @Arguments 2>&1
    $exitCode = $LASTEXITCODE
  }
  finally {
    $ErrorActionPreference = $previousErrorActionPreference
  }
  $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
  if (-not $AllowFailure -and $exitCode -ne 0) {
    throw "Command failed ($exitCode): $FilePath $($Arguments -join ' ')`n$text"
  }
  return [PSCustomObject]@{ Code = $exitCode; Text = $text }
}

function Invoke-Adb {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [switch]$AllowFailure
  )

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

function Resolve-RootTransport {
  param([switch]$AllowUnavailable)

  $direct = Invoke-Adb -Arguments @("shell", "id", "-u") -AllowFailure
  if ($direct.Code -eq 0 -and $direct.Text.Trim() -eq "0") {
    return "adbd-root"
  }

  $su0 = Invoke-Adb -Arguments @("shell", "su", "0", "id", "-u") -AllowFailure
  if ($su0.Code -eq 0 -and $su0.Text.Trim() -eq "0") {
    return "su-0"
  }

  $buildType = (Invoke-Adb -Arguments @(
    "shell", "getprop", "ro.build.type"
  ) -AllowFailure).Text.Trim()
  $debuggable = (Invoke-Adb -Arguments @(
    "shell", "getprop", "ro.debuggable"
  ) -AllowFailure).Text.Trim()
  $shellUid = $direct.Text.Trim()
  if ([string]::IsNullOrWhiteSpace($shellUid)) { $shellUid = "unknown" }
  if ([string]::IsNullOrWhiteSpace($buildType)) { $buildType = "unknown" }
  if ([string]::IsNullOrWhiteSpace($debuggable)) { $debuggable = "unknown" }
  if ($AllowUnavailable) { return $null }
  throw "Device root unavailable before deployment: shell_uid=$shellUid build_type=$buildType ro.debuggable=$debuggable. SO replacement requires either root adbd or a verified 'su 0' command; no installed SO was modified. Select a rooted test device with :UESetAndroidDevice."
}

function Resolve-RunAsTransport {
  param([Parameter(Mandatory = $true)][string]$PackageDump)

  if ($PackageDump -notmatch "flags=\[[^\]]*\bDEBUGGABLE\b") {
    throw "Installed package is not debuggable and the device has no root transport: $script:Package. Non-root SO injection requires the existing APK itself to be debuggable; no APK was modified or reinstalled."
  }

  $appIdMatch = [regex]::Match($PackageDump, "(?m)^\s*appId=(\d+)\s*$")
  if (-not $appIdMatch.Success) {
    throw "Installed appId not found for debuggable package: $script:Package"
  }
  $runAs = Invoke-Adb -Arguments @(
    "shell", "run-as", $script:Package, "id", "-u"
  ) -AllowFailure
  $appUid = $runAs.Text.Trim()
  if ($runAs.Code -ne 0 -or $appUid -ne $appIdMatch.Groups[1].Value) {
    throw "run-as unavailable for existing debuggable package $script:Package: expected_uid=$($appIdMatch.Groups[1].Value) actual_uid=$appUid. No APK or installed SO was modified."
  }
  $primaryAbiMatch = [regex]::Match(
    $PackageDump,
    "(?m)^\s*primaryCpuAbi=(\S+)\s*$"
  )
  if (-not $primaryAbiMatch.Success -or
      $primaryAbiMatch.Groups[1].Value -ne "arm64-v8a") {
    $actualAbi = if ($primaryAbiMatch.Success) {
      $primaryAbiMatch.Groups[1].Value
    } else { "unknown" }
    throw "App-private startup-agent transport requires the installed app primaryCpuAbi=arm64-v8a; package reports '$actualAbi'. No device state was changed."
  }

  $agentCapability = Invoke-Adb -Arguments @("shell", "am", "help") -AllowFailure
  if ($agentCapability.Text -notmatch "--attach-agent-bind") {
    throw "Device ActivityManager does not expose --attach-agent-bind. The existing APK and signing identity were left unchanged."
  }
  $apiLevel = (Invoke-Adb -Arguments @(
    "shell", "getprop", "ro.build.version.sdk"
  )).Text.Trim()
  if ($apiLevel -ne "34") {
    throw "App-private startup-agent transport is verified only for Android API 34; device reports API $apiLevel. No device state was changed."
  }
  $abiList = (Invoke-Adb -Arguments @(
    "shell", "getprop", "ro.product.cpu.abilist"
  )).Text.Trim()
  if (@($abiList -split ",") -notcontains "arm64-v8a") {
    throw "App-private startup-agent transport requires arm64-v8a; device reports ABI list '$abiList'. No device state was changed."
  }
  return [PSCustomObject]@{
    Kind = "run-as-agent"
    AppUid = $appUid
    ApiLevel = $apiLevel
  }
}

function Resolve-DeployTransport {
  param([Parameter(Mandatory = $true)][string]$PackageDump)

  $root = Resolve-RootTransport -AllowUnavailable
  if (-not [string]::IsNullOrWhiteSpace($root)) {
    return [PSCustomObject]@{ Kind = "root"; Root = $root }
  }
  return Resolve-RunAsTransport -PackageDump $PackageDump
}

function Invoke-AdbRoot {
  param(
    [Parameter(Mandatory = $true)]
    [string[]]$Arguments,

    [switch]$AllowFailure
  )

  if ($script:RootTransport -eq "adbd-root") {
    $rootArguments = @("shell") + $Arguments
  }
  elseif ($script:RootTransport -eq "su-0") {
    $rootArguments = @("shell", "su", "0") + $Arguments
  }
  else {
    throw "Root transport has not been resolved"
  }
  return Invoke-Adb -Arguments $rootArguments -AllowFailure:$AllowFailure
}

function Invoke-AdbRunAs {
  param(
    [Parameter(Mandatory = $true)][string[]]$Arguments,
    [switch]$AllowFailure
  )

  return Invoke-Adb -Arguments (
    @("shell", "run-as", $script:Package) + $Arguments
  ) -AllowFailure:$AllowFailure
}

function Resolve-LlvmStrip {
  $roots = @(
    $script:NdkRoot,
    $env:NDKROOT,
    $env:ANDROID_NDK_ROOT,
    $env:NDK_ROOT
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  foreach ($root in $roots) {
    $candidate = Join-Path $root "toolchains\llvm\prebuilt\windows-x86_64\bin\llvm-strip.exe"
    if (Test-Path -LiteralPath $candidate -PathType Leaf) {
      return $candidate
    }
  }
  throw "llvm-strip.exe not found under NDKROOT/ANDROID_NDK_ROOT/NDK_ROOT"
}

function Resolve-JvmtiHeader {
  $candidates = @()
  if (-not [string]::IsNullOrWhiteSpace($env:JAVA_HOME)) {
    $candidates += Join-Path $env:JAVA_HOME "include\jvmti.h"
  }
  $javaRoot = Join-Path $env:ProgramFiles "Java"
  if (Test-Path -LiteralPath $javaRoot -PathType Container) {
    $candidates += Get-ChildItem -LiteralPath $javaRoot -Directory | Sort-Object Name -Descending |
      ForEach-Object { Join-Path $_.FullName "include\jvmti.h" }
  }
  foreach ($candidate in @($candidates | Select-Object -Unique)) {
    if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
  }
  throw "jvmti.h not found under JAVA_HOME or Program Files\Java"
}

function Build-StartupAgent {
  param([Parameter(Mandatory = $true)][string]$LlvmStrip)

  $source = Join-Path $PSScriptRoot "ue_android_so_agent.c"
  if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
    throw "Android SO startup agent source not found: $source"
  }
  $toolchainBin = Split-Path -Parent $LlvmStrip
  $clang = Join-Path $toolchainBin "clang.exe"
  if (-not (Test-Path -LiteralPath $clang -PathType Leaf)) {
    throw "clang.exe not found next to llvm-strip.exe: $toolchainBin"
  }
  $jvmtiHeader = Resolve-JvmtiHeader
  $compileContract = @(
    "--target=aarch64-linux-android26",
    "-shared",
    "-fPIC",
    "-O2",
    "-std=c11",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-fvisibility=hidden",
    "-Wl,-soname,libnvim_ue_so_agent.so",
    "-pthread",
    "-ldl",
    "-llog"
  )
  $compilerVersion = Invoke-ExternalCapture -FilePath $clang -Arguments @("--version")
  $cacheMaterial = @(
    (Get-Sha256Hex -Path $source),
    (Get-Sha256Hex -Path $jvmtiHeader),
    $compilerVersion.Text,
    ($compileContract -join " ")
  ) -join "`n"
  $cacheHasher = [Security.Cryptography.SHA256]::Create()
  try {
    $cacheKey = ([BitConverter]::ToString(
      $cacheHasher.ComputeHash([Text.Encoding]::UTF8.GetBytes($cacheMaterial))
    ) -replace "-", "").Substring(0, 16).ToLowerInvariant()
  }
  finally { $cacheHasher.Dispose() }
  $outputDir = Join-Path $env:LOCALAPPDATA (
    "nvim-data\ue-android-so-agent\arm64-v8a\{0}" -f $cacheKey
  )
  $output = Join-Path $outputDir "libnvim_ue_so_agent.so"
  if (Test-Path -LiteralPath $output -PathType Leaf) { return $output }

  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
  Copy-Item -LiteralPath $jvmtiHeader -Destination (Join-Path $outputDir "jvmti.h") -Force
  $result = Invoke-ExternalCapture -FilePath $clang -Arguments @(
    "--target=aarch64-linux-android26",
    "-shared",
    "-fPIC",
    "-O2",
    "-std=c11",
    "-Wall",
    "-Wextra",
    "-Werror",
    "-fvisibility=hidden",
    "-Wl,-soname,libnvim_ue_so_agent.so",
    "-I", $outputDir,
    "-o", $output,
    $source,
    "-pthread",
    "-ldl",
    "-llog"
  )
  if ($result.Text) { Write-Host $result.Text }
  if (-not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw "Android SO startup agent build produced no output: $output"
  }
  return $output
}

function Assert-SourceSoName {
  param(
    [Parameter(Mandatory = $true)][string]$Source,
    [Parameter(Mandatory = $true)][string]$LlvmStrip
  )

  $readElf = Join-Path (Split-Path -Parent $LlvmStrip) "llvm-readelf.exe"
  if (-not (Test-Path -LiteralPath $readElf -PathType Leaf)) {
    throw "llvm-readelf.exe not found next to llvm-strip.exe"
  }
  $header = Invoke-ExternalCapture -FilePath $readElf -Arguments @("-h", $Source)
  if ($header.Text -notmatch "(?m)^\s*Class:\s+ELF64\s*$" -or
      $header.Text -notmatch "(?m)^\s*Machine:\s+AArch64\s*$") {
    throw "Source SO is not an ELF64 AArch64 library: $Source"
  }
  $dynamic = Invoke-ExternalCapture -FilePath $readElf -Arguments @("-d", $Source)
  if ($dynamic.Text -notmatch "(?m)\(SONAME\).*\[libUE4\.so\]") {
    throw "Source SO DT_SONAME is not libUE4.so; startup-agent path redirection requires the UE library identity: $Source"
  }
}

function Get-Sha256Hex {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  $stream = [IO.File]::OpenRead($Path)
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    return ([BitConverter]::ToString($sha256.ComputeHash($stream)) -replace "-", "").ToLowerInvariant()
  }
  finally {
    $sha256.Dispose()
    $stream.Dispose()
  }
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

function Get-RemoteLibraryMetadata {
  param([Parameter(Mandatory = $true)][string]$Path)

  $uid = (Invoke-AdbRoot -Arguments @("stat", "-c", "%u", $Path)).Text.Trim()
  $gid = (Invoke-AdbRoot -Arguments @("stat", "-c", "%g", $Path)).Text.Trim()
  $mode = (Invoke-AdbRoot -Arguments @("stat", "-c", "%a", $Path)).Text.Trim()
  $context = (Invoke-AdbRoot -Arguments @("stat", "-c", "%C", $Path)).Text.Trim()

  if ($uid -notmatch "^\d+$" -or $gid -notmatch "^\d+$") {
    throw "Invalid owner metadata for ${Path}: uid=$uid gid=$gid"
  }
  if ($mode -notmatch "^[0-7]{3,4}$") {
    throw "Invalid mode metadata for ${Path}: $mode"
  }
  if ([string]::IsNullOrWhiteSpace($context) -or $context -eq "?") {
    throw "Invalid SELinux context metadata for ${Path}: $context"
  }

  return [PSCustomObject]@{
    Uid = $uid
    Gid = $gid
    Mode = $mode
    Context = $context
  }
}

function Set-RemoteLibraryMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Metadata
  )

  Invoke-AdbRoot -Arguments @("chown", "$($Metadata.Uid):$($Metadata.Gid)", $Path) | Out-Null
  Invoke-AdbRoot -Arguments @("chmod", $Metadata.Mode, $Path) | Out-Null
  Invoke-AdbRoot -Arguments @("chcon", $Metadata.Context, $Path) | Out-Null
}

function Assert-RemoteLibraryMetadata {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Expected
  )

  $actual = Get-RemoteLibraryMetadata -Path $Path
  if ($actual.Uid -ne $Expected.Uid -or
      $actual.Gid -ne $Expected.Gid -or
      $actual.Mode -ne $Expected.Mode -or
      $actual.Context -ne $Expected.Context) {
    throw "Remote SO metadata mismatch: expected uid=$($Expected.Uid) gid=$($Expected.Gid) mode=$($Expected.Mode) context=$($Expected.Context); actual uid=$($actual.Uid) gid=$($actual.Gid) mode=$($actual.Mode) context=$($actual.Context)"
  }
}

function Get-PackageProcessIds {
  $result = Invoke-Adb -Arguments @("shell", "pidof", $script:Package) -AllowFailure
  if ($result.Code -ne 0 -or [string]::IsNullOrWhiteSpace($result.Text)) {
    return @()
  }
  return @(
    $result.Text.Trim() -split "\s+" |
      Where-Object { $_ -match "^\d+$" }
  )
}

function Wait-PackageStopped {
  param(
    [int]$TimeoutSeconds = 10,
    [int]$PollMilliseconds = 250
  )

  $timer = [Diagnostics.Stopwatch]::StartNew()
  while ($timer.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
    if (@(Get-PackageProcessIds).Count -eq 0) {
      return
    }
    Start-Sleep -Milliseconds $PollMilliseconds
  }
  throw "Package processes did not stop within ${TimeoutSeconds}s"
}

function Get-SourcePackageIdentity {
  $packageInfoPath = Join-Path (Split-Path -Parent $script:SourceSo) "packageInfo.txt"
  if (-not (Test-Path -LiteralPath $packageInfoPath -PathType Leaf)) {
    throw "Android SO package identity not found: $packageInfoPath. Run the configured Android build once so the SO package name can be verified."
  }

  $lines = @(
    Get-Content -LiteralPath $packageInfoPath |
      ForEach-Object { $_.Trim() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
  )
  if ($lines.Count -lt 2 -or $lines[1] -notmatch "^\d+$") {
    throw "Invalid Android package identity file: $packageInfoPath"
  }
  if ($lines[0] -ne $script:Package) {
    throw "Android package mismatch: build output=$($lines[0]) selected=$($script:Package)"
  }

  return [PSCustomObject]@{
    Path = $packageInfoPath
    Package = $lines[0]
    VersionCode = $lines[1]
  }
}

if (-not (Test-Path -LiteralPath $SourceSo -PathType Leaf)) {
  throw "Source SO not found: $SourceSo"
}

$deviceState = Invoke-Adb -Arguments @("get-state")
if ($deviceState.Text.Trim() -ne "device") {
  throw "Android device is not ready: $Serial ($($deviceState.Text.Trim()))"
}

$packageDump = Invoke-Adb -Arguments @("shell", "dumpsys", "package", $Package)
$sourceIdentity = Get-SourcePackageIdentity
$transport = Resolve-DeployTransport -PackageDump $packageDump.Text
$installedVersionMatch = [regex]::Match(
  $packageDump.Text,
  "(?m)^\s*versionCode=(\d+)\b"
)
if (-not $installedVersionMatch.Success) {
  throw "Installed APK versionCode not found for package: $Package"
}
$installedVersionCode = $installedVersionMatch.Groups[1].Value
if ($installedVersionCode -ne $sourceIdentity.VersionCode) {
  if ($transport.Kind -eq "root") {
    throw "Installed APK baseline mismatch: device versionCode=$installedVersionCode, build output versionCode=$($sourceIdentity.VersionCode). Root replacement modifies the installed native library and therefore requires an exact APK baseline."
  }
  Write-Warning "APK versionCode differs (device=$installedVersionCode build=$($sourceIdentity.VersionCode)); continuing with debuggable app-private injection. The installed APK/signature remain unchanged; tool files are limited to app-private code_cache/nvim-ue-so."
}
else {
  Write-Host "[UE SO deploy] APK baseline verified package=$Package versionCode=$installedVersionCode"
}
$installedApkFingerprint = if ($transport.Kind -eq "run-as-agent") {
  Get-InstalledApkFingerprint -PackageDump $packageDump.Text
} else { $null }

$nativeDirMatch = [regex]::Match(
  $packageDump.Text,
  "(?m)^\s*(?:legacyNativeLibraryDir|nativeLibraryDir)=(\S+)\s*$"
)
if (-not $nativeDirMatch.Success) {
  throw "nativeLibraryDir not found for package: $Package"
}

$nativeDir = $nativeDirMatch.Groups[1].Value
$script:RootTransport = $null
$targetSo = $null
$originalMetadata = $null
$backupDir = $null
$backupSo = $null
$targetNew = $null

if ($transport.Kind -eq "root") {
  $script:RootTransport = $transport.Root
  Write-Host "[UE SO deploy] transport=root/$script:RootTransport"

  $packagePath = (Invoke-Adb -Arguments @("shell", "pm", "path", $Package)).Text.Trim()
  if ($packagePath -notmatch "^package:") {
    throw "Installed APK path not found for package: $Package"
  }
  $sha256 = [Security.Cryptography.SHA256]::Create()
  try {
    $backupKey = ([BitConverter]::ToString(
      $sha256.ComputeHash([Text.Encoding]::UTF8.GetBytes($packagePath))
    ) -replace "-", "").Substring(0, 16).ToLowerInvariant()
  }
  finally { $sha256.Dispose() }

  $arm64Target = "$nativeDir/arm64/libUE4.so"
  $flatTarget = "$nativeDir/libUE4.so"
  if ((Invoke-AdbRoot -Arguments @("test", "-f", $arm64Target) -AllowFailure).Code -eq 0) {
    $targetSo = $arm64Target
  }
  elseif ((Invoke-AdbRoot -Arguments @("test", "-f", $flatTarget) -AllowFailure).Code -eq 0) {
    $targetSo = $flatTarget
  }
  else { throw "Installed libUE4.so not found under: $nativeDir" }

  $originalMetadata = Get-RemoteLibraryMetadata -Path $targetSo
  $backupDir = "/data/local/tmp/nvim-ue-so-backup/$Package/$backupKey"
  $backupSo = "$backupDir/libUE4.so.original"
  $targetNew = "$targetSo.nvim-new"
  Write-Host "[UE SO deploy] preserving metadata uid=$($originalMetadata.Uid) gid=$($originalMetadata.Gid) mode=$($originalMetadata.Mode) context=$($originalMetadata.Context)"
}
elseif ($transport.Kind -eq "run-as-agent") {
  Write-Host "[UE SO deploy] transport=run-as/startup-agent uid=$($transport.AppUid)"
  $installedCandidates = @(
    "$nativeDir/arm64/libUE4.so",
    "$nativeDir/libUE4.so"
  )
  $installedSo = $installedCandidates | Where-Object {
    (Invoke-Adb -Arguments @("shell", "test", "-f", $_) -AllowFailure).Code -eq 0
  } | Select-Object -First 1
  if ([string]::IsNullOrWhiteSpace($installedSo)) {
    throw "Installed libUE4.so not found under: $nativeDir"
  }
}
else { throw "Unsupported SO deploy transport: $($transport.Kind)" }

$llvmStrip = Resolve-LlvmStrip
Assert-SourceSoName -Source $script:SourceSo -LlvmStrip $llvmStrip
$hostAgent = if ($transport.Kind -eq "run-as-agent") {
  Build-StartupAgent -LlvmStrip $llvmStrip
} else { $null }
if ($PreflightOnly) {
  Write-Host "[UE SO deploy] preflight-only passed; no device state was changed"
  if ($hostAgent) { Write-Host "[UE SO deploy] startup agent=$hostAgent" }
  return
}
$hostTempSo = Join-Path ([IO.Path]::GetTempPath()) (
  "nvim-ue-deploy-{0}-{1}.so" -f $PID, [Guid]::NewGuid().ToString("N")
)
$hostTempManifest = Join-Path ([IO.Path]::GetTempPath()) (
  "nvim-ue-deploy-{0}-{1}.manifest" -f $PID, [Guid]::NewGuid().ToString("N")
)
$deviceStage = "/data/local/tmp/nvim-ue-$Package-$PID-libUE4.so"
$deviceAgentStage = "/data/local/tmp/nvim-ue-$Package-$PID-agent.so"
$deviceManifestStage = "/data/local/tmp/nvim-ue-$Package-$PID-manifest"
$runAsDir = "code_cache/nvim-ue-so"
$generationName = "g-$([Guid]::NewGuid().ToString("N").ToLowerInvariant())"
$runAsGenerationNew = "$runAsDir/.$generationName.new"
$runAsGeneration = "$runAsDir/$generationName"
$runAsCurrent = "$runAsDir/current"
$runAsCurrentNew = "$runAsDir/current.$PID.new"
$runAsSoNew = "$runAsGenerationNew/libUE4.so"
$runAsAgentNew = "$runAsGenerationNew/libnvim_ue_so_agent.so"
$runAsManifestNew = "$runAsGenerationNew/manifest"
$previousGeneration = $null
$generationComplete = $false
$generationPublished = $false
$replaced = $false
$operationSucceeded = $false
$operationMutex = Enter-OperationMutex

try {
  Write-Host "[UE SO deploy] stripping: $SourceSo"
  $stripResult = Invoke-ExternalCapture -FilePath $llvmStrip -Arguments @(
    "--strip-unneeded", "-o", $hostTempSo, $SourceSo
  )
  if ($stripResult.Text) { Write-Host $stripResult.Text }

  $localHash = Get-Sha256Hex -Path $hostTempSo
  $localSize = (Get-Item -LiteralPath $hostTempSo).Length
  Write-Host "[UE SO deploy] stripped size=$localSize sha256=$localHash"

  Invoke-Adb -Arguments @("shell", "am", "force-stop", $Package) | Out-Null
  Wait-PackageStopped
  Write-Host "[UE SO deploy] pushing to $Serial"
  $push = Invoke-Adb -Arguments @("push", $hostTempSo, $deviceStage)
  if ($push.Text) { Write-Host $push.Text }
  if ($transport.Kind -eq "run-as-agent") {
    $agentPush = Invoke-Adb -Arguments @("push", $hostAgent, $deviceAgentStage)
    if ($agentPush.Text) { Write-Host $agentPush.Text }
  }

  if ($transport.Kind -eq "root") {
    Invoke-AdbRoot -Arguments @("mkdir", "-p", $backupDir) | Out-Null
    if ((Invoke-AdbRoot -Arguments @("test", "-f", $backupSo) -AllowFailure).Code -ne 0) {
      Write-Host "[UE SO deploy] preserving installed original: $backupSo"
      Invoke-AdbRoot -Arguments @("cp", "-p", $targetSo, $backupSo) | Out-Null
    }
    Invoke-AdbRoot -Arguments @("cp", $deviceStage, $targetNew) | Out-Null
    Set-RemoteLibraryMetadata -Path $targetNew -Metadata $originalMetadata
    Invoke-AdbRoot -Arguments @("mv", "-f", $targetNew, $targetSo) | Out-Null
    $replaced = $true
    Assert-RemoteLibraryMetadata -Path $targetSo -Expected $originalMetadata
    $remoteHashOutput = Invoke-AdbRoot -Arguments @("sha256sum", $targetSo)
    $remoteHash = ($remoteHashOutput.Text -split "\s+")[0].ToLowerInvariant()
    if ($remoteHash -ne $localHash) {
      throw "Remote SO hash mismatch: local=$localHash remote=$remoteHash"
    }
    Write-Host "[UE SO deploy] replacement verified; package remains stopped"
    Write-Host "[UE SO deploy] launch explicitly with <Space>ul; original backup: $backupSo"
  }
  elseif ($transport.Kind -eq "run-as-agent") {
    Invoke-AdbRunAs -Arguments @("mkdir", "-p", $runAsDir) | Out-Null
    $previousResult = Invoke-AdbRunAs -Arguments @("cat", $runAsCurrent) -AllowFailure
    if ($previousResult.Code -eq 0) {
      $previousGeneration = $previousResult.Text.Trim()
      if ($previousGeneration -notmatch "^g-[0-9a-f]{32}$") {
        throw "Existing app-private generation pointer is invalid: $previousGeneration"
      }
    }
    Invoke-AdbRunAs -Arguments @("mkdir", $runAsGenerationNew) | Out-Null

    $copyCommand = "cat $deviceStage | run-as $Package sh -c 'cat > $runAsSoNew'"
    Invoke-Adb -Arguments @("shell", $copyCommand) | Out-Null
    Invoke-AdbRunAs -Arguments @("chmod", "500", $runAsSoNew) | Out-Null
    $stagedHashOutput = Invoke-AdbRunAs -Arguments @("sha256sum", $runAsSoNew)
    $stagedHash = ($stagedHashOutput.Text -split "\s+")[0].ToLowerInvariant()
    if ($stagedHash -ne $localHash) {
      throw "App-private staged SO hash mismatch: local=$localHash remote=$stagedHash"
    }

    $agentHash = Get-Sha256Hex -Path $hostAgent
    $agentCopyCommand = "cat $deviceAgentStage | run-as $Package sh -c 'cat > $runAsAgentNew'"
    Invoke-Adb -Arguments @("shell", $agentCopyCommand) | Out-Null
    Invoke-AdbRunAs -Arguments @("chmod", "500", $runAsAgentNew) | Out-Null
    $stagedAgentHashOutput = Invoke-AdbRunAs -Arguments @("sha256sum", $runAsAgentNew)
    $stagedAgentHash = ($stagedAgentHashOutput.Text -split "\s+")[0].ToLowerInvariant()
    if ($stagedAgentHash -ne $agentHash) {
      throw "App-private startup agent hash mismatch: local=$agentHash remote=$stagedAgentHash"
    }

    $manifest = "generation=$generationName`ninstalled_version_code=$installedVersionCode`ninstalled_apk_fingerprint=$installedApkFingerprint`nso_sha256=$localHash`nagent_sha256=$agentHash`n"
    [IO.File]::WriteAllText(
      $hostTempManifest,
      $manifest,
      [Activator]::CreateInstance(
        [Text.UTF8Encoding],
        [object[]]@($false)
      )
    )
    $manifestPush = Invoke-Adb -Arguments @(
      "push", $hostTempManifest, $deviceManifestStage
    )
    if ($manifestPush.Text) { Write-Host $manifestPush.Text }
    $manifestCopyCommand = "cat $deviceManifestStage | run-as $Package sh -c 'cat > $runAsManifestNew'"
    Invoke-Adb -Arguments @("shell", $manifestCopyCommand) | Out-Null
    Invoke-AdbRunAs -Arguments @("chmod", "400", $runAsManifestNew) | Out-Null
    $remoteManifest = (Invoke-AdbRunAs -Arguments @(
      "cat", $runAsManifestNew
    )).Text
    if ($remoteManifest.Trim() -ne $manifest.Trim()) {
      throw "App-private generation manifest mismatch before publish"
    }

    Invoke-AdbRunAs -Arguments @(
      "mv", $runAsGenerationNew, $runAsGeneration
    ) | Out-Null
    $generationComplete = $true
    $pointerCommand = "printf '%s\n' $generationName | run-as $Package sh -c 'cat > $runAsCurrentNew'"
    Invoke-Adb -Arguments @("shell", $pointerCommand) | Out-Null
    Invoke-AdbRunAs -Arguments @(
      "mv", "-f", $runAsCurrentNew, $runAsCurrent
    ) | Out-Null
    $generationPublished = $true
    $replaced = $true

    Write-Host "[UE SO deploy] app-private replacement verified; package remains stopped"
    Write-Host "[UE SO deploy] installed APK/signature unchanged; tool files are limited to app-private code_cache/nvim-ue-so"
    Write-Host "[UE SO deploy] launch explicitly with <Space>ul; published generation=$generationName"
  }
  $operationSucceeded = $true
}
catch {
  $failure = $_
  if ($replaced) {
    Write-Warning "SO deploy failed after replacement; restoring the previous load target"
    try {
      Invoke-Adb -Arguments @("shell", "am", "force-stop", $Package) | Out-Null
      Wait-PackageStopped
      if ($transport.Kind -eq "root") {
        Invoke-AdbRoot -Arguments @("cp", $backupSo, $targetNew) | Out-Null
        Set-RemoteLibraryMetadata -Path $targetNew -Metadata $originalMetadata
        Invoke-AdbRoot -Arguments @("mv", "-f", $targetNew, $targetSo) | Out-Null
        Assert-RemoteLibraryMetadata -Path $targetSo -Expected $originalMetadata
        Write-Warning "Installed original restored from: $backupSo"
      }
      elseif ($generationPublished) {
        if (-not [string]::IsNullOrWhiteSpace($previousGeneration)) {
          $restoreCommand = "printf '%s\n' $previousGeneration | run-as $Package sh -c 'cat > $runAsCurrentNew'"
          Invoke-Adb -Arguments @("shell", $restoreCommand) | Out-Null
          Invoke-AdbRunAs -Arguments @(
            "mv", "-f", $runAsCurrentNew, $runAsCurrent
          ) | Out-Null
          Write-Warning "Previous app-private generation restored: $previousGeneration"
        }
        else {
          Invoke-AdbRunAs -Arguments @("rm", "-f", $runAsCurrent) | Out-Null
          Write-Warning "App-private generation pointer removed; the installed APK copy was never modified"
        }
        $generationPublished = $false
        Invoke-AdbRunAs -Arguments @(
          "rm", "-rf", $runAsGeneration
        ) | Out-Null
        $generationComplete = $false
      }
    }
    catch {
      Write-Warning "Automatic rollback also failed: $_"
    }
  }
  throw $failure
}
finally {
  Remove-Item -LiteralPath $hostTempSo -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $hostTempManifest -Force -ErrorAction SilentlyContinue
  Invoke-Adb -Arguments @(
    "shell", "rm", "-f", $deviceStage, $deviceAgentStage, $deviceManifestStage
  ) -AllowFailure | Out-Null
  if ($transport.Kind -eq "root") {
    Invoke-AdbRoot -Arguments @("rm", "-f", $targetNew) -AllowFailure | Out-Null
  }
  else {
    $currentPointsToGeneration = $false
    if ($generationComplete) {
      $currentProbe = Invoke-AdbRunAs -Arguments @(
        "cat", $runAsCurrent
      ) -AllowFailure
      $currentPointsToGeneration = (
        $currentProbe.Code -eq 0 -and
        $currentProbe.Text.Trim() -eq $generationName
      )
      if ($currentPointsToGeneration) {
        $generationPublished = $true
      }
    }
    Invoke-AdbRunAs -Arguments @(
      "rm", "-rf", $runAsGenerationNew
    ) -AllowFailure | Out-Null
    Invoke-AdbRunAs -Arguments @(
      "rm", "-f", $runAsCurrentNew
    ) -AllowFailure | Out-Null
    if ($generationComplete -and -not $generationPublished) {
      Invoke-AdbRunAs -Arguments @(
        "rm", "-rf", $runAsGeneration
      ) -AllowFailure | Out-Null
    }
    if ($operationSucceeded -and $generationPublished -and
        -not [string]::IsNullOrWhiteSpace($previousGeneration) -and
        $previousGeneration -ne $generationName) {
      $oldGeneration = "$runAsDir/$previousGeneration"
      $cleanupOld = Invoke-AdbRunAs -Arguments @(
        "rm", "-rf", $oldGeneration
      ) -AllowFailure
      if ($cleanupOld.Code -ne 0) {
        Write-Warning "Published the new generation but could not remove stale generation: $oldGeneration"
      }
    }
  }
  Exit-OperationMutex -Mutex $operationMutex
}
