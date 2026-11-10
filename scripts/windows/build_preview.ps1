#Requires -Version 5.1
<#
.SYNOPSIS
    Builds an unsigned Windows preview bundle, and optionally its installer.

.DESCRIPTION
    Runs the same `flutter build windows --release` you would run by hand,
    checks the output against lib/tooling/windows_bundle_contract.dart, then
    wraps it with installer/setup.iss into
    build/installer/FlyNarwhal_Setup_Windows_<arch>_<version>.exe.

    Unlike scripts/release/build_desktop.dart this script needs no release
    secrets and no private obfuscator checkout. The app then falls back to
    lib/core/config/dart_define_secret_bridge.dart, which is exactly what
    `flutter run` uses during development, so the preview behaves like a local
    dev run. Release builds still have to go through the release workflow.

.PARAMETER Architecture
    x64 (default) or arm64. Must match the host CPU: Flutter does not
    cross-compile Windows desktop builds.

.PARAMETER Version
    Overrides the version taken from pubspec.yaml. Injected as
    APP_FULL_VERSION so the settings page and the updater can display it.

.PARAMETER SkipInstaller
    Stop after building and verifying the bundle. Use this when Inno Setup is
    not installed, or when the raw bundle is all you need.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/windows/build_preview.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File scripts/windows/build_preview.ps1 -SkipInstaller
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',

    [string]$Version,

    [switch]$SkipInstaller
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# PowerShell 7.4 turns this on by default, which would turn a non-zero exit
# code into a terminating error before the checks below can explain it.
if (Get-Variable -Name PSNativeCommandUseErrorActionPreference -ErrorAction SilentlyContinue) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$bundleDir = Join-Path $repoRoot "build\windows\$Architecture\runner\Release"

function Write-Step([string]$Message) {
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Get-HostArchitecture {
    # `$IsWindows` only exists on PowerShell 6+, and StrictMode rejects the
    # undefined name on Windows PowerShell 5.1, so ask .NET instead.
    if ([System.Environment]::OSVersion.Platform -ne [System.PlatformID]::Win32NT) {
        throw 'This script targets Windows hosts; Flutter builds Windows apps ' +
            'only there.'
    }
    # PROCESSOR_ARCHITEW6432 reports the real machine when an x64 PowerShell
    # runs on an ARM64 host; PROCESSOR_ARCHITECTURE would say AMD64 there and
    # let an arm64 build run against an x64 toolchain.
    $raw = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITEW6432')
    if (-not $raw) {
        $raw = [Environment]::GetEnvironmentVariable('PROCESSOR_ARCHITECTURE')
    }
    switch ($raw) {
        'AMD64' { return 'x64' }
        'ARM64' { return 'arm64' }
        default {
            throw "Unsupported Windows host architecture '$raw'; expected AMD64 or ARM64."
        }
    }
}

function Find-Iscc {
    $command = Get-Command iscc.exe -ErrorAction SilentlyContinue
    if ($command) { return $command.Source }

    # choco installs machine-wide; the Inno Setup installer itself defaults to
    # a per-user directory under %LOCALAPPDATA%\Programs. Read the variables
    # through the API because `ProgramFiles(x86)` cannot be written as
    # `$env:ProgramFiles(x86)` and StrictMode rejects the missing names.
    $roots = @(
        [Environment]::GetEnvironmentVariable('LOCALAPPDATA'),
        (Join-Path ([Environment]::GetEnvironmentVariable('LOCALAPPDATA')) 'Programs'),
        [Environment]::GetEnvironmentVariable('ProgramFiles'),
        [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
    ) | Where-Object { $_ }

    foreach ($root in $roots) {
        $candidate = Join-Path $root 'Inno Setup 6\ISCC.exe'
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    return $null
}

Push-Location $repoRoot
try {
    $hostArchitecture = Get-HostArchitecture
    if ($hostArchitecture -ne $Architecture) {
        throw "Requested $Architecture but this host is $hostArchitecture. " +
            'Flutter does not cross-compile Windows desktop builds.'
    }

    foreach ($tool in @('flutter', 'dart')) {
        if (-not (Get-Command $tool -ErrorAction SilentlyContinue)) {
            throw "$tool is not on PATH. Install the Flutter stable SDK and " +
                'reopen the shell.'
        }
    }

    if (-not $Version) {
        $match = Select-String -Path (Join-Path $repoRoot 'pubspec.yaml') `
            -Pattern '^version:\s*([^+]+)' | Select-Object -First 1
        if (-not $match) { throw 'pubspec.yaml has no version: entry.' }
        $Version = $match.Matches[0].Groups[1].Value.Trim()
    }

    Write-Step "Building FlyNarwhal $Version for windows-$Architecture"

    flutter pub get
    if ($LASTEXITCODE -ne 0) { throw "flutter pub get failed ($LASTEXITCODE)." }

    flutter build windows --release "--dart-define=APP_FULL_VERSION=$Version"
    if ($LASTEXITCODE -ne 0) { throw "flutter build windows failed ($LASTEXITCODE)." }

    if (-not (Test-Path -LiteralPath $bundleDir)) {
        throw "Bundle directory is missing: $bundleDir"
    }

    Write-Step 'Verifying the Windows bundle contract'
    # Guards the two mistakes that produce an app that looks fine but cannot
    # update itself: a helper built for the wrong CPU, and a foreign process
    # left in the bundle root.
    dart run scripts/windows/verify_bundle_contract.dart $Architecture $bundleDir
    if ($LASTEXITCODE -ne 0) { throw "Bundle contract check failed ($LASTEXITCODE)." }

    Write-Host "Bundle: $bundleDir" -ForegroundColor Green

    if ($SkipInstaller) {
        Write-Host 'Skipped the installer because -SkipInstaller was passed.'
        return
    }

    $iscc = Find-Iscc
    if (-not $iscc) {
        Write-Warning 'Inno Setup 6 was not found, so no installer was produced.'
        Write-Host 'Install it with: winget install --id JRSoftware.InnoSetup -e'
        Write-Host 'or re-run with -SkipInstaller to skip packaging.'
        return
    }

    $installerArch = if ($Architecture -eq 'x64') { 'amd64' } else { 'aarch64' }

    Write-Step "Packaging the installer with $iscc"
    # Pass the bundle directory explicitly instead of relying on setup.iss's
    # default `..\build\...` relative path, so the same invocation works for
    # x64 and arm64 and matches what the release workflow does.
    & $iscc "/DMyAppArch=$installerArch" "/DMyAppVersion=$Version" `
        "/DFlutterBundleDir=$bundleDir" (Join-Path $repoRoot 'installer\setup.iss')
    if ($LASTEXITCODE -ne 0) { throw "Inno Setup failed ($LASTEXITCODE)." }

    $installer = Join-Path $repoRoot `
        "build\installer\FlyNarwhal_Setup_Windows_${installerArch}_$Version.exe"
    if (-not (Test-Path -LiteralPath $installer)) {
        throw "Inno Setup reported success but $installer is missing."
    }

    Write-Host "Installer: $installer" -ForegroundColor Green
    Write-Host ('This preview build is unsigned, so SmartScreen shows ' +
        '"Windows protected your PC" on first launch: choose ' +
        '"More info" then "Run anyway".')
}
finally {
    Pop-Location
}
