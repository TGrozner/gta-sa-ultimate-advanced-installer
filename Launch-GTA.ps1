[CmdletBinding()]
param([Parameter(Mandatory)][string]$GamePath)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$game = Resolve-GamePath $GamePath
$installedLauncher = Join-Path $game 'Launch GTA SA 2026.ps1'
if (Test-Path -LiteralPath $installedLauncher -PathType Leaf) {
    & $installedLauncher
} else {
    & (Join-Path $PSScriptRoot 'scripts\Game-Launcher.ps1') -GameDirectory $game
}
