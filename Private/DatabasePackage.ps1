<#
.SYNOPSIS
    Verwaltet unveraenderliche, vollstaendig gehashte Offline-Datenbankpakete.
.DESCRIPTION
    Ein DATABASE_PACKAGE wird nur aus einer nachweislich exklusiven, sauber
    offline oder detached vorliegenden Dateimenge publiziert. MDF/NDF/LDF und
    FILESTREAM-Container werden rekursiv inventarisiert. Clone und Attach
    erhalten immer eine neue physische Kopie; Bibliotheksobjekte werden niemals
    direkt read/write an SQL Server gebunden.
#>

function Get-LabDatabasePackagePaths {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DataRoot)

    $root=Resolve-LabDataRootForUse -DataRoot $DataRoot
    $libraryRoot=Join-Path $root 'DatabasePackages'
    [PSCustomObject]@{
        DataRoot=$root
        LibraryRoot=$libraryRoot
        ObjectsRoot=Join-Path $libraryRoot 'Objects'
        RegistryPath=Join-Path $libraryRoot 'database-package-library.json'
        OperationsRoot=Join-Path $libraryRoot 'Operations'
    }
}

function Invoke-LabDatabasePackageLock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$LibraryRoot,[Parameter(Mandatory)][scriptblock]$ScriptBlock)

    $material=[Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($LibraryRoot).ToLowerInvariant())
    $token=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($material)).Substring(0,16)
    $name=if($IsWindows){"Global\SQL_Server_Lab_Database_Package_$token"}else{"SQL_Server_Lab_Database_Package_$token"}
    $mutex=[Threading.Mutex]::new($false,$name);$acquired=$false
    try {
        $acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(30))
        if(-not $acquired){throw 'DATABASE_PACKAGE_LOCK_TIMEOUT'}
        & $ScriptBlock
    }
    finally { if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose() }
}

function Test-LabDatabasePackageRelativePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path)
    return (-not [IO.Path]::IsPathFullyQualified($Path) -and $Path -notmatch '(^|[\\/])\.\.([\\/]|$)')
}

function Test-LabDatabasePackageDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Document)

    try {
        $valid=$Document|ConvertTo-Json -Depth 60|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'database-package-library.schema.json') -ErrorAction Stop
    } catch { throw "DATABASE_PACKAGE_LIBRARY_SCHEMA_INVALID: $($_.Exception.Message)" }
    if(-not $valid){throw 'DATABASE_PACKAGE_LIBRARY_SCHEMA_INVALID'}
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($package in @($Document.Packages)){
        if(-not $ids.Add([string]$package.DatabasePackageId)){throw 'DATABASE_PACKAGE_ID_DUPLICATE'}
        $objectPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach($object in @($package.Objects)){
            if(-not (Test-LabDatabasePackageRelativePath -Path ([string]$object.RelativePath))){throw 'DATABASE_PACKAGE_RELATIVE_PATH_INVALID'}
            if(-not $objectPaths.Add(([string]$object.RelativePath).Replace('\','/'))){throw 'DATABASE_PACKAGE_OBJECT_PATH_DUPLICATE'}
        }
        foreach($file in @($package.DatabaseFiles)){
            if(-not (Test-LabDatabasePackageRelativePath -Path ([string]$file.RelativeRoot))){throw 'DATABASE_PACKAGE_RELATIVE_ROOT_INVALID'}
            $matches=@($package.Objects|Where-Object DatabaseFileLogicalName -eq ([string]$file.LogicalName))
            if($matches.Count -lt 1){throw 'DATABASE_PACKAGE_DATABASE_FILE_EMPTY'}
            if([string]$file.Type -eq 'FILESTREAM' -and -not [bool]$file.IsDirectory){throw 'DATABASE_PACKAGE_FILESTREAM_ROOT_INVALID'}
            if([string]$file.Type -ne 'FILESTREAM' -and [bool]$file.IsDirectory){throw 'DATABASE_PACKAGE_FILE_ROOT_INVALID'}
        }
    }
    return $true
}

function Test-LabDatabasePackageJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    try{$valid=$Journal|ConvertTo-Json -Depth 40|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'database-package-journal.schema.json') -ErrorAction Stop}catch{throw "DATABASE_PACKAGE_JOURNAL_SCHEMA_INVALID: $($_.Exception.Message)"}
    if(-not $valid){throw 'DATABASE_PACKAGE_JOURNAL_SCHEMA_INVALID'}
    return $true
}

