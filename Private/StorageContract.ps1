<#
.SYNOPSIS
    Versionierter Storage-Contract fuer verwaltete Lab_Data-Wurzeln.
#>

function Get-LabDataRootMarkerPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    return Join-Path ([System.IO.Path]::GetFullPath($DataRoot)) '.sql-server-lab-root.json'
}

function Get-LabDataRootMarker {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $path = Get-LabDataRootMarkerPath -DataRoot $DataRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { return $null }
    try { return Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 8 }
    catch { throw "LAB_DATA_ROOT_MARKER_INVALID: $path - $($_.Exception.Message)" }
}

function Get-LabVolumeIdentity {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $fullPath = [System.IO.Path]::GetFullPath($Path)
    $volumeRoot = [System.IO.Path]::GetPathRoot($fullPath)
    $driveLetter = if ($IsWindows -and $volumeRoot -match '^[A-Za-z]:') { $volumeRoot.Substring(0, 2).ToUpperInvariant() } else { $volumeRoot }
    $volumeId = $volumeRoot
    if ($IsWindows -and $driveLetter -match '^[A-Z]:$' -and (Get-Command Get-Volume -ErrorAction SilentlyContinue)) {
        try {
            $volume = Get-Volume -DriveLetter $driveLetter.Substring(0, 1) -ErrorAction Stop
            if (-not [string]::IsNullOrWhiteSpace([string]$volume.UniqueId)) { $volumeId = [string]$volume.UniqueId }
        }
        catch { }
    }
    if ($IsWindows -and $driveLetter -match '^[A-Z]:$' -and [string]::Equals([string]$volumeId, [string]$volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        $mountvolPath = Join-Path ([Environment]::GetFolderPath('Windows')) 'System32\mountvol.exe'
        if (Test-Path -LiteralPath $mountvolPath -PathType Leaf) {
            try {
                $mountvolOutput = @(& $mountvolPath "$driveLetter\" '/L' 2>$null)
                $volumeName = @($mountvolOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object {
                    $_ -match '^\\\\\?\\Volume\{[0-9A-Fa-f-]{36}\}\\$'
                } | Select-Object -First 1)
                if ($volumeName.Count -eq 1) { $volumeId = [string]$volumeName[0] }
            }
            catch { }
        }
    }
    return [PSCustomObject]@{ VolumeId = $volumeId; DriveLetter = $driveLetter; VolumeRoot = $volumeRoot }
}

function Get-LabStableStorageLocationId {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ControllerId,
        [Parameter(Mandatory)][string]$VolumeId
    )

    $material = "$($ControllerId.Trim().ToLowerInvariant())`n$($VolumeId.Trim().ToLowerInvariant())"
    $hash = [Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material))
    $guidBytes = [byte[]]::new(16)
    [Array]::Copy($hash, $guidBytes, 16)
    $guidBytes[7] = ($guidBytes[7] -band 0x0f) -bor 0x50
    $guidBytes[8] = ($guidBytes[8] -band 0x3f) -bor 0x80
    return [Guid]::new($guidBytes).ToString('D')
}

