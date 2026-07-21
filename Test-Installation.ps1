[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [switch]$SkipExecutableHash
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$game = Resolve-GamePath $GamePath
$profile = Read-JsonFile (Join-Path $PSScriptRoot 'manifest\profile.json')
$issues = [System.Collections.Generic.List[string]]::new()
$passes = [System.Collections.Generic.List[string]]::new()

$hash = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $game 'gta_sa.exe')).Hash
if ($SkipExecutableHash -or $hash -in $profile.supportedExecutableHashes) {
    $passes.Add("Supported executable: $hash")
} else {
    $issues.Add("Unsupported gta_sa.exe SHA-256: $hash")
}

foreach ($file in $profile.requiredRootFiles) {
    if (Test-Path -LiteralPath (Join-Path $game $file) -PathType Leaf) {
        $passes.Add("Root dependency present: $file")
    } else {
        $issues.Add("Missing root dependency: $file")
    }
}

$modloader = Join-Path $game 'modloader'
foreach ($module in $profile.requiredModules) {
    if (Test-Path -LiteralPath (Join-Path $modloader $module) -PathType Container) {
        $passes.Add("Module present: $module")
    } else {
        $issues.Add("Missing module: $module")
    }
}

foreach ($module in $profile.forbiddenModules) {
    $matches = @(Get-ChildItem -LiteralPath $modloader -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like "*$module*" })
    foreach ($match in $matches) { $issues.Add("Forbidden module active: $($match.Name)") }
}

foreach ($file in $profile.forbiddenRootFiles) {
    if (Test-Path -LiteralPath (Join-Path $game $file) -PathType Leaf) {
        $issues.Add("Forbidden root wrapper: $file")
    }
}

$expectedSettings = @(
    @{ Path = 'modloader\_CORE - GInput\GInputSA.ini'; Section = 'Pad1'; Key = 'ControlsSet'; Value = '2' },
    @{ Path = 'modloader\_CORE - GInput\GInputSA.ini'; Section = 'Pad2'; Key = 'ControlsSet'; Value = '2' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'MAIN'; Key = 'DrivebyControlType'; Value = '5' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'MAIN'; Key = 'NoDrivingWhileAiming'; Value = '0' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'MAIN'; Key = 'FreeLineOfSight'; Value = '1' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'MAIN'; Key = 'NoAngleLimit'; Value = '1' },
    @{ Path = 'modloader\Controls - Manual DriveBy Refixed\cleo\DrivebySettings.ini'; Section = 'EXCEPTIONS'; Key = 'DisableOnMission'; Value = '0' },
    @{ Path = 'modloader\Gameplay - GTA V Essentials\GTAVEssentials.ini'; Section = 'Controls'; Key = 'Enabled'; Value = '1' },
    @{ Path = 'modloader\Gameplay - GTA V Essentials\GTAVEssentials.ini'; Section = 'Controls'; Key = 'R3LookBehind'; Value = '1' },
    @{ Path = 'modloader\Gameplay - GTA V Essentials\GTAVEssentials.ini'; Section = 'Compatibility'; Key = 'ForceFrameLimiter'; Value = '1' },
    @{ Path = 'modloader\Gameplay - GTA V Essentials\GTAVEssentials.ini'; Section = 'Autosave'; Key = 'Enabled'; Value = '0' },
    @{ Path = 'modloader\Gameplay - GTA V Essentials\GTAVEssentials.ini'; Section = 'Autosave'; Key = 'Slot'; Value = '7' },
    @{ Path = 'modloader\Gameplay - GTA V Essentials\GTAVEssentials.ini'; Section = 'Autosave'; Key = 'SafeWindowMs'; Value = '10000' },
    @{ Path = 'modloader\modloader.ini'; Section = 'Profiles.Advanced2026.Priority'; Key = 'Gameplay - GTA V Essentials'; Value = '95' },
    @{ Path = 'modloader\_CORE - Framerate Vigilante\FramerateVigilante.ini'; Section = 'Settings'; Key = 'FPSlimit'; Value = '60' },
    @{ Path = 'modloader\Graphics - SkyGfx 4.2b\skygfx1.ini'; Section = 'SkyGfx'; Key = 'buildingPipe'; Value = 'PS2' }
)

foreach ($setting in $expectedSettings) {
    $path = Join-Path $game $setting.Path
    $actual = Get-IniValue -Path $path -Section $setting.Section -Key $setting.Key
    if ($actual -eq $setting.Value) {
        $passes.Add("Setting valid: $($setting.Key)=$actual")
    } else {
        $issues.Add("Setting mismatch: $($setting.Path) [$($setting.Section)] $($setting.Key), expected '$($setting.Value)', got '$actual'")
    }
}

if (Test-Path -LiteralPath (Join-Path $game 'Tools\gta-f8-kill-switch.ps1') -PathType Leaf) {
    $passes.Add('F8 kill switch installed')
} else {
    $issues.Add('F8 kill switch missing')
}

Write-Host "PASS: $($passes.Count)" -ForegroundColor Green
$passes | ForEach-Object { Write-Host "  + $_" }

if ($issues.Count -gt 0) {
    Write-Host "FAIL: $($issues.Count)" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "  - $_" }
    exit 1
}

Write-Host 'Installation matches the validated profile.' -ForegroundColor Green
