function New-LabRunId {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $timestamp = [DateTime]::UtcNow.ToString(
        'yyyyMMddTHHmmssZ',
        [Globalization.CultureInfo]::InvariantCulture
    )
    $suffix = [Guid]::NewGuid().ToString('N').Substring(0, 8).ToUpperInvariant()
    return "LAB-$timestamp-$suffix"
}

function Test-LabRunId {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter()]
        [switch] $ThrowOnInvalid
    )

    $isValid = $LabRunId -match '^LAB-[0-9]{8}T[0-9]{6}Z-[0-9A-F]{8}$'
    if (-not $isValid -and $ThrowOnInvalid) {
        throw 'LabRunId does not match the LAB-001 run identifier contract.'
    }
    return $isValid
}

function Get-LabRunDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    Test-LabRunId -LabRunId $LabRunId -ThrowOnInvalid | Out-Null
    $normalizedRoot = [System.IO.Path]::GetFullPath($StateRoot)
    return [System.IO.Path]::GetFullPath(
        (Join-Path $normalizedRoot $LabRunId)
    )
}

function Write-LabJsonFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [object] $InputObject
    )

    $parentPath = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $parentPath -PathType Container)) {
        New-Item -ItemType Directory -Path $parentPath -ErrorAction Stop | Out-Null
    }

    $temporaryPath = Join-Path $parentPath (
        '.tmp-' + [Guid]::NewGuid().ToString('N') + '.json'
    )
    $json = $InputObject | ConvertTo-Json -Depth 100
    $encoding = [System.Text.UTF8Encoding]::new($false)
    try {
        [System.IO.File]::WriteAllText($temporaryPath, $json + "`n", $encoding)
        Move-Item -LiteralPath $temporaryPath -Destination $Path -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force
        }
    }
}

function Read-LabJsonFile {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Required LAB-001 state file is missing: $([IO.Path]::GetFileName($Path))."
    }
    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 |
        ConvertFrom-Json -Depth 100
}

function Initialize-LabRunState {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $runDirectory = Get-LabRunDirectory -LabRunId $LabRunId -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $runDirectory -ErrorAction Stop | Out-Null
    }

    $paths = [pscustomobject] @{
        RunDirectory = $runDirectory
        StatePath = (Join-Path $runDirectory 'run-state.json')
        RegistryPath = (Join-Path $runDirectory 'resource-registry.json')
        LogPath = (Join-Path $runDirectory 'events.jsonl')
        LockPath = (Join-Path $runDirectory 'run.lock')
    }
    $initializationLock = Enter-LabStateLock -LockPath $paths.LockPath
    try {
        if (-not (Test-Path -LiteralPath $paths.StatePath -PathType Leaf)) {
            $now = [DateTime]::UtcNow.ToString('o')
            Write-LabJsonFile -Path $paths.StatePath -InputObject ([ordered] @{
                    SchemaVersion = '1.0'
                    DataClassification = 'LOCAL_RUNTIME_STATE'
                    LabRunId = $LabRunId
                    LifecycleStatus = 'INITIALIZED'
                    CreatedAtUtc = $now
                    LastUpdatedAtUtc = $now
                    PreflightInvocationCount = 0
                })
        }

        if (-not (Test-Path -LiteralPath $paths.RegistryPath -PathType Leaf)) {
            Write-LabJsonFile -Path $paths.RegistryPath -InputObject ([ordered] @{
                    SchemaVersion = '1.0'
                    DataClassification = 'LOCAL_RUNTIME_STATE'
                    LabRunId = $LabRunId
                    Resources = @()
                })
        }
    }
    finally {
        $initializationLock.Dispose()
    }
    return $paths
}

function Enter-LabStateLock {
    [CmdletBinding()]
    [OutputType([System.IO.FileStream])]
    param(
        [Parameter(Mandatory)]
        [string] $LockPath
    )

    try {
        return [System.IO.File]::Open(
            $LockPath,
            [System.IO.FileMode]::OpenOrCreate,
            [System.IO.FileAccess]::ReadWrite,
            [System.IO.FileShare]::None
        )
    }
    catch [System.IO.IOException] {
        throw 'LAB-001 state is locked by another process.'
    }
}

function Write-LabEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $LogPath,

        [Parameter(Mandatory)]
        [ValidateSet('DEBUG', 'INFO', 'WARNING', 'ERROR')]
        [string] $Level,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z][A-Z0-9_]{2,63}$')]
        [string] $EventCode,

        [Parameter()]
        [hashtable] $Properties = @{}
    )

    $safeProperties = [ordered] @{}
    foreach ($key in @($Properties.Keys | Sort-Object)) {
        if ([string] $key -match '(?i)secret|password|credential|token|key') {
            $safeProperties[[string] $key] = '[REDACTED]'
        }
        else {
            $safeProperties[[string] $key] = $Properties[$key]
        }
    }

    $entry = [ordered] @{
        TimestampUtc = [DateTime]::UtcNow.ToString('o')
        Level = $Level
        EventCode = $EventCode
        Properties = $safeProperties
    }
    $line = $entry | ConvertTo-Json -Depth 20 -Compress
    [System.IO.File]::AppendAllText(
        $LogPath,
        $line + [Environment]::NewLine,
        [System.Text.UTF8Encoding]::new($false)
    )
}

