<#
.SYNOPSIS
    Beendet einen in dieser Modulsitzung gestarteten gemeinsamen KI-Gateway.
.DESCRIPTION
    Schließt ausschließlich den Ownerkanal der angegebenen Operation, bestätigt Prozess-
    und Listenerende und entfernt deren geschützten temporären Zustand. Fremde Prozesse,
    die gemeinsame Registrierung und Zertifikate bleiben unverändert.
.PARAMETER OperationId
    OperationId eines Starts aus derselben importierten Modulsitzung.
.OUTPUTS
    SqlServerLab.AiSharedGatewaySessionCleanup/1.0.
#>
function Stop-SqlServerLabAiSharedGatewaySession {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][ValidatePattern('^[a-f0-9-]{36}$')][string]$OperationId)
    if($PSCmdlet.ShouldProcess($OperationId,'Stop owned shared AI gateway session')){Stop-LabAiSharedGatewaySession -OperationId $OperationId}
}
