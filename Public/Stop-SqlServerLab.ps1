<#
.SYNOPSIS
    Stoppt eine laufende SQL_Server_Lab-Umgebung.
.DESCRIPTION
    Stoppt alle Container der Umgebung graceful (SIGTERM + Timeout)
    und setzt den State auf STOPPED. Daten bleiben erhalten.
.PARAMETER RunId
    Die RunId der zu stoppenden Umgebung.
.PARAMETER TimeoutSeconds
    Graceful-Shutdown-Timeout fuer Docker (Default: 30s).
.PARAMETER Force
    Keine Bestaetigung abfragen.
.EXAMPLE
    Stop-SqlServerLab -RunId $lab.RunId
.EXAMPLE
    Get-SqlServerLab | Stop-SqlServerLab -Force
#>
function Stop-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$RunId,
        [int]$TimeoutSeconds = 30,
        [switch]$Force
    )

    process {
        $stateRoot = Get-LabStateRoot
        $run = Get-LabRunState -RunId $RunId -StateRoot $stateRoot

        # Nur RUNNING darf gestoppt werden
        if ($run.state -ne 'RUNNING') {
            Write-LabWarning "Lab '$RunId' ist nicht im Status RUNNING (aktuell: $($run.state)). Nichts zu tun."
            return [PSCustomObject]@{ RunId = $RunId; Status = $run.state; Action = 'SKIPPED' }
        }

        $runPrefix = $RunId.Substring(0, 8)
        Write-LabInfo "Stoppe Lab ${runPrefix}... ($($run.metadata.name))"

        # Bestaetigung
        if (-not $Force -and -not $PSCmdlet.ShouldProcess($RunId, 'Stop')) {
            return [PSCustomObject]@{ RunId = $RunId; Status = 'RUNNING'; Action = 'CANCELLED' }
        }

        # Container stoppen
        $errors = 0
        foreach ($inst in $run.instances) {
            if ($inst.containerName) {
                try {
                    $status = Get-DockerInstanceStatus -ContainerIdOrName $inst.containerName
                    if ($status.Running) {
                        Stop-DockerInstance -ContainerIdOrName $inst.containerName -TimeoutSeconds $TimeoutSeconds
                        Write-LabSuccess "  Gestoppt: $($inst.containerName)"
                    }
                    else {
                        Write-LabInfo "  Bereits gestoppt: $($inst.containerName)"
                    }
                }
                catch {
                    Write-LabError "  Fehler bei $($inst.containerName): $_"
                    $errors++
                }
            }
        }

        # State-Transition
        if ($errors -eq 0) {
            $null = Set-LabRunState -RunId $RunId -NewState 'STOPPED' -Reason 'Stop-SqlServerLab' -StateRoot $stateRoot
            Write-LabSuccess "Lab gestoppt: ${runPrefix}..."
            return [PSCustomObject]@{ RunId = $RunId; Status = 'STOPPED'; Action = 'STOPPED' }
        }
        else {
            Write-LabWarning "Lab gestoppt mit $errors Fehler(n)"
            return [PSCustomObject]@{ RunId = $RunId; Status = 'STOPPED_WITH_ERRORS'; Action = 'PARTIAL'; Errors = $errors }
        }
    }
}
