<#
.SYNOPSIS
    Liest und plant den versionierten persistenten Storage-Katalog read-only.
.DESCRIPTION
    Trennt die dauerhafte PersistentStorageId von wechselbaren Provider- und
    Inventory-Bindungen. Der Planner mutiert weder Katalog noch Runtime.
#>

function New-LabPersistentStorageId {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification='Erzeugt nur eine neue in-memory Identitaet.')]
    [CmdletBinding()]
    param()

    return [Guid]::NewGuid().ToString('D')
}

function Invoke-LabPersistentStorageCatalogLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ControllerId,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock
    )

    $material = [Text.Encoding]::UTF8.GetBytes($ControllerId.ToLowerInvariant())
    $token = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($material)).Substring(0,16)
    $name = if ($IsWindows) { "Global\SQL_Server_Lab_Persistent_Storage_$token" } else { "SQL_Server_Lab_Persistent_Storage_$token" }
    $mutex = [Threading.Mutex]::new($false,$name); $acquired = $false
    try {
        $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if (-not $acquired) { throw 'PERSISTENT_STORAGE_CATALOG_LOCK_TIMEOUT' }
        return & $ScriptBlock
    }
    finally {
        if ($acquired) { $mutex.ReleaseMutex() }
        $mutex.Dispose()
    }
}

function Test-LabPersistentStorageCatalogDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)]$Configuration
    )

    $schemaPath = Join-Path $script:SchemasPath 'persistent-storage-catalog.schema.json'
    try {
        $valid = $Document | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch { throw "PERSISTENT_STORAGE_CATALOG_SCHEMA_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'PERSISTENT_STORAGE_CATALOG_SCHEMA_INVALID' }
    if ([string]$Document.ControllerId -ne [string]$Configuration.ControllerId) {
        throw 'PERSISTENT_STORAGE_CATALOG_CONTROLLER_MISMATCH'
    }

    $locationIds = @($Configuration.LabDataLocations | ForEach-Object { [string]$_.LocationId })
    $storageIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($store in @($Document.Stores)) {
        $storageId = [string]$store.PersistentStorageId
        if (-not $storageIds.Add($storageId)) { throw "PERSISTENT_STORAGE_ID_DUPLICATE: $storageId" }

        $referenceIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($reference in @($store.References)) {
            if (-not $referenceIds.Add([string]$reference.ReferenceId)) {
                throw "PERSISTENT_STORAGE_REFERENCE_DUPLICATE: $storageId"
            }
        }

        $binding = $store.LocationBinding
        $residency = [string]$binding.Residency
        if (-not $binding.InventoryObjectId -and -not $binding.ProviderResourceId -and -not $binding.RelativePath) {
            throw "PERSISTENT_STORAGE_BINDING_IDENTITY_REQUIRED: $storageId"
        }
        if ($binding.RelativePath) {
            $relativePath = [string]$binding.RelativePath
            if ([IO.Path]::IsPathFullyQualified($relativePath) -or $relativePath -match '^[A-Za-z]:' -or
                $relativePath -match '^[\\/]' -or $relativePath -match '(^|[\\/])\.\.([\\/]|$)') {
                throw "PERSISTENT_STORAGE_RELATIVE_PATH_INVALID: $storageId"
            }
        }
        switch ($residency) {
            'LAB_DATA' {
                if (-not $binding.LocationId -or [string]$binding.LocationId -notin $locationIds) {
                    throw "PERSISTENT_STORAGE_LOCATION_NOT_REGISTERED: $storageId"
                }
            }
            'NATIVE_RUNTIME' {
                if ([string]$store.Provider -notin @('docker','podman') -or $binding.LocationId -or -not $binding.ProviderResourceId) {
                    throw "PERSISTENT_STORAGE_NATIVE_BINDING_INVALID: $storageId"
                }
            }
            'EXTERNAL_HOST' {
                if ([string]$store.Provider -ne 'external' -or $binding.LocationId -or
                    [string]$store.CleanupDisposition -ne 'REPORT_ONLY' -or [string]$store.Retention -ne 'EXTERNAL_UNMANAGED') {
                    throw "PERSISTENT_STORAGE_EXTERNAL_BINDING_INVALID: $storageId"
                }
            }
        }

        $hasLease = $null -ne $store.Lease
        if ([string]$store.State -eq 'IN_USE' -and -not $hasLease) {
            throw "PERSISTENT_STORAGE_LEASE_REQUIRED: $storageId"
        }
        if ([string]$store.State -in @('AVAILABLE','DETACHED','DELETE_PENDING') -and $hasLease) {
            throw "PERSISTENT_STORAGE_LEASE_STATE_INVALID: $storageId"
        }
        if ($hasLease) {
            $activeRunReferences = @($store.References | Where-Object {
                [string]$_.Kind -eq 'RUN' -and [string]$_.State -eq 'ACTIVE'
            })
            if ($activeRunReferences.Count -ne 1 -or
                [string]$activeRunReferences[0].TargetId -ne [string]$store.Lease.RunId) {
                throw "PERSISTENT_STORAGE_LEASE_REFERENCE_REQUIRED: $storageId"
            }
        }
    }
    return $true
}

function Get-LabPersistentStorageCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Configuration)

    $emptyDocument = [PSCustomObject]@{
        ContractVersion = 'SqlServerLab.PersistentStorageCatalog/1.0'
        ControllerId = [string]$Configuration.ControllerId
        Revision = 0
        Stores = @()
    }
    if ([string]::IsNullOrWhiteSpace([string]$Configuration.ControllerId)) {
        return [PSCustomObject]@{ Status='UNAVAILABLE'; Document=$emptyDocument; Sources=@(); Issues=@('CONTROLLER_ID_UNAVAILABLE') }
    }

    $documents = [Collections.Generic.List[object]]::new()
    $sources = [Collections.Generic.List[object]]::new()
    $issues = [Collections.Generic.List[string]]::new()
    foreach ($location in @($Configuration.LabDataLocations)) {
        $root = [string]$location.LabDataRoot
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container) -or
            -not (Test-LabDataRootOwnership -DataRoot $root -ControllerId ([string]$Configuration.ControllerId))) { continue }
        $path = Join-Path (Join-Path $root 'Catalog') 'persistent-stores.json'
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        try {
            $document = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40 -ErrorAction Stop
            $null = Test-LabPersistentStorageCatalogDocument -Document $document -Configuration $Configuration
            $canonical = $document | ConvertTo-Json -Depth 40 -Compress
            $documents.Add([PSCustomObject]@{ Document=$document; Canonical=$canonical })
            $sources.Add([PSCustomObject]@{ LocationId=[string]$location.LocationId; Path=$path; Status='VALID' })
        }
        catch {
            $issues.Add($_.Exception.Message)
            $sources.Add([PSCustomObject]@{ LocationId=[string]$location.LocationId; Path=$path; Status='INVALID' })
        }
    }

    if ($issues.Count -gt 0) {
        return [PSCustomObject]@{ Status='INVALID'; Document=$emptyDocument; Sources=@($sources); Issues=@($issues) }
    }
    if ($documents.Count -eq 0) {
        return [PSCustomObject]@{ Status='EMPTY'; Document=$emptyDocument; Sources=@(); Issues=@() }
    }
    if (@($documents | Select-Object -ExpandProperty Canonical -Unique).Count -ne 1) {
        return [PSCustomObject]@{ Status='DIVERGED'; Document=$emptyDocument; Sources=@($sources); Issues=@('PERSISTENT_STORAGE_CATALOG_DIVERGED') }
    }
    return [PSCustomObject]@{ Status='AVAILABLE'; Document=$documents[0].Document; Sources=@($sources); Issues=@() }
}

