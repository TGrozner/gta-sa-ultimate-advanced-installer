[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
. (Join-Path $root 'scripts\Common.ps1')

$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('gta-installer-test-' + [guid]::NewGuid().ToString('N'))
$game = Join-Path $testRoot 'game'
$originalIni = "[Original]`r`nPreserve = yes`r`n"
try {
    New-Item -ItemType Directory -Path $game -Force | Out-Null
    [System.IO.File]::WriteAllText((Join-Path $game 'gta_sa.exe'), 'test executable')
    $ini = Join-Path $game 'modloader\Gameplay - GTA V Essentials\GTAVEssentials.ini'
    New-Item -ItemType Directory -Path (Split-Path -Parent $ini) -Force | Out-Null
    [System.IO.File]::WriteAllText($ini, $originalIni, [System.Text.Encoding]::ASCII)
    $originalHash = Get-FileSha256 -Path $ini

    $preview = & (Join-Path $root 'Install.ps1') -GamePath $game -SkipExecutableHash -AllowIncompleteProfile -WhatIf
    if (-not $preview -or $preview.CopyFiles -lt 3) { throw 'WhatIf did not return a complete installation plan.' }
    if (Test-Path -LiteralPath (Join-Path $game '_installer-transactions')) { throw 'WhatIf mutated the game directory.' }

    $installed = & (Join-Path $root 'Install.ps1') -GamePath $game -SkipExecutableHash -AllowIncompleteProfile -Confirm:$false
    if (-not $installed.TransactionId) { throw 'Installer did not return a transaction ID.' }
    $receipt = Read-JsonFile $installed.ReceiptPath
    if ($receipt.state -ne 'completed') { throw "Unexpected receipt state: $($receipt.state)" }
    if ((Get-IniValue -Path $ini -Section 'Controls' -Key 'Enabled') -ne '1') { throw 'Profile configuration was not applied.' }
    if (-not (Test-Path -LiteralPath (Join-Path $game 'Tools\gta-f8-kill-switch.ps1') -PathType Leaf)) { throw 'F8 watcher was not installed.' }

    $restored = & (Join-Path $root 'Restore-Installation.ps1') -GamePath $game -TransactionId $installed.TransactionId -Confirm:$false
    if ($restored.TransactionId -ne $installed.TransactionId) { throw 'Wrong transaction was restored.' }
    if ((Get-FileSha256 -Path $ini) -ne $originalHash) { throw 'Original INI was not restored byte-for-byte.' }
    if (Test-Path -LiteralPath (Join-Path $game 'Tools\gta-f8-kill-switch.ps1') -PathType Leaf) { throw 'New installer file was not removed.' }
    $receipt = Read-JsonFile $installed.ReceiptPath
    if ($receipt.state -ne 'restored') { throw "Restore receipt did not reach restored state: $($receipt.state)" }

    Write-Host 'Installer lifecycle passed: WhatIf, install receipt, configuration, and byte-exact restore.' -ForegroundColor Green
} finally {
    if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
