<#
.SYNOPSIS
    Führt ein katalogisiertes SQL-KI-Szenario gegen einen Lab-Run aus.
.DESCRIPTION
    Revalidiert Szenario, Dataset, Skripthashes, SQL-Version, Provider,
    Capabilities und persistierten KI-Intent vor der ersten SQL-Mutation.
    Ausgeführt werden ausschließlich hashgebundene T-SQL-Dateien innerhalb des
    Modul-Roots. Ein lokales Journal wird vor der Mutation angelegt; Cleanup
    und Fehlerstatus bleiben getrennt sichtbar.
.PARAMETER RunId
    Stabile ID des vorhandenen Lab-Runs.
.PARAMETER InstanceId
    Zielinstanz innerhalb des Runs. Standard ist primary.
.PARAMETER ScenarioId
    Stabile ID des katalogisierten Szenarios.
.PARAMETER Version
    Version des Szenariopakets. Standard ist 1.0.
.PARAMETER SaPassword
    Flüchtiges SQL-SA-Kennwort. Es wird weder in Plan noch Journal übernommen.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.PARAMETER Force
    Führt einen bereits erfolgreich abgeschlossenen identischen Plan erneut aus.
.OUTPUTS
    SqlServerLab.AiScenarioResult/1.0 mit PlanKey, Schritt- und Cleanupstatus.
.EXAMPLE
    Invoke-SqlServerLabAiScenario -RunId $runId -ScenarioId vector-core-ci -SaPassword $password
.EXAMPLE
    Invoke-SqlServerLabAiScenario -RunId $runId -ScenarioId vector-core-ci -SaPassword $password -WhatIf
#>
function Invoke-SqlServerLabAiScenario {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [string]$InstanceId = 'primary',
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$ScenarioId,
        [ValidatePattern('^[1-9][0-9]*\.[0-9]+$')][string]$Version = '1.0',
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$StateRoot,
        [switch]$Force
    )

    $planArguments = @{ScenarioId=$ScenarioId;Version=$Version;RunId=$RunId;InstanceId=$InstanceId}
    if ($StateRoot) { $planArguments.StateRoot = $StateRoot }
    $plan = Get-LabAiScenarioPlan @planArguments
    if ($plan.Status -ne 'READY') { throw "AI_SCENARIO_PLAN_BLOCKED: $(@($plan.Blockers) -join ', ')" }

    if (-not $PSCmdlet.ShouldProcess("Run $RunId / Instanz $InstanceId", "KI-Szenario $ScenarioId/$Version ausführen")) {
        return [PSCustomObject]@{
            Contract=[PSCustomObject]@{Name='SqlServerLab.AiScenarioResult';Version='1.0'}
            Status='PLAN_ONLY';RunId=$RunId;InstanceId=$InstanceId;ScenarioId=$ScenarioId;Version=$Version
            PlanKey=$plan.PlanKey;CleanupStatus='NOT_STARTED';Steps=@()
        }
    }

    $arguments = @{
        RunId=$RunId;InstanceId=$InstanceId;ScenarioId=$ScenarioId;Version=$Version
        SaPassword=$SaPassword;Force=$Force
    }
    if ($StateRoot) { $arguments.StateRoot = $StateRoot }
    return Invoke-LabAiScenario @arguments
}
