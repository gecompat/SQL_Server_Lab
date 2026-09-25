<#
.SYNOPSIS
    Prüft den gebundenen Loopback-Upstream eines gemeinsamen KI-Gateways.
.DESCRIPTION
    Revalidiert zuerst den geschützten gemeinsamen Gateway-Speicher und sendet
    anschließend genau einen synthetischen Embeddingrequest an den im Plan
    gebundenen numerischen Loopback-Endpunkt. Modell, Dimension und endliche
    Vektorwerte werden geprüft. Es werden weder Dienst noch SQL verändert.
.PARAMETER Plan
    Kanonischer Plan von Get-SqlServerLabAiSharedGatewayPlan.
.PARAMETER StateRoot
    Optionaler zentraler SQL_Server_Lab-StateRoot mit der Registrierung.
.PARAMETER ApiKey
    Optionaler flüchtiger Bearer-Schlüssel für den lokalen Upstream.
.PARAMETER TimeoutSeconds
    Begrenztes Requesttimeout zwischen 1 und 300 Sekunden.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiSharedGatewayUpstreamReceipt/1.0.
#>
function Test-SqlServerLabAiSharedGatewayUpstream {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$Plan,
        [string]$StateRoot,
        [SecureString]$ApiKey,
        [ValidateRange(1,300)][int]$TimeoutSeconds=30
    )
    process {
        Test-LabAiSharedGatewayUpstream -Plan $Plan -StateRoot $StateRoot -ApiKey $ApiKey -TimeoutSeconds $TimeoutSeconds
    }
}
