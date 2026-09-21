function Get-LabRetainedStoreHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowNull()]$Value)
    $json=ConvertTo-Json -InputObject $Value -Depth 40 -Compress
    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Get-LabRetainedStoreRecordHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store)
    # State/UpdatedAt/Deletion are the only fields this operation changes.
    $identity=[ordered]@{}
    foreach ($name in @($Store.PSObject.Properties.Name | Where-Object {$_ -cnotin @('State','UpdatedAt','Deletion')} | Sort-Object)) {
        $identity[$name]=$Store.$name
    }
    Get-LabRetainedStoreHash -Value $identity
}

function Get-LabRetainedStoreRecord {
    [CmdletBinding()]
    param($Configuration, [string]$PersistentStorageId)
    $catalog=Get-LabPersistentStorageCatalog -Configuration $Configuration
    if ($catalog.Status -cne 'AVAILABLE') { throw 'RETAINED_STORE_CATALOG_UNAVAILABLE' }
    $stores=@($catalog.Document.Stores | Where-Object PersistentStorageId -CEQ $PersistentStorageId)
    if ($stores.Count -ne 1) { throw 'RETAINED_STORE_ID_UNRESOLVED' }
    $store=$stores[0]
    if ($store.StorageClass -cne 'INSTANCE_STORE' -or $store.Provider -cnotin @('docker','podman') -or
        $store.Retention -cne 'RETAINED' -or $store.CleanupDisposition -cne 'PRESERVE' -or
        $store.LocationBinding.Residency -cne 'NATIVE_RUNTIME' -or $store.LocationBinding.LocationId -or
        $store.LocationBinding.RelativePath -or $store.LocationBinding.ProviderResourceId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$') {
        throw 'RETAINED_STORE_UNSUPPORTED'
    }
    if ($store.Lease -or @($store.References | Where-Object State -CEQ 'ACTIVE').Count) { throw 'RETAINED_STORE_REFERENCED' }
    $duplicates=@($catalog.Document.Stores | Where-Object {
        $_.PersistentStorageId -cne $PersistentStorageId -and $_.Provider -ceq $store.Provider -and
        ($_.LocationBinding.ProviderResourceId -ceq $store.LocationBinding.ProviderResourceId -or
         ($store.LocationBinding.InventoryObjectId -and $_.LocationBinding.InventoryObjectId -ceq $store.LocationBinding.InventoryObjectId))
    })
    if ($duplicates.Count) { throw 'RETAINED_STORE_BINDING_DUPLICATE' }
    [pscustomobject]@{Store=$store; Revision=[int]$catalog.Document.Revision}
}

