<#
.SYNOPSIS
    Liefert den gebundenen Laufzeitstatus eines SMTP-Testdiensts.
.DESCRIPTION
    Prüft für einen einzelnen Run die persistierte SMTP-Bindung und den zugehörigen
    Mailpit-Receiver. Die Ausgabe enthält weder Mailinhalte noch Zugangsdaten.
.PARAMETER RunId
    RunId des SMTP-fähigen Docker- oder Podman-Labs.
.PARAMETER StateRoot
    Optionaler StateRoot.
.OUTPUTS
    System.Management.Automation.PSCustomObject mit gebundenem Receiverstatus
    ohne Mailinhalte, Zugangsdaten oder lokale Pfade.
#>
function Get-SqlServerLabSmtpTestServiceStatus {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot)
    $binding=Get-LabSmtpTestServiceWebMailBinding -RunId $RunId -StateRoot $StateRoot
    $runtime=Get-LabSmtpTestServiceWebMailRuntimeStatus -Binding $binding
    [pscustomobject][ordered]@{ContractVersion='SqlServerLab.SmtpTestServiceStatus/1.0';RunId=$binding.RunId;ScopeId=$binding.ScopeId;Provider=$binding.Provider;RunState=$binding.RunState;ServiceId=$binding.ServiceId;ReceiverStatus=$runtime.ReceiverStatus;Status=$runtime.Status;Reason=$runtime.Reason;WebMailAvailable=($runtime.Status -ceq 'READY');WebMailKind='Mailpit';SupportedActions=@('Read','Delete')}
}
