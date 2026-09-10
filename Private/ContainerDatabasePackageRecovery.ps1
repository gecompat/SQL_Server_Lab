function Assert-LabContainerPackageExportPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory,[Parameter(Mandatory)][string]$Path)
    $run=[IO.Path]::GetFullPath($RunDirectory).TrimEnd('\','/')
    $root=Join-Path $run 'database-package-export'
    $resolved=[IO.Path]::GetFullPath($Path)
    if(-not $resolved.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'CONTAINER_DATABASE_PACKAGE_STAGE_SCOPE_INVALID'}
    $cursor=$resolved
    while($cursor.Length -ge $run.Length){
        if(Test-Path -LiteralPath $cursor){
            if((Get-Item -LiteralPath $cursor -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_REPARSE_POINT'}
        }
        if($cursor -eq $run){break}
        $cursor=[IO.Path]::GetDirectoryName($cursor)
    }
}

function Remove-LabContainerPackageExportPayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$RunDirectory,[Parameter(Mandatory)][string]$Path)
    Assert-LabContainerPackageExportPath -RunDirectory $RunDirectory -Path $Path
    $resolved=[IO.Path]::GetFullPath($Path)
    if([IO.Path]::GetFileName($resolved) -ne 'payload' -or [IO.Path]::GetFileName([IO.Path]::GetDirectoryName($resolved)) -notmatch '^[0-9a-f]{32}$'){throw 'CONTAINER_DATABASE_PACKAGE_STAGE_SCOPE_INVALID'}
    if(Test-Path -LiteralPath $resolved){
        if(@(Get-ChildItem -LiteralPath $resolved -Recurse -Force | Where-Object {$_.Attributes -band [IO.FileAttributes]::ReparsePoint}).Count){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_REPARSE_POINT'}
        Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
    }
}

function Get-LabContainerPackageIdentitySql {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabaseName)
    $literal=$DatabaseName.Replace("'","''")
    # SQL Server blendet database_guid offline aus. Datei-GUIDs und Katalogbindung
    # bleiben beobachtbar; ihre Fingerprints schuetzen auch den mutierenden Batch.
    @"
IF DB_ID(N'$literal') IS NULL OR DB_ID(N'$literal') <= 4 THROW 51000, 'CONTAINER_DATABASE_PACKAGE_USER_DATABASE_REQUIRED', 1;
IF NOT EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(N'$literal')) OR EXISTS(SELECT 1 FROM sys.master_files WHERE database_id=DB_ID(N'$literal') AND file_guid IS NULL) THROW 51000, 'CONTAINER_DATABASE_PACKAGE_SOURCE_IDENTITY_INVALID', 1;
DECLARE @packageIdentity TABLE(FileId int, Fingerprint varchar(64));
INSERT @packageIdentity SELECT mf.file_id, LOWER(CONVERT(varchar(64),HASHBYTES('SHA2_256',CONCAT(CONVERT(nvarchar(10),d.database_id),N'|',CONVERT(nvarchar(33),d.create_date,126),N'|',CONVERT(nvarchar(10),mf.file_id),N'|',CONVERT(nvarchar(36),mf.file_guid),N'|',CONVERT(nvarchar(10),mf.type),N'|',mf.physical_name)),2))
FROM sys.databases d JOIN sys.master_files mf ON mf.database_id=d.database_id WHERE d.name=N'$literal';
"@
}

function Get-LabContainerPackageSourceGuardSql {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$DatabaseName,[AllowNull()][string]$DatabaseGuid,[Parameter(Mandatory)][object[]]$FileIdentity)
    $literal=$DatabaseName.Replace("'","''")
    $values=@(foreach($file in $FileIdentity){
        if([int]$file.FileId -lt 1 -or [string]$file.Fingerprint -cnotmatch '^[a-f0-9]{64}$'){throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_IDENTITY_INVALID'}
        "($([int]$file.FileId),'$($file.Fingerprint)')"
    }) -join ','
    $query=Get-LabContainerPackageIdentitySql -DatabaseName $DatabaseName
    $query+=" IF (SELECT COUNT(*) FROM @packageIdentity) <> $($FileIdentity.Count) OR EXISTS(SELECT FileId,Fingerprint FROM @packageIdentity EXCEPT SELECT FileId,Fingerprint FROM (VALUES $values) AS expected(FileId,Fingerprint)) THROW 51000, 'CONTAINER_DATABASE_PACKAGE_RECOVERY_DATABASE_CHANGED', 1; "
    if($DatabaseGuid){
        $guid=[guid]$DatabaseGuid
        $query+=" IF EXISTS(SELECT 1 FROM sys.database_recovery_status WHERE database_id=DB_ID(N'$literal') AND database_guid IS NOT NULL AND database_guid <> CONVERT(uniqueidentifier,N'$guid')) THROW 51000, 'CONTAINER_DATABASE_PACKAGE_RECOVERY_DATABASE_CHANGED', 1; "
    }
    $query
}

