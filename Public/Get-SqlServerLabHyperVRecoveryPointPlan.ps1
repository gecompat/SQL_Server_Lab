<#
.SYNOPSIS
    Inventarisiert bestehende, an einen Hyper-V-Run gebundene Recovery Points.
.DESCRIPTION
    Erstellt einen sanitierten read-only Plan für bestehende Hyper-V-Checkpoints.
    Der Plan enthält keine VM-Namen, Hostpfade oder SQL-Verbindungsdaten. Er
    erzeugt keine Checkpoints und führt keine Quiesce- oder Restore-Aktion aus.
.PARAMETER RunId
    Stabile ID des zu prüfenden Hyper-V-Runs.
.PARAMETER InstanceId
    Stabile ID der zu prüfenden Hyper-V-Instanz.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.OUTPUTS
    SqlServerLab.HyperVRecoveryPointPlan/1.0 mit vorhandenen Recovery-Points
    oder einem strukturierten Blocker. `ExecutionImplemented` ist immer false.
.EXAMPLE
    Get-SqlServerLabHyperVRecoveryPointPlan -RunId '<run-id>' -InstanceId 'primary'
#>
function Get-SqlServerLabHyperVRecoveryPointPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [string]$StateRoot
    )

    return Get-LabHyperVRecoveryPointPlan -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
}