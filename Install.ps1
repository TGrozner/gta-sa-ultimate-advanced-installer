[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [string]$PackageRoot = (Join-Path $PSScriptRoot 'packages'),
    [switch]$SkipExecutableHash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$game = Resolve-GamePath $GamePath
$profile = Read-JsonFile (Join-Path $PSScriptRoot 'manifest\profile.json')
$running = @(Get-RunningGameProcesses $game)
if ($running.Count -gt 0) {
    throw "Close GTA SA before installing. Running PID(s): $($running.Id -join ', ')"
}

$executable = Join-Path $game 'gta_sa.exe'
$executableHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $executable).Hash
if (-not $SkipExecutableHash -and $executableHash -notin $profile.supportedExecutableHashes) {
    throw "Unsupported gta_sa.exe SHA-256: $executableHash"
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$backupRoot = Join-Path $game "_installer-backups\$timestamp"
$installedFiles = 0
$preparedPackages = 0

if (Test-Path -LiteralPath $PackageRoot -PathType Container) {
    foreach ($package in Get-ChildItem -LiteralPath $PackageRoot -Directory) {
        $overlay = Join-Path $package.FullName 'overlay'
        if (-not (Test-Path -LiteralPath $overlay -PathType Container)) { continue }
        $overlayFiles = @(Get-ChildItem -LiteralPath $overlay -Recurse -File)
        if ($overlayFiles.Count -eq 0) { continue }
        $preparedPackages++

        foreach ($file in $overlayFiles) {
            $relative = [System.IO.Path]::GetRelativePath($overlay, $file.FullName)
            $destination = Assert-ChildPath -Parent $game -Child (Join-Path $game $relative)
            $destinationDirectory = Split-Path -Parent $destination

            if ($PSCmdlet.ShouldProcess($destination, "Install $($package.Name) overlay file")) {
                if (Test-Path -LiteralPath $destination -PathType Leaf) {
                    $backup = Assert-ChildPath -Parent $backupRoot -Child (Join-Path $backupRoot $relative)
                    New-Item -ItemType Directory -Path (Split-Path -Parent $backup) -Force | Out-Null
                    Copy-Item -LiteralPath $destination -Destination $backup -Force
                }

                New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
                Copy-Item -LiteralPath $file.FullName -Destination $destination -Force
                $installedFiles++
            }
        }
    }
}

$ownedFiles = @(
    @{ Source = Join-Path $PSScriptRoot 'scripts\gta-f8-kill-switch.ps1'; Destination = Join-Path $game 'Tools\gta-f8-kill-switch.ps1' },
    @{ Source = Join-Path $PSScriptRoot 'scripts\Game-Launcher.ps1'; Destination = Join-Path $game 'Launch GTA SA 2026.ps1' }
)

foreach ($owned in $ownedFiles) {
    if ($PSCmdlet.ShouldProcess($owned.Destination, 'Install repository-owned launcher file')) {
        New-Item -ItemType Directory -Path (Split-Path -Parent $owned.Destination) -Force | Out-Null
        Copy-Item -LiteralPath $owned.Source -Destination $owned.Destination -Force
    }
}

$settings = @(
    @{ Path = 'modloader\_CORE - SaveLoader 2.7 Userfiles\III.VC.SA.SaveLoader.ini'; Section = 'MAIN'; Key = 'LoadSlot'; Value = '-1' },
    @{ Path = 'modloader\_CORE - SaveLoader 2.7 Userfiles\III.VC.SA.SaveLoader.ini'; Section = 'MAIN'; Key = 'SkipIntro'; Value = '1' },
    @{ Path = 'modloader\_CORE - SaveLoader 2.7 Userfiles\III.VC.SA.SaveLoader.ini'; Section = 'MAIN'; Key = 'CustomUserFilesDirectoryInGameDir'; Value = 'userfiles' },
    @{ Path = 'modloader\_CORE - GInput\GInputSA.ini'; Section = 'Pad1'; Key = 'ControlsSet'; Value = '2' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'MAIN'; Key = 'DrivebyControlType'; Value = '5' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'MAIN'; Key = 'DrivebyAimButton'; Value = 'RMB' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'EXCEPTIONS'; Key = 'DisableOnMission'; Value = '0' },
    @{ Path = 'modloader\_CORE - Framerate Vigilante\FramerateVigilante.ini'; Section = 'Settings'; Key = 'FPSlimit'; Value = '60' },
    @{ Path = 'modloader\_CORE - Framerate Vigilante\FramerateVigilante.ini'; Section = 'Settings'; Key = 'RefreshRate'; Value = '60' },
    @{ Path = 'modloader\_CORE - Framerate Vigilante\FramerateVigilante.ini'; Section = 'Settings'; Key = 'AutoLimitFPS'; Value = '1' },
    @{ Path = 'modloader\Graphics - SkyGfx 4.2b\skygfx1.ini'; Section = 'SkyGfx'; Key = 'buildingPipe'; Value = 'PS2' },
    @{ Path = 'modloader\Graphics - SkyGfx 4.2b\skygfx1.ini'; Section = 'SkyGfx'; Key = 'vehiclePipe'; Value = 'PS2' }
)

$configuredFiles = 0
foreach ($setting in $settings) {
    $path = Join-Path $game $setting.Path
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        Write-Warning "Configuration target missing: $($setting.Path)"
        continue
    }

    if ($PSCmdlet.ShouldProcess($path, "Set [$($setting.Section)] $($setting.Key)=$($setting.Value)")) {
        if (Set-IniValue -Path $path -Section $setting.Section -Key $setting.Key -Value $setting.Value) {
            $configuredFiles++
        }
    }
}

[pscustomobject]@{
    GamePath = $game
    ExecutableHash = $executableHash
    PreparedPackages = $preparedPackages
    InstalledFiles = $installedFiles
    ConfiguredSettings = $configuredFiles
    BackupRoot = if (Test-Path -LiteralPath $backupRoot) { $backupRoot } else { $null }
}

