<#
.SYNOPSIS
    Prüft eine vorhandene eigene Windows-/SSISDB-Quelle für die spätere SSIS-Katalogfixture.
.DESCRIPTION
    Bindet einen einzelnen RUNNING Hyper-V-/Windows-/SQL-2019,-2022- oder -2025-Run an dessen registrierte
    Instanz und beobachtet die vorhandenen SSIS- und SSISDB-Voraussetzungen frisch und
    read-only. Es startet keine VM, installiert keine Software, erstellt kein SSISDB,
    legt keine Projekte oder Ausführungen an und gibt weder Endpunkte noch Credentials aus.

    READY_FOR_FIXTURE_IMPLEMENTATION bedeutet nur, dass die eigene Quelle für den nächsten
    gebundenen Fixture-Slice beobachtbar ist. Es ist weder eine SSISDB-Ausführungsabnahme
    noch eine Freigabe für SQL_Server_Analyze oder einen externen Consumer.
.PARAMETER RunId
    Eindeutige RunId eines bereits laufenden eigenen Hyper-V-Labs.
.PARAMETER InstanceId
    Registrierte SQL-Instanz des Runs. Standard ist primary.
.PARAMETER StateRoot
    Optionaler lokaler StateRoot. Der Rückgabevertrag enthält daraus keine Pfade.
.PARAMETER TimeoutSeconds
    Harte Obergrenze für den einmaligen read-only Gasttransport.
.EXAMPLE
    Get-SqlServerLabSsisCatalogCapability -RunId $runId -InstanceId primary
.OUTPUTS
    SqlServerLab.SsisCatalogCapability/1.0. Die Ausgabe ist geheimnis-, endpoint- und pfadfrei.
#>
function Get-SqlServerLabSsisCatalogCapability {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][guid]$RunId,
        [ValidatePattern('^[A-Za-z][A-Za-z0-9_-]{0,63}$')][string]$InstanceId='primary',
        [string]$StateRoot=(Get-LabStateRoot),
        [ValidateRange(10,120)][int]$TimeoutSeconds=60
    )
    $reason='NONE'
    $observation=$null
    if (-not (Test-LabSsisWindowsHost)) {
        $reason='WINDOWS_HOST_REQUIRED'
    }
    else {
        $observation=Invoke-LabSsisPrerequisite -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot -TimeoutSeconds $TimeoutSeconds
        $reason=switch ([string]$observation.ReasonCode) {
            'SSIS_TARGET_UNAVAILABLE' {'TARGET_UNAVAILABLE';break}
            'SSIS_BINDING_CHANGED' {'BINDING_CHANGED';break}
            'SSIS_PROBE_UNAVAILABLE' {'PROBE_UNAVAILABLE';break}
            default {'NONE'}
        }
    }
    $sql=if($observation){[string]$observation.Sql}else{'UNKNOWN'}
    $edition=if($observation){[string]$observation.Edition}else{'UNKNOWN'}
    $components=if($observation){[string]$observation.DefaultPathComponents}else{'UNKNOWN'}
    $catalog=if($observation){[string]$observation.SsisDb}else{'UNKNOWN'}
    $binding=if($reason -eq 'NONE'){'BOUND'}else{'BLOCKED'}
    $source=if($binding -eq 'BOUND' -and $sql -cin @('SQL_2019_OBSERVED','SQL_2022_OBSERVED','SQL_2025_OBSERVED') -and $catalog -eq 'ONLINE_CATALOG_OBSERVED'){'OBSERVED'}else{'NOT_READY'}
    $status=if($source -eq 'OBSERVED' -and $components -eq 'OBSERVED'){'READY_FOR_FIXTURE_IMPLEMENTATION'}else{'BLOCKED'}
    [pscustomobject][ordered]@{
        ContractVersion='SqlServerLab.SsisCatalogCapability/1.0'
        Provider='hyperv'
        OperatingSystem='windows'
        Target=[pscustomobject][ordered]@{RunId=$RunId.ToString();InstanceId=$InstanceId;BindingStatus=$binding}
        Sql=[pscustomobject][ordered]@{Status=$sql;Edition=$edition}
        Ssis=[pscustomobject][ordered]@{DefaultPathComponents=$components;Catalog=$catalog}
        Source=[pscustomobject][ordered]@{Status=$source;ConnectionBinding='NOT_PROVISIONED';ConsumerRights='NOT_ASSESSED'}
        Fixture=[pscustomobject][ordered]@{Status='NOT_IMPLEMENTED';MutationAllowed=$false;ManagedExecutionIds=@()}
        Status=$status
        ReasonCode=$reason
        ReadOnly=$true
    }
}