function Write-LabPersistentStorageCatalogDocument {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Document,
        [Parameter(Mandatory)]$Configuration
    )

    $null = Test-LabPersistentStorageCatalogDocument -Document $Document -Configuration $Configuration
    $targets = [Collections.Generic.List[object]]::new()
    foreach ($location in @($Configuration.LabDataLocations | Sort-Object LocationId)) {
        $root = [string]$location.LabDataRoot
        if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container) -or
            -not (Test-LabDataRootOwnership -DataRoot $root -ControllerId ([string]$Configuration.ControllerId))) {
            throw "PERSISTENT_STORAGE_CATALOG_LOCATION_UNAVAILABLE: $([string]$location.LocationId)"
        }
        $path = Join-Path (Join-Path $root 'Catalog') 'persistent-stores.json'
        $previous = $null
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try { $previous = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40 -ErrorAction Stop }
            catch { throw "PERSISTENT_STORAGE_CATALOG_PREVIOUS_INVALID: $([string]$location.LocationId)" }
        }
        $targets.Add([PSCustomObject]@{ Path=$path; Previous=$previous; Written=$false })
    }
    if ($targets.Count -eq 0) { throw 'PERSISTENT_STORAGE_CATALOG_LOCATION_REQUIRED' }

    try {
        foreach ($target in $targets) {
            Write-LabArtifactJsonAtomic -Path ([string]$target.Path) -InputObject $Document
            $target.Written = $true
        }
        $verification = Get-LabPersistentStorageCatalog -Configuration $Configuration
        if ([string]$verification.Status -ne 'AVAILABLE' -or @($verification.Sources).Count -ne $targets.Count -or
            [int]$verification.Document.Revision -ne [int]$Document.Revision) {
            throw 'PERSISTENT_STORAGE_CATALOG_POSTCONDITION_FAILED'
        }
    }
    catch {
        $writeFailure = $_.Exception.Message; $rollbackFailures = [Collections.Generic.List[string]]::new()
        foreach ($target in @($targets | Where-Object Written)) {
            try {
                if ($null -eq $target.Previous) { Remove-Item -LiteralPath ([string]$target.Path) -Force }
                else { Write-LabArtifactJsonAtomic -Path ([string]$target.Path) -InputObject $target.Previous }
            }
            catch { $rollbackFailures.Add([string]$target.Path) }
        }
        if ($rollbackFailures.Count -gt 0) { throw "PERSISTENT_STORAGE_CATALOG_ROLLBACK_FAILED: $($rollbackFailures -join ', ')" }
        throw "PERSISTENT_STORAGE_CATALOG_WRITE_FAILED: $writeFailure"
    }
    return $Document
}

