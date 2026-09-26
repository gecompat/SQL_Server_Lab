<#
.SYNOPSIS
    Plant den sitzungsunabhängigen Autostart eines gemeinsamen KI-Gateways.
.DESCRIPTION
    Prüft Hostfähigkeit und registrierten Gatewayzustand read-only. Windows wird
    ausschließlich als kennwortloser S4U-Task mit lokalem, nicht EFS-verschlüsseltem
    StateRoot geplant. Linux benötigt einen erreichbaren systemd-Usermanager und
    bereits aktiviertes Linger. Der Befehl installiert, startet oder ändert nichts.
.PARAMETER Plan
    Kanonischer SqlServerLab.AiSharedGatewayPlan/1.0.
.PARAMETER StateRoot
    Optionaler zentraler SQL_Server_Lab-StateRoot mit der Gatewayregistrierung.
.PARAMETER ServiceMode
    Auto wählt ausschließlich die belegte Hostoption. WindowsS4U und SystemdUser
    fixieren die gewünschte Option und liefern bei einem unpassenden Host BLOCKED.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiSharedGatewayServicePlan/1.0.
#>
function Get-SqlServerLabAiSharedGatewayServicePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$Plan,
        [string]$StateRoot,
        [ValidateSet('Auto','WindowsS4U','SystemdUser')][string]$ServiceMode='Auto'
    )
    process {Get-LabAiSharedGatewayServicePlan @PSBoundParameters}
}
