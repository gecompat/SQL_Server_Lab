function Invoke-SqlServerLabLinuxPreflight {
    <#
    .SYNOPSIS
        Fuehrt den ausdruecklichen Toolbelt-V2-Preflight im eigenen Linuxclient aus.
    .DESCRIPTION
        Windowscontroller mit einem ausdruecklich fuer Linux erstellten eigenen
        False-Lab. Haelt denselben privaten V2-Bytesnapshot und ausgewaehlte
        Toolbeltquellen waehrend einer begrenzten Vordergrundsitzung. Beide
        echten Linuxstacks validieren unmittelbar vor Open den oeffentlichen
        Reader frisch; keine SQL-Objekte, kein Trust- oder Providerfallback.
        Der explizite Toolbeltcheckout ist vertrauenswuerdiger Caller-Code.
        Ein Export kann keine Codepfade oder Sitzung erzeugen. Bei fehlgeschlagener
        Ausfuehrung wird nur der eigene Client kanonisch entfernt; ungeklaerte
        Prozessenden bleiben gesperrter Recoverybedarf. Der SQL-Run bleibt zum
        ausdruecklichen Remove erhalten. Ergebnis enthaelt keine Secrets.
    .PARAMETER ExportBytes
        Genau einmal privat gelesene signierte V2-Exportbytes.
    .PARAMETER Path
        Ausdrueckliche private Linux-V2-Exportdatei. Wird genau einmal unter
        den kanonischen privaten Datei-ACLs gelesen; kein Codepfad aus dem Export.
    .PARAMETER StateRoot
        Exakter privater Root des ausdruecklich fuer Linux angelegten Runs.
    .PARAMETER RunId
        Exakter eigener Run.
    .PARAMETER InstanceId
        Exakte Instanz primary.
    .PARAMETER ToolbeltRoot
        Ausdruecklich vertrauenswuerdiger SQL_Server_Toolbelt-Checkout mit dem
        gekoppelten Linux-Preflight und gemeinsamen V2-Reader. Keine automatische
        Suche und keine Ableitung aus Export-, Browser- oder Umgebungsdaten.
    .EXAMPLE
        Invoke-SqlServerLabLinuxPreflight -Path $export.JsonPath -StateRoot $lab.StateRoot -RunId $lab.RunId -InstanceId primary -ToolbeltRoot $toolbelt
    .OUTPUTS
        SqlServerLab.LinuxConsumerResult/0.1 mit zwei echten Clientchecks.
    #>
    [CmdletBinding(DefaultParameterSetName='Path')]
    param(
        [Parameter(Mandatory,ParameterSetName='Bytes')][ValidateNotNullOrEmpty()][byte[]]$ExportBytes,
        [Parameter(Mandatory,ParameterSetName='Path')][ValidateNotNullOrEmpty()][string]$Path,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('primary')][string]$InstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$ToolbeltRoot
    )
    Assert-LabTlsLiveQualificationHost
    try{
        $arguments=@{};foreach($name in @('StateRoot','RunId','InstanceId','ToolbeltRoot')){$arguments[$name]=$PSBoundParameters[$name]}
        $arguments.ExportBytes=if($PSCmdlet.ParameterSetName-ceq'Path'){Read-LabTlsCaPrivateFile $Path (Get-LabTlsWindowsProcessFacts).UserSid 65536}else{[byte[]]$ExportBytes.Clone()}
        try{Invoke-LabTlsLinuxConsumerBridge @arguments}finally{[Array]::Clear($arguments.ExportBytes,0,$arguments.ExportBytes.Length)}
    }
    catch{throw 'TLS_LINUX_CONSUMER_REJECTED_OR_RECOVERY_REQUIRED'}
}
