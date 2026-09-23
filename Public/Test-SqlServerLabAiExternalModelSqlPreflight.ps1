<#
.SYNOPSIS
    Prüft den SQL-2025-Zielscope für einen External-Model-Plan schreibgeschützt.
.DESCRIPTION
    Bindet einen noch gültigen SQL-Plan an einen eigenen Docker-/Podman-Run und prüft SQL-Version,
    Datenbankidentität und -zustand, Database Master Key, benötigte Berechtigungen
    sowie freie Credential- und External-Model-Namen. Es wird kein SQL-Objekt verändert.
.PARAMETER SqlPlan
    Ergebnis von Get-SqlServerLabAiExternalModelSqlPlan.
.PARAMETER RunId
    Vorhandener eigener SQL-2025-Docker-/Podman-Run mit verwaltetem SA-Secret.
.PARAMETER InstanceId
    SQL-Instanz, standardmäßig primary.
.PARAMETER StateRoot
    Optionaler lokaler Run-State.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiExternalModelSqlPreflightReceipt/1.0.
.EXAMPLE
    Test-SqlServerLabAiExternalModelSqlPreflight -SqlPlan $sqlPlan -RunId $runId
#>
function Test-SqlServerLabAiExternalModelSqlPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$SqlPlan,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot
    )
    process {
        Invoke-LabAiExternalModelSqlPreflight -SqlPlan $SqlPlan -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    }
}
