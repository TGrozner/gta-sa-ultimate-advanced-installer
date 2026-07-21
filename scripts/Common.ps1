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

function Write-JsonFile {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$Value,
        [int]$Depth = 12
    )

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $directory = Split-Path -Parent $fullPath
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($fullPath) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        $json = $Value | ConvertTo-Json -Depth $Depth
        [System.IO.File]::WriteAllText($temporary, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
        Move-Item -LiteralPath $temporary -Destination $fullPath -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-FileSha256 {
    param([Parameter(Mandatory)][string]$Path)

    return (Get-FileHash -Algorithm SHA256 -LiteralPath $Path).Hash.ToUpperInvariant()
}

function Copy-FileAtomically {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )

    $directory = Split-Path -Parent $Destination
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $temporary = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Destination) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        Copy-Item -LiteralPath $Source -Destination $temporary -Force
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
}

function Get-RelativePath {
    param(
        [Parameter(Mandatory)][string]$BasePath,
        [Parameter(Mandatory)][string]$Path
    )

    $baseFull = [System.IO.Path]::GetFullPath($BasePath)
    while ($baseFull.EndsWith('\') -or $baseFull.EndsWith('/')) {
        $baseFull = $baseFull.Substring(0, $baseFull.Length - 1)
    }
    $baseFull += [System.IO.Path]::DirectorySeparatorChar
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    $baseUri = [Uri]$baseFull
    $pathUri = [Uri]$pathFull
    $relative = [Uri]::UnescapeDataString($baseUri.MakeRelativeUri($pathUri).ToString())
    return $relative.Replace('/', [System.IO.Path]::DirectorySeparatorChar)
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

    $parentBase = [System.IO.Path]::GetFullPath($Parent)
    while ($parentBase.EndsWith('\') -or $parentBase.EndsWith('/')) {
        $parentBase = $parentBase.Substring(0, $parentBase.Length - 1)
    }
    $parentFull = $parentBase + [System.IO.Path]::DirectorySeparatorChar
    $childFull = [System.IO.Path]::GetFullPath($Child)
    if (-not $childFull.StartsWith($parentFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Path escapes its allowed root: $childFull"
    }

    $relative = Get-RelativePath -BasePath $parentBase -Path $childFull
    $current = $parentBase
    foreach ($segment in $relative -split '[\\/]') {
        if ([string]::IsNullOrWhiteSpace($segment)) { continue }
        $current = Join-Path $current $segment
        if (Test-Path -LiteralPath $current) {
            $item = Get-Item -LiteralPath $current -Force
            if (($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw "Reparse points are not allowed inside managed paths: $current"
            }
        }
    }

    return $childFull
}

function Get-FileInventory {
    param([Parameter(Mandatory)][string]$Root)

    $rootFull = [System.IO.Path]::GetFullPath($Root)
    if (-not (Test-Path -LiteralPath $rootFull -PathType Container)) { return @() }

    return @(
        Get-ChildItem -LiteralPath $rootFull -Recurse -File | Sort-Object FullName | ForEach-Object {
            $relative = Get-RelativePath -BasePath $rootFull -Path $_.FullName
            [pscustomobject]@{
                path = $relative.Replace('\', '/')
                length = $_.Length
                sha256 = Get-FileSha256 -Path $_.FullName
            }
        }
    )
}

function Get-TextEncoding {
    param([Parameter(Mandatory)][string]$Path)

    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0x00 -and $bytes[1] -eq 0x00 -and $bytes[2] -eq 0xFE -and $bytes[3] -eq 0xFF) {
        return [System.Text.UTF32Encoding]::new($true, $true)
    }
    if ($bytes.Length -ge 4 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE -and $bytes[2] -eq 0x00 -and $bytes[3] -eq 0x00) {
        return [System.Text.UTF32Encoding]::new($false, $true)
    }
    if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        return [System.Text.UTF8Encoding]::new($true)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
        return [System.Text.UnicodeEncoding]::new($true, $true)
    }
    if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
        return [System.Text.UnicodeEncoding]::new($false, $true)
    }

    # GTA-era INI files are commonly ANSI. Preserve that convention unless a BOM proves otherwise.
    return [System.Text.Encoding]::Default
}

function Get-IniValue {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Section,
        [Parameter(Mandatory)][string]$Key
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }

    $currentSection = ''
    $encoding = Get-TextEncoding -Path $Path
    foreach ($line in [System.IO.File]::ReadAllLines($Path, $encoding)) {
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

    $encoding = Get-TextEncoding -Path $Path
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.AddRange([string[]][System.IO.File]::ReadAllLines($Path, $encoding))
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

    $directory = Split-Path -Parent ([System.IO.Path]::GetFullPath($Path))
    $temporary = Join-Path $directory ('.' + [System.IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid().ToString('N') + '.tmp')
    try {
        [System.IO.File]::WriteAllLines($temporary, $lines, $encoding)
        Move-Item -LiteralPath $temporary -Destination $Path -Force
    } finally {
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            Remove-Item -LiteralPath $temporary -Force
        }
    }
    return $true
}

function Get-RunningGameProcesses {
    param([Parameter(Mandatory)][string]$GamePath)

    $expected = [System.IO.Path]::GetFullPath((Join-Path $GamePath 'gta_sa.exe'))
    return @(Get-Process gta_sa -ErrorAction SilentlyContinue | Where-Object {
        try {
            return [System.IO.Path]::GetFullPath($_.Path) -eq $expected
        } catch {
            return $false
        }
    })
}
