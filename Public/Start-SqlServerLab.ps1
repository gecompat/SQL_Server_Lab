<#
.SYNOPSIS
    Startet eine gestoppte SQL_Server_Lab-Umgebung.
.DESCRIPTION
    Startet alle Container der Umgebung und wartet optional auf
    SQL-Bereitschaft. Setzt den State auf RUNNING.
.PARAMETER RunId
    Die RunId der zu startenden Umgebung.
.PARAMETER SkipReadyCheck
    SQL-Readiness-Pruefung ueberspringen.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit fuer SQL-Bereitschaft (Default: 60s).
.EXAMPLE
    Start-SqlServerLab -RunId $lab.RunId
.EXAMPLE
    Start-SqlServerLab -RunId $lab.RunId -SkipReadyCheck
#>
function Start-SqlServerLab {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$RunId,
        [switch]$SkipReadyCheck,
        [int]$TimeoutSeconds = 60
    )

    process {
        $stateRoot = Get-LabStateRoot
        $run = Get-LabRunState -RunId $RunId -StateRoot $stateRoot

        # Nur STOPPED darf gestartet werden
        if ($run.state -ne 'STOPPED') {
            Write-LabWarning "Lab '$RunId' ist nicht im Status STOPPED (aktuell: $($run.state)). Nichts zu tun."
            return [PSCustomObject]@{ RunId = $RunId; Status = $run.state; Action = 'SKIPPED' }
        }

        $runPrefix = $RunId.Substring(0, 8)
        Write-LabInfo "Starte Lab ${runPrefix}... ($($run.metadata.name))"

        # Container starten
        $errors = 0
        $startedInstances = @()

        foreach ($inst in $run.instances) {
            if ($inst.containerName) {
                try {
                    $status = Get-DockerInstanceStatus -ContainerIdOrName $inst.containerName
                    if (-not $status.Exists) {
                        Write-LabError "  Container nicht gefunden: $($inst.containerName)"
                        $errors++
                        continue
                    }

                    if (-not $status.Running) {
                        Start-DockerInstance -ContainerIdOrName $inst.containerName
                        Write-LabSuccess "  Gestartet: $($inst.containerName)"
                    }
                    else {
                        Write-LabInfo "  Laeuft bereits: $($inst.containerName)"
                    }
                    $startedInstances += $inst
                }
                catch {
                    Write-LabError "  Fehler bei $($inst.containerName): $_"
                    $errors++
                }
            }
        }

        if ($errors -gt 0 -and $startedInstances.Count -eq 0) {
            Write-LabError 'Kein Container konnte gestartet werden.'
            return [PSCustomObject]@{ RunId = $RunId; Status = 'STOPPED'; Action = 'FAILED'; Errors = $errors }
        }

        # SQL-Readiness pruefen
        if (-not $SkipReadyCheck -and $startedInstances.Count -gt 0) {
            foreach ($inst in $startedInstances) {
                if ($inst.port) {
                    # SA-Passwort aus State lesen
                    $runDir = Join-Path $stateRoot 'runs' $RunId
                    try {
                        $saPassword = Get-LabSecret -Path $runDir -Name 'sa-password'
                        $null = Wait-SqlReady -Port $inst.port -SaPassword $saPassword -TimeoutSeconds $TimeoutSeconds
                    }
                    catch {
                        Write-LabWarning "  SQL-Readiness-Check fehlgeschlagen: $_ (Container laeuft trotzdem)"
                    }
                }
            }
        }

        # State-Transition
        $null = Set-LabRunState -RunId $RunId -NewState 'RUNNING' -Reason 'Start-SqlServerLab' -StateRoot $stateRoot
        Write-LabSuccess "Lab gestartet: ${runPrefix}..."

        return [PSCustomObject]@{ RunId = $RunId; Status = 'RUNNING'; Action = 'STARTED'; Errors = $errors }
    }
}
