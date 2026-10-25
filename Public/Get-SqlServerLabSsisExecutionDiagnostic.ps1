<#
.SYNOPSIS
    Beobachtet den SSISDB-Ausführungskontext eines bestehenden eigenen SQL-2025-Runs.
.DESCRIPTION
    Bindet Katalogdatenbankkennung, Execution-ID und Projekt-LSN an denselben
    laufenden Hyper-V-Gast. Liest ausschließlich feste SQL-Metadaten, bekannte
    SSIS-Dateien, Registrierungen und einen gegebenenfalls noch laufenden
    ISServerExec-Prozess. Kein Paketstart, Deployment, Setup oder Reparatureingriff.
    Die Beobachtung ist kein Nachweis erfolgreicher Komponentenaktivierung.
.PARAMETER RunId
    Bereits laufender eigener Windows-/Hyper-V-/SQL-2025-Run.
.PARAMETER InstanceId
    Gespeicherte SQL-Instanz, standardmäßig primary.
.PARAMETER ExecutionId
    Exakte eigene SSISDB-Execution-ID aus der Consumer-Receipt.
.PARAMETER ExpectedProjectLsn
    Zugehörige Projektversionskennung aus derselben Receipt.
.PARAMETER ExpectedCatalogDatabaseGuid
    Erwartete SSISDB-Datenbankkennung; verhindert die Adoption eines anderen Katalogs.
.PARAMETER StateRoot
    Bereits konfigurierter lokaler StateRoot.
.PARAMETER TimeoutSeconds
    Frist des einmaligen Gastaufrufs, 10 bis 120 Sekunden.
.EXAMPLE
    Get-SqlServerLabSsisExecutionDiagnostic -RunId $runId -ExecutionId $receipt.ExecutionId -ExpectedProjectLsn $receipt.ProjectLsn -ExpectedCatalogDatabaseGuid $receipt.CatalogDatabaseGuid
.OUTPUTS
    SqlServerLab.SsisExecutionDiagnostic/1.0 ohne Secrets, Pfade, Konten oder Meldungstexte.
#>
function Get-SqlServerLabSsisExecutionDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$ExecutionId,
        [Parameter(Mandatory)][ValidateRange(1,[long]::MaxValue)][long]$ExpectedProjectLsn,
        [Parameter(Mandatory)][guid]$ExpectedCatalogDatabaseGuid,
        [string]$StateRoot=(Get-LabStateRoot),
        [ValidateRange(10,120)][int]$TimeoutSeconds=60
    )
    if(-not (Test-LabSsisWindowsHost)){throw 'SSIS_EXECUTION_DIAGNOSTIC_WINDOWS_HOST_REQUIRED'}
    if($RunId -eq [guid]::Empty -or $ExpectedCatalogDatabaseGuid -eq [guid]::Empty){throw 'SSIS_EXECUTION_DIAGNOSTIC_INPUT_INVALID'}
    Invoke-LabSsisExecutionDiagnostic -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -ExecutionId $ExecutionId -ExpectedProjectLsn $ExpectedProjectLsn -ExpectedCatalogDatabaseGuid $ExpectedCatalogDatabaseGuid -TimeoutSeconds $TimeoutSeconds
}
