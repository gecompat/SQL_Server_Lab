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
        Der isolierte Linux-Bytespfad verlangt eine bereits vom privaten
        Controllerbootstrap gebundene Sitzung. Er erzeugt weder Sitzung noch
        Transport und liest keinen Windows-StateRoot als Linuxdateipfad.
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
    .PARAMETER LinuxSessionRef
        Opaque Referenz der bereits gebundenen privaten Linux-Controllersitzung.
        Nur zusammen mit ExportBytes im eigenen Linuxpeer oder im bereits
        aktiven privaten Windows-Verifier dieser Sitzung verwendbar. Ein
        direkter Windowsconsumer darf keinen Linux-Namespaceexport verwenden.
    .PARAMETER LinuxClientStack
        Der unmittelbar folgende Linux-Login: SYSTEM_DATA_SQLCLIENT oder
        ODBC_SQLCMD. Jeder Login verlangt eine eigene frische Pruefung.
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
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot,
        [string]$LinuxSessionRef,
        [ValidateSet('SYSTEM_DATA_SQLCLIENT','ODBC_SQLCMD')][string]$LinuxClientStack='SYSTEM_DATA_SQLCLIENT'
    )
    try {
        if($PSVersionTable.PSVersion -lt [version]'7.5'){throw 'TLS_EXPORT_READ_REJECTED'}
        if(-not $IsWindows){
            if(-not $IsLinux -or $PSCmdlet.ParameterSetName -cne 'Bytes' -or -not $LinuxSessionRef){throw 'TLS_EXPORT_READ_REJECTED'}
            return Read-LabTlsLinuxPeerSnapshot -ExportBytes $ExportBytes -SessionRef $LinuxSessionRef -ClientStack $LinuxClientStack -StateRoot $StateRoot -RunId $RunId -InstanceId $InstanceId
        }
        $linuxController=$PSBoundParameters.ContainsKey('LinuxSessionRef') -or $PSBoundParameters.ContainsKey('LinuxClientStack')
        if($linuxController){
            if($PSCmdlet.ParameterSetName-cne'Bytes'){throw 'TLS_EXPORT_READ_REJECTED'}
            Assert-LabTlsLinuxControllerSession $StateRoot $RunId $InstanceId $ExportBytes $LinuxSessionRef $LinuxClientStack
        }
        $parameters=@{StateRoot=$StateRoot;RunId=$RunId;InstanceId=$InstanceId}
        if($linuxController){$parameters.AllowLinuxController=$true}
        if($PSCmdlet.ParameterSetName -ceq 'Bytes'){$parameters.ExportBytes=$ExportBytes;$parameters.FromBytes=$true}
        else{$parameters.Path=$Path}
        $snapshot=Read-LabTlsQualifiedExportSnapshot @parameters
        if($null -eq $snapshot -or $snapshot -is [bool]){throw 'TLS_EXPORT_READ_REJECTED'}
        $platform=$snapshot.Qualification.PSObject.Properties['ClientPlatform']
        if($platform-and$platform.Value-ceq'linux'-and-not$linuxController){throw 'TLS_EXPORT_READ_REJECTED'}
        return $snapshot
    } catch {throw 'TLS_EXPORT_READ_REJECTED'}
}
