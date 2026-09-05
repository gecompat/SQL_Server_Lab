<#
.SYNOPSIS
    Zeigt einen katalogisierten SQL-KI-Szenarioplan.
.DESCRIPTION
    Validiert das Szenariopaket samt Dataset- und Skripthashes und liefert nur
    portable Identitäten, Capability-Status, Blocker und optional die letzte
    sanitisierte Run-Evidence. Lokale Pfade, SQL-Endpunkte und Secrets werden
    nicht ausgegeben.
.PARAMETER ScenarioId
    Stabile ID des katalogisierten Szenarios.
.PARAMETER Version
    Version des Szenariopakets. Standard ist 1.0.
.PARAMETER RunId
    Optionaler Run, gegen den Provider, SQL-Version und persistierter KI-Intent
    geprüft werden.
.PARAMETER InstanceId
    Instanz innerhalb des Runs. Standard ist primary.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.OUTPUTS
    SqlServerLab.AiScenarioPlan/1.0 ohne Runtimepfade oder Zugangsdaten.
.EXAMPLE
    Get-SqlServerLabAiScenario -ScenarioId vector-core-ci
.EXAMPLE
    Get-SqlServerLabAiScenario -ScenarioId vector-core-ci -RunId $runId
#>
function Get-SqlServerLabAiScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$ScenarioId,
        [ValidatePattern('^[1-9][0-9]*\.[0-9]+$')][string]$Version = '1.0',
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [string]$InstanceId = 'primary',
        [string]$StateRoot
    )

    $arguments = @{ScenarioId=$ScenarioId;Version=$Version;InstanceId=$InstanceId}
    if ($RunId) { $arguments.RunId = $RunId }
    if ($StateRoot) { $arguments.StateRoot = $StateRoot }
    $plan = Get-LabAiScenarioPlan @arguments

    return [PSCustomObject]@{
        Contract = $plan.Contract
        ScenarioId = $plan.ScenarioId
        Version = $plan.Version
        Status = $plan.Status
        PlanKey = $plan.PlanKey
        RunId = $plan.RunId
        InstanceId = $plan.InstanceId
        Provider = $plan.Provider
        SqlVersion = $plan.SqlVersion
        RequiredCapabilities = @($plan.RequiredCapabilities)
        ModelBindings = $plan.ModelBindings
        Dataset = $plan.Dataset
        Assertions = @($plan.Assertions)
        Evaluation = $plan.Evaluation
        CleanupMode = $plan.CleanupMode
        Blockers = @($plan.Blockers)
        LastEvidence = $plan.LastEvidence
    }
}
