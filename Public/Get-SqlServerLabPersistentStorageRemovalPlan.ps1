<#
.SYNOPSIS
    Plant die Retention-Folgen einer Lab-Entfernung ohne Mutation.
.DESCRIPTION
    Erzeugt aus stabilen PersistentStorageIds und expliziten Policies einen
    schema-validierten Removal-Intent, inventarisiert Katalog und Residency
    read-only neu und liefert den bestehenden fail-closed Removal-Plan.
    Das Cmdlet entfernt weder den Run noch Daten, Leases oder Referenzen.
.PARAMETER RunId
    Stabile Run-ID der zu prüfenden Umgebung.
.PARAMETER Selection
    Eine oder mehrere Auswahlen mit PersistentStorageId, Policy und optionalen
    DatabaseReferenceIds. Anzeigenamen oder Runtime-Volumenamen sind keine
    zulässigen Identitäten.
.PARAMETER StateRoot
    Optionaler State-Root für isolierte Planung und Tests.
.PARAMETER DataRoot
    Optionaler registrierter Lab_Data-Root für den Storage-Katalog.
.OUTPUTS
    System.Management.Automation.PSCustomObject. Ein
    SqlServerLab.PersistentStorageRemovalPlan/1.0.
.EXAMPLE
    Get-SqlServerLabPersistentStorageRemovalPlan -RunId $runId -Selection @(
        @{ PersistentStorageId = $storageId; Policy = 'RETAIN_INSTANCE_STORE'; DatabaseReferenceIds = @() }
    )
#>
function Get-SqlServerLabPersistentStorageRemovalPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9a-fA-F-]{36}$')]
        [string]$RunId,

        [Parameter(Mandatory)]
        [Alias('Selections')]
        [ValidateNotNull()]
        [object[]]$Selection,

        [string]$StateRoot,
        [string]$DataRoot
    )

    $normalizedSelections = @(ConvertTo-LabPersistentStorageRemovalSelection -Selection $Selection)

    $intent = [PSCustomObject][ordered]@{
        ContractVersion = 'SqlServerLab.PersistentStorageRemovalIntent/1.0'
        IntentId = [Guid]::NewGuid().ToString('D')
        RunId = $RunId
        CreatedAt = Get-LabTimestamp
        Selections = $normalizedSelections
    }
    $null = Test-LabPersistentStorageRemovalIntent -Intent $intent

    $auditResult = Get-SqlServerLabCleanupAudit -NoWrite -StateRoot $StateRoot -DataRoot $DataRoot
    if (-not $auditResult -or -not $auditResult.Audit) {
        throw 'PERSISTENT_STORAGE_REMOVAL_AUDIT_UNAVAILABLE'
    }
    $audit = $auditResult.Audit
    $catalog = [PSCustomObject]@{
        Status = [string]$audit.PersistentStorage.CatalogStatus
        Document = $audit.PersistentStorage.Catalog
        Sources = @($audit.PersistentStorage.Sources)
        Issues = @($audit.PersistentStorage.Issues)
    }
    $plan = Get-LabPersistentStorageRemovalPlan -Catalog $catalog -Intent $intent -ResidencyInventory $audit.StorageResidency

    $schemaPath = Join-Path $script:SchemasPath 'persistent-storage-removal-plan.schema.json'
    try {
        $valid = $plan | ConvertTo-Json -Depth 40 | Test-Json -SchemaFile $schemaPath -ErrorAction Stop
    }
    catch {
        throw "PERSISTENT_STORAGE_REMOVAL_PLAN_INVALID: $($_.Exception.Message)"
    }
    if (-not $valid) { throw 'PERSISTENT_STORAGE_REMOVAL_PLAN_INVALID' }
    return $plan
}
