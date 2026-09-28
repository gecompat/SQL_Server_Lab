<#
.SYNOPSIS
    Lokale Einstellungen fuer interaktive Lab-Aktionen.
#>

function Get-LabProjectPreferencesPath {
    [CmdletBinding()]
    param()

    $configuredDataRoot = @(
        [string]$env:SQL_SERVER_LAB_DATA_ROOT,
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
    ) | Where-Object { $_ } | Select-Object -First 1
    if ($configuredDataRoot -and (Test-Path -LiteralPath $configuredDataRoot -PathType Container)) {
        return Join-Path (Join-Path $configuredDataRoot 'Catalog') 'preferences.json'
    }
    if (-not $script:ModuleRoot) { return $null }
    return Join-Path (Join-Path $script:ModuleRoot '.local') 'preferences.json'
}

function Get-LabProjectMediaRootDefault {
    [CmdletBinding()]
    param()

    $mediaRoot = Get-LabProjectPreferenceValue -Name mediaRoot
    if ($mediaRoot) {
        if ($mediaRoot -and (Test-Path -LiteralPath $mediaRoot -PathType Container)) {
            return (Resolve-Path -LiteralPath $mediaRoot -ErrorAction Stop).Path
        }
    }
    return $null
}

function Get-LabProjectPreferenceValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name)

    $snapshot = Get-LabPreferencesSnapshot
    return [string]$snapshot.Document[$Name]
}

function Set-LabProjectPreferenceValue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Value)

    Set-LabPreferencesEntry -Name $Name -Value $Value
}

function Get-LabPreferencesAuthority {
    [CmdletBinding()]
    param([string]$Path)
    if (-not $Path) { $Path = Get-LabProjectPreferencesPath }
    if (-not $path) { throw 'PREFERENCES_AUTHORITY_REQUIRED' }
    $path = [IO.Path]::GetFullPath($path)
    # Reject aliases through links: all cooperating writers lock the same physical authority.
    $cursor = $path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'PREFERENCES_REPARSE_POINT' }
        }
        $parent = [IO.Path]::GetDirectoryName($cursor)
        if ($parent -eq $cursor) { break }
        $cursor = $parent
    }
    $tail = [Collections.Generic.List[string]]::new()
    $existing = $path
    while (-not (Test-Path -LiteralPath $existing)) {
        $tail.Insert(0, [IO.Path]::GetFileName($existing))
        $existing = [IO.Path]::GetDirectoryName($existing)
    }
    $path = (Get-Item -LiteralPath $existing -Force -ErrorAction Stop).FullName
    foreach ($part in $tail) { $path = Join-Path $path $part }
    return $path
}

function Get-LabPreferencesDigest {
    param([Parameter(Mandatory)][string]$Text)
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Text)))
}

function Get-LabPreferencesSnapshot {
    [CmdletBinding()]
    param([string]$Path)
    $path = Get-LabPreferencesAuthority -Path $Path
    $identity = if ($IsWindows) { $path.ToUpperInvariant() } else { $path }
    $text = $null
    $document = [ordered]@{ schemaVersion = 1 }
    if (Test-Path -LiteralPath $path) {
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'PREFERENCES_INVALID' }
        try {
            $text = [IO.File]::ReadAllText($path)
            $document = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 30 -ErrorAction Stop
            if ($document -isnot [Collections.IDictionary]) { throw 'invalid' }
        }
        catch { throw 'PREFERENCES_INVALID' }
    }
    $authorityEvidence = $identity
    $parent = Split-Path -Parent $path
    if ((Split-Path -Leaf $parent) -eq 'Catalog') {
        $dataRoot = Split-Path -Parent $parent
        foreach ($authorityFile in @((Join-Path $dataRoot '.sql-server-lab-root.json'), (Join-Path $parent 'storage-locations.json'))) {
            $authorityEvidence += "`n" + $(if (Test-Path -LiteralPath $authorityFile -PathType Leaf) { [IO.File]::ReadAllText($authorityFile) } else { 'MISSING' })
        }
    }
    [pscustomobject]@{ Path=$path; Document=$document; Exists=($null -ne $text); AuthorityKey=(Get-LabPreferencesDigest -Text $authorityEvidence)
        Key=(Get-LabPreferencesDigest -Text ($authorityEvidence + "`n" + $(if ($null -eq $text) { 'MISSING' } else { 'PRESENT:' + $text }))) }
}

