[CmdletBinding()]
param(
    [string]$Compiler = 'i686-w64-mingw32-g++.exe',
    [string]$OutputPath = (Join-Path $PSScriptRoot '..\..\packages\gtav-essentials\overlay\modloader\Gameplay - GTA V Essentials\GTAVEssentials.asi')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$compilerCommand = Get-Command $Compiler -ErrorAction Stop
$output = [System.IO.Path]::GetFullPath($OutputPath)
New-Item -ItemType Directory -Path (Split-Path -Parent $output) -Force | Out-Null

& $compilerCommand.Source @(
    '-std=c++17',
    '-O2',
    '-Wall',
    '-Wextra',
    '-Werror',
    '-shared',
    '-static-libgcc',
    '-static-libstdc++',
    '-Wl,--kill-at',
    '-s',
    (Join-Path $PSScriptRoot 'GTAVEssentials.cpp'),
    '-o',
    $output
)
if ($LASTEXITCODE -ne 0) {
    throw "GTAVEssentials build failed with exit code $LASTEXITCODE."
}

Get-Item -LiteralPath $output | Select-Object FullName, Length, LastWriteTime
