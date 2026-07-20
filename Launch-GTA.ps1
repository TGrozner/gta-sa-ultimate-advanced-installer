[CmdletBinding()]
param([Parameter(Mandatory)][string]$GamePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$game = Resolve-GamePath $GamePath
$installedLauncher = Join-Path $game 'Launch GTA SA 2026.ps1'
if (Test-Path -LiteralPath $installedLauncher -PathType Leaf) {
    & $installedLauncher
    return
}

$watcher = Join-Path $PSScriptRoot 'scripts\gta-f8-kill-switch.ps1'
$arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$watcher`""
$powerShell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $powerShell) { $powerShell = Get-Command powershell.exe -ErrorAction Stop }
Start-Process -FilePath $powerShell.Source -ArgumentList $arguments -WindowStyle Hidden
Start-Sleep -Milliseconds 600
Start-Process -FilePath (Join-Path $game 'gta_sa.exe') -WorkingDirectory $game

