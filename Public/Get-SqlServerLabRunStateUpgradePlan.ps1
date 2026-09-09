<#
.SYNOPSIS
    Erstellt einen read-only Upgrade-Plan für einen lokalen Run-State.
.DESCRIPTION
    Klassifiziert einen einzelnen Run-State gegen den aktuellen
    `SqlServerLab.RunState/1.0`-Zielvertrag. Der Plan enthält keine lokalen
    Pfade, Secrets oder Runtimewerte und führt keine Migration aus.
.PARAMETER RunId
    Stabile ID des zu prüfenden Runs.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.OUTPUTS
    SqlServerLab.RunStateUpgradePlan/1.0 mit Upgrade-Status, Änderungen und
    Blockern. `ExecutionImplemented` ist im ersten read-only Slice stets false.
.EXAMPLE
    Get-SqlServerLabRunStateUpgradePlan -RunId '<run-id>'
#>
function Get-SqlServerLabRunStateUpgradePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    return Get-LabRunStateUpgradePlan -RunId $RunId -StateRoot $StateRoot
}