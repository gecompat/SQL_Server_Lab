function Assert-LabContainerStoreRuntimeScope {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Provider, [AllowNull()]$RuntimeBinding)
    if (-not $RuntimeBinding) { return }
    $scope=Get-LabContainerRuntimeScope -Provider $Provider
    if ([string]$scope.Status -cne 'AVAILABLE' -or
        [string]$RuntimeBinding.RuntimeScopeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$' -or
        [string]$scope.RuntimeId -cne [string]$RuntimeBinding.RuntimeScopeId) {
        throw 'CONTAINER_STORE_RUNTIME_SCOPE_CHANGED'
    }
}

function Test-LabContainerInstanceStoreRuntimeBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Store, [Parameter(Mandatory)]$RuntimeInspection)
    if (-not $Store.RuntimeBinding) { return $true }
    try { Assert-LabContainerStoreRuntimeScope -Provider $Store.Provider -RuntimeBinding $Store.RuntimeBinding }
    catch { return $false }
    $source=$Store.RuntimeBinding.RecoverySource
    if (-not $source) { return $true }
    return [string]$RuntimeInspection.Provider -ceq [string]$Store.Provider -and
        [string]$RuntimeInspection.VolumeName -ceq [string]$Store.LocationBinding.ProviderResourceId -and
        [string]$RuntimeInspection.Labels.'sql-server-lab.persistent-storage-id' -ceq [string]$Store.PersistentStorageId -and
        [string]$RuntimeInspection.Labels.'sql-server-lab.run-id' -ceq [string]$source.RunId -and
        [string]$RuntimeInspection.Labels.'sql-server-lab.scope-id' -ceq [string]$source.ScopeId -and
        [string]$RuntimeInspection.Labels.'sql-server-lab.instance-id' -ceq [string]$source.InstanceId -and
        [string]$RuntimeInspection.Labels.'sql-server-lab.sql-major-version' -ceq [string]$source.SqlMajorVersion -and
        [string]$RuntimeInspection.Labels.'sql-server-lab.persistence' -ceq [string]$source.Persistence
}

