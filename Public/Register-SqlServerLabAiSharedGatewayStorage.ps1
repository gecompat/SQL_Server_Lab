<#
.SYNOPSIS
    Registriert die gebundenen Dateien eines gemeinsamen KI-Gateways geschützt.
.DESCRIPTION
    Prüft Plan, Runtime, Modell und Zertifikatskette, kopiert sie unter einem
    hostweiten Mutex in den gemeinsamen StateRoot und veröffentlicht den
    vollständigen Zustand atomar. Es werden weder Dienst noch SQL verändert.
.PARAMETER Plan
    Kanonischer Plan von Get-SqlServerLabAiSharedGatewayPlan.
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
.PARAMETER StateRoot
    Optionaler zentraler SQL_Server_Lab-StateRoot für die gemeinsame Ablage.
.OUTPUTS
    Sanitisiertes SqlServerLab.AiSharedGatewayStorageReceipt/1.0.
#>
function Register-SqlServerLabAiSharedGatewayStorage {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory,ValueFromPipeline)]$Plan,
        [Parameter(Mandatory)][string]$RuntimePath,
        [Parameter(Mandatory)][string]$ModelPath,
        [Parameter(Mandatory)][string]$CertificatePath,
        [Parameter(Mandatory)][string]$PrivateKeyPath,
        [Parameter(Mandatory)][string]$CertificateAuthorityPath,
        [string]$StateRoot
    )
    process {
        if($WhatIfPreference){
            Register-LabAiSharedGatewayStorage -Plan $Plan -RuntimePath $RuntimePath -ModelPath $ModelPath `
                -CertificatePath $CertificatePath -PrivateKeyPath $PrivateKeyPath `
                -CertificateAuthorityPath $CertificateAuthorityPath -StateRoot $StateRoot -WhatIf
            $null=$PSCmdlet.ShouldProcess([string]$Plan.GatewayId,'Register protected shared AI gateway storage')
            return
        }
        if(-not $PSCmdlet.ShouldProcess([string]$Plan.GatewayId,'Register protected shared AI gateway storage')){return}
        Register-LabAiSharedGatewayStorage -Plan $Plan -RuntimePath $RuntimePath -ModelPath $ModelPath `
            -CertificatePath $CertificatePath -PrivateKeyPath $PrivateKeyPath `
            -CertificateAuthorityPath $CertificateAuthorityPath -StateRoot $StateRoot
    }
}
