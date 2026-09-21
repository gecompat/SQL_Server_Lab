function Get-LabRetainedStoreRemovalCandidates {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Catalog)
    if ($Catalog.Status -cne 'AVAILABLE') { return }
    foreach ($store in @($Catalog.Document.Stores)) {
        if ($store.StorageClass -cne 'INSTANCE_STORE' -or $store.Provider -cnotin @('docker','podman') -or
            $store.Retention -cne 'RETAINED' -or $store.CleanupDisposition -cne 'PRESERVE' -or
            $store.State -cnotin @('DETACHED','DELETE_PENDING') -or $store.Lease -or
            @($store.References | Where-Object State -CEQ 'ACTIVE').Count) { continue }
        if ($store.State -ceq 'DELETE_PENDING' -and -not $store.Deletion) { continue }
        [pscustomobject]@{
            PersistentStorageId=$store.PersistentStorageId; DisplayName=$store.DisplayName
            Provider=$store.Provider; State=$store.State; OperationId=$store.Deletion.OperationId
        }
    }
}

function Invoke-LabRetainedStoreRemovalInteractive {
    [CmdletBinding()]
    param()
    $dataRoot=Get-LabDataRootDefault
    if (-not $dataRoot) { throw 'RETAINED_STORE_DATA_ROOT_REQUIRED' }
    $configuration=Get-LabStorageConfiguration -DataRoot $dataRoot
    $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
    $candidates=@(Get-LabRetainedStoreRemovalCandidates -Catalog $catalog)
    if (-not $candidates.Count) { Write-LabInfo 'Kein abgetrennter behaltener SQL-Speicher verfügbar.'; return }
    $items=@(foreach($candidate in $candidates){
        New-LabConsoleItem -Id $candidate.PersistentStorageId -Label $candidate.DisplayName `
            -Value "$($candidate.Provider) · $($candidate.State) · $($candidate.PersistentStorageId)"
    })
    $items+=New-LabConsoleItem -Id back -Label 'Zurück' -Shortcut 0
    $selection=Invoke-LabConsoleMenu -ScreenId 'retained-store-removal' -Title 'Behaltenen SQL-Speicher löschen' `
        -Subtitle 'Endgültiger Datenverlust · Backup nicht geprüft' -Items $items
    if ($selection.Cancelled -or $selection.Id -eq 'back') { return }
    $selected=@($candidates | Where-Object PersistentStorageId -CEQ $selection.Id)
    if ($selected.Count -ne 1) { return }
    $arguments=@{PersistentStorageId=$selected[0].PersistentStorageId;DataRoot=$dataRoot}
    if ($selected[0].OperationId) { $arguments.OperationId=$selected[0].OperationId }
    else {
        $plan=Get-SqlServerLabRetainedStoreRemovalPlan @arguments
        $arguments.ExpectedCatalogRevision=$plan.CatalogRevision; $arguments.ExpectedPlanKey=$plan.PlanKey
    }
    Write-LabInfo 'Alle Datenbanken und Serverobjekte dieses Speichers werden endgültig gelöscht. Es wurde kein Backup geprüft.'
    if (-not (Read-LabConfirm -Prompt "Speicher $($selected[0].PersistentStorageId) endgültig löschen?" -Default $false)) { return }
    $result=Invoke-SqlServerLabRetainedStoreRemoval @arguments -Confirm:$false
    Write-LabStatus -Label 'Löschung' -Value $result.Status
    Write-LabInfo "Speicher-ID: $($result.PersistentStorageId) · Vorgang: $($result.OperationId) · $($result.Reason)"
    if ($result.Status -cne 'REMOVED') { throw "RETAINED_STORE_$($result.Status): $($result.OperationId)" }
}
