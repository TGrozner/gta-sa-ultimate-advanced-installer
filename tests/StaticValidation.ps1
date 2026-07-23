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

$rosaPackage = $mods.packages | Where-Object id -eq 'rosa'
$flaPackage = $mods.packages | Where-Object id -eq 'fastman92-limit-adjuster'
if ($null -eq $rosaPackage -or $rosaPackage.targetModules -notcontains $profile.rosaValidation.module) {
    throw 'RoSA manifest target does not match the full validated module.'
}
if ($null -eq $flaPackage -or $flaPackage.version -ne '7.6' -or $flaPackage.requiredRuntimeFiles.Count -ne 4) {
    throw 'fastman92 Limit Adjuster 7.6 runtime contract is incomplete.'
}
$requiredForbiddenAdjusters = @('ImgLimitAdjuster.asi', 'SimpleLimitAdjuster_IMGfiles.asi')
$missingForbiddenAdjusters = $requiredForbiddenAdjusters |
    Where-Object { $_ -notin $profile.forbiddenActiveFiles }
if ($missingForbiddenAdjusters) {
    throw "Incompatible RoSA limit adjusters are not forbidden: $($missingForbiddenAdjusters -join ', ')"
}
$flaConfig = Join-Path $root 'config\fastman92limitAdjuster_GTASA.ini'
$flaConfigText = Get-Content -Raw -LiteralPath $flaConfig
$requiredFlaConfig = @(
    'Enable handling of new enhanced IMG archives = 0',
    'Max number of IMG archives = 64',
    'Increase the IMG archive size limit = 1'
)
$missingFlaConfig = $requiredFlaConfig |
    Where-Object { $flaConfigText -notmatch [regex]::Escape($_) }
if ($missingFlaConfig) {
    throw "RoSA fastman92 configuration is incomplete: $($missingFlaConfig -join ', ')"
}

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

$essentialsRoot = Join-Path $root 'packages\gtav-essentials\overlay\modloader\Gameplay - GTA V Essentials'
$essentialsBinary = Join-Path $essentialsRoot 'GTAVEssentials.asi'
$essentialsSource = Join-Path $root 'native\GTAVEssentials\GTAVEssentials.cpp'
if (-not (Test-Path -LiteralPath $essentialsBinary -PathType Leaf)) {
    throw 'Bundled GTAVEssentials.asi is missing.'
}
if (-not (Test-Path -LiteralPath $essentialsSource -PathType Leaf)) {
    throw 'GTAVEssentials source is missing.'
}
$essentialsSourceText = Get-Content -Raw -LiteralPath $essentialsSource
$requiredAutosaveGuards = @(
    'kIsPlayerOnMissionAddress',
    'kFindPlayerPedAddress',
    'kFindPlayerVehicleAddress',
    'kActiveScriptsAddress',
    'kGangWarStateAddress',
    'kCutsceneRunningAddress',
    'kMenuActiveAddress',
    'kPad0DisableControlsAddress',
    'kSelectedSaveGameAddress',
    'kSaveBypassAddress',
    'kRuntimeAutosaveSupported',
    'kFrameLimiterEnabledAddress',
    'g_autosaveSafeWindowMs',
    'FindLatestSafehouseLocation',
    'WriteValidatedAutosave',
    'RestorePreviousAutosave'
)
$missingAutosaveGuards = $requiredAutosaveGuards | Where-Object { $essentialsSourceText -notmatch [regex]::Escape($_) }
if ($missingAutosaveGuards) {
    throw "GTAVEssentials autosave safety guards are missing: $($missingAutosaveGuards -join ', ')"
}
$requiredBikeHandBrakeGuards = @(
    'kGetBrakeAddress',
    'kBikeProcessControlInputsStart',
    'kBikeProcessControlInputsEnd',
    'BrakeHook',
    'InstallBrakeHook',
    'kGetLookLeftAddress',
    'kGetLookRightAddress',
    'LookLeftHook',
    'LookRightHook',
    'InstallSideLookHook'
)
$missingBikeHandBrakeGuards = $requiredBikeHandBrakeGuards | Where-Object { $essentialsSourceText -notmatch [regex]::Escape($_) }
if ($missingBikeHandBrakeGuards) {
    throw "GTAVEssentials bike handbrake guards are missing: $($missingBikeHandBrakeGuards -join ', ')"
}
$disabledSideLookHooks = @(
    'bool __attribute__((fastcall)) LookLeftHook(void*, void*)',
    'bool __attribute__((fastcall)) LookRightHook(void*, void*)',
    'controls hook=%s action=disabled outcome=installed'
)
$missingDisabledSideLookHooks = $disabledSideLookHooks |
    Where-Object { $essentialsSourceText -notmatch [regex]::Escape($_) }
if ($missingDisabledSideLookHooks) {
    throw "GTAVEssentials side-look actions are not hard-disabled: $($missingDisabledSideLookHooks -join ', ')"
}
$binaryBytes = [System.IO.File]::ReadAllBytes($essentialsBinary)
if ($binaryBytes.Length -lt 1024 -or $binaryBytes[0] -ne 0x4D -or $binaryBytes[1] -ne 0x5A) {
    throw 'Bundled GTAVEssentials.asi is not a valid PE binary.'
}
$essentialsPackage = $mods.packages | Where-Object id -eq 'gtav-essentials'
$essentialsHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $essentialsBinary).Hash
if ($null -eq $essentialsPackage -or $essentialsHash -ne $essentialsPackage.bundledSha256) {
    throw "Bundled GTAVEssentials.asi hash mismatch: $essentialsHash"
}

Write-Host "Static validation passed: $($mods.packages.Count) sources, $($profile.requiredModules.Count) required modules." -ForegroundColor Green
