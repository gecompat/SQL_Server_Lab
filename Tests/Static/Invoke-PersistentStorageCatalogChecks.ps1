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

    $externalDocument=$document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $externalStore=$externalDocument.Stores[0]
    $externalStore.State='DETACHED';$externalStore.Provider='external';$externalStore.Lease=$null
    $externalStore.Retention='EXTERNAL_UNMANAGED';$externalStore.CleanupDisposition='REPORT_ONLY'
    $externalStore.LocationBinding.Residency='EXTERNAL_HOST';$externalStore.LocationBinding.LocationId=$null
    $externalStore.LocationBinding.ProviderResourceId='external-catalog-test';$externalStore.LocationBinding.InventoryObjectId=$null
    $externalStore.References += [PSCustomObject]@{ReferenceId=[Guid]::NewGuid().ToString('D');Kind='DATABASE';State='ACTIVE';TargetId='ExternalCatalogTest'}
    $externalJson=$externalDocument | ConvertTo-Json -Depth 30
    Set-Content -LiteralPath $catalogPath1,$catalogPath2 -Value $externalJson -Encoding utf8NoBOM
    $externalEvidence=& $module {
        param($Configuration,$StorageId,$RunId)
        $first=Release-LabExternalPersistentStorageBinding -PersistentStorageId $StorageId -RunId $RunId -Configuration $Configuration -ExpectedRevision 4
        $second=Release-LabExternalPersistentStorageBinding -PersistentStorageId $StorageId -RunId $RunId -Configuration $Configuration -ExpectedRevision ([int]$first.CatalogRevision)
        $catalog=Get-LabPersistentStorageCatalog -Configuration $Configuration
        [PSCustomObject]@{First=$first;Second=$second;Store=@($catalog.Document.Stores | Where-Object PersistentStorageId -eq $StorageId)[0]}
    } $configuration $storageId $runId
    Add-CheckResult -Name 'Externe Bindungsfreigabe mutiert nur Katalogreferenzen, ist CAS-geschützt und idempotent' -Success (
        $externalEvidence.First.Changed -and [bool]$externalEvidence.First.Value.Released -and -not [bool]$externalEvidence.First.Value.SourceMutated -and
        -not $externalEvidence.Second.Changed -and -not [bool]$externalEvidence.Second.Value.Released -and
        [string]$externalEvidence.Store.LocationBinding.ProviderResourceId -eq 'external-catalog-test' -and
        @($externalEvidence.Store.References | Where-Object State -eq 'ACTIVE').Count -eq 0 -and
        @($externalEvidence.Store.References | Where-Object State -eq 'RELEASED').Count -eq 2)
    Set-Content -LiteralPath $catalogPath1,$catalogPath2 -Value $catalogJson -Encoding utf8NoBOM

    $backupSetId = [Guid]::NewGuid().ToString('D')
    $backupRecord = [PSCustomObject]@{
        BackupSetId=$backupSetId; Status='REUSABLE'; DatabaseName='CatalogedBackup'
        Source=[PSCustomObject]@{ Provider='podman'; RunId=$null; InstanceId='primary'; SqlMajorVersion='17' }
        Artifact=[PSCustomObject]@{ RelativePath='Objects/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.bak'; Sha256=('a' * 64); Bytes=42 }
        CreatedAt='2026-09-01T01:00:00Z'
    }
    $registered = & $module { param($record,$root,$config) Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $root -Configuration $config } $backupRecord $root1 $configuration
    $registeredAgain = & $module { param($record,$root,$config) Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $root -Configuration $config } $backupRecord $root1 $configuration
    $afterRegistration = & $module { param($config) Get-LabPersistentStorageCatalog -Configuration $config } $configuration
    $backupStore = @($afterRegistration.Document.Stores | Where-Object StorageClass -eq 'BACKUP_SET')
    Add-CheckResult -Name 'BACKUP_SET wird controllergebunden auf alle Roots gespiegelt und idempotent wiedererkannt' -Success (
        $registered.Changed -and -not $registeredAgain.Changed -and $afterRegistration.Status -eq 'AVAILABLE' -and
        @($afterRegistration.Sources).Count -eq 2 -and $afterRegistration.Document.Revision -eq 5 -and $backupStore.Count -eq 1 -and
        [string]$backupStore[0].References[0].TargetId -eq $backupSetId -and
        [string]$backupStore[0].LocationBinding.LocationId -eq $locationId1 -and
        [string]$backupStore[0].LocationBinding.RelativePath -match '^Backups/Objects/[a-f0-9]{64}\.bak$')
    $beforeArtifactCasHash1=(Get-FileHash -LiteralPath $catalogPath1 -Algorithm SHA256).Hash
    $beforeArtifactCasHash2=(Get-FileHash -LiteralPath $catalogPath2 -Algorithm SHA256).Hash
    $artifactCasBlocked=Test-ExpectedFailure -Pattern 'PERSISTENT_STORAGE_CATALOG_REVISION_CONFLICT' -Action {
        & $module {
            param($record,$root,$config)
            Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $root -Configuration $config -ExpectedRevision 4
        } $backupRecord $root1 $configuration
    }
    Add-CheckResult -Name 'Gemeinsamer Artifact-Writer blockiert auch einen veralteten No-op per Revision-CAS' -Success (
        $artifactCasBlocked -and
        (Get-FileHash -LiteralPath $catalogPath1 -Algorithm SHA256).Hash -eq $beforeArtifactCasHash1 -and
        (Get-FileHash -LiteralPath $catalogPath2 -Algorithm SHA256).Hash -eq $beforeArtifactCasHash2)

    $quarantinedRecord = $backupRecord | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $quarantinedRecord.Status = 'QUARANTINED'
    $quarantineSync = & $module { param($record,$root,$config) Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $root -Configuration $config } $quarantinedRecord $root1 $configuration
    $reusableSync = & $module { param($record,$root,$config) Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $root -Configuration $config } $backupRecord $root1 $configuration
    Add-CheckResult -Name 'Bestandsabgleich spiegelt Quarantäne und erneute Freigabe als katalogisierten Zustand' -Success (
        $quarantineSync.Changed -and $quarantineSync.Store.State -eq 'RECOVERY_REQUIRED' -and
        $reusableSync.Changed -and $reusableSync.Store.State -eq 'AVAILABLE')

    $conflictingRecord = $backupRecord | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $conflictingRecord.Source.Provider = 'docker'
    Add-CheckResult -Name 'Gleiche BackupSetId mit abweichender Bindung wird vor Katalogmutation blockiert' -Success (Test-ExpectedFailure -Pattern 'BACKUP_SET_STORAGE_BINDING_CONFLICT' -Action {
        & $module { param($record,$root,$config) Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $root -Configuration $config } $conflictingRecord $root1 $configuration
    })

    $rollbackRecord = $backupRecord | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $rollbackRecord.BackupSetId = [Guid]::NewGuid().ToString('D')
    $beforeRollbackHash1 = (Get-FileHash -LiteralPath $catalogPath1 -Algorithm SHA256).Hash
    $beforeRollbackHash2 = (Get-FileHash -LiteralPath $catalogPath2 -Algorithm SHA256).Hash
    $rollbackBlocked = & $module {
        param($record,$root,$config,$failPath)
        $original = (Get-Command Write-LabArtifactJsonAtomic -CommandType Function).ScriptBlock
        $failedOnce = $false
        $replacement = {
            param([string]$Path,$InputObject)
            if (-not $failedOnce -and [string]::Equals($Path,$failPath,[StringComparison]::OrdinalIgnoreCase)) {
                $failedOnce = $true; throw 'SYNTHETIC_SECOND_MIRROR_FAILURE'
            }
            & $original -Path $Path -InputObject $InputObject
        }.GetNewClosure()
        Set-Item Function:script:Write-LabArtifactJsonAtomic -Value $replacement
        try {
            Register-LabBackupSetPersistentStorage -BackupRecord $record -DataRoot $root -Configuration $config | Out-Null
            return $false
        }
        catch { return $_.Exception.Message -match 'PERSISTENT_STORAGE_CATALOG_WRITE_FAILED' }
        finally { Set-Item Function:script:Write-LabArtifactJsonAtomic -Value $original }
    } $rollbackRecord $root1 $configuration $catalogPath2
    Add-CheckResult -Name 'Fehler am zweiten Spiegel stellt die vorherige gemeinsame Revision wieder her' -Success (
        $rollbackBlocked -and (Get-FileHash -LiteralPath $catalogPath1 -Algorithm SHA256).Hash -eq $beforeRollbackHash1 -and
        (Get-FileHash -LiteralPath $catalogPath2 -Algorithm SHA256).Hash -eq $beforeRollbackHash2)

    $leaseRoot1 = Join-Path $temporaryRoot 'lease-one/Lab_Data'
    $leaseRoot2 = Join-Path $temporaryRoot 'lease-two/Lab_Data'
    New-Item -Path (Join-Path $leaseRoot1 'Catalog'),(Join-Path $leaseRoot2 'Catalog') -ItemType Directory -Force | Out-Null
    $leaseConfiguration = [PSCustomObject]@{
        ControllerId=[Guid]::NewGuid().ToString('D')
        LabDataLocations=@(
            [PSCustomObject]@{ LocationId=[Guid]::NewGuid().ToString('D'); LabDataRoot=$leaseRoot1 },
            [PSCustomObject]@{ LocationId=[Guid]::NewGuid().ToString('D'); LabDataRoot=$leaseRoot2 }
        )
    }
    $leaseRunId=[Guid]::NewGuid().ToString('D'); $leaseScopeId=[Guid]::NewGuid().ToString('D')
    $leaseEvidence = & $module {
        param($config,$root,$leaseRun,$leaseScope)
        $originalOwnership=(Get-Command Test-LabDataRootOwnership -CommandType Function).ScriptBlock
        $originalInspection=(Get-Command Get-LabContainerInstanceStoreRuntimeInspection -CommandType Function).ScriptBlock
        $script:leaseTestRuntimeStatus='MISSING'; $script:leaseTestRuntimeStorageId=$null
        $ownershipReplacement={ param($DataRoot,$ControllerId) $null=$DataRoot,$ControllerId; return $true }
        $inspectionReplacement={
            param($Provider,$VolumeName)
            if ($script:leaseTestRuntimeStatus -eq 'MISSING') {
                return [PSCustomObject]@{ Status='MISSING'; Provider=$Provider; VolumeName=$VolumeName; VolumeId=$null; Labels=[PSCustomObject]@{}; AttachedContainers=@() }
            }
            return [PSCustomObject]@{
                Status='AVAILABLE'; Provider=$Provider; VolumeName=$VolumeName; VolumeId=$VolumeName; AttachedContainers=@()
                Labels=[PSCustomObject]@{ 'sql-server-lab.persistent-storage-id'=$script:leaseTestRuntimeStorageId; 'sql-server-lab.sql-major-version'='2025' }
            }
        }
        Set-Item Function:script:Test-LabDataRootOwnership -Value $ownershipReplacement
        Set-Item Function:script:Get-LabContainerInstanceStoreRuntimeInspection -Value $inspectionReplacement
        try {
            $preRelease=Unregister-LabContainerInstanceStoreLease -Provider docker -VolumeName 'sql-lab-persistent-lease-test' `
                -RunId $leaseRun -ScopeId $leaseScope -DataRoot $root -Configuration $config
            $acquired=Register-LabContainerInstanceStoreLease -Provider docker -VolumeName 'sql-lab-persistent-lease-test' `
                -RunId $leaseRun -ScopeId $leaseScope -SqlVersion '2025-latest' -DisplayName 'Lease test' `
                -DataRoot $root -Configuration $config
            $script:leaseTestRuntimeStorageId=[string]$acquired.Store.PersistentStorageId; $script:leaseTestRuntimeStatus='AVAILABLE'
            $databaseReferences=Sync-LabContainerInstanceStoreDatabaseReference `
                -PersistentStorageId ([string]$acquired.Store.PersistentStorageId) -RunId $leaseRun -ScopeId $leaseScope `
                -DatabaseName @('ApplicationOne','ApplicationTwo') -Configuration $config
            $databaseReferencesAgain=Sync-LabContainerInstanceStoreDatabaseReference `
                -PersistentStorageId ([string]$acquired.Store.PersistentStorageId) -RunId $leaseRun -ScopeId $leaseScope `
                -DatabaseName @('ApplicationTwo','ApplicationOne') -Configuration $config
            $released=Unregister-LabContainerInstanceStoreLease -Provider docker -VolumeName 'sql-lab-persistent-lease-test' `
                -RunId $leaseRun -ScopeId $leaseScope -DataRoot $root -Configuration $config
            $reacquired=Register-LabContainerInstanceStoreLease -Provider docker -VolumeName 'sql-lab-persistent-lease-test' `
                -RunId $leaseRun -ScopeId $leaseScope -SqlVersion '2025-latest' -DisplayName 'Lease test' `
                -DataRoot $root -Configuration $config
            $foreignBlocked=$false
            try {
                Register-LabContainerInstanceStoreLease -Provider docker -VolumeName 'sql-lab-persistent-lease-test' `
                    -RunId ([Guid]::NewGuid().ToString('D')) -ScopeId ([Guid]::NewGuid().ToString('D')) `
                    -SqlVersion '2025-latest' -DisplayName 'Foreign lease' -DataRoot $root -Configuration $config | Out-Null
            }
            catch { $foreignBlocked=$_.Exception.Message -match 'CONTAINER_INSTANCE_STORE_LEASE_CONFLICT' }
            $script:leaseTestRuntimeStatus='MISSING'; $recoveryBlocked=$false
            try {
                Unregister-LabContainerInstanceStoreLease -Provider docker -VolumeName 'sql-lab-persistent-lease-test' `
                    -RunId $leaseRun -ScopeId $leaseScope -DataRoot $root -Configuration $config | Out-Null
            }
            catch { $recoveryBlocked=$_.Exception.Message -match 'CONTAINER_INSTANCE_STORE_RELEASE_RUNTIME_VERIFICATION_FAILED' }
            $after=Get-LabPersistentStorageCatalog -Configuration $config
            return [PSCustomObject]@{
                PreRelease=$preRelease; Acquired=$acquired; Released=$released; Reacquired=$reacquired; ForeignBlocked=$foreignBlocked
                DatabaseReferences=$databaseReferences; DatabaseReferencesAgain=$databaseReferencesAgain
                RecoveryBlocked=$recoveryBlocked; Catalog=$after
            }
        }
        finally {
            Set-Item Function:script:Test-LabDataRootOwnership -Value $originalOwnership
            Set-Item Function:script:Get-LabContainerInstanceStoreRuntimeInspection -Value $originalInspection
            Remove-Variable -Scope Script -Name leaseTestRuntimeStatus,leaseTestRuntimeStorageId -ErrorAction SilentlyContinue
        }
    } $leaseConfiguration $leaseRoot1 $leaseRunId $leaseScopeId
    $leaseStore=@($leaseEvidence.Catalog.Document.Stores)[0]
    Add-CheckResult -Name 'Vorab persistierte Cleanup-Kompensation bleibt ohne erworbene Lease ein No-op' -Success (
        -not $leaseEvidence.PreRelease.Changed -and $leaseEvidence.PreRelease.NotAcquired)
    Add-CheckResult -Name 'Regulärer persistenter Containerstore erhält vor Provisionierung eine stabile ID und exklusive Run-Lease' -Success (
        $leaseEvidence.Acquired.Changed -and -not $leaseEvidence.Acquired.Reused -and
        [string]$leaseEvidence.Acquired.Store.PersistentStorageId -match '^[0-9a-f-]{36}$' -and
        [string]$leaseEvidence.Acquired.Store.Lease.RunId -eq $leaseRunId -and
        @($leaseEvidence.Acquired.Store.References | Where-Object State -eq 'ACTIVE').Count -eq 1)
    Add-CheckResult -Name 'Verifizierte Datenbanken erhalten stabile idempotente Katalogreferenzen unter derselben Run-Lease' -Success (
        $leaseEvidence.DatabaseReferences.Changed -and -not $leaseEvidence.DatabaseReferencesAgain.Changed -and
        @($leaseEvidence.DatabaseReferences.Store.References | Where-Object {
            $_.Kind -eq 'DATABASE' -and $_.State -eq 'ACTIVE' -and $_.TargetId -in @('ApplicationOne','ApplicationTwo')
        }).Count -eq 2)
    Add-CheckResult -Name 'Release bewahrt den Runtime-Store, löst Lease sowie Run-/Datenbankreferenzen und erlaubt dieselbe stabile ID erneut' -Success (
        $leaseEvidence.Released.Store.State -eq 'DETACHED' -and -not $leaseEvidence.Released.Store.Lease -and
        @($leaseEvidence.Released.Store.References | Where-Object State -eq 'RELEASED').Count -eq 3 -and
        @($leaseEvidence.Released.Store.References | Where-Object { $_.Kind -eq 'DATABASE' -and $_.State -eq 'ACTIVE' }).Count -eq 0 -and
        $leaseEvidence.Reacquired.Reused -and
        [string]$leaseEvidence.Reacquired.Store.PersistentStorageId -eq [string]$leaseEvidence.Acquired.Store.PersistentStorageId)
    Add-CheckResult -Name 'Exklusive Instanzstore-Lease blockiert einen konkurrierenden Run' -Success $leaseEvidence.ForeignBlocked
    Add-CheckResult -Name 'Fehlendes oder abweichendes Runtime-Volume bleibt mit Lease als Recovery-Fall sichtbar' -Success (
        $leaseEvidence.RecoveryBlocked -and $leaseStore.State -eq 'RECOVERY_REQUIRED' -and
        [string]$leaseStore.Lease.RunId -eq $leaseRunId -and @($leaseEvidence.Catalog.Sources).Count -eq 2)

    $runScopedRoot = Join-Path $temporaryRoot 'run-scoped/Lab_Data'
    New-Item -Path (Join-Path $runScopedRoot 'Catalog') -ItemType Directory -Force | Out-Null
    $runScopedConfiguration = [PSCustomObject]@{
        ControllerId=[Guid]::NewGuid().ToString('D')
        LabDataLocations=@([PSCustomObject]@{ LocationId=[Guid]::NewGuid().ToString('D'); LabDataRoot=$runScopedRoot })
    }
    $runScopedRunId=[Guid]::NewGuid().ToString('D'); $runScopedScopeId=[Guid]::NewGuid().ToString('D')
    $runScopedEvidence = & $module {
        param($config,$root,$runId,$scopeId)
        $originalOwnership=(Get-Command Test-LabDataRootOwnership -CommandType Function).ScriptBlock
        $originalInspection=(Get-Command Get-LabContainerInstanceStoreRuntimeInspection -CommandType Function).ScriptBlock
        $script:runScopedStorageId=[Guid]::NewGuid().ToString('D'); $script:runScopedContainerId=('a' * 64)
        Set-Item Function:script:Test-LabDataRootOwnership -Value { param($DataRoot,$ControllerId) $null=$DataRoot,$ControllerId; return $true }
        Set-Item Function:script:Get-LabContainerInstanceStoreRuntimeInspection -Value {
            param($Provider,$VolumeName)
            [PSCustomObject]@{ Status='AVAILABLE'; Provider=$Provider; VolumeName=$VolumeName; VolumeId=$VolumeName; AttachedContainers=@($script:runScopedContainerId)
                Labels=[PSCustomObject]@{ 'sql-server-lab.persistent-storage-id'=$script:runScopedStorageId; 'sql-server-lab.run-id'=$runId; 'sql-server-lab.scope-id'=$scopeId; 'sql-server-lab.sql-major-version'='2025'; 'sql-server-lab.persistence'='run-scoped-runtime-volume' } }
        }
        try {
            $preview=Register-LabRunScopedContainerStore -Provider docker -VolumeName 'sql-lab-run-scoped-test' -RunId $runId -ScopeId $scopeId -ContainerId $script:runScopedContainerId -SqlVersion '2025-latest' -DisplayName 'Run scoped test' -DataRoot $root -Configuration $config -Preview
            $registered=Register-LabRunScopedContainerStore -Provider docker -VolumeName 'sql-lab-run-scoped-test' -RunId $runId -ScopeId $scopeId -ContainerId $script:runScopedContainerId -SqlVersion '2025-latest' -DisplayName 'Run scoped test' -DataRoot $root -Configuration $config -ExpectedRevision 0
            $again=Register-LabRunScopedContainerStore -Provider docker -VolumeName 'sql-lab-run-scoped-test' -RunId $runId -ScopeId $scopeId -ContainerId $script:runScopedContainerId -SqlVersion '2025-latest' -DisplayName 'Run scoped test' -DataRoot $root -Configuration $config -ExpectedRevision 1
            [PSCustomObject]@{ Preview=$preview; Registered=$registered; Again=$again }
        }
        finally {
            Set-Item Function:script:Test-LabDataRootOwnership -Value $originalOwnership
            Set-Item Function:script:Get-LabContainerInstanceStoreRuntimeInspection -Value $originalInspection
            Remove-Variable -Scope Script -Name runScopedStorageId,runScopedContainerId -ErrorAction SilentlyContinue
        }
    } $runScopedConfiguration $runScopedRoot $runScopedRunId $runScopedScopeId
    Add-CheckResult -Name 'Laufender labelgebundener Run-Store wird nur nach Container-Ownership revisionsgeschützt katalogisiert' -Success (
        $runScopedEvidence.Preview.Preview -and $runScopedEvidence.Preview.ProposedRevision -eq 1 -and
        $runScopedEvidence.Registered.Changed -and $runScopedEvidence.Registered.Store.Retention -eq 'RUN_SCOPED' -and
        $runScopedEvidence.Registered.Store.CleanupDisposition -eq 'RUN_CLEANUP' -and
        $runScopedEvidence.Registered.Store.Lease.RunId -eq $runScopedRunId -and
        -not $runScopedEvidence.Again.Changed)

    $publicRunScopedEvidence = & $module {
        param($config,$root)
        $runId=[Guid]::NewGuid().ToString('D');$scopeId=[Guid]::NewGuid().ToString('D');$storageId=[Guid]::NewGuid().ToString('D')
        $runDirectory=Join-Path (Join-Path $root 'state/runs') $runId;New-Item -ItemType Directory -Path $runDirectory -Force | Out-Null
        [PSCustomObject]@{runId=$runId;scopeId=$scopeId;instances=@([PSCustomObject]@{id='primary';containerId=('b'*64);containerName='public-run-store'})} | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $runDirectory 'connection-info.json') -Encoding utf8NoBOM
        $originalConfiguration=(Get-Command Get-LabStorageConfiguration -CommandType Function).ScriptBlock
        $originalResolver=(Get-Command Resolve-LabDataRootForUse -CommandType Function).ScriptBlock
        $originalRun=(Get-Command Get-LabRunState -CommandType Function).ScriptBlock
        $originalDesired=(Get-Command Get-LabPersistedDesiredState -CommandType Function).ScriptBlock
        $originalOwnership=(Get-Command Test-LabDataRootOwnership -CommandType Function).ScriptBlock
        $originalInspection=(Get-Command Get-LabContainerInstanceStoreRuntimeInspection -CommandType Function).ScriptBlock
        Set-Item Function:script:Get-LabStorageConfiguration -Value { param($DataRoot) $null=$DataRoot; $config }
        Set-Item Function:script:Resolve-LabDataRootForUse -Value { param($DataRoot) $null=$DataRoot; $root }
        Set-Item Function:script:Get-LabRunState -Value { param($RunId,$StateRoot) $null=$RunId,$StateRoot;[PSCustomObject]@{state='RUNNING';scopeId=$scopeId} }
        Set-Item Function:script:Get-LabPersistedDesiredState -Value { param($RunId,$StateRoot) $null=$RunId,$StateRoot;[PSCustomObject]@{Status='VALID';Snapshot=[PSCustomObject]@{LabName='Public run store';Instances=@([PSCustomObject]@{Id='primary';Provider='docker';Version='2025-latest';Intents=[PSCustomObject]@{Drives=@([PSCustomObject]@{Id='runtime-mssql';Persistence='run-scoped-runtime-volume';PersistentStorageId=$storageId})}})}} }
        Set-Item Function:script:Test-LabDataRootOwnership -Value { param($DataRoot,$ControllerId) $null=$DataRoot,$ControllerId;$true }
        Set-Item Function:script:Get-LabContainerInstanceStoreRuntimeInspection -Value { param($Provider,$VolumeName) [PSCustomObject]@{Status='AVAILABLE';Provider=$Provider;VolumeName=$VolumeName;VolumeId=$VolumeName;AttachedContainers=@(('b'*64));Labels=[PSCustomObject]@{'sql-server-lab.persistent-storage-id'=$storageId;'sql-server-lab.run-id'=$runId;'sql-server-lab.scope-id'=$scopeId;'sql-server-lab.sql-major-version'='2025';'sql-server-lab.persistence'='run-scoped-runtime-volume'}} }
        try {
            $planned=Sync-SqlServerLabRunScopedContainerStore -RunId $runId -InstanceId primary -DataRoot $root -StateRoot (Join-Path $root 'state') -WhatIf
            $applied=Sync-SqlServerLabRunScopedContainerStore -RunId $runId -InstanceId primary -DataRoot $root -StateRoot (Join-Path $root 'state') -Confirm:$false
            $again=Sync-SqlServerLabRunScopedContainerStore -RunId $runId -InstanceId primary -DataRoot $root -StateRoot (Join-Path $root 'state') -Confirm:$false
            $catalog=Get-LabPersistentStorageCatalog -Configuration $config
            [PSCustomObject]@{Planned=$planned;Applied=$applied;Again=$again;Catalog=$catalog;RunId=$runId;ScopeId=$scopeId;StorageId=$storageId}
        }
        finally {
            Set-Item Function:script:Get-LabStorageConfiguration -Value $originalConfiguration
            Set-Item Function:script:Resolve-LabDataRootForUse -Value $originalResolver
            Set-Item Function:script:Get-LabRunState -Value $originalRun
            Set-Item Function:script:Get-LabPersistedDesiredState -Value $originalDesired
            Set-Item Function:script:Test-LabDataRootOwnership -Value $originalOwnership
            Set-Item Function:script:Get-LabContainerInstanceStoreRuntimeInspection -Value $originalInspection
        }
    } $runScopedConfiguration $runScopedRoot
    $publicRunScopedStore=@($publicRunScopedEvidence.Catalog.Document.Stores | Where-Object PersistentStorageId -eq $publicRunScopedEvidence.StorageId)[0]
    Add-CheckResult -Name 'Öffentlicher Run-Store-Sync plant mutationsfrei, übernimmt dieselbe Stable-ID und bleibt idempotent' -Success (
        $publicRunScopedEvidence.Planned.Status -eq 'PLANNED' -and -not $publicRunScopedEvidence.Planned.Changed -and $publicRunScopedEvidence.Planned.WouldChange -and
        $publicRunScopedEvidence.Applied.Status -eq 'SYNCED' -and $publicRunScopedEvidence.Applied.Changed -and
        $publicRunScopedEvidence.Again.Status -eq 'NO_CHANGE' -and -not $publicRunScopedEvidence.Again.Changed -and
        [string]$publicRunScopedStore.PersistentStorageId -eq [string]$publicRunScopedEvidence.StorageId -and
        [string]$publicRunScopedStore.Lease.RunId -eq [string]$publicRunScopedEvidence.RunId -and
        [string]$publicRunScopedStore.Lease.ScopeId -eq [string]$publicRunScopedEvidence.ScopeId)

    $hyperVRoot1 = Join-Path $temporaryRoot 'hyperv-one/Lab_Data'
    $hyperVRoot2 = Join-Path $temporaryRoot 'hyperv-two/Lab_Data'
    New-Item -Path (Join-Path $hyperVRoot1 'Catalog'),(Join-Path $hyperVRoot2 'Catalog') -ItemType Directory -Force | Out-Null
    $hyperVConfiguration = [PSCustomObject]@{
        ControllerId=[Guid]::NewGuid().ToString('D')
        LabDataLocations=@(
            [PSCustomObject]@{ LocationId=[Guid]::NewGuid().ToString('D'); LabDataRoot=$hyperVRoot1 },
            [PSCustomObject]@{ LocationId=[Guid]::NewGuid().ToString('D'); LabDataRoot=$hyperVRoot2 }
        )
    }
    $hyperVRunId=[Guid]::NewGuid().ToString('D'); $hyperVScopeId=[Guid]::NewGuid().ToString('D')
    $hyperVRelativePath='Labs/catalog-test/Instances/hyperv/primary/SqlServer/2025/sql-data.vhdx'
    $hyperVDiskId=[Guid]::NewGuid().ToString('D').ToUpperInvariant()
    $hyperVEvidence = & $module {
        param($config,$root,$relativePath,$runId,$scopeId,$diskId)
        $originalOwnership=(Get-Command Test-LabDataRootOwnership -CommandType Function).ScriptBlock
        Set-Item Function:script:Test-LabDataRootOwnership -Value { param($DataRoot,$ControllerId) $null=$DataRoot,$ControllerId; return $true }
        try {
            $catalogPaths=@($config.LabDataLocations | ForEach-Object { Join-Path ([string]$_.LabDataRoot) 'Catalog/persistent-stores.json' })
            $preview=Register-LabHyperVInstanceStoreReservation -RunId $runId -ScopeId $scopeId `
                -DisplayName 'Hyper-V catalog test' -DataRoot $root -RelativePath $relativePath `
                -Configuration $config -ExpectedRevision 0 -Preview
            $previewWasReadOnly=@($catalogPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 0
            $reserved=Register-LabHyperVInstanceStoreReservation -RunId $runId -ScopeId $scopeId `
                -DisplayName 'Hyper-V catalog test' -DataRoot $root -RelativePath $relativePath `
                -Configuration $config -ExpectedRevision 0
            $reservationHashes=@($catalogPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
            $staleReservationBlocked=$false
            try {
                Register-LabHyperVInstanceStoreReservation -RunId $runId -ScopeId $scopeId `
                    -DisplayName 'Hyper-V catalog test' -DataRoot $root -RelativePath $relativePath `
                    -Configuration $config -ExpectedRevision 0 | Out-Null
            }
            catch { $staleReservationBlocked=$_.Exception.Message -match 'PERSISTENT_STORAGE_CATALOG_REVISION_CONFLICT' }
            $staleReservationReadOnly=(@($catalogPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join '|') -eq ($reservationHashes -join '|')
            $absolutePath=Join-Path $root $relativePath
            New-Item -ItemType Directory -Path (Split-Path -Parent $absolutePath) -Force | Out-Null
            New-Item -ItemType File -Path $absolutePath -Force | Out-Null
            $recovery=Set-LabHyperVInstanceStoreRecoveryRequired -PersistentStorageId ([string]$reserved.Store.PersistentStorageId) `
                -RunId $runId -ScopeId $scopeId -Configuration $config -ExpectedRevision ([int]$reserved.CatalogRevision)
            $resumed=Register-LabHyperVInstanceStoreReservation -RunId $runId -ScopeId $scopeId `
                -DisplayName 'Hyper-V catalog test' -DataRoot $root -RelativePath $relativePath `
                -Configuration $config -ExpectedRevision ([int]$recovery.CatalogRevision)
            $completed=Complete-LabHyperVInstanceStoreReservation -PersistentStorageId ([string]$reserved.Store.PersistentStorageId) `
                -RunId $runId -ScopeId $scopeId -DiskIdentifier $diskId -Configuration $config `
                -ExpectedRevision ([int]$resumed.CatalogRevision)
            $completedAgain=Complete-LabHyperVInstanceStoreReservation -PersistentStorageId ([string]$reserved.Store.PersistentStorageId) `
                -RunId $runId -ScopeId $scopeId -DiskIdentifier $diskId -Configuration $config `
                -ExpectedRevision ([int]$completed.CatalogRevision)
            $completionHashes=@($catalogPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
            $staleCompletionBlocked=$false
            try {
                Complete-LabHyperVInstanceStoreReservation -PersistentStorageId ([string]$reserved.Store.PersistentStorageId) `
                    -RunId $runId -ScopeId $scopeId -DiskIdentifier $diskId -Configuration $config `
                    -ExpectedRevision ([int]$recovery.CatalogRevision) | Out-Null
            }
            catch { $staleCompletionBlocked=$_.Exception.Message -match 'PERSISTENT_STORAGE_CATALOG_REVISION_CONFLICT' }
            $staleCompletionReadOnly=(@($catalogPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash }) -join '|') -eq ($completionHashes -join '|')
            $foreignBlocked=$false
            try {
                Register-LabHyperVInstanceStoreReservation -RunId ([Guid]::NewGuid().ToString('D')) `
                    -ScopeId ([Guid]::NewGuid().ToString('D')) -DisplayName 'Foreign Hyper-V store' `
                    -DataRoot $root -RelativePath $relativePath -Configuration $config | Out-Null
            }
            catch { $foreignBlocked=$_.Exception.Message -match 'HYPERV_INSTANCE_STORE_RESERVATION_CONFLICT' }
            $catalog=Get-LabPersistentStorageCatalog -Configuration $config
            $activeRun=[PSCustomObject]@{
                runId=$runId
                instances=@([PSCustomObject]@{
                    provider='hyperv'; drives=@()
                    persistentStorage=[PSCustomObject]@{
                        hostPath=$absolutePath; persistentStorageId=[string]$reserved.Store.PersistentStorageId
                        locationId=[string]$reserved.LocationId; relativePath=[string]$reserved.RelativePath
                    }
                })
            }
            $originalBackupPaths=(Get-Command Get-LabBackupLibraryPaths -CommandType Function).ScriptBlock
            $originalBackupDocument=(Get-Command Get-LabBackupLibraryDocument -CommandType Function).ScriptBlock
            $originalPackagePaths=(Get-Command Get-LabDatabasePackagePaths -CommandType Function).ScriptBlock
            $originalPackageDocument=(Get-Command Get-LabDatabasePackageDocument -CommandType Function).ScriptBlock
            try {
                Set-Item Function:script:Get-LabBackupLibraryPaths -Value { param($DataRoot) [PSCustomObject]@{ DataRoot=$DataRoot; LibraryRoot=(Join-Path $DataRoot 'Backups') } }
                Set-Item Function:script:Get-LabBackupLibraryDocument -Value { param($Paths) $null=$Paths; [PSCustomObject]@{ Backups=@() } }
                Set-Item Function:script:Get-LabDatabasePackagePaths -Value { param($DataRoot) [PSCustomObject]@{ DataRoot=$DataRoot; ObjectsRoot=(Join-Path $DataRoot 'Packages') } }
                Set-Item Function:script:Get-LabDatabasePackageDocument -Value { param($Paths) $null=$Paths; [PSCustomObject]@{ Packages=@() } }
                $inventory=Get-LabStorageResidencyInventory -Configuration $config -StateRoot (Join-Path $root 'State') -ActiveRuns @($activeRun)
                $plan=Get-LabPersistentStoragePlan -Catalog $catalog -ResidencyInventory $inventory
            }
            finally {
                Set-Item Function:script:Get-LabBackupLibraryPaths -Value $originalBackupPaths
                Set-Item Function:script:Get-LabBackupLibraryDocument -Value $originalBackupDocument
                Set-Item Function:script:Get-LabDatabasePackagePaths -Value $originalPackagePaths
                Set-Item Function:script:Get-LabDatabasePackageDocument -Value $originalPackageDocument
            }
            [PSCustomObject]@{
                Preview=$preview; PreviewWasReadOnly=$previewWasReadOnly; Reserved=$reserved
                StaleReservationBlocked=$staleReservationBlocked; StaleReservationReadOnly=$staleReservationReadOnly
                Recovery=$recovery; Resumed=$resumed; Completed=$completed; CompletedAgain=$completedAgain
                StaleCompletionBlocked=$staleCompletionBlocked; StaleCompletionReadOnly=$staleCompletionReadOnly
                ForeignBlocked=$foreignBlocked; Catalog=$catalog; Inventory=$inventory; Plan=$plan
            }
        }
        finally { Set-Item Function:script:Test-LabDataRootOwnership -Value $originalOwnership }
    } $hyperVConfiguration $hyperVRoot1 $hyperVRelativePath $hyperVRunId $hyperVScopeId $hyperVDiskId
    $hyperVStore=@($hyperVEvidence.Catalog.Document.Stores)[0]
    Add-CheckResult -Name 'Hyper-V-Reservierung plant read-only und bindet Apply per Revision an denselben Katalogstand' -Success (
        $hyperVEvidence.Preview.Changed -and $hyperVEvidence.Preview.Preview -and
        $hyperVEvidence.Preview.CatalogRevision -eq 0 -and $hyperVEvidence.Preview.ProposedRevision -eq 1 -and
        $hyperVEvidence.PreviewWasReadOnly -and $hyperVEvidence.StaleReservationBlocked -and
        $hyperVEvidence.StaleReservationReadOnly)
    Add-CheckResult -Name 'Reguläre Hyper-V-VHDX erhält vor der Mutation eine stabile INCOMPLETE-Reservierung und Run-Lease' -Success (
        $hyperVEvidence.Reserved.Changed -and -not $hyperVEvidence.Reserved.Reused -and
        $hyperVEvidence.Reserved.Store.State -eq 'INCOMPLETE' -and
        [string]$hyperVEvidence.Reserved.Store.Lease.RunId -eq $hyperVRunId -and
        [string]$hyperVEvidence.Reserved.Store.LocationBinding.RelativePath -eq $hyperVRelativePath)
    Add-CheckResult -Name 'Hyper-V-Abbruch bleibt sichtbar und verwendet beim Resume dieselbe Storage-ID' -Success (
        $hyperVEvidence.Recovery.Changed -and $hyperVEvidence.Recovery.Store.State -eq 'RECOVERY_REQUIRED' -and
        -not $hyperVEvidence.Resumed.Changed -and $hyperVEvidence.Resumed.Reused -and
        [string]$hyperVEvidence.Resumed.Store.PersistentStorageId -eq [string]$hyperVEvidence.Reserved.Store.PersistentStorageId)
    Add-CheckResult -Name 'Verifizierte Hyper-V-Disk-ID committed idempotent auf IN_USE und blockiert fremde Runs' -Success (
        $hyperVEvidence.Completed.Changed -and -not $hyperVEvidence.CompletedAgain.Changed -and $hyperVEvidence.ForeignBlocked -and
        $hyperVEvidence.StaleCompletionBlocked -and $hyperVEvidence.StaleCompletionReadOnly -and
        $hyperVStore.State -eq 'IN_USE' -and [string]$hyperVStore.LocationBinding.ProviderResourceId -eq $hyperVDiskId -and
        @($hyperVEvidence.Catalog.Sources).Count -eq 2)
    Add-CheckResult -Name 'Residency-Audit korreliert die katalogisierte Hyper-V-VHDX über dieselbe stabile Objektidentität' -Success (
        @($hyperVEvidence.Inventory.Objects | Where-Object {
            [string]$_.ObjectId -eq [string]$hyperVStore.LocationBinding.InventoryObjectId -and
            [string]$_.Provider -eq 'hyperv' -and [string]$_.ObjectClass -eq 'INSTANCE_STORE' -and $hyperVRunId -in @($_.RunIds)
        }).Count -eq 1 -and $hyperVEvidence.Plan.Status -eq 'READY' -and
        $hyperVEvidence.Plan.Stores[0].ObservationStatus -eq 'MATCHED' -and $hyperVEvidence.Plan.Stores[0].LeaseStatus -eq 'CONSISTENT')
    $hyperVEnvironmentText=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/HyperVLabEnvironment.ps1') -Raw -Encoding utf8
    $hyperVProviderText=Get-Content -LiteralPath (Join-Path $repoRoot 'Providers/HyperV/HyperVProvider.ps1') -Raw -Encoding utf8
    $catalogWriterText=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/PersistentStorageCatalog.ps1') -Raw -Encoding utf8
    $hyperVReservationWriterStart=$catalogWriterText.IndexOf('function Register-LabHyperVInstanceStoreReservation')
    $hyperVReservationWriterEnd=$catalogWriterText.IndexOf('function Set-LabHyperVPersistentDataOperationLease')
    $hyperVReservationWriterText=$catalogWriterText.Substring(
        $hyperVReservationWriterStart,
        $hyperVReservationWriterEnd - $hyperVReservationWriterStart)
    Add-CheckResult -Name 'Alle regulären Hyper-V-Instanzstore-Writer verwenden ausschließlich den gemeinsamen Mutationskern' -Success (
        $hyperVReservationWriterStart -ge 0 -and $hyperVReservationWriterEnd -gt $hyperVReservationWriterStart -and
        @([regex]::Matches($hyperVReservationWriterText,'Invoke-LabPersistentStorageCatalogMutation')).Count -eq 3 -and
        $hyperVReservationWriterText -notmatch 'Invoke-LabPersistentStorageCatalogLock' -and
        $hyperVReservationWriterText -notmatch 'Write-LabPersistentStorageCatalogDocument')
    Add-CheckResult -Name 'Regulärer Hyper-V-Erstellungsflow reserviert vor New-VHD und committed erst nach Attachment' -Success (
        $hyperVEnvironmentText.IndexOf('Register-LabHyperVInstanceStoreReservation') -lt $hyperVEnvironmentText.IndexOf('New-VHD -Path $storage.HyperVVhdxPath') -and
        $hyperVEnvironmentText.IndexOf('Complete-LabHyperVInstanceStoreReservation') -gt $hyperVEnvironmentText.IndexOf('Add-VMHardDiskDrive -VMName $lab.Instance.vmName') -and
        $hyperVEnvironmentText -match 'Set-LabHyperVInstanceStoreRecoveryRequired' -and
        $hyperVEnvironmentText -match '-ExpectedRevision \(\[int\]\$reservation\.CatalogRevision\)')
    Add-CheckResult -Name 'Hyper-V-VM-Identität trägt stabile Storage-ID, Retention und Cleanup-Disposition' -Success (
        $hyperVProviderText -match 'persistentStorageId = if \(\$_\.PersistentStorageId\)' -and
        $hyperVProviderText -match 'cleanupDisposition = if \(\$_\.CleanupDisposition\)')

    $enableDataRoot=Join-Path $temporaryRoot 'hyperv-enable/Lab_Data'
    $enableStateRoot=Join-Path $temporaryRoot 'hyperv-enable/State'
    $enableEvidence = & $module {
        param($dataRoot,$stateRoot)
        $previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
        $originals=@{}
        foreach($name in @('Get-HyperVLabVMs','Get-HyperVManagedVM','New-VHD','Get-VHD','Get-LabHyperVPersistentDataRuntimeInspection','Add-VMHardDiskDrive','Get-VMHardDiskDrive','Set-VMHardDiskDrive','Set-VM','Write-LabSuccess')) {
            $command=Get-Command $name -ErrorAction SilentlyContinue
            $originals[$name]=if($command -and $command.CommandType -eq 'Function'){$command.ScriptBlock}else{$null}
        }
        try {
            $null=Initialize-LabManagedDataRoot -DataRoot $dataRoot -Confirm:$false
            $env:SQL_SERVER_LAB_DATA_ROOT=$dataRoot
            $run=New-LabRunState -StateRoot $stateRoot -Metadata @{ name='Hyper-V persistent catalog'; workflowKind='hyperv-lab' } `
                -ProviderSubRuns @([PSCustomObject]@{ id='provider-hyperv'; provider='hyperv'; instanceIds=@('primary') })
            $vmId=[Guid]::NewGuid().ToString('D'); $vmName='sql-lab-hyperv-persistent-catalog'
            Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir 'connection-info.json') -InputObject ([PSCustomObject]@{
                instances=@([PSCustomObject]@{ id='primary'; provider='hyperv'; vmName=$vmName; vmId=$vmId; sqlVersion='2025' })
            })
            $script:enableAttached=$false; $script:enableNewVhdCalls=0; $script:enableReservedBeforeMutation=$false
            $script:enableDiskId=[Guid]::NewGuid().ToString('D').ToUpperInvariant()
            $script:enableRunId=[string]$run.RunId; $script:enableScopeId=[string]$run.ScopeId
            $script:enableVmId=$vmId; $script:enableVmName=$vmName
            Set-Item Function:script:Get-HyperVLabVMs -Value {
                param($RunId,$ScopeId) $null=$RunId,$ScopeId
                [PSCustomObject]@{ VMName=$script:enableVmName; VMId=$script:enableVmId; State='Off' }
            }
            Set-Item Function:script:Get-HyperVManagedVM -Value {
                param($VMName,$ExpectedRunId,$ExpectedScopeId) $null=$VMName,$ExpectedRunId,$ExpectedScopeId
                [PSCustomObject]@{
                    VM=[PSCustomObject]@{ Id=$script:enableVmId; State='Off'; Name=$script:enableVmName }
                    Identity=[PSCustomObject]@{
                        provider='hyperv'; runId=$script:enableRunId; scopeId=$script:enableScopeId; instanceId='primary'
                        childVhdxPath=(Join-Path ([IO.Path]::GetTempPath()) 'synthetic-os-child.vhdx'); additionalDrives=@()
                    }
                }
            }
            Set-Item Function:script:New-VHD -Value {
                [CmdletBinding()]param($Path,[switch]$Dynamic,$SizeBytes)
                $null=$Dynamic,$SizeBytes; $script:enableNewVhdCalls++
                $configuration=Get-LabStorageConfiguration
                $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
                $script:enableReservedBeforeMutation=@($catalog.Document.Stores | Where-Object {
                    $_.Provider -eq 'hyperv' -and $_.State -eq 'INCOMPLETE' -and $_.Lease.RunId -eq $script:enableRunId
                }).Count -eq 1
                New-Item -ItemType File -Path $Path -Force | Out-Null
            }
            Set-Item Function:script:Get-VHD -Value {
                [CmdletBinding()]param($Path) $null=$Path
                [PSCustomObject]@{ Size=32GB; FileSize=1MB; VhdType='Dynamic'; DiskIdentifier=$script:enableDiskId; ParentPath=$null }
            }
            Set-Item Function:script:Get-LabHyperVPersistentDataRuntimeInspection -Value {
                param($Path,$TargetVMName) $null=$Path,$TargetVMName
                $attachments=if($script:enableAttached){@([PSCustomObject]@{ VMName=$script:enableVmName; VMId=$script:enableVmId; VMState='Off'; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=1 })}else{@()}
                [PSCustomObject]@{
                    Status='AVAILABLE'; DiskIdentifier=$script:enableDiskId; Attachments=$attachments; CheckpointReferences=@()
                    Target=[PSCustomObject]@{ Status='AVAILABLE'; VMId=$script:enableVmId; State='Off'; CheckpointCount=0 }
                }
            }
            Set-Item Function:script:Add-VMHardDiskDrive -Value {
                [CmdletBinding()]param($VMName,$ControllerType,$ControllerNumber,$Path,[switch]$Passthru)
                $null=$VMName,$ControllerType,$ControllerNumber,$Passthru; $script:enableAttached=$true
                [PSCustomObject]@{ Path=$Path; ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=1 }
            }
            Set-Item Function:script:Get-VMHardDiskDrive -Value {
                [CmdletBinding()]param($VMName,$ControllerType,$ControllerNumber,$ControllerLocation)
                $null=$VMName,$ControllerType,$ControllerNumber,$ControllerLocation
                $configuration=Get-LabStorageConfiguration; $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
                $store=@($catalog.Document.Stores | Where-Object Provider -eq 'hyperv')[0]
                $root=@($configuration.LabDataLocations | Where-Object LocationId -eq $store.LocationBinding.LocationId)[0].LabDataRoot
                [PSCustomObject]@{ Path=(Join-Path $root $store.LocationBinding.RelativePath); ControllerType='SCSI'; ControllerNumber=0; ControllerLocation=1 }
            }
            Set-Item Function:script:Set-VMHardDiskDrive -Value { [CmdletBinding()]param($VMHardDiskDrive,$MaximumIOPS) $null=$VMHardDiskDrive,$MaximumIOPS }
            Set-Item Function:script:Set-VM -Value { [CmdletBinding()]param($VMName,$Notes,$AutomaticCheckpointsEnabled) $null=$VMName,$Notes,$AutomaticCheckpointsEnabled }
            Set-Item Function:script:Write-LabSuccess -Value { param($Message) $null=$Message }

            $first=Enable-HyperVLabPersistentData -RunId $run.RunId -DataRoot $dataRoot -SizeGB 32 -StateRoot $stateRoot
            $second=Enable-HyperVLabPersistentData -RunId $run.RunId -DataRoot $dataRoot -SizeGB 32 -StateRoot $stateRoot
            $configuration=Get-LabStorageConfiguration -DataRoot $dataRoot
            $catalog=Get-LabPersistentStorageCatalog -Configuration $configuration
            $connection=Get-Content -LiteralPath (Join-Path $run.RunDir 'connection-info.json') -Raw | ConvertFrom-Json -Depth 20
            [PSCustomObject]@{
                First=$first; Second=$second; Catalog=$catalog; Connection=$connection
                NewVhdCalls=$script:enableNewVhdCalls; ReservedBeforeMutation=$script:enableReservedBeforeMutation
            }
        }
        finally {
            foreach($name in $originals.Keys) {
                if($originals[$name]){Set-Item "Function:script:$name" -Value $originals[$name]}
                else{Remove-Item "Function:script:$name" -ErrorAction SilentlyContinue}
            }
            $env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot
            Remove-Variable -Scope Script -Name enableAttached,enableNewVhdCalls,enableReservedBeforeMutation,enableDiskId,enableRunId,enableScopeId,enableVmId,enableVmName -ErrorAction SilentlyContinue
        }
    } $enableDataRoot $enableStateRoot
    $enabledStore=@($enableEvidence.Catalog.Document.Stores | Where-Object Provider -eq 'hyperv')[0]
    Add-CheckResult -Name 'Regulärer Hyper-V-Enable-Pfad ist nach reservierter Erstellung und Attachment vollständig idempotent' -Success (
        $enableEvidence.ReservedBeforeMutation -and $enableEvidence.NewVhdCalls -eq 1 -and
        $enabledStore.State -eq 'IN_USE' -and [string]$enabledStore.PersistentStorageId -eq [string]$enableEvidence.First.persistentStorageId -and
        [string]$enableEvidence.Second.persistentStorageId -eq [string]$enableEvidence.First.persistentStorageId -and
        [string]$enableEvidence.Connection.instances[0].persistentStorage.persistentStorageId -eq [string]$enabledStore.PersistentStorageId -and
        [int]$enableEvidence.Connection.instances[0].persistentStorage.catalogRevision -eq [int]$enableEvidence.Catalog.Document.Revision)

    $exchangeRoot1=Join-Path $temporaryRoot 'exchange-one/Lab_Data'
    $exchangeRoot2=Join-Path $temporaryRoot 'exchange-two/Lab_Data'
    $exchangeRelativePath='Exchange/import-one'
    $exchangePath=Join-Path $exchangeRoot1 $exchangeRelativePath
    $exchangeStateRoot=Join-Path $temporaryRoot 'exchange-state'
    New-Item -Path (Join-Path $exchangeRoot1 'Catalog'),(Join-Path $exchangeRoot2 'Catalog'),$exchangePath,$exchangeStateRoot -ItemType Directory -Force | Out-Null
    Set-Content -LiteralPath (Join-Path $exchangePath 'payload.bin') -Value 'exchange-payload' -Encoding utf8NoBOM
    $exchangeConfiguration=[PSCustomObject]@{
        ControllerId=[Guid]::NewGuid().ToString('D')
        LabDataLocations=@(
            [PSCustomObject]@{ LocationId=[Guid]::NewGuid().ToString('D'); LabDataRoot=$exchangeRoot1 },
            [PSCustomObject]@{ LocationId=[Guid]::NewGuid().ToString('D'); LabDataRoot=$exchangeRoot2 }
        )
    }
    $exchangeWorkspaceId=[Guid]::NewGuid().ToString('D')
    $exchangeEvidence=& $module {
        param($config,$root,$relativePath,$stateRoot,$workspaceId)
        $originalConfiguration=(Get-Command Get-LabStorageConfiguration -CommandType Function).ScriptBlock
        $originalResolver=(Get-Command Resolve-LabDataRootForUse -CommandType Function).ScriptBlock
        $originalOwnership=(Get-Command Test-LabDataRootOwnership -CommandType Function).ScriptBlock
        $script:exchangeTestConfiguration=$config; $script:exchangeTestRoot=$root
        Set-Item Function:script:Get-LabStorageConfiguration -Value { param($DataRoot) $null=$DataRoot; return $script:exchangeTestConfiguration }
        Set-Item Function:script:Resolve-LabDataRootForUse -Value { param($DataRoot) $null=$DataRoot; return $script:exchangeTestRoot }
        Set-Item Function:script:Test-LabDataRootOwnership -Value { param($DataRoot,$ControllerId) $null=$DataRoot,$ControllerId; return $true }
        try {
            $internalPreview=Register-LabExchangeWorkspacePersistentStorage -WorkspaceId $workspaceId -DisplayName 'Import one' `
                -DataRoot $root -RelativePath $relativePath -Configuration $config -ExpectedRevision 0 -Preview
            $planned=Sync-SqlServerLabPersistentStorageArtifact -ExchangeWorkspaceId $workspaceId `
                -RelativePath $relativePath -DisplayName 'Import one' -DataRoot $root -WhatIf
            $catalogPaths=@($config.LabDataLocations | ForEach-Object { Join-Path ([string]$_.LabDataRoot) 'Catalog/persistent-stores.json' })
            $previewWasReadOnly=@($catalogPaths | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }).Count -eq 0
            $applied=Sync-SqlServerLabPersistentStorageArtifact -ExchangeWorkspaceId $workspaceId `
                -RelativePath $relativePath -DisplayName 'Import one' -DataRoot $root -Confirm:$false
            $again=Sync-SqlServerLabPersistentStorageArtifact -ExchangeWorkspaceId $workspaceId `
                -RelativePath $relativePath -DisplayName 'Import one' -DataRoot $root -Confirm:$false
            $catalog=Get-LabPersistentStorageCatalog -Configuration $config
            $store=@($catalog.Document.Stores | Where-Object StorageClass -eq 'EXCHANGE_WORKSPACE')[0]
            $hashesBefore=@($catalogPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
            $staleBlocked=$false
            try {
                Register-LabExchangeWorkspacePersistentStorage -WorkspaceId ([Guid]::NewGuid().ToString('D')) -DisplayName 'Stale' `
                    -DataRoot $root -RelativePath $relativePath -Configuration $config -ExpectedRevision 0 | Out-Null
            }
            catch { $staleBlocked=$_.Exception.Message -match 'PERSISTENT_STORAGE_CATALOG_REVISION_CONFLICT' }
            $scopeBlocked=$false
            try {
                Invoke-LabPersistentStorageCatalogMutation -Configuration $config -MutationName INVALID_SCOPE -ExpectedRevision 1 -Mutation {
                    param($document) $document.ControllerId=[Guid]::NewGuid().ToString('D')
                } | Out-Null
            }
            catch { $scopeBlocked=$_.Exception.Message -match 'PERSISTENT_STORAGE_CATALOG_MUTATION_SCOPE_VIOLATION' }
            $unsafeBlocked=$false
            try {
                Register-LabExchangeWorkspacePersistentStorage -WorkspaceId ([Guid]::NewGuid().ToString('D')) -DisplayName 'Unsafe' `
                    -DataRoot $root -RelativePath '../outside' -Configuration $config -ExpectedRevision 1 | Out-Null
            }
            catch { $unsafeBlocked=$_.Exception.Message -match 'EXCHANGE_WORKSPACE_RELATIVE_PATH_INVALID' }
            try {
                Register-LabExchangeWorkspacePersistentStorage -WorkspaceId ([Guid]::NewGuid().ToString('D')) -DisplayName 'Root alias' `
                    -DataRoot $root -RelativePath '.' -Configuration $config -ExpectedRevision 1 | Out-Null
                $unsafeBlocked=$false
            }
            catch { $unsafeBlocked=$unsafeBlocked -and $_.Exception.Message -match 'EXCHANGE_WORKSPACE_RELATIVE_PATH_INVALID' }
            $duplicateBindingBlocked=$false
            try {
                Register-LabExchangeWorkspacePersistentStorage -WorkspaceId ([Guid]::NewGuid().ToString('D')) -DisplayName 'Duplicate binding' `
                    -DataRoot $root -RelativePath $relativePath -Configuration $config -ExpectedRevision 1 | Out-Null
            }
            catch { $duplicateBindingBlocked=$_.Exception.Message -match 'EXCHANGE_WORKSPACE_BINDING_CONFLICT' }
            $hashesAfter=@($catalogPaths | ForEach-Object { (Get-FileHash -LiteralPath $_ -Algorithm SHA256).Hash })
            $inventory=Get-LabStorageResidencyInventory -Configuration $config -StateRoot $stateRoot `
                -PersistentStorageStores @($catalog.Document.Stores)
            $plan=Get-LabPersistentStoragePlan -Catalog $catalog -ResidencyInventory $inventory
            [PSCustomObject]@{
                InternalPreview=$internalPreview; Planned=$planned; PreviewWasReadOnly=$previewWasReadOnly
                Applied=$applied; Again=$again; Catalog=$catalog; Store=$store
                StaleBlocked=$staleBlocked; ScopeBlocked=$scopeBlocked; UnsafeBlocked=$unsafeBlocked
                DuplicateBindingBlocked=$duplicateBindingBlocked
                HashesUnchanged=(@(Compare-Object $hashesBefore $hashesAfter).Count -eq 0)
                Inventory=$inventory; Plan=$plan
            }
        }
        finally {
            Set-Item Function:script:Get-LabStorageConfiguration -Value $originalConfiguration
            Set-Item Function:script:Resolve-LabDataRootForUse -Value $originalResolver
            Set-Item Function:script:Test-LabDataRootOwnership -Value $originalOwnership
            Remove-Variable -Scope Script -Name exchangeTestConfiguration,exchangeTestRoot -ErrorAction SilentlyContinue
        }
    } $exchangeConfiguration $exchangeRoot1 $exchangeRelativePath $exchangeStateRoot $exchangeWorkspaceId
    $exchangeObject=@($exchangeEvidence.Inventory.Objects | Where-Object ObjectClass -eq 'EXCHANGE_WORKSPACE')[0]
    Add-CheckResult -Name 'Generischer Katalogkern plant read-only und committed genau einen gespiegelten Revisionsschritt' -Success (
        $exchangeEvidence.InternalPreview.Changed -and $exchangeEvidence.InternalPreview.Preview -and
        $exchangeEvidence.InternalPreview.CatalogRevision -eq 0 -and $exchangeEvidence.InternalPreview.ProposedRevision -eq 1 -and
        $exchangeEvidence.PreviewWasReadOnly -and $exchangeEvidence.Catalog.Document.Revision -eq 1 -and
        @($exchangeEvidence.Catalog.Sources).Count -eq 2)
    Add-CheckResult -Name 'Öffentlicher Exchange-Workspace-Sync ist schemafest und idempotent' -Success (
        $exchangeEvidence.Planned.Status -eq 'PLANNED' -and $exchangeEvidence.Planned.ArtifactType -eq 'EXCHANGE_WORKSPACE' -and
        $exchangeEvidence.Applied.Status -eq 'SYNCED' -and $exchangeEvidence.Applied.Changed -and
        $exchangeEvidence.Again.Status -eq 'NO_CHANGE' -and -not $exchangeEvidence.Again.Changed -and
        [string]$exchangeEvidence.Store.References[0].TargetId -eq $exchangeWorkspaceId -and
        ($exchangeEvidence.Applied | ConvertTo-Json -Depth 20 | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/persistent-storage-artifact-sync-result.schema.json')))
    Add-CheckResult -Name 'CAS, Mutationsgrenze und portable Pfadgrenze blockieren ohne Spiegeländerung' -Success (
        $exchangeEvidence.StaleBlocked -and $exchangeEvidence.ScopeBlocked -and $exchangeEvidence.UnsafeBlocked -and
        $exchangeEvidence.DuplicateBindingBlocked -and $exchangeEvidence.HashesUnchanged)
    Add-CheckResult -Name 'Exchange-Workspace wird über dieselbe stabile Objekt-ID im Residency-Plan korreliert' -Success (
        $exchangeObject.AuditStatus -eq 'VERIFIED' -and $exchangeObject.ObjectId -eq [string]$exchangeEvidence.Store.LocationBinding.InventoryObjectId -and
        $exchangeObject.Details.WorkspaceId -eq $exchangeWorkspaceId -and $exchangeObject.Details.FileCount -eq 1 -and
        $exchangeEvidence.Plan.Status -eq 'READY' -and $exchangeEvidence.Plan.Stores[0].ObservationStatus -eq 'MATCHED' -and
        ($exchangeEvidence.Inventory | ConvertTo-Json -Depth 30 | Test-Json -SchemaFile (Join-Path $repoRoot 'Schemas/lab-storage-residency-inventory.schema.json')))

    $duplicateWorkspaceReference = $exchangeEvidence.Catalog.Document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $duplicateReferenceStore = $duplicateWorkspaceReference.Stores[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $duplicateReferenceStore.PersistentStorageId = [Guid]::NewGuid().ToString('D')
    $duplicateReferenceStore.LocationBinding.InventoryObjectId = 'storage-object-aaaaaaaaaaaaaaaaaaaaaaaa'
    $duplicateReferenceStore.LocationBinding.RelativePath = 'Exchange/second'
    $duplicateWorkspaceReference.Stores = @($duplicateWorkspaceReference.Stores) + @($duplicateReferenceStore)
    $duplicateWorkspaceBinding = $exchangeEvidence.Catalog.Document | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $duplicateBindingStore = $duplicateWorkspaceBinding.Stores[0] | ConvertTo-Json -Depth 30 | ConvertFrom-Json -Depth 30
    $duplicateBindingStore.PersistentStorageId = [Guid]::NewGuid().ToString('D')
    $duplicateBindingStore.LocationBinding.InventoryObjectId = 'storage-object-bbbbbbbbbbbbbbbbbbbbbbbb'
    $duplicateBindingStore.References[0].ReferenceId = [Guid]::NewGuid().ToString('D')
    $duplicateBindingStore.References[0].TargetId = [Guid]::NewGuid().ToString('D')
    $duplicateWorkspaceBinding.Stores = @($duplicateWorkspaceBinding.Stores) + @($duplicateBindingStore)
    Add-CheckResult -Name 'Katalogvalidierung blockiert doppelte Workspace-IDs und portable Bindungen unabhängig vom Writer' -Success ((
        Test-ExpectedFailure -Pattern 'EXCHANGE_WORKSPACE_REFERENCE_INVALID' -Action {
            & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $duplicateWorkspaceReference $exchangeConfiguration
        }) -and (
        Test-ExpectedFailure -Pattern 'EXCHANGE_WORKSPACE_BINDING_DUPLICATE' -Action {
            & $module { param($doc,$config) Test-LabPersistentStorageCatalogDocument -Document $doc -Configuration $config } $duplicateWorkspaceBinding $exchangeConfiguration
        }))

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