function Write-LabDatabasePackageJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp;$null=Test-LabDatabasePackageJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Get-LabDatabasePackageDocument {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Paths)
    if(-not(Test-Path -LiteralPath $Paths.RegistryPath -PathType Leaf)){
        return [PSCustomObject][ordered]@{ContractVersion='SqlServerLab.DatabasePackageLibrary/1.0';Revision=0;UpdatedAt=Get-LabTimestamp;Packages=@()}
    }
    try {
        $document=Get-Content -LiteralPath $Paths.RegistryPath -Raw -Encoding utf8|ConvertFrom-Json -Depth 60 -ErrorAction Stop
        $null=Test-LabDatabasePackageDocument -Document $document
        return $document
    } catch { throw "DATABASE_PACKAGE_LIBRARY_INVALID: $($_.Exception.Message)" }
}

function Get-LabDatabasePackageManifestSha256 {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package)
    $lines=[Collections.Generic.List[string]]::new()
    $lines.Add("DATABASE|$($Package.DatabaseName)|$($Package.Source.SqlMajorVersion)|$([bool]$Package.DatabaseMetadata.HasFileStream)|$([bool]$Package.DatabaseMetadata.IsEncrypted)")
    foreach($file in @($Package.DatabaseFiles|Sort-Object LogicalName)){
        $lines.Add("FILE|$($file.LogicalName)|$($file.Type)|$($file.RelativeRoot)|$([bool]$file.IsDirectory)")
    }
    foreach($object in @($Package.Objects|Sort-Object RelativePath)){
        $lines.Add("OBJECT|$($object.DatabaseFileLogicalName)|$($object.RelativePath.Replace('\','/'))|$($object.Bytes)|$($object.Sha256)")
    }
    $bytes=[Text.Encoding]::UTF8.GetBytes(($lines -join "`n"))
    return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()
}

