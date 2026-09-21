<#
.SYNOPSIS
    Löscht genau einen eigenen behaltenen Instanzspeicher endgültig.
.DESCRIPTION
    Apply verlangt die Revision und den PlanKey des zuvor geprüften Preview.
    WhatIf und abgelehnte Bestätigungen schreiben nichts. Resume setzt nur die
    eigene Operation vorwärts fort. Die stabile Speicher-ID bleibt dauerhaft
    als REMOVED-Tombstone erhalten. Kein Run und kein Backup wird gelöscht.
.PARAMETER PersistentStorageId
    Stabile UUID des Speichers, niemals ein Volume-Name oder Dateipfad.
.PARAMETER DataRoot
    Registrierter Lab_Data-Root des Katalogs.
.PARAMETER StateRoot
    Root der Original-Run-Evidence und des Operationsjournals.
.PARAMETER ExpectedCatalogRevision
    Katalogrevision aus Get-SqlServerLabRetainedStoreRemovalPlan.
.PARAMETER ExpectedPlanKey
    Fingerprint des vollständig geprüften Preview.
.PARAMETER OperationId
    Fortzusetzende Löschoperation aus einem früheren Ergebnis.
.OUTPUTS
    PSCustomObject mit Status, PersistentStorageId, OperationId und Reason.
#>
function Invoke-SqlServerLabRetainedStoreRemoval {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact='High', DefaultParameterSetName='Apply')]
    param(
        [Parameter(Mandatory)][guid]$PersistentStorageId,
        [Parameter(Mandatory)][string]$DataRoot, [string]$StateRoot,
        [Parameter(Mandatory,ParameterSetName='Apply')][ValidateRange(0,2147483647)][int]$ExpectedCatalogRevision,
        [Parameter(Mandatory,ParameterSetName='Apply')][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedPlanKey,
        [Parameter(Mandatory,ParameterSetName='Resume')][guid]$OperationId
    )
    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    $id=$PersistentStorageId.ToString('D')
    try {
        $root=Resolve-LabDataRootForUse -DataRoot $DataRoot
        $configuration=Get-LabStorageConfiguration -DataRoot $root
        if ($PSCmdlet.ParameterSetName -ceq 'Apply') {
            $plan=Get-LabRetainedStoreRemovalPlan -Configuration $configuration -PersistentStorageId $id -StateRoot $StateRoot
            if ($plan.CatalogRevision -ne $ExpectedCatalogRevision -or $plan.PlanKey -cne $ExpectedPlanKey) {
                throw 'RETAINED_STORE_PREVIEW_CHANGED'
            }
            $OperationId=[guid]::NewGuid()
        }
        else {
            $record=Get-LabRetainedStoreRecord -Configuration $configuration -PersistentStorageId $id
            if ($record.Store.Deletion -and $record.Store.Deletion.OperationId -cne $OperationId.ToString('D')) {
                throw 'RETAINED_STORE_OPERATION_MISMATCH'
            }
        }
    }
    catch {
        if ($_.Exception.Message -cmatch '^RETAINED_STORE_[A-Z_]+$') { throw $_.Exception.Message }
        throw 'RETAINED_STORE_PREVIEW_UNVERIFIABLE'
    }
    if (-not $PSCmdlet.ShouldProcess($id,'Alle Daten dieses behaltenen SQL-Speichers endgültig löschen (Backup nicht geprüft)')) {
        return [pscustomobject]@{Status=if($WhatIfPreference){'PLANNED'}else{'CANCELLED'};PersistentStorageId=$id;OperationId=$null;Reason='NONE'}
    }
    $arguments=@{Configuration=$configuration;PersistentStorageId=$id;StateRoot=$StateRoot;OperationId=$OperationId}
    if ($PSCmdlet.ParameterSetName -ceq 'Apply') {
        $arguments.ExpectedRevision=$ExpectedCatalogRevision; $arguments.ExpectedPlanKey=$ExpectedPlanKey
    }
    Invoke-LabRetainedStoreRemoval @arguments
}
