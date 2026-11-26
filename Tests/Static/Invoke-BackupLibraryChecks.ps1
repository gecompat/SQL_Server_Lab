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
        $script:backupProofPassword = $Password
        Set-Item Function:script:Invoke-SqlQuery -Value {
            param($Query,$ProductQueryPassword,$SaPlain)
            if (-not [object]::ReferenceEquals($ProductQueryPassword,$script:backupProofPassword) -or $SaPlain) {
                throw 'SYNTHETIC_BACKUP_REQUIRES_SECURE_QUERY'
            }
            $script:backupSql.Add([string]$Query); @('ok')
        }
        Set-Item Function:script:Export-LabSampleBaselineBackup -Value {
            param($DestinationPath) Copy-Item -LiteralPath $Fixture -Destination $DestinationPath
            [PSCustomObject]@{Provider='docker';ContainerName='not-persisted';RunId=$null;InstanceId=$null}
        }.GetNewClosure()

        $originalPublicBackupCore=(Get-Command New-LabDatabaseLibraryBackup -CommandType Function).ScriptBlock
        $script:publicBackupWhatIfCalls=0
        try {
            Set-Item Function:script:New-LabDatabaseLibraryBackup -Value { $script:publicBackupWhatIfCalls++ }
            $publicBackupPreview=Backup-SqlServerLabDatabase -Port 14333 -SaPassword $Password -Provider docker `
                -ContainerName 'runtime-only' -DatabaseName 'BackupEvidence' -DataRoot $Root -WhatIf
        }
        finally { Set-Item Function:script:New-LabDatabaseLibraryBackup -Value $originalPublicBackupCore }

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
            PublicBackupPreview=$publicBackupPreview
            PublicBackupWhatIfCalls=$script:publicBackupWhatIfCalls
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
    Add-CheckResult 'Oeffentliches Backup-WhatIf bleibt vor Runtime- und Bibliotheksmutation' (
        $result.PublicBackupPreview.Status -eq 'CANCELLED' -and
        -not $result.PublicBackupPreview.MutationPerformed -and $result.PublicBackupWhatIfCalls -eq 0)
    $removalText=Get-Content -LiteralPath (Join-Path $repoRoot 'Public/Invoke-SqlServerLabPersistentStorageRemoval.ps1') -Raw
    Add-CheckResult 'Bereits bestaetigte Retention unterdrueckt einen verschachtelten zweiten Backup-Prompt' (
        $removalText -match 'Backup-SqlServerLabDatabase[\s\S]{0,300}?-Confirm:\$false')
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
    Add-CheckResult 'Externe Backups ohne SQL-Backup-CHECKSUM fallen nur bei SQL-Fehler 3187 auf VERIFYONLY zurück' (
        $restoreText -match 'function Test-LabBackupChecksumUnavailableError[\s\S]+?3187' -and
        $restoreText -match '\$backupSourceKind -eq ''LIBRARY'' -or -not \(Test-LabBackupChecksumUnavailableError -ErrorRecord \$_\)' -and
        $restoreText -match 'RESTORE VERIFYONLY FROM DISK = N''\$escapedContainerBackupPath'';')
    Add-CheckResult 'Öffentlicher Restore wählt Bibliotheksbackups ausschließlich über BackupSetId im gemeinsamen Core' ($restoreText -match '\[string\]\$BackupSetId' -and $restoreText -match '\[string\]\$DataRoot' -and $restoreText -match 'RESTORE_BACKUP_SOURCE_EXACTLY_ONE_REQUIRED' -and $restoreText -match 'Get-LabDatabaseBackup -BackupSetId \$BackupSetId -DataRoot \$DataRoot')
    $restorePreview=Restore-SqlServerLabDatabase -Port 14333 -SaPassword $password -Provider docker `
        -ContainerName 'runtime-only' -BackupSource 'synthetic-not-resolved.bak' -DatabaseName 'RestoreEvidence' -WhatIf
    Add-CheckResult 'Öffentliches Restore-WhatIf bleibt vor Artifact-, Transfer-, Journal- und SQL-Mutation' (
        $restorePreview.Status -eq 'CANCELLED' -and -not $restorePreview.MutationPerformed -and
        $restoreText.IndexOf('$PSCmdlet.ShouldProcess') -lt $restoreText.IndexOf('Resolve-LabArtifact') -and
        $restoreText.IndexOf('$PSCmdlet.ShouldProcess') -lt $restoreText.IndexOf('Start-LabStorageSqlOperation'))
    Add-CheckResult 'Restore-Ergebnis benennt Recovery nach SQL-Teilfehler und Core bereinigt Containerkopien' (
        $restoreText -match "Recovery\s+= 'VERIFY_OR_REMOVE_PARTIAL_TARGET'" -and
        $restoreText -match 'rm -f -- \$runtimeBackupPath')

    Add-CheckResult 'Restore-Statements verwenden prozessgebundenes SA-Passwort und sperren vorhandene Ziele ohne Replace' (
        $restoreText -cnotmatch 'PtrToStringBSTR|\$saPlain|''-P''' -and
        @([regex]::Matches($restoreText,'-SqlPassword \$SaPassword')).Count -eq 2 -and
        @([regex]::Matches($restoreText,'-ProductQueryPassword \$SaPassword')).Count -eq 3 -and
        $restoreText -match '(?s)\$targetGuard = if \(-not \$Replace\).+DB_ID.+RESTORE_TARGET_DATABASE_EXISTS.+RESTORE DATABASE')

    $browserRestore=& $module {
        param($Password)
        $run='43434343-2222-4333-8444-555555555555'
        $backup='51515151-2222-4333-8444-555555555555'
        $vm=[guid]'61616161-2222-4333-8444-555555555555'
        $fixture=[pscustomobject]@{Address='192.0.2.23';ObservedAddress='192.0.2.23';RestoreCalls=0;Checks=0;Exists=$false;Drift=$false;Reads=0;Bound=$false;Storage='VERIFIED';BackupVersion=17;Cleanup='CONFIRMED'}
        function Get-LabHyperVStorageReconcileContext {
            param($RunId,$InstanceId)
            [pscustomobject]@{StateRoot='synthetic-root';Run=[pscustomobject]@{state='RUNNING'};VM=[pscustomobject]@{Id=$vm;State='Running'}}
        }
        function Resolve-LabRunInstance {
            param($RunId,$InstanceId,$StateRoot)
            $fixture.Reads++
            [pscustomobject]@{Provider='hyperv';VMId=$vm.ToString('D');HostName=$fixture.Address;Version='2025'
                Port=if($fixture.Drift -and $fixture.Reads -eq 2){1435}else{1433}}
        }
        function Assert-LabWindowsPoolMutationAllowed {}
        function Get-LabConnectionCenterCmsConfiguration {}
        function Get-LabDataRootDefault { 'synthetic-data-root' }
        function Resolve-LabDataRootForUse { param($DataRoot) $DataRoot }
        function Get-LabDatabaseBackupSelection { [pscustomobject]@{BackupSetId=$backup;Availability='SELECTABLE';SourceSqlMajorVersion=$fixture.BackupVersion;IsEncrypted=$false} }
        function Get-LabVerifiedStorageRuntimeContext {
            [pscustomobject]@{Receipt=[pscustomobject]@{Status=$fixture.Storage}}
        }
        function Get-VMNetworkAdapter { param($VM,$ErrorAction) [pscustomobject]@{IPAddresses=@($fixture.ObservedAddress)} }
        function Get-HyperVLabWorkflowRun {
            param($RunId,$StateRoot,$ExpectedVmId,[switch]$NoWrite)
            if ($ExpectedVmId -ne $vm -or -not $NoWrite) { throw 'WRONG_PROBE_BINDING' }
            [pscustomobject]@{Instance=[pscustomobject]@{id='primary'}}
        }
        function Get-HyperVLabSqlInstanceReceipt {
            param($Lab,$Credential,$ExpectedVmId)
            if ($ExpectedVmId -ne $vm -or $Credential.UserName -cne 'Administrator') { throw 'WRONG_GUEST_AUTHORITY' }
            [pscustomobject]@{instances=@([pscustomobject]@{serviceStatus='Running';tcpPort=1433})}
        }
        function Invoke-LabSqlcmdProgress {
            param($SqlPassword,$ProcessTimeoutSeconds,$ArgumentList)
            $fixture.Checks++
            if (-not [object]::ReferenceEquals($SqlPassword,$Password) -or $ArgumentList -ccontains '-P') { throw 'WRONG_SQL_SECRET' }
            [pscustomobject]@{ExitCode=0;Output=@($(if($fixture.Exists){'1'}else{'0'}))}
        }
        function Restore-SqlServerLabDatabase {
            param($RunId,$InstanceId,$BackupSetId,$DatabaseName,$SaPassword,$GuestCredential,$StateRoot,$DataRoot,[switch]$NonInteractive,[switch]$Confirm,[switch]$Replace)
            $fixture.RestoreCalls++
            $fixture.Bound=$RunId -ceq $run -and $InstanceId -ceq 'primary' -and $BackupSetId -ceq $backup -and
                $DatabaseName -ceq 'NewRestoreDb' -and $DataRoot -ceq 'synthetic-data-root' -and $NonInteractive -and -not $Confirm -and -not $Replace -and
                $GuestCredential.UserName -ceq 'Administrator' -and [object]::ReferenceEquals($SaPassword,$Password)
            [pscustomobject]@{Success=$true;Provider='hyperv';BackupSetId=$BackupSetId;DatabaseName=$DatabaseName;PrivatePath='fixture-private';CleanupStatus=$fixture.Cleanup}
        }
        $argsRestore=@{RunId=$run;InstanceId='primary';BackupSetId=$backup;DatabaseName='NewRestoreDb'
            GuestUserName='Administrator';GuestPassword=$Password;SaPassword=$Password}
        $success=Invoke-LabGuidedHyperVLibraryRestore @argsRestore
        $fixture.Exists=$true
        $exists=try { $null=Invoke-LabGuidedHyperVLibraryRestore @argsRestore; '' } catch { $_.Exception.Message }
        $fixture.Exists=$false
        $fixture.ObservedAddress='192.0.2.99'
        $before=$fixture.Checks
        $foreignIp=try { $null=Invoke-LabGuidedHyperVLibraryRestore @argsRestore; '' } catch { $_.Exception.Message }
        $ipBlockedBeforeSql=$before -eq $fixture.Checks
        $fixture.ObservedAddress=$fixture.Address
        $fixture.BackupVersion=18
        $before=$fixture.Checks
        $newerBackup=try { $null=Invoke-LabGuidedHyperVLibraryRestore @argsRestore; '' } catch { $_.Exception.Message }
        $versionBlockedBeforeSql=$before -eq $fixture.Checks
        $fixture.BackupVersion=17
        $fixture.Reads=0
        $fixture.Drift=$true
        $drift=try { $null=Invoke-LabGuidedHyperVLibraryRestore @argsRestore; '' } catch { $_.Exception.Message }
        $guardedCalls=$fixture.RestoreCalls
        $fixture.Drift=$false
        $fixture.Cleanup='RECOVERY_REQUIRED'
        $cleanup=try { $null=Invoke-LabGuidedHyperVLibraryRestore @argsRestore; '' } catch { $_.Exception.Message }
        [pscustomobject]@{Success=$success;Exists=$exists;ForeignIp=$foreignIp;IpBlockedBeforeSql=$ipBlockedBeforeSql
            Drift=$drift;NewerBackup=$newerBackup;VersionBlockedBeforeSql=$versionBlockedBeforeSql;Calls=$guardedCalls;Bound=$fixture.Bound;Cleanup=$cleanup}
    } $password
    Add-CheckResult 'Hyper-V Browser-Restore bindet die verifizierte Library an genau ein Ziel ohne Replace und projiziert nur die Quittung' (
        $browserRestore.Calls -eq 1 -and $browserRestore.Bound -and $browserRestore.Success.Status -ceq 'RESTORED' -and
        -not $browserRestore.Success.PSObject.Properties['PrivatePath'])
    Add-CheckResult 'Vorhandenes Ziel, fremde Gast-IP und spätere Endpunktdrift sperren Hyper-V Browser-Restore' (
        $browserRestore.Exists -ceq 'HYPERV_LIBRARY_RESTORE_TARGET_EXISTS' -and
        $browserRestore.ForeignIp -ceq 'HYPERV_LIBRARY_RESTORE_TARGET_NOT_READY' -and $browserRestore.IpBlockedBeforeSql -and
        $browserRestore.Drift -ceq 'HYPERV_LIBRARY_RESTORE_TARGET_NOT_READY' -and
        $browserRestore.NewerBackup -ceq 'HYPERV_LIBRARY_RESTORE_BACKUP_NOT_SELECTABLE' -and $browserRestore.VersionBlockedBeforeSql)

    Add-CheckResult 'Restore ergibt ohne bestätigte Kopienbereinigung keinen grünen Abschluss im Browser' (
        $browserRestore.Cleanup -ceq 'HYPERV_LIBRARY_RESTORE_CLEANUP_REQUIRED' -and $browserRestore.Success.CleanupStatus -ceq 'CONFIRMED')

    $backupPreflight = & $module {
        param($Password,$Root)
        $reads = [Runtime.CompilerServices.StrongBox[int]]::new(0)
        function Get-LabDatabaseBackupMetadata {
            $reads.Value++
            throw 'SYNTHETIC_UNEXPECTED_SQL_READ'
        }
        function Initialize-LabSampleBaselineBackupTarget { throw 'SAMPLE_BASELINE_HYPERV_VERIFIED_RECEIPT_REQUIRED' }
        $arguments = @{Port=14333;SaPassword=$Password;Provider='hyperv'
            RunId='43434343-2222-4333-8444-555555555555';InstanceId='primary';DatabaseName='BackupEvidence'
            GuestCredential=[pscredential]::new('Administrator',$Password);DataRoot=$Root}
        $code = try { $null=New-LabDatabaseLibraryBackup @arguments; 'UNEXPECTED_SUCCESS' } catch { $_.Exception.Message }
        [pscustomobject]@{SqlReads=$reads.Value;Code=$code}
    } $password $testRoot
    Add-CheckResult 'Hyper-V-Backup prüft den bestätigten Speicher vor dem ersten SQL-Zugriff' (
        $backupPreflight.Code -ceq 'SAMPLE_BASELINE_HYPERV_VERIFIED_RECEIPT_REQUIRED' -and $backupPreflight.SqlReads -eq 0)

    $backupIntent = & $module {
        param($Password,$Root)
        $runId = '43434343-2222-4333-8444-555555555555'
        $scopeId = '51515151-2222-4333-8444-555555555555'
        $vmId = '61616161-2222-4333-8444-555555555555'
        $storagePlanId = '71717171-2222-4333-8444-555555555555'
        $state = Join-Path $Root 'hyperv-intent'
        $runDirectory = Join-Path $state ('runs/'+$runId)
        $null = New-Item -ItemType Directory -Path $runDirectory
        $calls = [pscustomobject]@{Exports=0;Before=$null;RecordPath=$null;ForeignVM=$false}
        function Initialize-LabSampleBaselineBackupTarget {
            [pscustomobject]@{Provider='hyperv';BackupRoot='C:\Synthetic\Backup';RunId=$runId
                InstanceId='primary';StateRoot=$state;StoragePlanId=$storagePlanId}
        }
        function Get-HyperVLabWorkflowRun {
            [pscustomobject]@{Run=[pscustomobject]@{runId=$runId;scopeId=$scopeId;state='RUNNING'}
                Instance=[pscustomobject]@{id='primary';vmName='synthetic-guest';vmId=$vmId};RunDirectory=$runDirectory}
        }
        function Get-HyperVManagedVM {
            $observedId = if ($calls.ForeignVM) { '81818181-2222-4333-8444-555555555555' } else { $vmId }
            [pscustomobject]@{VM=[pscustomobject]@{Id=$observedId;State='Running'}}
        }
        function Get-LabDatabaseBackupMetadata { [pscustomobject]@{IsEncrypted=$false} }
        function Get-LabDatabaseMigrationDependencyInventory { [pscustomobject]@{Status='SYNTHETIC'} }
        function Invoke-SqlQuery {
            param($Query)
            if ($Query -cnotmatch 'backup-(?<Key>[0-9a-f]{32})\.bak') { throw 'SYNTHETIC_BACKUP_PATH_UNBOUND' }
            $calls.RecordPath=Join-Path $runDirectory ('backup-library-'+$Matches.Key+'.local.journal.json')
            $calls.Before=Get-Content -LiteralPath $calls.RecordPath -Raw | ConvertFrom-Json
            if ($mode -ceq 'failure') { throw 'SYNTHETIC_BACKUP_SQL_INTERRUPTED' }
        }
        function Export-LabSampleBaselineBackup {
            $calls.Exports++
            if ($mode -ceq 'record-drift') { [IO.File]::WriteAllText($calls.RecordPath,'FOREIGN_RECORD_CANARY') }
            [pscustomobject]@{Provider='hyperv'}
        }
        function Register-LabDatabaseBackupArtifact {
            [pscustomobject]@{Record=[pscustomobject]@{BackupSetId=$storagePlanId;Artifact=[pscustomobject]@{Sha256=('a'*64);Bytes=64}
                DatabaseMetadata=[pscustomobject]@{HasFileStream=$false;MigrationBoundary='SYNTHETIC'}}}
        }
        $arguments = @{Port=14333;SaPassword=$Password;Provider='hyperv'
            RunId=$runId;InstanceId='primary';DatabaseName='BackupEvidence'
            GuestCredential=[pscredential]::new('Administrator',$Password);DataRoot=$Root}
        $mode='failure'
        $failure=try { $null=New-LabDatabaseLibraryBackup @arguments; throw 'UNEXPECTED_SUCCESS' } catch { $_.Exception }
        $pending=Get-Content -LiteralPath $calls.RecordPath -Raw | ConvertFrom-Json
        $exportsAfterFailure=$calls.Exports
        $calls.ForeignVM=$true
        $drift=try { $null=New-LabDatabaseLibraryBackup @arguments; 'UNEXPECTED_SUCCESS' } catch { $_.Exception.Message }
        $calls.ForeignVM=$false
        $mode='success'
        $completed=New-LabDatabaseLibraryBackup @arguments
        $receipt=Get-Content -LiteralPath $calls.RecordPath -Raw | ConvertFrom-Json
        $before=$calls.Before
        $exportsBeforeDrift=$calls.Exports
        $mode='record-drift'
        $recordDrift=try { $null=New-LabDatabaseLibraryBackup @arguments; 'UNEXPECTED_SUCCESS' } catch { $_.Exception.Message }
        [pscustomobject]@{Failure=$failure.Message;ExportsAfterFailure=$exportsAfterFailure
            Recovery=$failure.Data['SqlServerLab.BackupRuntimeCleanupStatus'];File=$failure.Data['SqlServerLab.BackupRuntimeFileName']
            Pending=$pending;Drift=$drift;Before=$before;Receipt=$receipt;Success=$completed.Status;Exports=$exportsBeforeDrift
            RecordDrift=$recordDrift;DriftBytes=[IO.File]::ReadAllText($calls.RecordPath)}
    } $password $testRoot
    Add-CheckResult 'Hyper-V Backup-Intent bleibt bei SQL-Unterbruch offen und getrennt vom Primärfehler' (
        $backupIntent.Failure -ceq 'SYNTHETIC_BACKUP_SQL_INTERRUPTED' -and $backupIntent.ExportsAfterFailure -eq 0 -and
        $backupIntent.Recovery -ceq 'RECOVERY_REQUIRED' -and $backupIntent.File -cmatch '^backup-[0-9a-f]{32}\.bak$' -and
        $backupIntent.Pending.Status -ceq 'GUEST_FILE_UNCONFIRMED' -and $backupIntent.Pending.FileName -ceq $backupIntent.File)
    Add-CheckResult 'Hyper-V Backup-Intent bindet die VM vor SQL und bestätigt erst nach dem Export die Gastdatei-Abwesenheit' (
        $backupIntent.Drift -ceq 'HYPERV_BACKUP_INTENT_BINDING_INVALID' -and $backupIntent.Exports -eq 1 -and
        $backupIntent.Before.Status -ceq 'GUEST_FILE_UNCONFIRMED' -and $backupIntent.Receipt.Status -ceq 'GUEST_FILE_REMOVED' -and
        $backupIntent.Before.OperationKey -ceq $backupIntent.Receipt.OperationKey -and
        $backupIntent.Receipt.VMId -ceq '61616161-2222-4333-8444-555555555555' -and $backupIntent.Success -ceq 'BACKUP_REUSABLE')

    Add-CheckResult 'Hyper-V Backup-Intent überschreibt keinen inzwischen ersetzten Datensatz' (
        $backupIntent.RecordDrift -ceq 'HYPERV_BACKUP_INTENT_PATH_INVALID' -and
        $backupIntent.DriftBytes -ceq 'FOREIGN_RECORD_CANARY')

    $cleanupProof=& $module {
        param($Password)
        $guest=[PSCredential]::new('Administrator',$Password)
        function Get-HyperVLabWorkflowRun {
            [pscustomobject]@{Run=[pscustomobject]@{runId='43434343-2222-4333-8444-555555555555';scopeId='61616161-2222-4333-8444-555555555555'}
                Instance=[pscustomobject]@{vmName='synthetic-vm'}}
        }
        $reply=[pscustomobject]@{Removed=$false}
        function Invoke-HyperVPowerShellDirect { $reply }
        $restoreCleanup=@{RunId='43434343-2222-4333-8444-555555555555';Path='C:\Synthetic\owned-copy.bak';Credential=$guest;StateRoot='synthetic-state'}
        $falseDenied=try { Remove-LabHyperVGuestFile @restoreCleanup; $false } catch { $_.Exception.Message -ceq 'HYPERV_GUEST_FILE_CLEANUP_UNCONFIRMED' }
        $reply.Removed=$true
        $null=Remove-LabHyperVGuestFile @restoreCleanup
        $falseDenied
    } $password
    Add-CheckResult 'Hyper-V-Kopienbereinigung verlangt explizit die bestätigte Abwesenheit im gebundenen Gast' ([bool]$cleanupProof)

    $serverAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
    $parser=$serverAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
        $node.Name -ceq 'Get-UiHyperVLibraryRestoreRequest'},$true)
    $parseRequest=[scriptblock]::Create($parser.Body.Extent.Text.Trim().Substring(1,$parser.Body.Extent.Text.Trim().Length-2))
    $request=@{parameters=@{RunId='43434343-2222-4333-8444-555555555555';InstanceId='primary';BackupSetId='51515151-2222-4333-8444-555555555555';
        DatabaseName='NewRestoreDb';GuestUserName='Administrator';GuestPassword='SyntheticGuest';SaPassword='SyntheticSa'};confirmed=$true}
    $typed=& $parseRequest -Body ($request|ConvertTo-Json -Compress)
    try {
        Add-CheckResult 'Hyper-V Restore-Parser bindet beide Zugänge als nur lesbare SecureStrings vor dem flüchtigen Job' (
            $typed.GuestPassword -is [SecureString] -and $typed.GuestPassword.IsReadOnly() -and
            $typed.SaPassword -is [SecureString] -and $typed.SaPassword.IsReadOnly() -and $typed.Count -eq 7)
    } finally { $typed.GuestPassword.Dispose();$typed.SaPassword.Dispose() }
    $request.parameters['Replace']=$true
    $replaceDenied=try { $null=& $parseRequest -Body ($request|ConvertTo-Json -Compress);$false } catch { $_.Exception.Message -ceq 'HYPERV_LIBRARY_RESTORE_INPUT_INVALID' }
    $null=$request.parameters.Remove('Replace')
    $request.confirmed=$false
    $unconfirmedDenied=try { $null=& $parseRequest -Body ($request|ConvertTo-Json -Compress);$false } catch { $_.Exception.Message -ceq 'HYPERV_LIBRARY_RESTORE_INPUT_INVALID' }
    Add-CheckResult 'Hyper-V Restore-Parser verwirft Replace und fehlende Bestätigung vor jeder Jobanlage' ($replaceDenied -and $unconfirmedDenied)
}
finally {
    $env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
}

$failed=@($results | Where-Object { -not $_.Success })
if($failed.Count -gt 0){ throw "BACKUP LIBRARY CHECKS FAILED: $($failed.Name -join '; ')" }
Write-Host "BACKUP LIBRARY CHECKS: PASS ($($results.Count))" -ForegroundColor Green