function Get-LabContainerPackageIdentitySignature {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$FileIdentity)
    (@($FileIdentity | Sort-Object FileId | ForEach-Object {"$($_.FileId)|$($_.Fingerprint)"}) -join "`n")
}

function Get-LabContainerPackageDatabaseState {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)][string]$DatabaseName,[Parameter(Mandatory)][string]$SaPlain)
    $literal=$DatabaseName.Replace("'","''")
    $query=@"
SET NOCOUNT ON;
$(Get-LabContainerPackageIdentitySql -DatabaseName $DatabaseName)
SELECT CONCAT(N'PKG_STATE|', CONVERT(nvarchar(36),r.database_guid), N'|',d.state_desc,N'|',d.user_access_desc)
FROM sys.databases d LEFT JOIN sys.database_recovery_status r ON r.database_id=d.database_id WHERE d.name=N'$literal';
SELECT CONCAT(N'PKG_CATALOG|',FileId,N'|',Fingerprint) FROM @packageIdentity ORDER BY FileId;
"@
    $hostName=if($Context.Instance.host){[string]$Context.Instance.host}else{'127.0.0.1'}
    $output=@(Invoke-SqlQuery -HostName $hostName -Port ([int]$Context.CurrentPort) -SaPlain $SaPlain -Database master -TimeoutSeconds 120 -Query $query | ForEach-Object {([string]$_).Trim()})
    $rows=@($output | Where-Object {$_ -like 'PKG_STATE|*'})
    if($rows.Count -ne 1 -or $rows[0] -notmatch '^PKG_STATE\|([0-9a-fA-F-]{36})?\|(ONLINE|OFFLINE)\|(MULTI_USER|SINGLE_USER|RESTRICTED_USER)$'){throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_STATE_INVALID'}
    $guidText=$Matches[1];$state=$Matches[2];$access=$Matches[3]
    $guid=[guid]::Empty
    if(($guidText -and (-not [guid]::TryParse($guidText,[ref]$guid) -or $guid -eq [guid]::Empty)) -or ($state -eq 'ONLINE' -and -not $guidText)){throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_IDENTITY_INVALID'}
    $files=@(foreach($row in $output | Where-Object {$_ -like 'PKG_CATALOG|*'}){
        if($row -cnotmatch '^PKG_CATALOG\|([1-9][0-9]{0,4})\|([a-f0-9]{64})$'){throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_IDENTITY_INVALID'}
        [pscustomobject]@{FileId=[int]$Matches[1];Fingerprint=$Matches[2]}
    })
    if(-not $files.Count -or @($files | Select-Object -ExpandProperty FileId -Unique).Count -ne $files.Count){throw 'CONTAINER_DATABASE_PACKAGE_SOURCE_IDENTITY_INVALID'}
    [pscustomobject]@{DatabaseGuid=$(if($guidText){$guid.ToString('D')}else{$null});FileIdentity=$files;State=$state;Access=$access}
}

function Assert-LabContainerPackageExportJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal)
    try{$valid=$Journal | ConvertTo-Json -Depth 12 | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'container-database-package-export-journal.schema.json') -ErrorAction Stop}
    catch{throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_JOURNAL_INVALID'}
    if(-not $valid){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_JOURNAL_INVALID'}
    if(@($Journal.FileIdentity | Select-Object -ExpandProperty FileId -Unique).Count -ne $Journal.FileIdentity.Count){throw 'CONTAINER_DATABASE_PACKAGE_EXPORT_JOURNAL_INVALID'}
}

function Write-LabContainerPackageExportJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp
    Assert-LabContainerPackageExportJournal -Journal $Journal
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Get-LabContainerPackagePublishedResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$DataRoot)
    $package=Get-LabDatabasePackage -DatabasePackageId $Journal.PublishedResult.DatabasePackageId -DataRoot $DataRoot
    if($package.Record.DatabaseName -cne $Journal.DatabaseName -or $package.Record.Source.RunId -ne $Journal.RunId -or
        $package.Record.Source.InstanceId -ne $Journal.InstanceId -or $package.Record.Source.Provider -ne $Journal.Provider){throw 'CONTAINER_DATABASE_PACKAGE_PUBLISHED_BINDING_CHANGED'}
    $binding=Register-LabDatabasePackagePersistentStorage -PackageRecord $package.Record -DataRoot $DataRoot -Preview
    if($binding.Changed -or -not $binding.Store -or $binding.Store.PersistentStorageId -ne $Journal.PublishedResult.PersistentStorageId){throw 'CONTAINER_DATABASE_PACKAGE_PUBLISHED_BINDING_CHANGED'}
    $Journal.PublishedResult
}

