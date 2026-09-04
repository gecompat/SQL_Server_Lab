#Requires -Version 7.2
[CmdletBinding()] param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$RemainingArgs)

if ($ShowHelp -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help') {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module = Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru -ErrorAction Stop
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Persistent Storage Removal Plan Checks' -ForegroundColor Cyan

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern)
    try { & $Action | Out-Null; return $false }
    catch { return $_.Exception.Message -match $Pattern }
}

function Copy-TestObject { param($Value) $Value | ConvertTo-Json -Depth 40 | ConvertFrom-Json -Depth 40 }

try {
    $runId=[Guid]::NewGuid().ToString('D'); $scopeId=[Guid]::NewGuid().ToString('D')
    $storageId=[Guid]::NewGuid().ToString('D'); $databaseReferenceId=[Guid]::NewGuid().ToString('D')
    $store=[PSCustomObject][ordered]@{
        PersistentStorageId=$storageId; DisplayName='Retained SQL store'; StorageClass='INSTANCE_STORE'; State='IN_USE'; Provider='docker'
        LocationBinding=[PSCustomObject][ordered]@{ Residency='NATIVE_RUNTIME'; LocationId=$null; ProviderResourceId='sql-lab-retained'; InventoryObjectId='storage-object-aaaaaaaaaaaaaaaaaaaaaaaa'; RelativePath=$null }
        References=@(
            [PSCustomObject][ordered]@{ ReferenceId=[Guid]::NewGuid().ToString('D'); Kind='RUN'; State='ACTIVE'; TargetId=$runId },
            [PSCustomObject][ordered]@{ ReferenceId=$databaseReferenceId; Kind='DATABASE'; State='ACTIVE'; TargetId='database-one' }
        )
        Lease=[PSCustomObject][ordered]@{ LeaseId=[Guid]::NewGuid().ToString('D'); RunId=$runId; ScopeId=$scopeId; Mode='EXCLUSIVE'; AcquiredAt='2026-09-01T00:00:00Z'; ExpiresAt=$null }
        Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt='2026-09-01T00:00:00Z'; UpdatedAt='2026-09-01T00:00:00Z'
    }
    $document=[PSCustomObject][ordered]@{ ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0'; ControllerId=[Guid]::NewGuid().ToString('D'); Revision=5; Stores=@($store) }
    $catalog=[PSCustomObject]@{ Status='AVAILABLE'; Document=$document; Sources=@(); Issues=@() }
    $inventory=[PSCustomObject]@{ Objects=@([PSCustomObject]@{ ObjectId='storage-object-aaaaaaaaaaaaaaaaaaaaaaaa'; Provider='docker'; LogicalName='sql-lab-retained'; Lifecycle='RETAINED'; AuditStatus='VERIFIED'; RunIds=@($runId) }) }
    $intent=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.PersistentStorageRemovalIntent/1.0'; IntentId=[Guid]::NewGuid().ToString('D'); RunId=$runId; CreatedAt='2026-09-01T00:00:00Z'
        Selections=@([PSCustomObject][ordered]@{ PersistentStorageId=$storageId; Policy='RETAIN_INSTANCE_STORE'; DatabaseReferenceIds=@() })
    }

    Add-CheckResult -Name 'Removal-Intent erfüllt striktes Schema und eindeutige Auswahl' -Success (
        (& $module { param($value) Test-LabPersistentStorageRemovalIntent -Intent $value } $intent) -and
        (($intent | ConvertTo-Json -Depth 30) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/persistent-storage-removal-intent.schema.json')))
    $duplicateIntent=Copy-TestObject $intent; $duplicateIntent.Selections=@($duplicateIntent.Selections[0],(Copy-TestObject $duplicateIntent.Selections[0]))
    Add-CheckResult -Name 'Doppelte Policy-Auswahl für dieselbe Storage-ID wird abgelehnt' -Success (Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_REMOVAL_SELECTION_DUPLICATE' -Action {
        & $module { param($value) Test-LabPersistentStorageRemovalIntent -Intent $value } $duplicateIntent
    })

    $catalogBefore=$document | ConvertTo-Json -Depth 40 -Compress
    $retainPlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $catalog $intent $inventory
    Add-CheckResult -Name 'Retained Instanzstore wird bewahrt und erst danach aus Lease und Run gelöst' -Success (
        $retainPlan.Status -eq 'READY' -and $retainPlan.Stores[0].Outcome -eq 'RETAIN_CATALOGED' -and
        $retainPlan.Execution.Status -eq 'EXECUTABLE' -and $retainPlan.Execution.Reason -eq 'READY_FOR_EXECUTION' -and
        -not $retainPlan.Stores[0].Destructive -and $retainPlan.Stores[0].RequiresSeparateStorageDelete -and
        (@($retainPlan.Stores[0].Steps.Action) -join ',') -match 'PRESERVE_STORE,RELEASE_LEASE,RELEASE_RUN_REFERENCE$') `
        -Message (($retainPlan | ConvertTo-Json -Depth 20 -Compress))
    Add-CheckResult -Name 'Removal-Plan bleibt read-only und erfüllt den eigenen Vertrag' -Success (
        $catalogBefore -eq ($document | ConvertTo-Json -Depth 40 -Compress) -and
        (($retainPlan | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/persistent-storage-removal-plan.schema.json')))

    $auditFixture=[PSCustomObject]@{
        PersistentStorage=[PSCustomObject]@{
            CatalogStatus='AVAILABLE'; Catalog=$document; Sources=@(); Issues=@()
        }
        StorageResidency=$inventory
    }
    $publicPlan=& $module {
        param($fixture,$targetRunId,$selections)
        $originalAuditCommand=${function:Get-SqlServerLabCleanupAudit}
        $script:PersistentStorageRemovalAuditFixture=$fixture
        try {
            Set-Item -LiteralPath Function:\Get-SqlServerLabCleanupAudit -Value {
                [PSCustomObject]@{ Path=$null; Audit=$script:PersistentStorageRemovalAuditFixture }
            }
            Get-SqlServerLabPersistentStorageRemovalPlan -RunId $targetRunId -Selection @($selections)
        }
        finally {
            Set-Item -LiteralPath Function:\Get-SqlServerLabCleanupAudit -Value $originalAuditCommand
            Remove-Variable -Name PersistentStorageRemovalAuditFixture -Scope Script -ErrorAction SilentlyContinue
        }
    } $auditFixture $runId $intent.Selections
    Add-CheckResult -Name 'Öffentliche CLI erzeugt denselben schema-validierten read-only Retention-Plan' -Success (
        (Get-Command Get-SqlServerLabPersistentStorageRemovalPlan -Module SqlServerLab -ErrorAction SilentlyContinue) -and
        $publicPlan.Status -eq 'READY' -and $publicPlan.Stores[0].PersistentStorageId -eq $storageId -and
        $publicPlan.Stores[0].Policy -eq 'RETAIN_INSTANCE_STORE' -and
        $catalogBefore -eq ($document | ConvertTo-Json -Depth 40 -Compress) -and
        (($publicPlan | ConvertTo-Json -Depth 40) | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/persistent-storage-removal-plan.schema.json'))) `
        -Message (($publicPlan | ConvertTo-Json -Depth 20 -Compress))

    $backupIntent=Copy-TestObject $intent; $backupIntent.Selections[0].Policy='BACKUP_ON_REMOVE'; $backupIntent.Selections[0].DatabaseReferenceIds=@($databaseReferenceId)
    $backupPlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $catalog $backupIntent $inventory
    Add-CheckResult -Name 'Backup-on-Remove verlangt CHECKSUM und RESTORE VERIFYONLY vor Freigabe' -Success (
        $backupPlan.Status -eq 'READY' -and $backupPlan.Stores[0].Outcome -eq 'BACKUP_AND_RETAIN' -and
        @($backupPlan.Stores[0].Steps.Action) -contains 'VERIFY_BACKUP_CHECKSUM' -and
        @($backupPlan.Stores[0].Steps.Action) -contains 'VERIFY_RESTORE' -and
        @($backupPlan.Stores[0].Steps | Where-Object FailureState -eq 'RECOVERY_REQUIRED').Count -ge 3) `
        -Message (($backupPlan | ConvertTo-Json -Depth 20 -Compress))

    $packageIntent=Copy-TestObject $backupIntent; $packageIntent.Selections[0].Policy='PACKAGE_ON_REMOVE'
    $packagePlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $catalog $packageIntent $inventory
    Add-CheckResult -Name 'Package-on-Remove plant Offline, vollständiges Inventar, SHA-256 und Postcondition' -Success (
        $packagePlan.Status -eq 'READY' -and $packagePlan.Stores[0].Outcome -eq 'PACKAGE_AND_RETAIN' -and
        $packagePlan.Execution.Status -eq 'EXECUTABLE' -and
        $packagePlan.Execution.Reason -eq 'READY_FOR_EXECUTION' -and
        'PACKAGE_ON_REMOVE' -in @($packagePlan.Execution.ExecutablePolicies) -and
        (@('OFFLINE_DATABASES','MATERIALIZE_PACKAGE','HASH_PACKAGE','VERIFY_PACKAGE') | Where-Object { $_ -notin @($packagePlan.Stores[0].Steps.Action) }).Count -eq 0) `
        -Message (($packagePlan | ConvertTo-Json -Depth 20 -Compress))

    $bothIntent=Copy-TestObject $backupIntent; $bothIntent.Selections[0].Policy='BACKUP_AND_PACKAGE'
    $bothPlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $catalog $bothIntent $inventory
    Add-CheckResult -Name 'Backup-and-Package führt beide Nachweise ohne implizite Store-Löschung aus' -Success (
        $bothPlan.Status -eq 'READY' -and $bothPlan.Stores[0].Outcome -eq 'BACKUP_PACKAGE_AND_RETAIN' -and
        $bothPlan.Execution.Status -eq 'EXECUTABLE' -and $bothPlan.Execution.Reason -eq 'READY_FOR_EXECUTION' -and
        'BACKUP_AND_PACKAGE' -in @($bothPlan.Execution.ExecutablePolicies) -and
        @($bothPlan.Stores[0].Steps.Action) -contains 'VERIFY_RESTORE' -and @($bothPlan.Stores[0].Steps.Action) -contains 'VERIFY_PACKAGE' -and
        -not $bothPlan.Stores[0].Destructive -and $bothPlan.Stores[0].RequiresSeparateStorageDelete) `
        -Message (($bothPlan | ConvertTo-Json -Depth 20 -Compress))

    $deleteDocument=Copy-TestObject $document
    $deleteDocument.Stores[0].State='IN_USE'; $deleteDocument.Stores[0].Retention='RUN_SCOPED'; $deleteDocument.Stores[0].CleanupDisposition='RUN_CLEANUP'
    $deleteCatalog=[PSCustomObject]@{ Status='AVAILABLE'; Document=$deleteDocument }
    $deleteIntent=Copy-TestObject $intent; $deleteIntent.Selections[0].Policy='DELETE_WITH_RUN'
    $deletePlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $deleteCatalog $deleteIntent $inventory
    Add-CheckResult -Name 'DELETE_WITH_RUN ist nur für rungebundene Cleanup-Ressource destruktiv' -Success (
        $deletePlan.Status -eq 'READY' -and $deletePlan.Stores[0].Outcome -eq 'DELETE_RUN_RESOURCE' -and
        $deletePlan.Stores[0].Destructive -and -not $deletePlan.Stores[0].RequiresSeparateStorageDelete) `
        -Message (($deletePlan | ConvertTo-Json -Depth 20 -Compress))
    $unsafeDeleteIntent=Copy-TestObject $intent; $unsafeDeleteIntent.Selections[0].Policy='DELETE_WITH_RUN'
    $unsafeDeletePlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $catalog $unsafeDeleteIntent $inventory
    Add-CheckResult -Name 'DELETE_WITH_RUN kann retained Persistent Storage nicht freigeben' -Success (
        $unsafeDeletePlan.Status -eq 'BLOCKED' -and 'DELETE_WITH_RUN_NOT_ALLOWED' -in @($unsafeDeletePlan.Stores[0].Blockers) -and -not $unsafeDeletePlan.Stores[0].Destructive)
    Add-CheckResult -Name 'Fachlich blockierter Plan wird nicht als Executor-Capability missverstanden' -Success (
        $unsafeDeletePlan.Execution.Status -eq 'BLOCKED' -and $unsafeDeletePlan.Execution.Reason -eq 'PLAN_BLOCKED')

    $externalDocument=Copy-TestObject $document
    $externalDocument.Stores[0].State='DETACHED'; $externalDocument.Stores[0].Provider='external'; $externalDocument.Stores[0].Lease=$null
    $externalDocument.Stores[0].Retention='EXTERNAL_UNMANAGED'; $externalDocument.Stores[0].CleanupDisposition='REPORT_ONLY'
    $externalDocument.Stores[0].LocationBinding.Residency='EXTERNAL_HOST'; $externalDocument.Stores[0].LocationBinding.InventoryObjectId=$null
    $externalDocument.Stores[0].LocationBinding.ProviderResourceId='external-retained-store'
    $externalIntent=Copy-TestObject $intent; $externalIntent.Selections[0].Policy='EXTERNAL_UNMANAGED'
    $externalInventory=[PSCustomObject]@{ Objects=@([PSCustomObject]@{ ObjectId='storage-object-cccccccccccccccccccccccc'; Provider='external'; LogicalName='external-retained-store'; Lifecycle='RETAINED'; AuditStatus='VERIFIED'; RunIds=@($runId) }) }
    $externalPlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } ([PSCustomObject]@{Status='AVAILABLE';Document=$externalDocument}) $externalIntent $externalInventory
    Add-CheckResult -Name 'EXTERNAL_UNMANAGED löst nur die Bindung und mutiert niemals die Quelle' -Success (
        $externalPlan.Status -eq 'READY' -and $externalPlan.Stores[0].Outcome -eq 'RELEASE_BINDING_ONLY' -and
        $externalPlan.Execution.Status -eq 'EXECUTABLE' -and 'EXTERNAL_UNMANAGED' -in @($externalPlan.Execution.ExecutablePolicies) -and
        @($externalPlan.Stores[0].Steps | Where-Object Mutation -in @('SQL','STORAGE')).Count -eq 0 -and
        @($externalPlan.Stores[0].Steps.Action) -contains 'RELEASE_EXTERNAL_BINDING')

    $unknownDatabaseIntent=Copy-TestObject $backupIntent
    $unknownDatabaseIntent.Selections[0].DatabaseReferenceIds=@([Guid]::NewGuid().ToString('D'))
    $unknownDatabasePlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $catalog $unknownDatabaseIntent $inventory
    Add-CheckResult -Name 'Backup-/Package-Auswahl ist an aktive Datenbankreferenzen gebunden' -Success (
        $unknownDatabasePlan.Status -eq 'BLOCKED' -and 'DATABASE_REFERENCE_NOT_ACTIVE' -in @($unknownDatabasePlan.Stores[0].Blockers))

    $foreignDocument=Copy-TestObject $document
    $foreignDocument.Stores[0].References += [PSCustomObject]@{ ReferenceId=[Guid]::NewGuid().ToString('D'); Kind='RUN'; State='ACTIVE'; TargetId=[Guid]::NewGuid().ToString('D') }
    $foreignPlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } ([PSCustomObject]@{Status='AVAILABLE';Document=$foreignDocument}) $intent $inventory
    Add-CheckResult -Name 'Fremde aktive Run-Referenz blockiert jeden Removal-Plan' -Success (
        $foreignPlan.Status -eq 'BLOCKED' -and 'FOREIGN_ACTIVE_REFERENCE' -in @($foreignPlan.Stores[0].Blockers))

    $uncatalogedInventory=Copy-TestObject $inventory
    $uncatalogedInventory.Objects += [PSCustomObject]@{ ObjectId='storage-object-bbbbbbbbbbbbbbbbbbbbbbbb'; Provider='podman'; LogicalName='uncataloged'; Lifecycle='RETAINED'; AuditStatus='VERIFIED'; RunIds=@($runId) }
    $uncatalogedPlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } $catalog $intent $uncatalogedInventory
    Add-CheckResult -Name 'Nicht katalogisiertes retained Objekt blockiert statt still bereinigt zu werden' -Success (
        $uncatalogedPlan.Status -eq 'BLOCKED' -and @($uncatalogedPlan.Issues | Where-Object { $_ -like 'UNCATALOGED_RETAINED_OBJECT:*' }).Count -eq 1)

    $recoveryDocument=Copy-TestObject $document; $recoveryDocument.Stores[0].State='RECOVERY_REQUIRED'
    $recoveryPlan=& $module { param($cat,$value,$inv) Get-LabPersistentStorageRemovalPlan -Catalog $cat -Intent $value -ResidencyInventory $inv } ([PSCustomObject]@{Status='AVAILABLE';Document=$recoveryDocument}) $intent $inventory
    Add-CheckResult -Name 'RECOVERY_REQUIRED-Store bleibt vor normalem Removal fail-closed' -Success (
        $recoveryPlan.Status -eq 'BLOCKED' -and 'STORE_STATE_RECOVERY_REQUIRED' -in @($recoveryPlan.Stores[0].Blockers))

    $secretIntent=Copy-TestObject $intent; $secretIntent.Selections[0] | Add-Member -NotePropertyName Password -NotePropertyValue 'not-a-real-secret'
    Add-CheckResult -Name 'Strikter Removal-Intent lässt keine Secretfelder zu' -Success (Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_REMOVAL_INTENT_INVALID' -Action {
        & $module { param($value) Test-LabPersistentStorageRemovalIntent -Intent $value } $secretIntent
    })
}
finally {
    Remove-Module $module.Name -Force -ErrorAction SilentlyContinue
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
