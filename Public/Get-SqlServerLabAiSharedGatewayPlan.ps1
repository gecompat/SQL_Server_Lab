<#
.SYNOPSIS
    Plant einen gemeinsam verwalteten HTTPS-Embedding-Gateway für SQL-KI-Labs.
.DESCRIPTION
    Erzeugt einen geheimnis- und pfadfreien, deterministischen Plan für einen
    persistenten Loopback-Gateway und dessen SQL-Verbraucher. Der aktuelle
    Slice ist ausdrücklich nicht ausführbar und verändert weder Host, Runtime,
    Zertifikate, Secrets noch SQL Server.
.PARAMETER GatewayId
    Stabiler, lokaler Bezeichner des gemeinsam geplanten Gateways.
.PARAMETER Location
    Lokale, von den SQL-Consumern erreichbare HTTPS-Embeddingadresse.
.PARAMETER UpstreamBackend
    Gebundene Runtime- und Beschleunigerfamilie des lokalen Upstreams.
.PARAMETER UpstreamLocation
    Numerische Loopbackadresse des Upstreams mit dessen festem Embeddingpfad.
.PARAMETER RuntimeModel
    Exakter Modellbezeichner, den der Upstream in Antworten liefern muss.
.PARAMETER Dimension
    Erwartete, positive Embeddingdimension.
.PARAMETER InputProfile
    Gebundenes Eingabeprofil für die spätere Requestaufbereitung.
.PARAMETER ModelSha256
    SHA-256-Digest des gebundenen Modellartefakts.
.PARAMETER RuntimeSha256
    SHA-256-Digest der gebundenen Runtime.
.PARAMETER ServerCertificateSha256
    SHA-256-Fingerabdruck des geplanten Gateway-Serverzertifikats.
.PARAMETER CertificateAuthoritySha256
    SHA-256-Fingerabdruck der geplanten vertrauenswürdigen CA.
.PARAMETER Consumer
    Ein bis 64 Verbraucher mit RunId, InstanceId, DatabaseId, ExternalModelName
    und einer jeweils eindeutigen SQL_SERVER_LAB_SECRET_-Referenz.
.OUTPUTS
    SqlServerLab.AiSharedGatewayPlan/1.0 mit einem blockierenden Ausführungsstatus.
#>
function Get-SqlServerLabAiSharedGatewayPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{0,62}$')][string]$GatewayId,
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][ValidateSet('LlamaCppCpu','LlamaCppCuda','LlamaCppOpenVino','LlamaCppRocm','LlamaCppVulkan','LlamaCppSycl','OpenVinoModelServer')][string]$UpstreamBackend,
        [Parameter(Mandatory)][string]$UpstreamLocation,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [ValidateSet('raw','nomic-search','snowflake-search')][string]$InputProfile='raw',
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ModelSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$RuntimeSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ServerCertificateSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$CertificateAuthoritySha256,
        [Parameter(Mandatory)][ValidateCount(1,64)][object[]]$Consumer
    )
    New-LabAiSharedGatewayPlan @PSBoundParameters
}
