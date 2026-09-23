<#
.SYNOPSIS
    Beendet ausschließlich einen in dieser Modulsitzung gestarteten OVMS-HTTPS-Gateway.
.DESCRIPTION
    Schließt den Ownerkanal, bestätigt Prozess- und Listenerende und entfernt die
    temporäre API-Key-Datei. Fremde Prozesse und Caller-Zertifikate bleiben unberührt.
.PARAMETER OperationId
    Vom Start zurückgegebene OperationId aus derselben importierten Modulsitzung.
.OUTPUTS
    SqlServerLab.AiOvmsHttpsGatewayCleanup/1.0 mit bestätigtem Cleanupstatus.
#>
function Stop-SqlServerLabOvmsHttpsGateway {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$OperationId)
    if($PSCmdlet.ShouldProcess('owned OVMS HTTPS gateway','Stop')){Stop-LabAiOvmsHttpsGateway -OperationId $OperationId}
}
