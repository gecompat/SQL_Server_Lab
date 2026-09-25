<#
.SYNOPSIS
    Startet einen besitzgebundenen, zeitlich begrenzten gemeinsamen KI-Gateway.
.DESCRIPTION
    Revalidiert die geschützte Gatewayregistrierung und den gebundenen Loopback-Upstream,
    bevor ein ausschließlich an 127.0.0.1 gebundener TLS-Worker gestartet wird. Jeder im
    Plan deklarierte Consumer muss genau einen SecureString-Schlüssel bereitstellen.
    Die Sitzung endet beim Schließen des Ownerkanals oder spätestens mit der Lease.
.PARAMETER Plan
    Kanonischer Shared-Gateway-Plan.
.PARAMETER ApiKeyByReference
    Exakte Zuordnung jeder ApiKeyReference des Plans zu einem SecureString.
.PARAMETER StateRoot
    Optionaler zentraler SQL_Server_Lab-StateRoot mit der Registrierung.
.PARAMETER UpstreamApiKey
    Optionaler flüchtiger Bearer-Schlüssel des gebundenen Loopback-Upstreams.
.PARAMETER StartTimeoutSeconds
    Zeitbudget für Revalidierung, Workerstart und HTTPS-Probe.
.PARAMETER LeaseSeconds
    Maximale Laufzeit der ownergebundenen Sitzung, höchstens eine Stunde.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiSharedGatewaySession/1.0-Receipt.
#>
function Start-SqlServerLabAiSharedGatewaySession {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$Plan,
        [Parameter(Mandatory)][hashtable]$ApiKeyByReference,
        [string]$StateRoot,
        [SecureString]$UpstreamApiKey,
        [ValidateRange(1,300)][int]$StartTimeoutSeconds=30,
        [ValidateRange(30,3600)][int]$LeaseSeconds=900
    )
    process {
        if($PSCmdlet.ShouldProcess([string]$Plan.GatewayId,'Start owner-bound shared AI gateway session')){
            $arguments=@{}+$PSBoundParameters;$arguments.Remove('WhatIf');$arguments.Remove('Confirm');Start-LabAiSharedGatewaySession @arguments
        }
    }
}
