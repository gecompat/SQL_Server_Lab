<#
.SYNOPSIS
    Prüft einen geplanten HTTPS-Embedding-Endpunkt schreibgeschützt.
.DESCRIPTION
    Sendet genau einen festen synthetischen OpenAI-kompatiblen Embeddingrequest,
    prüft den tatsächlich präsentierten Zertifikatshash, die Vertrauenskette,
    das Antwortformat und die geplante Dimension. Das Ergebnis enthält weder
    Testtext, Embeddingvektor noch API-Key. Runtime-, Modell- und Accelerator-
    Identität bleiben ausdrücklich unbestätigt.
.PARAMETER Plan
    Ergebnis von Get-SqlServerLabAiExternalModelPlan.
.PARAMETER ApiKey
    Optionaler Bearer-Key als SecureString. Er wird nur für den Request geöffnet.
.PARAMETER TrustedRootCertificate
    Optionale Root-CA für eine isolierte Custom-Root-Trust-Prüfung. Ohne Angabe
    muss die normale Systemvertrauenskette gültig sein. Der Host-Truststore wird
    nicht verändert.
.PARAMETER TimeoutSeconds
    Begrenztes Requesttimeout zwischen 1 und 300 Sekunden.
.OUTPUTS
    Sanitierte SqlServerLab.AiExternalModelEndpointReceipt/1.0.
.EXAMPLE
    $plan | Test-SqlServerLabAiExternalModelEndpoint -TrustedRootCertificate $localCa
#>
function Test-SqlServerLabAiExternalModelEndpoint {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$Plan,
        [SecureString]$ApiKey,
        [Security.Cryptography.X509Certificates.X509Certificate2]$TrustedRootCertificate,
        [ValidateRange(1,300)][int]$TimeoutSeconds = 30
    )
    process {
        Invoke-LabAiExternalModelEndpointProbe -Plan $Plan -ApiKey $ApiKey `
            -TrustedRootCertificate $TrustedRootCertificate -TimeoutSeconds $TimeoutSeconds
    }
}
