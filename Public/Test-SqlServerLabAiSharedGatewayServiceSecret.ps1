<#
.SYNOPSIS
    Prüft Consumer-Schlüssel für einen persistenten Shared-Gateway-Dienst.
.DESCRIPTION
    Löst jede im kanonischen Gatewayplan gebundene Consumer-Referenz ausschließlich
    über PowerShell SecretManagement auf. Prozess-Umgebungsvariablen gelten nicht
    als Neustartnachweis. Werte werden nur im Speicher auf Typ und Gatewayformat
    geprüft und weder ausgegeben noch persistiert. Das Receipt gilt für den im
    Serviceplan gebundenen aktuellen Principal. Ein anderer Benutzer-/Hostkontext
    wird vor dem Vaultzugriff mit AI_SHARED_GATEWAY_SERVICE_PRINCIPAL_MISMATCH
    abgewiesen; der Dienstplan muss dort neu erzeugt werden. Die spätere nichtinteraktive
    Auflösung im echten Service-Logon bleibt eigene Evidence. Der Befehl
    installiert oder startet keinen Dienst.
.PARAMETER Plan
    Kanonischer SqlServerLab.AiSharedGatewayPlan/1.0.
.PARAMETER ServicePlan
    Bereiter und manipulationsgebundener SqlServerLab.AiSharedGatewayServicePlan/1.0.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiSharedGatewayServiceSecretReceipt/1.0.
#>
function Test-SqlServerLabAiSharedGatewayServiceSecret {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory,ValueFromPipeline)]$ServicePlan
    )
    process {Test-LabAiSharedGatewayServiceSecret -Plan $Plan -ServicePlan $ServicePlan}
}
