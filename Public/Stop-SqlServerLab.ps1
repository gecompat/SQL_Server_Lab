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
        [int]$TimeoutSeconds = 10,
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

        # Container via Labels finden und stoppen (docker/podman)
        $rt = Get-ContainerRuntime
        $errors = 0
        $containerIds = if ($rt) { & $rt ps -q --filter "label=sql-server-lab.run-id=$RunId" 2>$null } else { $null }
        if (-not $containerIds) {
            Write-LabInfo '  Keine laufenden Container gefunden.'
        }
        else {
            @($containerIds) | ForEach-Object {
                $cId = $_.Trim()
                if (-not $cId) { return }
                $cName = (& $rt inspect $cId --format '{{.Name}}' 2>$null).TrimStart('/')
                try {
                    & $rt stop -t $TimeoutSeconds $cId | Out-Null
                    if ($LASTEXITCODE -ne 0) { throw "Container stop fehlgeschlagen: $cId" }
                    Write-LabSuccess "  Gestoppt: $cName"
                }
                catch {
                    Write-LabError "  Fehler bei ${cName}: $_"
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
