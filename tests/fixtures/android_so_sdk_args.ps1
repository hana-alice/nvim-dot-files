# Runner argument contract only: the fixture records argv and creates an empty
# action file. It does not establish UE/Android host capability or compile code.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$runner = Join-Path $PSScriptRoot "../../scripts/ue_android_so_build.ps1"
$fixtureRoot = Join-Path $PSScriptRoot (".android-so-sdk-{0}" -f [Guid]::NewGuid().ToString("N"))
$buildDir = Join-Path $fixtureRoot "Engine/Build/BatchFiles"
$callsPath = Join-Path $buildDir "calls.jsonl"

try {
  New-Item -ItemType Directory -Path $buildDir -Force | Out-Null
  $project = Join-Path $fixtureRoot "Project With Spaces.uproject"
  Set-Content -LiteralPath $project -Value "{}"
  Set-Content -LiteralPath (Join-Path $buildDir "record.ps1") -Value @'
$ErrorActionPreference = "Stop"
# Preserve the batch command line via an environment variable: forwarding it
# through PowerShell -File would reinterpret the colon in -Project=C:/... .
$arguments = @([regex]::Matches($env:NVIM_UE_FIXTURE_ARGV, '(?:"[^"]*"|\S)+') | ForEach-Object { $_.Value.Trim('"') })
ConvertTo-Json -InputObject $arguments -Compress | Add-Content -LiteralPath (Join-Path $PSScriptRoot "calls.jsonl")
foreach ($argument in $arguments) {
  if ($argument.StartsWith("-WriteOutdatedActions=")) {
    [IO.File]::WriteAllText($argument.Substring("-WriteOutdatedActions=".Length), "{}")
  }
}
'@
  $powershellExe = Join-Path $PSHOME "pwsh.exe"
  Set-Content -LiteralPath (Join-Path $buildDir "Build.bat") -Value @(
    '@echo off'
    'setlocal'
    'set "NVIM_UE_FIXTURE_ARGV=%*"'
    ('@"{0}" -NoProfile -File "%~dp0record.ps1"' -f $powershellExe)
  )

  foreach ($skipSdk in @($false, $true)) {
    if (Test-Path -LiteralPath $callsPath) { Remove-Item -LiteralPath $callsPath }
    $runnerArgs = @(
      "-NoProfile", "-File", $runner,
      "-EngineRoot", $fixtureRoot,
      "-Project", $project,
      "-Target", "Client",
      "-Platform", "Android",
      "-Configuration", "Development",
      "-WaitMutex", "-FromMsBuild"
    )
    if ($skipSdk) { $runnerArgs += @("-SdkArgument", "-skip-project-sdk") }
    & $powershellExe @runnerArgs
    if ($LASTEXITCODE -ne 0) { throw "Runner failed with exit code $LASTEXITCODE" }
    $calls = @(Get-Content -LiteralPath $callsPath | ForEach-Object { ,(ConvertFrom-Json $_) })
    if ($calls.Count -ne 2) { throw "Expected export and execute calls, got $($calls.Count)" }
    if (($calls[0] -contains "-skip-project-sdk") -ne $skipSdk) { throw "Export SDK switch mismatch: $skipSdk" }
    if ($calls[1] -contains "-skip-project-sdk") { throw "Execute must not receive target rule SDK switch" }
    if ($calls[0] -notcontains "-Project=$project") { throw "Project argument lost its space-containing path" }
    if ($calls[0] -notcontains "-FromMsBuild") { throw "Export lost FromMsBuild" }
    if ($calls[0] -notcontains "-WaitMutex" -or $calls[1] -notcontains "-WaitMutex") { throw "WaitMutex forwarding changed" }
    if ($calls[1] -notcontains "-Mode=Execute") { throw "Second call must execute actions" }
    $actionArgument = @($calls[0] | Where-Object { $_.StartsWith("-WriteOutdatedActions=") })
    if ($actionArgument.Count -ne 1) { throw "Expected one exported actions path" }
    $actionsPath = $actionArgument[0].Substring("-WriteOutdatedActions=".Length)
    if ($calls[1] -notcontains "-Actions=$actionsPath") { throw "Execute did not receive exported actions path" }
    if (Test-Path -LiteralPath $actionsPath) { throw "Runner did not clean up actions file" }
    Write-Host "PASS SDK argument enabled=${skipSdk}: export/execute argv and action cleanup"
  }
  Remove-Item -LiteralPath $callsPath
  foreach ($invalidArgument in @("skip-project-sdk", "-skip sdk", "-skip;noop", "-skip&noop", '-skip"quoted"', '-skip%PATH%', "-skip`n")) {
    $rejected = $false
    try {
      & $runner -EngineRoot $fixtureRoot -Project $project -Target Client -Platform Android -Configuration Development -SdkArgument $invalidArgument
    }
    catch {
      if ($_.FullyQualifiedErrorId -notlike "ParameterArgumentValidationError*") { throw }
      $rejected = $true
    }
    if (-not $rejected) { throw "Unsafe SDK argument accepted" }
    if (Test-Path -LiteralPath $callsPath) { throw "Rejected SDK argument reached Build.bat" }
  }
  Write-Host "PASS unsafe SDK arguments rejected before Build.bat"
}
finally {
  if (Test-Path -LiteralPath $fixtureRoot) {
    $resolvedFixture = (Resolve-Path -LiteralPath $fixtureRoot).Path
    $resolvedParent = (Resolve-Path -LiteralPath $PSScriptRoot).Path
    if ([IO.Path]::GetDirectoryName($resolvedFixture) -ne $resolvedParent) { throw "Unsafe fixture cleanup path: $resolvedFixture" }
    Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
  }
}
