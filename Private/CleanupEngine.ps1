<#
.SYNOPSIS
    Cleanup-Engine fuer SQL_Server_Lab.
.DESCRIPTION
    Erstellt maschinenlesbare Cleanup-Plaene vor Mutationen und
    fuehrt Cleanup in umgekehrter Abhaengigkeitsreihenfolge aus.
    Nur eigene Ressourcen (identifiziert durch RunId/ScopeId) werden beruehrt.
#>

# =============================================================================
# Cleanup-Plan
# =============================================================================

function New-CleanupPlan {
    <#
    .SYNOPSIS Erstellt einen Cleanup-Plan fuer einen Run.
    .DESCRIPTION Wird VOR der ersten Mutation geschrieben, damit bei Fehler
                 bekannt ist was zu entfernen waere.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId
    )

    $plan = [PSCustomObject]@{
        runId     = $RunId
        scopeId   = $ScopeId
        createdAt = Get-LabTimestamp
        steps     = @()
        status    = 'PENDING'
    }

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $planPath -Encoding utf8

    return $plan
}

function Add-CleanupStep {
    <#
    .SYNOPSIS Fuegt einen Schritt zum Cleanup-Plan hinzu.
    .DESCRIPTION Jeder Cleanup-Schritt beschreibt eine zu entfernende Ressource
                 mit Kompensationsaktion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$ResourceType,
        [Parameter(Mandatory)][string]$ResourceId,
        [Parameter(Mandatory)][string]$Action,
        [string]$Compensation = '',
        [string[]]$DependsOn = @()
    )

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    $plan = Get-Content $planPath -Raw | ConvertFrom-Json -Depth 10

    $order = $plan.steps.Count + 1
    $step = @{
        order        = $order
        resourceType = $ResourceType
        resourceId   = $ResourceId
        action       = $Action
        compensation = $Compensation
        dependsOn    = $DependsOn
        state        = 'PENDING'
        executedAt   = $null
        error        = $null
    }

    $plan.steps += $step
    $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $planPath -Encoding utf8

    return $step
}

# =============================================================================
# Cleanup-Ausfuehrung
# =============================================================================

function Invoke-CleanupPlan {
    <#
    .SYNOPSIS Fuehrt den Cleanup-Plan in umgekehrter Reihenfolge aus.
    .DESCRIPTION Nur Schritte mit state=PENDING werden ausgefuehrt.
                 Fehler werden protokolliert, blockieren aber nicht den Rest.
    .OUTPUTS PSCustomObject mit Status (CLEANUP_SUCCEEDED/PARTIAL/BLOCKED).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunDir,
        [Parameter(Mandatory)][string]$ScopeId
    )

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    if (-not (Test-Path $planPath)) {
        Write-LabWarning "Kein Cleanup-Plan gefunden."
        return [PSCustomObject]@{ Status = 'CLEANUP_SUCCEEDED'; Steps = 0; Errors = 0 }
    }

    $plan = Get-Content $planPath -Raw | ConvertFrom-Json -Depth 10
    $plan.status = 'EXECUTING'
    $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $planPath -Encoding utf8

    # Schritte in umgekehrter Reihenfolge
    $pendingSteps = @($plan.steps | Where-Object { $_.state -eq 'PENDING' } | Sort-Object order -Descending)

    $errors = 0
    $executed = 0

    foreach ($step in $pendingSteps) {
        Write-LabInfo "Cleanup [$($step.order)]: $($step.action) $($step.resourceType):$($step.resourceId)"

        try {
            switch ($step.resourceType) {
                'container' {
                    Remove-DockerInstance -ContainerIdOrName $step.resourceId -ExpectedScopeId $ScopeId
                }
                'volume' {
                    docker volume rm $step.resourceId 2>&1 | Out-Null
                }
                'network' {
                    docker network rm $step.resourceId 2>&1 | Out-Null
                }
                default {
                    Write-LabWarning "Unbekannter Ressourcentyp: $($step.resourceType)"
                }
            }

            $step.state = 'COMPLETED'
            $step.executedAt = Get-LabTimestamp
            $executed++
            Write-LabSuccess "  Entfernt: $($step.resourceId)"
        }
        catch {
            $step.state = 'FAILED'
            $step.error = $_.ToString()
            $step.executedAt = Get-LabTimestamp
            $errors++
            Write-LabError "  Fehlgeschlagen: $($step.resourceId) - $_"
        }
    }

    # Status aktualisieren
    $plan.status = if ($errors -eq 0) { 'COMPLETED' } else { 'PARTIAL' }
    $plan | ConvertTo-Json -Depth 10 | Set-Content -Path $planPath -Encoding utf8

    $overallStatus = if ($errors -eq 0) { 'CLEANUP_SUCCEEDED' }
                     elseif ($executed -gt 0) { 'CLEANUP_PARTIAL' }
                     else { 'CLEANUP_BLOCKED' }

    return [PSCustomObject]@{
        Status   = $overallStatus
        Steps    = $executed
        Errors   = $errors
        Total    = $pendingSteps.Count
    }
}

function Get-CleanupPlan {
    <#
    .SYNOPSIS Liest den aktuellen Cleanup-Plan eines Runs.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDir)

    $planPath = Join-Path $RunDir 'cleanup-plan.json'
    if (-not (Test-Path $planPath)) { return $null }
    Get-Content $planPath -Raw | ConvertFrom-Json -Depth 10
}