function Resolve-LabStorageParentPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $candidate = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -match '^[A-Za-z]:$' -or
        -not [IO.Path]::IsPathFullyQualified($candidate)) {
        throw 'LAB_STORAGE_PARENT_NOT_FULLY_QUALIFIED'
    }
    try { $fullPath = [IO.Path]::GetFullPath($candidate) }
    catch { throw "LAB_STORAGE_PARENT_INVALID: $($_.Exception.Message)" }
    $volumeRoot = [IO.Path]::GetPathRoot($fullPath)
    if ([string]::IsNullOrWhiteSpace($volumeRoot)) { throw 'LAB_STORAGE_PARENT_VOLUME_REQUIRED' }
    $parent = if ($fullPath.TrimEnd('\', '/') -eq $volumeRoot.TrimEnd('\', '/')) {
        $volumeRoot
    }
    else {
        $fullPath.TrimEnd('\', '/')
    }
    return [PSCustomObject]@{
        InputPath = $Path
        LabDataParent = $parent
        LabDataRoot = Join-Path $parent 'Lab_Data'
        VolumeRoot = $volumeRoot
    }
}

function Resolve-LabStorageRootPath {
    <# .SYNOPSIS Normalisiert einen frei wählbaren, nicht zu breiten Lab-Datenroot. #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)

    $candidate = $Path.Trim()
    if ([string]::IsNullOrWhiteSpace($candidate) -or
        $candidate -match '^[A-Za-z]:$' -or
        -not [IO.Path]::IsPathFullyQualified($candidate)) {
        throw 'LAB_DATA_ROOT_NOT_FULLY_QUALIFIED'
    }
    try { $root = [IO.Path]::GetFullPath($candidate).TrimEnd('\', '/') }
    catch { throw "LAB_DATA_ROOT_INVALID: $($_.Exception.Message)" }
    $volumeRoot = [IO.Path]::GetPathRoot($root).TrimEnd('\', '/')
    if ([string]::Equals($root, $volumeRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LAB_DATA_ROOT_TOO_BROAD: Ein Laufwerks- oder Dateisystemroot ist nicht zulaessig.'
    }
    return [PSCustomObject]@{
        InputPath = $Path
        LabDataParent = Split-Path -Parent $root
        LabDataRoot = $root
        VolumeRoot = [IO.Path]::GetPathRoot($root)
    }
}

function Get-LabStorageTopology {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        $VolumeIdentity
    )

    if (-not $VolumeIdentity) { $VolumeIdentity = Get-LabVolumeIdentity -Path $Path }
    $backingDeviceIds = [System.Collections.Generic.List[string]]::new()
    $mediaType = 'Unknown'; $busType = 'Unknown'; $healthStatus = 'Unknown'
    $topologyStatus = if ($VolumeIdentity.VolumeId) { 'LogicalOnly' } else { 'Unknown' }
    $freeBytes = [long]0
    try { $freeBytes = [long][IO.DriveInfo]::new([string]$VolumeIdentity.VolumeRoot).AvailableFreeSpace }
    catch { Write-Verbose "Freier Speicher konnte für '$($VolumeIdentity.VolumeRoot)' nicht ermittelt werden: $($_.Exception.Message)" }

    if ($IsWindows -and [string]$VolumeIdentity.DriveLetter -match '^[A-Z]:$' -and
        (Get-Command Get-Partition -ErrorAction SilentlyContinue) -and
        (Get-Command Get-Disk -ErrorAction SilentlyContinue)) {
        try {
            $partition = Get-Partition -DriveLetter ([string]$VolumeIdentity.DriveLetter).Substring(0, 1) -ErrorAction Stop
            $disks = @($partition | Get-Disk -ErrorAction Stop)
            foreach ($disk in $disks) {
                $deviceId = @([string]$disk.UniqueId, [string]$disk.SerialNumber, "disk-number:$([int]$disk.Number)") |
                    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1
                if ($deviceId -and $deviceId -notin $backingDeviceIds) { $backingDeviceIds.Add($deviceId.Trim()) }
            }
            if ($disks.Count -gt 0) {
                $mediaType = (@($disks | ForEach-Object { [string]$_.MediaType } | Where-Object { $_ -and $_ -ne 'Unspecified' } | Sort-Object -Unique) -join ',')
                if (-not $mediaType) { $mediaType = 'Unknown' }
                $busType = (@($disks | ForEach-Object { [string]$_.BusType } | Where-Object { $_ } | Sort-Object -Unique) -join ',')
                if (-not $busType) { $busType = 'Unknown' }
                $healthStatus = (@($disks | ForEach-Object { [string]$_.HealthStatus } | Where-Object { $_ } | Sort-Object -Unique) -join ',')
                if (-not $healthStatus) { $healthStatus = 'Unknown' }
                $unprovenBusTypes = @('Unknown', 'RAID', 'iSCSI', 'File Backed Virtual', 'Storage Spaces', 'Virtual')
                if ($backingDeviceIds.Count -gt 0 -and @($disks | Where-Object { [string]$_.BusType -in $unprovenBusTypes }).Count -eq 0) {
                    $topologyStatus = 'Proven'
                }
            }
        }
        catch { $topologyStatus = 'LogicalOnly' }
    }
    return [PSCustomObject]@{
        BackingDeviceIds = @($backingDeviceIds)
        TopologyStatus = $topologyStatus
        MediaType = $mediaType
        BusType = $busType
        HealthStatus = $healthStatus
        FreeBytes = $freeBytes
    }
}

function New-LabStorageLocationRecord {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Erzeugt ausschließlich einen in-memory Location-Datensatz.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ControllerId,
        [Parameter(Mandatory)][string]$LabDataRoot,
        $ExistingLocation
    )

    $root = [IO.Path]::GetFullPath($LabDataRoot).TrimEnd('\', '/')
    $volume = Get-LabVolumeIdentity -Path $root
    $topology = Get-LabStorageTopology -Path $root -VolumeIdentity $volume
    $locationId = if ($ExistingLocation -and [string]$ExistingLocation.LocationId) {
        [string]$ExistingLocation.LocationId
    }
    else {
        Get-LabStableStorageLocationId -ControllerId $ControllerId -VolumeId ([string]$volume.VolumeId)
    }
    return [PSCustomObject]@{
        LocationId = $locationId
        DisplayName = if ($ExistingLocation -and [string]$ExistingLocation.DisplayName) { [string]$ExistingLocation.DisplayName } elseif ($volume.DriveLetter) { "Storage $($volume.DriveLetter)" } else { "Storage $locationId" }
        Selectors = @($(if ($ExistingLocation) { @($ExistingLocation.Selectors) } else { @() }) | ForEach-Object { [string]$_ } | Where-Object { $_ } | Sort-Object -Unique)
        ControllerId = $ControllerId
        VolumeId = [string]$volume.VolumeId
        DriveLetter = [string]$volume.DriveLetter
        LabDataParent = Split-Path -Parent $root
        LabDataRoot = $root
        BackingDeviceIds = @($topology.BackingDeviceIds)
        TopologyStatus = [string]$topology.TopologyStatus
        MediaType = [string]$topology.MediaType
        BusType = [string]$topology.BusType
        HealthStatus = [string]$topology.HealthStatus
        FreeBytes = [long]$topology.FreeBytes
    }
}

function Initialize-LabManagedDataRoot {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$ControllerId
    )

    $root = [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
    if ($script:ModuleRoot) {
        $repositoryRoot = [System.IO.Path]::GetFullPath($script:ModuleRoot).TrimEnd('\', '/')
        $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
        if ($root.StartsWith($repositoryRoot + [System.IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'LAB_DATA_ROOT_INSIDE_REPOSITORY'
        }
    }
    $existingMarker = Get-LabDataRootMarker -DataRoot $root
    if ($existingMarker) {
        if ([string]$existingMarker.ManagedBy -ne 'SQL_Server_Lab') { throw 'LAB_DATA_ROOT_FOREIGN_OWNER' }
        if ($ControllerId -and [string]$existingMarker.ControllerId -ne $ControllerId) { throw 'LAB_DATA_ROOT_CONTROLLER_MISMATCH' }
        $ControllerId = [string]$existingMarker.ControllerId
    }
    if ([string]::IsNullOrWhiteSpace($ControllerId)) { $ControllerId = [Guid]::NewGuid().ToString('D') }

    $directories = @(
        'Backups/Incoming', 'Backups/Verified', 'Labs', 'Catalog', 'Exports', 'State', 'Temp',
        'HyperV/Runs', 'HyperV/Builds', 'HyperV/Images', 'HyperV/Staging', 'HyperV/Recovery'
    )
    foreach ($path in @($root) + @($directories | ForEach-Object { Join-Path $root $_ })) {
        if (-not (Test-Path -LiteralPath $path -PathType Container) -and $PSCmdlet.ShouldProcess($path, 'Verwaltetes Storage-Verzeichnis erstellen')) {
            New-Item -Path $path -ItemType Directory -Force | Out-Null
        }
    }
    $volume = Get-LabVolumeIdentity -Path $root
    $marker = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.DataRoot/2.0'
        ManagedBy = 'SQL_Server_Lab'
        ControllerId = $ControllerId
        VolumeId = $volume.VolumeId
        CreatedAt = if ($existingMarker -and $existingMarker.CreatedAt) { [string]$existingMarker.CreatedAt } else { Get-LabTimestamp }
        DataRoot = $root
    }
    if ($PSCmdlet.ShouldProcess((Get-LabDataRootMarkerPath -DataRoot $root), 'Data-Root-Marker schreiben')) {
        Write-LabArtifactJsonAtomic -Path (Get-LabDataRootMarkerPath -DataRoot $root) -InputObject $marker
    }
    return $marker
}

function Test-LabDataRootOwnership {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot, [string]$ControllerId)

    $marker = Get-LabDataRootMarker -DataRoot $DataRoot
    if (-not $marker -or [string]$marker.ContractVersion -ne 'SqlServerLab.DataRoot/2.0' -or [string]$marker.ManagedBy -ne 'SQL_Server_Lab') { return $false }
    return (-not $ControllerId -or [string]$marker.ControllerId -eq $ControllerId)
}

function Get-LabStorageConfiguration {
    [CmdletBinding()]
    param([string]$DataRoot)

    if (-not $DataRoot) { $DataRoot = Get-LabDataRootDefault }
    $empty = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.Storage/2.0'; ControllerId = $null
        DefaultLocationId = $null; DefaultDataRoot = $null; LabDataLocations = @()
        LegacyMigrationReceipt = $null
    }
    if (-not $DataRoot) { return $empty }
    $path = Join-Path (Join-Path $DataRoot 'Catalog') 'storage-locations.json'
    $rawConfiguration = $null; $source = 'storage-catalog'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        $marker = Get-LabDataRootMarker -DataRoot $DataRoot
        if (-not $marker) { return $empty }
        $rawConfiguration = [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.Storage/2.0'; ControllerId = [string]$marker.ControllerId
            DefaultDataRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
            LabDataLocations = @([PSCustomObject]@{ LabDataRoot=[IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/') })
        }
        $source = 'legacy-data-root-marker'
    }
    else {
        try { $rawConfiguration = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20 }
        catch { throw "LAB_STORAGE_CONFIGURATION_INVALID: $($_.Exception.Message)" }
    }

    $controllerId = [string]$rawConfiguration.ControllerId
    if ([string]::IsNullOrWhiteSpace($controllerId)) {
        $marker = Get-LabDataRootMarker -DataRoot $DataRoot
        $controllerId = [string]$marker.ControllerId
    }
    if ([string]::IsNullOrWhiteSpace($controllerId)) { throw 'LAB_STORAGE_CONTROLLER_ID_REQUIRED' }
    $upgraded = $source -ne 'storage-catalog' -or -not $rawConfiguration.DefaultLocationId
    $locations = @(
        foreach ($location in @($rawConfiguration.LabDataLocations)) {
            if (-not $location.LabDataRoot) { continue }
            if (-not $location.LocationId -or -not $location.DisplayName -or
                -not $location.PSObject.Properties['Selectors'] -or -not $location.TopologyStatus -or
                -not $location.PSObject.Properties['BackingDeviceIds']) {
                $upgraded = $true
            }
            New-LabStorageLocationRecord -ControllerId $controllerId `
                -LabDataRoot ([string]$location.LabDataRoot) -ExistingLocation $location
        }
    )
    $defaultRoot = if ($rawConfiguration.DefaultDataRoot) {
        [IO.Path]::GetFullPath([string]$rawConfiguration.DefaultDataRoot).TrimEnd('\', '/')
    }
    elseif ($locations.Count -eq 1) { [string]$locations[0].LabDataRoot }
    else { $null }
    $defaultLocation = if ([string]$rawConfiguration.DefaultLocationId) {
        @($locations | Where-Object { [string]$_.LocationId -eq [string]$rawConfiguration.DefaultLocationId } | Select-Object -First 1)
    }
    elseif ($defaultRoot) {
        @($locations | Where-Object {
            [string]::Equals([string]$_.LabDataRoot, $defaultRoot, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
    }
    else { @() }
    $defaultLocationId = if ($defaultLocation.Count -eq 1) { [string]$defaultLocation[0].LocationId } else { $null }
    $receipt = if ($rawConfiguration.LegacyMigrationReceipt) { $rawConfiguration.LegacyMigrationReceipt } elseif ($upgraded) {
        [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.StorageLegacyMigrationReceipt/1.0'
            Status = 'IN_MEMORY_UPGRADE'
            Source = $source
            DefaultPreserved = [bool]$defaultLocationId
        }
    }
    else { $null }
    return [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.Storage/2.0'
        ControllerId = $controllerId
        DefaultLocationId = $defaultLocationId
        DefaultDataRoot = if ($defaultLocation.Count -eq 1) { [string]$defaultLocation[0].LabDataRoot } else { $defaultRoot }
        LabDataLocations = @($locations | Sort-Object LocationId)
        LegacyMigrationReceipt = $receipt
        UpdatedAt = [string]$rawConfiguration.UpdatedAt
    }
}

function Write-LabStorageConfiguration {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [string[]]$AdditionalRoots = @()
    )

    $receipt = $Configuration.LegacyMigrationReceipt
    if ($receipt -and [string]$receipt.Status -eq 'IN_MEMORY_UPGRADE') {
        $receipt = [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.StorageLegacyMigrationReceipt/1.0'
            Status = 'PERSISTED'
            Source = [string]$receipt.Source
            DefaultPreserved = [bool]$receipt.DefaultPreserved
            PersistedAt = Get-LabTimestamp
        }
    }
    $document = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.Storage/2.0'
        ControllerId = [string]$Configuration.ControllerId
        DefaultLocationId = [string]$Configuration.DefaultLocationId
        DefaultDataRoot = [string]$Configuration.DefaultDataRoot
        LabDataLocations = @($Configuration.LabDataLocations | Sort-Object LocationId)
        LegacyMigrationReceipt = $receipt
        UpdatedAt = Get-LabTimestamp
    }
    $catalogRoots = @(
        @($document.LabDataLocations | ForEach-Object { [string]$_.LabDataRoot })
        @($AdditionalRoots)
    ) | Where-Object { $_ } | Sort-Object -Unique
    foreach ($root in $catalogRoots) {
        if ((Test-Path -LiteralPath $root -PathType Container) -and
            (Test-LabDataRootOwnership -DataRoot $root -ControllerId ([string]$document.ControllerId))) {
            Write-LabArtifactJsonAtomic -Path (Join-Path (Join-Path $root 'Catalog') 'storage-locations.json') -InputObject $document
        }
    }
    return $document
}

function Register-LabDataRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [switch]$SetDefault,
        [switch]$ProcessEnvironmentOnly
    )

    $root = (Resolve-Path -LiteralPath $DataRoot -ErrorAction Stop).Path.TrimEnd('\', '/')
    $currentDefault = Get-LabDataRootDefault
    $configuration = Get-LabStorageConfiguration -DataRoot $currentDefault
    $controllerId = [string]$configuration.ControllerId
    $marker = Get-LabDataRootMarker -DataRoot $root
    if (-not $marker) { throw 'LAB_DATA_ROOT_MARKER_REQUIRED: Root zuerst ueber die Storage-Verwaltung initialisieren.' }
    if ($controllerId -and [string]$marker.ControllerId -ne $controllerId) { throw 'LAB_DATA_ROOT_CONTROLLER_MISMATCH' }
    if (-not $controllerId) { $controllerId = [string]$marker.ControllerId }
    $volume = Get-LabVolumeIdentity -Path $root
    $locations = @($configuration.LabDataLocations)
    $existingVolume = @($locations | Where-Object { [string]$_.VolumeId -eq [string]$volume.VolumeId } | Select-Object -First 1)
    if ($existingVolume.Count -gt 0 -and -not [string]::Equals([string]$existingVolume[0].LabDataRoot, $root, [StringComparison]::OrdinalIgnoreCase)) {
        throw "LAB_DATA_ROOT_MIGRATION_REQUIRED: Volume $($volume.DriveLetter) ist bereits mit $($existingVolume[0].LabDataRoot) registriert. Parent-Wechsel nur ueber eine Storage-Migration."
    }
    $location = New-LabStorageLocationRecord -ControllerId $controllerId -LabDataRoot $root `
        -ExistingLocation $(if ($existingVolume.Count -eq 1) { $existingVolume[0] } else { $null })
    $locations = @($locations | Where-Object { [string]$_.VolumeId -ne [string]$volume.VolumeId }) + @($location)
    $defaultLocationId = if (-not $configuration.DefaultLocationId) { [string]$location.LocationId } else { [string]$configuration.DefaultLocationId }
    if ($SetDefault) { $defaultLocationId = [string]$location.LocationId }
    $defaultLocation = @($locations | Where-Object LocationId -eq $defaultLocationId | Select-Object -First 1)
    if ($defaultLocation.Count -ne 1) { throw 'LAB_STORAGE_DEFAULT_LOCATION_NOT_FOUND' }
    $null = Write-LabStorageConfiguration -Configuration ([PSCustomObject]@{
        ContractVersion = 'SqlServerLab.Storage/2.0'; ControllerId = $controllerId
        DefaultLocationId = $defaultLocationId; DefaultDataRoot = [string]$defaultLocation[0].LabDataRoot
        LabDataLocations = $locations; LegacyMigrationReceipt = $configuration.LegacyMigrationReceipt
    })
    if ($SetDefault -or -not $currentDefault) {
        $env:SQL_SERVER_LAB_DATA_ROOT = $root
        $env:SQL_SERVER_LAB_CONTROLLER_ID = $controllerId
        if (-not $ProcessEnvironmentOnly) {
            [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', $root, 'User')
            [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_CONTROLLER_ID', $controllerId, 'User')
            Set-LabProjectPreferenceValue -Name dataRoot -Value $root
        }
        $null = Set-LabTestEnvironmentDiscoveryEnvironment -DataRoot $root -ProcessEnvironmentOnly:$ProcessEnvironmentOnly
    }
    return $root
}

function Set-LabDataLocation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, ParameterSetName='Root')][string]$LabDataRoot,
        [Parameter(Mandatory, ParameterSetName='LegacyParent')][string]$LabDataParent,
        [switch]$SetDefault,
        [switch]$ProcessEnvironmentOnly
    )

    $resolvedParent = if ($PSCmdlet.ParameterSetName -eq 'Root') {
        Resolve-LabStorageRootPath -Path $LabDataRoot
    }
    else {
        Resolve-LabStorageParentPath -Path $LabDataParent
    }
    $parent = [string]$resolvedParent.LabDataParent
    $dataRoot = [string]$resolvedParent.LabDataRoot
    if (-not $PSCmdlet.ShouldProcess($dataRoot, 'Normalisierte Lab_Data-Location initialisieren und registrieren')) { return $null }
    $configuration = Get-LabStorageConfiguration
    $marker = Initialize-LabManagedDataRoot -DataRoot $dataRoot -ControllerId ([string]$configuration.ControllerId)
    $null = Register-LabDataRoot -DataRoot $dataRoot -SetDefault:$SetDefault -ProcessEnvironmentOnly:$ProcessEnvironmentOnly
    $updated = Get-LabStorageConfiguration -DataRoot $(if ($configuration.DefaultDataRoot) { [string]$configuration.DefaultDataRoot } else { $dataRoot })
    $location = @($updated.LabDataLocations | Where-Object { [string]::Equals([string]$_.LabDataRoot, $dataRoot, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    return [PSCustomObject]@{
        LocationId = [string]$location.LocationId; LabDataParent=$parent; LabDataRoot=$dataRoot
        ControllerId=$marker.ControllerId; Volume=(Get-LabVolumeIdentity -Path $dataRoot)
        TopologyStatus=[string]$location.TopologyStatus; BackingDeviceIds=@($location.BackingDeviceIds)
    }
}

function Set-LabDefaultDataLocation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$LocationId,
        [switch]$ProcessEnvironmentOnly
    )

    $configuration = Get-LabStorageConfiguration
    $location = @($configuration.LabDataLocations | Where-Object LocationId -eq $LocationId | Select-Object -First 1)
    if ($location.Count -ne 1) { throw "LAB_STORAGE_LOCATION_NOT_FOUND: $LocationId" }
    if ([string]$configuration.DefaultLocationId -eq $LocationId) { return [string]$location[0].LabDataRoot }
    if (-not $PSCmdlet.ShouldProcess([string]$location[0].LabDataRoot, 'Globalen Lab_Data-Fallback explizit ändern')) { return $null }
    $configuration.DefaultLocationId = $LocationId
    $configuration.DefaultDataRoot = [string]$location[0].LabDataRoot
    $document = Write-LabStorageConfiguration -Configuration $configuration
    $env:SQL_SERVER_LAB_DATA_ROOT = [string]$document.DefaultDataRoot
    $env:SQL_SERVER_LAB_CONTROLLER_ID = [string]$document.ControllerId
    if (-not $ProcessEnvironmentOnly) {
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', [string]$document.DefaultDataRoot, 'User')
        [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_CONTROLLER_ID', [string]$document.ControllerId, 'User')
    }
    if (-not $ProcessEnvironmentOnly) {
        Set-LabProjectPreferenceValue -Name dataRoot -Value ([string]$document.DefaultDataRoot)
    }
    $null = Set-LabTestEnvironmentDiscoveryEnvironment -DataRoot ([string]$document.DefaultDataRoot) -ProcessEnvironmentOnly:$ProcessEnvironmentOnly
    return [string]$document.DefaultDataRoot
}

function Set-LabDataLocationMetadata {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$LocationId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DisplayName,
        [string[]]$Selectors = @()
    )

    $normalizedSelectors = @($Selectors | ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } | Where-Object { $_ } | Sort-Object -Unique)
    foreach ($selector in $normalizedSelectors) {
        if ($selector -notmatch '^[a-z][a-z0-9-]{0,62}$') { throw "LAB_STORAGE_SELECTOR_INVALID: $selector" }
    }
    $configuration = Get-LabStorageConfiguration
    $location = @($configuration.LabDataLocations | Where-Object LocationId -eq $LocationId | Select-Object -First 1)
    if ($location.Count -ne 1) { throw "LAB_STORAGE_LOCATION_NOT_FOUND: $LocationId" }
    $conflicts = @($configuration.LabDataLocations | Where-Object {
        [string]$_.LocationId -ne $LocationId -and @($_.Selectors | Where-Object { $_ -in $normalizedSelectors }).Count -gt 0
    })
    if ($conflicts.Count -gt 0) { throw "LAB_STORAGE_SELECTOR_NOT_UNIQUE: $(@($conflicts.Selectors | Where-Object { $_ -in $normalizedSelectors }) -join ', ')" }
    if (-not $PSCmdlet.ShouldProcess([string]$location[0].LabDataRoot, 'Storage-Anzeigename und portable Selektoren ändern')) { return $null }
    $location[0].DisplayName = $DisplayName.Trim()
    $location[0].Selectors = $normalizedSelectors
    $null = Write-LabStorageConfiguration -Configuration $configuration
    return $location[0]
}

function Get-LabDataLocationReferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Location, $Configuration)

    if (-not $Configuration) { $Configuration = Get-LabStorageConfiguration }
    $references = [System.Collections.Generic.List[object]]::new()
    $root = [IO.Path]::GetFullPath([string]$Location.LabDataRoot).TrimEnd('\', '/')
    foreach ($run in @(Get-LabActiveRuns)) {
        $runRoot = [string]$run.metadata.dataRoot
        if ($runRoot -and [string]::Equals([IO.Path]::GetFullPath($runRoot).TrimEnd('\', '/'), $root, [StringComparison]::OrdinalIgnoreCase)) {
            $references.Add([PSCustomObject]@{ Kind='run'; Id=[string]$run.runId })
        }
    }
    if ($IsWindows) {
        foreach ($drive in @(Get-LabHyperVHardDiskDriveInventory)) {
            if (-not $drive.Path) { continue }
            $path = [IO.Path]::GetFullPath([string]$drive.Path)
            if ($path.Equals($root, [StringComparison]::OrdinalIgnoreCase) -or
                $path.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                $references.Add([PSCustomObject]@{ Kind='hyperv-vhdx'; Id=[string]$drive.VMName })
            }
        }
    }
    foreach ($configurationRoot in @($Configuration.LabDataLocations | ForEach-Object { [string]$_.LabDataRoot } | Where-Object { $_ })) {
        foreach ($file in @(Get-ChildItem -LiteralPath (Join-Path $configurationRoot 'Catalog') -Filter '*.json' -File -Recurse -ErrorAction SilentlyContinue)) {
            if ($file.Name -eq 'storage-locations.json') { continue }
            $content = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8
            if ($content.Contains([string]$Location.LocationId, [StringComparison]::OrdinalIgnoreCase) -or
                $content.Contains($root, [StringComparison]::OrdinalIgnoreCase)) {
                $references.Add([PSCustomObject]@{ Kind='plan-or-journal'; Id=$file.FullName })
            }
        }
    }
    return @($references)
}

function Unregister-LabDataLocation {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$LocationId)

    $configuration = Get-LabStorageConfiguration
    $location = @($configuration.LabDataLocations | Where-Object LocationId -eq $LocationId | Select-Object -First 1)
    if ($location.Count -ne 1) { throw "LAB_STORAGE_LOCATION_NOT_FOUND: $LocationId" }
    if ([string]$configuration.DefaultLocationId -eq $LocationId) { throw 'LAB_STORAGE_DEFAULT_LOCATION_PROTECTED' }
    $references = @(Get-LabDataLocationReferences -Location $location[0] -Configuration $configuration)
    if ($references.Count -gt 0) {
        $referenceSummary = @($references | ForEach-Object { "$($_.Kind):$($_.Id)" }) -join ', '
        throw "LAB_STORAGE_LOCATION_REFERENCED: $referenceSummary"
    }
    if (-not $PSCmdlet.ShouldProcess([string]$location[0].LabDataRoot, 'Unbenutzte Storage-Location deregistrieren')) { return $false }
    $removedRoot = [string]$location[0].LabDataRoot
    $configuration.LabDataLocations = @($configuration.LabDataLocations | Where-Object LocationId -ne $LocationId)
    $null = Write-LabStorageConfiguration -Configuration $configuration -AdditionalRoots $removedRoot
    return $true
}

function Resolve-LabDataRootForUse {
    [CmdletBinding()]
    param([string]$DataRoot)

    $configuration = Get-LabStorageConfiguration
    $candidate = if ($DataRoot) { [System.IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/') } else { [string]$configuration.DefaultDataRoot }
    if (-not $candidate) { throw 'LAB_DATA_ROOT_REQUIRED: Zuerst eine Lab_Data-Ablage konfigurieren.' }
    $registered = @($configuration.LabDataLocations | Where-Object { [string]::Equals([string]$_.LabDataRoot, $candidate, [StringComparison]::OrdinalIgnoreCase) })
    if ($registered.Count -eq 0) { throw "LAB_DATA_ROOT_NOT_REGISTERED: $candidate" }
    if (-not (Test-LabDataRootOwnership -DataRoot $candidate -ControllerId ([string]$configuration.ControllerId))) { throw "LAB_DATA_ROOT_OWNERSHIP_INVALID: $candidate" }
    return (Resolve-Path -LiteralPath $candidate -ErrorAction Stop).Path
}

function Get-LabStorageMigrationLifecycleGuard {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$LocationId
    )

    $result = [ordered]@{
        ContractVersion = 'SqlServerLab.StorageMigrationLifecycleGuard/1.0'
        Allowed = $true
        Status = 'ABSENT'
        ReasonCode = 'STORAGE_MIGRATION_NOT_ACTIVE'
        Reason = 'Kein nichtterminales Storage-Migrationsjournal ist vorhanden.'
    }
    $journalDirectory = Join-Path (Join-Path ([IO.Path]::GetFullPath($DataRoot)) 'Catalog') 'storage-migrations'
    if (-not (Test-Path -LiteralPath $journalDirectory -PathType Container)) {
        return [PSCustomObject]$result
    }

    $statuses = [Collections.Generic.List[string]]::new()
    foreach ($journalFile in @(Get-ChildItem -LiteralPath $journalDirectory -Filter '*.journal.json' -File -ErrorAction SilentlyContinue)) {
        try {
            $journal = Get-Content -LiteralPath $journalFile.FullName -Raw -Encoding utf8 |
                ConvertFrom-Json -Depth 30 -ErrorAction Stop
            if ([string]$journal.ContractVersion -ne 'SqlServerLab.StorageMigrationJournal/1.0' -or
                -not [string]$journal.LocationId) {
                throw 'Vertrag oder LocationId ist ungueltig.'
            }
            if ($LocationId -and -not [string]::Equals(
                    [string]$journal.LocationId,
                    $LocationId,
                    [StringComparison]::OrdinalIgnoreCase
                )) {
                continue
            }
            $statuses.Add([string]$journal.Status)
        }
        catch {
            $result.Allowed = $false
            $result.Status = 'INVALID'
            $result.ReasonCode = 'STORAGE_MIGRATION_JOURNAL_INVALID'
            $result.Reason = 'Ein Storage-Migrationsjournal der gebundenen Location ist ungueltig.'
            return [PSCustomObject]$result
        }
    }
    $nonTerminal = @($statuses | Where-Object { $_ -ne 'COMPLETED' } | Sort-Object -Unique)
    if ($nonTerminal.Count -gt 0) {
        $result.Allowed = $false
        $result.Status = $nonTerminal -join ','
        $result.ReasonCode = 'STORAGE_MIGRATION_NOT_TERMINAL'
        $result.Reason = 'Die gebundene Storage-Location besitzt eine nichtterminale Migration.'
    }
    elseif ($statuses.Count -gt 0) {
        $result.Status = 'COMPLETED'
        $result.ReasonCode = 'STORAGE_MIGRATION_COMPLETED'
        $result.Reason = 'Alle Storage-Migrationsjournale der gebundenen Location sind abgeschlossen.'
    }
    return [PSCustomObject]$result
}

function Get-LabStorageMigrationHyperVBindingInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [string]$StateRoot
    )

    $sourceRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $searchRoots = @($sourceRoot, $StateRoot) | Where-Object { $_ } |
        ForEach-Object { [IO.Path]::GetFullPath([string]$_).TrimEnd('\', '/') } |
        Sort-Object -Unique
    $receiptPaths = @(
        foreach ($searchRoot in $searchRoots) {
            if (-not (Test-Path -LiteralPath $searchRoot -PathType Container)) { continue }
            Get-ChildItem -LiteralPath $searchRoot -Filter 'hyperv-resource-binding.local.json' `
                -File -Recurse -Force -ErrorAction Stop | ForEach-Object { $_.FullName }
        }
    ) | Sort-Object -Unique

    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($receiptPath in $receiptPaths) {
        try {
            $bindingDocument = Get-Content -LiteralPath $receiptPath -Raw -Encoding utf8 |
                ConvertFrom-Json -Depth 20 -ErrorAction Stop
        }
        catch {
            $inventory.Add([PSCustomObject]@{
                ReceiptPath=$receiptPath; ResourceClass=$null; ResourceId=$null; ResourceKey=$null
                LocationId=$null; LabDataRoot=$sourceRoot; HyperVResourceRoot=$null
                Valid=$false; ValidationCode='HYPERV_RESOURCE_BINDING_FILE_INVALID'; MigrationStatus='INVALID'
            })
            continue
        }
        if (-not [string]::Equals(
                [IO.Path]::GetFullPath([string]$bindingDocument.LabDataRoot).TrimEnd('\', '/'),
                $sourceRoot,
                [StringComparison]::OrdinalIgnoreCase
            )) {
            continue
        }
        $validation = Test-LabHyperVResourceBinding -Binding $bindingDocument -DataRoot $sourceRoot
        $migrationStatus = 'ABSENT'
        $migrationJournalName = switch ([string]$bindingDocument.ResourceClass) {
            'Run' { 'hyperv-resource-migration.local.journal.json' }
            'Image' { 'hyperv-image-migration.local.journal.json' }
            default { $null }
        }
        if ($migrationJournalName) {
            $migrationJournalPath = Join-Path (Split-Path -Parent $receiptPath) $migrationJournalName
            if (Test-Path -LiteralPath $migrationJournalPath -PathType Leaf) {
                try {
                    $migrationJournal = Get-Content -LiteralPath $migrationJournalPath -Raw -Encoding utf8 |
                        ConvertFrom-Json -Depth 50 -ErrorAction Stop
                    $migrationStatus = [string]$migrationJournal.Status
                    if (-not $migrationStatus) { $migrationStatus = 'INVALID' }
                }
                catch { $migrationStatus = 'INVALID' }
            }
        }
        $inventory.Add([PSCustomObject]@{
            ReceiptPath=$receiptPath; ResourceClass=[string]$bindingDocument.ResourceClass
            ResourceId=[string]$bindingDocument.ResourceId; ResourceKey=[string]$bindingDocument.ResourceKey
            LocationId=[string]$bindingDocument.LocationId; LabDataRoot=[string]$bindingDocument.LabDataRoot
            HyperVResourceRoot=[string]$bindingDocument.HyperVResourceRoot
            Valid=[bool]$validation.Valid; ValidationCode=[string]$validation.Code
            MigrationStatus=$migrationStatus
        })
    }
    return @($inventory)
}

function Assert-LabStorageMigrationHyperVBindingPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $planned = @($Plan.HyperVBindings)
    $stateRoot = if ($Plan.PSObject.Properties['StateRoot']) { [string]$Plan.StateRoot } else { $null }
    $current = @(Get-LabStorageMigrationHyperVBindingInventory -DataRoot $SourceRoot -StateRoot $stateRoot)
    if (Test-Path -LiteralPath $TargetRoot -PathType Container) {
        try {
            $current += @(Get-LabStorageMigrationHyperVBindingInventory -DataRoot $TargetRoot -StateRoot $stateRoot)
        }
        catch {
            # Vor dem Katalogwechsel kann der teilweise kopierte Zielroot noch
            # keine eigenstaendig aufloesbare Storage-Konfiguration besitzen.
            Write-Verbose "Zielroot-Inventar vor Katalogwechsel noch nicht aufloesbar: $($_.Exception.Message)"
        }
    }
    $normalizeToSource = {
        param([string]$Path)
        if (-not $Path) { return '' }
        $candidate = [IO.Path]::GetFullPath($Path)
        $targetBoundary = Test-LabPathWithinRoot -Root $TargetRoot -Path $candidate
        if ($targetBoundary.Valid -or [string]::Equals(
                $candidate.TrimEnd('\', '/'),
                ([IO.Path]::GetFullPath($TargetRoot)).TrimEnd('\', '/'),
                [StringComparison]::OrdinalIgnoreCase
            )) {
            $candidate = [IO.Path]::GetFullPath(
                (Join-Path $SourceRoot ([IO.Path]::GetRelativePath($TargetRoot, $candidate)))
            )
        }
        return $candidate.TrimEnd('\', '/').ToLowerInvariant()
    }
    $toKey = {
        param($Binding)
        return @(
            (& $normalizeToSource ([string]$Binding.ReceiptPath))
            ([string]$Binding.ResourceClass).ToLowerInvariant()
            ([string]$Binding.ResourceId).ToLowerInvariant()
            ([string]$Binding.ResourceKey).ToLowerInvariant()
            ([string]$Binding.LocationId).ToLowerInvariant()
            (& $normalizeToSource ([string]$Binding.LabDataRoot))
            (& $normalizeToSource ([string]$Binding.HyperVResourceRoot))
            ([string][bool]$Binding.Valid).ToLowerInvariant()
            ([string]$Binding.ValidationCode).ToLowerInvariant()
            ([string]$Binding.MigrationStatus).ToLowerInvariant()
        ) -join '|'
    }
    $plannedKeys = @($planned | ForEach-Object { & $toKey $_ } | Sort-Object -Unique)
    $currentKeys = @($current | ForEach-Object { & $toKey $_ } | Sort-Object -Unique)
    if (($plannedKeys -join "`n") -ne ($currentKeys -join "`n")) {
        $differentFields = [Collections.Generic.List[string]]::new()
        if ($planned.Count -eq 1 -and $current.Count -ge 1) {
            $comparison = @($current | Where-Object {
                [string]$_.ResourceKey -eq [string]$planned[0].ResourceKey
            } | Select-Object -First 1)
            if ($comparison.Count -eq 1) {
                foreach ($property in @('ReceiptPath','ResourceClass','ResourceId','ResourceKey','LocationId','LabDataRoot','HyperVResourceRoot','Valid','ValidationCode','MigrationStatus')) {
                    $plannedValue = if ($property -in @('ReceiptPath','LabDataRoot','HyperVResourceRoot')) {
                        & $normalizeToSource ([string]$planned[0].$property)
                    } else { ([string]$planned[0].$property).ToLowerInvariant() }
                    $currentValue = if ($property -in @('ReceiptPath','LabDataRoot','HyperVResourceRoot')) {
                        & $normalizeToSource ([string]$comparison[0].$property)
                    } else { ([string]$comparison[0].$property).ToLowerInvariant() }
                    if ($plannedValue -ne $currentValue) { $differentFields.Add($property) }
                }
            }
        }
        $plannedHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($plannedKeys -join "`n")
        )).ToLowerInvariant().Substring(0, 12)
        $currentHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
            [Text.Encoding]::UTF8.GetBytes($currentKeys -join "`n")
        )).ToLowerInvariant().Substring(0, 12)
        throw "LAB_STORAGE_MIGRATION_HYPERV_BINDING_PLAN_STALE: planned=$($plannedKeys.Count)/$plannedHash; current=$($currentKeys.Count)/$currentHash; fields=$($differentFields -join ',')"
    }
    foreach ($binding in $current) {
        if (-not [bool]$binding.Valid) {
            throw "LAB_STORAGE_MIGRATION_HYPERV_BINDING_INVALID: $([string]$binding.ValidationCode)"
        }
    }
    return @($planned)
}

function New-LabDataMigrationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourceDataRoot,
        [Parameter(Mandatory)][string]$TargetParent
    )

    $configuration = Get-LabStorageConfiguration
    $sourceRoot = Resolve-LabDataRootForUse -DataRoot $SourceDataRoot
    $sourceLocation = @($configuration.LabDataLocations | Where-Object { [string]::Equals([string]$_.LabDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase) } | Select-Object -First 1)
    if ($sourceLocation.Count -eq 0) { throw "LAB_DATA_ROOT_NOT_REGISTERED: $sourceRoot" }

    $resolvedTarget = Resolve-LabStorageParentPath -Path $TargetParent
    $normalizedTargetParent = [string]$resolvedTarget.LabDataParent
    $targetRoot = [string]$resolvedTarget.LabDataRoot
    $sourceVolume = Get-LabVolumeIdentity -Path $sourceRoot
    $targetVolume = Get-LabVolumeIdentity -Path $targetRoot
    $blockers = [System.Collections.Generic.List[string]]::new()
    if ([string]$sourceVolume.VolumeId -ne [string]$targetVolume.VolumeId) {
        $blockers.Add('TARGET_VOLUME_DIFFERS: Ein anderes Volume wird als eigene Lab_Data-Location registriert, nicht als Parent-Migration behandelt.')
    }
    if ([string]::Equals($sourceRoot, $targetRoot, [StringComparison]::OrdinalIgnoreCase)) { $blockers.Add('SOURCE_EQUALS_TARGET') }

    $targetMarker = Get-LabDataRootMarker -DataRoot $targetRoot
    if ($targetMarker -and [string]$targetMarker.ControllerId -ne [string]$configuration.ControllerId) { $blockers.Add('TARGET_CONTROLLER_MISMATCH') }
    if ((Test-Path -LiteralPath $targetRoot -PathType Container) -and -not $targetMarker) {
        $targetContent = Get-ChildItem -LiteralPath $targetRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($targetContent) { $blockers.Add('TARGET_NOT_EMPTY_OR_UNMANAGED') }
    }

    $files = @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop)
    $totalBytes = [long](($files | Measure-Object -Property Length -Sum).Sum)
    $driveInfo = [System.IO.DriveInfo]::new($targetVolume.VolumeRoot)
    $availableBytes = [long]$driveInfo.AvailableFreeSpace
    $requiredBytes = [long][Math]::Ceiling($totalBytes * 1.1)
    if ($availableBytes -lt $requiredBytes) { $blockers.Add('TARGET_CAPACITY_INSUFFICIENT') }

    $stateRoot = Get-LabStateRoot
    $hyperVBindings = @(Get-LabStorageMigrationHyperVBindingInventory -DataRoot $sourceRoot -StateRoot $stateRoot)
    foreach ($binding in $hyperVBindings) {
        if (-not [bool]$binding.Valid) {
            $blockers.Add("HYPERV_RESOURCE_BINDING_INVALID:$([string]$binding.ValidationCode)")
        }
        if ([string]$binding.MigrationStatus -notin @('ABSENT', 'COMPLETED')) {
            $blockers.Add("HYPERV_RESOURCE_MIGRATION_NOT_TERMINAL:$([string]$binding.ResourceKey):$([string]$binding.MigrationStatus)")
        }
    }

    $hyperVVMConfigurations = @()
    try {
        $hyperVVMConfigurations = @(Get-LabStorageMigrationHyperVVMConfigurationInventory `
            -DataRoot $sourceRoot -TargetRoot $targetRoot)
        if ($hyperVVMConfigurations.Count -gt 0 -and -not (Get-Command Move-VMStorage -ErrorAction SilentlyContinue)) {
            $blockers.Add('HYPERV_VM_STORAGE_COMMAND_UNAVAILABLE')
        }
        foreach ($vmConfiguration in $hyperVVMConfigurations) {
            if ([string]$vmConfiguration.State -ne 'Off') {
                $blockers.Add("HYPERV_VM_CONFIGURATION_VM_NOT_OFF:$([string]$vmConfiguration.VMName)")
            }
        }
    }
    catch {
        $blockers.Add('HYPERV_VM_CONFIGURATION_INVENTORY_FAILED')
    }

    $affectedRuns = @()
    foreach ($run in @(Get-LabActiveRuns)) {
        $runDataRoot = [string]$run.metadata.dataRoot
        $boundRun = @($hyperVBindings | Where-Object {
            [string]$_.ResourceClass -eq 'Run' -and
            [string]::Equals([string]$_.ResourceId, [string]$run.runId, [StringComparison]::OrdinalIgnoreCase)
        }).Count -gt 0
        if ($boundRun -or ($runDataRoot -and [string]::Equals([System.IO.Path]::GetFullPath($runDataRoot).TrimEnd('\', '/'), $sourceRoot.TrimEnd('\', '/'), [StringComparison]::OrdinalIgnoreCase))) {
            $runState = [string]$run.state
            $providers = @(
                @($run.instances | ForEach-Object { [string]$_.provider })
                @($run.providerSubRuns.PSObject.Properties | ForEach-Object { [string]$_.Name })
            ) | Where-Object { $_ } | Sort-Object -Unique
            $affectedRuns += [PSCustomObject]@{ RunId=[string]$run.runId; Name=[string]$run.metadata.name; State=$runState; Providers=@($providers) }
            if ($runState -notin @('STOPPED', 'REMOVED', 'FAILED')) { $blockers.Add("RUN_NOT_STOPPED:$($run.runId)") }
            if (@($providers | Where-Object { $_ -in @('docker', 'podman') }).Count -gt 0) { $blockers.Add("CONTAINER_REBIND_REQUIRED:$($run.runId)") }
        }
    }
    $planId = [Guid]::NewGuid().ToString('D')
    $plan = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.StorageMigrationPlan/1.0'
        PlanId = $planId
        CreatedAt = Get-LabTimestamp
        ControllerId = [string]$configuration.ControllerId
        Status = if ($blockers.Count -eq 0) { 'READY' } else { 'BLOCKED' }
        Source = [PSCustomObject]@{
            LocationId=[string]$sourceLocation[0].LocationId; VolumeId=$sourceVolume.VolumeId
            DriveLetter=$sourceVolume.DriveLetter; LabDataRoot=$sourceRoot
        }
        Target = [PSCustomObject]@{
            LocationId=[string]$sourceLocation[0].LocationId; VolumeId=$targetVolume.VolumeId
            DriveLetter=$targetVolume.DriveLetter; LabDataParent=$normalizedTargetParent; LabDataRoot=$targetRoot
        }
        Inventory = [PSCustomObject]@{ FileCount=$files.Count; TotalBytes=$totalBytes; RequiredBytes=$requiredBytes; AvailableBytes=$availableBytes }
        AffectedRuns = @($affectedRuns)
        StateRoot = [IO.Path]::GetFullPath($stateRoot)
        HyperVBindings = @($hyperVBindings)
        HyperVVMConfigurations = @($hyperVVMConfigurations)
        RequiredActions = @('Stop affected environments', 'Create migration journal', 'Copy and verify data', 'Update provider and state references', 'Switch authoritative storage catalog', 'Remove empty managed source root')
        Blockers = @($blockers | Sort-Object -Unique)
        ExecutionImplemented = $true
    }
    $planDirectory = Join-Path (Join-Path $sourceRoot 'Catalog') 'storage-migrations'
    if (-not (Test-Path -LiteralPath $planDirectory -PathType Container)) { New-Item -Path $planDirectory -ItemType Directory -Force | Out-Null }
    $planPath = Join-Path $planDirectory "$planId.plan.json"
    Write-LabArtifactJsonAtomic -Path $planPath -InputObject $plan
    return [PSCustomObject]@{ Path=$planPath; Plan=$plan }
}

function Write-LabDataMigrationJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Journal, [string]$MirrorPath)

    $Journal.UpdatedAt = Get-LabTimestamp
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
    if ($MirrorPath) { Write-LabArtifactJsonAtomic -Path $MirrorPath -InputObject $Journal }
}

function Get-LabHyperVHardDiskDriveInventory {
    [CmdletBinding()]
    param()

    $getVmCommand = Get-Command Get-VM -ErrorAction SilentlyContinue
    $getDriveCommand = Get-Command Get-VMHardDiskDrive -ErrorAction SilentlyContinue
    if (-not $getVmCommand -or -not $getDriveCommand) { return @() }

    $drives = [System.Collections.Generic.List[object]]::new()
    foreach ($vm in @(Get-VM -ErrorAction Stop)) {
        foreach ($drive in @(Get-VMHardDiskDrive -VMName ([string]$vm.Name) -ErrorAction Stop)) {
            $drives.Add($drive)
        }
    }
    return @($drives)
}

function Get-LabHyperVVirtualMachineInventory {
    [CmdletBinding()]
    param()

    if (-not $IsWindows -or -not (Get-Command Get-VM -ErrorAction SilentlyContinue)) { return @() }
    return @(Get-VM -ErrorAction Stop)
}

function Get-LabStorageMigrationHyperVVMConfigurationInventory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DataRoot,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $sourceRoot = [IO.Path]::GetFullPath($DataRoot).TrimEnd('\', '/')
    $normalizedTargetRoot = [IO.Path]::GetFullPath($TargetRoot).TrimEnd('\', '/')
    $inventory = [Collections.Generic.List[object]]::new()
    foreach ($vm in @(Get-LabHyperVVirtualMachineInventory)) {
        $boundPaths = [Collections.Generic.List[object]]::new()
        foreach ($candidate in @(
            [PSCustomObject]@{
                Kind='Configuration'
                Path=if ([string]$vm.Path) { [string]$vm.Path } else { [string]$vm.ConfigurationLocation }
            },
            [PSCustomObject]@{ Kind='Snapshot'; Path=[string]$vm.SnapshotFileLocation },
            [PSCustomObject]@{ Kind='SmartPaging'; Path=[string]$vm.SmartPagingFilePath }
        )) {
            if (-not [string]$candidate.Path) { continue }
            $currentPath = [IO.Path]::GetFullPath([string]$candidate.Path).TrimEnd('\', '/')
            $sourceBoundary = Test-LabPathWithinRoot -Root $sourceRoot -Path (Join-Path $currentPath '.path-check')
            $targetBoundary = Test-LabPathWithinRoot -Root $normalizedTargetRoot -Path (Join-Path $currentPath '.path-check')
            if (-not $sourceBoundary.Valid -and -not $targetBoundary.Valid) { continue }
            $sourcePath = if ($sourceBoundary.Valid) {
                $currentPath
            }
            else {
                Join-Path $sourceRoot ([IO.Path]::GetRelativePath($normalizedTargetRoot, $currentPath))
            }
            $destinationPath = if ($targetBoundary.Valid) {
                $currentPath
            }
            else {
                Join-Path $normalizedTargetRoot ([IO.Path]::GetRelativePath($sourceRoot, $currentPath))
            }
            $boundPaths.Add([PSCustomObject]@{
                Kind=[string]$candidate.Kind
                Path=[IO.Path]::GetFullPath($sourcePath).TrimEnd('\', '/')
                DestinationPath=[IO.Path]::GetFullPath($destinationPath).TrimEnd('\', '/')
                CurrentPath=$currentPath
            })
        }
        if ($boundPaths.Count -eq 0) { continue }
        $inventory.Add([PSCustomObject]@{
            VMId=[string]$vm.VMId
            VMName=[string]$vm.Name
            State=[string]$vm.State
            Paths=@($boundPaths)
        })
    }
    return @($inventory)
}

function Assert-LabStorageMigrationHyperVVMConfigurationPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$TargetRoot
    )

    $planned = if ($Plan.PSObject.Properties['HyperVVMConfigurations']) {
        @($Plan.HyperVVMConfigurations)
    }
    else { @() }
    $current = @(Get-LabStorageMigrationHyperVVMConfigurationInventory `
        -DataRoot $SourceRoot -TargetRoot $TargetRoot)
    if ($planned.Count -eq 0 -and $current.Count -gt 0) {
        throw 'LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_REBIND_REQUIRED'
    }
    if ($planned.Count -gt 0 -and -not (Get-Command Move-VMStorage -ErrorAction SilentlyContinue)) {
        throw 'LAB_STORAGE_MIGRATION_HYPERV_VM_STORAGE_COMMAND_UNAVAILABLE'
    }

    $plannedKeys = [Collections.Generic.List[string]]::new()
    $plannedVMIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($vm in $planned) {
        if (-not [string]$vm.VMId -or -not [string]$vm.VMName -or [string]$vm.State -ne 'Off') {
            throw 'LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_PLAN_INVALID'
        }
        if (-not $plannedVMIds.Add([string]$vm.VMId)) {
            throw 'LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_PLAN_INVALID'
        }
        $plannedKinds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($path in @($vm.Paths)) {
            if ([string]$path.Kind -notin @('Configuration','Snapshot','SmartPaging') -or
                -not [string]$path.Path -or -not [string]$path.DestinationPath -or
                -not $plannedKinds.Add([string]$path.Kind)) {
                throw 'LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_PLAN_INVALID'
            }
            $sourceBoundary = Test-LabPathWithinRoot -Root $SourceRoot -Path (Join-Path ([string]$path.Path) '.path-check')
            $targetBoundary = Test-LabPathWithinRoot -Root $TargetRoot -Path (Join-Path ([string]$path.DestinationPath) '.path-check')
            if (-not $sourceBoundary.Valid -or -not $targetBoundary.Valid) {
                throw 'LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_PLAN_SCOPE_INVALID'
            }
            $plannedKeys.Add((@(
                [string]$vm.VMId, [string]$vm.VMName, [string]$path.Kind,
                [IO.Path]::GetFullPath([string]$path.Path).ToLowerInvariant(),
                [IO.Path]::GetFullPath([string]$path.DestinationPath).ToLowerInvariant()
            ) -join '|'))
        }
    }

    $currentKeys = [Collections.Generic.List[string]]::new()
    foreach ($vm in $current) {
        if ([string]$vm.State -ne 'Off') {
            throw "LAB_STORAGE_MIGRATION_HYPERV_VM_NOT_OFF: $([string]$vm.VMName)"
        }
        foreach ($path in @($vm.Paths)) {
            $currentKeys.Add((@(
                [string]$vm.VMId, [string]$vm.VMName, [string]$path.Kind,
                [IO.Path]::GetFullPath([string]$path.Path).ToLowerInvariant(),
                [IO.Path]::GetFullPath([string]$path.DestinationPath).ToLowerInvariant()
            ) -join '|'))
        }
    }
    if (@(Compare-Object @($plannedKeys | Sort-Object) @($currentKeys | Sort-Object)).Count -gt 0) {
        throw 'LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_PLAN_STALE'
    }
    return @($planned)
}

function Update-LabMigratedJsonReferences {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$SourceRoot, [Parameter(Mandatory)][string]$TargetRoot)

    $changed = [System.Collections.Generic.List[string]]::new()
    $sourceEscaped = $SourceRoot.Replace('\', '\\')
    $targetEscaped = $TargetRoot.Replace('\', '\\')
    foreach ($path in @(Get-ChildItem -LiteralPath $Root -Filter '*.json' -File -Recurse -Force -ErrorAction Stop)) {
        $content = Get-Content -LiteralPath $path.FullName -Raw -Encoding utf8
        $updated = $content.Replace($sourceEscaped, $targetEscaped, [StringComparison]::OrdinalIgnoreCase)
        $updated = $updated.Replace($SourceRoot, $TargetRoot, [StringComparison]::OrdinalIgnoreCase)
        if ($updated -ne $content) {
            [System.IO.File]::WriteAllText($path.FullName, $updated, [System.Text.UTF8Encoding]::new($false))
            $changed.Add($path.FullName)
        }
    }
    return @($changed)
}

function Invoke-LabDataMigration {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param([Parameter(Mandatory)][string]$PlanPath, [switch]$ProcessEnvironmentOnly)

    $resolvedPlanPath = (Resolve-Path -LiteralPath $PlanPath -ErrorAction Stop).Path
    $plan = Get-Content -LiteralPath $resolvedPlanPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    if ([string]$plan.ContractVersion -ne 'SqlServerLab.StorageMigrationPlan/1.0' -or -not [bool]$plan.ExecutionImplemented) { throw 'LAB_STORAGE_MIGRATION_PLAN_NOT_EXECUTABLE' }
    if ([string]$plan.Status -ne 'READY' -or @($plan.Blockers).Count -gt 0) { throw "LAB_STORAGE_MIGRATION_PLAN_BLOCKED: $(@($plan.Blockers) -join ', ')" }
    $sourceRoot = (Resolve-Path -LiteralPath ([string]$plan.Source.LabDataRoot) -ErrorAction Stop).Path.TrimEnd('\', '/')
    $targetRoot = [System.IO.Path]::GetFullPath([string]$plan.Target.LabDataRoot).TrimEnd('\', '/')
    $configuration = Get-LabStorageConfiguration -DataRoot $sourceRoot
    if ([string]$configuration.ControllerId -ne [string]$plan.ControllerId) { throw 'LAB_STORAGE_MIGRATION_CONTROLLER_MISMATCH' }
    $sourceLocation = @($configuration.LabDataLocations | Where-Object {
        (([string]$plan.Source.LocationId) -and [string]$_.LocationId -eq [string]$plan.Source.LocationId) -or
        (-not [string]$plan.Source.LocationId -and [string]::Equals([string]$_.LabDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase))
    } | Select-Object -First 1)
    if ($sourceLocation.Count -ne 1 -or
        -not [string]::Equals([string]$sourceLocation[0].LabDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'LAB_STORAGE_MIGRATION_LOCATION_ID_MISMATCH'
    }
    if (-not (Test-LabDataRootOwnership -DataRoot $sourceRoot -ControllerId ([string]$plan.ControllerId))) { throw 'LAB_STORAGE_MIGRATION_SOURCE_OWNERSHIP_INVALID' }
    try {
        $validatedHyperVVMConfigurations = @(Assert-LabStorageMigrationHyperVVMConfigurationPlan `
            -Plan $plan -SourceRoot $sourceRoot -TargetRoot $targetRoot)
    }
    catch {
        throw "LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_INVENTORY_FAILED: $($_.Exception.Message)"
    }
    $validatedHyperVBindings = @(Assert-LabStorageMigrationHyperVBindingPlan `
        -Plan $plan -SourceRoot $sourceRoot -TargetRoot $targetRoot)
    if (-not $PSCmdlet.ShouldProcess("$sourceRoot -> $targetRoot", 'Lab_Data journalisiert migrieren')) { return $null }

    $planHash = (Get-FileHash -LiteralPath $resolvedPlanPath -Algorithm SHA256).Hash.ToLowerInvariant()
    $journalDirectory = Split-Path -Parent $resolvedPlanPath
    $journalPath = Join-Path $journalDirectory "$($plan.PlanId).journal.json"
    $targetJournalPath = Join-Path (Join-Path (Join-Path $targetRoot 'Catalog') 'storage-migrations') "$($plan.PlanId).journal.json"
    $journal = if (Test-Path -LiteralPath $journalPath -PathType Leaf) {
        Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
    }
    else {
        [PSCustomObject]@{
            ContractVersion='SqlServerLab.StorageMigrationJournal/1.0'; PlanId=[string]$plan.PlanId; PlanSha256=$planHash
            LocationId=[string]$sourceLocation[0].LocationId
            Status='PREPARING'; CreatedAt=Get-LabTimestamp; UpdatedAt=Get-LabTimestamp; CurrentStep='validate'
            CompletedAt=$null; CopiedFiles=@(); ReboundResources=@(); ReboundBindings=@(); UpdatedReferences=@(); Errors=@()
        }
    }
    if ([string]$journal.PlanSha256 -ne $planHash) { throw 'LAB_STORAGE_MIGRATION_PLAN_CHANGED' }
    if (-not $journal.PSObject.Properties['ReboundBindings']) {
        $journal | Add-Member -NotePropertyName ReboundBindings -NotePropertyValue @()
    }

    try {
        if ($IsWindows) {
            foreach ($drive in @(Get-LabHyperVHardDiskDriveInventory | Where-Object {
                if (-not $_.Path) { return $false }
                $drivePath = [System.IO.Path]::GetFullPath([string]$_.Path)
                return $drivePath.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or $drivePath.StartsWith($sourceRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            })) {
                $vm = Get-VM -Name ([string]$drive.VMName) -ErrorAction Stop
                if ([string]$vm.State -ne 'Off') { throw "LAB_STORAGE_MIGRATION_HYPERV_VM_NOT_OFF: $($drive.VMName)" }
            }
        }
        foreach ($runtime in @('docker', 'podman')) {
            $runtimeResolution = Resolve-LabHostTool -Name $runtime
            if (-not $runtimeResolution.Available) { continue }
            $runtimeInvocation = [string]$runtimeResolution.Invocation
            $containerIds = & $runtimeInvocation ps -a -q --filter 'label=sql-server-lab.run-id' 2>$null
            if ($LASTEXITCODE -ne 0) { continue }
            foreach ($containerId in @($containerIds)) {
                $inspect = @(& $runtimeInvocation inspect ([string]$containerId) 2>$null | ConvertFrom-Json -Depth 30)[0]
                foreach ($mount in @($inspect.Mounts | Where-Object { $_.Type -eq 'bind' -and $_.Source })) {
                    $mountSource = [System.IO.Path]::GetFullPath([string]$mount.Source)
                    if ($mountSource.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or $mountSource.StartsWith($sourceRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) {
                        throw "LAB_STORAGE_MIGRATION_CONTAINER_REBIND_REQUIRED: $runtime/$containerId"
                    }
                }
            }
        }

        $journal.Status = 'COPYING'; $journal.CurrentStep = 'copy-and-verify'
        Write-LabDataMigrationJournal -Path $journalPath -Journal $journal
        if (-not (Test-Path -LiteralPath $targetRoot -PathType Container)) { New-Item -Path $targetRoot -ItemType Directory -Force | Out-Null }
        $targetJournalDirectory = Split-Path -Parent $targetJournalPath
        if (-not (Test-Path -LiteralPath $targetJournalDirectory -PathType Container)) { New-Item -Path $targetJournalDirectory -ItemType Directory -Force | Out-Null }
        $vmmsManagedSourceRoots = @($validatedHyperVVMConfigurations | ForEach-Object { @($_.Paths) } | ForEach-Object { [string]$_.Path })
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop | Where-Object { $_.FullName -ne $journalPath })) {
            $vmmsManagedFile = [string]$sourceFile.Extension -in @('.vmcx','.vmrs','.vmgs') -and
                @($vmmsManagedSourceRoots | Where-Object {
                    (Test-LabPathWithinRoot -Root $_ -Path $sourceFile.FullName).Valid
                }).Count -gt 0
            if ($vmmsManagedFile) { continue }
            $relativePath = [System.IO.Path]::GetRelativePath($sourceRoot, $sourceFile.FullName)
            $destination = Join-Path $targetRoot $relativePath
            $destinationDirectory = Split-Path -Parent $destination
            if (-not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) { New-Item -Path $destinationDirectory -ItemType Directory -Force | Out-Null }
            $sourceHash = (Get-FileHash -LiteralPath $sourceFile.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            $alreadyCopied = (Test-Path -LiteralPath $destination -PathType Leaf) -and ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToLowerInvariant() -eq $sourceHash)
            if (-not $alreadyCopied) {
                $temporaryDestination = "$destination.sql-lab-migrating"
                Copy-Item -LiteralPath $sourceFile.FullName -Destination $temporaryDestination -Force
                $targetHash = (Get-FileHash -LiteralPath $temporaryDestination -Algorithm SHA256).Hash.ToLowerInvariant()
                if ($targetHash -ne $sourceHash) { throw "LAB_STORAGE_MIGRATION_HASH_MISMATCH: $relativePath" }
                Move-Item -LiteralPath $temporaryDestination -Destination $destination -Force
            }
            if ($relativePath -notin @($journal.CopiedFiles)) { $journal.CopiedFiles += $relativePath }
            Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        }

        $journal.Status = 'REBINDING'; $journal.CurrentStep = 'provider-rebind'
        Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        if ($IsWindows) {
            foreach ($drive in @(Get-LabHyperVHardDiskDriveInventory | Where-Object {
                if (-not $_.Path) { return $false }
                $drivePath = [System.IO.Path]::GetFullPath([string]$_.Path)
                return $drivePath.Equals($sourceRoot, [StringComparison]::OrdinalIgnoreCase) -or $drivePath.StartsWith($sourceRoot + [System.IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)
            })) {
                $vm = Get-VM -Name ([string]$drive.VMName) -ErrorAction Stop
                if ([string]$vm.State -ne 'Off') { throw "LAB_STORAGE_MIGRATION_HYPERV_VM_NOT_OFF: $($drive.VMName)" }
                $newPath = Join-Path $targetRoot ([System.IO.Path]::GetRelativePath($sourceRoot, [string]$drive.Path))
                Set-VMHardDiskDrive -VMHardDiskDrive $drive -Path $newPath -ErrorAction Stop
                $journal.ReboundResources += [PSCustomObject]@{ Provider='hyperv'; VMName=[string]$drive.VMName; PreviousPath=[string]$drive.Path; Path=$newPath }
            }
        }
        foreach ($vmPlan in $validatedHyperVVMConfigurations) {
            $vm = @(Get-LabHyperVVirtualMachineInventory | Where-Object {
                [string]$_.VMId -eq [string]$vmPlan.VMId -and [string]$_.Name -eq [string]$vmPlan.VMName
            })
            if ($vm.Count -ne 1 -or [string]$vm[0].State -ne 'Off') {
                throw "LAB_STORAGE_MIGRATION_HYPERV_VM_IDENTITY_OR_STATE_INVALID: $([string]$vmPlan.VMName)"
            }
            $currentVMConfiguration = @(Get-LabStorageMigrationHyperVVMConfigurationInventory `
                -DataRoot $sourceRoot -TargetRoot $targetRoot | Where-Object {
                    [string]$_.VMId -eq [string]$vmPlan.VMId -and [string]$_.VMName -eq [string]$vmPlan.VMName
                })
            if ($currentVMConfiguration.Count -ne 1) {
                throw "LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_MISSING: $([string]$vmPlan.VMName)"
            }
            $allDestinationPaths = @($vmPlan.Paths | Where-Object {
                $kind = [string]$_.Kind
                $actual = @($currentVMConfiguration[0].Paths | Where-Object { [string]$_.Kind -eq $kind })
                $actual.Count -eq 1 -and [string]::Equals(
                    [string]$actual[0].CurrentPath, [string]$_.DestinationPath,
                    [StringComparison]::OrdinalIgnoreCase)
            }).Count -eq @($vmPlan.Paths).Count
            $receipt = @($journal.ReboundResources | Where-Object {
                [string]$_.Kind -eq 'VMStorage' -and [string]$_.VMId -eq [string]$vmPlan.VMId
            }) | Select-Object -First 1
            if (-not $receipt) {
                $receipt = [PSCustomObject]@{
                    Provider='hyperv'; Kind='VMStorage'; VMId=[string]$vmPlan.VMId
                    VMName=[string]$vmPlan.VMName; State='PENDING'; Paths=@($vmPlan.Paths)
                    CompletedAt=$null
                }
                $journal.ReboundResources = @($journal.ReboundResources) + @($receipt)
                Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
            }
            if (-not $allDestinationPaths) {
                $moveParameters = @{ VM=$vm[0]; ErrorAction='Stop' }
                foreach ($path in @($vmPlan.Paths)) {
                    $parameterName = switch ([string]$path.Kind) {
                        'Configuration' { 'VirtualMachinePath' }
                        'Snapshot' { 'SnapshotFilePath' }
                        'SmartPaging' { 'SmartPagingFilePath' }
                    }
                    $moveParameters[$parameterName] = [string]$path.DestinationPath
                }
                Move-VMStorage @moveParameters
            }
            $currentVMConfiguration = @(Get-LabStorageMigrationHyperVVMConfigurationInventory `
                -DataRoot $sourceRoot -TargetRoot $targetRoot | Where-Object {
                    [string]$_.VMId -eq [string]$vmPlan.VMId -and [string]$_.VMName -eq [string]$vmPlan.VMName
                })
            if ($currentVMConfiguration.Count -ne 1 -or
                @($vmPlan.Paths | Where-Object {
                    $kind = [string]$_.Kind
                    $actual = @($currentVMConfiguration[0].Paths | Where-Object { [string]$_.Kind -eq $kind })
                    $actual.Count -ne 1 -or -not [string]::Equals(
                        [string]$actual[0].CurrentPath, [string]$_.DestinationPath,
                        [StringComparison]::OrdinalIgnoreCase)
                }).Count -gt 0) {
                throw "LAB_STORAGE_MIGRATION_HYPERV_VM_CONFIGURATION_POSTCONDITION_FAILED: $([string]$vmPlan.VMName)"
            }
            $receipt.State = 'COMPLETED'
            $receipt.CompletedAt = Get-LabTimestamp
            Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        }

        $journal.Status = 'SWITCHING'; $journal.CurrentStep = 'references-and-catalog'
        $journal.UpdatedReferences = @(Update-LabMigratedJsonReferences -Root $targetRoot -SourceRoot $sourceRoot -TargetRoot $targetRoot)
        $null = Initialize-LabManagedDataRoot -DataRoot $targetRoot -ControllerId ([string]$configuration.ControllerId) -Confirm:$false
        $locations = @($configuration.LabDataLocations | ForEach-Object {
            if ([string]::Equals([string]$_.LabDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
                New-LabStorageLocationRecord -ControllerId ([string]$configuration.ControllerId) `
                    -LabDataRoot $targetRoot -ExistingLocation $_
            }
            else { $_ }
        })
        $newConfiguration = [PSCustomObject]@{
            ContractVersion='SqlServerLab.Storage/2.0'; ControllerId=[string]$configuration.ControllerId
            DefaultLocationId=[string]$configuration.DefaultLocationId
            DefaultDataRoot=if ([string]::Equals([string]$configuration.DefaultDataRoot, $sourceRoot, [StringComparison]::OrdinalIgnoreCase)) { $targetRoot } else { [string]$configuration.DefaultDataRoot }
            LabDataLocations=$locations; LegacyMigrationReceipt=$configuration.LegacyMigrationReceipt
        }
        $newConfiguration = Write-LabStorageConfiguration -Configuration $newConfiguration
        if ([string]::Equals([string]$newConfiguration.DefaultDataRoot, $targetRoot, [StringComparison]::OrdinalIgnoreCase)) {
            $env:SQL_SERVER_LAB_DATA_ROOT = $targetRoot
            if (-not $ProcessEnvironmentOnly) {
                [Environment]::SetEnvironmentVariable('SQL_SERVER_LAB_DATA_ROOT', $targetRoot, 'User')
                Set-LabProjectPreferenceValue -Name dataRoot -Value $targetRoot
            }
            $null = Set-LabTestEnvironmentDiscoveryEnvironment -DataRoot $targetRoot -ProcessEnvironmentOnly:$ProcessEnvironmentOnly
        }

        foreach ($bindingInventory in $validatedHyperVBindings) {
            $receiptBoundary = Test-LabPathWithinRoot -Root $sourceRoot -Path ([string]$bindingInventory.ReceiptPath)
            $stateDirectory = if ($receiptBoundary.Valid) {
                Split-Path -Parent (Join-Path $targetRoot ([IO.Path]::GetRelativePath($sourceRoot, [string]$bindingInventory.ReceiptPath)))
            }
            else {
                Split-Path -Parent ([string]$bindingInventory.ReceiptPath)
            }
            if (-not $receiptBoundary.Valid) {
                $journal.UpdatedReferences = @(
                    @($journal.UpdatedReferences) + @(
                        Update-LabMigratedJsonReferences -Root $stateDirectory -SourceRoot $sourceRoot -TargetRoot $targetRoot
                    ) | Sort-Object -Unique
                )
            }
            $updatedBinding = Resolve-LabHyperVResourceBinding `
                -ResourceId ([string]$bindingInventory.ResourceId) `
                -ResourceClass ([string]$bindingInventory.ResourceClass) `
                -LocationId ([string]$bindingInventory.LocationId) `
                -DataRoot $targetRoot
            $bindingPath = Write-LabHyperVResourceBinding -Binding $updatedBinding `
                -StateDirectory $stateDirectory -DataRoot $targetRoot
            if (@($journal.ReboundBindings | Where-Object {
                    [string]$_.ResourceKey -eq [string]$updatedBinding.ResourceKey
                }).Count -eq 0) {
                $journal.ReboundBindings = @($journal.ReboundBindings) + @([PSCustomObject]@{
                    ResourceClass=[string]$updatedBinding.ResourceClass
                    ResourceId=[string]$updatedBinding.ResourceId
                    ResourceKey=[string]$updatedBinding.ResourceKey
                    ReceiptPath=$bindingPath
                })
            }
            Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        }

        $journal.Status = 'CLEANING'; $journal.CurrentStep = 'remove-verified-source'
        Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $targetJournalPath
        foreach ($sourceFile in @(Get-ChildItem -LiteralPath $sourceRoot -File -Recurse -Force -ErrorAction Stop)) {
            $relativePath = [System.IO.Path]::GetRelativePath($sourceRoot, $sourceFile.FullName)
            $destination = Join-Path $targetRoot $relativePath
            if (-not (Test-Path -LiteralPath $destination -PathType Leaf)) { throw "LAB_STORAGE_MIGRATION_TARGET_FILE_MISSING: $relativePath" }
            if ($sourceFile.FullName -ne $journalPath) { Remove-Item -LiteralPath $sourceFile.FullName -Force }
        }
        if (Test-Path -LiteralPath $journalPath -PathType Leaf) { Remove-Item -LiteralPath $journalPath -Force }
        foreach ($directory in @(Get-ChildItem -LiteralPath $sourceRoot -Directory -Recurse -Force | Sort-Object FullName -Descending)) {
            if (-not (Get-ChildItem -LiteralPath $directory.FullName -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $directory.FullName -Force }
        }
        if (-not (Get-ChildItem -LiteralPath $sourceRoot -Force -ErrorAction SilentlyContinue | Select-Object -First 1)) { Remove-Item -LiteralPath $sourceRoot -Force }

        $journal.Status = 'COMPLETED'; $journal.CurrentStep = 'complete'; $journal.CompletedAt = Get-LabTimestamp
        Write-LabDataMigrationJournal -Path $targetJournalPath -Journal $journal
        return [PSCustomObject]@{ Status='COMPLETED'; PlanId=[string]$plan.PlanId; DataRoot=$targetRoot; JournalPath=$targetJournalPath }
    }
    catch {
        $journal.Status = 'RECOVERY_REQUIRED'; $journal.CurrentStep = 'failed'
        $journal.Errors += [PSCustomObject]@{ At=Get-LabTimestamp; Message=$_.Exception.Message }
        try { Write-LabDataMigrationJournal -Path $journalPath -Journal $journal -MirrorPath $(if (Test-Path -LiteralPath $targetRoot -PathType Container) { $targetJournalPath } else { $null }) } catch { }
        throw "LAB_STORAGE_MIGRATION_RECOVERY_REQUIRED: $($_.Exception.Message)"
    }
}

function Select-LabDataLocationInteractive {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Configuration,
        [Parameter(Mandatory)][string]$Title,
        [switch]$ExcludeDefault
    )

    $locations = @($Configuration.LabDataLocations | Where-Object {
        -not $ExcludeDefault -or [string]$_.LocationId -ne [string]$Configuration.DefaultLocationId
    })
    if ($locations.Count -eq 0) { return $null }
    $items = for ($index = 0; $index -lt $locations.Count; $index++) {
        $location = $locations[$index]
        $defaultMarker = if ([string]$location.LocationId -eq [string]$Configuration.DefaultLocationId) { ' · Standard' } else { '' }
        New-LabConsoleItem -Id ([string]$location.LocationId) -Label ([string]$location.LabDataRoot) `
            -Value ("{0} · {1} Backing Device(s){2}" -f $location.TopologyStatus, @($location.BackingDeviceIds).Count, $defaultMarker) `
            -Shortcut ([string]($index + 1)) -Data $location
    }
    $selection = Invoke-LabConsoleMenu -ScreenId 'storage-location-select' -Title $Title -Items $items
    if ($selection.Status -ne 'Selected') { return $null }
    return $selection.SelectedItem.Data
}

function Invoke-LabStorageInteractive {
    [CmdletBinding()]
    param()

    while ($true) {
        $configuration = Get-LabStorageConfiguration
        $subtitle = if ($configuration.DefaultDataRoot) {
            "Standard: $($configuration.DefaultDataRoot) · $(@($configuration.LabDataLocations).Count) Location(s)"
        }
        else { 'Noch keine verwaltete Lab_Data-Location' }
        $menu = Invoke-LabConsoleMenu -ScreenId 'storage-management' -Title 'Storage verwalten' -Subtitle $subtitle -Items @(
            New-LabConsoleItem -Id 'add' -Label 'Lab-Datenroot hinzufügen' -Value 'vollständiger Pfad; ändert einen vorhandenen Standard nicht' -Shortcut '1'
            New-LabConsoleItem -Id 'show' -Label 'Locations und Topologie aktualisieren' -Shortcut '2'
            New-LabConsoleItem -Id 'metadata' -Label 'Anzeigename und portable Selektoren ändern' -Shortcut '3' -Disabled:(@($configuration.LabDataLocations).Count -eq 0)
            New-LabConsoleItem -Id 'default' -Label 'Globalen Fallback explizit festlegen' -Shortcut '4' -Disabled:(@($configuration.LabDataLocations).Count -lt 2)
            New-LabConsoleItem -Id 'remove' -Label 'Unbenutzte Location deregistrieren' -Value 'Default und Referenzen sind geschützt' -Shortcut '5' -Disabled:(@($configuration.LabDataLocations).Count -lt 2)
            New-LabConsoleItem -Id 'plan' -Label 'Parent-Migration planen' -Shortcut '6' -Disabled:(@($configuration.LabDataLocations).Count -eq 0)
            New-LabConsoleItem -Id 'execute' -Label 'Freigegebenen Migrationsplan ausführen' -Shortcut '7'
            New-LabConsoleItem -Id 'file-plan' -Label 'SQL-Dateiplatzierung lokal binden und prüfen' -Shortcut '8' -Disabled:(@($configuration.LabDataLocations).Count -eq 0)
            New-LabConsoleItem -Id 'back' -Label 'Zurück' -Shortcut '0'
        )
        if ($menu.Status -ne 'Selected' -or [string]$menu.SelectedItem.Id -eq 'back') { return }
        try {
            switch ([string]$menu.SelectedItem.Id) {
                'add' {
                    $dataRoot = Read-Host '  Vollständigen Lab-Datenroot eingeben (z. B. D:\Lab1_Data)'
                    $resolved = Resolve-LabStorageRootPath -Path $dataRoot
                    Write-LabInfo "Normalisiertes Ziel: $($resolved.LabDataRoot)"
                    if (-not (Read-LabConfirm -Prompt '  Diese Lab_Data-Location initialisieren und registrieren?' -Default $false)) { continue }
                    $result = Set-LabDataLocation -LabDataRoot $dataRoot -Confirm:$false
                    Write-LabSuccess "Lab-Datenroot registriert: $($result.LabDataRoot)"
                    Write-LabInfo "LocationId=$($result.LocationId); Topologie=$($result.TopologyStatus); Standard blieb unverändert."
                }
                'show' {
                    foreach ($location in @($configuration.LabDataLocations)) {
                        $marker = if ([string]$location.LocationId -eq [string]$configuration.DefaultLocationId) { ' [STANDARD]' } else { '' }
                        Write-Host ("  {0} · {1}{2}`n    Selektoren={3}`n    Root={4}`n    Volume={5}; Topologie={6}; Backing={7}; Bus={8}; Medium={9}; Health={10}; Frei={11}" -f
                            $location.LocationId, $location.DisplayName, $marker, (@($location.Selectors) -join ', '), $location.LabDataRoot, $location.VolumeId,
                            $location.TopologyStatus, (@($location.BackingDeviceIds) -join ', '), $location.BusType,
                            $location.MediaType, $location.HealthStatus, $location.FreeBytes)
                    }
                    Wait-LabConsoleAcknowledgement -Prompt '  Enter oder Escape: Zurück zum Storage-Menü'
                }
                'metadata' {
                    $location = Select-LabDataLocationInteractive -Configuration $configuration -Title 'Storage-Location benennen und Selektoren zuordnen'
                    if (-not $location) { continue }
                    $displayName = Read-Host "  Anzeigename [$($location.DisplayName)]"
                    if (-not $displayName) { $displayName = [string]$location.DisplayName }
                    $selectorsText = Read-Host "  Portable Selektoren, kommasepariert [$(@($location.Selectors) -join ',')]"
                    $selectors = if ($selectorsText) { @($selectorsText -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) } else { @($location.Selectors) }
                    Write-LabInfo "Location=$($location.LocationId); Anzeigename=$displayName; Selektoren=$($selectors -join ', ')"
                    if (Read-LabConfirm -Prompt '  Metadaten jetzt speichern?' -Default $false) {
                        $null = Set-LabDataLocationMetadata -LocationId ([string]$location.LocationId) -DisplayName $displayName -Selectors $selectors -Confirm:$false
                        Write-LabSuccess 'Storage-Metadaten gespeichert.'
                    }
                }
                'default' {
                    $location = Select-LabDataLocationInteractive -Configuration $configuration -Title 'Neuen globalen Lab_Data-Fallback wählen'
                    if (-not $location -or [string]$location.LocationId -eq [string]$configuration.DefaultLocationId) { continue }
                    Write-LabWarning "Neue persistente Labs verwenden danach standardmäßig: $($location.LabDataRoot)"
                    if (Read-LabConfirm -Prompt '  Globalen Fallback jetzt explizit ändern?' -Default $false) {
                        $null = Set-LabDefaultDataLocation -LocationId ([string]$location.LocationId) -Confirm:$false
                        Write-LabSuccess "Globaler Fallback geändert: $($location.LabDataRoot)"
                    }
                }
                'remove' {
                    $location = Select-LabDataLocationInteractive -Configuration $configuration -Title 'Unbenutzte Location deregistrieren' -ExcludeDefault
                    if (-not $location) { continue }
                    Write-LabWarning 'Die Daten werden nicht gelöscht; nur die Registry-Bindung wird entfernt.'
                    if (Read-LabConfirm -Prompt "  Location $($location.LocationId) deregistrieren?" -Default $false) {
                        $null = Unregister-LabDataLocation -LocationId ([string]$location.LocationId) -Confirm:$false
                        Write-LabSuccess "Location deregistriert: $($location.LabDataRoot)"
                    }
                }
                'plan' {
                    $location = Select-LabDataLocationInteractive -Configuration $configuration -Title 'Quell-Location für Parent-Migration wählen'
                    if (-not $location) { continue }
                    $targetParent = Read-Host '  Neuer vollqualifizierter Parent auf demselben Volume'
                    $result = New-LabDataMigrationPlan -SourceDataRoot ([string]$location.LabDataRoot) -TargetParent $targetParent
                    Write-LabInfo "Migrationsplan: $($result.Path)"
                    Write-Host ("    LocationId={0}; Status={1}; Dateien={2}; Bytes={3}; Blocker={4}" -f
                        $result.Plan.Source.LocationId, $result.Plan.Status, $result.Plan.Inventory.FileCount,
                        $result.Plan.Inventory.TotalBytes, @($result.Plan.Blockers).Count) -ForegroundColor DarkGray
                    foreach ($blocker in @($result.Plan.Blockers)) { Write-LabWarning $blocker }
                }
                'execute' {
                    $planPath = Read-Host '  Vollständiger Pfad zur *.plan.json'
                    Write-LabWarning 'Die Migration kopiert und prüft alle Dateien, bindet Hyper-V-VHDX um und schaltet erst danach den Katalog um.'
                    if (Read-LabConfirm -Prompt '  Migrationsplan jetzt ausführen?' -Default $false) {
                        $result = Invoke-LabDataMigration -PlanPath $planPath -Confirm:$false
                        Write-LabSuccess "Storage-Migration abgeschlossen: $($result.DataRoot)"
                        Write-LabInfo "Journal: $($result.JournalPath)"
                    }
                }
                'file-plan' {
                    Invoke-LabStorageFilePlacementInteractive
                }
            }
        }
        catch [OperationCanceledException] {
            if (-not (Test-LabConsoleInputCancellation $_)) { throw }
        }
        catch { Write-LabError $_.Exception.Message }
    }
}
