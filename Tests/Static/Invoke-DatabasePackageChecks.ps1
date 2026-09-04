#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-database-package-$([Guid]::NewGuid().ToString('N'))"
$dataRoot=Join-Path $testRoot 'Lab_Data'
$previousDataRoot=$env:SQL_SERVER_LAB_DATA_ROOT
$results=[Collections.Generic.List[object]]::new()

function Add-CheckResult { param([string]$Name,[bool]$Success,[string]$Detail='') $results.Add([PSCustomObject]@{Name=$Name;Success=$Success;Detail=$Detail});$color=if($Success){'Green'}else{'Red'};Write-Host "$(if($Success){'PASS'}else{'FAIL'}): $Name $Detail" -ForegroundColor $color }

try {
    New-Item -ItemType Directory -Path $testRoot -Force|Out-Null
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $result=& $module {
        param($Root,$WorkRoot)
        $null=Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false
        $env:SQL_SERVER_LAB_DATA_ROOT=$Root
        $source=Join-Path $WorkRoot 'source';$stream=Join-Path $source 'EvidenceStream';$nested=Join-Path $stream 'nested'
        New-Item -ItemType Directory -Path $nested -Force|Out-Null
        [IO.File]::WriteAllBytes((Join-Path $source 'Evidence.mdf'),[Text.Encoding]::UTF8.GetBytes('primary-data'))
        [IO.File]::WriteAllBytes((Join-Path $source 'Evidence_2.ndf'),[Text.Encoding]::UTF8.GetBytes('secondary-data'))
        [IO.File]::WriteAllBytes((Join-Path $source 'Evidence_log.ldf'),[Text.Encoding]::UTF8.GetBytes('transaction-log'))
        [IO.File]::WriteAllBytes((Join-Path $stream 'root.bin'),[byte[]](1,2,3,4))
        [IO.File]::WriteAllBytes((Join-Path $nested 'blob.bin'),[byte[]](5,6,7,8,9))
        $inventory=@(
            [PSCustomObject]@{LogicalName='Evidence';Type='DATA';FullPath=Join-Path $source 'Evidence.mdf'},
            [PSCustomObject]@{LogicalName='EvidenceSecondary';Type='DATA';FullPath=Join-Path $source 'Evidence_2.ndf'},
            [PSCustomObject]@{LogicalName='EvidenceLog';Type='LOG';FullPath=Join-Path $source 'Evidence_log.ldf'},
            [PSCustomObject]@{LogicalName='EvidenceStream';Type='FILESTREAM';FullPath=$stream}
        )
        $evidence=[PSCustomObject]@{DatabaseState='OFFLINE';DetachState='CLEAN_OFFLINE';AccessMode='EXCLUSIVE';WriterCount=0;StateObservedAfterLock=$true}
        $metadata=[PSCustomObject]@{HasFileStream=$true;FileStreamInventoryComplete=$true;IsEncrypted=$false;TdeKeyEvidenceVerified=$false}
        $dependencyObservation=[PSCustomObject]@{SqlMajorVersion='17';Containment='NONE';IsEncrypted=$false;EncryptionState=0;EncryptorType='NONE';ServerLoginMappingCount=1;SqlAgentJobCount=0;CredentialOrProxyCount=0;LinkedServerCount=0}
        $dependencyInventory=New-LabDatabaseMigrationDependencyInventory -DatabaseName Evidence -Provider hyperv -RunId 'sanitized-run' -InstanceId primary -Observation $dependencyObservation
        $created=New-LabDatabasePackage -DatabaseName Evidence -Provider hyperv -SqlMajorVersion 17 -RunId 'sanitized-run' -InstanceId primary -SourceEvidence $evidence -DatabaseMetadata $metadata -FileInventory $inventory -DataRoot $Root -MigrationDependencyInventory $dependencyInventory
        $storageConfiguration=Get-LabStorageConfiguration -DataRoot $Root
        $legacyCatalog=Get-LabPersistentStorageCatalog -Configuration $storageConfiguration
        $initialPersistentCatalog=$legacyCatalog
        $legacyDocument=$legacyCatalog.Document|ConvertTo-Json -Depth 40|ConvertFrom-Json -Depth 40
        $legacyDocument.Stores=@($legacyDocument.Stores|Where-Object{
            @($_.References|Where-Object{[string]$_.TargetId -eq [string]$created.DatabasePackageId}).Count -eq 0
        })
        $legacyDocument.Revision=[int]$legacyDocument.Revision+1
        $null=Write-LabPersistentStorageCatalogDocument -Document $legacyDocument -Configuration $storageConfiguration
        $catalogPath=(Get-LabPersistentStorageCatalog -Configuration $storageConfiguration).Sources[0].Path
        $previewHashBefore=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
        $publicSyncPreview=Sync-SqlServerLabPersistentStorageArtifact -DatabasePackageId $created.DatabasePackageId -DataRoot $Root -WhatIf
        $previewHashAfter=(Get-FileHash -LiteralPath $catalogPath -Algorithm SHA256).Hash
        $publicSync=Sync-SqlServerLabPersistentStorageArtifact -DatabasePackageId $created.DatabasePackageId -DataRoot $Root -Confirm:$false
        $publicSyncAgain=Sync-SqlServerLabPersistentStorageArtifact -DatabasePackageId $created.DatabasePackageId -DataRoot $Root -Confirm:$false
        $persistentCatalog=Get-LabPersistentStorageCatalog -Configuration $storageConfiguration
        $residencyInventory=Get-LabStorageResidencyInventory -Configuration $storageConfiguration -StateRoot (Join-Path $Root 'State')
        $syncResult=@(Sync-LabDatabasePackagePersistentStorageCatalog -DataRoot $Root)
        $package=Get-LabDatabasePackage -DatabasePackageId $created.DatabasePackageId -DataRoot $Root
        $selection=@(Get-LabDatabasePackageSelection -DataRoot $Root)
        $publicSelection=@(Get-SqlServerLabDatabasePackage -DatabasePackageId $created.DatabasePackageId -DataRoot $Root -VerifyIntegrity)
        $cloneRoot=Join-Path $WorkRoot 'clone';$clone=Copy-LabDatabasePackageClone -Package $package -TargetDirectory $cloneRoot
        $ready=Get-LabDatabasePackageAttachPlan -Package $package -TargetDirectory (Join-Path $WorkRoot 'attach-ready') -TargetEvidence ([PSCustomObject]@{SqlMajorVersion=17;FileStreamEnabled=$true;TdeKeyAvailable=$false;DatabaseExists=$false;ExclusiveUseAvailable=$true;PackageWriterCount=0})
        $old=Get-LabDatabasePackageAttachPlan -Package $package -TargetDirectory (Join-Path $WorkRoot 'attach-old') -TargetEvidence ([PSCustomObject]@{SqlMajorVersion=16;FileStreamEnabled=$true;TdeKeyAvailable=$false;DatabaseExists=$false;ExclusiveUseAvailable=$true;PackageWriterCount=0})
        $noStream=Get-LabDatabasePackageAttachPlan -Package $package -TargetDirectory (Join-Path $WorkRoot 'attach-no-stream') -TargetEvidence ([PSCustomObject]@{SqlMajorVersion=17;FileStreamEnabled=$false;TdeKeyAvailable=$false;DatabaseExists=$false;ExclusiveUseAvailable=$true;PackageWriterCount=0})
        $parallel=Get-LabDatabasePackageAttachPlan -Package $package -TargetDirectory (Join-Path $WorkRoot 'attach-parallel') -TargetEvidence ([PSCustomObject]@{SqlMajorVersion=17;FileStreamEnabled=$true;TdeKeyAvailable=$false;DatabaseExists=$false;ExclusiveUseAvailable=$false;PackageWriterCount=1})
        $attachCalls=[Collections.Generic.List[object]]::new();$attachRoot=Join-Path $WorkRoot 'attached';$attachPlan=Get-LabDatabasePackageAttachPlan -Package $package -TargetDirectory $attachRoot -TargetEvidence ([PSCustomObject]@{SqlMajorVersion=17;FileStreamEnabled=$true;TdeKeyAvailable=$false;DatabaseExists=$false;ExclusiveUseAvailable=$true;PackageWriterCount=0})
        $attached=Invoke-LabDatabasePackageAttachPlan -Plan $attachPlan -Package $package -OperationDirectory (Join-Path $WorkRoot 'attach-operation') -Confirm:$false -AttachAction {
            param($DatabaseName,$Files)$attachCalls.Add([PSCustomObject]@{DatabaseName=$DatabaseName;Files=@($Files)})
        } -VerifyAction { param($DatabaseName,$Files)[PSCustomObject]@{DatabaseState='ONLINE';AttachmentCount=1;PathsMatch=@($Files|Where-Object{-not(Test-Path -LiteralPath $_.Path)}).Count -eq 0} }
        $publicTargetRoot=Join-Path $WorkRoot 'public-hyperv-target'
        $publicOperationRoot=Join-Path $WorkRoot 'public-hyperv-operation'
        $fakeContext=[PSCustomObject]@{
            Lab=[PSCustomObject]@{Run=[PSCustomObject]@{runId='synthetic-target-run';scopeId='synthetic-target-scope'};Instance=[PSCustomObject]@{id='primary';vmName='synthetic-target-vm'}}
            TargetDirectory=$publicTargetRoot
            OperationDirectory=$publicOperationRoot
            TargetEvidence=[PSCustomObject]@{SqlMajorVersion=17;FileStreamEnabled=$true;TdeKeyAvailable=$false;DatabaseExists=$false;ExclusiveUseAvailable=$true;PackageWriterCount=0;TargetDirectoryEmpty=$true}
        }
        $testSecret=[Security.SecureString]::new()
        foreach($character in 'synthetic-only'.ToCharArray()){$testSecret.AppendChar($character)}
        $testSecret.MakeReadOnly()
        $credential=[PSCredential]::new('Administrator',$testSecret)
        $originalContext=(Get-Command Get-LabHyperVDatabasePackageAttachContext -CommandType Function).ScriptBlock
        $originalCopy=(Get-Command Copy-LabDatabasePackageToHyperVGuest -CommandType Function).ScriptBlock
        $originalSqlAttach=(Get-Command Invoke-LabHyperVDatabasePackageSqlAttach -CommandType Function).ScriptBlock
        $originalRecovery=(Get-Command Invoke-LabHyperVDatabasePackageAttachRecovery -CommandType Function).ScriptBlock
        $script:publicAttachCopyCalls=0;$script:publicAttachSqlCalls=0;$script:publicAttachRecoveryCalls=0;$script:publicAttachJournalProtected=$false
        try {
            Set-Item Function:script:Get-LabHyperVDatabasePackageAttachContext -Value { return $fakeContext }.GetNewClosure()
            Set-Item Function:script:Copy-LabDatabasePackageToHyperVGuest -Value {
                param($Context,$Package,$Credential)
                $script:publicAttachCopyCalls++
                [PSCustomObject]@{Status='VERIFIED';TargetCopyVerified=$true}
            }
            Set-Item Function:script:Invoke-LabHyperVDatabasePackageSqlAttach -Value {
                param($Context,$Package,$Credential)
                $script:publicAttachSqlCalls++
                $journal=Get-Content -LiteralPath (Join-Path $Context.OperationDirectory 'database-package-attach-journal.json') -Raw|ConvertFrom-Json
                $script:publicAttachJournalProtected=[string]$journal.Status -eq 'ATTACHING' -and [bool]$journal.AttachInvoked -and [bool]$journal.TargetCopyVerified -and $journal.Recovery -eq 'DETACH_TARGET_COPY_AND_PRESERVE_PACKAGE'
                [PSCustomObject]@{DatabaseState='ONLINE';AttachmentCount=1;PathsMatch=$true}
            }
            Set-Item Function:script:Invoke-LabHyperVDatabasePackageAttachRecovery -Value {
                param($Package,$Context,$Journal,$Credential)
                $script:publicAttachRecoveryCalls++
                [PSCustomObject]@{Status='RECOVERED';DatabaseAbsent=$true}
            }
            $publicPreview=Invoke-SqlServerLabDatabasePackageAttach -DatabasePackageId $created.DatabasePackageId -RunId 'synthetic-target-run' -InstanceId primary -GuestCredential $credential -DataRoot $Root -WhatIf
            $previewDidNotExecute=$script:publicAttachCopyCalls -eq 0 -and $script:publicAttachSqlCalls -eq 0 -and -not(Test-Path -LiteralPath $publicOperationRoot)
            $publicAttach=Invoke-SqlServerLabDatabasePackageAttach -DatabasePackageId $created.DatabasePackageId -RunId 'synthetic-target-run' -InstanceId primary -GuestCredential $credential -DataRoot $Root -Confirm:$false
            $recoveryJournal=Get-Content -LiteralPath (Join-Path $publicOperationRoot 'database-package-attach-journal.json') -Raw|ConvertFrom-Json
            $recoveryJournal.Status='RECOVERY_REQUIRED';$recoveryJournal.Recovery='DETACH_TARGET_COPY_AND_PRESERVE_PACKAGE'
            Write-LabDatabasePackageAttachJournal -Journal $recoveryJournal -Path (Join-Path $publicOperationRoot 'database-package-attach-journal.json')
            $publicRecovery=Invoke-SqlServerLabDatabasePackageAttach -DatabasePackageId $created.DatabasePackageId -RunId 'synthetic-target-run' -InstanceId primary -GuestCredential $credential -DataRoot $Root -Recover -Confirm:$false
        }
        finally {
            Set-Item Function:script:Get-LabHyperVDatabasePackageAttachContext -Value $originalContext
            Set-Item Function:script:Copy-LabDatabasePackageToHyperVGuest -Value $originalCopy
            Set-Item Function:script:Invoke-LabHyperVDatabasePackageSqlAttach -Value $originalSqlAttach
            Set-Item Function:script:Invoke-LabHyperVDatabasePackageAttachRecovery -Value $originalRecovery
        }
        $originalContainerContext=(Get-Command Get-LabContainerReconcileContext -CommandType Function).ScriptBlock
        $originalContainerExport=(Get-Command Export-LabContainerDatabasePackage -CommandType Function).ScriptBlock
        $script:publicContainerPackageExportCalls=0
        try {
            Set-Item Function:script:Get-LabContainerReconcileContext -Value {
                [PSCustomObject]@{Provider='docker';WasRunning=$true}
            }
            Set-Item Function:script:Export-LabContainerDatabasePackage -Value {
                param($RunId,$InstanceId,$DatabaseName,$DataRoot,$StateRoot)
                $script:publicContainerPackageExportCalls++
                [PSCustomObject]@{Status='REUSABLE';DatabasePackageId='11111111-1111-1111-1111-111111111111';PersistentStorageId='22222222-2222-2222-2222-222222222222';Path=$DataRoot;ManifestSha256='a'*64}
            }
            $publicContainerExportPreview=Export-SqlServerLabDatabasePackage -RunId '33333333-3333-3333-3333-333333333333' -InstanceId primary -DatabaseName Evidence -DataRoot $Root -StateRoot (Join-Path $WorkRoot 'container-state') -WhatIf
            $publicContainerExport=Export-SqlServerLabDatabasePackage -RunId '33333333-3333-3333-3333-333333333333' -InstanceId primary -DatabaseName Evidence -DataRoot $Root -StateRoot (Join-Path $WorkRoot 'container-state') -Confirm:$false
        }
        finally {
            Set-Item Function:script:Get-LabContainerReconcileContext -Value $originalContainerContext
            Set-Item Function:script:Export-LabContainerDatabasePackage -Value $originalContainerExport
        }
        $badDetach=$false
        try { $null=New-LabDatabasePackage -DatabaseName BadDetach -Provider hyperv -SqlMajorVersion 17 -SourceEvidence ([PSCustomObject]@{DatabaseState='ONLINE';DetachState='UNKNOWN';AccessMode='MULTI_USER';WriterCount=1;StateObservedAfterLock=$false}) -DatabaseMetadata $metadata -FileInventory $inventory -DataRoot $Root } catch { $badDetach=$_.Exception.Message -match 'SOURCE_NOT_OFFLINE|CLEAN_DETACH_UNVERIFIED|SOURCE_NOT_EXCLUSIVE' }
        $tde=$false
        try { $null=New-LabDatabasePackage -DatabaseName Encrypted -Provider hyperv -SqlMajorVersion 17 -SourceEvidence $evidence -DatabaseMetadata ([PSCustomObject]@{HasFileStream=$true;FileStreamInventoryComplete=$true;IsEncrypted=$true;TdeKeyEvidenceVerified=$false}) -FileInventory $inventory -DataRoot $Root } catch { $tde=$_.Exception.Message -match 'TDE_KEY_EVIDENCE_REQUIRED' }
        $originalRegistration=(Get-Command Register-LabDatabasePackagePersistentStorage -CommandType Function).ScriptBlock
        Set-Item Function:script:Register-LabDatabasePackagePersistentStorage -Value { throw 'SYNTHETIC_PACKAGE_CATALOG_FAILURE' }
        $catalogFailure=$false
        try {
            $null=New-LabDatabasePackage -DatabaseName CatalogFailure -Provider hyperv -SqlMajorVersion 17 -SourceEvidence $evidence -DatabaseMetadata $metadata -FileInventory $inventory -DataRoot $Root
        } catch { $catalogFailure=$_.Exception.Message -match 'DATABASE_PACKAGE_CATALOG_REGISTRATION_FAILED.*SYNTHETIC_PACKAGE_CATALOG_FAILURE' }
        finally { Set-Item Function:script:Register-LabDatabasePackagePersistentStorage -Value $originalRegistration }
        $afterCatalogFailure=Get-LabDatabasePackageDocument -Paths (Get-LabDatabasePackagePaths -DataRoot $Root)
        $quarantined=@($afterCatalogFailure.Packages|Where-Object{$_.DatabaseName -eq 'CatalogFailure' -and $_.Status -eq 'QUARANTINED'})
        $quarantineGuard=$false
        if($quarantined.Count -eq 1){
            try{$null=Get-LabDatabasePackage -DatabasePackageId ([string]$quarantined[0].DatabasePackageId) -DataRoot $Root}catch{$quarantineGuard=$_.Exception.Message -match 'DATABASE_PACKAGE_NOT_REUSABLE'}
        }
        $catalogFailureJournal=if($quarantined.Count -eq 1){
            Get-Content -LiteralPath (Join-Path (Join-Path (Get-LabDatabasePackagePaths -DataRoot $Root).OperationsRoot ([string]$quarantined[0].DatabasePackageId)) 'database-package-journal.json') -Raw|ConvertFrom-Json
        }else{$null}
        $objectPath=Join-Path $package.Path ([string]$package.Record.Objects[0].RelativePath)
        [IO.File]::AppendAllText($objectPath,'tamper')
        $tamper=$false
        try{$null=Get-LabDatabasePackage -DatabasePackageId $created.DatabasePackageId -DataRoot $Root}catch{$tamper=$_.Exception.Message -match 'OBJECT_HASH_MISMATCH'}
        [PSCustomObject]@{Created=$created;Package=$package;Selection=$selection;PublicSelection=$publicSelection;PublicSyncPreview=$publicSyncPreview;PublicSync=$publicSync;PublicSyncAgain=$publicSyncAgain;PreviewDidNotMutate=$previewHashBefore -eq $previewHashAfter;InitialPersistentCatalog=$initialPersistentCatalog;PersistentCatalog=$persistentCatalog;ResidencyInventory=$residencyInventory;SyncResult=$syncResult;Clone=$clone;Ready=$ready;Old=$old;NoStream=$noStream;Parallel=$parallel;Attached=$attached;AttachCalls=@($attachCalls);PublicAttachPreview=$publicPreview;PublicAttachPreviewDidNotExecute=$previewDidNotExecute;PublicAttach=$publicAttach;PublicRecovery=$publicRecovery;PublicAttachRecoveryCalls=$script:publicAttachRecoveryCalls;PublicAttachCopyCalls=$script:publicAttachCopyCalls;PublicAttachSqlCalls=$script:publicAttachSqlCalls;PublicAttachJournalProtected=$script:publicAttachJournalProtected;PublicContainerExportPreview=$publicContainerExportPreview;PublicContainerExport=$publicContainerExport;PublicContainerExportCalls=$script:publicContainerPackageExportCalls;BadDetach=$badDetach;Tde=$tde;CatalogFailure=$catalogFailure;CatalogFailureQuarantined=$quarantined.Count -eq 1;QuarantineGuard=$quarantineGuard;CatalogFailureJournal=$catalogFailureJournal;Tamper=$tamper;CloneFiles=@(Get-ChildItem -LiteralPath $cloneRoot -File -Recurse)}
    } $dataRoot $testRoot

    Add-CheckResult 'Offline-Paket enthält MDF, NDF, LDF und vollständigen FILESTREAM-Baum' ($result.Package.Record.DatabaseFiles.Count -eq 4 -and $result.Package.Record.Objects.Count -eq 5 -and @($result.Package.Record.DatabaseFiles|Where-Object Type -eq 'FILESTREAM').Count -eq 1)
    Add-CheckResult 'Paketmanifest und Objektmenge werden als REUSABLE veröffentlicht' ($result.Created.Status -eq 'REUSABLE' -and $result.Created.ManifestSha256 -match '^[a-f0-9]{64}$')
    Add-CheckResult 'CLI-Auswahl verwendet stabile ID und hasht nur auf ausdrückliche Verifikation' (
        $result.Selection.Count -eq 1 -and $result.Selection[0].DatabasePackageId -eq $result.Created.DatabasePackageId -and
        $result.Selection[0].Availability -eq 'SELECTABLE' -and $result.Selection[0].IntegrityValidation -eq 'DEFERRED_UNTIL_USE' -and
        $result.PublicSelection.Count -eq 1 -and $result.PublicSelection[0].IntegrityValidation -eq 'VERIFIED')
    Add-CheckResult 'Öffentlicher Bestands-Sync plant ohne Mutation und registriert genau eine DatabasePackageId idempotent' (
        $result.PublicSyncPreview.ContractVersion -eq 'SqlServerLab.PersistentStorageArtifactSyncResult/1.0' -and
        $result.PublicSyncPreview.Status -eq 'PLANNED' -and $result.PublicSyncPreview.WouldChange -and
        -not $result.PublicSyncPreview.PersistentStorageId -and $result.PreviewDidNotMutate -and
        $result.PublicSync.Status -eq 'SYNCED' -and $result.PublicSync.Changed -and
        $result.PublicSyncAgain.Status -eq 'NO_CHANGE' -and -not $result.PublicSyncAgain.Changed -and
        [string]$result.PublicSync.PersistentStorageId -eq [string]$result.PublicSyncAgain.PersistentStorageId -and
        ($result.PublicSync|ConvertTo-Json -Depth 10) -notmatch [regex]::Escape($testRoot))
    $selectionJson=$result.Selection|ConvertTo-Json -Depth 20
    Add-CheckResult 'Browser-Inventur enthält weder Hostpfade noch Hashes und autorisiert keinen Attach' (
        $selectionJson -notmatch [regex]::Escape($testRoot) -and $selectionJson -notmatch 'ManifestSha256|Sha256|Password|Credential' -and
        $result.Selection[0].AttachStatus -eq 'TARGET_BINDING_REQUIRED' -and $result.Selection[0].AttachReason -eq 'TARGET_PROVIDER_PATH_MAPPING_NOT_BOUND')
    Add-CheckResult 'CLI- und Browser-Inventur zeigen sanitisierte Migrationsgrenzen ohne erneute SQL-Abfrage' (
        $result.Selection[0].DependencyInventoryStatus -eq 'SQL_ENGINE_COMPLETE_EXTERNAL_REVIEW_REQUIRED' -and
        'SERVER_LOGIN_MAPPING' -in $result.Selection[0].DependencyCategories -and
        'SERVER_CONFIGURATION' -in $result.Selection[0].DependencyCategories -and
        'SERVER_OBJECTS_NOT_INCLUDED' -in $result.Selection[0].MigrationWarnings -and
        $selectionJson -notmatch 'RunId|InstanceId|HostName|ObjectName|KeyName')
    $initialPersistentStores=@($result.InitialPersistentCatalog.Document.Stores|Where-Object StorageClass -eq 'DATABASE_PACKAGE')
    $persistentStores=@($result.PersistentCatalog.Document.Stores|Where-Object StorageClass -eq 'DATABASE_PACKAGE')
    Add-CheckResult 'Paketpublikation registriert eine getrennte stabile PersistentStorageId atomar im zentralen Katalog' (
        $result.Created.PersistentStorageId -match '^[0-9a-f-]{36}$' -and $initialPersistentStores.Count -eq 1 -and
        [string]$initialPersistentStores[0].PersistentStorageId -eq [string]$result.Created.PersistentStorageId -and
        [string]$initialPersistentStores[0].References[0].TargetId -eq [string]$result.Created.DatabasePackageId -and
        @($result.SyncResult).Count -eq 1 -and -not [bool]$result.SyncResult[0].Changed -and
        [string]$persistentStores[0].PersistentStorageId -eq [string]$result.PublicSync.PersistentStorageId)
    $packageResidency=@($result.ResidencyInventory.Objects|Where-Object ObjectClass -eq 'DATABASE_PACKAGE')
    $residencyText=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/StorageResidencyInventory.ps1') -Raw
    Add-CheckResult 'Residency-Inventar bindet das Paket ohne erneutes Inhalts-Hashing an dieselbe Objekt-ID' (
        $packageResidency.Count -eq 1 -and $packageResidency[0].AuditStatus -eq 'VERIFIED' -and
        [string]$packageResidency[0].ObjectId -eq [string]$persistentStores[0].LocationBinding.InventoryObjectId -and
        $residencyText -notmatch '(?s)foreach \(\$package.+Get-FileHash')
    Add-CheckResult 'Clone materialisiert eine unabhängige, vollständig gehashte Dateimenge' ($result.Clone.Status -eq 'CLONED' -and $result.CloneFiles.Count -eq 5 -and -not $result.Clone.DirectPackageAttachAllowed)
    Add-CheckResult 'Attach-Plan erzwingt COPY_THEN_ATTACH und verbietet direktes Paket-Attach' ($result.Ready.Status -eq 'READY' -and $result.Ready.Mode -eq 'COPY_THEN_ATTACH' -and -not $result.Ready.DirectPackageAttachAllowed)
    Add-CheckResult 'Attach-Plan weist Datenbankdateien statt vollständiger Instanzmigration aus' ($result.Ready.MigrationBoundary.ArtifactScope -eq 'DATABASE_FILES_ONLY' -and -not $result.Ready.MigrationBoundary.FullInstanceMigration -and 'SERVER_LOGIN_MAPPING' -in $result.Ready.MigrationBoundary.DependencyCategories)
    Add-CheckResult 'Attach-Executor kopiert vor Attach und journalisiert die Online-Postcondition' ($result.Attached.Status -eq 'ATTACHED' -and $result.AttachCalls.Count -eq 1 -and $result.AttachCalls[0].Files.Count -eq 4 -and (Get-Content -LiteralPath $result.Attached.JournalPath -Raw|ConvertFrom-Json).Status -eq 'COMPLETED')
    Add-CheckResult 'Öffentlicher Hyper-V-Attach plant per stabiler ID und Ziel-Run ohne Mutation' (
        $result.PublicAttachPreview.ContractVersion -eq 'SqlServerLab.DatabasePackageAttachResult/1.0' -and
        $result.PublicAttachPreview.Status -eq 'PLANNED' -and $result.PublicAttachPreview.TargetBinding -eq 'RUN_SQL_DEFAULT_DATA' -and
        $result.PublicAttachPreview.IntegrityValidation -eq 'VERIFIED' -and $result.PublicAttachPreviewDidNotExecute)
    $publicAttachJson=$result.PublicAttach|ConvertTo-Json -Depth 30
    Add-CheckResult 'Öffentlicher Hyper-V-Attach schützt die SQL-Mutation vorab und liefert nur sanitisierte Postconditions' (
        $result.PublicAttach.Status -eq 'ATTACHED' -and $result.PublicAttach.TargetCopyVerified -and
        $result.PublicAttach.AttachInvoked -and $result.PublicAttach.PostconditionVerified -and
        $result.PublicAttachCopyCalls -eq 1 -and $result.PublicAttachSqlCalls -eq 1 -and $result.PublicAttachJournalProtected -and
        $publicAttachJson -notmatch [regex]::Escape($testRoot) -and
        $publicAttachJson -notmatch 'TargetDirectory|JournalPath|Sha256|Password|Credential')
    Add-CheckResult 'Öffentlicher Hyper-V-Paket-Attach ist tatsächlich aus dem Modul exportiert' (
        $null -ne (Get-Command Invoke-SqlServerLabDatabasePackageAttach -Module SqlServerLab -ErrorAction SilentlyContinue))
    Add-CheckResult 'Öffentlicher Hyper-V-Paket-Attach führt nur ein passendes Recovery-Journal aus' (
        $result.PublicRecovery.Status -eq 'RECOVERED' -and $result.PublicAttachRecoveryCalls -eq 1)
    $publicContainerExportJson=$result.PublicContainerExport|ConvertTo-Json -Depth 20
    Add-CheckResult 'Öffentlicher Container-Paketexport plant ohne Offline-Mutation und veröffentlicht nur sanitisierte stabile IDs' (
        $result.PublicContainerExportPreview.Status -eq 'PLANNED' -and
        -not $result.PublicContainerExportPreview.DatabasePackageId -and
        $result.PublicContainerExport.Status -eq 'REUSABLE' -and
        $result.PublicContainerExport.Provider -eq 'docker' -and
        $result.PublicContainerExport.DatabasePackageId -eq '11111111-1111-1111-1111-111111111111' -and
        $result.PublicContainerExport.PersistentStorageId -eq '22222222-2222-2222-2222-222222222222' -and
        $result.PublicContainerExportCalls -eq 1 -and
        $publicContainerExportJson -notmatch [regex]::Escape($testRoot) -and
        $publicContainerExportJson -notmatch 'Path|Sha256|Password|Credential')
    Add-CheckResult 'Öffentlicher Container-Paketexport ist tatsächlich aus dem Modul exportiert' (
        $null -ne (Get-Command Export-SqlServerLabDatabasePackage -Module SqlServerLab -ErrorAction SilentlyContinue))
    Add-CheckResult 'Neuer-zu-älter-SQL-Attach endet fail-closed' ('TARGET_SQL_VERSION_OLDER_THAN_SOURCE' -in $result.Old.Blockers)
    Add-CheckResult 'Fehlende FILESTREAM-Capability endet fail-closed' ('TARGET_FILESTREAM_CAPABILITY_MISSING' -in $result.NoStream.Blockers)
    Add-CheckResult 'Parallele Read/Write-Nutzung endet fail-closed' ('TARGET_EXCLUSIVE_USE_UNVERIFIED' -in $result.Parallel.Blockers -and 'PACKAGE_PARALLEL_WRITER_OBSERVED' -in $result.Parallel.Blockers)
    Add-CheckResult 'Inkonsistenter Offline-/Detach-Zustand wird vor Kopie blockiert' $result.BadDetach
    Add-CheckResult 'TDE-Paket verlangt explizite Schlüsselnachweise' $result.Tde
    Add-CheckResult 'Fehlgeschlagener Katalogcommit quarantänisiert Paket und Journal fail-closed' (
        $result.CatalogFailure -and $result.CatalogFailureQuarantined -and $result.QuarantineGuard -and
        $result.CatalogFailureJournal.Status -eq 'RECOVERY_REQUIRED' -and
        $result.CatalogFailureJournal.Recovery -eq 'RETRY_PERSISTENT_STORAGE_CATALOG_REGISTRATION')
    Add-CheckResult 'Veränderte Paketobjekte werden bei erneuter Auswahl blockiert' $result.Tamper
    $registryJson=$result.Package.Record|ConvertTo-Json -Depth 60
    Add-CheckResult 'Package-Receipt enthält keine Quellpfade oder Credentials' ($registryJson -notmatch [regex]::Escape($testRoot) -and $registryJson -notmatch 'Password|Credential|SaPassword')
    $containerExporter=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerDatabasePackage.ps1') -Raw
    Add-CheckResult 'Container-Dateiinventar normiert Systemmetadaten vor der Paketverkettung kollationsfest' (
        @([regex]::Matches($containerExporter,'COLLATE Latin1_General_100_BIN2')).Count -eq 3 -and
        $containerExporter -notmatch "CONCAT\(N'PKG_FILE\|', mf\.type_desc")
}
finally { $env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot;Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }

$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "DATABASE PACKAGE CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "DATABASE PACKAGE CHECKS: PASS ($($results.Count))" -ForegroundColor Green
