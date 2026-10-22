#Requires -Version 7.2
function Read-SqlServerLabQualifiedTestEnvironment {
    <#
    .SYNOPSIS
        Liest einen signierten V2-Testvertrag mit aktueller eigener Labbindung.
    .DESCRIPTION
        Windows, aktueller registrierter Client-/Trustkontext und ausdrueckliche
        Run-/Instanz-/StateRoot-Auswahl sind erforderlich. Der Dateipfad wird
        genau einmal unter privaten ACLs gelesen. ExportBytes validiert dieselben
        bereits gelesenen Bytes erneut, ohne die urspruengliche Datei zu oeffnen.
        Signatur, Frist sowie aktuelle Ziel-, Runtime-, Zertifikats-, Client- und
        Trustbindung werden wie beim qualifizierten Export-Readback geprueft.
        Es gibt keinen V1-/Provider-/Trust-Fallback und keine neue SQL-Anmeldung.
        Das Ergebnis enthaelt Credentials und bleibt ausschliesslich privat.
        VerifiedAtUtc ist ein Beobachtungszeitpunkt, keine Runtime-Reservierung
        und keine Verlaengerung von Qualification.ExpiresAt. Vor spaeterer Nutzung
        dieselben ExportBytes erneut pruefen; keine Exportdatei nachlesen.
    .PARAMETER Path
        Explizite vorhandene private TestUmgebung.json aus einem V2-Export.
    .PARAMETER ExportBytes
        Die unveraenderten Bytes eines zuvor gelesenen Exports, maximal 64 KiB.
    .PARAMETER RunId
        Exakte RunId des eigenen operativen TLS-Labs.
    .PARAMETER InstanceId
        Exakte SQL-Instanz dieses Runs.
    .PARAMETER StateRoot
        Ausdruecklicher privater StateRoot des eigenen operativen TLS-Labs.
    .EXAMPLE
        $snapshot = Read-SqlServerLabQualifiedTestEnvironment -Path $export.JsonPath -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot
    .EXAMPLE
        $current = Read-SqlServerLabQualifiedTestEnvironment -ExportBytes $snapshot.ExportBytes -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot
    .OUTPUTS
        SqlServerLab.QualifiedTestEnvironmentSnapshot/0.1 mit privaten Exportbytes,
        geprueftem Vertrag, Qualifikation, Bytehash und Beobachtungszeitpunkt.
    #>
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory,ParameterSetName='Path')][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory,ParameterSetName='Bytes')][ValidateNotNullOrEmpty()][byte[]]$ExportBytes,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot
    )
    try {
        if(-not $IsWindows -or $PSVersionTable.PSVersion -lt [version]'7.5'){throw 'TLS_EXPORT_READ_REJECTED'}
        $parameters=@{StateRoot=$StateRoot;RunId=$RunId;InstanceId=$InstanceId}
        if($PSCmdlet.ParameterSetName -ceq 'Bytes'){$parameters.ExportBytes=$ExportBytes;$parameters.FromBytes=$true}
        else{$parameters.Path=$Path}
        $snapshot=Read-LabTlsQualifiedExportSnapshot @parameters
        if($null -eq $snapshot -or $snapshot -is [bool]){throw 'TLS_EXPORT_READ_REJECTED'}
        return $snapshot
    } catch {throw 'TLS_EXPORT_READ_REJECTED'}
}
