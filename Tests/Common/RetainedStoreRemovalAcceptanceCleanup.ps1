# Only the supervisor's fresh synthetic fixture may use this fallback when New
# failed before producing the complete public removal evidence. No catalog repair
# or tombstone is fabricated; the failed test's private state remains for review.
function Assert-RetainedAcceptancePartialStore {
    param($InputObject,$Run,$Store,$Volume)
    if($Run.metadata.workflowOperationId -cne $InputObject.OperationId -or
        $Run.state -cnotin @('REMOVED','CLEANED_UP') -or $Store.Deletion -or
        $Store.Provider -cne $InputObject.Provider -or $Store.StorageClass -cne 'INSTANCE_STORE' -or
        $Store.Retention -cne 'RETAINED' -or $Store.CleanupDisposition -cne 'PRESERVE' -or
        $Store.LocationBinding.Residency -cne 'NATIVE_RUNTIME' -or
        ($Store.Lease -and ($Store.Lease.RunId -cne $Run.runId -or $Store.Lease.ScopeId -cne $Run.scopeId)) -or
        @($Store.References | Where-Object { $_.Kind -ceq 'RUN' -and $_.TargetId -ceq $Run.runId }).Count -ne 1 -or
        @($Store.References | Where-Object { $_.State -ceq 'ACTIVE' -and ($_.Kind -cne 'RUN' -or $_.TargetId -cne $Run.runId) }).Count -gt 0){
        throw 'ACCEPTANCE_PARTIAL_STORE_OWNERSHIP_UNPROVEN'
    }
    if($Volume.Status -ceq 'MISSING'){return}
    if($Volume.Status -cne 'AVAILABLE' -or @($Volume.AttachedContainers).Count -or
        $Volume.VolumeName -cne $Store.LocationBinding.ProviderResourceId -or $Volume.Driver -cne 'local' -or
        ($Volume.Options -and @($Volume.Options.PSObject.Properties).Count) -or
        $Volume.Labels.'sql-server-lab.persistent-storage-id' -cne $Store.PersistentStorageId -or
        $Volume.Labels.'sql-server-lab.run-id' -cne $Run.runId -or
        $Volume.Labels.'sql-server-lab.scope-id' -cne $Run.scopeId -or
        $Volume.Labels.'sql-server-lab.instance-id' -cne 'primary' -or
        $Volume.Labels.'sql-server-lab.sql-major-version' -cne '2025' -or
        $Volume.Labels.'sql-server-lab.persistence' -cnotin @('data-root-runtime-volume','cataloged-runtime-volume') -or
        $Volume.Labels.'sql-server-lab.storage-role') {throw 'ACCEPTANCE_PARTIAL_VOLUME_OWNERSHIP_UNPROVEN'}
    $creationText=if($Volume.CreatedAt -is [datetime]){$Volume.CreatedAt.ToUniversalTime().ToString('o')}else{[string]$Volume.CreatedAt}
    $startText=if($InputObject.CreatedAt -is [datetime]){$InputObject.CreatedAt.ToUniversalTime().ToString('o')}else{[string]$InputObject.CreatedAt}
    $created=[datetimeoffset]::Parse($creationText,[Globalization.CultureInfo]::InvariantCulture)
    $started=[datetimeoffset]::Parse($startText,[Globalization.CultureInfo]::InvariantCulture)
    if($created -lt $started.AddSeconds(-1) -or $created -gt [datetimeoffset]::UtcNow.AddSeconds(1)){
        throw 'ACCEPTANCE_PARTIAL_VOLUME_NOT_FRESH'
    }
}