function Get-LabDatabasePackageSourceObjects {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$FileInventory)

    $objects=[Collections.Generic.List[object]]::new();$databaseFiles=[Collections.Generic.List[object]]::new()
    $logicalNames=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $relativeRoots=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $physicalPaths=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach($entry in $FileInventory){
        $logical=[string]$entry.LogicalName;$type=[string]$entry.Type;$path=[IO.Path]::GetFullPath([string]$entry.FullPath)
        if(-not $logicalNames.Add($logical)){throw 'DATABASE_PACKAGE_LOGICAL_NAME_DUPLICATE'}
        if(-not $physicalPaths.Add($path)){throw 'DATABASE_PACKAGE_PHYSICAL_PATH_DUPLICATE'}
        if($type -notin @('DATA','LOG','FILESTREAM')){throw 'DATABASE_PACKAGE_FILE_TYPE_INVALID'}
        $isDirectory=$type -eq 'FILESTREAM'
        if($isDirectory -and -not(Test-Path -LiteralPath $path -PathType Container)){throw 'DATABASE_PACKAGE_FILESTREAM_CONTAINER_MISSING'}
        if(-not $isDirectory -and -not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'DATABASE_PACKAGE_FILE_MISSING'}
        $safeLogical=($logical -replace '[^A-Za-z0-9_.-]','_')
        $relativeRoot=Join-Path 'Files' $safeLogical
        if(-not $relativeRoots.Add($relativeRoot)){throw 'DATABASE_PACKAGE_RELATIVE_ROOT_COLLISION'}
        $databaseFiles.Add([PSCustomObject][ordered]@{LogicalName=$logical;Type=$type;RelativeRoot=$relativeRoot;IsDirectory=$isDirectory})
        if($isDirectory){
            $children=@(Get-ChildItem -LiteralPath $path -File -Recurse -Force|Sort-Object FullName)
            if($children.Count -eq 0){throw 'DATABASE_PACKAGE_FILESTREAM_CONTAINER_EMPTY_UNVERIFIED'}
            foreach($child in $children){
                $childRelative=[IO.Path]::GetRelativePath($path,$child.FullName)
                $objects.Add([PSCustomObject][ordered]@{DatabaseFileLogicalName=$logical;SourcePath=$child.FullName;RelativePath=(Join-Path $relativeRoot $childRelative);Bytes=[long]$child.Length;Sha256=(Get-FileHash -LiteralPath $child.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
            }
        } else {
            $item=Get-Item -LiteralPath $path
            $extension=if($type -eq 'LOG'){'.ldf'}elseif($item.Extension){$item.Extension}else{'.mdf'}
            $relativePath="$relativeRoot$extension"
            $objects.Add([PSCustomObject][ordered]@{DatabaseFileLogicalName=$logical;SourcePath=$item.FullName;RelativePath=$relativePath;Bytes=[long]$item.Length;Sha256=(Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant()})
        }
    }
    [PSCustomObject]@{DatabaseFiles=@($databaseFiles);Objects=@($objects)}
}

function Assert-LabDatabasePackageSourceEvidence {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$SourceEvidence,[Parameter(Mandatory)]$DatabaseMetadata)
    foreach($property in @('DatabaseState','DetachState','AccessMode','WriterCount','StateObservedAfterLock')){if(-not $SourceEvidence.PSObject.Properties[$property]){throw "DATABASE_PACKAGE_SOURCE_EVIDENCE_INCOMPLETE: $property"}}
    foreach($property in @('HasFileStream','FileStreamInventoryComplete','IsEncrypted','TdeKeyEvidenceVerified')){if(-not $DatabaseMetadata.PSObject.Properties[$property]){throw "DATABASE_PACKAGE_METADATA_INCOMPLETE: $property"}}
    if([string]$SourceEvidence.DatabaseState -notin @('OFFLINE','DETACHED')){throw 'DATABASE_PACKAGE_SOURCE_NOT_OFFLINE'}
    if([string]$SourceEvidence.DetachState -notin @('CLEAN_OFFLINE','CLEAN_DETACHED')){throw 'DATABASE_PACKAGE_CLEAN_DETACH_UNVERIFIED'}
    if([string]$SourceEvidence.AccessMode -ne 'EXCLUSIVE' -or [int]$SourceEvidence.WriterCount -ne 0){throw 'DATABASE_PACKAGE_SOURCE_NOT_EXCLUSIVE'}
    if(-not [bool]$SourceEvidence.StateObservedAfterLock){throw 'DATABASE_PACKAGE_POST_LOCK_STATE_UNVERIFIED'}
    if([bool]$DatabaseMetadata.IsEncrypted -and -not [bool]$DatabaseMetadata.TdeKeyEvidenceVerified){throw 'DATABASE_PACKAGE_TDE_KEY_EVIDENCE_REQUIRED'}
    if([bool]$DatabaseMetadata.HasFileStream -and -not [bool]$DatabaseMetadata.FileStreamInventoryComplete){throw 'DATABASE_PACKAGE_FILESTREAM_INVENTORY_INCOMPLETE'}
}

function New-LabDatabasePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [Parameter(Mandatory)][ValidateSet('docker','podman','hyperv','external')][string]$Provider,
        [Parameter(Mandatory)][string]$SqlMajorVersion,
        [string]$RunId,[string]$InstanceId,
        [Parameter(Mandatory)]$SourceEvidence,
        [Parameter(Mandatory)]$DatabaseMetadata,
        [Parameter(Mandatory)][object[]]$FileInventory,
        [Parameter(Mandatory)][string]$DataRoot,
        [string[]]$ExternalDependencies=@()
    )

    Assert-LabDatabasePackageSourceEvidence -SourceEvidence $SourceEvidence -DatabaseMetadata $DatabaseMetadata
    $source=Get-LabDatabasePackageSourceObjects -FileInventory $FileInventory
    $fileStreamEntries=@($source.DatabaseFiles|Where-Object Type -eq 'FILESTREAM')
    if(([bool]$DatabaseMetadata.HasFileStream) -ne ($fileStreamEntries.Count -gt 0)){throw 'DATABASE_PACKAGE_FILESTREAM_METADATA_MISMATCH'}
    $packageId=[Guid]::NewGuid().ToString('D');$now=Get-LabTimestamp
    $record=[PSCustomObject][ordered]@{
        DatabasePackageId=$packageId;Status='REUSABLE';DatabaseName=$DatabaseName
        Source=[PSCustomObject][ordered]@{Provider=$Provider;RunId=if($RunId){$RunId}else{$null};InstanceId=if($InstanceId){$InstanceId}else{$null};SqlMajorVersion=$SqlMajorVersion}
        DatabaseMetadata=[PSCustomObject][ordered]@{
            StateAtCapture=[string]$SourceEvidence.DatabaseState;HasFileStream=[bool]$DatabaseMetadata.HasFileStream
            FileStreamInventoryComplete=[bool]$DatabaseMetadata.FileStreamInventoryComplete;IsEncrypted=[bool]$DatabaseMetadata.IsEncrypted
            TdeKeyEvidenceVerified=[bool]$DatabaseMetadata.TdeKeyEvidenceVerified;ExternalDependencies=@($ExternalDependencies|Sort-Object -Unique)
        }
        DatabaseFiles=@($source.DatabaseFiles);Objects=@($source.Objects|ForEach-Object{[PSCustomObject][ordered]@{DatabaseFileLogicalName=$_.DatabaseFileLogicalName;RelativePath=$_.RelativePath;Bytes=$_.Bytes;Sha256=$_.Sha256}})
        ManifestSha256='0'*64;CaptureEvidence=[PSCustomObject][ordered]@{AccessMode='EXCLUSIVE';WriterCount=0;StateObservedAfterLock=$true;SourceReleased=$false}
        CreatedAt=$now;UpdatedAt=$now
    }
    $record.ManifestSha256=Get-LabDatabasePackageManifestSha256 -Package $record
    $paths=Get-LabDatabasePackagePaths -DataRoot $DataRoot
    return Invoke-LabDatabasePackageLock -LibraryRoot $paths.LibraryRoot -ScriptBlock {
        foreach($directory in @($paths.LibraryRoot,$paths.ObjectsRoot,$paths.OperationsRoot)){if(-not(Test-Path -LiteralPath $directory -PathType Container)){New-Item -ItemType Directory -Path $directory -Force|Out-Null}}
        $operationRoot=Join-Path $paths.OperationsRoot $packageId;$staging=Join-Path $operationRoot 'staging';$journalPath=Join-Path $operationRoot 'database-package-journal.json'
        New-Item -ItemType Directory -Path $staging -Force|Out-Null
        $journal=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.DatabasePackageJournal/1.0';DatabasePackageId=$packageId;Status='COPYING';SourceState=[string]$SourceEvidence.DatabaseState;SourceReleased=$false;PublishedPath=$null;Recovery='RETRY_EXPORT_FROM_CLEAN_OFFLINE_SOURCE';UpdatedAt=$now}
        Write-LabDatabasePackageJournal -Journal $journal -Path $journalPath
        try {
            foreach($object in @($source.Objects)){
                $target=Join-Path $staging ([string]$object.RelativePath);$parent=Split-Path -Parent $target
                if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
                Copy-Item -LiteralPath ([string]$object.SourcePath) -Destination $target
                $item=Get-Item -LiteralPath $target
                if([long]$item.Length -ne [long]$object.Bytes -or (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$object.Sha256){throw 'DATABASE_PACKAGE_COPY_VERIFICATION_FAILED'}
            }
            Write-LabArtifactJsonAtomic -Path (Join-Path $staging 'package.json') -InputObject $record
            $objectRoot=Join-Path $paths.ObjectsRoot ([string]$record.ManifestSha256)
            if(Test-Path -LiteralPath $objectRoot){throw 'DATABASE_PACKAGE_OBJECT_ALREADY_EXISTS'}
            [IO.Directory]::Move($staging,$objectRoot)
            $document=Get-LabDatabasePackageDocument -Paths $paths
            $document.Packages=@($document.Packages)+@($record);$document.Revision=[int]$document.Revision+1;$document.UpdatedAt=$now
            $null=Test-LabDatabasePackageDocument -Document $document
            Write-LabArtifactJsonAtomic -Path $paths.RegistryPath -InputObject $document
            $journal.Status='COMPLETED';$journal.PublishedPath=$objectRoot;$journal.Recovery='NOT_REQUIRED';$journal.UpdatedAt=Get-LabTimestamp
            Write-LabDatabasePackageJournal -Journal $journal -Path $journalPath
            [PSCustomObject]@{Status='REUSABLE';DatabasePackageId=$packageId;ManifestSha256=$record.ManifestSha256;Path=$objectRoot;RegistryPath=$paths.RegistryPath;JournalPath=$journalPath}
        } catch {
            $journal.Status='RECOVERY_REQUIRED';$journal.Recovery='PRESERVE_SOURCE_OFFLINE_AND_RETRY_OR_REMOVE_INCOMPLETE_STAGING';$journal.UpdatedAt=Get-LabTimestamp
            Write-LabDatabasePackageJournal -Journal $journal -Path $journalPath
            throw
        }
    }
}

function Get-LabDatabasePackage {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabasePackageId,[Parameter(Mandatory)][string]$DataRoot)
    $paths=Get-LabDatabasePackagePaths -DataRoot $DataRoot;$document=Get-LabDatabasePackageDocument -Paths $paths
    $matches=@($document.Packages|Where-Object DatabasePackageId -eq $DatabasePackageId)
    if($matches.Count -ne 1){throw 'DATABASE_PACKAGE_NOT_FOUND'}
    $record=$matches[0];$root=Join-Path $paths.ObjectsRoot ([string]$record.ManifestSha256)
    if(-not(Test-Path -LiteralPath $root -PathType Container)){throw 'DATABASE_PACKAGE_OBJECT_MISSING'}
    if((Get-LabDatabasePackageManifestSha256 -Package $record) -ne [string]$record.ManifestSha256){throw 'DATABASE_PACKAGE_MANIFEST_HASH_MISMATCH'}
    foreach($object in @($record.Objects)){
        $path=Join-Path $root ([string]$object.RelativePath)
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'DATABASE_PACKAGE_OBJECT_INCOMPLETE'}
        $item=Get-Item -LiteralPath $path
        if([long]$item.Length -ne [long]$object.Bytes -or (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$object.Sha256){throw 'DATABASE_PACKAGE_OBJECT_HASH_MISMATCH'}
    }
    [PSCustomObject]@{Record=$record;Path=$root;RegistryPath=$paths.RegistryPath}
}

function Get-LabDatabasePackageAttachPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package,[Parameter(Mandatory)]$TargetEvidence,[Parameter(Mandatory)][string]$TargetDirectory)
    $record=if($Package.PSObject.Properties['Record']){$Package.Record}else{$Package};$blockers=[Collections.Generic.List[string]]::new()
    if([int]$TargetEvidence.SqlMajorVersion -lt [int]$record.Source.SqlMajorVersion){$blockers.Add('TARGET_SQL_VERSION_OLDER_THAN_SOURCE')}
    if([bool]$record.DatabaseMetadata.HasFileStream -and -not [bool]$TargetEvidence.FileStreamEnabled){$blockers.Add('TARGET_FILESTREAM_CAPABILITY_MISSING')}
    if([bool]$record.DatabaseMetadata.IsEncrypted -and -not [bool]$TargetEvidence.TdeKeyAvailable){$blockers.Add('TARGET_TDE_KEY_MISSING')}
    if([bool]$TargetEvidence.DatabaseExists){$blockers.Add('TARGET_DATABASE_ALREADY_EXISTS')}
    if(-not [bool]$TargetEvidence.ExclusiveUseAvailable){$blockers.Add('TARGET_EXCLUSIVE_USE_UNVERIFIED')}
    if([int]$TargetEvidence.PackageWriterCount -ne 0){$blockers.Add('PACKAGE_PARALLEL_WRITER_OBSERVED')}
    if(Test-Path -LiteralPath $TargetDirectory){if(@(Get-ChildItem -LiteralPath $TargetDirectory -Force).Count -gt 0){$blockers.Add('TARGET_DIRECTORY_NOT_EMPTY')}}
    $plan=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.DatabasePackageAttachPlan/1.0';DatabasePackageId=[string]$record.DatabasePackageId
        Status=if($blockers.Count -eq 0){'READY'}else{'BLOCKED'};DatabaseName=[string]$record.DatabaseName;TargetDirectory=[IO.Path]::GetFullPath($TargetDirectory)
        Mode='COPY_THEN_ATTACH';SourceFilesReadOnly=$true;DirectPackageAttachAllowed=$false
        Steps=@('REVERIFY_PACKAGE','COPY_TO_OPERATION_OWNED_TARGET','VERIFY_TARGET_HASHES','ATTACH_EXCLUSIVE_COPY','VERIFY_DATABASE_ONLINE')
        Blockers=@($blockers|Sort-Object -Unique);Recovery='DETACH_TARGET_COPY_IF_ATTACHED_AND_PRESERVE_IMMUTABLE_PACKAGE'
    }
    try{$valid=$plan|ConvertTo-Json -Depth 40|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'database-package-attach-plan.schema.json') -ErrorAction Stop}catch{throw "DATABASE_PACKAGE_ATTACH_PLAN_SCHEMA_INVALID: $($_.Exception.Message)"}
    if(-not $valid){throw 'DATABASE_PACKAGE_ATTACH_PLAN_SCHEMA_INVALID'}
    return $plan
}

