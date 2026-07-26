<#
.SYNOPSIS
    Startet eine SQL_Server_Lab-Umgebung neu.
.DESCRIPTION
    Stoppt Container graceful, startet neu und wartet auf SQL-Bereitschaft.
    Nuetzlich nach Konfigurations-Aenderungen oder bei SQL-Problemen.
.PARAMETER RunId
    Die RunId der Umgebung.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit fuer SQL-Bereitschaft nach Neustart (Default: 60s).
.PARAMETER Force
    Keine Bestaetigung abfragen.
.EXAMPLE
    Restart-SqlServerLab -RunId $lab.RunId
#>
function Restart-SqlServerLab {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory, ValueFromPipelineByPropertyName)]
        [string]$RunId,
        [int]$TimeoutSeconds = 60,
        [switch]$Force
    )

    process {
        $stateRoot = Get-LabStateRoot
        $run = Get-LabRunState -RunId $RunId -StateRoot $stateRoot
        $runPrefix = $RunId.Substring(0, 8)

        if ($run.state -notin @('RUNNING', 'STOPPED')) {
            Write-LabWarning "Lab '${runPrefix}...' ist im Status '$($run.state)' - Restart nicht moeglich."
            return [PSCustomObject]@{ RunId = $RunId; Status = $run.state; Action = 'SKIPPED' }
        }

        Write-LabInfo "Restart Lab ${runPrefix}... ($($run.metadata.name))"

        # Bestaetigung
        if (-not $Force -and -not $PSCmdlet.ShouldProcess($RunId, 'Restart')) {
            return [PSCustomObject]@{ RunId = $RunId; Status = $run.state; Action = 'CANCELLED' }
        }

        # Stop (falls laufend)
        if ($run.state -eq 'RUNNING') {
            $null = Stop-SqlServerLab -RunId $RunId -Force
        }

        # Start + Wait-SqlReady
        $result = Start-SqlServerLab -RunId $RunId -TimeoutSeconds $TimeoutSeconds

        Write-LabSuccess "Lab neugestartet: ${runPrefix}..."
        return $result
    }
}
