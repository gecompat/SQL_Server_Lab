<#
.SYNOPSIS
    Entfernt ein von SQL_Server_Lab erstelltes SQL External Model sicher.
.DESCRIPTION
    Bindet SQL-Plan und Apply-Receipt erneut an den eigenen Run und entfernt nur
    bei exakt passendem SQL-Ownership-Receipt zuerst External Model, danach
    Credential und Ownership-Tabelle in einer Transaktion. Unbekannte oder
    partielle Zustände werden nicht weiter verändert.
.PARAMETER SqlPlan
    Unveränderter Plan des zuvor ausgeführten SQL-Apply.
.PARAMETER ApplyReceipt
    Passendes Ergebnis von Invoke-SqlServerLabAiExternalModelSqlApply.
.PARAMETER RunId
    Eigener SQL-2025-Docker-, Podman- oder Hyper-V-Run. Hyper-V wird vor dem
    Cleanup erneut über die VMId revalidiert.
.PARAMETER InstanceId
    SQL-Instanz, standardmäßig primary.
.PARAMETER StateRoot
    Optionaler lokaler Run-State.
.PARAMETER Resume
    Beobachtet und beendet einen zuvor journalisierten Cleanup-Ausgang.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiExternalModelSqlCleanupReceipt/1.0.
#>
function Remove-SqlServerLabAiExternalModelSql {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$SqlPlan,
        [Parameter(Mandatory)]$ApplyReceipt,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$RunId,
        [ValidatePattern('^[a-zA-Z][a-zA-Z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot,
        [switch]$Resume
    )
    if($PSCmdlet.ShouldProcess("Run $RunId / Instanz $InstanceId / Datenbank $($SqlPlan.DatabaseName)",'Eigenes SQL External Model, Credential und Ownership-Receipt entfernen')){
        $arguments=@{SqlPlan=$SqlPlan;ApplyReceipt=$ApplyReceipt;RunId=$RunId;InstanceId=$InstanceId;Resume=$Resume}
        if($PSBoundParameters.ContainsKey('StateRoot')){$arguments.StateRoot=$StateRoot}
        Invoke-LabAiExternalModelSqlCleanup @arguments
    }
}
