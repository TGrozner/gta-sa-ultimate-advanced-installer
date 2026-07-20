Set-StrictMode -Version Latest

function Get-RepositoryRoot {
    return [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Read-JsonFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "JSON file not found: $Path"
    }

    return Get-Content -Raw -LiteralPath $Path | ConvertFrom-Json
}

function Resolve-GamePath {
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    if (-not (Test-Path -LiteralPath $fullPath -PathType Container)) {
        throw "Game directory not found: $fullPath"
    }

    $executable = Join-Path $fullPath 'gta_sa.exe'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) {
        throw "gta_sa.exe not found in: $fullPath"
    }

    return $fullPath
}

function Assert-ChildPath {
    param(
        [Parameter(Mandatory)][string]$Parent,
        [Parameter(Mandatory)][string]$Child
    )

    $parentFull = [System.IO.Path]::GetFullPath($Parent).TrimEnd('\') + '\'
    $childFull = [System.IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its allowed root: $childFull"
    }

    return $childFull
}

function Get-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $currentSection = ''
    foreach ($line in [System.IO.File]::ReadAllLines($Path)) {
        if ($line -match '^\s*\[(.+?)\]\s*(?:[;#].*)?$') {
            $currentSection = $Matches[1]
            continue
        }

        if ($currentSection -ieq $Section -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*?)\s*(?:;.*)?$')) {
            return $Matches[1].Trim()
        }
    }

    return $null
}

function Set-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key,
        [Parameter(Mandatory)][string]$Value
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]][System.IO.File]::ReadAllLines($Path))
    $currentSection = ''
    $sectionFound = $false
    $keyFound = $false
    $insertAt = $lines.Count

    for ($index = 0; $index -lt $lines.Count; $index++) {
        $line = $lines[$index]
        if ($line -match '^\s*\[(.+?)\]\s*(?:[;#].*)?$') {
            if ($sectionFound -and -not $keyFound) { $insertAt = $index; break }
            $currentSection = $Matches[1]
            if ($currentSection -ieq $Section) { $sectionFound = $true }
            continue
        }

        if ($currentSection -ieq $Section -and $line -match ('^\s*' + [regex]::Escape($Key) + '\s*=')) {
            $lines[$index] = "$Key = $Value"
            $keyFound = $true
            break
        }
    }

    if (-not $sectionFound) {
        $lines.Add('')
        $lines.Add("[$Section]")
        $lines.Add("$Key = $Value")
    } elseif (-not $keyFound) {
        $lines.Insert($insertAt, "$Key = $Value")
    }

    [System.IO.File]::WriteAllLines($Path, $lines, [System.Text.UTF8Encoding]::new($false))
    return $true
}

function Get-RunningGameProcesses {
    param([Parameter(Mandatory)][string]$GamePath)

    $expected = Join-Path $GamePath 'gta_sa.exe'
    return Get-Process gta_sa -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -eq $expected }
}