function Invoke-WithLabPreferencesLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][Alias('Path')][string[]]$PreferencePath, [Parameter(Mandatory)][scriptblock]$Body)
    $authorities = @($PreferencePath | ForEach-Object {
        $canonical = Get-LabPreferencesAuthority -Path $_
        if ($IsWindows) { $canonical.ToUpperInvariant() } else { $canonical }
    } | Sort-Object -CaseSensitive -Unique)
    $locks = [Collections.Generic.List[object]]::new()
    $deadline = [datetime]::UtcNow.AddSeconds(10)
    try {
        foreach ($authority in $authorities) {
            $preferencesLockName = 'SqlServerLabPreferences_' + (Get-LabPreferencesDigest -Text $authority)
            if ($IsWindows) { $preferencesLockName = 'Global\' + $preferencesLockName }
            $mutex = [Threading.Mutex]::new($false, $preferencesLockName)
            $acquired = $false
            try {
                $remaining = $deadline - [datetime]::UtcNow
                if ($remaining.TotalMilliseconds -le 0) { throw 'PREFERENCES_LOCK_TIMEOUT' }
                try { $acquired = $mutex.WaitOne($remaining) }
                catch [Threading.AbandonedMutexException] { $acquired = $true }
                if (-not $acquired) { throw 'PREFERENCES_LOCK_TIMEOUT' }
                $locks.Add($mutex)
            }
            finally { if (-not $acquired) { $mutex.Dispose() } }
        }
        & $Body
    }
    finally {
        for ($index=$locks.Count-1; $index -ge 0; $index--) { $locks[$index].ReleaseMutex(); $locks[$index].Dispose() }
    }
}

function Set-LabPreferencesEntry {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][object]$Value, [string]$ExpectedKey)
    $snapshot = Get-LabPreferencesSnapshot
    if ($ExpectedKey -and $snapshot.Key -cne $ExpectedKey) { throw 'PREFERENCES_PREVIEW_STALE' }
    Invoke-WithLabPreferencesLock -Path $snapshot.Path -Body {
        # Resolve the selected authority again after waiting; never resurrect a migrated source.
        $current = Get-LabPreferencesSnapshot
        if ($current.Path -cne $snapshot.Path -or $current.AuthorityKey -cne $snapshot.AuthorityKey -or
            ($snapshot.Exists -and -not $current.Exists) -or ($ExpectedKey -and $current.Key -cne $ExpectedKey)) { throw 'PREFERENCES_PREVIEW_STALE' }
        $current.Document[$Name] = $Value
        $current.Document['updatedAt'] = Get-LabTimestamp
        Write-LabArtifactJsonAtomic -Path $current.Path -InputObject $current.Document
    }
}