function Copy-LabDatabasePackageClone {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Package,[Parameter(Mandatory)][string]$TargetDirectory)
    $record=$Package.Record;$sourceRoot=[string]$Package.Path
    if(Test-Path -LiteralPath $TargetDirectory){if(@(Get-ChildItem -LiteralPath $TargetDirectory -Force).Count -gt 0){throw 'DATABASE_PACKAGE_CLONE_TARGET_NOT_EMPTY'}}else{New-Item -ItemType Directory -Path $TargetDirectory -Force|Out-Null}
    foreach($object in @($record.Objects)){
        $source=Join-Path $sourceRoot ([string]$object.RelativePath);$target=Join-Path $TargetDirectory ([string]$object.RelativePath);$parent=Split-Path -Parent $target
        if(-not(Test-Path -LiteralPath $parent -PathType Container)){New-Item -ItemType Directory -Path $parent -Force|Out-Null}
        Copy-Item -LiteralPath $source -Destination $target
        if((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash.ToLowerInvariant() -ne [string]$object.Sha256){throw 'DATABASE_PACKAGE_CLONE_HASH_MISMATCH'}
    }
    [PSCustomObject]@{Status='CLONED';DatabasePackageId=[string]$record.DatabasePackageId;TargetDirectory=[IO.Path]::GetFullPath($TargetDirectory);DirectPackageAttachAllowed=$false}
}

function Test-LabDatabasePackageAttachJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    try{$valid=$Journal|ConvertTo-Json -Depth 40|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'database-package-attach-journal.schema.json') -ErrorAction Stop}catch{throw "DATABASE_PACKAGE_ATTACH_JOURNAL_SCHEMA_INVALID: $($_.Exception.Message)"}
    if(-not $valid){throw 'DATABASE_PACKAGE_ATTACH_JOURNAL_SCHEMA_INVALID'}
    return $true
}

function Write-LabDatabasePackageAttachJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp;$null=Test-LabDatabasePackageAttachJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Invoke-LabDatabasePackageAttachPlan {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][scriptblock]$AttachAction,
        [Parameter(Mandatory)][scriptblock]$VerifyAction,
        [Parameter(Mandatory)][string]$OperationDirectory
    )
    if([string]$Plan.ContractVersion -ne 'SqlServerLab.DatabasePackageAttachPlan/1.0'){throw 'DATABASE_PACKAGE_ATTACH_PLAN_CONTRACT_INVALID'}
    if([string]$Plan.Status -ne 'READY'){throw "DATABASE_PACKAGE_ATTACH_PLAN_BLOCKED: $(@($Plan.Blockers)-join ',')"}
    if([string]$Plan.DatabasePackageId -ne [string]$Package.Record.DatabasePackageId){throw 'DATABASE_PACKAGE_ATTACH_ID_MISMATCH'}
    if([string]$Plan.Mode -ne 'COPY_THEN_ATTACH' -or [bool]$Plan.DirectPackageAttachAllowed){throw 'DATABASE_PACKAGE_DIRECT_ATTACH_FORBIDDEN'}
    if(-not $PSCmdlet.ShouldProcess([string]$Plan.TargetDirectory,"Clone and attach database package $($Plan.DatabasePackageId)")){return $null}
    if(-not(Test-Path -LiteralPath $OperationDirectory -PathType Container)){New-Item -ItemType Directory -Path $OperationDirectory -Force|Out-Null}
    $journalPath=Join-Path $OperationDirectory 'database-package-attach-journal.json'
    $journal=[PSCustomObject][ordered]@{
        ContractVersion='SqlServerLab.DatabasePackageAttachJournal/1.0';DatabasePackageId=[string]$Plan.DatabasePackageId
        Status='COPYING';TargetDirectory=[string]$Plan.TargetDirectory;TargetCopyVerified=$false;AttachInvoked=$false
        PostconditionVerified=$false;Recovery='REMOVE_UNATTACHED_TARGET_COPY';UpdatedAt=Get-LabTimestamp
    }
    Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
    try {
        $clone=Copy-LabDatabasePackageClone -Package $Package -TargetDirectory ([string]$Plan.TargetDirectory)
        $journal.TargetCopyVerified=$true;$journal.Status='ATTACHING';$journal.Recovery='REMOVE_UNATTACHED_TARGET_COPY'
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
        $databaseFiles=@($Package.Record.DatabaseFiles|ForEach-Object{
            $file=$_;$object=@($Package.Record.Objects|Where-Object DatabaseFileLogicalName -eq ([string]$file.LogicalName)|Select-Object -First 1)
            $relative=if([bool]$file.IsDirectory){[string]$file.RelativeRoot}else{[string]$object.RelativePath}
            [PSCustomObject]@{LogicalName=[string]$file.LogicalName;Type=[string]$file.Type;Path=[IO.Path]::GetFullPath((Join-Path ([string]$Plan.TargetDirectory) $relative))}
        })
        $null=& $AttachAction ([string]$Plan.DatabaseName) $databaseFiles
        $journal.AttachInvoked=$true;$journal.Status='VERIFYING';$journal.Recovery='DETACH_TARGET_COPY_AND_PRESERVE_PACKAGE'
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
        $post=& $VerifyAction ([string]$Plan.DatabaseName) $databaseFiles
        if([string]$post.DatabaseState -ne 'ONLINE' -or [int]$post.AttachmentCount -ne 1 -or -not [bool]$post.PathsMatch){throw 'DATABASE_PACKAGE_ATTACH_POSTCONDITION_FAILED'}
        $journal.PostconditionVerified=$true;$journal.Status='COMPLETED';$journal.Recovery='NOT_REQUIRED'
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
        [PSCustomObject]@{Status='ATTACHED';DatabasePackageId=[string]$Plan.DatabasePackageId;DatabaseName=[string]$Plan.DatabaseName;TargetDirectory=[string]$Plan.TargetDirectory;JournalPath=$journalPath;Clone=$clone}
    }
    catch {
        $journal.Status='RECOVERY_REQUIRED';$journal.Recovery=if($journal.AttachInvoked){'DETACH_TARGET_COPY_AND_PRESERVE_PACKAGE'}else{'REMOVE_UNATTACHED_TARGET_COPY'}
        Write-LabDatabasePackageAttachJournal -Journal $journal -Path $journalPath
        throw
    }
}

