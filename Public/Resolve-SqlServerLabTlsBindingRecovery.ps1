#Requires -Version 7.2
function Resolve-SqlServerLabTlsBindingRecovery {
    <#
    .SYNOPSIS
        Schliesst eine unvollstaendige eigene TLS-Wiederbindung explizit ab.
    .DESCRIPTION
        Complete qualifiziert den exakten gespeicherten Kandidaten mit beiden
        strikten Clients erneut. Rollback stellt ausschliesslich eigene vorherige
        Metadaten wieder her und liefert ausdruecklich keinen TLS-PASS.
        Kein Zertifikat, Key, Trust, Container oder SQL-Dienst wird geaendert.
        Nur die letzte exakte eigene Transaktion ist zulaessig. Unklare Ausgaenge
        verlangen erneute ausdrueckliche Pruefung, niemals automatischen Replay.
    .PARAMETER RunId
        Exakte RunId des eigenen operativen TLS-Labs.
    .PARAMETER InstanceId
        Exakte Instanz dieses Runs.
    .PARAMETER StateRoot
        Zurueckgegebener privater TLS-StateRoot.
    .PARAMETER TransactionId
        Exakte geschuetzte Transaktions-ID aus der Recoveryanzeige.
    .PARAMETER Action
        Complete oder Rollback; eine begonnene Ruecknahme darf nicht wechseln.
    .EXAMPLE
        Resolve-SqlServerLabTlsBindingRecovery -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot -TransactionId $recovery.TransactionId -Action Complete
    .OUTPUTS
        SqlServerLab.TlsBindingRecovery/0.1 mit getrenntem Qualifikationsstatus.
    #>
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z')][string]$TransactionId,
        [Parameter(Mandatory)][ValidateSet('Complete','Rollback')][string]$Action
    )
    if(-not $PSCmdlet.ShouldProcess(($RunId+'/'+$InstanceId+'/'+$TransactionId),($Action+' own incomplete TLS metadata transaction'))){return}
    try {Resolve-LabTlsRebindRecovery -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -TransactionId $TransactionId -Action $Action}
    catch {
        if($_.Exception.Message -cmatch '\ATLS_[A-Z0-9_]+\z'){throw $_.Exception.Message}
        throw 'TLS_REBIND_RECOVERY_REJECTED'
    }
}
