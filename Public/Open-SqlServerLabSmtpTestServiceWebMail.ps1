<#
.SYNOPSIS
    Öffnet Mailpit über einen kurzlebigen lokalen Browserzugang.
.DESCRIPTION
    Startet für einen laufenden, gebundenen SMTP-Testdienst einen lokalen Proxy.
    Dieser liest das Run-Secret nur im Speicher und reicht es nicht an Konsole,
    Browser-URL oder Statusobjekt weiter. Der Zugang ist auf Lesen und Löschen
    beschränkt und endet nach der angegebenen Laufzeit.
.PARAMETER RunId
    RunId des SMTP-fähigen Docker- oder Podman-Labs.
.PARAMETER LifetimeMinutes
    Laufzeit des lokalen Browserzugangs, zwischen einer und 60 Minuten.
.PARAMETER NoBrowser
    Erstellt den Zugang ohne den Standardbrowser zu starten.
.PARAMETER StateRoot
    Optionaler StateRoot.
.OUTPUTS
    System.Management.Automation.PSCustomObject mit kurzlebiger lokaler URL und
    Ablaufzeit, jedoch ohne Zugangsdaten.
#>
function Open-SqlServerLabSmtpTestServiceWebMail {
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RunId,[ValidateRange(1,60)][int]$LifetimeMinutes=15,[switch]$NoBrowser,[string]$StateRoot)
    $binding=Get-LabSmtpTestServiceWebMailBinding -RunId $RunId -StateRoot $StateRoot
    $runtime=Get-LabSmtpTestServiceWebMailRuntimeStatus -Binding $binding
    if($runtime.Status -cne 'READY'){throw $runtime.Reason}
    if(-not $PSCmdlet.ShouldProcess(('SMTP-Testdienst '+$RunId),'Lokalen WebMail-Zugang starten')){return}
    $proxy=Start-LabSmtpTestServiceWebMailProxy -Binding $binding -LifetimeMinutes $LifetimeMinutes
    if(-not $NoBrowser){Start-Process $proxy.Url}
    [pscustomobject][ordered]@{ContractVersion='SqlServerLab.SmtpTestServiceWebMailAccess/1.0';Status='OPENED';WebMailKind='Mailpit';Url=$proxy.Url;ExpiresAt=$proxy.ExpiresAt;BrowserStarted=(-not $NoBrowser);SupportedActions=@('Read','Delete')}
}