function Test-LabPathWithinRoot {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [string] $Root
    )

    $comparison = if ($IsWindows) {
        [System.StringComparison]::OrdinalIgnoreCase
    }
    else {
        [System.StringComparison]::Ordinal
    }
    $normalizedRoot = [System.IO.Path]::GetFullPath($Root).TrimEnd(
        [System.IO.Path]::DirectorySeparatorChar
    ) + [System.IO.Path]::DirectorySeparatorChar
    $normalizedPath = [System.IO.Path]::GetFullPath($Path)
    return $normalizedPath.StartsWith($normalizedRoot, $comparison)
}

function Register-LabResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [ValidateSet('LOCAL_FILESYSTEM', 'DOCKER')]
        [string] $Provider,

        [Parameter(Mandatory)]
        [ValidateSet('FILE', 'DIRECTORY', 'CONTAINER', 'NETWORK', 'VOLUME')]
        [string] $ResourceType,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z0-9][A-Z0-9_-]{2,127}$')]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [string] $ExactLocator,

        [Parameter()]
        [string] $BoundaryLocator,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    foreach ($locator in @($ExactLocator, $BoundaryLocator)) {
        if (
            -not [string]::IsNullOrWhiteSpace($locator) -and
            [Management.Automation.WildcardPattern]::ContainsWildcardCharacters(
                $locator
            )
        ) {
            throw 'Cleanup locators must not contain wildcard characters.'
        }
    }

    $paths = Initialize-LabRunState -LabRunId $LabRunId -StateRoot $StateRoot
    $stateLock = Enter-LabStateLock -LockPath $paths.LockPath
    try {
        $storedLocator = $ExactLocator
        $storedBoundary = ''
        if ($Provider -eq 'LOCAL_FILESYSTEM') {
            if ($ResourceType -notin @('FILE', 'DIRECTORY')) {
                throw 'LOCAL_FILESYSTEM supports only FILE and DIRECTORY resources.'
            }
            $storedLocator = [IO.Path]::GetFullPath($ExactLocator)
            $storedBoundary = if ([string]::IsNullOrWhiteSpace($BoundaryLocator)) {
                $paths.RunDirectory
            }
            else {
                [IO.Path]::GetFullPath($BoundaryLocator)
            }
            if (
                -not (Test-LabPathWithinRoot `
                        -Path $storedLocator `
                        -Root $storedBoundary)
            ) {
                throw 'LOCAL_FILESYSTEM resources must be inside their cleanup boundary.'
            }
            if (
                $ResourceType -eq 'DIRECTORY' -and
                [IO.Path]::GetFileName(
                    $storedLocator.TrimEnd(
                        [IO.Path]::DirectorySeparatorChar,
                        [IO.Path]::AltDirectorySeparatorChar
                    )
                ) -ne $LabRunId
            ) {
                throw 'Registered cleanup directories must use the exact LabRunId leaf.'
            }
        }
        elseif ($Provider -eq 'DOCKER') {
            if ($ResourceType -in @('CONTAINER', 'NETWORK')) {
                if ($ExactLocator -notmatch '^[a-f0-9]{64}$') {
                    throw 'Docker container and network locators require a full object ID.'
                }
            }
            elseif ($ResourceType -eq 'VOLUME') {
                if ($ExactLocator -notmatch '^[a-z0-9][a-z0-9_.-]{0,127}$') {
                    throw 'Docker volume locators require an exact normalized name.'
                }
            }
            else {
                throw 'DOCKER supports only CONTAINER, NETWORK, and VOLUME resources.'
            }
        }

        $registry = Read-LabJsonFile -Path $paths.RegistryPath
        $resources = @($registry.Resources)
        if (@($resources | Where-Object { $_.ResourceId -eq $ResourceId }).Count -gt 0) {
            throw 'ResourceId is already registered for this run.'
        }

        $resources += [pscustomobject] @{
            OwnerRunId = $LabRunId
            Provider = $Provider
            ResourceType = $ResourceType
            ResourceId = $ResourceId
            ExactLocator = $storedLocator
            BoundaryLocator = $storedBoundary
            RegisteredAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        Write-LabJsonFile -Path $paths.RegistryPath -InputObject ([ordered] @{
                SchemaVersion = '1.0'
                DataClassification = 'LOCAL_RUNTIME_STATE'
                LabRunId = $LabRunId
                Resources = $resources
            })
    }
    finally {
        $stateLock.Dispose()
    }
}

function Set-LabRunState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $StatePath,

        [Parameter(Mandatory)]
        [hashtable] $Changes
    )

    $state = Read-LabJsonFile -Path $StatePath
    $updated = [ordered] @{}
    foreach ($property in $state.PSObject.Properties) {
        $updated[$property.Name] = $property.Value
    }
    foreach ($key in $Changes.Keys) {
        $updated[$key] = $Changes[$key]
    }
    $updated.LastUpdatedAtUtc = [DateTime]::UtcNow.ToString('o')
    Write-LabJsonFile -Path $StatePath -InputObject $updated
}