function Get-LabContainerStoreRecoverySource {
    [CmdletBinding()]
    param([string]$OriginalRunId, [string]$InstanceId, [string]$PersistentStorageId,
        [string]$StateRoot, [Parameter(Mandatory)]$Configuration)
    $directory=Join-Path (Join-Path $StateRoot 'runs') $OriginalRunId
    $statePath=Join-Path $directory 'run-state.json'
    $connectionPath=Join-Path $directory 'connection-info.json'
    $stateJson=Get-Content -LiteralPath $statePath -Raw -Encoding utf8 -ErrorAction Stop
    $connectionJson=Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8 -ErrorAction Stop
    $run=$stateJson | ConvertFrom-Json -Depth 30
    $ControllerId=[string]$Configuration.ControllerId
    $ownedRoots=@($Configuration.LabDataLocations | Where-Object { [string]::Equals([string]$_.LabDataRoot,[string]$run.metadata.dataRoot,[StringComparison]::OrdinalIgnoreCase) })
    if ($run.metadata.persistentData -isnot [bool] -or -not $run.metadata.persistentData -or $ownedRoots.Count -ne 1 -or
        -not (Test-LabDataRootOwnership -DataRoot ([string]$run.metadata.dataRoot) -ControllerId $ControllerId)) { throw 'RECOVER_CONTAINER_STORE_CONTROLLER_EVIDENCE_INVALID' }
    if ([string]$run.runId -cne $OriginalRunId -or [string]$run.scopeId -notmatch '^[0-9a-fA-F-]{36}$' -or
        [string]$run.state -cnotin @('REMOVED','CLEANED_UP')) { throw 'RECOVER_CONTAINER_STORE_RUN_STATE_INVALID' }
    $desired=Get-LabPersistedDesiredState -RunId $OriginalRunId -StateRoot $StateRoot
    if ($desired.Status -cne 'VALID' -or $desired.Snapshot.PersistentData -isnot [bool] -or
        -not $desired.Snapshot.PersistentData) { throw 'RECOVER_CONTAINER_STORE_DESIRED_STATE_INVALID' }
    $instances=@($desired.Snapshot.Instances | Where-Object { $_.Id -ceq $InstanceId })
    if ($instances.Count -ne 1 -or $instances[0].Provider -cnotin @('docker','podman')) { throw 'RECOVER_CONTAINER_STORE_INSTANCE_UNRESOLVED' }
    $instance=$instances[0]
    $drives=@($instance.Intents.Drives | Where-Object { $_.Id -ceq 'persistent-mssql' -and
        $_.Persistence -cin @('data-root-runtime-volume','cataloged-runtime-volume') })
    if ($drives.Count -ne 1 -or [string]$drives[0].PersistentStorageId -cne $PersistentStorageId) { throw 'RECOVER_CONTAINER_STORE_DESIRED_BINDING_INVALID' }
    if (@($instance.Intents.Drives | Where-Object { $_.Id -match 'external-(languages|libraries)$' }).Count -gt 0) { throw 'RECOVER_CONTAINER_STORE_SIDECARS_UNSUPPORTED' }
    $connection=$connectionJson | ConvertFrom-Json -Depth 30
    $connections=@($connection.instances | Where-Object { $_.id -ceq $InstanceId })
    if ([string]$connection.runId -cne $OriginalRunId -or [string]$connection.scopeId -cne [string]$run.scopeId -or $connections.Count -ne 1) { throw 'RECOVER_CONTAINER_STORE_CONNECTION_EVIDENCE_INVALID' }
    $ci=$connections[0]; $storage=$ci.persistentStorage
    if ([string]$ci.provider -cne [string]$instance.Provider -or [string]$ci.version -cne [string]$instance.Version -or
        [string]$ci.containerId -cnotmatch '^[a-f0-9]{64}$' -or
        [string]$storage.persistentStorageId -cne $PersistentStorageId -or [string]$storage.mode -cne [string]$drives[0].Persistence -or
        [string]$storage.containerVolume -cnotmatch '^[A-Za-z0-9][A-Za-z0-9_.-]{0,254}$') { throw 'RECOVER_CONTAINER_STORE_CONNECTION_EVIDENCE_INVALID' }
    if (@($ci.externalRuntime | Where-Object { $_ }).Count -gt 0) { throw 'RECOVER_CONTAINER_STORE_SIDECARS_UNSUPPORTED' }
    # Bind every original byte; changing unrelated evidence also invalidates this preview.
    if ($stateJson -cne (Get-Content -LiteralPath $statePath -Raw -Encoding utf8) -or
        $connectionJson -cne (Get-Content -LiteralPath $connectionPath -Raw -Encoding utf8)) { throw 'RECOVER_CONTAINER_STORE_SOURCE_CHANGED' }
    $material=@($ControllerId,$stateJson,$connectionJson) | ConvertTo-Json -Compress
    $hash=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($material))).ToLowerInvariant()
    [pscustomobject]@{Provider=[string]$instance.Provider;VolumeName=[string]$storage.containerVolume;PersistentStorageId=$PersistentStorageId;
        RunId=$OriginalRunId;ScopeId=[string]$run.scopeId;InstanceId=$InstanceId;SqlMajorVersion=([string]$instance.Version).Substring(0,4);
        Persistence=[string]$drives[0].Persistence;EvidenceSha256=$hash;DisplayName="$($desired.Snapshot.LabName) / $InstanceId / SQL $($instance.Version)"}
}