function Register-LabBackupSetPersistentStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$BackupRecord,
        [Parameter(Mandatory)][string]$DataRoot,
        [AllowNull()]$Configuration
    )

    $configuration = if ($Configuration) { $Configuration } else { Get-LabStorageConfiguration -DataRoot $DataRoot }
    $resolvedRoot = if ($Configuration) {
        [IO.Path]::GetFullPath($DataRoot).TrimEnd('\','/')
    }
    else { (Resolve-LabDataRootForUse -DataRoot $DataRoot).TrimEnd('\','/') }
    $locations = @($configuration.LabDataLocations | Where-Object {
        [string]::Equals(([IO.Path]::GetFullPath([string]$_.LabDataRoot).TrimEnd('\','/')),$resolvedRoot,[StringComparison]::OrdinalIgnoreCase)
    })
    if ($locations.Count -ne 1) { throw 'BACKUP_SET_STORAGE_LOCATION_UNRESOLVED' }
    if ([string]$BackupRecord.Source.Provider -notin @('docker','podman','hyperv')) { throw 'BACKUP_SET_STORAGE_PROVIDER_INVALID' }
    $backupSetId = [string]$BackupRecord.BackupSetId
    $inventoryObjectId = Get-LabStorageResidencyObjectId -Key "backup-set|$([string]$configuration.ControllerId)|$backupSetId"

    return Invoke-LabPersistentStorageCatalogLock -ControllerId ([string]$configuration.ControllerId) -ScriptBlock {
        $catalog = Get-LabPersistentStorageCatalog -Configuration $configuration
        if ([string]$catalog.Status -in @('INVALID','DIVERGED','UNAVAILABLE')) {
            throw "PERSISTENT_STORAGE_CATALOG_MUTATION_BLOCKED: $([string]$catalog.Status)"
        }
        $matches = @($catalog.Document.Stores | Where-Object {
            @($_.References | Where-Object { [string]$_.Kind -eq 'ARTIFACT' -and [string]$_.TargetId -eq $backupSetId }).Count -gt 0
        })
        if ($matches.Count -gt 1) { throw 'BACKUP_SET_STORAGE_REFERENCE_DUPLICATE' }
        $relativePath = (Join-Path 'Backups' ([string]$BackupRecord.Artifact.RelativePath)).Replace('\','/')
        $expectedState = if ([string]$BackupRecord.Status -eq 'REUSABLE') { 'AVAILABLE' } else { 'RECOVERY_REQUIRED' }
        if ($matches.Count -eq 1) {
            $existing = $matches[0]
            if ([string]$existing.StorageClass -ne 'BACKUP_SET' -or [string]$existing.Provider -ne [string]$BackupRecord.Source.Provider -or
                [string]$existing.LocationBinding.LocationId -ne [string]$locations[0].LocationId -or
                [string]$existing.LocationBinding.InventoryObjectId -ne $inventoryObjectId -or
                [string]$existing.LocationBinding.RelativePath -ne $relativePath -or $null -ne $existing.Lease -or
                [string]$existing.Retention -ne 'RETAINED' -or [string]$existing.CleanupDisposition -ne 'PRESERVE' -or
                @($existing.References | Where-Object { [string]$_.Kind -eq 'ARTIFACT' -and [string]$_.State -eq 'ACTIVE' -and [string]$_.TargetId -eq $backupSetId }).Count -ne 1) {
                throw 'BACKUP_SET_STORAGE_BINDING_CONFLICT'
            }
            if ([string]$existing.State -ne $expectedState) {
                $next = $catalog.Document | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
                $nextStore = @($next.Stores | Where-Object PersistentStorageId -eq ([string]$existing.PersistentStorageId))[0]
                $nextStore.State = $expectedState; $nextStore.UpdatedAt = Get-LabTimestamp
                $next.Revision = [int]$next.Revision + 1
                $null = Write-LabPersistentStorageCatalogDocument -Document $next -Configuration $configuration
                return [PSCustomObject]@{ Changed=$true; Store=$nextStore; CatalogRevision=[int]$next.Revision }
            }
            return [PSCustomObject]@{ Changed=$false; Store=$existing; CatalogRevision=[int]$catalog.Document.Revision }
        }

        $now = Get-LabTimestamp
        $displayName = "$([string]$BackupRecord.DatabaseName) backup $([string]$BackupRecord.CreatedAt)"
        if ($displayName.Length -gt 128) { $displayName = $displayName.Substring(0,128) }
        $store = [PSCustomObject][ordered]@{
            PersistentStorageId=(New-LabPersistentStorageId); DisplayName=$displayName; StorageClass='BACKUP_SET'
            State=$expectedState
            Provider=[string]$BackupRecord.Source.Provider
            LocationBinding=[PSCustomObject][ordered]@{
                Residency='LAB_DATA'; LocationId=[string]$locations[0].LocationId; ProviderResourceId=$null
                InventoryObjectId=$inventoryObjectId; RelativePath=$relativePath
            }
            References=@([PSCustomObject][ordered]@{ ReferenceId=$backupSetId; Kind='ARTIFACT'; State='ACTIVE'; TargetId=$backupSetId })
            Lease=$null; Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt=$now; UpdatedAt=$now
        }
        $next = $catalog.Document | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $next.Revision = [int]$next.Revision + 1
        $next.Stores = @($next.Stores) + @($store)
        $null = Test-LabPersistentStorageCatalogDocument -Document $next -Configuration $configuration
        $null = Write-LabPersistentStorageCatalogDocument -Document $next -Configuration $configuration
        return [PSCustomObject]@{ Changed=$true; Store=$store; CatalogRevision=[int]$next.Revision }
    }
}

function Register-LabDatabasePackagePersistentStorage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$PackageRecord,
        [Parameter(Mandatory)][string]$DataRoot,
        [AllowNull()]$Configuration
    )

    $configuration = if ($Configuration) { $Configuration } else { Get-LabStorageConfiguration -DataRoot $DataRoot }
    $resolvedRoot = if ($Configuration) {
        [IO.Path]::GetFullPath($DataRoot).TrimEnd('\','/')
    }
    else { (Resolve-LabDataRootForUse -DataRoot $DataRoot).TrimEnd('\','/') }
    $locations = @($configuration.LabDataLocations | Where-Object {
        [string]::Equals(([IO.Path]::GetFullPath([string]$_.LabDataRoot).TrimEnd('\','/')),$resolvedRoot,[StringComparison]::OrdinalIgnoreCase)
    })
    if ($locations.Count -ne 1) { throw 'DATABASE_PACKAGE_STORAGE_LOCATION_UNRESOLVED' }
    if ([string]$PackageRecord.Source.Provider -notin @('docker','podman','hyperv','external')) { throw 'DATABASE_PACKAGE_STORAGE_PROVIDER_INVALID' }
    $packageId = [string]$PackageRecord.DatabasePackageId
    $inventoryObjectId = Get-LabStorageResidencyObjectId -Key "database-package|$([string]$configuration.ControllerId)|$packageId"

    return Invoke-LabPersistentStorageCatalogLock -ControllerId ([string]$configuration.ControllerId) -ScriptBlock {
        $catalog = Get-LabPersistentStorageCatalog -Configuration $configuration
        if ([string]$catalog.Status -in @('INVALID','DIVERGED','UNAVAILABLE')) {
            throw "PERSISTENT_STORAGE_CATALOG_MUTATION_BLOCKED: $([string]$catalog.Status)"
        }
        $catalogMatches = @($catalog.Document.Stores | Where-Object {
            @($_.References | Where-Object { [string]$_.Kind -eq 'ARTIFACT' -and [string]$_.TargetId -eq $packageId }).Count -gt 0
        })
        if ($catalogMatches.Count -gt 1) { throw 'DATABASE_PACKAGE_STORAGE_REFERENCE_DUPLICATE' }
        $relativePath = (Join-Path 'DatabasePackages' (Join-Path 'Objects' ([string]$PackageRecord.ManifestSha256))).Replace('\','/')
        $expectedState = if ([string]$PackageRecord.Status -eq 'REUSABLE') { 'AVAILABLE' } else { 'RECOVERY_REQUIRED' }
        if ($catalogMatches.Count -eq 1) {
            $existing = $catalogMatches[0]
            if ([string]$existing.StorageClass -ne 'DATABASE_PACKAGE' -or [string]$existing.Provider -ne [string]$PackageRecord.Source.Provider -or
                [string]$existing.LocationBinding.LocationId -ne [string]$locations[0].LocationId -or
                [string]$existing.LocationBinding.InventoryObjectId -ne $inventoryObjectId -or
                [string]$existing.LocationBinding.RelativePath -ne $relativePath -or $null -ne $existing.Lease -or
                [string]$existing.Retention -ne 'RETAINED' -or [string]$existing.CleanupDisposition -ne 'PRESERVE' -or
                @($existing.References | Where-Object { [string]$_.Kind -eq 'ARTIFACT' -and [string]$_.State -eq 'ACTIVE' -and [string]$_.TargetId -eq $packageId }).Count -ne 1) {
                throw 'DATABASE_PACKAGE_STORAGE_BINDING_CONFLICT'
            }
            if ([string]$existing.State -ne $expectedState) {
                $next = $catalog.Document | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
                $nextStore = @($next.Stores | Where-Object PersistentStorageId -eq ([string]$existing.PersistentStorageId))[0]
                $nextStore.State = $expectedState; $nextStore.UpdatedAt = Get-LabTimestamp
                $next.Revision = [int]$next.Revision + 1
                $null = Write-LabPersistentStorageCatalogDocument -Document $next -Configuration $configuration
                return [PSCustomObject]@{ Changed=$true; Store=$nextStore; CatalogRevision=[int]$next.Revision }
            }
            return [PSCustomObject]@{ Changed=$false; Store=$existing; CatalogRevision=[int]$catalog.Document.Revision }
        }

        $now = Get-LabTimestamp
        $displayName = "$([string]$PackageRecord.DatabaseName) package $([string]$PackageRecord.CreatedAt)"
        if ($displayName.Length -gt 128) { $displayName = $displayName.Substring(0,128) }
        $store = [PSCustomObject][ordered]@{
            PersistentStorageId=(New-LabPersistentStorageId); DisplayName=$displayName; StorageClass='DATABASE_PACKAGE'
            State=$expectedState; Provider=[string]$PackageRecord.Source.Provider
            LocationBinding=[PSCustomObject][ordered]@{
                Residency='LAB_DATA'; LocationId=[string]$locations[0].LocationId; ProviderResourceId=$null
                InventoryObjectId=$inventoryObjectId; RelativePath=$relativePath
            }
            References=@([PSCustomObject][ordered]@{ ReferenceId=$packageId; Kind='ARTIFACT'; State='ACTIVE'; TargetId=$packageId })
            Lease=$null; Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt=$now; UpdatedAt=$now
        }
        $next = $catalog.Document | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $next.Revision = [int]$next.Revision + 1
        $next.Stores = @($next.Stores) + @($store)
        $null = Test-LabPersistentStorageCatalogDocument -Document $next -Configuration $configuration
        $null = Write-LabPersistentStorageCatalogDocument -Document $next -Configuration $configuration
        return [PSCustomObject]@{ Changed=$true; Store=$store; CatalogRevision=[int]$next.Revision }
    }
}

function Register-LabContainerInstanceStoreClone {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Journal,
        [Parameter(Mandatory)]$Configuration
    )

    if ([string]$Plan.ContractVersion -ne 'SqlServerLab.ContainerInstanceStorePlan/1.0' -or
        [string]$Plan.Status -ne 'READY' -or [string]$Plan.Action -ne 'CLONE') {
        throw 'CONTAINER_INSTANCE_STORE_CATALOG_PLAN_INVALID'
    }
    if ([string]$Journal.ContractVersion -ne 'SqlServerLab.ContainerInstanceStoreJournal/1.0' -or
        [string]$Journal.Status -notin @('VERIFIED','COMPLETED') -or
        [string]$Journal.OperationId -ne [string]$Plan.OperationId -or
        [string]$Journal.Provider -ne [string]$Plan.Provider -or
        [string]$Journal.Source.PersistentStorageId -ne [string]$Plan.Source.PersistentStorageId -or
        [string]$Journal.Target.PersistentStorageId -ne [string]$Plan.Target.PersistentStorageId -or
        [string]$Journal.Target.VolumeName -ne [string]$Plan.Target.VolumeName -or
        [string]$Journal.Target.VolumeId -ne [string]$Plan.Target.VolumeName -or
        -not $Journal.Source.Evidence -or -not $Journal.Target.Evidence -or
        [string]$Journal.Source.Evidence.Sha256 -ne [string]$Journal.Target.Evidence.Sha256 -or
        [long]$Journal.Source.Evidence.FileCount -ne [long]$Journal.Target.Evidence.FileCount -or
        [long]$Journal.Source.Evidence.TotalBytes -ne [long]$Journal.Target.Evidence.TotalBytes) {
        throw 'CONTAINER_INSTANCE_STORE_CATALOG_EVIDENCE_INVALID'
    }
    if ([string]::IsNullOrWhiteSpace([string]$Configuration.ControllerId)) {
        throw 'CONTAINER_INSTANCE_STORE_CATALOG_CONFIGURATION_INVALID'
    }

    $targetStorageId = [string]$Plan.Target.PersistentStorageId
    $targetVolumeName = [string]$Plan.Target.VolumeName
    $targetInventoryObjectId = Get-LabStorageResidencyObjectId -Key "runtime-volume|$([string]$Plan.Provider)|$targetVolumeName"

    return Invoke-LabPersistentStorageCatalogLock -ControllerId ([string]$Configuration.ControllerId) -ScriptBlock {
        $catalog = Get-LabPersistentStorageCatalog -Configuration $Configuration
        if ([string]$catalog.Status -ne 'AVAILABLE') {
            throw "PERSISTENT_STORAGE_CATALOG_MUTATION_BLOCKED: $([string]$catalog.Status)"
        }
        $sourceStores = @($catalog.Document.Stores | Where-Object {
            [string]$_.PersistentStorageId -eq [string]$Plan.Source.PersistentStorageId
        })
        if ($sourceStores.Count -ne 1 -or [string]$sourceStores[0].StorageClass -ne 'INSTANCE_STORE' -or
            [string]$sourceStores[0].Provider -ne [string]$Plan.Provider -or
            [string]$sourceStores[0].State -notin @('AVAILABLE','DETACHED') -or $sourceStores[0].Lease -or
            @($sourceStores[0].References | Where-Object State -eq 'ACTIVE').Count -gt 0 -or
            [string]$sourceStores[0].LocationBinding.ProviderResourceId -ne [string]$Plan.Source.VolumeName) {
            throw 'CONTAINER_INSTANCE_STORE_CATALOG_SOURCE_CONFLICT'
        }

        $targetStores = @($catalog.Document.Stores | Where-Object {
            [string]$_.PersistentStorageId -eq $targetStorageId -or
            ([string]$_.Provider -eq [string]$Plan.Provider -and
                ([string]$_.LocationBinding.ProviderResourceId -eq $targetVolumeName -or
                 [string]$_.LocationBinding.InventoryObjectId -eq $targetInventoryObjectId))
        })
        if ($targetStores.Count -gt 1) { throw 'CONTAINER_INSTANCE_STORE_CATALOG_TARGET_DUPLICATE' }
        if ($targetStores.Count -eq 1) {
            $existing = $targetStores[0]
            if ([string]$existing.PersistentStorageId -ne $targetStorageId -or
                [string]$existing.StorageClass -ne 'INSTANCE_STORE' -or [string]$existing.Provider -ne [string]$Plan.Provider -or
                [string]$existing.State -ne 'DETACHED' -or $existing.Lease -or
                [string]$existing.LocationBinding.Residency -ne 'NATIVE_RUNTIME' -or $existing.LocationBinding.LocationId -or
                [string]$existing.LocationBinding.ProviderResourceId -ne $targetVolumeName -or
                [string]$existing.LocationBinding.InventoryObjectId -ne $targetInventoryObjectId -or $existing.LocationBinding.RelativePath -or
                [string]$existing.Retention -ne 'RETAINED' -or [string]$existing.CleanupDisposition -ne 'PRESERVE' -or
                @($existing.References | Where-Object {
                    [string]$_.ReferenceId -eq [string]$Plan.OperationId -and [string]$_.Kind -eq 'RUN' -and
                    [string]$_.State -eq 'RELEASED' -and [string]$_.TargetId -eq [string]$Plan.Target.RunId
                }).Count -ne 1 -or @($existing.References | Where-Object State -eq 'ACTIVE').Count -gt 0) {
                throw 'CONTAINER_INSTANCE_STORE_CATALOG_TARGET_CONFLICT'
            }
            return [PSCustomObject]@{ Changed=$false; Store=$existing; CatalogRevision=[int]$catalog.Document.Revision }
        }

        $now = Get-LabTimestamp
        $displayName = "Clone of $([string]$sourceStores[0].DisplayName)"
        if ($displayName.Length -gt 128) { $displayName = $displayName.Substring(0,128) }
        $store = [PSCustomObject][ordered]@{
            PersistentStorageId=$targetStorageId; DisplayName=$displayName; StorageClass='INSTANCE_STORE'
            State='DETACHED'; Provider=[string]$Plan.Provider
            LocationBinding=[PSCustomObject][ordered]@{
                Residency='NATIVE_RUNTIME'; LocationId=$null; ProviderResourceId=$targetVolumeName
                InventoryObjectId=$targetInventoryObjectId; RelativePath=$null
            }
            References=@([PSCustomObject][ordered]@{
                ReferenceId=[string]$Plan.OperationId; Kind='RUN'; State='RELEASED'; TargetId=[string]$Plan.Target.RunId
            })
            Lease=$null; Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt=$now; UpdatedAt=$now
        }
        $next = $catalog.Document | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40
        $next.Revision = [int]$next.Revision + 1
        $next.Stores = @($next.Stores) + @($store)
        $null = Test-LabPersistentStorageCatalogDocument -Document $next -Configuration $Configuration
        $null = Write-LabPersistentStorageCatalogDocument -Document $next -Configuration $Configuration
        return [PSCustomObject]@{ Changed=$true; Store=$store; CatalogRevision=[int]$next.Revision }
    }
}

function Sync-LabBackupSetPersistentStorageCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $paths = Get-LabBackupLibraryPaths -DataRoot $DataRoot
    $library = Get-LabBackupLibraryDocument -Paths $paths
    $results = foreach ($record in @($library.Backups | Sort-Object BackupSetId)) {
        Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $paths.DataRoot
    }
    return @($results)
}

function Sync-LabDatabasePackagePersistentStorageCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $paths = Get-LabDatabasePackagePaths -DataRoot $DataRoot
    $library = Get-LabDatabasePackageDocument -Paths $paths
    $results = foreach ($record in @($library.Packages | Sort-Object DatabasePackageId)) {
        Register-LabDatabasePackagePersistentStorage -PackageRecord $record -DataRoot $paths.DataRoot
    }
    return @($results)
}

function Get-LabPersistentStoragePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$ResidencyInventory
    )

    $catalogStatus = if ($Catalog.PSObject.Properties['Status']) { [string]$Catalog.Status } else { 'AVAILABLE' }
    $document = if ($Catalog.PSObject.Properties['Document']) { $Catalog.Document } else { $Catalog }
    $actions = [Collections.Generic.List[object]]::new()
    $stores = [Collections.Generic.List[object]]::new()
    $matchedObjectIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)

    if ($catalogStatus -in @('INVALID','DIVERGED','UNAVAILABLE')) {
        $actions.Add([PSCustomObject]@{ Action='RESOLVE_CONFLICT'; Severity='BLOCKING'; PersistentStorageId=$null; InventoryObjectId=$null; Reason="CATALOG_$catalogStatus" })
    }

    foreach ($store in @($document.Stores)) {
        $binding = $store.LocationBinding
        $matches = if ($binding.InventoryObjectId) {
            @($ResidencyInventory.Objects | Where-Object ObjectId -eq ([string]$binding.InventoryObjectId))
        }
        elseif ($binding.ProviderResourceId) {
            @($ResidencyInventory.Objects | Where-Object {
                [string]$_.Provider -eq [string]$store.Provider -and
                [string]$_.LogicalName -eq [string]$binding.ProviderResourceId
            })
        }
        else { @() }
        foreach ($match in $matches) { $null = $matchedObjectIds.Add([string]$match.ObjectId) }

        $observationStatus = if ($matches.Count -eq 1) { 'MATCHED' } elseif ($matches.Count -gt 1) { 'AMBIGUOUS' } elseif ([string]$store.Provider -eq 'external') { 'NOT_REQUIRED' } else { 'MISSING' }
        $leaseStatus = 'NONE'
        if ($store.Lease) {
            if ($matches.Count -gt 1) { $leaseStatus = 'CONFLICT' }
            elseif ($matches.Count -eq 0) { $leaseStatus = 'NOT_OBSERVED' }
            elseif ([string]$store.Lease.RunId -in @($matches[0].RunIds | ForEach-Object { [string]$_ })) { $leaseStatus = 'CONSISTENT' }
            else { $leaseStatus = 'CONFLICT' }
        }
        $stores.Add([PSCustomObject]@{
            PersistentStorageId=[string]$store.PersistentStorageId; StorageClass=[string]$store.StorageClass
            Provider=[string]$store.Provider; State=[string]$store.State; LeaseStatus=$leaseStatus
            ObservationStatus=$observationStatus; ObservedObjectIds=@($matches | ForEach-Object { [string]$_.ObjectId } | Sort-Object -Unique)
        })

        if ($observationStatus -eq 'AMBIGUOUS' -or $leaseStatus -eq 'CONFLICT') {
            $actions.Add([PSCustomObject]@{ Action='RESOLVE_CONFLICT'; Severity='BLOCKING'; PersistentStorageId=[string]$store.PersistentStorageId; InventoryObjectId=$null; Reason='BINDING_OR_LEASE_CONFLICT' })
        }
        elseif ($observationStatus -eq 'MISSING' -or $leaseStatus -eq 'NOT_OBSERVED') {
            $actions.Add([PSCustomObject]@{ Action='VERIFY_REQUIRED'; Severity='WARNING'; PersistentStorageId=[string]$store.PersistentStorageId; InventoryObjectId=$null; Reason='CATALOG_BINDING_NOT_OBSERVED' })
        }
        else {
            $actions.Add([PSCustomObject]@{ Action='NO_OP'; Severity='INFO'; PersistentStorageId=[string]$store.PersistentStorageId; InventoryObjectId=$(if ($matches.Count -eq 1) { [string]$matches[0].ObjectId } else { $null }); Reason='CATALOG_BINDING_CONSISTENT' })
        }
    }

    foreach ($object in @($ResidencyInventory.Objects | Where-Object {
        [string]$_.Lifecycle -eq 'RETAINED' -and [string]$_.AuditStatus -ne 'UNVERIFIABLE'
    })) {
        if ($matchedObjectIds.Contains([string]$object.ObjectId)) { continue }
        $actions.Add([PSCustomObject]@{
            Action='REGISTER_REQUIRED'; Severity='WARNING'; PersistentStorageId=$null
            InventoryObjectId=[string]$object.ObjectId; Reason='RETAINED_OBJECT_NOT_CATALOGED'
        })
    }

    $actionArray = @($actions)
    $storeArray = @($stores)
    $blockers = @($actionArray | Where-Object Severity -eq 'BLOCKING').Count
    $warnings = @($actionArray | Where-Object Severity -eq 'WARNING').Count
    [PSCustomObject]@{
        ContractVersion='SqlServerLab.PersistentStoragePlan/1.0'
        Status=if ($blockers -gt 0) { 'BLOCKED' } elseif ($warnings -gt 0) { 'PARTIAL' } else { 'READY' }
        CatalogRevision=[int]$document.Revision
        Stores=$storeArray
        Actions=$actionArray
        Summary=[PSCustomObject]@{
            StoreCount=$storeArray.Count
            MatchedStores=@($storeArray | Where-Object ObservationStatus -eq 'MATCHED').Count
            RegistrationCandidates=@($actionArray | Where-Object Action -eq 'REGISTER_REQUIRED').Count
            Warnings=$warnings
            Blockers=$blockers
        }
    }
}