function Get-LabRetainedStoreObservation {
    [CmdletBinding()]
    param($Store, $Configuration, [string]$StateRoot, $Expected)
    $context=Get-LabRetainedStoreRuntimeContext -Provider $Store.Provider
    if (($Store.RuntimeBinding -and $Store.RuntimeBinding.RuntimeScopeId -cne $context.RuntimeScopeId) -or
        ($Expected -and $Expected.RuntimeScopeId -cne $context.RuntimeScopeId)) { throw 'RETAINED_STORE_RUNTIME_SCOPE_CHANGED' }
    $volume=Get-LabRetainedStoreVolume -Context $context -VolumeName $Store.LocationBinding.ProviderResourceId
    foreach ($sidecar in @(Get-LabContainerInstanceStoreSidecarDefinitions -BaseVolumeName $Store.LocationBinding.ProviderResourceId)) {
        $extra=Get-LabRetainedStoreVolume -Context $context -VolumeName $sidecar.VolumeName
        if ($extra.Status -cne 'MISSING') { throw 'RETAINED_STORE_SIDECARS_UNSUPPORTED' }
    }
    if ($volume.Status -ceq 'MISSING') {
        if (-not $Expected) { throw 'RETAINED_STORE_SOURCE_MISSING' }
        $source=$Expected.Source
    }
    elseif ($volume.Status -ceq 'AVAILABLE') {
        if (@($volume.AttachedContainers).Count) { throw 'RETAINED_STORE_ATTACHED' }
        $labels=$volume.Labels
        if ($labels.'sql-server-lab.storage-role' -and $labels.'sql-server-lab.storage-role' -cne 'DATA') {
            throw 'RETAINED_STORE_SIDECARS_UNSUPPORTED'
        }
        $runId=[string]$labels.'sql-server-lab.run-id'
        $instanceId=[string]$labels.'sql-server-lab.instance-id'
        $parsedId=[guid]::Empty
        if (-not [guid]::TryParseExact($runId,'D',[ref]$parsedId) -or
            $instanceId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$') { throw 'RETAINED_STORE_OWNERSHIP_UNPROVEN' }
        $source=Get-LabContainerStoreRecoverySource -OriginalRunId $runId -InstanceId $instanceId `
            -PersistentStorageId $Store.PersistentStorageId -StateRoot $StateRoot -Configuration $Configuration
        $expectedLabels=[ordered]@{
            'sql-server-lab.persistent-storage-id'=$Store.PersistentStorageId
            'sql-server-lab.run-id'=$source.RunId; 'sql-server-lab.scope-id'=$source.ScopeId
            'sql-server-lab.instance-id'=$source.InstanceId
            'sql-server-lab.sql-major-version'=$source.SqlMajorVersion; 'sql-server-lab.persistence'=$source.Persistence
        }
        foreach ($key in $expectedLabels.Keys) {
            if ([string]$labels.$key -cne [string]$expectedLabels[$key]) { throw 'RETAINED_STORE_LABEL_MISMATCH' }
        }
        $created=[datetimeoffset]::MinValue
        if ($source.Provider -cne $Store.Provider -or $source.VolumeName -cne $volume.VolumeName) { throw 'RETAINED_STORE_VOLUME_BINDING_UNPROVEN' }
        if ($volume.Driver -cne 'local' -or ($volume.Options -and @($volume.Options.PSObject.Properties).Count)) { throw 'RETAINED_STORE_VOLUME_DRIVER_UNSUPPORTED' }
        $creationText=if($volume.CreatedAt -is [datetime]){$volume.CreatedAt.ToUniversalTime().ToString('o')}else{[string]$volume.CreatedAt}
        if (-not [datetimeoffset]::TryParse($creationText,[Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::AssumeUniversal,[ref]$created)) { throw 'RETAINED_STORE_VOLUME_CREATION_UNPROVEN' }
        $fingerprint=Get-LabRetainedStoreHash -Value ([ordered]@{
            Name=$volume.VolumeName; Driver=$volume.Driver; CreatedAt=$created.ToUniversalTime().ToString('o'); Labels=$expectedLabels
        })
        if ($Expected -and $Expected.VolumeFingerprint -cne $fingerprint) { throw 'RETAINED_STORE_VOLUME_REPLACED' }
    }
    else { throw 'RETAINED_STORE_OBSERVATION_UNVERIFIABLE' }
    # Even after a lost successful delete reply, original state must remain bound.
    $freshSource=Get-LabContainerStoreRecoverySource -OriginalRunId $source.RunId -InstanceId $source.InstanceId `
        -PersistentStorageId $Store.PersistentStorageId -StateRoot $StateRoot -Configuration $Configuration
    if (($Expected -and $Expected.Source.EvidenceSha256 -cne $freshSource.EvidenceSha256) -or
        $source.EvidenceSha256 -cne $freshSource.EvidenceSha256) { throw 'RETAINED_STORE_SOURCE_CHANGED' }
    if ($Store.RuntimeBinding.RecoverySource) {
        foreach ($field in @('RunId','ScopeId','InstanceId','SqlMajorVersion','Persistence','EvidenceSha256')) {
            if ([string]$Store.RuntimeBinding.RecoverySource.$field -cne [string]$freshSource.$field) {
                throw 'RETAINED_STORE_RECOVERY_BINDING_CHANGED'
            }
        }
    }
    $scopeAgain=Get-LabRetainedStoreRuntimeContext -Provider $Store.Provider
    if ($scopeAgain.RuntimeScopeId -cne $context.RuntimeScopeId) { throw 'RETAINED_STORE_RUNTIME_SCOPE_CHANGED' }
    # Bound source/sidecar checks can take time. Recheck the selected volume last.
    $last=Get-LabRetainedStoreVolume -Context $context -VolumeName $Store.LocationBinding.ProviderResourceId
    if ($last.Status -cne $volume.Status) { throw 'RETAINED_STORE_OBSERVATION_CHANGED' }
    if ($last.Status -ceq 'AVAILABLE') {
        if (@($last.AttachedContainers).Count) { throw 'RETAINED_STORE_ATTACHED' }
        if ($last.CreatedAt -cne $volume.CreatedAt -or $last.Driver -cne $volume.Driver -or
            (Get-LabRetainedStoreHash $last.Options) -cne (Get-LabRetainedStoreHash $volume.Options) -or
            (Get-LabRetainedStoreHash $last.Labels) -cne (Get-LabRetainedStoreHash $volume.Labels)) {
            throw 'RETAINED_STORE_VOLUME_REPLACED'
        }
    }
    [pscustomobject]@{Status=$volume.Status; Context=$context; Source=$freshSource; VolumeFingerprint=$fingerprint}
}

function Get-LabRetainedStoreRemovalPlan {
    [CmdletBinding()]
    param($Configuration, [string]$PersistentStorageId, [string]$StateRoot)
    $record=Get-LabRetainedStoreRecord -Configuration $Configuration -PersistentStorageId $PersistentStorageId
    $store=$record.Store
    if ($store.State -cne 'DETACHED' -or $store.Deletion) { throw 'RETAINED_STORE_STATE_NOT_DETACHED' }
    $observation=Get-LabRetainedStoreObservation -Store $store -Configuration $Configuration -StateRoot $StateRoot
    $plan=[ordered]@{
        ContractVersion='SqlServerLab.RetainedStoreRemovalPlan/1.0'
        PersistentStorageId=$PersistentStorageId; ControllerId=[string]$Configuration.ControllerId
        CatalogRevision=$record.Revision; Provider=[string]$store.Provider
        CatalogedDatabaseReferenceCount=@($store.References | Where-Object Kind -CEQ 'DATABASE').Count
        RuntimeScopeId=[string]$observation.Context.RuntimeScopeId
        RecordFingerprint=(Get-LabRetainedStoreRecordHash -Store $store)
        VolumeFingerprint=[string]$observation.VolumeFingerprint; Source=$observation.Source
    }
    $plan.PlanKey=Get-LabRetainedStoreHash -Value $plan
    [pscustomobject]$plan
}

function Get-LabRetainedStoreJournalPath {
    [CmdletBinding()]
    param([string]$StateRoot, [guid]$OperationId)
    Join-Path (Join-Path $StateRoot 'retained-store-removals') ($OperationId.ToString('D')+'.json')
}

function Write-LabRetainedStoreJournal {
    [CmdletBinding()]
    param([string]$Path, $Journal)
    $valid=$Journal | ConvertTo-Json -Depth 40 | Test-Json `
        -SchemaFile (Join-Path $script:SchemasPath 'retained-store-removal-journal.schema.json') -ErrorAction Stop
    if (-not $valid) { throw 'RETAINED_STORE_JOURNAL_INVALID' }
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Invoke-LabRetainedStoreRemoval {
    [CmdletBinding()]
    param($Configuration, [string]$PersistentStorageId, [string]$StateRoot,
        [int]$ExpectedRevision=-1, [string]$ExpectedPlanKey, [guid]$OperationId)
    $path=Get-LabRetainedStoreJournalPath -StateRoot $StateRoot -OperationId $OperationId
    $journal=$null
    try {
        # All supported catalog consumers share this lock. DELETE_PENDING also
        # persists the exclusion when this process crashes or the lock is released.
        return Invoke-LabPersistentStorageCatalogLock -ControllerId $Configuration.ControllerId -ScriptBlock {
            if (Test-Path -LiteralPath $path) {
                try {
                    $json=Get-Content -LiteralPath $path -Raw -Encoding utf8 -ErrorAction Stop
                    if (-not ($json | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'retained-store-removal-journal.schema.json') -ErrorAction Stop)) {
                        throw 'INVALID'
                    }
                    $journal=$json | ConvertFrom-Json -Depth 40 -ErrorAction Stop
                }
                catch { throw 'RETAINED_STORE_JOURNAL_INVALID' }
                if ($journal.OperationId -cne $OperationId.ToString('D') -or
                    $journal.Plan.PersistentStorageId -cne $PersistentStorageId -or
                    $journal.Plan.ControllerId -cne $Configuration.ControllerId) { throw 'RETAINED_STORE_OPERATION_MISMATCH' }
                $plan=$journal.Plan
                $keyMaterial=[ordered]@{}
                foreach ($property in $plan.PSObject.Properties) {
                    if ($property.Name -cne 'PlanKey') { $keyMaterial[$property.Name]=$property.Value }
                }
                if ((Get-LabRetainedStoreHash $keyMaterial) -cne $plan.PlanKey) { throw 'RETAINED_STORE_JOURNAL_INVALID' }
            }
            else {
                if (-not $ExpectedPlanKey -or $ExpectedRevision -lt 0) { throw 'RETAINED_STORE_RESUME_JOURNAL_REQUIRED' }
                $plan=Get-LabRetainedStoreRemovalPlan -Configuration $Configuration -PersistentStorageId $PersistentStorageId -StateRoot $StateRoot
                if ($plan.CatalogRevision -ne $ExpectedRevision -or $plan.PlanKey -cne $ExpectedPlanKey) {
                    throw 'RETAINED_STORE_PREVIEW_CHANGED'
                }
                $journal=[pscustomobject]@{
                    ContractVersion='SqlServerLab.RetainedStoreRemovalJournal/1.0'
                    OperationId=$OperationId.ToString('D'); Plan=$plan; Phase='PREPARED'; UpdatedAt=Get-LabTimestamp
                }
                Write-LabRetainedStoreJournal -Path $path -Journal $journal
            }
            $record=Get-LabRetainedStoreRecord -Configuration $Configuration -PersistentStorageId $PersistentStorageId
            if ((Get-LabRetainedStoreRecordHash -Store $record.Store) -cne $plan.RecordFingerprint) {
                throw 'RETAINED_STORE_CATALOG_BINDING_CHANGED'
            }
            if ($record.Store.State -ceq 'DETACHED' -and -not $record.Store.Deletion) {
                if ($record.Revision -ne $plan.CatalogRevision -or $journal.Phase -cne 'PREPARED') { throw 'RETAINED_STORE_RESERVATION_CONFLICT' }
                $fresh=Get-LabRetainedStoreRemovalPlan -Configuration $Configuration -PersistentStorageId $PersistentStorageId -StateRoot $StateRoot
                if ($fresh.PlanKey -cne $plan.PlanKey) { throw 'RETAINED_STORE_PREVIEW_CHANGED' }
                $deletion=[pscustomobject]@{
                    OperationId=$OperationId.ToString('D'); PlanKey=$plan.PlanKey; RuntimeScopeId=$plan.RuntimeScopeId
                    VolumeFingerprint=$plan.VolumeFingerprint; RecordFingerprint=$plan.RecordFingerprint
                    RequestedAt=Get-LabTimestamp; RemovedAt=$null; AbsenceVerifiedAt=$null
                }
                $null=Invoke-LabPersistentStorageCatalogMutation -Configuration $Configuration -ExpectedRevision $record.Revision `
                    -MutationName RESERVE_RETAINED_STORE_REMOVAL -Mutation {
                        param($document)
                        $target=@($document.Stores | Where-Object PersistentStorageId -CEQ $PersistentStorageId)[0]
                        $target.State='DELETE_PENDING'; $target.UpdatedAt=$deletion.RequestedAt
                        $target | Add-Member -NotePropertyName Deletion -NotePropertyValue $deletion
                    }
                $record=Get-LabRetainedStoreRecord -Configuration $Configuration -PersistentStorageId $PersistentStorageId
            }
            $store=$record.Store
            if ($store.State -cnotin @('DELETE_PENDING','REMOVED') -or
                $store.Deletion.OperationId -cne $OperationId.ToString('D') -or $store.Deletion.PlanKey -cne $plan.PlanKey -or
                $store.Deletion.RuntimeScopeId -cne $plan.RuntimeScopeId -or
                $store.Deletion.VolumeFingerprint -cne $plan.VolumeFingerprint -or
                $store.Deletion.RecordFingerprint -cne $plan.RecordFingerprint) { throw 'RETAINED_STORE_RESERVATION_CONFLICT' }
            if ($store.State -ceq 'REMOVED') {
                $terminal=Get-LabRetainedStoreObservation -Store $store -Configuration $Configuration -StateRoot $StateRoot -Expected $plan
                if ($terminal.Status -cne 'MISSING') { throw 'RETAINED_STORE_TERMINAL_RESOURCE_REAPPEARED' }
                if ($journal.Phase -cne 'REMOVED') {
                    $journal.Phase='REMOVED'; $journal.UpdatedAt=Get-LabTimestamp
                    Write-LabRetainedStoreJournal -Path $path -Journal $journal
                }
                return [pscustomobject]@{Status='REMOVED';PersistentStorageId=$PersistentStorageId;OperationId=$OperationId.ToString('D');Reason='NONE'}
            }
            if ($journal.Phase -cne 'DELETE_REQUESTED') {
                # Reject stale recovery evidence before changing even the journal.
                $null=Get-LabRetainedStoreObservation -Store $store -Configuration $Configuration -StateRoot $StateRoot -Expected $plan
                $journal.Phase='DELETE_REQUESTED'; $journal.UpdatedAt=Get-LabTimestamp
                Write-LabRetainedStoreJournal -Path $path -Journal $journal
            }
            $observed=Get-LabRetainedStoreObservation -Store $store -Configuration $Configuration -StateRoot $StateRoot -Expected $plan
            if ($observed.Status -ceq 'AVAILABLE') {
                if ($store.State -ceq 'REMOVED') { throw 'RETAINED_STORE_TERMINAL_RESOURCE_REAPPEARED' }
                # The ownership/attachment observation above is deliberately the
                # last operation before the one non-forced, context-pinned delete.
                Remove-LabRetainedStoreVolume -Context $observed.Context -VolumeName $store.LocationBinding.ProviderResourceId
            }
            $after=Get-LabRetainedStoreObservation -Store $store -Configuration $Configuration -StateRoot $StateRoot -Expected $plan
            if ($after.Status -cne 'MISSING') { throw 'RETAINED_STORE_DELETE_NOT_CONFIRMED' }
            if ($store.State -cne 'REMOVED') {
                $timestamp=Get-LabTimestamp
                $null=Invoke-LabPersistentStorageCatalogMutation -Configuration $Configuration -ExpectedRevision $record.Revision `
                    -MutationName COMPLETE_RETAINED_STORE_REMOVAL -Mutation {
                        param($document)
                        $target=@($document.Stores | Where-Object PersistentStorageId -CEQ $PersistentStorageId)[0]
                        $target.State='REMOVED'; $target.UpdatedAt=$timestamp
                        $target.Deletion.RemovedAt=$timestamp; $target.Deletion.AbsenceVerifiedAt=$timestamp
                    }
            }
            $journal.Phase='REMOVED'; $journal.UpdatedAt=Get-LabTimestamp
            Write-LabRetainedStoreJournal -Path $path -Journal $journal
            [pscustomobject]@{Status='REMOVED'; PersistentStorageId=$PersistentStorageId; OperationId=$OperationId.ToString('D'); Reason='NONE'}
        }
    }
    catch {
        # Never expose provider, host-path or raw catalog writer diagnostics.
        $reason=if($_.Exception.Message -cmatch '^RETAINED_STORE_[A-Z_]+$'){$_.Exception.Message}else{'RETAINED_STORE_OPERATION_UNVERIFIABLE'}
        [pscustomobject]@{
            Status=if(Test-Path -LiteralPath $path){'RECOVERY_REQUIRED'}else{'BLOCKED'}
            PersistentStorageId=$PersistentStorageId; OperationId=$OperationId.ToString('D'); Reason=$reason
        }
    }
}
