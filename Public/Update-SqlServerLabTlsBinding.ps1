#Requires -Version 7.2
function Update-SqlServerLabTlsBinding {
    <#
    .SYNOPSIS
        Qualifiziert die unveraenderte TLS-Bindung eines eigenen Containers nach Neustart erneut.
    .DESCRIPTION
        Verlangt den exakten eigenen Run, seine Instanz und seinen TLS-StateRoot.
        Windows/PowerShell 7.5+, Docker oder Podman, policygebundener Record 0.2/0.3.
        Nur die gespeicherte Start-Epoche wird nach zwei echten strikten Clients
        aktualisiert. Zertifikat, Key, Provider, Image, Port und Trust bleiben gleich.
        Ein unveraenderter Start liefert UNCHANGED_ALREADY_BOUND ohne neuen Clientnachweis.
        Unklare Schreibausgaenge bleiben TLS_REBIND_RECOVERY_REQUIRED; kein automatischer Retry.
        Get-SqlServerLabTlsBindingRecovery zeigt den eigenen offenen Intent.
        Resolve-SqlServerLabTlsBindingRecovery verlangt danach eine neue explizite Auswahl.
    .PARAMETER RunId
        Exakte RunId des eigenen operativen TLS-Labs.
    .PARAMETER InstanceId
        Exakte Instanz, im operativen TLS-Pfad primary.
    .PARAMETER StateRoot
        Ausdruecklich zurueckgegebener privater StateRoot dieses TLS-Labs.
    .EXAMPLE
        Update-SqlServerLabTlsBinding -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot -WhatIf
    .EXAMPLE
        Update-SqlServerLabTlsBinding -RunId $lab.RunId -InstanceId primary -StateRoot $lab.StateRoot
    .OUTPUTS
        SqlServerLab.TlsBindingUpdate/0.1 mit Status, Build und frischem Nachweiszeitraum.
    #>
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='Medium')]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$RunId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$InstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$StateRoot
    )
    if(-not $PSCmdlet.ShouldProcess(($RunId+'/'+$InstanceId),'Qualify unchanged TLS certificate after container restart and commit new start binding')){return}
    try {Update-LabTlsRestartBinding -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot}
    catch {
        if($_.Exception.Message -cmatch '\ATLS_[A-Z0-9_]+\z'){throw $_.Exception.Message}
        throw 'TLS_REBIND_REJECTED'
    }
}
