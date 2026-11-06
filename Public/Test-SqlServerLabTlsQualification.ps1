#Requires -Version 7.2
function Test-SqlServerLabTlsQualification {
    <#
    .SYNOPSIS
        Prueft die authentifizierte TLS-Verbindung eines eigenen operativen Labs aktuell.
    .DESCRIPTION
        Verlangt Windows mit PowerShell 7.5+, den aktuellen registrierten
        Client-/Trustkontext und einen eigenen Docker-/Podman-TLS-Run mit
        SQL 2019 CU32, 2022 CU27 oder 2025 CU9 oder einen eigenen Windows-/Hyper-V-
        TLS-Run mit SQL 2025 RTM. Beide echten Clientstacks
        verbinden strikt und pruefen SQL-Build sowie Transportverschluesselung.
        Ziel, Runtime, Zertifikat, Client, Registry und Trust werden frisch
        gebunden. Fehler fuehren weder zu True noch zu einem anderen Ziel.
        Das Ergebnis enthaelt keine Credentials, Endpoints, Pfade oder Digests.
        Es beschreibt den Beobachtungszeitpunkt, reserviert keine Runtime und
        wird nicht gespeichert. Vor spaeterer Verwendung erneut pruefen;
        Bindungsdrift invalidiert den Nachweis auch vor ExpiresAtUtc.
        Der Befehl erstellt keinen Export und veraendert keine Zertifikate,
        Keys, Truststores, SQL-Konfiguration oder gespeicherte TLS-Bindung.
    .PARAMETER RunId
        Exakte RunId des eigenen operativen TLS-Labs.
    .PARAMETER InstanceId
        Exakte SQL-Instanz dieses Runs.
    .PARAMETER StateRoot
        Ausdruecklich zurueckgegebener privater StateRoot dieses TLS-Labs.
    .EXAMPLE
        Test-SqlServerLabTlsQualification -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot
    .OUTPUTS
        SqlServerLab.TlsLiveQualificationResult/0.1 mit Status,
        Beobachtungszeitpunkt, bestehender Nachweisfrist und beiden Clientchecks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot
    )
    Assert-LabTlsLiveQualificationHost
    try {
        $started=Get-LabTlsLiveQualificationUtcNow
        $qualification=Test-LabAuthenticatedTlsEnvironment -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $observed=Get-LabTlsLiveQualificationUtcNow
        return ConvertTo-LabTlsLiveQualificationResult -Qualification $qualification -RunId $RunId -InstanceId $InstanceId -StartedAt $started -ObservedAt $observed
    }catch{throw 'TLS_LIVE_QUALIFICATION_REJECTED'}
}
