<#
.SYNOPSIS
    Veröffentlicht eine sauber offline geschaltete Container-Datenbank als Paket.
.DESCRIPTION
    Exportiert ausschließlich eine über RunId und InstanceId gebundene Docker-
    oder Podman-Datenbank. Der gemeinsame Container-Core revalidiert die live
    ermittelte Verbindung, schaltet die Quelle exklusiv offline, inventarisiert
    nur die von SQL Server gemeldeten MDF/NDF/LDF-Dateien und veröffentlicht sie
    erst nach vollständiger Objekt- und Manifest-SHA-256-Prüfung. Das Paket wird
    atomar unter seiner stabilen DatabasePackageId katalogisiert.

    FILESTREAM und TDE ohne eigenständigen Recovery-Key-Vertrag bleiben vor der
    Offline-Mutation gesperrt. Freie Container-, Host- oder Zielpfade sind kein
    Teil dieses Befehls.
.PARAMETER RunId
    Stabile ID des laufenden verwalteten Container-Runs.
.PARAMETER InstanceId
    Stabile ID der Containerinstanz innerhalb des Runs.
.PARAMETER DatabaseName
    Name der zu exportierenden Benutzerdatenbank.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.PARAMETER DataRoot
    Optionaler registrierter Lab_Data-Root für die Paketbibliothek.
.OUTPUTS
    Sanitisierter Status mit stabiler DatabasePackageId und PersistentStorageId.
.EXAMPLE
    Export-SqlServerLabDatabasePackage -RunId $runId -InstanceId primary -DatabaseName Schulung
#>
function Export-SqlServerLabDatabasePackage {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,127}$')][string]$InstanceId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [string]$StateRoot,
        [string]$DataRoot
    )

    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    if (-not $DataRoot) { $DataRoot=Get-LabDataRootDefault }
    if (-not $DataRoot) { throw 'DATABASE_PACKAGE_DATA_ROOT_REQUIRED' }
    $DataRoot=Resolve-LabDataRootForUse -DataRoot $DataRoot

    $context=Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    if ([string]$context.Provider -notin @('docker','podman')) { throw 'DATABASE_PACKAGE_CONTAINER_PROVIDER_NOT_SUPPORTED' }
    if (-not [bool]$context.WasRunning) { throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_NOT_RUNNING' }

    if (-not $PSCmdlet.ShouldProcess("$RunId/$InstanceId/$DatabaseName", 'Datenbank exklusiv offline schalten und verifiziertes Paket veröffentlichen')) {
        return [PSCustomObject][ordered]@{
            ContractVersion='SqlServerLab.DatabasePackageExportResult/1.0'
            Status='PLANNED'
            RunId=$RunId
            InstanceId=$InstanceId
            DatabaseName=$DatabaseName
            Provider=[string]$context.Provider
            DatabasePackageId=$null
            PersistentStorageId=$null
        }
    }

    $published=Export-LabContainerDatabasePackage -RunId $RunId -InstanceId $InstanceId -DatabaseName $DatabaseName -DataRoot $DataRoot -StateRoot $StateRoot
    [PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.DatabasePackageExportResult/1.0'
        Status=[string]$published.Status
        RunId=$RunId
        InstanceId=$InstanceId
        DatabaseName=$DatabaseName
        Provider=[string]$context.Provider
        DatabasePackageId=[string]$published.DatabasePackageId
        PersistentStorageId=[string]$published.PersistentStorageId
    }
}
