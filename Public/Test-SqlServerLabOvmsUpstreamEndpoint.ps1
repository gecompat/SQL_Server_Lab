<#
.SYNOPSIS
    Prueft einen lokalen OVMS-Embedding-Upstream schreibgeschuetzt.
.DESCRIPTION
    Sendet genau einen synthetischen OpenAI-kompatiblen Embeddingrequest an
    einen numerischen Loopback-HTTP-Endpunkt mit dem exakten Pfad
    /v3/embeddings. Modellname, Antwortformat, Dimension und endliche
    Vektorwerte werden geprueft. Die Pruefung startet oder veraendert weder OVMS
    noch einen TLS-Gateway und bestaetigt keine Acceleratornutzung.
.PARAMETER Location
    Numerische Loopback-HTTP-URL einschliesslich /v3/embeddings und Port ab 1024.
.PARAMETER RuntimeModel
    Exakter Modellname, den OVMS in der Antwort zurueckgeben muss.
.PARAMETER Dimension
    Erwartete Embeddingdimension zwischen 1 und 1998.
.PARAMETER TimeoutSeconds
    Begrenztes Requesttimeout zwischen 1 und 300 Sekunden.
.OUTPUTS
    Sanitierte SqlServerLab.AiOvmsUpstreamReceipt/1.0.
.EXAMPLE
    Test-SqlServerLabOvmsUpstreamEndpoint -Location 'http://127.0.0.1:9000/v3/embeddings' -RuntimeModel 'OpenVINO/Qwen3-Embedding-0.6B-int8-ov' -Dimension 1024
#>
function Test-SqlServerLabOvmsUpstreamEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Location,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$')][string]$RuntimeModel,
        [Parameter(Mandatory)][ValidateRange(1,1998)][int]$Dimension,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 30
    )

    Invoke-LabAiOvmsUpstreamProbe -Location $Location -RuntimeModel $RuntimeModel `
        -Dimension $Dimension -TimeoutSeconds $TimeoutSeconds
}
