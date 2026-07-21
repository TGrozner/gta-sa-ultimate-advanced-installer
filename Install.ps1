[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [string]$PackageRoot = (Join-Path $PSScriptRoot 'packages'),
    [string]$PackageLockPath = (Join-Path $PSScriptRoot 'manifest\packages.lock.json'),
    [switch]$SkipExecutableHash,
    [switch]$AllowIncompleteProfile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

function Normalize-RelativePath {
    param([Parameter(Mandatory)][string]$Path)
    return $Path.Replace('\', '/').TrimStart('/')
}

$game = Resolve-GamePath $GamePath
$profilePath = Join-Path $PSScriptRoot 'manifest\profile.json'
$manifestPath = Join-Path $PSScriptRoot 'manifest\mods.json'
$profile = Read-JsonFile $profilePath
$manifest = Read-JsonFile $manifestPath
$packageLock = Read-JsonFile $PackageLockPath

$running = @(Get-RunningGameProcesses $game)
if ($running.Count -gt 0) {
    throw "Close GTA SA before installing. Running PID(s): $($running.Id -join ', ')"
}

$executable = Join-Path $game 'gta_sa.exe'
$executableHash = Get-FileSha256 -Path $executable
if (-not $SkipExecutableHash -and $executableHash -notin $profile.supportedExecutableHashes) {
    throw "Unsupported gta_sa.exe SHA-256: $executableHash"
}

if ($packageLock.schemaVersion -ne 1) { throw 'Unsupported package-lock schema.' }
$manifestHash = Get-FileSha256 -Path $manifestPath
if ($packageLock.manifestSha256 -ne $manifestHash) {
    throw "Package lock is stale. Run .\Lock-Packages.ps1. Expected manifest hash $manifestHash."
}

$manifestPackages = @{}
$packageOrder = @{}
for ($index = 0; $index -lt $manifest.packages.Count; $index++) {
    $package = $manifest.packages[$index]
    $manifestPackages[$package.id] = $package
    $packageOrder[$package.id] = $index
}

$lockedPackages = @{}
foreach ($locked in $packageLock.packages) {
    if ($lockedPackages.ContainsKey($locked.id)) { throw "Duplicate package in lock: $($locked.id)" }
    $lockedPackages[$locked.id] = $locked
}

$packageRootFull = [System.IO.Path]::GetFullPath($PackageRoot)
if (-not (Test-Path -LiteralPath $packageRootFull -PathType Container)) {
    throw "Package directory not found: $packageRootFull"
}

$copyOperations = [System.Collections.Generic.List[object]]::new()
$preparedPackageIds = [System.Collections.Generic.List[string]]::new()
foreach ($packageDirectory in Get-ChildItem -LiteralPath $packageRootFull -Directory | Sort-Object Name) {
    $overlay = Join-Path $packageDirectory.FullName 'overlay'
    $inventory = @(Get-FileInventory -Root $overlay)
    if ($inventory.Count -eq 0) { continue }

    $id = $packageDirectory.Name
    if (-not $manifestPackages.ContainsKey($id)) { throw "Unknown package directory: $id" }
    if (-not $lockedPackages.ContainsKey($id)) { throw "Prepared package is not locked: $id" }
    $package = $manifestPackages[$id]
    $locked = $lockedPackages[$id]
    if ($locked.version -ne $package.version) {
        throw "Locked version mismatch for ${id}: manifest '$($package.version)', lock '$($locked.version)'."
    }

    $actualByPath = @{}
    foreach ($file in $inventory) { $actualByPath[$file.path] = $file }
    $lockedByPath = @{}
    foreach ($file in $locked.files) { $lockedByPath[$file.path] = $file }
    $missingFromLock = @($actualByPath.Keys | Where-Object { -not $lockedByPath.ContainsKey($_) })
    $missingFromOverlay = @($lockedByPath.Keys | Where-Object { -not $actualByPath.ContainsKey($_) })
    if ($missingFromLock.Count -gt 0 -or $missingFromOverlay.Count -gt 0) {
        throw "Locked inventory mismatch for $id. Re-run .\Lock-Packages.ps1."
    }

    foreach ($file in $inventory) {
        $expected = $lockedByPath[$file.path]
        if ($file.sha256 -ne $expected.sha256 -or [long]$file.length -ne [long]$expected.length) {
            throw "Locked file mismatch for $id/$($file.path). Re-run .\Lock-Packages.ps1 only after verifying the package."
        }
        $source = Assert-ChildPath -Parent $overlay -Child (Join-Path $overlay $file.path)
        $relative = Normalize-RelativePath $file.path
        $destination = Assert-ChildPath -Parent $game -Child (Join-Path $game $relative)
        $copyOperations.Add([pscustomobject]@{
            PackageId = $id
            PackageOrder = $packageOrder[$id]
            Source = $source
            RelativePath = $relative
            Destination = $destination
            Sha256 = $file.sha256
        })
    }

    $inventoryPaths = @($inventory.path | ForEach-Object { (Normalize-RelativePath $_).ToLowerInvariant() })
    $declaredRootFiles = if ($package.PSObject.Properties.Name -contains 'rootFiles') { @($package.rootFiles) } else { @() }
    $declaredModules = if ($package.PSObject.Properties.Name -contains 'targetModules') { @($package.targetModules) } else { @() }
    foreach ($rootFile in $declaredRootFiles) {
        $declared = (Normalize-RelativePath $rootFile).ToLowerInvariant()
        if ($declared -notin $inventoryPaths) {
            throw "Package '$id' does not contain its declared root file: $rootFile"
        }
    }
    foreach ($module in $declaredModules) {
        $prefix = ('modloader/' + $module + '/').ToLowerInvariant()
        if (@($inventoryPaths | Where-Object { $_.StartsWith($prefix) }).Count -eq 0) {
            throw "Package '$id' does not contain its declared module: $module"
        }
    }
    $preparedPackageIds.Add($id)
}

$unpreparedLocks = @($lockedPackages.Keys | Where-Object { $_ -notin $preparedPackageIds })
if ($unpreparedLocks.Count -gt 0) {
    throw "Package lock references overlays that are not prepared: $($unpreparedLocks -join ', ')"
}

$ownedFiles = @(
    @{ Source = Join-Path $PSScriptRoot 'scripts\gta-f8-kill-switch.ps1'; RelativePath = 'Tools/gta-f8-kill-switch.ps1' },
    @{ Source = Join-Path $PSScriptRoot 'scripts\Game-Launcher.ps1'; RelativePath = 'Launch GTA SA 2026.ps1' }
)
foreach ($owned in $ownedFiles) {
    $sourceHash = Get-FileSha256 -Path $owned.Source
    $destination = Assert-ChildPath -Parent $game -Child (Join-Path $game $owned.RelativePath)
    $copyOperations.Add([pscustomobject]@{
        PackageId = '_installer'
        PackageOrder = [int]::MaxValue
        Source = $owned.Source
        RelativePath = Normalize-RelativePath $owned.RelativePath
        Destination = $destination
        Sha256 = $sourceHash
    })
}

$allowedConflicts = @{}
foreach ($rule in @($profile.allowedOverlayConflicts)) {
    $allowedConflicts[(Normalize-RelativePath $rule.path).ToLowerInvariant()] = $rule.winnerPackageId
}

$resolvedCopies = [System.Collections.Generic.List[object]]::new()
$conflictMessages = [System.Collections.Generic.List[string]]::new()
foreach ($group in $copyOperations | Group-Object { $_.RelativePath.ToLowerInvariant() }) {
    $members = @($group.Group | Sort-Object PackageOrder, PackageId)
    if ($members.Count -eq 1) {
        $resolvedCopies.Add($members[0])
        continue
    }

    $hashes = @($members.Sha256 | Select-Object -Unique)
    if ($hashes.Count -eq 1) {
        $resolvedCopies.Add($members[0])
        $conflictMessages.Add("Identical duplicate collapsed: $($members[0].RelativePath) [$($members.PackageId -join ', ')]")
        continue
    }

    $key = $group.Name
    if (-not $allowedConflicts.ContainsKey($key)) {
        throw "Overlay collision with different content: $($members[0].RelativePath) [$($members.PackageId -join ', ')]"
    }
    $winnerId = $allowedConflicts[$key]
    $winner = @($members | Where-Object PackageId -eq $winnerId)
    if ($winner.Count -ne 1) {
        throw "Invalid collision rule for $($members[0].RelativePath): winner '$winnerId' is not unique."
    }
    $resolvedCopies.Add($winner[0])
    $conflictMessages.Add("Declared collision resolved: $($members[0].RelativePath) -> $winnerId")
}

$plannedRelativePaths = @($resolvedCopies.RelativePath | ForEach-Object { $_.ToLowerInvariant() })
$missingRequirements = [System.Collections.Generic.List[string]]::new()
foreach ($module in $profile.requiredModules) {
    $prefix = ('modloader/' + $module + '/').ToLowerInvariant()
    $planned = @($plannedRelativePaths | Where-Object { $_.StartsWith($prefix) }).Count -gt 0
    if (-not $planned -and -not $AllowIncompleteProfile) {
        $missingRequirements.Add("module:$module")
    }
}
foreach ($file in $profile.requiredFiles) {
    $relative = Normalize-RelativePath $file
    $planned = $relative.ToLowerInvariant() -in $plannedRelativePaths
    if (-not $planned -and -not $AllowIncompleteProfile) {
        $missingRequirements.Add("file:$relative")
    }
}

foreach ($optional in @($profile.optionalModules)) {
    if ($optional.packageId -notin $preparedPackageIds) { continue }
    $optionalFiles = if ($optional.PSObject.Properties.Name -contains 'requiredFiles') { @($optional.requiredFiles) } else { @() }
    foreach ($file in $optionalFiles) {
        $relative = Normalize-RelativePath $file
        $planned = $relative.ToLowerInvariant() -in $plannedRelativePaths
        $existing = Test-Path -LiteralPath (Join-Path $game $relative) -PathType Leaf
        if (-not $planned -and -not $existing) {
            $missingRequirements.Add("optional-dependency:$($optional.packageId):$relative")
        }
    }
}

foreach ($excluded in @($profile.excludedModules)) {
    $prefix = ('modloader/' + $excluded.name + '/').ToLowerInvariant()
    if (@($plannedRelativePaths | Where-Object { $_.StartsWith($prefix) }).Count -gt 0) {
        throw "Prepared overlays contain excluded module '$($excluded.name)': $($excluded.reason)"
    }
}
if ($missingRequirements.Count -gt 0) {
    throw "Incomplete package set. Missing $($missingRequirements.Count) requirement(s): $($missingRequirements -join ', ')"
}

$settings = [System.Collections.Generic.List[object]]::new()
foreach ($setting in $profile.configuration) { $settings.Add($setting) }
foreach ($priority in $profile.modulePriorities.PSObject.Properties) {
    $settings.Add([pscustomobject]@{
        path = 'modloader/modloader.ini'
        section = "Profiles.$($profile.modLoaderProfile).Priority"
        key = $priority.Name
        value = [string]$priority.Value
        required = $true
    })
}

foreach ($setting in $settings) {
    $relative = Normalize-RelativePath $setting.path
    $planned = $relative.ToLowerInvariant() -in $plannedRelativePaths
    $existing = Test-Path -LiteralPath (Join-Path $game $relative) -PathType Leaf
    if (-not $planned -and -not $existing -and $setting.required -and -not $AllowIncompleteProfile) {
        throw "Required configuration target is not provided: $relative"
    }
}

$targetEntries = [System.Collections.Generic.Dictionary[string,object]]::new([System.StringComparer]::OrdinalIgnoreCase)
foreach ($copy in $resolvedCopies) {
    if (-not $targetEntries.ContainsKey($copy.RelativePath)) {
        $targetEntries[$copy.RelativePath] = [ordered]@{
            relativePath = $copy.RelativePath
            existedBefore = $false
            originalSha256 = $null
            backupRelativePath = $null
            installedSha256 = $null
            sources = @($copy.PackageId)
        }
    } else {
        $targetEntries[$copy.RelativePath].sources += $copy.PackageId
    }
}
foreach ($setting in $settings) {
    $relative = Normalize-RelativePath $setting.path
    if (-not $targetEntries.ContainsKey($relative)) {
        $targetEntries[$relative] = [ordered]@{
            relativePath = $relative
            existedBefore = $false
            originalSha256 = $null
            backupRelativePath = $null
            installedSha256 = $null
            sources = @('_configuration')
        }
    } elseif ('_configuration' -notin $targetEntries[$relative].sources) {
        $targetEntries[$relative].sources += '_configuration'
    }
}

$plan = [pscustomobject]@{
    GamePath = $game
    ExecutableHash = $executableHash
    Packages = @($preparedPackageIds)
    CopyFiles = $resolvedCopies.Count
    ConfigurationValues = $settings.Count
    ManagedFiles = $targetEntries.Count
    CollisionDecisions = @($conflictMessages)
}
if (-not $PSCmdlet.ShouldProcess($game, "Install $($preparedPackageIds.Count) locked package(s) and manage $($targetEntries.Count) file(s)")) {
    return $plan
}

$transactionId = (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
$transactionRoot = Assert-ChildPath -Parent $game -Child (Join-Path $game "_installer-transactions\$transactionId")
$backupFilesRoot = Join-Path $transactionRoot 'files'
$receiptPath = Join-Path $transactionRoot 'receipt.json'
New-Item -ItemType Directory -Path $backupFilesRoot -Force | Out-Null

$receipt = [ordered]@{
    schemaVersion = 1
    transactionId = $transactionId
    state = 'planned'
    startedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    completedAtUtc = $null
    restoredAtUtc = $null
    gamePath = $game
    executableSha256 = $executableHash
    profileSha256 = Get-FileSha256 -Path $profilePath
    manifestSha256 = $manifestHash
    packageLockSha256 = Get-FileSha256 -Path $PackageLockPath
    packageIds = @($preparedPackageIds)
    collisionDecisions = @($conflictMessages)
    files = @($targetEntries.Values)
    error = $null
}
Write-JsonFile -Path $receiptPath -Value $receipt -Depth 12

$mutationsStarted = $false
try {
    foreach ($entry in $receipt.files) {
        $destination = Assert-ChildPath -Parent $game -Child (Join-Path $game $entry.relativePath)
        if (Test-Path -LiteralPath $destination -PathType Container) {
            throw "Managed file path is an existing directory: $($entry.relativePath)"
        }
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $entry.existedBefore = $true
            $entry.originalSha256 = Get-FileSha256 -Path $destination
            $entry.backupRelativePath = Normalize-RelativePath (Join-Path 'files' $entry.relativePath)
            $backup = Assert-ChildPath -Parent $transactionRoot -Child (Join-Path $transactionRoot $entry.backupRelativePath)
            New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
            Copy-Item -LiteralPath $destination -Destination $backup -Force
            if ((Get-FileSha256 -Path $backup) -ne $entry.originalSha256) {
                throw "Backup verification failed: $($entry.relativePath)"
            }
        }
    }

    $receipt.state = 'backed-up'
    Write-JsonFile -Path $receiptPath -Value $receipt -Depth 12
    $mutationsStarted = $true

    foreach ($copy in $resolvedCopies | Sort-Object PackageOrder, RelativePath) {
        Copy-FileAtomically -Source $copy.Source -Destination $copy.Destination
        if ((Get-FileSha256 -Path $copy.Destination) -ne $copy.Sha256) {
            throw "Post-copy verification failed: $($copy.RelativePath)"
        }
    }

    $configuredValues = 0
    foreach ($setting in $settings) {
        $relative = Normalize-RelativePath $setting.path
        $path = Assert-ChildPath -Parent $game -Child (Join-Path $game $relative)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            if ($setting.required -and -not $AllowIncompleteProfile) {
                throw "Configuration target disappeared during installation: $relative"
            }
            continue
        }
        if (-not (Set-IniValue -Path $path -Section $setting.section -Key $setting.key -Value ([string]$setting.value))) {
            throw "Failed to configure $relative [$($setting.section)] $($setting.key)"
        }
        $configuredValues++
    }

    foreach ($entry in $receipt.files) {
        $destination = Join-Path $game $entry.relativePath
        if (Test-Path -LiteralPath $destination -PathType Leaf) {
            $entry.installedSha256 = Get-FileSha256 -Path $destination
        }
    }
    $receipt.state = 'completed'
    $receipt.completedAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    Write-JsonFile -Path $receiptPath -Value $receipt -Depth 12

    [pscustomobject]@{
        GamePath = $game
        ExecutableHash = $executableHash
        TransactionId = $transactionId
        ReceiptPath = $receiptPath
        PreparedPackages = $preparedPackageIds.Count
        InstalledFiles = $resolvedCopies.Count
        ConfiguredValues = $configuredValues
        CollisionDecisions = @($conflictMessages)
    }
} catch {
    $failure = $_
    $receipt.error = $failure.Exception.Message
    if ($mutationsStarted) {
        $rollbackErrors = [System.Collections.Generic.List[string]]::new()
        for ($index = $receipt.files.Count - 1; $index -ge 0; $index--) {
            $entry = $receipt.files[$index]
            try {
                $destination = Assert-ChildPath -Parent $game -Child (Join-Path $game $entry.relativePath)
                if ($entry.existedBefore) {
                    $backup = Assert-ChildPath -Parent $transactionRoot -Child (Join-Path $transactionRoot $entry.backupRelativePath)
                    Copy-FileAtomically -Source $backup -Destination $destination
                } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
                    Remove-Item -LiteralPath $destination -Force
                }
            } catch {
                $rollbackErrors.Add("$($entry.relativePath): $($_.Exception.Message)")
            }
        }
        $receipt.state = if ($rollbackErrors.Count -eq 0) { 'rolled-back' } else { 'rollback-failed' }
        if ($rollbackErrors.Count -gt 0) { $receipt.error += " | Rollback: $($rollbackErrors -join '; ')" }
    } else {
        $receipt.state = 'failed-before-mutation'
    }
    Write-JsonFile -Path $receiptPath -Value $receipt -Depth 12
    throw $failure
}