function Restore-LabContainerPackageExportSource {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Context,[Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$SaPlain)
    Assert-LabContainerPackageExportJournal -Journal $Journal
    $fresh=Get-LabContainerReconcileContext -RunId $Context.RunId -InstanceId $Context.InstanceId -StateRoot $Context.StateRoot
    if(-not $fresh.WasRunning -or [string]$fresh.ContainerId -ne [string]$Journal.ContainerId -or
        [string]$fresh.Provider -ne [string]$Journal.Provider -or [string]$fresh.RunId -ne [string]$Journal.RunId -or
        [string]$fresh.Run.scopeId -ne [string]$Journal.ScopeId -or [string]$fresh.InstanceId -ne [string]$Journal.InstanceId){throw 'CONTAINER_DATABASE_PACKAGE_RECOVERY_BINDING_CHANGED'}
    $current=Get-LabContainerPackageDatabaseState -Context $fresh -DatabaseName $Journal.DatabaseName -SaPlain $SaPlain
    if(($Journal.DatabaseGuid -and $current.DatabaseGuid -and $current.DatabaseGuid -ne $Journal.DatabaseGuid) -or
        (Get-LabContainerPackageIdentitySignature $current.FileIdentity) -cne (Get-LabContainerPackageIdentitySignature $Journal.FileIdentity)){throw 'CONTAINER_DATABASE_PACKAGE_RECOVERY_DATABASE_CHANGED'}
    $identifier=([string]$Journal.DatabaseName).Replace(']',']]')
    $statements=[Collections.Generic.List[string]]::new()
    if($current.State -ne $Journal.OriginalState){$statements.Add("ALTER DATABASE [$identifier] SET $($Journal.OriginalState);")}
    if($current.Access -ne $Journal.OriginalAccess){$statements.Add("ALTER DATABASE [$identifier] SET $($Journal.OriginalAccess);")}
    if($statements.Count){
        $hostName=if($fresh.Instance.host){[string]$fresh.Instance.host}else{'127.0.0.1'}
        $guard=Get-LabContainerPackageSourceGuardSql -DatabaseName $Journal.DatabaseName -DatabaseGuid $Journal.DatabaseGuid -FileIdentity $Journal.FileIdentity
        $null=Invoke-SqlQuery -HostName $hostName -Port ([int]$fresh.CurrentPort) -SaPlain $SaPlain -Database master -TimeoutSeconds 120 -Query ($guard+($statements -join ' '))
    }
    $observed=Get-LabContainerPackageDatabaseState -Context $fresh -DatabaseName $Journal.DatabaseName -SaPlain $SaPlain
    if(($Journal.DatabaseGuid -and $observed.DatabaseGuid -and $observed.DatabaseGuid -ne $Journal.DatabaseGuid) -or
        (Get-LabContainerPackageIdentitySignature $observed.FileIdentity) -cne (Get-LabContainerPackageIdentitySignature $Journal.FileIdentity) -or
        $observed.State -ne $Journal.OriginalState -or $observed.Access -ne $Journal.OriginalAccess){throw 'CONTAINER_DATABASE_PACKAGE_RECOVERY_POSTCONDITION_FAILED'}
}
