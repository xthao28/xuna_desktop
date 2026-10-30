<#
.SYNOPSIS
    Per-user Windows installer for XUNA Desktop Agent (UDC-3 §5.6.6).
.DESCRIPTION
    - Builds or copies the Release bundle to %LOCALAPPDATA%\Programs\XUNA
    - Registers start-at-login in HKCU\Software\Microsoft\Windows\CurrentVersion\Run
      (never runs elevated and is never installed as a Windows Service / Session 0)
    - Initializes %APPDATA%\XUNA\host-policy.json with owner-only ACL if missing
#>
param(
    [switch]$SkipBuild,
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\XUNA'
$ConfigDir = Join-Path $env:APPDATA 'XUNA'
$PolicyPath = Join-Path $ConfigDir 'host-policy.json'
$RunKeyPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$RunValueName = 'XunaDesktopAgent'

if ($Uninstall) {
    if (Get-ItemProperty -Path $RunKeyPath -Name $RunValueName -ErrorAction SilentlyContinue) {
        Remove-ItemProperty -Path $RunKeyPath -Name $RunValueName
    }
    if (Test-Path $InstallDir) {
        Remove-Item -Path $InstallDir -Recurse -Force
    }
    Write-Host "Removed XUNA Desktop Agent from $InstallDir and HKCU Run."
    exit 0
}

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
if (-not $SkipBuild) {
    Push-Location $RepoRoot
    try {
        fvm flutter build windows --release
    } finally {
        Pop-Location
    }
}

$BundleDir = Join-Path $RepoRoot 'build\windows\x64\runner\Release'
if (-not (Test-Path (Join-Path $BundleDir 'xuna_desktop.exe'))) {
    throw "Release binary not found at $BundleDir\xuna_desktop.exe"
}

New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
Copy-Item -Path (Join-Path $BundleDir '*') -Destination $InstallDir -Recurse -Force

New-Item -ItemType Directory -Force -Path $ConfigDir | Out-Null
if (-not (Test-Path $PolicyPath)) {
    $DefaultPolicy = @'
{
  "schemaVersion": 1,
  "families": {
    "media": "allow",
    "app": "allow",
    "url": "allow",
    "workflow": "allow"
  },
  "apps": [],
  "urlDomains": [
    "github.com"
  ],
  "workflows": [],
  "players": [
    "spotify",
    "music"
  ]
}
'@
    Set-Content -Path $PolicyPath -Value $DefaultPolicy -Encoding UTF8
}

# Restrict host-policy.json ACL to the current user only (UDC-3 §5.6.4).
$CurrentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
& icacls $PolicyPath /inheritance:r /grant:r "${CurrentUser}:(R,W)" | Out-Null

$ExePath = Join-Path $InstallDir 'xuna_desktop.exe'
Set-ItemProperty -Path $RunKeyPath -Name $RunValueName -Value "`"$ExePath`""

Write-Host "Installed XUNA Desktop Agent to $InstallDir and registered HKCU Run."

