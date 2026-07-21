[CmdletBinding()]
param([string]$GameDirectory = $PSScriptRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$game = [System.IO.Path]::GetFullPath($GameDirectory)
$executable = Join-Path $game 'gta_sa.exe'
$watcher = Join-Path $game 'Tools\gta-f8-kill-switch.ps1'

if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw "gta_sa.exe not found: $executable" }
if (-not (Test-Path -LiteralPath $watcher -PathType Leaf)) { throw "F8 watcher not installed: $watcher" }

$alreadyRunning = @(Get-Process gta_sa -ErrorAction SilentlyContinue | Where-Object {
    try { [System.IO.Path]::GetFullPath($_.Path) -eq $executable } catch { $false }
})
if ($alreadyRunning.Count -gt 0) { throw "This GTA SA installation is already running (PID $($alreadyRunning.Id -join ', '))." }

$gameProcess = Start-Process -FilePath $executable -WorkingDirectory $game -PassThru
$powerShell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
if (-not $powerShell) { $powerShell = Get-Command powershell.exe -ErrorAction Stop }
$arguments = @(
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$watcher`"",
    '-ProcessId', [string]$gameProcess.Id,
    '-ExpectedExecutable', "`"$executable`""
)
try {
    Start-Process -FilePath $powerShell.Source -ArgumentList $arguments -WindowStyle Hidden | Out-Null
} catch {
    if (-not $gameProcess.HasExited) { $gameProcess.Kill() }
    throw
}

[pscustomobject]@{ ProcessId = $gameProcess.Id; Executable = $executable; KillSwitch = 'F8' }