function Update-LabPreferencesPathReferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$TargetRoot)
    Invoke-WithLabPreferencesLock -Path $Path -Body {
        $current = Get-LabPreferencesSnapshot -Path $Path
        if (-not $current.Exists) { throw 'PREFERENCES_MIGRATION_SOURCE_MISSING' }
        $text = $current.Document | ConvertTo-Json -Depth 30
        $updated = $text.Replace($SourceRoot.Replace('\','\\'), $TargetRoot.Replace('\','\\'), [StringComparison]::OrdinalIgnoreCase)
        $updated = $updated.Replace($SourceRoot, $TargetRoot, [StringComparison]::OrdinalIgnoreCase)
        if ($updated -cne $text) {
            $document = ConvertFrom-Json -InputObject $updated -AsHashtable -Depth 30 -ErrorAction Stop
            Write-LabArtifactJsonAtomic -Path $current.Path -InputObject $document
            return $true
        }
        return $false
    }
}

function Assert-LabPreferencesPreflight {
    [CmdletBinding()]
    param([string]$DataRoot)
    if ($DataRoot) { $null = Get-LabPreferencesSnapshot -Path (Join-Path (Join-Path $DataRoot 'Catalog') 'preferences.json') }
    else { $null = Get-LabPreferencesSnapshot }
}
function Get-LabMediaRootCandidates {
    [CmdletBinding()]
    param()

    $candidates = @(
        @{ Source='ProcessEnvironment'; Path=[string]$env:SQL_SERVER_LAB_MEDIA_ROOT },
        @{ Source='ProjectPreference'; Path=[string](Get-LabProjectPreferenceValue -Name mediaRoot) },
        @{ Source='UserEnvironment'; Path=[string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', 'User') }
    )
    $selected = $false
    foreach ($candidate in $candidates) {
        if (-not $candidate.Path) { continue }
        $resolved = $null
        $status = 'ROOT_NOT_FOUND'
        try { if (Test-Path -LiteralPath $candidate.Path -PathType Container -ErrorAction Stop) { $resolved = (Resolve-Path -LiteralPath $candidate.Path -ErrorAction Stop).Path; $status='READY' } }
        catch { $status = 'ROOT_UNREADABLE' }
        $active = [bool]$resolved -and -not $selected
        if ($active) { $selected = $true }
        [pscustomobject]@{ Source=$candidate.Source; Path=$candidate.Path; ResolvedPath=$resolved;
            Status=$status; Selected=$active }
    }
}

function Get-LabMediaRootDefault {
    [CmdletBinding()]
    param()

    $selected = @(Get-LabMediaRootCandidates | Where-Object Selected | Select-Object -First 1)
    if ($selected.Count) { return [string]$selected[0].ResolvedPath }
    return $null
}

function Set-LabMediaRootDefault {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$MediaRoot,
        [switch]$ProcessEnvironmentOnly
    )

    $resolved = (Resolve-Path -LiteralPath $MediaRoot -ErrorAction Stop).Path
    $volumeRoot = [System.IO.Path]::GetPathRoot($resolved)
    if ($resolved.TrimEnd('\', '/') -eq $volumeRoot.TrimEnd('\', '/')) {
        throw 'MEDIA_ROOT_TOO_BROAD: Bitte den vollstaendigen Media-Root-Ordner angeben, z. B. C:\Lab_Base.'
    }
    if (-not $ProcessEnvironmentOnly) { Assert-LabPreferencesPreflight }
    $env:SQL_SERVER_LAB_MEDIA_ROOT = $resolved
    if (-not $ProcessEnvironmentOnly) {
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_MEDIA_ROOT', $resolved, 'User')
        Set-LabProjectPreferenceValue -Name mediaRoot -Value $resolved
    }
    return $resolved
}

function Get-LabTestDataRootDefault {
    <# Liefert die sichtbare, wiederverwendbare Testdaten-Bibliothek. #>
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_TEST_DATA_ROOT,
        (Get-LabProjectPreferenceValue -Name testDataRoot),
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_TEST_DATA_ROOT', 'User')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate -PathType Container) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }

    $mediaRoot = Get-LabMediaRootDefault
    if ($mediaRoot) { return (Join-Path $mediaRoot 'Testdaten') }
    return $null
}

function Set-LabTestDataRootDefault {
    <# Speichert eine sichtbare Testdaten-Bibliothek außerhalb des Run-State. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$TestDataRoot)

    Assert-LabPreferencesPreflight
    $resolved = [System.IO.Path]::GetFullPath($TestDataRoot)
    if (-not (Test-Path -LiteralPath $resolved -PathType Container)) {
        New-Item -Path $resolved -ItemType Directory -Force | Out-Null
    }
    $resolved = (Resolve-Path -LiteralPath $resolved -ErrorAction Stop).Path
    $env:SQL_SERVER_LAB_TEST_DATA_ROOT = $resolved
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_TEST_DATA_ROOT', $resolved, 'User')
    Set-LabProjectPreferenceValue -Name testDataRoot -Value $resolved
    return $resolved
}

function Get-LabDataRootDefault {
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_DATA_ROOT,
        (Get-LabProjectPreferenceValue -Name dataRoot),
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', 'User')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if ((Test-Path -LiteralPath $candidate -PathType Container) -and (Test-LabDataRootOwnership -DataRoot $candidate)) {
            return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
        }
    }
    return $null
}

function Set-LabTestEnvironmentDiscoveryEnvironment {
    <# Veröffentlicht ausschließlich portable Pfade; die Dateien selbst können Secrets enthalten. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [switch]$ProcessEnvironmentOnly
    )

    $root = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
    $contractPath = Join-Path $root 'Exports/TestUmgebung.json'
    $schemaPath = Join-Path $root 'Exports/TestUmgebung.schema.json'
    $promptPath = Join-Path $root 'Exports/TestUmgebung.prompt.md'
    $variables = [ordered]@{
        SQL_SERVER_LAB_TEST_ENV_FILE = $contractPath
        SQL_SERVER_LAB_TEST_ENV_SCHEMA_FILE = $schemaPath
        SQL_SERVER_LAB_TEST_ENV_PROMPT_FILE = $promptPath
    }
    foreach ($pair in $variables.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($pair.Key, $pair.Value, 'Process')
        if (-not $ProcessEnvironmentOnly) {
            try { [Environment]::SetEnvironmentVariable($pair.Key, $pair.Value, 'User') }
            catch { Write-Verbose "Benutzervariable $($pair.Key) konnte nicht gesetzt werden: $($_.Exception.Message)" }
        }
    }
    return [PSCustomObject]$variables
}

