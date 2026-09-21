<#
.SYNOPSIS
    Prüft die endgültige Löschung eines eigenen abgetrennten SQL-Instanzspeichers.
.DESCRIPTION
    Read-only Preview für genau eine katalogisierte PersistentStorageId. Nur
    moderne einzelne Docker-/Podman-Datenvolumes mit unveränderter Original-
    Evidence sind zugelassen. Alle enthaltenen Daten gehen bei Apply verloren;
    dieser Plan bestätigt weder ein Backup noch dessen Wiederherstellbarkeit.
.PARAMETER PersistentStorageId
    Stabile UUID des katalogisierten, behaltenen Speichers.
.PARAMETER DataRoot
    Registrierter Lab_Data-Root des controllergebundenen Katalogs.
.PARAMETER StateRoot
    Optionaler Root der ursprünglichen Run-Evidence und Löschjournale.
.OUTPUTS
    PSCustomObject mit ID, Provider, Katalogrevision und gebundenem PlanKey.
#>
function Get-SqlServerLabRetainedStoreRemovalPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)][guid]$PersistentStorageId,
        [Parameter(Mandatory)][string]$DataRoot, [string]$StateRoot)
    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    try {
        $root=Resolve-LabDataRootForUse -DataRoot $DataRoot
        $configuration=Get-LabStorageConfiguration -DataRoot $root
        $plan=Get-LabRetainedStoreRemovalPlan -Configuration $configuration `
            -PersistentStorageId $PersistentStorageId.ToString('D') -StateRoot $StateRoot
        [pscustomobject]@{
            Status='READY'; PersistentStorageId=$plan.PersistentStorageId; Provider=$plan.Provider
            CatalogRevision=$plan.CatalogRevision; PlanKey=$plan.PlanKey
            SqlVersion=$plan.Source.SqlMajorVersion; CatalogedDatabaseReferenceCount=$plan.CatalogedDatabaseReferenceCount
            ContentInventory='OFFLINE_NOT_INSPECTED'
            DataLoss='ALL_STORE_CONTENTS'; BackupStatus='NOT_VERIFIED'
        }
    }
    catch {
        if ($_.Exception.Message -cmatch '^RETAINED_STORE_[A-Z_]+$') { throw $_.Exception.Message }
        throw 'RETAINED_STORE_PREVIEW_UNVERIFIABLE'
    }
}
