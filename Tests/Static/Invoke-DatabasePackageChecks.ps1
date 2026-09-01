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
        [PSCustomObject]@{Created=$created;Package=$package;Selection=$selection;PublicSelection=$publicSelection;PersistentCatalog=$persistentCatalog;ResidencyInventory=$residencyInventory;SyncResult=$syncResult;Clone=$clone;Ready=$ready;Old=$old;NoStream=$noStream;Parallel=$parallel;Attached=$attached;AttachCalls=@($attachCalls);BadDetach=$badDetach;Tde=$tde;CatalogFailure=$catalogFailure;CatalogFailureQuarantined=$quarantined.Count -eq 1;QuarantineGuard=$quarantineGuard;CatalogFailureJournal=$catalogFailureJournal;Tamper=$tamper;CloneFiles=@(Get-ChildItem -LiteralPath $cloneRoot -File -Recurse)}
    } $dataRoot $testRoot

    Add-CheckResult 'Offline-Paket enthält MDF, NDF, LDF und vollständigen FILESTREAM-Baum' ($result.Package.Record.DatabaseFiles.Count -eq 4 -and $result.Package.Record.Objects.Count -eq 5 -and @($result.Package.Record.DatabaseFiles|Where-Object Type -eq 'FILESTREAM').Count -eq 1)
    Add-CheckResult 'Paketmanifest und Objektmenge werden als REUSABLE veröffentlicht' ($result.Created.Status -eq 'REUSABLE' -and $result.Created.ManifestSha256 -match '^[a-f0-9]{64}$')
    Add-CheckResult 'CLI-Auswahl verwendet stabile ID und hasht nur auf ausdrückliche Verifikation' (
        $result.Selection.Count -eq 1 -and $result.Selection[0].DatabasePackageId -eq $result.Created.DatabasePackageId -and
        $result.Selection[0].Availability -eq 'SELECTABLE' -and $result.Selection[0].IntegrityValidation -eq 'DEFERRED_UNTIL_USE' -and
        $result.PublicSelection.Count -eq 1 -and $result.PublicSelection[0].IntegrityValidation -eq 'VERIFIED')
    $selectionJson=$result.Selection|ConvertTo-Json -Depth 20
    Add-CheckResult 'Browser-Inventur enthält weder Hostpfade noch Hashes und autorisiert keinen Attach' (
        $selectionJson -notmatch [regex]::Escape($testRoot) -and $selectionJson -notmatch 'ManifestSha256|Sha256|Password|Credential' -and
        $result.Selection[0].AttachStatus -eq 'TARGET_BINDING_REQUIRED' -and $result.Selection[0].AttachReason -eq 'TARGET_PROVIDER_PATH_MAPPING_NOT_BOUND')
    $persistentStores=@($result.PersistentCatalog.Document.Stores|Where-Object StorageClass -eq 'DATABASE_PACKAGE')
    Add-CheckResult 'Paketpublikation registriert eine getrennte stabile PersistentStorageId atomar im zentralen Katalog' (
        $result.Created.PersistentStorageId -match '^[0-9a-f-]{36}$' -and $persistentStores.Count -eq 1 -and
        [string]$persistentStores[0].PersistentStorageId -eq [string]$result.Created.PersistentStorageId -and
        [string]$persistentStores[0].References[0].TargetId -eq [string]$result.Created.DatabasePackageId -and
        @($result.SyncResult).Count -eq 1 -and -not [bool]$result.SyncResult[0].Changed)
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
}
finally { $env:SQL_SERVER_LAB_DATA_ROOT=$previousDataRoot;Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue;Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }

$failed=@($results|Where-Object{-not $_.Success})
if($failed.Count -gt 0){throw "DATABASE PACKAGE CHECKS FAILED: $($failed.Name -join '; ')"}
Write-Host "DATABASE PACKAGE CHECKS: PASS ($($results.Count))" -ForegroundColor Green