function Repair-LabContainerStoreCatalog {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Source, [string]$StateRoot, [string]$RuntimeScopeId,
        [Parameter(Mandatory)]$Configuration, [int]$ExpectedRevision=-1, [switch]$Preview)
    $readSource=${function:Get-LabContainerStoreRecoverySource}
    $inspect=${function:Get-LabContainerInstanceStoreRuntimeInspection}
    $checkBinding=${function:Test-LabContainerInstanceStoreRuntimeBinding}
    $getObjectId=${function:Get-LabStorageResidencyObjectId}
    $timestamp=Get-LabTimestamp
    $mutation={
        param($Document)
        $current=& $readSource -OriginalRunId $Source.RunId -InstanceId $Source.InstanceId -PersistentStorageId $Source.PersistentStorageId -StateRoot $StateRoot -Configuration $Configuration
        if ($current.EvidenceSha256 -cne $Source.EvidenceSha256) { throw 'RECOVER_CONTAINER_STORE_SOURCE_CHANGED' }
        $binding=[pscustomobject]@{RuntimeScopeId=$RuntimeScopeId;ObservedAt=$timestamp;RecoverySource=[pscustomobject]@{
            RunId=$current.RunId;ScopeId=$current.ScopeId;InstanceId=$current.InstanceId;SqlMajorVersion=$current.SqlMajorVersion;Persistence=$current.Persistence;EvidenceSha256=$current.EvidenceSha256}}
        $objectId=& $getObjectId -Key "runtime-volume|$($current.Provider)|$($current.VolumeName)"
        $store=[pscustomobject][ordered]@{
            PersistentStorageId=$current.PersistentStorageId;DisplayName=$current.DisplayName;StorageClass='INSTANCE_STORE';State='DETACHED';Provider=$current.Provider;
            LocationBinding=[pscustomobject]@{Residency='NATIVE_RUNTIME';LocationId=$null;ProviderResourceId=$current.VolumeName;InventoryObjectId=$objectId;RelativePath=$null};
            RuntimeBinding=$binding;References=@([pscustomobject]@{ReferenceId=$current.RunId;Kind='RUN';State='RELEASED';TargetId=$current.RunId});
            Lease=$null;Retention='RETAINED';CleanupDisposition='PRESERVE';CreatedAt=$timestamp;UpdatedAt=$timestamp}
        $runtime=& $inspect -Provider $current.Provider -VolumeName $current.VolumeName
        if ($runtime.Status -cne 'AVAILABLE' -or @($runtime.AttachedContainers).Count -ne 0 -or -not (& $checkBinding -Store $store -RuntimeInspection $runtime)) { throw 'RECOVER_CONTAINER_STORE_RUNTIME_OWNERSHIP_INVALID' }
        foreach ($suffix in @('-external-languages','-external-libraries')) {
            $sidecar=& $inspect -Provider $current.Provider -VolumeName ($current.VolumeName+$suffix) -RequireMissingEvidence
            if ($sidecar.Status -cne 'MISSING') { throw 'RECOVER_CONTAINER_STORE_SIDECARS_UNSUPPORTED' }
        }
        $matches=@($Document.Stores | Where-Object { $_.PersistentStorageId -eq $current.PersistentStorageId -or
            ($_.Provider -eq $current.Provider -and ($_.LocationBinding.ProviderResourceId -eq $current.VolumeName -or $_.LocationBinding.InventoryObjectId -eq $objectId)) })
        if ($matches.Count -gt 1) { throw 'RECOVER_CONTAINER_STORE_BINDING_CONFLICT' }
        if ($matches.Count -eq 1) {
            $existing=$matches[0]
            if ($existing.PersistentStorageId -cne $current.PersistentStorageId -or $existing.State -cne 'DETACHED' -or $existing.Lease -or
                $existing.StorageClass -cne 'INSTANCE_STORE' -or $existing.Provider -cne $current.Provider -or $existing.Retention -cne 'RETAINED' -or $existing.CleanupDisposition -cne 'PRESERVE' -or
                @($existing.References | Where-Object State -eq 'ACTIVE').Count -gt 0 -or
                ($existing.LocationBinding | ConvertTo-Json -Compress) -cne ($store.LocationBinding | ConvertTo-Json -Compress) -or
                $existing.RuntimeBinding.RuntimeScopeId -cne $RuntimeScopeId -or
                ($existing.RuntimeBinding.RecoverySource | ConvertTo-Json -Compress) -cne ($binding.RecoverySource | ConvertTo-Json -Compress)) { throw 'RECOVER_CONTAINER_STORE_BINDING_CONFLICT' }
            return $current.PersistentStorageId
        }
        $finalRuntime=& $inspect -Provider $current.Provider -VolumeName $current.VolumeName
        if ($finalRuntime.Status -cne 'AVAILABLE' -or @($finalRuntime.AttachedContainers).Count -ne 0 -or
            -not (& $checkBinding -Store $store -RuntimeInspection $finalRuntime)) { throw 'RECOVER_CONTAINER_STORE_RUNTIME_OWNERSHIP_INVALID' }
        $last=& $readSource -OriginalRunId $Source.RunId -InstanceId $Source.InstanceId -PersistentStorageId $Source.PersistentStorageId -StateRoot $StateRoot -Configuration $Configuration
        if ($last.EvidenceSha256 -cne $Source.EvidenceSha256) { throw 'RECOVER_CONTAINER_STORE_SOURCE_CHANGED' }
        $Document.Stores=@($Document.Stores)+@($store)
        $current.PersistentStorageId
    }.GetNewClosure()
    $transaction=Invoke-LabPersistentStorageCatalogMutation -Configuration $Configuration -MutationName RECOVER_CONTAINER_STORE -Mutation $mutation -ExpectedRevision $ExpectedRevision -Preview:$Preview
    [pscustomobject]@{Changed=$transaction.Changed;CatalogRevision=$transaction.CatalogRevision;ProposedRevision=$transaction.ProposedRevision;
        Store=@($transaction.Document.Stores | Where-Object PersistentStorageId -eq $Source.PersistentStorageId)[0]}
}
