function Get-CanonicalPath {
    param([Parameter(Mandatory)][string] $Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim())
    if ([string]::IsNullOrWhiteSpace($expanded)) {
        throw 'Ein leerer Pfad ist nicht zulässig.'
    }
    if ($expanded -match "['\r\n]") {
        throw 'Lab-Pfade dürfen keine Zeilenumbrüche oder einfachen Anführungszeichen enthalten.'
    }
    if (-not [IO.Path]::IsPathRooted($expanded)) {
        throw "Der Pfad '$expanded' ist nicht absolut."
    }
    if ($expanded.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw 'UNC- und Netzwerkpfade werden für diese lokale Testumgebung nicht unterstützt.'
    }

    $fullPath = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not $fullPath.Equals($root, [StringComparison]::OrdinalIgnoreCase)) {
        $fullPath = $fullPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar)
    }
    return $fullPath
}

function Test-PathEqualsOrBelow {
    param(
        [Parameter(Mandatory)][string] $Candidate,
        [Parameter(Mandatory)][string] $Parent
    )

    $candidatePath = Get-CanonicalPath -Path $Candidate
    $parentPath = Get-CanonicalPath -Path $Parent
    if ($candidatePath.Equals($parentPath, [StringComparison]::OrdinalIgnoreCase)) {
        return $true
    }
    $prefix = $parentPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $candidatePath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)
}

function Get-ProtectedPaths {
    $protected = @()
    foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
        if (-not [string]::IsNullOrWhiteSpace($drive.Root)) {
            $protected += @{ Path = $drive.Root; Reason = 'Laufwerkswurzel'; ExactOnly = $true }
        }
    }
    $protected += @{ Path = $env:SystemRoot; Reason = 'Windows-Systemverzeichnis'; ExactOnly = $false }
    $protected += @{ Path = $env:ProgramFiles; Reason = 'Program Files'; ExactOnly = $false }
    $protected += @{ Path = ${env:ProgramFiles(x86)}; Reason = 'Program Files (x86)'; ExactOnly = $false }
    $protected += @{ Path = $env:ProgramData; Reason = 'ProgramData'; ExactOnly = $false }
    $protected += @{ Path = $env:USERPROFILE; Reason = 'Benutzerprofilwurzel'; ExactOnly = $true }
    $protected += @{ Path = $script:RepositoryRoot; Reason = 'Repository'; ExactOnly = $false }
    $protected += @{ Path = $script:QuickStartRoot; Reason = 'QuickStart-Quellverzeichnis'; ExactOnly = $false }
    return $protected
}

function Assert-SafeTargetPath {
    param([Parameter(Mandatory)][string] $Path)

    $canonical = Get-CanonicalPath -Path $Path

    # Reparse points
    if ((Test-Path -LiteralPath $canonical) -and
        ([IO.File]::GetAttributes($canonical) -band [IO.FileAttributes]::ReparsePoint)) {
        throw "Der Pfad '$canonical' ist ein Reparse Point (Junction/Symlink) und nicht zulässig."
    }

    # Protected paths
    foreach ($rule in @(Get-ProtectedPaths)) {
        if ([string]::IsNullOrWhiteSpace($rule.Path)) { continue }
        $protectedCanonical = Get-CanonicalPath -Path $rule.Path
        if ($rule.ExactOnly) {
            if ($canonical.Equals($protectedCanonical, [StringComparison]::OrdinalIgnoreCase)) {
                throw "Der Pfad '$canonical' ist geschützt ($($rule.Reason))."
            }
        }
        else {
            if (Test-PathEqualsOrBelow -Candidate $canonical -Parent $protectedCanonical) {
                throw "Der Pfad '$canonical' liegt innerhalb von '$protectedCanonical' ($($rule.Reason))."
            }
        }
    }

    # Must be empty or non-existent
    if (Test-Path -LiteralPath $canonical) {
        $children = @(Get-ChildItem -LiteralPath $canonical -Force -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0) {
            throw "Der Pfad '$canonical' existiert und ist nicht leer."
        }
    }
}

function Write-ScopeMarker {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ScopeId
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -Path $Path -ItemType Directory -Force | Out-Null
    }
    $markerPath = Join-Path $Path $script:MarkerFileName
    $marker = @{
        Owner = $script:MarkerOwner
        ScopeId = $ScopeId
        CreatedUtc = (Get-Date).ToUniversalTime().ToString('o')
        HostName = $env:COMPUTERNAME
    } | ConvertTo-Json -Depth 2
    [IO.File]::WriteAllText($markerPath, $marker, [Text.Encoding]::UTF8)
}

function Test-ScopeMarker {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $ScopeId
    )

    $markerPath = Join-Path $Path $script:MarkerFileName
    if (-not (Test-Path -LiteralPath $markerPath)) {
        return $false
    }
    try {
        $marker = Get-Content -LiteralPath $markerPath -Raw -Encoding utf8 | ConvertFrom-Json
        return ($marker.Owner -eq $script:MarkerOwner -and $marker.ScopeId -eq $ScopeId)
    }
    catch {
        return $false
    }
}
