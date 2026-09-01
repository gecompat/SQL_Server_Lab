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
$temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-lab-persistent-catalog-$([Guid]::NewGuid().ToString('N'))"
$failures = [Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Persistent Storage Catalog Checks' -ForegroundColor Cyan

function Test-ExpectedFailure {
    param([Parameter(Mandatory)][scriptblock]$Action, [Parameter(Mandatory)][string]$Pattern)
    try { & $Action | Out-Null; return $false }
    catch { return $_.Exception.Message -match $Pattern }
}

try {
    $controllerId = [Guid]::NewGuid().ToString('D')
    $locationId1 = [Guid]::NewGuid().ToString('D'); $locationId2 = [Guid]::NewGuid().ToString('D')
    $runId = [Guid]::NewGuid().ToString('D'); $scopeId = [Guid]::NewGuid().ToString('D')
    $storageId = & $module { New-LabPersistentStorageId }
    $root1 = Join-Path $temporaryRoot 'one/Lab_Data'; $root2 = Join-Path $temporaryRoot 'two/Lab_Data'
    New-Item -Path (Join-Path $root1 'Catalog'),(Join-Path $root2 'Catalog') -ItemType Directory -Force | Out-Null
    $configuration = [PSCustomObject]@{
        ControllerId=$controllerId
        LabDataLocations=@(
            [PSCustomObject]@{ LocationId=$locationId1; LabDataRoot=$root1 },
            [PSCustomObject]@{ LocationId=$locationId2; LabDataRoot=$root2 }
        )
    }
    $store = [PSCustomObject][ordered]@{
        PersistentStorageId=$storageId; DisplayName='SQL 2025 persistent'; StorageClass='INSTANCE_STORE'; State='IN_USE'; Provider='docker'
        LocationBinding=[PSCustomObject][ordered]@{
            Residency='NATIVE_RUNTIME'; LocationId=$null; ProviderResourceId='sql-lab-persistent-test'
            InventoryObjectId='storage-object-111111111111111111111111'; RelativePath=$null
        }
        References=@([PSCustomObject][ordered]@{ ReferenceId=[Guid]::NewGuid().ToString('D'); Kind='RUN'; State='ACTIVE'; TargetId=$runId })
        Lease=[PSCustomObject][ordered]@{
            LeaseId=[Guid]::NewGuid().ToString('D'); RunId=$runId; ScopeId=$scopeId; Mode='EXCLUSIVE'
            AcquiredAt='2026-09-01T00:00:00Z'; ExpiresAt=$null
        }
        Retention='RETAINED'; CleanupDisposition='PRESERVE'; CreatedAt='2026-09-01T00:00:00Z'; UpdatedAt='2026-09-01T00:00:00Z'
    }
    $document = [PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.PersistentStorageCatalog/1.0'; ControllerId=$controllerId; Revision=4; Stores=@($store)
    }
    $catalogJson = $document | ConvertTo-Json -Depth 30
    $catalogPath1 = Join-Path $root1 'Catalog/persistent-stores.json'; $catalogPath2 = Join-Path $root2 'Catalog/persistent-stores.json'
    Set-Content -LiteralPath $catalogPath1 -Value $catalogJson -Encoding utf8NoBOM
    Set-Content -LiteralPath $catalogPath2 -Value $catalogJson -Encoding utf8NoBOM

    $valid = & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $document $configuration
    Add-CheckResult -Name 'Katalogdokument erfüllt Schema und semantischen Vertrag' -Success $valid
    Add-CheckResult -Name 'PersistentStorageId ist eine eigenständige UUID statt eines Runtime-Namens' -Success (
        $storageId -match '^[0-9a-f-]{36}$' -and $storageId -ne [string]$store.LocationBinding.ProviderResourceId)

    $catalog = & $module {
        param($config)
        Set-Item Function:Test-LabDataRootOwnership -Value { param($DataRoot,$ControllerId) return $true }
        Get-LabPersistentStorageCatalog -Configuration $config
    } $configuration
    Add-CheckResult -Name 'Identische controllergebundene Katalogspiegel werden read-only zusammengeführt' -Success (
        $catalog.Status -eq 'AVAILABLE' -and @($catalog.Sources).Count -eq 2 -and @($catalog.Document.Stores).Count -eq 1)

    $renamed = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $renamed.Stores[0].DisplayName = 'Umbenannter Anzeigename'
    Add-CheckResult -Name 'Anzeigenamenänderung verändert die stabile Storage-ID nicht' -Success (
        [string]$renamed.Stores[0].PersistentStorageId -eq $storageId -and
        (& $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $renamed $configuration))

    $inventory = [PSCustomObject]@{
        Objects=@(
            [PSCustomObject]@{
                ObjectId='storage-object-111111111111111111111111'; ObjectClass='INSTANCE_STORE'; Provider='docker'; Lifecycle='RETAINED'
                AuditStatus='VERIFIED'; LogicalName='sql-lab-persistent-test'; RunIds=@($runId)
            },
            [PSCustomObject]@{
                ObjectId='storage-object-222222222222222222222222'; ObjectClass='INSTANCE_STORE'; Provider='podman'; Lifecycle='RETAINED'
                AuditStatus='VERIFIED'; LogicalName='sql-lab-persistent-unregistered'; RunIds=@()
            }
        )
    }
    $hashBefore = (Get-FileHash -LiteralPath $catalogPath1 -Algorithm SHA256).Hash
    $plan = & $module { param($cat,$inv) Get-LabPersistentStoragePlan -Catalog $cat -ResidencyInventory $inv } $catalog $inventory
    $hashAfter = (Get-FileHash -LiteralPath $catalogPath1 -Algorithm SHA256).Hash
    Add-CheckResult -Name 'Planner bindet Katalog-ID, Observation und exklusive Lease konsistent' -Success (
        $plan.Stores[0].PersistentStorageId -eq $storageId -and $plan.Stores[0].ObservationStatus -eq 'MATCHED' -and
        $plan.Stores[0].LeaseStatus -eq 'CONSISTENT')
    Add-CheckResult -Name 'Retained Objekt ohne Katalogeintrag bleibt ID-los als Registrierungskandidat sichtbar' -Success (
        @($plan.Actions | Where-Object { $_.Action -eq 'REGISTER_REQUIRED' -and -not $_.PersistentStorageId -and $_.InventoryObjectId -eq 'storage-object-222222222222222222222222' }).Count -eq 1)
    Add-CheckResult -Name 'Read-only Planner verändert keinen Katalogspiegel' -Success ($hashBefore -eq $hashAfter)
    Add-CheckResult -Name 'Plan erfüllt den eigenständigen versionierten JSON-Vertrag' -Success (
        $plan | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/persistent-storage-plan.schema.json'))

    $duplicate = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $duplicate.Stores = @($duplicate.Stores[0], ($duplicate.Stores[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30))
    Add-CheckResult -Name 'Doppelte PersistentStorageId wird fail-closed abgelehnt' -Success (Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_ID_DUPLICATE' -Action {
        & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $duplicate $configuration
    })

    $missingLease = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $missingLease.Stores[0].Lease = $null
    Add-CheckResult -Name 'IN_USE ohne exklusive Lease wird fail-closed abgelehnt' -Success (Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_LEASE_REQUIRED' -Action {
        & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $missingLease $configuration
    })

    $competingLeaseReference = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $competingLeaseReference.Stores[0].References += [PSCustomObject]@{
        ReferenceId=[Guid]::NewGuid().ToString('D'); Kind='RUN'; State='ACTIVE'; TargetId=[Guid]::NewGuid().ToString('D')
    }
    Add-CheckResult -Name 'Exklusive Lease blockiert eine zweite aktive Run-Referenz' -Success (Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_LEASE_REFERENCE_REQUIRED' -Action {
        & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $competingLeaseReference $configuration
    })

    $unsafePath = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $unsafePath.Stores[0].LocationBinding.RelativePath = '../outside'
    $driveRelativePath = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $driveRelativePath.Stores[0].LocationBinding.RelativePath = 'D:outside'
    Add-CheckResult -Name 'Katalogbindungen akzeptieren keine absoluten, laufwerksrelativen oder traversierenden portablen Pfade' -Success ((Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_RELATIVE_PATH_INVALID' -Action {
        & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $unsafePath $configuration
    }) -and (Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_RELATIVE_PATH_INVALID' -Action {
        & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $driveRelativePath $configuration
    }))

    $conflictDocument = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $conflictDocument.Stores[0].LocationBinding.InventoryObjectId = $null
    $conflictCatalog = [PSCustomObject]@{ Status='AVAILABLE'; Document=$conflictDocument; Sources=@(); Issues=@() }
    $conflictInventory = [PSCustomObject]@{ Objects=@(
        $inventory.Objects[0],
        [PSCustomObject]@{ ObjectId='storage-object-333333333333333333333333'; Provider='docker'; Lifecycle='RETAINED'; AuditStatus='VERIFIED'; LogicalName='sql-lab-persistent-test'; RunIds=@($runId) }
    ) }
    $conflictPlan = & $module { param($cat,$inv) Get-LabPersistentStoragePlan -Catalog $cat -ResidencyInventory $inv } $conflictCatalog $conflictInventory
    Add-CheckResult -Name 'Mehrdeutige Providerbindung blockiert statt einen Store zu raten' -Success (
        $conflictPlan.Status -eq 'BLOCKED' -and $conflictPlan.Summary.Blockers -eq 1 -and $conflictPlan.Stores[0].ObservationStatus -eq 'AMBIGUOUS')

    Set-Content -LiteralPath $catalogPath2 -Value (($renamed | ConvertTo-Json -Depth 30)) -Encoding utf8NoBOM
    $diverged = & $module { param($config) Get-LabPersistentStorageCatalog -Configuration $config } $configuration
    Add-CheckResult -Name 'Abweichende Katalogspiegel werden sichtbar blockiert' -Success (
        $diverged.Status -eq 'DIVERGED' -and 'PERSISTENT_STORAGE_CATALOG_DIVERGED' -in @($diverged.Issues))

    $withSecret = $document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $withSecret.Stores[0] | Add-Member -NotePropertyName Password -NotePropertyValue 'synthetic-secret'
    Add-CheckResult -Name 'Strenges Schema lässt keine Secretfelder in Stores zu' -Success (Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_CATALOG_SCHEMA_INVALID' -Action {
        & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $withSecret $configuration
    })
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
