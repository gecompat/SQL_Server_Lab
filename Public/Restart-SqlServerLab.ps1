<#
.SYNOPSIS
    Startet eine SQL_Server_Lab-Umgebung neu.
.DESCRIPTION
    Startet Container- oder reguläre Hyper-V-Labs neu. Hyper-V-Labs werden
    durch die delegierenden Start- und Stoppfunktionen nie als Container
    behandelt. Bei Container-Labs wird danach auf SQL-Bereitschaft gewartet.
.PARAMETER RunId
    Die RunId der Umgebung.
.PARAMETER TimeoutSeconds
    Maximale Wartezeit fuer SQL-Bereitschaft nach Neustart (Default: 60s).
.PARAMETER Force
    Ueberspringt Bestaetigungen, einschliesslich der besonderen
    Sicherheitsabfrage fuer einen optional konfigurierten CMS.
.INPUTS
    System.Object. Objekte mit einer RunId-Eigenschaft koennen ueber die
    Pipeline gebunden werden.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Liefert das Ergebnis des
    anschliessenden Startvorgangs oder den uebersprungenen Status.
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
        $run = (Sync-LabRunRuntimeState -Run $run -StateRoot $stateRoot).Run
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
            $stopResult = if ($Force) {
                Stop-SqlServerLab -RunId $RunId -Force
            }
            else {
                Stop-SqlServerLab -RunId $RunId
            }
            if ($stopResult.Action -eq 'CANCELLED') {
                return [PSCustomObject]@{
                    RunId  = $RunId
                    Status = 'RUNNING'
                    Action = 'CANCELLED'
                    Reason = $stopResult.Reason
                }
            }
        }

        # Start + Wait-SqlReady
        $result = Start-SqlServerLab -RunId $RunId -TimeoutSeconds $TimeoutSeconds

        Write-LabSuccess "Lab neugestartet: ${runPrefix}..."
        return $result
    }
}
