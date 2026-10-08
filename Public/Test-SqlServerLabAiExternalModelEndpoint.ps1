<#
.SYNOPSIS
    Prüft einen geplanten HTTPS-Embedding-Endpunkt schreibgeschützt.
.DESCRIPTION
    Sendet genau einen festen synthetischen OpenAI-kompatiblen Embeddingrequest,
    prüft den tatsächlich präsentierten Zertifikatshash, die Vertrauenskette,
    den Runtime-Modellnamen, das Antwortformat und die geplante Dimension.
    Verbindet im Hostprozess genau eine numerische Loopback-Adresse. Feste
    Hostaliases werden einmal vollständig aufgelöst; leere, missgebildete oder
    nicht ausschließlich lokale Ergebnisse werden vor Schlüsselöffnung
    abgewiesen. IPv4 hat Vorrang, danach entscheidet die numerische Adresse;
    ein zweiter Verbindungsversuch erfolgt nicht. Die tatsächliche Peeradresse
    und der Port müssen vor der Requesterstellung passen. Die ursprüngliche
    HTTPS-Autorität bleibt für TLS und HTTP erhalten; Proxy, Redirect und
    HTTP-Protokollwechsel sind deaktiviert, HTTP/1.1 ist exakt vorgegeben.
    TLS verwendet weiterhin den Systemdefault ohne fixe Version, Downgrade
    oder Retry. Offen bleibt ein Windows-TLS-1.3-Sequenzfehler nach TLS 1.2
    im selben Clientprozess, beobachtet unter .NET 6 und .NET 10. Die native
    Mindestframework-Abnahme ist deshalb nur PARTIAL; Ursache und Zuordnung
    zu einer Produktregression sind UNRESOLVED.
    Das Ergebnis enthält weder Testtext,
    Embeddingvektor noch API-Key. Runtime-
    Binärdatei, Modelldatei und Accelerator-Identität bleiben unbestätigt.
.PARAMETER Plan
    Ergebnis von Get-SqlServerLabAiExternalModelPlan.
.PARAMETER ApiKey
    Optionaler Bearer-Key als SecureString. Er wird nur für den Request geöffnet.
.PARAMETER TrustedRootCertificate
    Optionale Root-CA für eine isolierte Custom-Root-Trust-Prüfung. Ohne Angabe
    muss die normale Systemvertrauenskette gültig sein. Der Host-Truststore wird
    nicht verändert.
.PARAMETER TimeoutSeconds
    Eine gemeinsame kooperative Frist für DNS-Warten, TCP, TLS und die auf
    1 MiB begrenzte Antwort, zwischen 1 und 300 Sekunden. Synchrone native
    Zertifikatskettenprüfung kann nicht zwangsweise unterbrochen werden.
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
