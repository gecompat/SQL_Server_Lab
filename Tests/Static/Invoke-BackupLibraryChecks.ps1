#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-backup-library-$([Guid]::NewGuid().ToString('N'))"
$dataRoot=Join-Path $testRoot 'Lab_Data'
$previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
$results=[Collections.Generic.List[object]]::new()

function Add-CheckResult { param([string]$Name,[bool]$Success,[string]$Detail='') $results.Add([PSCustomObject]@{Name=$Name;Success=$Success;Detail=$Detail}); $color=if($Success){'Green'}else{'Red'}; Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name $Detail" -ForegroundColor $color }

try {
    New-Item -ItemType Directory -Path $testRoot -Force | Out-Null
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $password=[Security.SecureString]::new()
    foreach($character in 'BackupLibrary_Test!Aa7'.ToCharArray()){$password.AppendChar($character)}
    $password.MakeReadOnly()
    $fixture=Join-Path $testRoot 'fixture.bak'
    [IO.File]::WriteAllBytes($fixture,[Text.Encoding]::UTF8.GetBytes('synthetic-backup-payload'))

    $result=& $module {
        param($Root,$Fixture,$Password)
        $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false
        $env:SQL_SERVER_LAB_DATA_ROOT=$Root
        $script:backupSql=[Collections.Generic.List[string]]::new()
        Set-Item Function:script:Get-LabDatabaseBackupMetadata -Value {
            [PSCustomObject]@{SqlMajorVersion='17';FileCount=2;FileStreamFileCount=0;FileTableCount=0;HasFileStream=$false;IsEncrypted=$false}
        }
        Set-Item Function:script:Get-LabDatabaseMigrationDependencySqlObservation -Value {
            [PSCustomObject]@{SqlMajorVersion='17';Containment='NONE';IsEncrypted=$false;EncryptionState=0;EncryptorType='NONE';ServerLoginMappingCount=1;SqlAgentJobCount=0;CredentialOrProxyCount=0;LinkedServerCount=0}
        }
        Set-Item Function:script:Initialize-LabSampleBaselineBackupTarget -Value {
            [PSCustomObject]@{Provider='docker';ContainerName='sanitized-at-runtime';BackupRoot='/var/opt/mssql/backup'}
        }
        Set-Item Function:script:Invoke-SqlQuery -Value { param($Query) $script:backupSql.Add([string]$Query); @('ok') }
        Set-Item Function:script:Export-LabSampleBaselineBackup -Value {
            param($DestinationPath) Copy-Item -LiteralPath $Fixture -Destination $DestinationPath
            [PSCustomObject]@{Provider='docker';ContainerName='not-persisted';RunId=$null;InstanceId=$null}
        }.GetNewClosure()

        $created=New-LabDatabaseLibraryBackup -Port 14333 -SaPassword $Password -Provider docker `
            -ContainerName 'runtime-only' -DatabaseName 'BackupEvidence' -DataRoot $Root
        $storageConfiguration=Get-LabStorageConfiguration -DataRoot $Root
        $legacyCatalog=Get-LabPersistentStorageCatalog -Configuration $storageConfiguration
        $initialPersistentCatalog=$legacyCatalog
        $legacyDocument=$legacyCatalog.Document|ConvertTo-Json -Depth 40|ConvertFrom-Json -Depth 40
        $legacyDocument.Stores=@($legacyDocument.Stores|Where-Object{
            @($_.References|Where-Object{[string]$_.TargetId -eq [string]$created.BackupSetId}).Count -eq 0
        })
        $legacyDocument.Revision=[int]$legacyDocument.Revision+1
        $null=Write-LabPersistentStorageCatalogDocument -Document $legacyDocument -Configuration $storageConfiguration
        $catalogPath=(Get-LabPersistentStorageCatalog -Configuration $storageConfiguration).Sources[0].Path
        $previewHashBefore=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
        $publicSyncPreview=Sync-SqlServerLabPersistentStorageArtifact -BackupSetId $created.BackupSetId -DataRoot $Root -WhatIf
        $previewHashAfter=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
        $publicSync=Sync-SqlServerLabPersistentStorageArtifact -BackupSetId $created.BackupSetId -DataRoot $Root -Confirm:$false
        $publicSyncAgain=Sync-SqlServerLabPersistentStorageArtifact -BackupSetId $created.BackupSetId -DataRoot $Root -Confirm:$false
        $persistentCatalog=Get-LabPersistentStorageCatalog -Configuration $storageConfiguration
        $residencyInventory=Get-LabStorageResidencyInventory -Configuration $storageConfiguration -StateRoot (Join-Path $Root 'State')
        $syncResult=@(Sync-LabBackupSetPersistentStorageCatalog -DataRoot $Root)
        $selected=Get-LabDatabaseBackup -BackupSetId $created.BackupSetId -DataRoot $Root
        $catalog=@(Get-LabDatabaseBackupSelection -DataRoot $Root)
        $contentHash=([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes('3|beta')))).ToLowerInvariant()
        $verification=Add-LabDatabaseBackupRestoreVerification -BackupSetId $created.BackupSetId `
            -TargetProvider podman -TargetSqlMajorVersion 17 -ContentSha256 $contentHash `
            -FileStreamContentVerified $false -DataRoot $Root
        $document=Get-Content -LiteralPath $created.RegistryPath -Raw | ConvertFrom-Json -Depth 40
        $filestreamGuard=$false
        $document.Backups[0].DatabaseMetadata.HasFileStream=$true
        $document.Backups[0].DatabaseMetadata.FileStreamFileCount=1
        Write-LabArtifactJsonAtomic -Path $created.RegistryPath -InputObject $document
        try {
            $null=Add-LabDatabaseBackupRestoreVerification -BackupSetId $created.BackupSetId `
                -TargetProvider podman -TargetSqlMajorVersion 17 -ContentSha256 $contentHash `
                -FileStreamContentVerified $false -DataRoot $Root
        } catch { $filestreamGuard=$_.Exception.Message -match 'FILESTREAM_CONTENT_EVIDENCE_REQUIRED' }
        $document.Backups[0].Status='QUARANTINED'
        Write-LabArtifactJsonAtomic -Path $created.RegistryPath -InputObject $document
        $quarantineGuard=$false
        try { $null=Get-LabDatabaseBackup -BackupSetId $created.BackupSetId -DataRoot $Root }
        catch { $quarantineGuard=$_.Exception.Message -match 'BACKUP_LIBRARY_SET_NOT_REUSABLE' }
        Set-Item Function:script:Get-LabDatabaseBackupMetadata -Value {
            [PSCustomObject]@{SqlMajorVersion='17';FileCount=2;FileStreamFileCount=0;FileTableCount=0;HasFileStream=$false;IsEncrypted=$true}
        }
        $tdeGuard=$false
        try {
            $null=New-LabDatabaseLibraryBackup -Port 14333 -SaPassword $Password -Provider docker `
                -ContainerName 'runtime-only' -DatabaseName 'EncryptedEvidence' -DataRoot $Root
        } catch { $tdeGuard=$_.Exception.Message -match 'TDE_DEPENDENCY_UNSUPPORTED' }
        $originalRegistration=(Get-Command Register-LabBackupSetPersistentStorage -CommandType Function).ScriptBlock
        Set-Item Function:script:Register-LabBackupSetPersistentStorage -Value { throw 'SYNTHETIC_CATALOG_FAILURE' }
        $catalogFailure=$false
        try {
            $null=Register-LabDatabaseBackupArtifact -BackupPath $Fixture -DatabaseName 'CatalogFailure' -Provider docker `
                -Metadata ([PSCustomObject]@{SqlMajorVersion='17';FileCount=1;FileStreamFileCount=0;FileTableCount=0;HasFileStream=$false;IsEncrypted=$false}) -DataRoot $Root
        } catch { $catalogFailure=$_.Exception.Message -match 'BACKUP_LIBRARY_CATALOG_REGISTRATION_FAILED.*SYNTHETIC_CATALOG_FAILURE' }
        finally { Set-Item Function:script:Register-LabBackupSetPersistentStorage -Value $originalRegistration }
        $afterCatalogFailure=Get-LabBackupLibraryDocument -Paths (Get-LabBackupLibraryPaths -DataRoot $Root)
        $catalogFailureQuarantined=@($afterCatalogFailure.Backups | Where-Object { $_.DatabaseName -eq 'CatalogFailure' -and $_.Status -eq 'QUARANTINED' }).Count -eq 1
        [PSCustomObject]@{
            Created=$created.Status -eq 'BACKUP_REUSABLE' -and (Test-Path -LiteralPath $created.Path -PathType Leaf)
            PersistentStorageId=[string]$created.PersistentStorageId
            PublicSyncPreview=$publicSyncPreview;PublicSync=$publicSync;PublicSyncAgain=$publicSyncAgain
            PreviewDidNotMutate=$previewHashBefore -eq $previewHashAfter
            InitialPersistentCatalog=$initialPersistentCatalog;PersistentCatalog=$persistentCatalog
            ResidencyInventory=$residencyInventory
            SyncResult=$syncResult
            Selected=$selected.Record.BackupSetId -eq $created.BackupSetId -and $selected.Record.Artifact.Sha256 -eq $created.Sha256
            Catalog=$catalog
            Sql=($script:backupSql -join "`n")
            Registry=$document
            Verification=$verification
            FileStreamGuard=$filestreamGuard
            QuarantineGuard=$quarantineGuard
            TdeGuard=$tdeGuard
            CatalogFailure=$catalogFailure
            CatalogFailureQuarantined=$catalogFailureQuarantined
        }
    } $dataRoot $fixture $password

    Add-CheckResult 'Backup wird erst nach CHECKSUM und RESTORE VERIFYONLY veröffentlicht' ($result.Sql -match 'BACKUP DATABASE.+CHECKSUM' -and $result.Sql -match 'RESTORE VERIFYONLY.+WITH CHECKSUM')
    Add-CheckResult 'Inhaltsadressiertes Backup ist als REUSABLE selektierbar' ($result.Created -and $result.Selected)
    Add-CheckResult 'Öffentlicher Bestands-Sync plant ohne Mutation und registriert genau ein BackupSetId idempotent' (
        $result.PublicSyncPreview.ContractVersion -eq 'SqlServerLab.PersistentStorageArtifactSyncResult/1.0' -and
        $result.PublicSyncPreview.Status -eq 'PLANNED' -and $result.PublicSyncPreview.WouldChange -and
        -not $result.PublicSyncPreview.PersistentStorageId -and $result.PreviewDidNotMutate -and
        $result.PublicSync.Status -eq 'SYNCED' -and $result.PublicSync.Changed -and
        $result.PublicSyncAgain.Status -eq 'NO_CHANGE' -and -not $result.PublicSyncAgain.Changed -and
        [string]$result.PublicSync.PersistentStorageId -eq [string]$result.PublicSyncAgain.PersistentStorageId -and
        ($result.PublicSync|ConvertTo-Json -Depth 10) -notmatch [regex]::Escape($testRoot))
    $initialPersistentStores=@($result.InitialPersistentCatalog.Document.Stores | Where-Object StorageClass -eq 'BACKUP_SET')
    $persistentStores=@($result.PersistentCatalog.Document.Stores | Where-Object StorageClass -eq 'BACKUP_SET')
    Add-CheckResult 'Backup-Publikation registriert eine getrennte stabile PersistentStorageId atomar im zentralen Katalog' (
        $result.PersistentStorageId -match '^[0-9a-f-]{36}$' -and $initialPersistentStores.Count -eq 1 -and
        [string]$initialPersistentStores[0].PersistentStorageId -eq $result.PersistentStorageId -and
        [string]$initialPersistentStores[0].References[0].TargetId -eq [string]$result.Catalog[0].BackupSetId -and
        @($result.SyncResult).Count -eq 1 -and -not [bool]$result.SyncResult[0].Changed -and
        [string]$persistentStores[0].PersistentStorageId -eq [string]$result.PublicSync.PersistentStorageId)
    $backupResidency=@($result.ResidencyInventory.Objects | Where-Object ObjectClass -eq 'BACKUP_SET')
    Add-CheckResult 'Residency-Inventar bindet den Backupbestand ohne erneutes Inhalts-Hashing an dieselbe Objekt-ID' (
        $backupResidency.Count -eq 1 -and $backupResidency[0].AuditStatus -eq 'VERIFIED' -and
        [string]$backupResidency[0].ObjectId -eq [string]$persistentStores[0].LocationBinding.InventoryObjectId -and
        (Get-Content -LiteralPath (Join-Path $repoRoot 'Private/StorageResidencyInventory.ps1') -Raw) -notmatch '(?s)foreach \(\$backup.+Get-FileHash')
    $catalogJson=$result.Catalog | ConvertTo-Json -Depth 10
    Add-CheckResult 'Backup-Auswahl ist billig, stabil und ohne lokale Pfade oder Hashes sanitisiert' ($result.Catalog.Count -eq 1 -and $result.Catalog[0].BackupSetId -match '^[0-9a-f-]{36}$' -and $result.Catalog[0].Availability -eq 'SELECTABLE' -and $catalogJson -notmatch 'RelativePath|Sha256|RegistryPath|\\Objects\\|/Objects/')
    Add-CheckResult 'Quarantänestatus sperrt die exakte BackupSetId-Auswahl fail-closed' $result.QuarantineGuard
    Add-CheckResult 'Receipt enthält sanitisierte Metadaten ohne Runtime-Endpunkte oder Credentials' (($result.Registry | ConvertTo-Json -Depth 40) -notmatch '14333|runtime-only|sanitized-at-runtime|not-persisted|BackupLibrary_Test')
    Add-CheckResult 'Backup-Receipt weist Datenbankdateien und getrennte Serverobjekte statt Vollmigration aus' ($result.Registry.Backups[0].DatabaseMetadata.MigrationBoundary.ArtifactScope -eq 'DATABASE_FILES_ONLY' -and -not $result.Registry.Backups[0].DatabaseMetadata.MigrationBoundary.FullInstanceMigration -and 'SERVER_LOGIN_MAPPING' -in $result.Registry.Backups[0].DatabaseMetadata.MigrationBoundary.DependencyCategories)
    $migrationPlanBinding=$result.Registry.Backups[0].DatabaseMetadata.MigrationExecutionPlanBinding
    Add-CheckResult 'Backup-Receipt bindet den nicht ausführbaren Migrationsplan an die exakte Backup-SHA und projiziert nur Reviewstatus' (
        $migrationPlanBinding.BindingVersion -eq 'SqlServerLab.BackupMigrationExecutionPlanBinding/1.0' -and
        $migrationPlanBinding.ArtifactSha256 -eq $result.Registry.Backups[0].Artifact.Sha256 -and
        $migrationPlanBinding.PlanContractVersion -eq 'SqlServerLab.DatabaseMigrationExecutionPlan/1.0' -and
        -not $migrationPlanBinding.MutationAllowed -and $migrationPlanBinding.TransferAuthority -eq 'NONE' -and
        @($migrationPlanBinding.Steps).Count -eq 8 -and
        $result.Catalog[0].MigrationExecutionStatus -eq 'MANUAL_REVIEW_REQUIRED' -and
        $result.Catalog[0].MigrationPlanStepCount -eq 8)
    Add-CheckResult 'Cross-Provider-Inhaltsdigest wird getrennt als Restore-Evidence erfasst' ($result.Verification.TargetProvider -eq 'podman' -and $result.Verification.ContentSha256 -match '^[a-f0-9]{64}$')
    Add-CheckResult 'FILESTREAM-Backup verlangt echte FILESTREAM-Inhaltsevidence' $result.FileStreamGuard
    Add-CheckResult 'TDE-Backup wird ohne Zertifikat- und Recovery-Vertrag nicht veröffentlicht' $result.TdeGuard
    Add-CheckResult 'Fehlgeschlagener Katalogcommit quarantänisiert die Bibliothek statt Wiederverwendbarkeit zu behaupten' ($result.CatalogFailure -and $result.CatalogFailureQuarantined)
    Add-CheckResult 'Öffentliches Backup-Cmdlet ist exportiert' ([bool](Get-Command Backup-SqlServerLabDatabase -ErrorAction SilentlyContinue))
    Add-CheckResult 'Öffentlicher Artefakt-Bestandssync ist exportiert' ([bool](Get-Command Sync-SqlServerLabPersistentStorageArtifact -ErrorAction SilentlyContinue))
    $restoreText=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Restore-SqlServerLabDatabase.ps1') -Raw
    Add-CheckResult 'Jeder öffentliche Restore führt VERIFYONLY WITH CHECKSUM vor FILELISTONLY aus' ($restoreText -match '(?s)Pruefe Backup.+RESTORE VERIFYONLY.+WITH CHECKSUM.+Lese Backup-Metadaten.+RESTORE FILELISTONLY')
    Add-CheckResult 'Öffentlicher Restore wählt Bibliotheksbackups ausschließlich über BackupSetId im gemeinsamen Core' ($restoreText -match '\[string\]\$BackupSetId' -and $restoreText -match '\[string\]\$DataRoot' -and $restoreText -match 'RESTORE_BACKUP_SOURCE_EXACTLY_ONE_REQUIRED' -and $restoreText -match 'Get-LabDatabaseBackup -BackupSetId \$BackupSetId -DataRoot \$DataRoot')
}
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed=@($results | Where-Object { -not $_.Success })
if($failed.Count -gt 0){ throw "BACKUP LIBRARY CHECKS FAILED: $($failed.Name -join '; ')" }
Write-Host "BACKUP LIBRARY CHECKS: PASS ($($results.Count))" -ForegroundColor Green
