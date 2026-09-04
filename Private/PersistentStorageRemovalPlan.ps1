<#
.SYNOPSIS
    Plant die Folgen einer Run-Entfernung für katalogisierte Speicher read-only.
.DESCRIPTION
    Validiert explizite Retention-Entscheidungen und erzeugt geordnete,
    recovery-geschützte Schritte. Der Planner mutiert weder SQL noch Storage,
    Katalog, Lease oder Run-State.
#>

function Test-LabPersistentStorageRemovalIntent {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Intent)

    $schemaPath = Join-Path $script:SchemasPath 'persistent-storage-removal-intent.schema.json'
    try { $valid = $Intent | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop }
    catch { throw "PERSISTENT_STORAGE_REMOVAL_INTENT_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'PERSISTENT_STORAGE_REMOVAL_INTENT_INVALID' }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($selection in @($Intent.Selections)) {
        if (-not $ids.Add([string]$selection.PersistentStorageId)) {
            throw "PERSISTENT_STORAGE_REMOVAL_SELECTION_DUPLICATE: $($selection.PersistentStorageId)"
        }
    }
    return $true
}

function ConvertTo-LabPersistentStorageRemovalSelection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Selection)
    @(
        foreach ($item in @($Selection)) {
            if (-not $item) { throw 'PERSISTENT_STORAGE_REMOVAL_SELECTION_REQUIRED' }
            [PSCustomObject][ordered]@{
                PersistentStorageId = [string]$item.PersistentStorageId
                Policy = [string]$item.Policy
                DatabaseReferenceIds = @($item.DatabaseReferenceIds | ForEach-Object { [string]$_ })
            }
        }
    )
}

function New-LabPersistentStorageRemovalStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Order,
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Mutation,
        [Parameter(Mandatory)][string]$FailureState,
        [string[]]$Evidence = @()
    )
    [PSCustomObject]@{ Order=$Order; Action=$Action; Mutation=$Mutation; FailureState=$FailureState; Evidence=@($Evidence) }
}

function Get-LabPersistentStorageRemovalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Catalog,
        [Parameter(Mandatory)]$Intent,
        [Parameter(Mandatory)]$ResidencyInventory
    )

    $null = Test-LabPersistentStorageRemovalIntent -Intent $Intent
    $catalogStatus = if ($Catalog.PSObject.Properties['Status']) { [string]$Catalog.Status } else { 'AVAILABLE' }
    $document = if ($Catalog.PSObject.Properties['Document']) { $Catalog.Document } else { $Catalog }
    $issues = [Collections.Generic.List[string]]::new()
    if ($catalogStatus -in @('INVALID','DIVERGED','UNAVAILABLE')) { $issues.Add("CATALOG_$catalogStatus") }
    if ([string]::IsNullOrWhiteSpace([string]$document.ControllerId) -or
        [string]$document.ContractVersion -ne 'SqlServerLab.PersistentStorageCatalog/1.0') {
        $issues.Add('CATALOG_CONTRACT_INVALID')
    }

    $runId = [string]$Intent.RunId
    $storesById = @{}
    foreach ($store in @($document.Stores)) { $storesById[[string]$store.PersistentStorageId] = $store }
    foreach ($selection in @($Intent.Selections)) {
        if (-not $storesById.ContainsKey([string]$selection.PersistentStorageId)) {
            $issues.Add("SELECTION_STORE_NOT_FOUND:$($selection.PersistentStorageId)")
        }
    }

    $catalogedObjectIds = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($store in @($document.Stores)) {
        $binding = $store.LocationBinding
        $matches = if ($binding.InventoryObjectId) {
            @($ResidencyInventory.Objects | Where-Object ObjectId -eq ([string]$binding.InventoryObjectId))
        }
        elseif ($binding.ProviderResourceId) {
            @($ResidencyInventory.Objects | Where-Object {
                [string]$_.Provider -eq [string]$store.Provider -and [string]$_.LogicalName -eq [string]$binding.ProviderResourceId
            })
        }
        else { @() }
        foreach ($match in $matches) { $null = $catalogedObjectIds.Add([string]$match.ObjectId) }
    }
    foreach ($object in @($ResidencyInventory.Objects | Where-Object {
        [string]$_.Lifecycle -eq 'RETAINED' -and $runId -in @($_.RunIds | ForEach-Object { [string]$_ })
    })) {
        if (-not $catalogedObjectIds.Contains([string]$object.ObjectId)) {
            $issues.Add("UNCATALOGED_RETAINED_OBJECT:$($object.ObjectId)")
        }
    }

    $plannedStores = [Collections.Generic.List[object]]::new()
    $runStores = @($document.Stores | Where-Object {
        $runId -eq [string]$_.Lease.RunId -or
        $runId -in @($_.References | Where-Object { $_.Kind -eq 'RUN' -and $_.State -eq 'ACTIVE' } | ForEach-Object { [string]$_.TargetId })
    })
    foreach ($store in $runStores) {
        $storageId = [string]$store.PersistentStorageId
        $selection = @($Intent.Selections | Where-Object PersistentStorageId -eq $storageId) | Select-Object -First 1
        $policy = if ($selection) { [string]$selection.Policy } else { $null }
        $databaseIds = if ($selection) { @($selection.DatabaseReferenceIds | ForEach-Object { [string]$_ }) } else { @() }
        $blockers = [Collections.Generic.List[string]]::new()
        $preconditions = [Collections.Generic.List[string]]::new()
        $steps = [Collections.Generic.List[object]]::new()
        $outcome = 'BLOCKED'; $destructive = $false; $separateDelete = $true

        $foreignRunReferences = @($store.References | Where-Object {
            $_.Kind -eq 'RUN' -and $_.State -eq 'ACTIVE' -and [string]$_.TargetId -ne $runId
        })
        if ($foreignRunReferences.Count -gt 0) { $blockers.Add('FOREIGN_ACTIVE_REFERENCE') }
        if ($store.Lease -and [string]$store.Lease.RunId -ne $runId) { $blockers.Add('LEASE_OWNED_BY_OTHER_RUN') }
        if ([string]$store.State -in @('INCOMPLETE','RECOVERY_REQUIRED','DELETE_PENDING')) { $blockers.Add("STORE_STATE_$($store.State)") }
        if (-not $policy -and [string]$store.StorageClass -notin @('BACKUP_SET','DATABASE_PACKAGE')) { $blockers.Add('POLICY_REQUIRED') }

        $activeDatabaseReferenceIds = @($store.References | Where-Object { $_.Kind -eq 'DATABASE' -and $_.State -eq 'ACTIVE' } | ForEach-Object { [string]$_.ReferenceId })
        if ($databaseIds.Count -gt 0 -and @($databaseIds | Where-Object { $_ -notin $activeDatabaseReferenceIds }).Count -gt 0) {
            $blockers.Add('DATABASE_REFERENCE_NOT_ACTIVE')
        }

        $preconditions.Add('SCOPE_REVALIDATED'); $preconditions.Add('NO_FOREIGN_ACTIVE_REFERENCES')
        $steps.Add((New-LabPersistentStorageRemovalStep -Order 1 -Action 'VERIFY_SCOPE' -Mutation 'NONE' -FailureState 'NONE' -Evidence @('RUN_ID','STORAGE_ID')))
        $steps.Add((New-LabPersistentStorageRemovalStep -Order 2 -Action 'VERIFY_REFERENCES' -Mutation 'NONE' -FailureState 'NONE' -Evidence @('ACTIVE_REFERENCES')))
        if ($store.Lease) {
            $preconditions.Add('LEASE_MATCHES_RUN')
            $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'VERIFY_LEASE' -Mutation 'NONE' -FailureState 'NONE' -Evidence @('LEASE_ID','RUN_ID','SCOPE_ID')))
        }

        switch ($policy) {
            'DELETE_WITH_RUN' {
                if ([string]$store.Retention -ne 'RUN_SCOPED' -or [string]$store.CleanupDisposition -ne 'RUN_CLEANUP') { $blockers.Add('DELETE_WITH_RUN_NOT_ALLOWED') }
                $outcome='DELETE_RUN_RESOURCE'; $destructive=$true; $separateDelete=$false
                $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'DELETE_RUN_RESOURCE' -Mutation 'STORAGE' -FailureState 'RECOVERY_REQUIRED' -Evidence @('SCOPE_POSTCONDITION')))
            }
            'RETAIN_INSTANCE_STORE' {
                if ([string]$store.StorageClass -ne 'INSTANCE_STORE' -or [string]$store.Retention -ne 'RETAINED' -or [string]$store.CleanupDisposition -ne 'PRESERVE') { $blockers.Add('RETAIN_INSTANCE_STORE_NOT_ALLOWED') }
                $outcome='RETAIN_CATALOGED'
                $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'PRESERVE_STORE' -Mutation 'NONE' -FailureState 'NONE' -Evidence @('STORAGE_ID')))
            }
            { $_ -in @('BACKUP_ON_REMOVE','PACKAGE_ON_REMOVE','BACKUP_AND_PACKAGE') } {
                if ([string]$store.StorageClass -ne 'INSTANCE_STORE' -or [string]$store.Retention -ne 'RETAINED') { $blockers.Add('EXPORT_POLICY_NOT_ALLOWED') }
                if ($databaseIds.Count -eq 0) { $blockers.Add('DATABASE_SELECTION_REQUIRED') }
                if ($policy -in @('BACKUP_ON_REMOVE','BACKUP_AND_PACKAGE')) {
                    $preconditions.Add('BACKUP_CHECKSUM'); $preconditions.Add('RESTORE_VERIFYONLY')
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'BACKUP_DATABASES' -Mutation 'SQL' -FailureState 'RECOVERY_REQUIRED' -Evidence @('DATABASE_REFERENCE_IDS')))
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'VERIFY_BACKUP_CHECKSUM' -Mutation 'NONE' -FailureState 'RECOVERY_REQUIRED' -Evidence @('CHECKSUM')))
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'VERIFY_RESTORE' -Mutation 'NONE' -FailureState 'RECOVERY_REQUIRED' -Evidence @('RESTORE_VERIFYONLY')))
                }
                if ($policy -in @('PACKAGE_ON_REMOVE','BACKUP_AND_PACKAGE')) {
                    $preconditions.Add('DATABASE_OFFLINE_OR_DETACHED'); $preconditions.Add('PACKAGE_HASH')
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'OFFLINE_DATABASES' -Mutation 'SQL' -FailureState 'RECOVERY_REQUIRED' -Evidence @('DATABASE_STATE')))
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'MATERIALIZE_PACKAGE' -Mutation 'STORAGE' -FailureState 'RECOVERY_REQUIRED' -Evidence @('FILE_INVENTORY')))
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'HASH_PACKAGE' -Mutation 'NONE' -FailureState 'RECOVERY_REQUIRED' -Evidence @('SHA256')))
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'VERIFY_PACKAGE' -Mutation 'NONE' -FailureState 'RECOVERY_REQUIRED' -Evidence @('PACKAGE_POSTCONDITION')))
                }
                $outcome = switch ($policy) { 'BACKUP_ON_REMOVE' { 'BACKUP_AND_RETAIN' } 'PACKAGE_ON_REMOVE' { 'PACKAGE_AND_RETAIN' } default { 'BACKUP_PACKAGE_AND_RETAIN' } }
            }
            'EXTERNAL_UNMANAGED' {
                if ([string]$store.Provider -ne 'external' -or [string]$store.Retention -ne 'EXTERNAL_UNMANAGED' -or [string]$store.CleanupDisposition -ne 'REPORT_ONLY') { $blockers.Add('EXTERNAL_UNMANAGED_NOT_ALLOWED') }
                $outcome='RELEASE_BINDING_ONLY'
                $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'RELEASE_EXTERNAL_BINDING' -Mutation 'CATALOG' -FailureState 'RECOVERY_REQUIRED' -Evidence @('SOURCE_UNCHANGED')))
            }
            default {
                if ([string]$store.StorageClass -in @('BACKUP_SET','DATABASE_PACKAGE') -and [string]$store.Retention -eq 'RETAINED') {
                    $outcome='RETAIN_CATALOGED'
                    $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'PRESERVE_STORE' -Mutation 'NONE' -FailureState 'NONE' -Evidence @('STORAGE_ID')))
                }
            }
        }

        if ($blockers.Count -eq 0) {
            if ($outcome -in @('RETAIN_CATALOGED','BACKUP_AND_RETAIN','PACKAGE_AND_RETAIN','BACKUP_PACKAGE_AND_RETAIN') -and
                'PRESERVE_STORE' -notin @($steps.Action)) {
                $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'PRESERVE_STORE' -Mutation 'NONE' -FailureState 'NONE' -Evidence @('STORAGE_ID')))
            }
            if ($store.Lease) { $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'RELEASE_LEASE' -Mutation 'CATALOG' -FailureState 'RECOVERY_REQUIRED' -Evidence @('LEASE_RELEASED'))) }
            $steps.Add((New-LabPersistentStorageRemovalStep -Order ($steps.Count + 1) -Action 'RELEASE_RUN_REFERENCE' -Mutation 'CATALOG' -FailureState 'RECOVERY_REQUIRED' -Evidence @('REFERENCE_RELEASED')))
        }
        if ($blockers.Count -gt 0) { $outcome='BLOCKED'; $destructive=$false }
        $plannedStores.Add([PSCustomObject]@{
            PersistentStorageId=$storageId; StorageClass=[string]$store.StorageClass; Provider=[string]$store.Provider
            Policy=$policy; Outcome=$outcome; Destructive=$destructive; RequiresSeparateStorageDelete=$separateDelete
            DatabaseReferenceIds=@($databaseIds | Sort-Object -Unique); Preconditions=@($preconditions | Sort-Object -Unique)
            Steps=@($steps); Blockers=@($blockers | Sort-Object -Unique)
        })
    }

    $storeArray = @($plannedStores)
    $storeBlockerCount = 0
    foreach ($plannedStore in $storeArray) { $storeBlockerCount += @($plannedStore.Blockers).Count }
    $blockerCount = $storeBlockerCount + $issues.Count
    $recoverySteps = @($storeArray.Steps | ForEach-Object { $_ } | Where-Object FailureState -eq 'RECOVERY_REQUIRED').Count
    $executablePolicies = @('RETAIN_INSTANCE_STORE','BACKUP_ON_REMOVE','PACKAGE_ON_REMOVE')
    $plannedPolicies = @($storeArray | Where-Object {
        [string]$_.Policy -and [string]$_.Policy -notin $executablePolicies
    } | ForEach-Object { [string]$_.Policy } | Sort-Object -Unique)
    $executionStatus = if ($blockerCount -gt 0) {
        'BLOCKED'
    }
    elseif ($plannedPolicies.Count -gt 0) {
        'PLANNED_NOT_EXECUTABLE'
    }
    else {
        'EXECUTABLE'
    }
    [PSCustomObject]@{
        ContractVersion='SqlServerLab.PersistentStorageRemovalPlan/1.0'; IntentId=[string]$Intent.IntentId; RunId=$runId
        CatalogRevision=[int]$document.Revision; Status=if ($blockerCount -gt 0) { 'BLOCKED' } else { 'READY' }
        Stores=$storeArray; Issues=@($issues | Sort-Object -Unique)
        Execution=[PSCustomObject]@{
            Status=$executionStatus
            ExecutablePolicies=$executablePolicies
            PlannedPolicies=$plannedPolicies
            Reason=if ($executionStatus -eq 'PLANNED_NOT_EXECUTABLE') {
                'EXECUTOR_CAPABILITY_NOT_IMPLEMENTED'
            }
            elseif ($executionStatus -eq 'BLOCKED') {
                'PLAN_BLOCKED'
            }
            else {
                'READY_FOR_EXECUTION'
            }
        }
        Summary=[PSCustomObject]@{
            StoreCount=$storeArray.Count; DestructiveStoreCount=@($storeArray | Where-Object Destructive).Count
            ProtectedStoreCount=@($storeArray | Where-Object RequiresSeparateStorageDelete).Count
            RecoveryGuardedSteps=$recoverySteps; Blockers=$blockerCount
        }
    }
}
