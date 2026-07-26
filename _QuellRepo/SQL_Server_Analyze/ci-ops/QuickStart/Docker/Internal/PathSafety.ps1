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
    if ($script:IsWindowsHost -and $expanded.StartsWith('\\', [StringComparison]::Ordinal)) {
        throw 'UNC- und Netzwerkpfade werden für diese lokale Testumgebung nicht unterstützt.'
    }

    $fullPath = [IO.Path]::GetFullPath($expanded)
    $root = [IO.Path]::GetPathRoot($fullPath)
    if (-not $fullPath.Equals($root, $script:PathComparison)) {
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
    if ($candidatePath.Equals($parentPath, $script:PathComparison)) {
        return $true
    }
    $prefix = $parentPath.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    return $candidatePath.StartsWith($prefix, $script:PathComparison)
}

function Get-ProtectedPathRules {
    $rules = [Collections.Generic.List[object]]::new()

    if ($script:IsWindowsHost) {
        foreach ($drive in @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue)) {
            if (-not [string]::IsNullOrWhiteSpace($drive.Root)) {
                $rules.Add([pscustomobject]@{ Path = $drive.Root; IncludeChildren = $false; Reason = 'Laufwerkswurzel' })
            }
        }

        foreach ($entry in @(
                @{ Value = $env:SystemRoot; Reason = 'Windows-Systemverzeichnis' },
                @{ Value = $env:ProgramFiles; Reason = 'Program Files' },
                @{ Value = ${env:ProgramFiles(x86)}; Reason = 'Program Files (x86)' },
                @{ Value = $env:ProgramData; Reason = 'ProgramData' },
                @{ Value = $env:USERPROFILE; Reason = 'Benutzerprofilwurzel'; ExactOnly = $true },
                @{ Value = $script:RepositoryRoot; Reason = 'Repository' },
                @{ Value = $script:QuickStartRoot; Reason = 'QuickStart-Quellverzeichnis' }
            )) {
            if (-not [string]::IsNullOrWhiteSpace([string] $entry.Value)) {
                $includeChildren = -not ($entry.ContainsKey('ExactOnly') -and [bool] $entry.ExactOnly)
                $rules.Add([pscustomobject]@{ Path = [string] $entry.Value; IncludeChildren = $includeChildren; Reason = [string] $entry.Reason })
            }
        }
    }
    else {
        $rules.Add([pscustomobject]@{ Path = '/'; IncludeChildren = $false; Reason = 'Dateisystemwurzel' })
        foreach ($path in @('/bin', '/boot', '/dev', '/etc', '/lib', '/lib64', '/opt', '/proc', '/run', '/sbin', '/sys', '/usr', '/var')) {
            $rules.Add([pscustomobject]@{ Path = $path; IncludeChildren = $true; Reason = 'geschützter Systempfad' })
        }
        foreach ($path in @('/home', '/root')) {
            $rules.Add([pscustomobject]@{ Path = $path; IncludeChildren = $false; Reason = 'Benutzerwurzel' })
        }
        $rules.Add([pscustomobject]@{ Path = $script:RepositoryRoot; IncludeChildren = $true; Reason = 'Repository' })
        $rules.Add([pscustomobject]@{ Path = $script:QuickStartRoot; IncludeChildren = $true; Reason = 'QuickStart-Quellverzeichnis' })
    }

    return $rules.ToArray()
}

function Assert-NoReparsePointInExistingPath {
    param([Parameter(Mandatory)][string] $Path)

    $current = $Path
    while (-not (Test-Path -LiteralPath $current)) {
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }

    while (-not [string]::IsNullOrWhiteSpace($current)) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw "Der Pfad '$Path' führt über den Reparse-Point '$current'. Junctions und symbolische Links sind für Lab-Wurzeln nicht zulässig."
        }
        $parent = Split-Path -Parent $current
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $current) {
            break
        }
        $current = $parent
    }
}

function Assert-SafeEmptyRoot {
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Purpose
    )

    $canonical = Get-CanonicalPath -Path $Path
    foreach ($rule in @(Get-ProtectedPathRules)) {
        $protected = Get-CanonicalPath -Path $rule.Path
        $blocked = if ($rule.IncludeChildren) {
            Test-PathEqualsOrBelow -Candidate $canonical -Parent $protected
        }
        else {
            $canonical.Equals($protected, $script:PathComparison)
        }
        if ($blocked) {
            throw "Der Zielpfad '$canonical' ist als $($rule.Reason) geschützt. Bitte einen dedizierten leeren Lab-Pfad wählen."
        }
    }

    if ($script:IsWindowsHost) {
        $driveRoot = [IO.Path]::GetPathRoot($canonical)
        $driveInfo = [IO.DriveInfo]::new($driveRoot)
        if ($driveInfo.DriveType -ne [IO.DriveType]::Fixed) {
            throw "Der Pfad '$canonical' liegt nicht auf einem lokalen festen Laufwerk."
        }
    }

    Assert-NoReparsePointInExistingPath -Path $canonical

    if (Test-Path -LiteralPath $canonical -PathType Leaf) {
        throw "Der $Purpose-Pfad '$canonical' ist eine Datei."
    }
    if (Test-Path -LiteralPath $canonical -PathType Container) {
        $content = @(Get-ChildItem -LiteralPath $canonical -Force -ErrorAction Stop)
        if ($content.Count -gt 0) {
            throw "Der $Purpose-Pfad '$canonical' ist nicht leer. Es wird nichts überschrieben."
        }
    }
    return $canonical
}

function Assert-RootsDoNotOverlap {
    param([Parameter(Mandatory)][string[]] $Paths)

    for ($i = 0; $i -lt $Paths.Count; $i++) {
        for ($j = $i + 1; $j -lt $Paths.Count; $j++) {
            if (
                (Test-PathEqualsOrBelow -Candidate $Paths[$i] -Parent $Paths[$j]) -or
                (Test-PathEqualsOrBelow -Candidate $Paths[$j] -Parent $Paths[$i])
            ) {
                throw "Die Pfade '$($Paths[$i])' und '$($Paths[$j])' dürfen nicht gleich sein oder ineinander liegen."
            }
        }
    }
}

function Get-DefaultLabRoot {
    if (-not $script:IsWindowsHost) {
        if (-not [string]::IsNullOrWhiteSpace($env:HOME)) {
            return (Join-Path $env:HOME 'sql-server-analyze-quickstart')
        }
        return '/srv/sql-server-analyze-quickstart'
    }

    $systemDrive = [IO.Path]::GetPathRoot($env:SystemRoot)
    $drives = @(Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue | Where-Object {
            $_.Root -match '^[A-Za-z]:\\$' -and $_.Free -gt 20GB
        })
    $selected = $drives |
        Sort-Object @{ Expression = { if ($_.Root -eq $systemDrive) { 1 } else { 0 } } }, @{ Expression = 'Free'; Descending = $true } |
        Select-Object -First 1
    if ($null -eq $selected) {
        return (Join-Path $systemDrive 'SQL_Server_Analyze_QuickStart')
    }
    return (Join-Path $selected.Root 'SQL_Server_Analyze_QuickStart')
}

function Read-PathWithDefault {
    param(
        [Parameter(Mandatory)][string] $Prompt,
        [Parameter(Mandatory)][string] $Default
    )

    $value = (Read-Host "$Prompt [Standard: $Default]").Trim()
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $Default
    }
    return $value
}
