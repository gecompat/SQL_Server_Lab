#Requires -Version 7.2
function Get-SqlServerLabTlsBindingRecovery {
    <#
    .SYNOPSIS
        Zeigt eine unvollstaendige eigene TLS-Wiederbindung ohne Aenderung an.
    .DESCRIPTION
        Prueft die geschuetzte eigene Transaktionsfolge unter dem Writer-Lock.
        Liefert nur den Status und die Transaktions-ID, keine Credentials oder Pfade.
        Die Anzeige ist kein SQL-Clientnachweis und fuehrt keinen Apply aus.
    .PARAMETER RunId
        Exakte RunId des eigenen operativen TLS-Labs.
    .PARAMETER InstanceId
        Exakte Instanz dieses Runs.
    .PARAMETER StateRoot
        Zurueckgegebener privater TLS-StateRoot.
    .EXAMPLE
        Get-SqlServerLabTlsBindingRecovery -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot
    .OUTPUTS
        SqlServerLab.TlsBindingRecovery/0.1 ohne neuen Clientnachweis.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot
    )
    try {Get-LabTlsRebindRecovery -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    catch {
        if($_.Exception.Message -cmatch '\ATLS_[A-Z0-9_]+\z'){throw $_.Exception.Message}
        throw 'TLS_REBIND_RECOVERY_REJECTED'
    }
}
