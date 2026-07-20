$gameDirectory = $PSScriptRoot
$watcher = Join-Path $gameDirectory 'Tools\gta-f8-kill-switch.ps1'
$watcherPattern = [regex]::Escape($watcher)

if (-not (Test-Path -LiteralPath $watcher -PathType Leaf)) {
    throw "F8 watcher not installed: $watcher"
}

$watcherRunning = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.Name -in @('pwsh.exe', 'powershell.exe') -and
        $_.CommandLine -match $watcherPattern
    }

if (-not $watcherRunning) {
    $powerShell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $powerShell) { $powerShell = Get-Command powershell.exe -ErrorAction Stop }
    $arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$watcher`""
    Start-Process -FilePath $powerShell.Source -ArgumentList $arguments -WindowStyle Hidden
    Start-Sleep -Milliseconds 600
}

Start-Process -FilePath (Join-Path $gameDirectory 'gta_sa.exe') -WorkingDirectory $gameDirectory
