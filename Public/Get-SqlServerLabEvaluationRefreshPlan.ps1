<#
.SYNOPSIS
    Plant Ersatz oder Migration einer registrierten SQL-Instanz ohne Ausführung.
.DESCRIPTION
    Liest genau eine moderne Hyper-V-SQL-Instanz unter einem registrierten
    Lab_Data. Windows-Aktivierung bleibt historische Metadaten; SQL-Fristen
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
        [Parameter(Mandatory)][ValidateSet('FREE_SLOT_REPLACEMENT','RECONSTRUCT_LAB','STATEFUL_MIGRATION')][string]$Mode
    )
    New-LabEvaluationRefreshPlan @PSBoundParameters
}
