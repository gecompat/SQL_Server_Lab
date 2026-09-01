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
