[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\Common.ps1')

$profilePath = Join-Path $root 'manifest\profile.json'
$modsPath = Join-Path $root 'manifest\mods.json'
$lockPath = Join-Path $root 'manifest\packages.lock.json'
$profile = Read-JsonFile $profilePath
$mods = Read-JsonFile $modsPath
$lock = Read-JsonFile $lockPath

if ($profile.schemaVersion -ne 2 -or $mods.schemaVersion -ne 2 -or $lock.schemaVersion -ne 1) {
    throw 'Unsupported manifest or lock schema.'
}
if ($lock.manifestSha256 -ne (Get-FileSha256 -Path $modsPath)) {
    throw 'packages.lock.json is stale; run Lock-Packages.ps1.'
}
if (@($profile.supportedExecutableHashes | Where-Object { $_ -notmatch '^[A-Fa-f0-9]{64}$' }).Count -gt 0) {
    throw 'Every supported executable hash must be a SHA-256 value.'
}

$duplicateIds = @($mods.packages | Group-Object id | Where-Object Count -gt 1)
if ($duplicateIds.Count -gt 0) { throw "Duplicate package IDs: $($duplicateIds.Name -join ', ')" }
$duplicateModules = @($mods.packages | ForEach-Object { $_.targetModules } | Group-Object | Where-Object Count -gt 1)
if ($duplicateModules.Count -gt 0) { throw "Modules have multiple package owners: $($duplicateModules.Name -join ', ')" }

$packageById = @{}
$moduleOwners = @{}
$rootFileOwners = @{}
foreach ($package in $mods.packages) {
    $packageById[$package.id] = $package
    foreach ($property in @('id', 'name', 'version', 'sourceUrl', 'sourceKind', 'license')) {
        if ($package.PSObject.Properties.Name -notcontains $property -or [string]::IsNullOrWhiteSpace([string]$package.$property)) {
            throw "Package '$($package.id)' is missing '$property'."
        }
    }
    if ($package.sourceUrl -notmatch '^https://') { throw "Non-HTTPS source URL: $($package.id)" }
    if ($package.sourceKind -notin @('manual', 'bundled-source')) {
        throw "Unsupported source kind for '$($package.id)': $($package.sourceKind)"
    }
    $targetModules = if ($package.PSObject.Properties.Name -contains 'targetModules') { @($package.targetModules) } else { @() }
    $rootFiles = if ($package.PSObject.Properties.Name -contains 'rootFiles') { @($package.rootFiles) } else { @() }
    if ($targetModules.Count -eq 0 -and $rootFiles.Count -eq 0) {
        throw "Package '$($package.id)' declares no install target."
    }
    foreach ($module in $targetModules) { $moduleOwners[$module] = $package.id }
    foreach ($file in $rootFiles) {
        if ($rootFileOwners.ContainsKey($file)) { throw "Root file '$file' has more than one package owner." }
        $rootFileOwners[$file] = $package.id
    }
}

$activeModules = @($profile.requiredModules) + @($profile.optionalModules | ForEach-Object name)
foreach ($module in $activeModules) {
    if (-not $moduleOwners.ContainsKey($module)) { throw "Profile module has no package owner: $module" }
}
foreach ($file in $profile.requiredFiles) {
    if (-not $rootFileOwners.ContainsKey($file)) { throw "Required file has no package owner: $file" }
}
foreach ($optional in @($profile.optionalModules)) {
    if (-not $packageById.ContainsKey($optional.packageId)) { throw "Unknown optional package: $($optional.packageId)" }
    if ($moduleOwners[$optional.name] -ne $optional.packageId) {
        throw "Optional module/package mismatch: $($optional.name) -> $($optional.packageId)"
    }
}
$excludedNames = @($profile.excludedModules | ForEach-Object name)
foreach ($module in $excludedNames) {
    if ($module -in $activeModules) { throw "Excluded module is active: $module" }
    if ($profile.modulePriorities.PSObject.Properties.Name -contains $module) { throw "Excluded module has a priority: $module" }
}
foreach ($priority in $profile.modulePriorities.PSObject.Properties) {
    if ($priority.Name -notin $activeModules) { throw "Priority references inactive module: $($priority.Name)" }
}
foreach ($rule in @($profile.compatibilityRules)) {
    if ($profile.modulePriorities.PSObject.Properties.Name -notcontains $rule.higherPriorityModule) {
        throw "Compatibility rule has no higher priority: $($rule.id)"
    }
    $higher = [int]$profile.modulePriorities.($rule.higherPriorityModule)
    foreach ($lowerModule in $rule.lowerPriorityModules) {
        if ($profile.modulePriorities.PSObject.Properties.Name -notcontains $lowerModule) {
            throw "Compatibility rule has no lower priority: $($rule.id)/$lowerModule"
        }
        if ($higher -le [int]$profile.modulePriorities.($lowerModule)) {
            throw "Compatibility rule priority is inverted: $($rule.id)"
        }
    }
}
$duplicateSettings = @($profile.configuration |
    Group-Object { "$($_.path)|$($_.section)|$($_.key)".ToLowerInvariant() } |
    Where-Object Count -gt 1)
if ($duplicateSettings.Count -gt 0) { throw "Duplicate configuration keys: $($duplicateSettings.Name -join ', ')" }

$lockedIds = @{}
foreach ($lockedPackage in $lock.packages) {
    if (-not $packageById.ContainsKey($lockedPackage.id)) { throw "Lock contains unknown package: $($lockedPackage.id)" }
    if ($lockedIds.ContainsKey($lockedPackage.id)) { throw "Lock contains duplicate package: $($lockedPackage.id)" }
    $lockedIds[$lockedPackage.id] = $true
    if ($lockedPackage.version -ne $packageById[$lockedPackage.id].version) { throw "Locked version mismatch: $($lockedPackage.id)" }
    $overlay = Join-Path $root "packages\$($lockedPackage.id)\overlay"
    $actual = @(Get-FileInventory -Root $overlay)
    $actualMap = @{}; foreach ($file in $actual) { $actualMap[$file.path] = $file }
    $lockedMap = @{}; foreach ($file in $lockedPackage.files) { $lockedMap[$file.path] = $file }
    if ($actualMap.Count -ne $lockedMap.Count) { throw "Locked inventory size mismatch: $($lockedPackage.id)" }
    foreach ($path in $actualMap.Keys) {
        if (-not $lockedMap.ContainsKey($path) -or $actualMap[$path].sha256 -ne $lockedMap[$path].sha256 -or
            [long]$actualMap[$path].length -ne [long]$lockedMap[$path].length) {
            throw "Locked inventory mismatch: $($lockedPackage.id)/$path"
        }
    }
}

$tokens = $null
$errors = $null
foreach ($script in Get-ChildItem -LiteralPath $root -Recurse -File -Filter '*.ps1') {
    [void][System.Management.Automation.Language.Parser]::ParseFile($script.FullName, [ref]$tokens, [ref]$errors)
    if (@($errors).Count -gt 0) { throw "PowerShell parse failure in $($script.FullName): $($errors[0].Message)" }
}
$tooLarge = Get-ChildItem -LiteralPath $root -Recurse -File |
    Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' -and $_.Length -gt 5MB }
if ($tooLarge) { throw "Unexpected large repository file: $($tooLarge.FullName -join ', ')" }

$essentialsRoot = Join-Path $root 'packages\gtav-essentials\overlay\modloader\Gameplay - GTA V Essentials'
$essentialsBinary = Join-Path $essentialsRoot 'GTAVEssentials.asi'
$essentialsSource = Join-Path $root 'native\GTAVEssentials\GTAVEssentials.cpp'
$binaryBytes = [System.IO.File]::ReadAllBytes($essentialsBinary)
if ($binaryBytes.Length -lt 1024 -or $binaryBytes[0] -ne 0x4D -or $binaryBytes[1] -ne 0x5A) {
    throw 'Bundled GTAVEssentials.asi is not a valid PE binary.'
}
$essentialsPackage = $packageById['gtav-essentials']
$essentialsHash = Get-FileSha256 -Path $essentialsBinary
if ($essentialsHash -ne $essentialsPackage.bundledSha256) { throw "Bundled ASI hash mismatch: $essentialsHash" }
$sourceText = Get-Content -Raw -LiteralPath $essentialsSource
foreach ($guard in @('kSupportedExecutableSha256', 'IsSupportedExecutable', 'PrepareThiscallHook', 'WriteExecutableMemory')) {
    if ($sourceText -notmatch [regex]::Escape($guard)) { throw "Native hook guard is missing: $guard" }
}
if ($sourceText -match '(?i)autosave|kSaveSlotAddress') { throw 'Dead autosave code remains in GTAVEssentials.' }

$watcherText = Get-Content -Raw -LiteralPath (Join-Path $root 'scripts\gta-f8-kill-switch.ps1')
foreach ($guard in @('ProcessId', 'ExpectedExecutable', 'QueryFullProcessImageName')) {
    if ($watcherText -notmatch [regex]::Escape($guard)) { throw "F8 scope guard is missing: $guard" }
}
if ($watcherText -match 'GetProcessesByName') { throw 'F8 watcher still targets processes globally.' }
if (-not (Test-Path -LiteralPath (Join-Path $root 'Restore-Installation.ps1') -PathType Leaf)) {
    throw 'Restore-Installation.ps1 is missing.'
}

Write-Host "Static validation passed: $($mods.packages.Count) sources, $($profile.requiredModules.Count) required modules, $($lock.packages.Count) locked overlays." -ForegroundColor Green