function Set-LabDataRootDefault {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    Assert-LabPreferencesPreflight -DataRoot $DataRoot
    $root = Register-LabDataRoot -DataRoot $DataRoot
    $configuration = Get-LabStorageConfiguration
    $location = @($configuration.LabDataLocations | Where-Object {
        [string]::Equals([string]$_.LabDataRoot, $root, [StringComparison]::OrdinalIgnoreCase)
    } | Select-Object -First 1)
    if ($location.Count -ne 1) { throw 'LAB_STORAGE_DEFAULT_LOCATION_NOT_FOUND' }
    return Set-LabDefaultDataLocation -LocationId ([string]$location[0].LocationId) -Confirm:$false
}

function Get-LabHyperVSwitchDefault {
    <# Liefert den zuletzt bewusst gewählten Hyper-V-Lab-Switch. #>
    [CmdletBinding()]
    param()

    $candidates = @(
        [string]$env:SQL_SERVER_LAB_HYPERV_NETWORK,
        (Get-LabProjectPreferenceValue -Name hyperVSwitch),
        [string][Environment]::GetEnvironmentVariable('SQL_SERVER_LAB_HYPERV_NETWORK', 'User')
    ) | Where-Object { $_ }
    foreach ($candidate in $candidates) {
        if (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) {
            if (Get-VMSwitch -Name $candidate -ErrorAction SilentlyContinue) { return $candidate }
        }
    }
    return $null
}

function Set-LabHyperVSwitchDefault {
    <# Speichert einen vorhandenen Switch als Standard für neue Host-SSMS-fähige Labs. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$SwitchName)

    if (-not (Get-Command Get-VMSwitch -ErrorAction SilentlyContinue) -or -not (Get-VMSwitch -Name $SwitchName -ErrorAction SilentlyContinue)) {
        throw "HYPERV_SWITCH_NOT_FOUND: $SwitchName"
    }
    Assert-LabPreferencesPreflight
    $env:SQL_SERVER_LAB_HYPERV_NETWORK = $SwitchName
    [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_HYPERV_NETWORK', $SwitchName, 'User')
    Set-LabProjectPreferenceValue -Name hyperVSwitch -Value $SwitchName
    return $SwitchName
}
