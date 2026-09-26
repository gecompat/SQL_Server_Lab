<#
.SYNOPSIS
    Prüft Registrierung, Sessionbesitz und Listenerstatus eines gemeinsamen KI-Gateways.
.DESCRIPTION
    Revalidiert den geschützten Gateway-Store und unterscheidet eine fehlende
    Registrierung, einen registrierten gestoppten Gateway, eine eigene laufende
    Session sowie Recoverybedarf bei Drift, Ownerverlust oder einem fremd belegten
    Port. Die Prüfung startet und stoppt weder Prozesse noch Provider oder SQL Server.
.PARAMETER Plan
    Kanonischer SqlServerLab.AiSharedGatewayPlan/1.0.
.PARAMETER StateRoot
    Optionaler zentraler SQL_Server_Lab-StateRoot mit der Gatewayregistrierung.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiSharedGatewayStatus/1.0-Receipt.
#>
function Get-SqlServerLabAiSharedGatewayStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory,ValueFromPipeline)]$Plan,[string]$StateRoot)
    process {Get-LabAiSharedGatewayStatus @PSBoundParameters}
}
