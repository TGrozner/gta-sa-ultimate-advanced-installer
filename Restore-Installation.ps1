[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$GamePath,
    [ValidatePattern('^[A-Za-z0-9-]+$')][string]$TransactionId,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'scripts\Common.ps1')

$game = Resolve-GamePath $GamePath
$running = @(Get-RunningGameProcesses $game)
if ($running.Count -gt 0) {
    throw "Close GTA SA before restoring. Running PID(s): $($running.Id -join ', ')"
}

$transactionsRoot = Assert-ChildPath -Parent $game -Child (Join-Path $game '_installer-transactions')
if (-not (Test-Path -LiteralPath $transactionsRoot -PathType Container)) {
    throw "No installer transactions found in: $transactionsRoot"
}

if ($TransactionId) {
    $transactionRoot = Assert-ChildPath -Parent $transactionsRoot -Child (Join-Path $transactionsRoot $TransactionId)
    $receiptPath = Join-Path $transactionRoot 'receipt.json'
    $receipt = Read-JsonFile $receiptPath
} else {
    $candidate = Get-ChildItem -LiteralPath $transactionsRoot -Directory |
        Sort-Object LastWriteTimeUtc -Descending |
        ForEach-Object {
            $candidateReceiptPath = Join-Path $_.FullName 'receipt.json'
            if (-not (Test-Path -LiteralPath $candidateReceiptPath -PathType Leaf)) { return }
            try {
                $candidateReceipt = Read-JsonFile $candidateReceiptPath
                if ($candidateReceipt.state -eq 'completed') {
                    return [pscustomobject]@{ Root = $_.FullName; Path = $candidateReceiptPath; Receipt = $candidateReceipt }
                }
            } catch {
                Write-Warning "Ignoring unreadable transaction receipt: $candidateReceiptPath"
            }
        } |
        Select-Object -First 1
    if (-not $candidate) { throw 'No completed installation transaction is available to restore.' }
    $transactionRoot = $candidate.Root
    $receiptPath = $candidate.Path
    $receipt = $candidate.Receipt
}

if ($receipt.schemaVersion -ne 1) { throw 'Unsupported transaction receipt schema.' }
if ([System.IO.Path]::GetFullPath($receipt.gamePath) -ne $game) {
    throw "Transaction belongs to a different game directory: $($receipt.gamePath)"
}
if ($receipt.state -eq 'restored') {
    return [pscustomobject]@{ TransactionId = $receipt.transactionId; State = 'already-restored'; ReceiptPath = $receiptPath }
}
if ($receipt.state -notin @('completed', 'restore-failed')) {
    throw "Transaction '$($receipt.transactionId)' cannot be restored from state '$($receipt.state)'."
}

$drift = [System.Collections.Generic.List[string]]::new()
foreach ($entry in $receipt.files) {
    $destination = Assert-ChildPath -Parent $game -Child (Join-Path $game $entry.relativePath)
    if ($entry.existedBefore) {
        if ([string]::IsNullOrWhiteSpace($entry.backupRelativePath)) {
            throw "Receipt has no backup path for: $($entry.relativePath)"
        }
        $backup = Assert-ChildPath -Parent $transactionRoot -Child (Join-Path $transactionRoot $entry.backupRelativePath)
        if (-not (Test-Path -LiteralPath $backup -PathType Leaf)) { throw "Backup is missing: $($entry.relativePath)" }
        if ((Get-FileSha256 -Path $backup) -ne $entry.originalSha256) { throw "Backup hash mismatch: $($entry.relativePath)" }
    }

    if ($entry.installedSha256) {
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) {
            $drift.Add("missing:$($entry.relativePath)")
        } elseif ((Get-FileSha256 -Path $destination) -ne $entry.installedSha256) {
            $drift.Add("modified:$($entry.relativePath)")
        }
    } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
        $drift.Add("unexpected:$($entry.relativePath)")
    }
}

if ($drift.Count -gt 0 -and -not $Force) {
    throw "Installed files changed after installation. Refusing to overwrite them: $($drift -join ', '). Re-run with -Force only after reviewing those files."
}

$plan = [pscustomobject]@{
    GamePath = $game
    TransactionId = $receipt.transactionId
    ManagedFiles = @($receipt.files).Count
    Drift = @($drift)
}
if (-not $PSCmdlet.ShouldProcess($game, "Restore transaction '$($receipt.transactionId)'")) { return $plan }

$receipt.state = 'restoring'
Write-JsonFile -Path $receiptPath -Value $receipt -Depth 12
try {
    for ($index = $receipt.files.Count - 1; $index -ge 0; $index--) {
        $entry = $receipt.files[$index]
        $destination = Assert-ChildPath -Parent $game -Child (Join-Path $game $entry.relativePath)
        if ($entry.existedBefore) {
            $backup = Assert-ChildPath -Parent $transactionRoot -Child (Join-Path $transactionRoot $entry.backupRelativePath)
            Copy-FileAtomically -Source $backup -Destination $destination
            if ((Get-FileSha256 -Path $destination) -ne $entry.originalSha256) {
                throw "Restore verification failed: $($entry.relativePath)"
            }
        } elseif (Test-Path -LiteralPath $destination -PathType Leaf) {
            Remove-Item -LiteralPath $destination -Force
        }
    }
    $receipt.state = 'restored'
    $receipt.restoredAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    $receipt.error = $null
    Write-JsonFile -Path $receiptPath -Value $receipt -Depth 12
} catch {
    $receipt.state = 'restore-failed'
    $receipt.error = $_.Exception.Message
    Write-JsonFile -Path $receiptPath -Value $receipt -Depth 12
    throw
}

[pscustomobject]@{
    GamePath = $game
    TransactionId = $receipt.transactionId
    RestoredFiles = @($receipt.files).Count
    DriftOverridden = @($drift).Count
    ReceiptPath = $receiptPath
}
