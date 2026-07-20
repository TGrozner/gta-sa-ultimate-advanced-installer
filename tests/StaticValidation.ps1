[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))

$profile = Get-Content -Raw -LiteralPath (Join-Path $root 'manifest\profile.json') | ConvertFrom-Json
$mods = Get-Content -Raw -LiteralPath (Join-Path $root 'manifest\mods.json') | ConvertFrom-Json

if ($profile.schemaVersion -ne 1 -or $mods.schemaVersion -ne 1) {
    throw 'Unsupported manifest schema.'
}

$duplicateIds = $mods.packages | Group-Object id | Where-Object Count -gt 1
if ($duplicateIds) { throw "Duplicate package IDs: $($duplicateIds.Name -join ', ')" }

$invalidUrls = $mods.packages | Where-Object { $_.sourceUrl -notmatch '^https://' }
if ($invalidUrls) { throw "Non-HTTPS source URLs: $($invalidUrls.id -join ', ')" }

$tokens = $null
$errors = $null
foreach ($script in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1') {
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        throw "PowerShell parse failure in $($script.FullName): $($errors[0].Message)"
    }
}

$trackedCandidates = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch '\\.git\\' }
$tooLarge = $trackedCandidates | Where-Object Length -gt 5MB
if ($tooLarge) { throw "Unexpected large repository file: $($tooLarge.FullName -join ', ')" }

Write-Host "Static validation passed: $($mods.packages.Count) sources, $($profile.requiredModules.Count) required modules." -ForegroundColor Green

