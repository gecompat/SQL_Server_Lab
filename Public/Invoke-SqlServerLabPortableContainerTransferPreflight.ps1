<#
.SYNOPSIS
    Fuehrt die eng begrenzte Backup-Staging- und SQL-Medienvorpruefung aus.
.DESCRIPTION
    Die Funktion akzeptiert nur eine explizite DatabaseTransfers-Auswahl. Sie
    verwendet ausschliesslich einen bestehenden laufenden verwalteten Docker-
    oder Podman-Zielcontainer mit live verifiziertem persistent-backups
    Bind-Mount nach /var/opt/mssql/backup. Die Vorpruefung kopiert Backups nur
    in einen operationseigenen temporaeren Bereich und fuehrt HEADERONLY sowie
    VERIFYONLY WITH CHECKSUM, STOP_ON_ERROR aus. Sie erstellt keine Datenbank,
    fuehrt keinen Restore aus und gibt keinen Transfer frei.
.PARAMETER SourceRunId
    Lauf-ID der bereits verifizierten Backupquelle.
.PARAMETER SourceInstanceId
    Instanz-ID der bereits verifizierten Backupquelle.
.PARAMETER TargetRunId
    Lauf-ID der bestehenden laufenden Docker- oder Podman-Zielinstanz.
.PARAMETER TargetInstanceId
    Instanz-ID des Ziels.
.PARAMETER DatabaseTransfers
    Ausschließlich explizite Objekte mit SourceDatabaseName, TargetDatabaseName und BackupSetId.
.PARAMETER DataRoot
    Lokaler Lab_Data-Root der registrierten Backup-Bibliothek.
.PARAMETER StateRoot
    Optionaler lokaler State-Root für die gebundenen Runs und kurzlebigen Secrets.
.OUTPUTS
    SqlServerLab.PortableContainerTransferPreflightResult/1.0. Das Ergebnis
    projiziert keine Pfade, Credentials oder Rohheader und gibt keinen Transfer frei.
#>
function Invoke-SqlServerLabPortableContainerTransferPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$SourceRunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$SourceInstanceId,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$TargetRunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$TargetInstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][object[]]$DatabaseTransfers,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$DataRoot,
        [string]$StateRoot
    )
    $request=New-LabPortableContainerTransferPreflightRequest -SourceRunId $SourceRunId -SourceInstanceId $SourceInstanceId -TargetRunId $TargetRunId -TargetInstanceId $TargetInstanceId -DatabaseTransfers $DatabaseTransfers
    $result=Invoke-LabPortableContainerTransferPreflight -Request $request -DataRoot $DataRoot -StateRoot $StateRoot
    $schema=Join-Path $script:SchemasPath 'portable-container-transfer-preflight-result.schema.json'
    if(-not ($result|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema -ErrorAction Stop)) { throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_RESULT_INVALID' }
    return $result
}
