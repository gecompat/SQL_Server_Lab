<#
.SYNOPSIS
    Startet einen eigenen zeitlich begrenzten HTTPS-Gateway vor einem lokalen OVMS-Endpunkt.
.DESCRIPTION
    Verifiziert zuerst den festen numerischen IPv4-Loopback-Upstream und startet dann
    einen ausschließlich an 127.0.0.1 gebundenen TLS-Proxy. Request und Response werden
    auf einen einzelnen OpenAI-kompatiblen Embeddingvertrag rekonstruiert. Ownerverlust
    und Lease-Ende schließen den Listener; es werden keine Zertifikatsbindungen angelegt.
.PARAMETER UpstreamLocation
    Exakter HTTP-Endpunkt auf numerischem IPv4-Loopback und `/v3/embeddings`.
.PARAMETER RuntimeModel
    Exakter Modellname, den Request und OVMS-Antwort tragen müssen.
.PARAMETER Dimension
    Erwartete Anzahl endlicher float32-kompatibler Vektorwerte.
.PARAMETER Port
    Freier nicht privilegierter IPv4-Loopback-Port des HTTPS-Gateways.
.PARAMETER CertificatePath
    Caller-eigenes PEM-Leaf-Zertifikat mit SAN für 127.0.0.1.
.PARAMETER PrivateKeyPath
    Passender caller-eigener PEM-Key; er wird weder kopiert noch entfernt.
.PARAMETER ApiKey
    SecureString aus 24 bis 256 ASCII-Buchstaben, Ziffern, `_` oder `-`.
.PARAMETER TrustedRootPath
    Optionales CA-PEM, das ausschließlich für die Startprobe vertraut wird.
.PARAMETER StartTimeoutSeconds
    Zeitbudget für Upstream-, Listener- und HTTPS-Probe.
.PARAMETER LeaseSeconds
    Maximale Gesamtlaufzeit einschließlich Startphase, höchstens eine Stunde.
.OUTPUTS
    SqlServerLab.AiOvmsHttpsGateway/1.0 ohne Secret- oder lokale Dateipfade.
#>
function Start-SqlServerLabOvmsHttpsGateway {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$UpstreamLocation,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [Parameter(Mandatory)][ValidateRange(1024,65535)][int]$Port,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][SecureString]$ApiKey,
        [string]$TrustedRootPath,
        [ValidateRange(1,300)][int]$StartTimeoutSeconds=30,
        [ValidateRange(30,3600)][int]$LeaseSeconds=900
    )
    if($PSCmdlet.ShouldProcess('owned OVMS HTTPS gateway','Start')){$arguments=@{}+$PSBoundParameters;$arguments.Remove('WhatIf');$arguments.Remove('Confirm');Start-LabAiOvmsHttpsGateway @arguments}
}
