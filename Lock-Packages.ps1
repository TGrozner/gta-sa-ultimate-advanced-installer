[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot 'packages'),
    [string]$OutputPath = (Join-Path $PSScriptRoot 'manifest\packages.lock.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$manifestPath = Join-Path $PSScriptRoot 'manifest\mods.json'
$manifest = Read-JsonFile $manifestPath
$knownPackages = @{}
foreach ($package in $manifest.packages) { $knownPackages[$package.id] = $package }

$packageRootFull = [System.IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $packageRootFull -PathType Container)) {
    throw "Package directory not found: $packageRootFull"
}

$lockedPackages = [System.Collections.Generic.List[object]]::new()
foreach ($directory in Get-ChildItem -LiteralPath $packageRootFull -Directory | Sort-Object Name) {
    $overlay = Join-Path $directory.FullName 'overlay'
    $files = @(Get-FileInventory -Root $overlay)
    if ($files.Count -eq 0) { continue }
    if (-not $knownPackages.ContainsKey($directory.Name)) {
        throw "Unknown package directory with installable files: $($directory.Name)"
    }

    $lockedPackages.Add([pscustomobject]@{
        id = $directory.Name
        version = $knownPackages[$directory.Name].version
        files = $files
    })
}

$lock = [ordered]@{
    schemaVersion = 1
    generatedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    manifestSha256 = Get-FileSha256 -Path $manifestPath
    packages = $lockedPackages
}

if ($PSCmdlet.ShouldProcess([System.IO.Path]::GetFullPath($OutputPath), "Lock $($lockedPackages.Count) prepared package(s)")) {
    Write-JsonFile -Path $OutputPath -Value $lock -Depth 12
}

[pscustomobject]@{
    LockPath = [System.IO.Path]::GetFullPath($OutputPath)
    Packages = $lockedPackages.Count
    Files = @($lockedPackages | ForEach-Object { $_.files }).Count
    ManifestSha256 = $lock.manifestSha256
}
