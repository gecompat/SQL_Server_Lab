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

        # Container via Labels finden und starten (docker/podman)
        $rt = Get-ContainerRuntime
        $errors = 0
        $startedInstances = @()

        $containerIds = if ($rt) { & $rt ps -a -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null } else { $null }
        if (-not $containerIds) {
            Write-LabError '  Keine Container fuer diesen Run gefunden.'
            $errors++
        }
        else {
            @($containerIds) | ForEach-Object {
                $cId = $_.Trim()
                if (-not $cId) { return }
                $cName = (& $rt inspect $cId --format '{{.Name}}' 2>$null).TrimStart('/')
                try {
                    $status = Get-DockerInstanceStatus -ContainerIdOrName $cId
                    if (-not $status.Running) {
                        & $rt start $cId | Out-Null
                        if ($LASTEXITCODE -ne 0) { throw "Container start fehlgeschlagen: $cId" }
                        Write-LabSuccess "  Gestartet: $cName"
                    }
                    else {
                        Write-LabInfo "  Laeuft bereits: $cName"
                    }
                    $startedInstances += [PSCustomObject]@{ containerName = $cName; port = $null }
                }
                catch {
                    Write-LabError "  Fehler bei ${cName}: $_"
                    $errors++
                }
            }
        }

        if ($errors -gt 0 -and $startedInstances.Count -eq 0) {
            Write-LabError 'Kein Container konnte gestartet werden.'
            return [PSCustomObject]@{ RunId = $RunId; Status = 'STOPPED'; Action = 'FAILED'; Errors = $errors }
        }

        # SQL-Readiness pruefen (Port aus connection-info.json)
        if (-not $SkipReadyCheck -and $startedInstances.Count -gt 0) {
            $runDir = Join-Path $stateRoot 'runs' $RunId
            $connInfoPath = Join-Path $runDir 'connection-info.json'
            if (Test-Path $connInfoPath) {
                $connInfo = Get-Content $connInfoPath -Raw | ConvertFrom-Json
                foreach ($inst in $connInfo.instances) {
                    if ($inst.port) {
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
        }

        # State-Transition
        $null = Set-LabRunState -RunId $RunId -NewState 'RUNNING' -Reason 'Start-SqlServerLab' -StateRoot $stateRoot
        Write-LabSuccess "Lab gestartet: ${runPrefix}..."

        return [PSCustomObject]@{ RunId = $RunId; Status = 'RUNNING'; Action = 'STARTED'; Errors = $errors }
    }
}
