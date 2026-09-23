<#
.SYNOPSIS
    Plant einen vorhandenen lokalen Embedding-Endpunkt für CREATE EXTERNAL MODEL.
.DESCRIPTION
    Liefert einen geheimnisfreien, hashgebundenen SQL-Server-2025-Plan für einen
    vorhandenen OpenAI-kompatiblen HTTPS-Endpunkt. Es werden keine Netzwerkprobe,
    Installation, Trust-, Firewall-, Hosts- oder Dienständerung durchgeführt.
.PARAMETER Backend
    OpenAI-kompatible Inferenzruntime und deren Gerätepfad.
.PARAMETER Accelerator
    Geplantes CPU-, GPU- oder NPU-Ziel. Dies ist noch keine Runtime-Evidence.
.PARAMETER Location
    Vollständige HTTPS-URL von /v1/embeddings oder bei OVMS /v3/embeddings.
.PARAMETER ExternalModelName
    Sicherer T-SQL-Bezeichner für CREATE EXTERNAL MODEL.
.PARAMETER RuntimeModel
    Modellbezeichner, den der OpenAI-kompatible Endpunkt erwartet.
.PARAMETER Dimension
    Erwartete, später live zu bestätigende Embeddingdimension.
.PARAMETER ModelSha256
    SHA-256 der exakt vorgesehenen Modelldatei.
.PARAMETER RuntimeSha256
    SHA-256 der exakt vorgesehenen Serverruntime.
.PARAMETER ServerCertificateSha256
    SHA-256 des für die HTTPS-Verbindung vorgesehenen Serverzertifikats.
.PARAMETER TlsMode
    Direct für Runtime-TLS oder Gateway für einen getrennt gebundenen TLS-Proxy.
.PARAMETER InputProfile
    Rollenabhängige Textvorverarbeitung vor dem Embeddingaufruf.
.PARAMETER GatewayBinding
    Vollständiges Receipt von Start-SqlServerLabOvmsHttpsGateway. Nur für OVMS
    mit TlsMode Gateway; der Plan rechnet dessen Binding-Key erneut nach.
.OUTPUTS
    SqlServerLab.AiExternalModelPlan/1.0 ohne Secretwert oder lokalen Pfad.
.EXAMPLE
    Get-SqlServerLabAiExternalModelPlan -Backend LlamaCppOpenVino -Accelerator NPU -Location https://host.docker.internal:11435/v1/embeddings -ExternalModelName LocalNpuEmbedding -RuntimeModel bound-model -Dimension 768 -ModelSha256 $modelHash -RuntimeSha256 $runtimeHash -ServerCertificateSha256 $certHash
#>
function Get-SqlServerLabAiExternalModelPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('LlamaCppOpenVino','OpenVinoModelServer','LlamaCppRocm','LlamaCppCuda','LlamaCppSnapdragonOpenCl','LlamaCppSnapdragonHexagon')][string]$Backend,
        [Parameter(Mandatory)][ValidateSet('CPU','GPU','NPU')][string]$Accelerator,
        [Parameter(Mandatory)][ValidatePattern('^https://')][string]$Location,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z_][A-Za-z0-9_]{0,127}$')][string]$ExternalModelName,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ModelSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$RuntimeSha256,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$ServerCertificateSha256,
        [ValidateSet('Direct','Gateway')][string]$TlsMode = 'Direct',
        [ValidateSet('raw','nomic-search','snowflake-search')][string]$InputProfile = 'raw',
        [object]$GatewayBinding
    )
    New-LabAiExternalModelPlan @PSBoundParameters
}
