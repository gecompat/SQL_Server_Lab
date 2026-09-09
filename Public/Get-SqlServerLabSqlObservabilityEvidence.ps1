<#
.SYNOPSIS
    Erfasst sanitisierte SQL-Observability-Evidence read-only.
.DESCRIPTION
    Liest aggregierte Server-, Datenbank-, Query-Store- und Wait-Statistiken
    direkt oder über eine gespeicherte Run-/Instanzbindung. Die Ausgabe enthält
    keine SQL-Texte, Datenbank-, Login-, Host- oder Secretwerte.
.PARAMETER HostName
    Hostname oder IP-Adresse der SQL-Quelle im direkten Modus.
.PARAMETER Port
    SQL-Port der Quelle im direkten Modus.
.PARAMETER Provider
    Providerklassifikation der direkten Quelle.
.PARAMETER RunId
    Bevorzugte stabile Run-Identität der SQL-Quelle.
.PARAMETER InstanceId
    Instanz-ID innerhalb des gespeicherten Runs. Standard ist primary.
.PARAMETER SaPassword
    SA-Kennwort als fluechtiges SecureString. Es wird nicht in das Ergebnis
    übernommen oder gespeichert.
.PARAMETER StateRoot
    Optionaler State-Root für die Run-Auflösung.
.OUTPUTS
    SqlServerLab.SqlObservabilityEvidence/1.0 mit sanitisierter Quellbindung
    und aggregierten SQL-Metriken.
.EXAMPLE
    Get-SqlServerLabSqlObservabilityEvidence -RunId $runId -SaPassword $password
#>
function Get-SqlServerLabSqlObservabilityEvidence {
    [CmdletBinding(DefaultParameterSetName='RunBased')]
    param(
        [Parameter(ParameterSetName='Direct')][string]$HostName='127.0.0.1',
        [Parameter(ParameterSetName='Direct',Mandatory)][ValidateRange(1,65535)][int]$Port,
        [Parameter(ParameterSetName='Direct',Mandatory)]
        [ValidateSet('docker','podman','hyperv','external')][string]$Provider,
        [Parameter(ParameterSetName='RunBased',Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
        [Parameter(ParameterSetName='RunBased')][string]$InstanceId='primary',
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$StateRoot
    )

    $sourceRunId=$null
    $sourceInstanceId=$null
    if($PSCmdlet.ParameterSetName -eq 'RunBased'){
        $target=Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $HostName=[string]$target.HostName
        $Port=[int]$target.Port
        $Provider=[string]$target.Provider
        $sourceRunId=$RunId
        $sourceInstanceId=$InstanceId
    }
    Get-LabSqlObservabilityEvidence -HostName $HostName -Port $Port -SaPassword $SaPassword `
        -Provider $Provider -RunId $sourceRunId -InstanceId $sourceInstanceId
}