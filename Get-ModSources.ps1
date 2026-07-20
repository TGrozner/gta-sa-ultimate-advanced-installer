[CmdletBinding()]
param(
    [switch]$Prepare,
    [switch]$OpenManualPages,
    [string[]]$Id,
    [string]$PackageRoot = (Join-Path $PSScriptRoot 'packages')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$manifest = Read-JsonFile (Join-Path $PSScriptRoot 'manifest\mods.json')
$packageRootFull = [System.IO.Path]::GetFullPath($PackageRoot)

if ($Prepare) {
    New-Item -ItemType Directory -Path $packageRootFull -Force | Out-Null
}

$selectedPackages = @($manifest.packages)
if ($Id) {
    $selectedPackages = @($selectedPackages | Where-Object { $_.id -in $Id })
    $unknown = @($Id | Where-Object { $_ -notin $selectedPackages.id })
    if ($unknown.Count -gt 0) { throw "Unknown package ID(s): $($unknown -join ', ')" }
}

foreach ($package in $selectedPackages) {
    $packagePath = Join-Path $packageRootFull $package.id
    $overlayPath = Join-Path $packagePath 'overlay'

    if ($Prepare) {
        New-Item -ItemType Directory -Path $overlayPath -Force | Out-Null
        $shortcutPath = Join-Path $packagePath 'SOURCE.url'
        [System.IO.File]::WriteAllLines($shortcutPath, @('[InternetShortcut]', "URL=$($package.sourceUrl)"), [System.Text.UTF8Encoding]::new($false))

        $instructions = @(
            $package.name
            "Version: $($package.version)"
            "Source: $($package.sourceUrl)"
            ''
            'Extract installable files under overlay, preserving paths relative to the GTA SA game root.'
            'Never commit downloaded archives or third-party assets to this repository.'
        )
        [System.IO.File]::WriteAllLines((Join-Path $packagePath 'README.txt'), $instructions, [System.Text.UTF8Encoding]::new($false))
    }

    [pscustomobject]@{
        Id = $package.id
        Name = $package.name
        Version = $package.version
        Prepared = Test-Path -LiteralPath $overlayPath -PathType Container
        Source = $package.sourceUrl
    }

    if ($OpenManualPages) {
        Start-Process $package.sourceUrl
    }
}
