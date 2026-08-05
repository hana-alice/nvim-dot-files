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

  [string]$NdkRoot = $env:NDKROOT
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

function Get-RemoteLibraryMetadata {
  param([Parameter(Mandatory = $true)][string]$Path)

  $uid = (Invoke-Adb -Arguments @("shell", "su", "0", "stat", "-c", "%u", $Path)).Text.Trim()
  $gid = (Invoke-Adb -Arguments @("shell", "su", "0", "stat", "-c", "%g", $Path)).Text.Trim()
  $mode = (Invoke-Adb -Arguments @("shell", "su", "0", "stat", "-c", "%a", $Path)).Text.Trim()
  $context = (Invoke-Adb -Arguments @("shell", "su", "0", "stat", "-c", "%C", $Path)).Text.Trim()

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

  Invoke-Adb -Arguments @("shell", "su", "0", "chown", "$($Metadata.Uid):$($Metadata.Gid)", $Path) | Out-Null
  Invoke-Adb -Arguments @("shell", "su", "0", "chmod", $Metadata.Mode, $Path) | Out-Null
  Invoke-Adb -Arguments @("shell", "su", "0", "chcon", $Metadata.Context, $Path) | Out-Null
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
    throw "Android SO baseline identity not found: $packageInfoPath. Build and install one matching APK before SO-only deploys."
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

$rootId = Invoke-Adb -Arguments @("shell", "su", "0", "id")
if ($rootId.Text -notmatch "uid=0\(root\)") {
  throw "Device root check failed: $($rootId.Text)"
}

$packageDump = Invoke-Adb -Arguments @("shell", "dumpsys", "package", $Package)
$sourceIdentity = Get-SourcePackageIdentity
$installedVersionMatch = [regex]::Match(
  $packageDump.Text,
  "(?m)^\s*versionCode=(\d+)\b"
)
if (-not $installedVersionMatch.Success) {
  throw "Installed APK versionCode not found for package: $Package"
}
$installedVersionCode = $installedVersionMatch.Groups[1].Value
if ($installedVersionCode -ne $sourceIdentity.VersionCode) {
  throw "Installed APK baseline mismatch: device versionCode=$installedVersionCode, build output versionCode=$($sourceIdentity.VersionCode). Install the matching APK once (:UEInstallAndroid / <Space>ui), then use SO-only deploys until Java/manifest/Gradle inputs change."
}
Write-Host "[UE SO deploy] APK baseline verified package=$Package versionCode=$installedVersionCode"

$nativeDirMatch = [regex]::Match(
  $packageDump.Text,
  "(?m)^\s*(?:legacyNativeLibraryDir|nativeLibraryDir)=(\S+)\s*$"
)
if (-not $nativeDirMatch.Success) {
  throw "nativeLibraryDir not found for package: $Package"
}

$nativeDir = $nativeDirMatch.Groups[1].Value
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
finally {
  $sha256.Dispose()
}

$arm64Target = "$nativeDir/arm64/libUE4.so"
$flatTarget = "$nativeDir/libUE4.so"
if ((Invoke-Adb -Arguments @("shell", "su", "0", "test", "-f", $arm64Target) -AllowFailure).Code -eq 0) {
  $targetSo = $arm64Target
}
elseif ((Invoke-Adb -Arguments @("shell", "su", "0", "test", "-f", $flatTarget) -AllowFailure).Code -eq 0) {
  $targetSo = $flatTarget
}
else {
  throw "Installed libUE4.so not found under: $nativeDir"
}
$originalMetadata = Get-RemoteLibraryMetadata -Path $targetSo
Write-Host "[UE SO deploy] preserving metadata uid=$($originalMetadata.Uid) gid=$($originalMetadata.Gid) mode=$($originalMetadata.Mode) context=$($originalMetadata.Context)"

$llvmStrip = Resolve-LlvmStrip
$hostTempSo = Join-Path ([IO.Path]::GetTempPath()) (
  "nvim-ue-deploy-{0}-{1}.so" -f $PID, [Guid]::NewGuid().ToString("N")
)
$deviceStage = "/data/local/tmp/nvim-ue-$Package-libUE4.so"
$backupDir = "/data/local/tmp/nvim-ue-so-backup/$Package/$backupKey"
$backupSo = "$backupDir/libUE4.so.original"
$targetNew = "$targetSo.nvim-new"
$replaced = $false

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
  Invoke-Adb -Arguments @("shell", "su", "0", "mkdir", "-p", $backupDir) | Out-Null
  if ((Invoke-Adb -Arguments @("shell", "su", "0", "test", "-f", $backupSo) -AllowFailure).Code -ne 0) {
    Write-Host "[UE SO deploy] preserving installed original: $backupSo"
    Invoke-Adb -Arguments @("shell", "su", "0", "cp", "-p", $targetSo, $backupSo) | Out-Null
  }

  Write-Host "[UE SO deploy] pushing to $Serial"
  $push = Invoke-Adb -Arguments @("push", $hostTempSo, $deviceStage)
  if ($push.Text) { Write-Host $push.Text }

  Invoke-Adb -Arguments @("shell", "su", "0", "cp", $deviceStage, $targetNew) | Out-Null
  Set-RemoteLibraryMetadata -Path $targetNew -Metadata $originalMetadata
  Invoke-Adb -Arguments @("shell", "su", "0", "mv", "-f", $targetNew, $targetSo) | Out-Null
  $replaced = $true
  Assert-RemoteLibraryMetadata -Path $targetSo -Expected $originalMetadata

  $remoteHashOutput = Invoke-Adb -Arguments @("shell", "su", "0", "sha256sum", $targetSo)
  $remoteHash = ($remoteHashOutput.Text -split "\s+")[0].ToLowerInvariant()
  if ($remoteHash -ne $localHash) {
    throw "Remote SO hash mismatch: local=$localHash remote=$remoteHash"
  }

  Write-Host "[UE SO deploy] replacement verified; package remains stopped"
  Write-Host "[UE SO deploy] launch explicitly with <Space>ul; original backup: $backupSo"
}
catch {
  $failure = $_
  if ($replaced) {
    Write-Warning "SO deploy failed after replacement; restoring the installed original"
    try {
      Invoke-Adb -Arguments @("shell", "am", "force-stop", $Package) | Out-Null
      Wait-PackageStopped
      Invoke-Adb -Arguments @("shell", "su", "0", "cp", $backupSo, $targetNew) | Out-Null
      Set-RemoteLibraryMetadata -Path $targetNew -Metadata $originalMetadata
      Invoke-Adb -Arguments @("shell", "su", "0", "mv", "-f", $targetNew, $targetSo) | Out-Null
      Assert-RemoteLibraryMetadata -Path $targetSo -Expected $originalMetadata
      Write-Warning "Installed original restored from: $backupSo"
    }
    catch {
      Write-Warning "Automatic rollback also failed: $_"
    }
  }
  throw $failure
}
finally {
  Remove-Item -LiteralPath $hostTempSo -Force -ErrorAction SilentlyContinue
  Invoke-Adb -Arguments @("shell", "su", "0", "rm", "-f", $deviceStage, $targetNew) -AllowFailure | Out-Null
}
