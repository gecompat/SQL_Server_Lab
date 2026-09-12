<#
.SYNOPSIS
    Fuehrt die operationgebundene Backup-Staging- und SQL-Medienvorpruefung aus.
.DESCRIPTION
    Akzeptiert nur explizite DatabaseTransfers. Vor jeder Staging-Mutation
    validiert der Vertrag die komplette Auswahl und die bestehende, laufende
    verwaltete Docker- oder Podman-Zielbindung. HEADERONLY und VERIFYONLY
    pruefen ausschliesslich die temporär im bestehenden Bind-Mount sichtbaren
    Medien; Restore, Datenbankerzeugung und Transferfreigabe erfolgen nicht.
.PARAMETER SourceRunId
    Lauf-ID der bereits verifizierten Backupquelle.
.PARAMETER SourceInstanceId
    Instanz-ID der bereits verifizierten Backupquelle.
.PARAMETER TargetRunId
    Lauf-ID der bestehenden laufenden Docker- oder Podman-Zielinstanz.
.PARAMETER TargetInstanceId
    Instanz-ID der bestehenden laufenden Zielinstanz.
.PARAMETER DatabaseTransfers
    Ausschließlich explizite Objekte mit SourceDatabaseName, TargetDatabaseName und BackupSetId.
.PARAMETER DataRoot
    Lokaler Lab_Data-Root der registrierten Backup-Bibliothek.
.PARAMETER StateRoot
    Optionaler lokaler State-Root für die gebundenen Runs und kurzlebigen Secrets.
.OUTPUTS
    SqlServerLab.PortableContainerTransferPreflightResult/1.0 ohne Pfade, Endpoints, Container-ID, Secrets oder Rohheader.
#>
function Invoke-SqlServerLabPortableContainerTransferPreflight {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
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
    $allowed=$PSCmdlet.ShouldProcess(('operation '+$request.OperationId),'Stage backup media and run SQL media preflight')
    $result=Invoke-LabPortableContainerTransferPreflight -Request $request -DataRoot $DataRoot -StateRoot $StateRoot -MutationAuthorized:$allowed
    $schema=Join-Path $script:SchemasPath 'portable-container-transfer-preflight-result.schema.json';if(-not($result|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema -ErrorAction Stop)){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_RESULT_INVALID'};return $result
}
