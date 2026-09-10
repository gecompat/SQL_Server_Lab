<#
.SYNOPSIS
    Migriert einen ausdrücklich markierten synthetischen Legacy-Run-State.
.DESCRIPTION
    Revalidiert den read-only Upgrade-Plan direkt vor der Mutation. Nur ein
    unversionierter State mit `metadata.syntheticStateFixture=true` darf
    migriert werden. Die ursprüngliche Revision und ein Journal bleiben im
    Run-Verzeichnis; der Commit ist atomar, und ein Fehler stellt den
    Ausgangszustand wieder her. Provider- oder Runtime-Ressourcen werden nie
    verändert.
.PARAMETER RunId
    Stabile ID des zu migrierenden lokalen Run-States.
.PARAMETER StateRoot
    Optionaler lokaler State-Root.
.OUTPUTS
    SqlServerLab.RunStateUpgradeResult/1.0 ohne lokale Pfade oder Secrets.
.EXAMPLE
    Invoke-SqlServerLabRunStateUpgrade -RunId $runId -WhatIf
#>
function Invoke-SqlServerLabRunStateUpgrade {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [string]$StateRoot
    )

    $arguments = @{ RunId = $RunId }
    if ($StateRoot) { $arguments.StateRoot = $StateRoot }
    $plan = Get-LabRunStateUpgradePlan @arguments
    if ($plan.Status -ne 'READY') { return Invoke-LabRunStateUpgrade @arguments }
    if (-not $PSCmdlet.ShouldProcess("Run-State $RunId", 'synthetischen Legacy-State atomar migrieren')) {
        return [PSCustomObject]@{
            ContractVersion = 'SqlServerLab.RunStateUpgradeResult/1.0'; RunId = $plan.RunId; PlanId = $plan.PlanId
            Status = 'PLAN_ONLY'; SourceStateSha256 = $plan.SourceStateSha256; TargetContractVersion = $plan.TargetContractVersion
            RollbackStatus = 'NOT_STARTED'; Blockers = @()
        }
    }
    return Invoke-LabRunStateUpgrade @arguments
}
