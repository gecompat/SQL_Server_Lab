<#
.SYNOPSIS
    Prüft Artefakte und Zertifikate eines gemeinsamen KI-Gateway-Plans read-only.
.DESCRIPTION
    Vergleicht Runtime, Modell, Serverzertifikat, privaten Schlüssel und CA mit
    dem unveränderten Plan. Das sanitiserte Receipt enthält keine lokalen Pfade
    oder Schlüsselwerte und bestätigt weder Dienstbetrieb noch SQL-Anbindung.
.PARAMETER Plan
    Ergebnis von Get-SqlServerLabAiSharedGatewayPlan.
.PARAMETER RuntimePath
    Lokale Runtime-Datei mit dem im Plan gebundenen SHA-256-Digest.
.PARAMETER ModelPath
    Lokale Modelldatei mit dem im Plan gebundenen SHA-256-Digest.
.PARAMETER CertificatePath
    PEM-Datei des gebundenen Serverzertifikats.
.PARAMETER PrivateKeyPath
    PEM-Datei des zum Serverzertifikat gehörenden privaten Schlüssels.
.PARAMETER CertificateAuthorityPath
    PEM-Datei der im Plan gebundenen Zertifizierungsstelle.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiSharedGatewayPreflightReceipt/1.0.
#>
function Test-SqlServerLabAiSharedGatewayPreflight {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$Plan,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$CertificateAuthorityPath
    )
    process{Test-LabAiSharedGatewayPreflight @PSBoundParameters}
}