function Get-LabDatabasePackageSqlTargetEvidence {
    [CmdletBinding()]
    param(
        [string]$HostName='127.0.0.1',[Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$DatabaseName,
        [bool]$TdeKeyAvailable=$false
    )
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    try{
        $escaped=$DatabaseName.Replace("'","''")
        $output=@(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $plain -Database master -Query "SET NOCOUNT ON; SELECT CONCAT(CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion')),N'|',CONVERT(nvarchar(10),(SELECT value_in_use FROM sys.configurations WHERE name=N'filestream access level')),N'|',CASE WHEN DB_ID(N'$escaped') IS NULL THEN N'0' ELSE N'1' END);")
        $line=@($output|ForEach-Object{([string]$_).Trim()}|Where-Object{$_ -match '^\d+\|\d+\|[01]$'}|Select-Object -First 1)
        if($line.Count -ne 1){throw 'DATABASE_PACKAGE_SQL_TARGET_EVIDENCE_INVALID'}
        $parts=$line[0].Split('|')
        [PSCustomObject]@{SqlMajorVersion=[int]$parts[0];FileStreamEnabled=[int]$parts[1] -gt 0;TdeKeyAvailable=$TdeKeyAvailable;DatabaseExists=[int]$parts[2] -eq 1;ExclusiveUseAvailable=$true;PackageWriterCount=0}
    } finally {$plain=$null}
}

function Invoke-LabDatabasePackageSqlAttach {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)]$Package,
        [string]$HostName='127.0.0.1',[Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$TargetDirectory,
        [Parameter(Mandatory)][string]$OperationDirectory,
        [bool]$TdeKeyAvailable=$false
    )
    $databaseName=[string]$Package.Record.DatabaseName
    $evidence=Get-LabDatabasePackageSqlTargetEvidence -HostName $HostName -Port $Port -SaPassword $SaPassword -DatabaseName $databaseName -TdeKeyAvailable $TdeKeyAvailable
    $plan=Get-LabDatabasePackageAttachPlan -Package $Package -TargetEvidence $evidence -TargetDirectory $TargetDirectory
    if([string]$plan.Status -ne 'READY'){throw "DATABASE_PACKAGE_ATTACH_PLAN_BLOCKED: $(@($plan.Blockers)-join ',')"}
    if(-not $PSCmdlet.ShouldProcess("${HostName}:$Port/$databaseName",'Copy immutable package and attach exclusive database files')){return $plan}
    $bstr=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try{$plain=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)}finally{[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)}
    try{
        $result=Invoke-LabDatabasePackageAttachPlan -Plan $plan -Package $Package -OperationDirectory $OperationDirectory -Confirm:$false -AttachAction {
            param($Name,$Files)
            $escapedName=$Name.Replace(']',']]');$clauses=@($Files|ForEach-Object{"(FILENAME = N'$(([string]$_.Path).Replace("'","''"))')"}) -join ",`n"
            $null=Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $plain -Database master -TimeoutSeconds 600 -Query "CREATE DATABASE [$escapedName] ON $clauses FOR ATTACH; ALTER DATABASE [$escapedName] SET MULTI_USER;"
        }.GetNewClosure() -VerifyAction {
            param($Name,$Files)
            $escapedLiteral=$Name.Replace("'","''");$expected=@($Files.Path|ForEach-Object{[IO.Path]::GetFullPath([string]$_)}|Sort-Object)
            $output=@(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $plain -Database master -Query "SET NOCOUNT ON; SELECT CONCAT(d.state_desc,N'|',CONVERT(nvarchar(10),COUNT_BIG(mf.file_id))) FROM sys.databases d JOIN sys.master_files mf ON mf.database_id=d.database_id WHERE d.name=N'$escapedLiteral' GROUP BY d.state_desc;")
            $line=@($output|ForEach-Object{([string]$_).Trim()}|Where-Object{$_ -match '^ONLINE\|\d+$'}|Select-Object -First 1)
            $pathsOutput=@(Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $plain -Database master -Query "SET NOCOUNT ON; SELECT physical_name FROM sys.master_files WHERE database_id=DB_ID(N'$escapedLiteral') ORDER BY file_id;"|ForEach-Object{([string]$_).Trim()}|Where-Object{$_ -match '^[A-Za-z]:[\\/]' -or $_ -match '^/'})
            $actual=@($pathsOutput|ForEach-Object{[IO.Path]::GetFullPath([string]$_)}|Sort-Object)
            [PSCustomObject]@{DatabaseState=if($line.Count -eq 1){'ONLINE'}else{'UNKNOWN'};AttachmentCount=if($line.Count -eq 1){1}else{0};PathsMatch=(Compare-Object $expected $actual).Count -eq 0}
        }.GetNewClosure()
        return $result
    } finally {$plain=$null}
}
