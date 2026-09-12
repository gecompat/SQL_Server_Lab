<#
.SYNOPSIS
    Prueft explizit ausgewaehlte Backupsets im bereits gebundenen SQL-Backup-Mount vor.
.DESCRIPTION
    Dieser Vertrag ist kein Transferexecutor. Er akzeptiert nur explizite DatabaseTransfers,
    veraendert keinen Container und verwendet ausschliesslich einen bereits live nachgewiesenen
    persistent-backups Bind-Mount. Jede Mutation ist operationseigen journalisiert.
#>

function Get-LabPortableContainerTransferPreflightSelectionDigest {
    [CmdletBinding()]param([Parameter(Mandatory)][object[]]$DatabaseTransfers)
    $normalized=@($DatabaseTransfers|ForEach-Object{[PSCustomObject][ordered]@{SourceDatabaseName=[string]$_.SourceDatabaseName;TargetDatabaseName=[string]$_.TargetDatabaseName;BackupSetId=([string]$_.BackupSetId).ToLowerInvariant()}}|Sort-Object SourceDatabaseName,TargetDatabaseName,BackupSetId)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($normalized|ConvertTo-Json -Depth 5 -Compress))
    try{return ([Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes))).ToLowerInvariant()}finally{[Array]::Clear($bytes,0,$bytes.Length)}
}

