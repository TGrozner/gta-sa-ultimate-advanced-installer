[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [switch]$SkipExecutableHash,
    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$game = Resolve-GamePath $GamePath
$profilePath = Join-Path $PSScriptRoot 'manifest\profile.json'
$manifestPath = Join-Path $PSScriptRoot 'manifest\mods.json'
$profile = Read-JsonFile $profilePath
$issues = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
$passes = [System.Collections.Generic.List[string]]::new()

$hash = Get-FileSha256 -Path (Join-Path $game 'gta_sa.exe')
if ($SkipExecutableHash -or $hash -in $profile.supportedExecutableHashes) {
    $passes.Add("Executable accepted: $hash")
} else {
    $issues.Add("Unsupported gta_sa.exe SHA-256: $hash")
}

foreach ($file in $profile.requiredFiles) {
    $path = Assert-ChildPath -Parent $game -Child (Join-Path $game $file)
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $passes.Add("Required file present: $file")
    } else {
        $issues.Add("Missing required file: $file")
    }
}

$modloader = Assert-ChildPath -Parent $game -Child (Join-Path $game 'modloader')
foreach ($module in $profile.requiredModules) {
    $path = Assert-ChildPath -Parent $modloader -Child (Join-Path $modloader $module)
    $files = if (Test-Path -LiteralPath $path -PathType Container) {
        @(Get-ChildItem -LiteralPath $path -Recurse -File -ErrorAction SilentlyContinue)
    } else { @() }
    if ($files.Count -gt 0) {
        $passes.Add("Required module populated: $module")
    } else {
        $issues.Add("Missing or empty required module: $module")
    }
}

foreach ($optional in @($profile.optionalModules)) {
    $path = Assert-ChildPath -Parent $modloader -Child (Join-Path $modloader $optional.name)
    if (-not (Test-Path -LiteralPath $path -PathType Container)) { continue }
    $warnings.Add("Optional module enabled: $($optional.name) — $($optional.reason)")
    $optionalFiles = if ($optional.PSObject.Properties.Name -contains 'requiredFiles') { @($optional.requiredFiles) } else { @() }
    foreach ($file in $optionalFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $game $file) -PathType Leaf)) {
            $issues.Add("Optional module '$($optional.name)' is missing dependency: $file")
        }
    }
}

foreach ($excluded in @($profile.excludedModules)) {
    $path = Assert-ChildPath -Parent $modloader -Child (Join-Path $modloader $excluded.name)
    if (Test-Path -LiteralPath $path -PathType Container) {
        $issues.Add("Excluded module active: $($excluded.name) — $($excluded.reason)")
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

$expectedSettings = [System.Collections.Generic.List[object]]::new()
foreach ($setting in $profile.configuration) { $expectedSettings.Add($setting) }
foreach ($priority in $profile.modulePriorities.PSObject.Properties) {
    $expectedSettings.Add([pscustomobject]@{
        path = 'modloader/modloader.ini'
        section = "Profiles.$($profile.modLoaderProfile).Priority"
        key = $priority.Name
        value = [string]$priority.Value
        required = $true
    })
}
foreach ($setting in $expectedSettings) {
    $path = Assert-ChildPath -Parent $game -Child (Join-Path $game $setting.path)
    if (-not (Test-Path -LiteralPath $path -PathType Leaf) -and -not $setting.required) { continue }
    $actual = Get-IniValue -Path $path -Section $setting.section -Key $setting.key
    if ($actual -eq [string]$setting.value) {
        $passes.Add("Setting valid: $($setting.path) [$($setting.section)] $($setting.key)")
    } else {
        $issues.Add("Setting mismatch: $($setting.path) [$($setting.section)] $($setting.key), expected '$($setting.value)', got '$actual'")
    }
}

foreach ($rule in @($profile.compatibilityRules)) {
    $higher = [int]$profile.modulePriorities.($rule.higherPriorityModule)
    foreach ($lowerModule in $rule.lowerPriorityModules) {
        $lower = [int]$profile.modulePriorities.($lowerModule)
        if ($higher -le $lower) {
            $issues.Add("Invalid compatibility priority '$($rule.id)': '$($rule.higherPriorityModule)' ($higher) must be above '$lowerModule' ($lower).")
        }
    }
}

foreach ($tool in @('Tools/gta-f8-kill-switch.ps1', 'Launch GTA SA 2026.ps1')) {
    if (Test-Path -LiteralPath (Join-Path $game $tool) -PathType Leaf) {
        $passes.Add("Managed launcher file present: $tool")
    } else {
        $issues.Add("Managed launcher file missing: $tool")
    }
}

$transactionsRoot = Join-Path $game '_installer-transactions'
$latest = if (Test-Path -LiteralPath $transactionsRoot -PathType Container) {
    Get-ChildItem -LiteralPath $transactionsRoot -Directory |
        Sort-Object LastWriteTimeUtc -Descending |
        ForEach-Object {
            $path = Join-Path $_.FullName 'receipt.json'
            if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return }
            try {
                $value = Read-JsonFile $path
                if ($value.state -eq 'completed') { return [pscustomobject]@{ Path = $path; Value = $value } }
            } catch { }
        } |
        Select-Object -First 1
} else { $null }

if (-not $latest) {
    $issues.Add('No completed installer transaction receipt found.')
} else {
    $receipt = $latest.Value
    if ($receipt.manifestSha256 -ne (Get-FileSha256 -Path $manifestPath)) {
        $issues.Add('Installed transaction uses a different mod manifest revision.')
    }
    if ($receipt.profileSha256 -ne (Get-FileSha256 -Path $profilePath)) {
        $issues.Add('Installed transaction uses a different profile revision.')
    }
    foreach ($entry in $receipt.files) {
        $path = Assert-ChildPath -Parent $game -Child (Join-Path $game $entry.relativePath)
        if (-not $entry.installedSha256) {
            $issues.Add("Receipt has no installed hash: $($entry.relativePath)")
        } elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            $issues.Add("Managed file missing: $($entry.relativePath)")
        } elseif ((Get-FileSha256 -Path $path) -ne $entry.installedSha256) {
            $issues.Add("Managed file changed: $($entry.relativePath)")
        }
    }
    $passes.Add("Transaction receipt verified: $($receipt.transactionId)")
}

$result = [pscustomobject]@{
    Success = $issues.Count -eq 0
    Passes = @($passes)
    Warnings = @($warnings)
    Issues = @($issues)
}
if ($PassThru) { return $result }

Write-Host "PASS: $($passes.Count)" -ForegroundColor Green
$passes | ForEach-Object { Write-Host "  + $_" }
if ($warnings.Count -gt 0) {
    Write-Host "WARN: $($warnings.Count)" -ForegroundColor Yellow
    $warnings | ForEach-Object { Write-Host "  ! $_" }
}
if ($issues.Count -gt 0) {
    Write-Host "FAIL: $($issues.Count)" -ForegroundColor Red
    $issues | ForEach-Object { Write-Host "  - $_" }
    exit 1
}
Write-Host 'Installation matches the locked profile and its transaction receipt.' -ForegroundColor Green
