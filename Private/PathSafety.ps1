<#
.SYNOPSIS
    Pfadsicherheits-Validierung fuer SQL_Server_Lab.
.DESCRIPTION
    Verhindert Mutationen an Systempfaden, Repository-Verzeichnissen,
    fremden Scopes und anderen geschuetzten Orten.
#>

# =============================================================================
# Geschuetzte Pfade
# =============================================================================

function Get-ProtectedPaths {
    <#
    .SYNOPSIS
        Liefert die Liste geschuetzter Pfade fuer das aktuelle Betriebssystem.
    .OUTPUTS
        Array von Objekten mit Path, Description, ExactOnly.
    #>
    [CmdletBinding()]
    param()

    $protected = @()

    if ($IsWindows) {
        $protected += @(
            @{ Path = $env:SystemRoot;                     Description = 'Windows-Systemverzeichnis';        ExactOnly = $false }
            @{ Path = $env:ProgramFiles;                   Description = 'Program Files';                    ExactOnly = $false }
            @{ Path = ${env:ProgramFiles(x86)};            Description = 'Program Files (x86)';              ExactOnly = $false }
            @{ Path = $env:ProgramData;                    Description = 'ProgramData';                      ExactOnly = $false }
            @{ Path = "$env:SystemDrive\Users";            Description = 'Benutzerprofile-Root';             ExactOnly = $true  }
            @{ Path = "$env:SystemDrive\Recovery";         Description = 'Recovery-Partition';                ExactOnly = $false }
            @{ Path = "$env:USERPROFILE\Documents";        Description = 'Eigene Dokumente';                 ExactOnly = $true  }
            @{ Path = "$env:USERPROFILE\Desktop";          Description = 'Desktop';                          ExactOnly = $true  }
        )
    }
    else {
        # Linux/macOS
        $protected += @(
            @{ Path = '/';           Description = 'Root-Dateisystem';    ExactOnly = $true  }
            @{ Path = '/bin';        Description = 'Systembinaries';      ExactOnly = $false }
            @{ Path = '/sbin';       Description = 'Systembinaries';      ExactOnly = $false }
            @{ Path = '/usr';        Description = 'Systemanwendungen';   ExactOnly = $false }
            @{ Path = '/etc';        Description = 'Konfiguration';       ExactOnly = $false }
            @{ Path = '/var';        Description = 'Variable Daten';      ExactOnly = $true  }
            @{ Path = '/tmp';        Description = 'Temporaer';           ExactOnly = $true  }
            @{ Path = '/home';       Description = 'Home-Root';           ExactOnly = $true  }
        )
    }

    return $protected
}

# =============================================================================
# Validierung
# =============================================================================

function Test-PathSafe {
    <#
    .SYNOPSIS
        Prueft ob ein Zielpfad sicher fuer Lab-Mutationen ist.
    .PARAMETER Path
        Der zu pruefende Pfad.
    .PARAMETER RepositoryRoot
        Optionaler Pfad zum Git-Repository (wird ebenfalls geschuetzt).
    .PARAMETER AllowedScopeId
        Optionale ScopeId. Pfade mit fremden Scope-Markern werden abgelehnt.
    .OUTPUTS
        PSCustomObject mit Valid (bool), Reason (string).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Path,

        [string]$RepositoryRoot,

        [string]$AllowedScopeId
    )

    $result = [PSCustomObject]@{ Valid = $true; Reason = '' }

    # Pfad normalisieren
    $resolved = $null
    try {
        # Resolve ohne zu pruefen ob existiert (Test-Path wuerde fehlschlagen bei neuem Pfad)
        $resolved = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        $result.Valid = $false
        $result.Reason = "Pfad konnte nicht aufgeloest werden: $Path"
        return $result
    }

    # Leer oder Root-Drive?
    if ([string]::IsNullOrWhiteSpace($resolved)) {
        $result.Valid = $false
        $result.Reason = "Leerer Pfad"
        return $result
    }

    # Geschuetzte Pfade pruefen
    $protected = Get-ProtectedPaths
    foreach ($entry in $protected) {
        if (-not $entry.Path) { continue }

        $protectedNorm = [System.IO.Path]::GetFullPath($entry.Path)

        if ($entry.ExactOnly) {
            # Nur exakter Match
            if ($resolved -eq $protectedNorm) {
                $result.Valid = $false
                $result.Reason = "Pfad ist geschuetzt: $($entry.Description) ($protectedNorm)"
                return $result
            }
        }
        else {
            # Prefix-Match (alles darunter)
            $prefix = $protectedNorm.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
            if ($resolved.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -or
                $resolved -eq $protectedNorm) {
                $result.Valid = $false
                $result.Reason = "Pfad liegt in geschuetztem Bereich: $($entry.Description) ($protectedNorm)"
                return $result
            }
        }
    }

    # Repository-Schutz
    if ($RepositoryRoot) {
        $repoNorm = [System.IO.Path]::GetFullPath($RepositoryRoot)
        $repoPrefix = $repoNorm.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($resolved.StartsWith($repoPrefix, [StringComparison]::OrdinalIgnoreCase) -or
            $resolved -eq $repoNorm) {
            $result.Valid = $false
            $result.Reason = "Pfad liegt im Repository-Verzeichnis (geschuetzt)"
            return $result
        }
    }

    # Symlink/Junction-Pruefung (nur wenn Pfad existiert)
    if (Test-Path $resolved) {
        $item = Get-Item $resolved -Force -ErrorAction SilentlyContinue
        if ($item -and $item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            $result.Valid = $false
            $result.Reason = "Pfad ist ein Symlink oder Junction (nicht kontrollierbar)"
            return $result
        }
    }

    # Scope-Marker-Pruefung (falls Pfad existiert und ScopeId angegeben)
    if ($AllowedScopeId -and (Test-Path $resolved)) {
        $markerFile = Join-Path $resolved '.sql-server-lab-scope.json'
        if (Test-Path $markerFile) {
            try {
                $marker = Get-Content $markerFile -Raw | ConvertFrom-Json
                if ($marker.scopeId -and $marker.scopeId -ne $AllowedScopeId) {
                    $result.Valid = $false
                    $result.Reason = "Pfad gehoert zu fremdem Scope: $($marker.scopeId)"
                    return $result
                }
            }
            catch {
                $result.Valid = $false
                $result.Reason = "Scope-Marker vorhanden aber nicht lesbar"
                return $result
            }
        }
    }

    return $result
}

function Assert-PathSafe {
    <#
    .SYNOPSIS
        Wie Test-PathSafe, wirft aber bei unsicherem Pfad eine Exception.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$RepositoryRoot,
        [string]$AllowedScopeId
    )

    $check = Test-PathSafe -Path $Path -RepositoryRoot $RepositoryRoot -AllowedScopeId $AllowedScopeId
    if (-not $check.Valid) {
        throw "PFAD_UNSICHER: $($check.Reason) [Pfad: $Path]"
    }
}

function Write-ScopeMarker {
    <#
    .SYNOPSIS
        Schreibt einen Scope-Marker in ein Verzeichnis (Ownership-Claim).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$RunId
    )

    $marker = @{
        scopeId   = $ScopeId
        runId     = $RunId
        createdAt = Get-LabTimestamp
        owner     = $env:USERNAME ?? $env:USER ?? 'unknown'
    }

    $markerPath = Join-Path $Path '.sql-server-lab-scope.json'
    $marker | ConvertTo-Json -Depth 5 | Set-Content -Path $markerPath -Encoding utf8
}