function New-LabPortableContainerTransferPreflightRequest {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$SourceRunId,[Parameter(Mandatory)][string]$SourceInstanceId,[Parameter(Mandatory)][string]$TargetRunId,[Parameter(Mandatory)][string]$TargetInstanceId,[Parameter(Mandatory)][object[]]$DatabaseTransfers)
    $seenTarget=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$seenSource=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$seenBackup=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$normalized=[Collections.Generic.List[object]]::new()
    foreach($entry in $DatabaseTransfers){
        $source=[string]$entry.SourceDatabaseName;$target=[string]$entry.TargetDatabaseName;$backup=([string]$entry.BackupSetId).ToLowerInvariant()
        if($source -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or $target -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$' -or $backup -notmatch '^[0-9a-f-]{36}$'){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_DATABASE_SELECTION_INVALID'}
        if(-not $seenTarget.Add($target)){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_TARGET_DATABASE_DUPLICATE'}
        if(-not $seenSource.Add($source)){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_SOURCE_DATABASE_DUPLICATE'}
        if(-not $seenBackup.Add($backup)){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_BACKUPSET_DUPLICATE'}
        $normalized.Add([PSCustomObject][ordered]@{SourceDatabaseName=$source;TargetDatabaseName=$target;BackupSetId=$backup})
    }
    if($normalized.Count -eq 0){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_DATABASE_SELECTION_REQUIRED'}
    $request=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferPreflightRequest/1.0';OperationId=[guid]::NewGuid().ToString('D');SourceRunId=$SourceRunId.ToLowerInvariant();SourceInstanceId=$SourceInstanceId;TargetRunId=$TargetRunId.ToLowerInvariant();TargetInstanceId=$TargetInstanceId;DatabaseTransfers=@($normalized|Sort-Object SourceDatabaseName,TargetDatabaseName,BackupSetId);SelectionDigest=(Get-LabPortableContainerTransferPreflightSelectionDigest -DatabaseTransfers @($normalized));CreatedAt=Get-LabTimestamp}
    $schema=Join-Path $script:SchemasPath 'portable-container-transfer-preflight-request.schema.json';if(-not($request|ConvertTo-Json -Depth 10|Test-Json -SchemaFile $schema -ErrorAction Stop)){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_REQUEST_INVALID'};return $request
}

function Assert-LabPortableContainerTransferPreflightNoReparsePath {
    [CmdletBinding()]param([Parameter(Mandatory)][string]$Root,[Parameter(Mandatory)][string]$Path)
    $rootFull=[IO.Path]::GetFullPath($Root).TrimEnd('\','/');$pathFull=[IO.Path]::GetFullPath($Path);$comparison=if($IsWindows){[StringComparison]::OrdinalIgnoreCase}else{[StringComparison]::Ordinal}
    if(-not $pathFull.StartsWith($rootFull+[IO.Path]::DirectorySeparatorChar,$comparison)){throw 'BACKUP_LIBRARY_OBJECT_PATH_OUTSIDE_ALLOWED_ROOT'}
    $cursor=$rootFull
    while($true){if(-not(Test-Path -LiteralPath $cursor)){throw 'BACKUP_LIBRARY_OBJECT_PATH_COMPONENT_MISSING'};$item=Get-Item -LiteralPath $cursor -Force -ErrorAction Stop;if($item.Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'BACKUP_LIBRARY_OBJECT_REPARSE_POINT_BLOCKED'};if($cursor -eq $pathFull){break};$relative=$pathFull.Substring($cursor.Length).TrimStart('\','/');$part=($relative -split '[\\/]')[0];$cursor=Join-Path $cursor $part}
}

function Get-LabPortableContainerTransferPreflightBackups {
    [CmdletBinding()]param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$DataRoot)
    $blockers=[Collections.Generic.List[string]]::new();$records=[Collections.Generic.List[object]]::new()
    try{$paths=Get-LabBackupLibraryPaths -DataRoot $DataRoot}catch{
        foreach($transfer in @($Request.DatabaseTransfers)){$records.Add([PSCustomObject]@{Public=[PSCustomObject][ordered]@{BackupSetId=[string]$transfer.BackupSetId;SourceDatabaseName=[string]$transfer.SourceDatabaseName;TargetDatabaseName=[string]$transfer.TargetDatabaseName;Sha256=$null;Bytes=0;HeaderOnly='NOT_EXECUTED';VerifyOnly='NOT_EXECUTED'};SourcePath=$null;StageFileName="$($transfer.BackupSetId).bak"})}
        return [PSCustomObject]@{Records=@($records);Blockers=@('BACKUP_LOCAL_OWNERSHIP_OR_INTEGRITY_UNVERIFIABLE')}
    }
    foreach($transfer in @($Request.DatabaseTransfers)){
        $view=[ordered]@{BackupSetId=[string]$transfer.BackupSetId;SourceDatabaseName=[string]$transfer.SourceDatabaseName;TargetDatabaseName=[string]$transfer.TargetDatabaseName;Sha256=$null;Bytes=0;HeaderOnly='NOT_EXECUTED';VerifyOnly='NOT_EXECUTED'}
        try{
            $backup=Get-LabDatabaseBackup -BackupSetId ([string]$transfer.BackupSetId) -DataRoot $DataRoot;$record=$backup.Record
            $expectedRelative=('Objects/'+([string]$record.Artifact.Sha256).ToLowerInvariant()+'.bak');if(([string]$record.Artifact.RelativePath).Replace('\','/') -cne $expectedRelative){throw 'BACKUP_LIBRARY_OBJECT_PATH_NOT_CANONICAL'}
            $expectedPath=Join-Path $paths.LibraryRoot $expectedRelative;if([IO.Path]::GetFullPath($backup.Path) -cne [IO.Path]::GetFullPath($expectedPath)){throw 'BACKUP_LIBRARY_OBJECT_PATH_NOT_ALLOWED'}
            Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $paths.LibraryRoot -Path $expectedPath;$item=Get-Item -LiteralPath $expectedPath -Force -ErrorAction Stop
            $expectedHash=[string]$record.Artifact.Sha256;$expectedBytes=[long]$record.Artifact.Bytes;$actualHash=(Get-LabProgressFileHash -LiteralPath $expectedPath -Algorithm SHA256).Hash.ToLowerInvariant();$view.Sha256=$expectedHash;$view.Bytes=$expectedBytes
            if($actualHash -ne $expectedHash -or $item.Length -ne $expectedBytes){$blockers.Add('BACKUP_SHA256_OR_SIZE_MISMATCH')}
            if(-not[bool]$record.Verification.BackupChecksum -or -not[bool]$record.Verification.RestoreVerifyOnly){$blockers.Add('BACKUP_CHECKSUM_OR_VERIFYONLY_EVIDENCE_MISSING')}
            if([string]$record.DatabaseName -cne [string]$transfer.SourceDatabaseName){$blockers.Add('BACKUP_DATABASE_NAME_MISMATCH')}
            if([string]$record.Source.RunId -cne [string]$Request.SourceRunId -or [string]$record.Source.InstanceId -cne [string]$Request.SourceInstanceId){$blockers.Add('BACKUP_SOURCE_BINDING_MISMATCH')}
            if([string]$record.Source.SqlMajorVersion -ne '17' -or [bool]$record.DatabaseMetadata.HasFileStream -or [bool]$record.DatabaseMetadata.IsEncrypted){$blockers.Add('BACKUP_SCOPE_UNSUPPORTED')}
            $records.Add([PSCustomObject]@{Public=[PSCustomObject]$view;SourcePath=$expectedPath;StageFileName="$($transfer.BackupSetId).bak"})
        }catch{$blockers.Add('BACKUP_LOCAL_OWNERSHIP_OR_INTEGRITY_UNVERIFIABLE')}
    }
    [PSCustomObject]@{Records=@($records);Blockers=@($blockers|Sort-Object -Unique)}
}

function Get-LabPortableContainerTransferPreflightTargetBinding {
    [CmdletBinding()]param([Parameter(Mandatory)]$Request,[string]$StateRoot)
    $public=[ordered]@{Provider=$null;RunId=[string]$Request.TargetRunId;InstanceId=[string]$Request.TargetInstanceId;RuntimeScopeId=$null;BindingStatus='UNAVAILABLE'}
    try {
        $run=Get-LabRunState -RunId ([string]$Request.TargetRunId) -StateRoot $StateRoot
        $target=Resolve-LabRunInstance -RunId ([string]$Request.TargetRunId) -InstanceId ([string]$Request.TargetInstanceId) -StateRoot $StateRoot
        if([string]$run.state -ne 'RUNNING' -or [string]$target.Provider -notin @('docker','podman')){throw 'binding'}
        $public.Provider=[string]$target.Provider
        $scope=Get-LabContainerRuntimeScope -Provider ([string]$target.Provider)
        if([string]$scope.Status -ne 'AVAILABLE' -or [string]::IsNullOrWhiteSpace([string]$scope.RuntimeId)){throw 'binding'}
        $public.RuntimeScopeId=[string]$scope.RuntimeId
        $runtime=Get-LabHostToolInvocation -Name ([string]$target.Provider)
        $inspection=@(& $runtime inspect ([string]$target.ContainerName) 2>$null)
        if($LASTEXITCODE -ne 0 -or $inspection.Count -eq 0){throw 'binding'}
        $container=($inspection -join "`n")|ConvertFrom-Json -Depth 30
        if($container -is [array]){if($container.Count -ne 1){throw 'binding'};$container=$container[0]}
        $containerId=[string]$container.Id
        if($container.State.Running -ne $true -or $containerId -notmatch '^[0-9a-fA-F]{64}$'){throw 'binding'}
        $labels=$container.Config.Labels
        if([string]$labels.'sql-server-lab.run-id' -cne [string]$Request.TargetRunId -or [string]$labels.'sql-server-lab.scope-id' -cne [string]$run.scopeId -or [string]$labels.'sql-server-lab.instance-id' -cne [string]$Request.TargetInstanceId){throw 'binding'}
        $mount=@($container.Mounts|Where-Object{$_ -and [string]$_.Type -eq 'bind' -and [string]$_.Destination -eq '/var/opt/mssql/backup' -and $_.RW -eq $true})
        if($mount.Count -ne 1 -or [string]::IsNullOrWhiteSpace([string]$mount[0].Source)){throw 'binding'}
        $hostRoot=(Resolve-Path -LiteralPath ([string]$mount[0].Source) -ErrorAction Stop).Path
        Assert-LabPortableContainerTransferPreflightNoReparsePath -Root (Split-Path -Parent $hostRoot) -Path $hostRoot
        if([string]::IsNullOrWhiteSpace([string]$target.HostName) -or [int]$target.Port -lt 1){throw 'binding'}
        $ports=@($container.NetworkSettings.Ports.'1433/tcp')
        if($ports.Count -ne 1 -or [int]$ports[0].HostPort -ne [int]$target.Port -or [string]$ports[0].HostIp -notin @('127.0.0.1','::1')){throw 'binding'}
        $public.BindingStatus='VERIFIED'
        return [PSCustomObject]@{Available=$true;Code=$null;Public=[PSCustomObject]$public;HostRoot=$hostRoot;HostName=[string]$target.HostName;Port=[int]$target.Port;ContainerId=$containerId.ToLowerInvariant()}
    }catch{return [PSCustomObject]@{Available=$false;Code='SQL_VISIBLE_STAGING_BINDING_UNAVAILABLE';Public=[PSCustomObject]$public}}
}
function Write-LabPortableContainerTransferPreflightJournal {
    [CmdletBinding()]param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp;$schema=Join-Path $script:SchemasPath 'portable-container-transfer-preflight-journal.schema.json';if(-not($Journal|ConvertTo-Json -Depth 20|Test-Json -SchemaFile $schema -ErrorAction Stop)){throw 'PORTABLE_CONTAINER_TRANSFER_PREFLIGHT_JOURNAL_INVALID'};Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function New-LabPortableContainerTransferPreflightSqlConnection {
    [CmdletBinding()]param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][SecureString]$Secret)
    if(-not $Secret.IsReadOnly()){$Secret.MakeReadOnly()};$credential=[System.Data.SqlClient.SqlCredential]::new('sa',$Secret);$builder=[System.Data.SqlClient.SqlConnectionStringBuilder]::new();$builder.DataSource=[string]::Concat([string]$Binding.HostName,',',[string]$Binding.Port);$builder.InitialCatalog='master';$builder.Encrypt=$true;$builder.TrustServerCertificate=$true;$builder.ConnectTimeout=15;$builder.ApplicationName='SqlServerLab.PortableContainerTransferPreflight';$builder.Pooling=$false;$builder.PersistSecurityInfo=$false;$connection=[System.Data.SqlClient.SqlConnection]::new();$connection.ConnectionString=$builder.ConnectionString;$connection.Credential=$credential;return $connection
}
function Test-LabPortableContainerTransferPreflightSqlConnection {[CmdletBinding()]param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][SecureString]$Secret)$connection=New-LabPortableContainerTransferPreflightSqlConnection -Binding $Binding -Secret $Secret;try{$connection.Open()}finally{$connection.Dispose()}}

function Test-LabPortableContainerTransferPreflightHeaderObservation {
    [CmdletBinding()]param([Parameter(Mandatory)]$Header,[Parameter(Mandatory)][string]$ExpectedDatabaseName)
    foreach($name in @('Position','BackupType','SoftwareVersionMajor')){if($Header.$name -isnot [byte] -and $Header.$name -isnot [int16] -and $Header.$name -isnot [int32] -and $Header.$name -isnot [int64]){throw 'SQL_MEDIA_HEADERONLY_TYPE_OR_VERSION_INVALID'}}
    if([int]$Header.Position -ne 1 -or [int]$Header.BackupType -ne 1 -or [int]$Header.SoftwareVersionMajor -ne 17){throw 'SQL_MEDIA_HEADERONLY_TYPE_OR_VERSION_INVALID'}
    if([string]$Header.DatabaseName -cne $ExpectedDatabaseName){throw 'SQL_MEDIA_HEADERONLY_DATABASE_NAME_MISMATCH'}
    foreach($name in @('DatabaseGuid','FamilyGUID')){if($Header.$name -isnot [guid] -or $Header.$name -eq [guid]::Empty){throw 'SQL_MEDIA_HEADERONLY_GUID_INVALID'}}
    foreach($name in @('HasBackupChecksums','IsDamaged','IsSnapshot')){if($Header.$name -isnot [bool]){throw 'SQL_MEDIA_HEADERONLY_UNKNOWN_VALUE'}}
    if($Header.HasBackupChecksums -ne $true -or $Header.IsDamaged -ne $false -or $Header.IsSnapshot -ne $false){throw 'SQL_MEDIA_HEADERONLY_SAFETY_FLAG_INVALID'}
    if([string]$Header.EncryptorType -cne 'NO_Encryption'){throw 'SQL_MEDIA_HEADERONLY_ENCRYPTION_UNKNOWN_OR_UNSUPPORTED'}
    $true
}
function Get-LabPortableContainerTransferPreflightHeaderObservation {[CmdletBinding()]param([Parameter(Mandatory)]$Reader)
    $required=@('Position','BackupType','DatabaseName','SoftwareVersionMajor','DatabaseGuid','FamilyGUID','HasBackupChecksums','IsDamaged','IsSnapshot','EncryptorType');$ordinals=@{}
    for($i=0;$i -lt $Reader.FieldCount;$i++){$name=[string]$Reader.GetName($i);if($required -contains $name){$ordinals[$name]=$i}}
    foreach($name in $required){if(-not $ordinals.ContainsKey($name)){throw 'SQL_MEDIA_HEADERONLY_REQUIRED_COLUMN_MISSING'}}
    if(-not $Reader.Read()){throw 'SQL_MEDIA_HEADERONLY_EMPTY'};$row=[ordered]@{};foreach($name in $required){$value=$Reader.GetValue([int]$ordinals[$name]);if($value -is [DBNull]){throw 'SQL_MEDIA_HEADERONLY_UNKNOWN_VALUE'};$row[$name]=$value};if($Reader.Read()){throw 'SQL_MEDIA_HEADERONLY_MULTIPLE_ROWS'};[PSCustomObject]$row
}
function Invoke-LabPortableContainerTransferPreflightSql {[CmdletBinding()]param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][SecureString]$Secret,[Parameter(Mandatory)][string]$SqlBackupPath,[Parameter(Mandatory)][string]$ExpectedDatabaseName)
    $connection=New-LabPortableContainerTransferPreflightSqlConnection -Binding $Binding -Secret $Secret
    try{$connection.Open();$header=$connection.CreateCommand();$header.CommandText='RESTORE HEADERONLY FROM DISK = @backupPath;';$header.CommandTimeout=120;$null=$header.Parameters.Add('@backupPath',[Data.SqlDbType]::NVarChar,4000);$header.Parameters['@backupPath'].Value=$SqlBackupPath
        try{$reader=$header.ExecuteReader();try{$observation=Get-LabPortableContainerTransferPreflightHeaderObservation -Reader $reader;$null=Test-LabPortableContainerTransferPreflightHeaderObservation -Header $observation -ExpectedDatabaseName $ExpectedDatabaseName}finally{$reader.Dispose()}}finally{$header.Dispose()}
        $verify=$connection.CreateCommand();$verify.CommandText='RESTORE VERIFYONLY FROM DISK = @backupPath WITH CHECKSUM, STOP_ON_ERROR;';$verify.CommandTimeout=120;$null=$verify.Parameters.Add('@backupPath',[Data.SqlDbType]::NVarChar,4000);$verify.Parameters['@backupPath'].Value=$SqlBackupPath;try{$null=$verify.ExecuteNonQuery()}finally{$verify.Dispose()}
    }finally{$connection.Dispose()}
}

function New-LabPortableContainerTransferPreflightResult {[CmdletBinding()]param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)]$Target,[Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Transfers,[Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Blockers,[Parameter(Mandatory)][string]$Status,[Parameter(Mandatory)][string]$CleanupStatus)[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferPreflightResult/1.0';OperationId=[string]$Request.OperationId;SelectionDigest=[string]$Request.SelectionDigest;Status=$Status;TransferExecutionImplemented=$false;TransferExecutorStatus='BLOCKED';Target=$Target;Transfers=$Transfers;Blockers=@($Blockers|Sort-Object -Unique);CleanupStatus=$CleanupStatus;CompletedAt=Get-LabTimestamp}}

function Invoke-LabPortableContainerTransferPreflightCleanup {[CmdletBinding()]param([Parameter(Mandatory)][string]$HostRoot,[Parameter(Mandatory)][string]$JournalPath,[Parameter(Mandatory)][string]$OperationDirectory,[Parameter(Mandatory)][object[]]$StageFiles)
    try{Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $HostRoot -Path $JournalPath;Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $HostRoot -Path $OperationDirectory;$expected=@($StageFiles|ForEach-Object{[IO.Path]::GetFileName([string]$_)});$children=@(Get-ChildItem -LiteralPath $OperationDirectory -Force -ErrorAction Stop);if(@($children|Where-Object{$_.Name -notin $expected -or $_.PSIsContainer -or ($_.Attributes -band [IO.FileAttributes]::ReparsePoint)}).Count){throw 'foreign'}
        foreach($stage in $StageFiles){Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $HostRoot -Path $stage;if(Test-Path -LiteralPath $stage){Remove-Item -LiteralPath $stage -Force -ErrorAction Stop;if(Test-Path -LiteralPath $stage){throw 'stage remains'}}}
        if(@(Get-ChildItem -LiteralPath $OperationDirectory -Force -ErrorAction Stop).Count){throw 'contents remain'};Remove-Item -LiteralPath $OperationDirectory -Force -ErrorAction Stop;if(Test-Path -LiteralPath $OperationDirectory){throw 'directory remains'}
        if(Test-Path -LiteralPath $JournalPath){Remove-Item -LiteralPath $JournalPath -Force -ErrorAction Stop;if(Test-Path -LiteralPath $JournalPath){throw 'journal remains'}};'CLEANED'
    }catch{'RECOVERY_REQUIRED'}
}

function Invoke-LabPortableContainerTransferPreflight {
    [CmdletBinding()]param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$DataRoot,[string]$StateRoot,[switch]$MutationAuthorized)
    $backupPreflight=Get-LabPortableContainerTransferPreflightBackups -Request $Request -DataRoot $DataRoot;$target=Get-LabPortableContainerTransferPreflightTargetBinding -Request $Request -StateRoot $StateRoot;$transfers=@($backupPreflight.Records|ForEach-Object{$_.Public});$blockers=[Collections.Generic.List[string]]::new();foreach($code in @($backupPreflight.Blockers)){[void]$blockers.Add($code)};if(-not $target.Available){[void]$blockers.Add([string]$target.Code)}
    if($blockers.Count -gt 0){return New-LabPortableContainerTransferPreflightResult -Request $Request -Target $target.Public -Transfers $transfers -Blockers @($blockers) -Status 'BLOCKED' -CleanupStatus 'NO_MUTATION_PERFORMED'}
    if(-not $MutationAuthorized){return New-LabPortableContainerTransferPreflightResult -Request $Request -Target $target.Public -Transfers $transfers -Blockers @('WHATIF_NO_MUTATION_PERFORMED') -Status 'BLOCKED' -CleanupStatus 'NO_MUTATION_PERFORMED'}
    $targetSecret=$null;try{$targetSecret=Get-LabRelationalCoreSecret -RunId ([string]$Request.TargetRunId) -StateRoot $StateRoot;Test-LabPortableContainerTransferPreflightSqlConnection -Binding $target -Secret $targetSecret}catch{[void]$blockers.Add('SQL_MEDIA_PREFLIGHT_MANAGED_SECRET_OR_CONNECTION_UNAVAILABLE')};if($blockers.Count){return New-LabPortableContainerTransferPreflightResult -Request $Request -Target $target.Public -Transfers $transfers -Blockers @($blockers) -Status 'BLOCKED' -CleanupStatus 'NO_MUTATION_PERFORMED'}
    $directoryLeaf="transfer-preflight-$($Request.OperationId)";$operationDirectory=Join-Path $target.HostRoot $directoryLeaf;$journalPath=Join-Path $target.HostRoot "$directoryLeaf.journal.json";$stageFiles=@($backupPreflight.Records|ForEach-Object{Join-Path $operationDirectory $_.StageFileName});$journal=[PSCustomObject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferPreflightJournal/1.0';OperationId=[string]$Request.OperationId;SelectionDigest=[string]$Request.SelectionDigest;Status='INTENT_PERSISTED';Intent='STAGE_AND_SQL_MEDIA_PRECHECK_ONLY';StageDirectoryRelativePath=$directoryLeaf;JournalRelativePath="$directoryLeaf.journal.json";Transfers=@($transfers|ForEach-Object{[PSCustomObject][ordered]@{BackupSetId=$_.BackupSetId;StageFileName="$($_.BackupSetId).bak";Status='PLANNED'}});UpdatedAt=Get-LabTimestamp};$cleanupStatus='NOT_STARTED';$runtimeFailure=$null
    try{if(Test-Path -LiteralPath $operationDirectory -or Test-Path -LiteralPath $journalPath){throw 'SQL_MEDIA_PREFLIGHT_OPERATION_COLLISION'};Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath;New-Item -ItemType Directory -Path $operationDirectory -ErrorAction Stop|Out-Null;$journal.Status='STAGING';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath
        for($i=0;$i -lt $backupPreflight.Records.Count;$i++){$record=$backupPreflight.Records[$i];$stage=$stageFiles[$i];Copy-Item -LiteralPath $record.SourcePath -Destination $stage -ErrorAction Stop;$item=Get-Item -LiteralPath $stage -Force -ErrorAction Stop;$hash=(Get-LabProgressFileHash -LiteralPath $stage -Algorithm SHA256).Hash.ToLowerInvariant();if($item.Length -ne [long]$record.Public.Bytes -or $hash -ne [string]$record.Public.Sha256){throw 'SQL_MEDIA_PREFLIGHT_STAGING_HASH_OR_SIZE_MISMATCH'};$journal.Transfers[$i].Status='STAGED';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath}
        $journal.Status='SQL_MEDIA_PRECHECK';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath;for($i=0;$i -lt $transfers.Count;$i++){$transfer=$transfers[$i];$sqlPath='/var/opt/mssql/backup/'+$directoryLeaf+'/'+$transfer.BackupSetId+'.bak';Invoke-LabPortableContainerTransferPreflightSql -Binding $target -Secret $targetSecret -SqlBackupPath $sqlPath -ExpectedDatabaseName $transfer.SourceDatabaseName;$transfer.HeaderOnly='PASSED';$transfer.VerifyOnly='PASSED';$journal.Transfers[$i].Status='SQL_MEDIA_PASSED';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath}
        $journal.Status='POST_SQL_REVALIDATING';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath;$fresh=Get-LabPortableContainerTransferPreflightTargetBinding -Request $Request -StateRoot $StateRoot;if(-not $fresh.Available -or $fresh.ContainerId -cne $target.ContainerId -or -not [string]::Equals([string]$fresh.HostRoot,[string]$target.HostRoot,[StringComparison]::OrdinalIgnoreCase) -or -not [string]::Equals([string]$fresh.HostName,[string]$target.HostName,[StringComparison]::OrdinalIgnoreCase) -or $fresh.Port -ne $target.Port){throw 'SQL_MEDIA_PREFLIGHT_TARGET_BINDING_DRIFT'};for($i=0;$i -lt $stageFiles.Count;$i++){$item=Get-Item -LiteralPath $stageFiles[$i] -Force -ErrorAction Stop;$hash=(Get-LabProgressFileHash -LiteralPath $stageFiles[$i] -Algorithm SHA256).Hash.ToLowerInvariant();if($item.Length -ne [long]$transfers[$i].Bytes -or $hash -ne [string]$transfers[$i].Sha256){throw 'SQL_MEDIA_PREFLIGHT_STAGE_FILE_DRIFT'}};$journal.Status='PRECHECKED';Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath
    }catch{$runtimeFailure=if($_.Exception.Message -match '^SQL_MEDIA_PREFLIGHT_TARGET_BINDING_DRIFT'){'SQL_MEDIA_PREFLIGHT_TARGET_BINDING_DRIFT'}else{'SQL_MEDIA_PREFLIGHT_FAILED'};$journal.Status='RECOVERY_REQUIRED';try{Write-LabPortableContainerTransferPreflightJournal -Journal $journal -Path $journalPath}catch{}}
    $cleanupStatus=Invoke-LabPortableContainerTransferPreflightCleanup -HostRoot $target.HostRoot -JournalPath $journalPath -OperationDirectory $operationDirectory -StageFiles $stageFiles;if($cleanupStatus -eq 'RECOVERY_REQUIRED'){$runtimeFailure='SQL_MEDIA_PREFLIGHT_CLEANUP_REQUIRED'};if($runtimeFailure){[void]$blockers.Add($runtimeFailure)};$status=if($cleanupStatus -eq 'RECOVERY_REQUIRED'){'RECOVERY_REQUIRED'}elseif($runtimeFailure){'BLOCKED'}else{'PRECHECKED'};New-LabPortableContainerTransferPreflightResult -Request $Request -Target $target.Public -Transfers $transfers -Blockers @($blockers) -Status $status -CleanupStatus $cleanupStatus
}
