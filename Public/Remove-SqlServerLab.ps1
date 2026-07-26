<#
.SYNOPSIS
    Entfernt eine SQL-Server-Testumgebung.
.DESCRIPTION
    Scope-gebundenes Entfernen: Prueft Ownership, fuehrt Cleanup-Plan aus,
    entfernt Secrets und State.
.EXAMPLE
    Remove-SqlServerLab -RunId 'abc12345-...'
.EXAMPLE
    Remove-SqlServerLab   # Entfernt den letzten aktiven Run
#>
function Remove-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [string]$RunId,
        [string]$StateRoot,
        [switch]$Force
    )

    $ErrorActionPreference = 'Stop'

    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }

    # Run ermitteln
    if (-not $RunId) {
        $activeRuns = Get-LabActiveRuns -StateRoot $StateRoot
        if ($activeRuns.Count -eq 0) {
            Write-LabInfo 'Keine aktiven Lab-Umgebungen gefunden.'
            return
        }
        if ($activeRuns.Count -eq 1) {
            $RunId = $activeRuns[0].runId
        }
        else {
            Write-LabInfo "$($activeRuns.Count) aktive Umgebungen gefunden:"
            for ($i = 0; $i -lt $activeRuns.Count; $i++) {
                $r = $activeRuns[$i]
                Write-LabStatus -Label "[$($i + 1)]" -Value "$($r.runId.Substring(0,8))... ($($r.state)) - $($r.metadata.name)"
            }
            $choice = Read-LabChoice -Options ($activeRuns | ForEach-Object { "$($_.runId.Substring(0,8))... ($($_.state))" }) `
                -Prompt 'Welche Umgebung entfernen?'
            $RunId = $activeRuns[$choice].runId
        }
    }

    # State laden
    $state = Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $runDir = Join-Path $StateRoot 'runs' $RunId

    Write-LabHeader "Lab entfernen: $($state.metadata.name)"
    Write-LabStatus -Label 'RunId' -Value $RunId
    Write-LabStatus -Label 'ScopeId' -Value $state.scopeId
    Write-LabStatus -Label 'Status' -Value $state.state

    # Bestaetigung (ausser -Force)
    if (-not $Force) {
        $confirm = Read-LabConfirm -Prompt 'Umgebung unwiderruflich entfernen?'
        if (-not $confirm) {
            Write-LabInfo 'Abgebrochen.'
            return
        }
    }

    # State-Transition
    if ($state.state -notin @('CLEANUP_PENDING', 'CLEANUP_RUNNING', 'CLEANED_UP', 'REMOVED')) {
        Set-LabRunState -RunId $RunId -NewState 'CLEANUP_PENDING' -Reason 'Benutzer-Entfernung' -StateRoot $StateRoot
    }

    # Cleanup-Plan ausfuehren
    Write-LabInfo 'Cleanup-Plan ausfuehren...'
    Set-LabRunState -RunId $RunId -NewState 'CLEANUP_RUNNING' -Reason 'Cleanup gestartet' -StateRoot $StateRoot

    $cleanupResult = Invoke-CleanupPlan -RunDir $runDir -ScopeId $state.scopeId

    Write-LabStatus -Label 'Cleanup' -Value "$($cleanupResult.Status) ($($cleanupResult.Steps) Steps, $($cleanupResult.Errors) Fehler)"

    # Auch Container suchen die im Plan fehlen (Sicherheitsnetz)
    $orphans = Get-DockerLabContainers -RunId $RunId
    foreach ($orphan in $orphans) {
        Write-LabWarning "Orphan-Container gefunden: $($orphan.Name)"
        try {
            Remove-DockerInstance -ContainerIdOrName $orphan.ContainerId -ExpectedScopeId $state.scopeId
        }
        catch {
            Write-LabError "Orphan nicht entfernbar: $_"
        }
    }

    # State finalisieren
    Set-LabRunState -RunId $RunId -NewState 'CLEANED_UP' -Reason $cleanupResult.Status -StateRoot $StateRoot
    Set-LabRunState -RunId $RunId -NewState 'REMOVED' -Reason 'Vollstaendig entfernt' -StateRoot $StateRoot

    # Secrets loeschen
    Remove-LabSecrets -Path $runDir

    Write-LabSuccess "Umgebung entfernt: $RunId"

    return [PSCustomObject]@{
        RunId   = $RunId
        Status  = 'REMOVED'
        Cleanup = $cleanupResult.Status
    }
}
