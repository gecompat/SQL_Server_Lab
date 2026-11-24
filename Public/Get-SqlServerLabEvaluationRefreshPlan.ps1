<#
.SYNOPSIS
    Plant Ersatz oder Migration einer registrierten SQL-Instanz ohne Ausführung.
.DESCRIPTION
    Liest eine moderne Hyper-V-SQL-Quellinstanz und optional die Metadaten
    eines separaten Ziellabs unter demselben registrierten Lab_Data.
    Windows-Aktivierung bleibt historische Metadaten. SQL-Fristen
    stammen ausschließlich aus dem bestehenden gebundenen Gast-Receipt.
    Alle drei Entscheidungsarten bleiben BLOCKED, ohne Aktionen, Persistenz,
    Zielübernahme, Lizenzfreigabe oder Gleichwertigkeitsbehauptung.
.PARAMETER RunId
    Vorhandene Run-ID. Keine globale Run-Suche oder Adoption.
.PARAMETER InstanceId
    Genau eine vorhandene SQL-Instanz des Runs.
.PARAMETER DataRoot
    Explizites registriertes Lab_Data. StateRoot wird ausschließlich daraus abgeleitet.
.PARAMETER Mode
    FREE_SLOT_REPLACEMENT, RECONSTRUCT_LAB oder STATEFUL_MIGRATION.
.PARAMETER ObserveSqlSource
    Erfasst bei STATEFUL_MIGRATION zusätzlich aggregierte SQL-Quellzähler einer
    laufenden, gebundenen SQL-2025-Prepared-Instanz. Keine Persistenz.
.PARAMETER ObserveWindowsLicense
    Liest zusätzlich den Windows-Lizenzstatus der laufenden gebundenen VM.
    Die registrierte Historie bleibt getrennt. Die Abfrage aktiviert und
    speichert keine Lizenz.
.PARAMETER TargetRunId
    Optionales registriertes SQL-2025-Ziellab unter demselben Lab_Data.
    Für STATEFUL_MIGRATION wird seine Metadatenbindung separat vorgeprüft.
.PARAMETER TargetInstanceId
    Instanz-ID des mit TargetRunId gewählten separaten Ziellabs.
.PARAMETER ObserveTargetWindowsLicense
    Liest in STATEFUL_MIGRATION ausdrücklich die Windows-Lizenz der gebundenen
    laufenden Ziel-VM. Die historische Quelle, SQL-Bereitschaft und die
    Transferfreigabe werden dadurch nicht verändert.
.PARAMETER ObserveTargetSqlReadiness
    Prüft in STATEFUL_MIGRATION ausdrücklich mit einer lesenden Gastabfrage,
    ob die erwartete SQL-Instanz im laufenden Ziellab antwortet. Der Befund
    bleibt flüchtig und gibt weder SQL-Lizenz, Speicher noch Transfer frei.
.PARAMETER ObserveTargetStorage
    Liest freien Speicher für die Standardpfade Daten, Log und Backup in der
    laufenden gebundenen Ziel-VM. Gemeinsame Volumes werden nur einmal gezeigt.
    Der Befund bestätigt weder Hostkapazität noch ausreichenden Transferspeicher.
.OUTPUTS
    SqlServerLab.EvaluationRefreshPlan/1.0; strikt nicht ausführbar.
.EXAMPLE
    Get-SqlServerLabEvaluationRefreshPlan -RunId $runId -InstanceId primary `
        -DataRoot $dataRoot -Mode STATEFUL_MIGRATION
#>
function Get-SqlServerLabEvaluationRefreshPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')][string]$RunId,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$InstanceId,
        [Parameter(Mandatory)][ValidateLength(1,2048)][string]$DataRoot,
        [Parameter(Mandatory)][ValidateSet('FREE_SLOT_REPLACEMENT','RECONSTRUCT_LAB','STATEFUL_MIGRATION')][string]$Mode,
        [switch]$ObserveSqlSource,
        [switch]$ObserveWindowsLicense,
        [ValidatePattern('^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$')][string]$TargetRunId,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$TargetInstanceId,
        [switch]$ObserveTargetWindowsLicense,
        [switch]$ObserveTargetSqlReadiness,
        [switch]$ObserveTargetStorage
    )
    New-LabEvaluationRefreshPlan @PSBoundParameters
}
