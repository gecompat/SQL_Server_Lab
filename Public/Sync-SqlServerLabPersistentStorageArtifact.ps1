<#
.SYNOPSIS
    Synchronisiert ein vorhandenes Backup oder Datenbankpaket mit dem persistenten Storage-Katalog.
.DESCRIPTION
    Revalidiert genau ein katalogisiertes BackupSetId oder DatabasePackageId
    vollständig und registriert dessen stabile Artefaktbindung idempotent im
    controllergebundenen Persistent-Storage-Katalog. Vor der Mutation läuft
    derselbe Bindungs- und Konfliktcheck im Preview-Modus. Abweichende,
    mehrdeutige oder unzulässige Bindungen werden fail-closed abgelehnt.

    Das Cmdlet verändert weder SQL Server noch Docker-, Podman- oder Hyper-V-
    Ressourcen. Die Ausgabe enthält keine lokalen Pfade, Endpunkte oder Secrets.
.PARAMETER BackupSetId
    Stabile ID eines vorhandenen Eintrags der Backup-Bibliothek.
.PARAMETER DatabasePackageId
    Stabile ID eines vorhandenen Eintrags der Datenbankpaket-Bibliothek.
.PARAMETER DataRoot
    Optionaler registrierter Lab_Data-Root. Ohne Angabe gilt der konfigurierte Standard.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Ein
    SqlServerLab.PersistentStorageArtifactSyncResult/1.0.
.EXAMPLE
    Sync-SqlServerLabPersistentStorageArtifact -BackupSetId $backupSetId -WhatIf
.EXAMPLE
    Sync-SqlServerLabPersistentStorageArtifact -DatabasePackageId $databasePackageId -Confirm:$false
#>
function Sync-SqlServerLabPersistentStorageArtifact {
    [CmdletBinding(DefaultParameterSetName='BackupSet', SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory, ParameterSetName='BackupSet')]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$BackupSetId,

        [Parameter(Mandatory, ParameterSetName='DatabasePackage')]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$DatabasePackageId,

        [string]$DataRoot
    )

    if (-not $DataRoot) { $DataRoot = Get-LabDataRootDefault }
    if (-not $DataRoot) { throw 'PERSISTENT_STORAGE_ARTIFACT_SYNC_DATA_ROOT_REQUIRED' }
    $DataRoot = Resolve-LabDataRootForUse -DataRoot $DataRoot

    if ($PSCmdlet.ParameterSetName -eq 'BackupSet') {
        $artifactType = 'BACKUP_SET'
        $artifactId = $BackupSetId
        $artifact = Get-LabDatabaseBackup -BackupSetId $BackupSetId -DataRoot $DataRoot
        $preview = Register-LabBackupSetPersistentStorage -BackupRecord $artifact.Record -DataRoot $DataRoot -Preview
    }
    else {
        $artifactType = 'DATABASE_PACKAGE'
        $artifactId = $DatabasePackageId
        $artifact = Get-LabDatabasePackage -DatabasePackageId $DatabasePackageId -DataRoot $DataRoot
        $preview = Register-LabDatabasePackagePersistentStorage -PackageRecord $artifact.Record -DataRoot $DataRoot -Preview
    }

    if (-not [bool]$preview.Changed) {
        $result = [PSCustomObject][ordered]@{
            ContractVersion='SqlServerLab.PersistentStorageArtifactSyncResult/1.0'
            Status='NO_CHANGE'; ArtifactType=$artifactType; ArtifactId=$artifactId
            Changed=$false; WouldChange=$false
            PersistentStorageId=[string]$preview.Store.PersistentStorageId
            CatalogRevision=[int]$preview.CatalogRevision
        }
    }
    elseif (-not $PSCmdlet.ShouldProcess("$artifactType/$artifactId", 'mit dem persistenten Storage-Katalog synchronisieren')) {
        $result = [PSCustomObject][ordered]@{
            ContractVersion='SqlServerLab.PersistentStorageArtifactSyncResult/1.0'
            Status=if ($WhatIfPreference) { 'PLANNED' } else { 'CANCELLED' }
            ArtifactType=$artifactType; ArtifactId=$artifactId
            Changed=$false; WouldChange=$true
            PersistentStorageId=if ($preview.Store) { [string]$preview.Store.PersistentStorageId } else { $null }
            CatalogRevision=[int]$preview.CatalogRevision
        }
    }
    else {
        $synchronized = if ($artifactType -eq 'BACKUP_SET') {
            $artifact = Get-LabDatabaseBackup -BackupSetId $BackupSetId -DataRoot $DataRoot
            Register-LabBackupSetPersistentStorage -BackupRecord $artifact.Record -DataRoot $DataRoot
        }
        else {
            $artifact = Get-LabDatabasePackage -DatabasePackageId $DatabasePackageId -DataRoot $DataRoot
            Register-LabDatabasePackagePersistentStorage -PackageRecord $artifact.Record -DataRoot $DataRoot
        }
        $result = [PSCustomObject][ordered]@{
            ContractVersion='SqlServerLab.PersistentStorageArtifactSyncResult/1.0'
            Status=if ([bool]$synchronized.Changed) { 'SYNCED' } else { 'NO_CHANGE' }
            ArtifactType=$artifactType; ArtifactId=$artifactId
            Changed=[bool]$synchronized.Changed; WouldChange=[bool]$synchronized.Changed
            PersistentStorageId=[string]$synchronized.Store.PersistentStorageId
            CatalogRevision=[int]$synchronized.CatalogRevision
        }
    }

    $schemaPath = Join-Path $script:SchemasPath 'persistent-storage-artifact-sync-result.schema.json'
    try {
        $valid = $result | ConvertTo-Json -Depth 10 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch { throw "PERSISTENT_STORAGE_ARTIFACT_SYNC_RESULT_INVALID: $($_.Exception.Message)" }
    if (-not $valid) { throw 'PERSISTENT_STORAGE_ARTIFACT_SYNC_RESULT_INVALID' }
    return $result
}
