<#
.SYNOPSIS
    Ein-DB-Transfer in einen ausschließlich operationseigenen SQL-2025-Container.
.DESCRIPTION
    Wiederaufnahme ist ausschließlich Cleanup. Ein begonnenes RESTORE wird nie
    wiederholt und eine vorhandene Zielinstanz wird niemals adoptiert.
#>
function Get-LabTransferHash {
    param([Parameter(Mandatory)]$Value)
    $bytes=[Text.Encoding]::UTF8.GetBytes(($Value|ConvertTo-Json -Depth 30 -Compress))
    try { [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally { [Array]::Clear($bytes,0,$bytes.Length) }
}

function Invoke-LabTransferNative {
    param([Parameter(Mandatory)][string]$Provider,[Parameter(Mandatory)][string[]]$Arguments,[int]$TimeoutSeconds=60)
    $result=Invoke-LabProgressNativeCommand -FilePath (Get-LabHostToolInvocation -Name $Provider) -ArgumentList $Arguments -Phase Transfer -TimeoutSeconds $TimeoutSeconds
    if($result.ExitCode -ne 0){throw 'TRANSFER_RUNTIME_COMMAND_FAILED'}
    return @($result.Output)
}

function Get-LabTransferBinding {
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot,[string]$OperationId)
    $run=Get-LabRunState -RunId $RunId -StateRoot $StateRoot
    $instance=Resolve-LabRunInstance -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
    $version=Get-SqlServerVersion -VersionId ([string]$instance.Version)
    if($run.state -ne 'RUNNING' -or $instance.Provider -notin @('docker','podman') -or -not $version -or [string]$version.id -cne '2025'){throw 'TRANSFER_RUN_NOT_ELIGIBLE'}
    $scope=Get-LabContainerRuntimeScope -Provider $instance.Provider
    if($scope.Status -ne 'AVAILABLE' -or -not $scope.RuntimeId){throw 'TRANSFER_RUNTIME_SCOPE_UNAVAILABLE'}
    $inspection=@((Invoke-LabTransferNative -Provider $instance.Provider -Arguments @('inspect',$instance.ContainerName)) -join "`n"|ConvertFrom-Json -Depth 30)
    if($inspection.Count -ne 1){throw 'TRANSFER_CONTAINER_AMBIGUOUS'}
    $container=$inspection[0];$labels=$container.Config.Labels
    if($container.State.Running -ne $true -or [string]$container.Id -notmatch '^[a-f0-9]{64}$' -or $container.Os -and $container.Os -ne 'linux' -or
        [string]$labels.'sql-server-lab.run-id' -cne $RunId -or [string]$labels.'sql-server-lab.scope-id' -cne [string]$run.scopeId -or
        [string]$labels.'sql-server-lab.instance-id' -cne $InstanceId){throw 'TRANSFER_CONTAINER_OWNERSHIP_INVALID'}
    $ports=@($container.NetworkSettings.Ports.'1433/tcp')
    if($ports.Count -ne 1 -or [int]$ports[0].HostPort -ne [int]$instance.Port -or $ports[0].HostIp -notin @('127.0.0.1','::1')){throw 'TRANSFER_ENDPOINT_BINDING_INVALID'}
    if([string]$instance.HostName -cnotin @('127.0.0.1','::1') -or [string]$instance.HostName -cne [string]$ports[0].HostIp){throw 'TRANSFER_ENDPOINT_BINDING_INVALID'}
    $volumes=@()
    if($OperationId){
        if([string]$run.metadata.workflowOperationId -cne $OperationId -or [bool]$run.metadata.persistentData){throw 'TRANSFER_OPERATION_OWNERSHIP_INVALID'}
        $mounts=@($container.Mounts)
        if($mounts.Count -ne 1 -or $mounts[0].Type -ne 'volume' -or $mounts[0].Destination -cne '/var/opt/mssql' -or $mounts[0].RW -ne $true){throw 'TRANSFER_VOLUME_BINDING_INVALID'}
        $volume=@((Invoke-LabTransferNative -Provider $instance.Provider -Arguments @('volume','inspect',[string]$mounts[0].Name)) -join "`n"|ConvertFrom-Json -Depth 30)
        if($volume.Count -ne 1){throw 'TRANSFER_VOLUME_BINDING_INVALID'}
        $vl=$volume[0].Labels
        if([string]$vl.'sql-server-lab.run-id' -cne $RunId -or [string]$vl.'sql-server-lab.scope-id' -cne [string]$run.scopeId -or
            [string]$vl.'sql-server-lab.instance-id' -cne $InstanceId -or $vl.'sql-server-lab.persistent-storage-id' -or $vl.'sql-server-lab.persistence'){throw 'TRANSFER_VOLUME_OWNERSHIP_INVALID'}
        $attachments=@(Invoke-LabTransferNative -Provider $instance.Provider -Arguments @('ps','-a','--no-trunc','--filter',"volume=$($mounts[0].Name)",'--format','{{.ID}}'))
        if($attachments.Count -ne 1 -or [string]$attachments[0] -cne [string]$container.Id){throw 'TRANSFER_VOLUME_SHARED'}
        $volumes=@([string]$mounts[0].Name)
    }
    [pscustomobject]@{RunId=$RunId;ScopeId=[string]$run.scopeId;InstanceId=$InstanceId;Provider=[string]$instance.Provider;RuntimeScopeId=[string]$scope.RuntimeId;ContainerId=[string]$container.Id;Volumes=$volumes;HostName=[string]$instance.HostName;Port=[int]$instance.Port}
}

function Get-LabTransferBindingIdentity {
    param([Parameter(Mandatory)]$Binding)
    [pscustomobject][ordered]@{RunId=$Binding.RunId;ScopeId=$Binding.ScopeId;InstanceId=$Binding.InstanceId;Provider=$Binding.Provider;RuntimeScopeId=$Binding.RuntimeScopeId;ContainerId=$Binding.ContainerId;Volumes=@($Binding.Volumes);EndpointHash=(Get-LabTransferHash ([ordered]@{HostName=$Binding.HostName;Port=$Binding.Port}))}
}

function Assert-LabTransferBinding {
    param([Parameter(Mandatory)]$Expected,[string]$StateRoot,[string]$OperationId)
    $actual=Get-LabTransferBinding -RunId $Expected.RunId -InstanceId $Expected.InstanceId -StateRoot $StateRoot -OperationId $OperationId
    if((Get-LabTransferHash (Get-LabTransferBindingIdentity $actual)) -cne (Get-LabTransferHash $Expected)){throw 'TRANSFER_LIVE_BINDING_DRIFT'}
    return $actual
}

function Invoke-LabTransferSqlRows {
    param([Parameter(Mandatory)]$Connection,[Parameter(Mandatory)][string]$Query,[hashtable]$Parameters=@{},[int]$TimeoutSeconds=120)
    $command=$Connection.CreateCommand();$command.CommandText=$Query;$command.CommandTimeout=$TimeoutSeconds
    foreach($key in $Parameters.Keys){$null=$command.Parameters.AddWithValue($key,$Parameters[$key])}
    $reader=$null;$rows=[Collections.Generic.List[object]]::new()
    try {$reader=$command.ExecuteReader();while($reader.Read()){$row=[ordered]@{};for($i=0;$i -lt $reader.FieldCount;$i++){$row[$reader.GetName($i)]=$reader.GetValue($i)};$rows.Add([pscustomobject]$row)}}
    finally {if($reader){$reader.Dispose()};$command.Dispose()}
    return @($rows)
}

function Get-LabTransferSourceObservation {
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][string]$DatabaseName,[string]$StateRoot)
    $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $StateRoot
    $connection=New-LabRelationalCoreConnection -Binding $Binding -DatabaseName $DatabaseName -Secret $secret
    try {
        $connection.Open();Assert-LabRelationalCoreDatabaseBinding -Connection $connection -RequestedDatabaseName $DatabaseName
        $rows=@(Invoke-LabTransferSqlRows -Connection $connection -Query @'
SELECT DB_ID() AS DatabaseId, CONVERT(nvarchar(36),r.database_guid) AS DatabaseGuid,
 CONVERT(nvarchar(33),d.create_date,126) AS CreatedAt
FROM sys.databases d JOIN sys.database_recovery_status r ON r.database_id=d.database_id
WHERE d.database_id=DB_ID() AND d.database_id>4 AND d.state=0 AND d.is_read_only=1
 AND d.is_encrypted=0 AND d.source_database_id IS NULL
 AND d.is_distributor=0 AND d.is_published=0 AND d.is_subscribed=0
 AND CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))=17
 AND EXISTS(SELECT 1 FROM sys.dm_os_host_info WHERE host_platform=N'Linux')
 AND NOT EXISTS(SELECT 1 FROM sys.database_files WHERE type NOT IN (0,1));
'@)
        if($rows.Count -ne 1 -or [string]$rows[0].DatabaseGuid -notmatch '^[0-9a-fA-F-]{36}$'){throw 'TRANSFER_SOURCE_DATABASE_UNSUPPORTED'}
        $tables=@(Get-LabRelationalCoreTableInventory -Connection $connection)
        if($tables.Count -gt 32){throw 'TRANSFER_SOURCE_LIMIT_EXCEEDED'}
        $totalRows=[long]0
        foreach($table in $tables){
            if(-not(Test-LabRelationalCoreTableSupported -Table $table)){throw 'TRANSFER_SOURCE_CONTENT_UNSUPPORTED'}
            $count=@(Invoke-LabTransferSqlRows -Connection $connection -Query ("SELECT COUNT_BIG(*) AS Rows FROM ["+$table.Schema.Replace(']',']]')+"].["+$table.Name.Replace(']',']]')+"];"))
            if($count.Count -ne 1){throw 'TRANSFER_SOURCE_LIMIT_UNVERIFIABLE'}
            $totalRows+=[long]$count[0].Rows
            if($totalRows -gt 100000){throw 'TRANSFER_SOURCE_LIMIT_EXCEEDED'}
        }
        return $rows[0]
    } finally {$connection.Dispose();$secret=$null}
}

function Get-LabTransferBackup {
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$DataRoot)
    $selection=[pscustomobject]@{SourceRunId=$Request.SourceRunId;SourceInstanceId=$Request.SourceInstanceId;DatabaseTransfers=@([pscustomobject]@{SourceDatabaseName=$Request.SourceDatabaseName;TargetDatabaseName=$Request.TargetDatabaseName;BackupSetId=$Request.BackupSetId})}
    $check=Get-LabPortableContainerTransferPreflightBackups -Request $selection -DataRoot $DataRoot
    if(@($check.Blockers).Count -or @($check.Records).Count -ne 1){throw 'TRANSFER_BACKUP_UNVERIFIABLE'}
    if([long]$check.Records[0].Public.Bytes -gt 256MB){throw 'TRANSFER_BACKUP_LIMIT_EXCEEDED'}
    return $check.Records[0]
}

function Write-LabTransferJournal {
    param([Parameter(Mandatory)]$Journal,[Parameter(Mandatory)][string]$Path)
    $Journal.UpdatedAt=Get-LabTimestamp
    if(-not($Journal|ConvertTo-Json -Depth 35|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'portable-container-transfer-journal.schema.json') -ErrorAction Stop)){throw 'TRANSFER_JOURNAL_INVALID'}
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function ConvertTo-LabTransferFilePlan {
    param([Parameter(Mandatory)][object[]]$Rows,[Parameter(Mandatory)][string]$OperationId)
    $names=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase);$ids=[Collections.Generic.HashSet[long]]::new();$files=[Collections.Generic.List[object]]::new();$totalSize=[decimal]0
    if($Rows.Count -gt 16){throw 'TRANSFER_FILELIST_LIMIT_EXCEEDED'}
    foreach($row in $Rows){
        if([string]::IsNullOrWhiteSpace([string]$row.LogicalName) -or [string]$row.LogicalName -match '[\x00-\x1f]' -or ([string]$row.LogicalName).Length -gt 128 -or
            $row.Type -cnotin @('D','L') -or $row.IsPresent -isnot [bool] -or -not $row.IsPresent -or
            $row.FileId -isnot [long] -or $row.FileId -le 0 -or -not $names.Add([string]$row.LogicalName) -or -not $ids.Add([long]$row.FileId) -or
            ($row.TDEThumbprint -isnot [DBNull] -and $null -ne $row.TDEThumbprint)){throw 'TRANSFER_FILELIST_UNSUPPORTED'}
        if(($row.Size -isnot [decimal] -and $row.Size -isnot [long]) -or $row.Size -le 0){throw 'TRANSFER_FILELIST_SIZE_INVALID'}
        $totalSize+=[decimal]$row.Size
        if($totalSize -gt 1GB){throw 'TRANSFER_FILELIST_LIMIT_EXCEEDED'}
        $extension=if($row.Type -ceq 'L'){'ldf'}else{'mdf'}
        $files.Add([pscustomobject][ordered]@{LogicalName=[string]$row.LogicalName;Type=[string]$row.Type;FileId=[long]$row.FileId;Bytes=[long]$row.Size;Path="/var/opt/mssql/data/transfer-$OperationId-$($row.FileId).$extension"})
    }
    if(-not @($files|Where-Object Type -eq D).Count -or -not @($files|Where-Object Type -eq L).Count){throw 'TRANSFER_FILELIST_INCOMPLETE'}
    return @($files|Sort-Object FileId)
}

function New-LabTransferConnection {
    param([Parameter(Mandatory)]$Binding,[Parameter(Mandatory)][string]$OperationId,[string]$StateRoot,[switch]$Probe)
    $secret=Get-LabRelationalCoreSecret -RunId $Binding.RunId -StateRoot $StateRoot
    try {$connection=New-LabPortableContainerTransferPreflightSqlConnection -Binding $Binding -Secret $secret
        $builder=[Data.SqlClient.SqlConnectionStringBuilder]::new($connection.ConnectionString)
        $builder['Application Name']=if($Probe){'SqlServerLab.TransferProbe'}else{"SqlServerLab.Transfer.$OperationId"};$connection.ConnectionString=$builder.ConnectionString
        return $connection
    }finally{$secret=$null}
}

function Assert-LabTransferNoResidue {
    param([Parameter(Mandatory)]$Binding)
    $scope=Get-LabContainerRuntimeScope -Provider $Binding.Provider
    if($scope.Status -ne 'AVAILABLE' -or $scope.RuntimeId -cne $Binding.RuntimeScopeId){throw 'TRANSFER_CLEANUP_RUNTIME_UNVERIFIABLE'}
    $containers=@(Invoke-LabTransferNative -Provider $Binding.Provider -Arguments @('ps','-a','--no-trunc','--filter',"label=sql-server-lab.run-id=$($Binding.RunId)",'--format','{{.ID}}'))
    $volumes=@(Invoke-LabTransferNative -Provider $Binding.Provider -Arguments @('volume','ls','--filter',"label=sql-server-lab.run-id=$($Binding.RunId)",'--format','{{.Name}}'))
    $exact=@(Invoke-LabTransferNative -Provider $Binding.Provider -Arguments @('ps','-a','--no-trunc','--filter',"id=$($Binding.ContainerId)",'--format','{{.ID}}'))
    $allVolumes=@(Invoke-LabTransferNative -Provider $Binding.Provider -Arguments @('volume','ls','--format','{{.Name}}'))
    if($containers.Count -or $volumes.Count -or $exact.Count -or @($Binding.Volumes|Where-Object {$_ -cin $allVolumes}).Count){throw 'TRANSFER_CLEANUP_RESIDUE'}
}

function Remove-LabTransferOwnedRun {
    param([Parameter(Mandatory)]$Journal,[string]$StateRoot)
    $owned=Get-LabOperationOwnedRun -OperationId $Journal.OperationId -StateRoot $StateRoot
    if(-not $owned){
        if($Journal.Target){$run=Get-LabRunState -RunId $Journal.Target.RunId -StateRoot $StateRoot;if($run.state -ne 'REMOVED'){throw 'TRANSFER_CLEANUP_RUN_MISSING'};Assert-LabTransferNoResidue -Binding $Journal.Target}
        elseif($Journal.Status -ne 'INTENT'){throw 'TRANSFER_CREATE_OUTCOME_UNVERIFIABLE'}
        return
    }
    if($Journal.Target -and $owned.runId -cne $Journal.Target.RunId){throw 'TRANSFER_CLEANUP_OWNERSHIP_MISMATCH'}
    # Failed creation without a returned full live binding remains recoverable,
    # never guessed from a resource name or a partially written cleanup plan.
    if(-not $Journal.Target){
        $candidate=Get-LabTransferBinding -RunId $owned.runId -InstanceId primary -StateRoot $StateRoot -OperationId $Journal.OperationId
        if($candidate.Provider -cne $Journal.Source.Provider -or $candidate.RuntimeScopeId -cne $Journal.Source.RuntimeScopeId -or $candidate.ContainerId -ceq $Journal.Source.ContainerId){throw 'TRANSFER_CREATE_OUTCOME_UNVERIFIABLE'}
        $Journal.Target=Get-LabTransferBindingIdentity $candidate
    }
    $binding=Assert-LabTransferBinding -Expected $Journal.Target -StateRoot $StateRoot -OperationId $Journal.OperationId
    $cleanup=Remove-SqlServerLab -RunId $binding.RunId -StateRoot $StateRoot -Force -Confirm:$false
    if($cleanup.Status -ne 'REMOVED'){throw 'TRANSFER_RUN_CLEANUP_FAILED'}
    Assert-LabTransferNoResidue -Binding $Journal.Target
}

function New-LabTransferResult {
    param([Parameter(Mandatory)]$Journal)
    [pscustomobject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransfer/1.0';OperationId=$Journal.OperationId;Status=$Journal.Status;TargetRunId=if($Journal.Target){$Journal.Target.RunId}else{$null};TargetInstanceId='primary';Comparison=$Journal.Comparison;CleanupStatus=$Journal.CleanupStatus;FailureCode=$Journal.FailureCode}
}

function Invoke-LabPortableContainerTransfer {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Request,[Parameter(Mandatory)][string]$DataRoot,[Parameter(Mandatory)][string]$StateRoot)
    $operationId=$Request.OperationId
    $requestHash=Get-LabTransferHash ([ordered]@{Request=$Request;DataRoot=[IO.Path]::GetFullPath($DataRoot);StateRoot=[IO.Path]::GetFullPath($StateRoot)})
    $root=Join-Path $StateRoot 'portable-container-transfers';$null=New-Item -ItemType Directory -Path $root -Force
    Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $StateRoot -Path $root
    $path=Join-Path $root "$operationId.json";$lockPath=Join-Path $root "$operationId.lock";$lock=$null
    if(Test-Path -LiteralPath $lockPath){Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $root -Path $lockPath}
    try {$lock=[IO.File]::Open($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'TRANSFER_OPERATION_LOCKED'}
    try {
        if(Test-Path -LiteralPath $path){
            Assert-LabPortableContainerTransferPreflightNoReparsePath -Root $root -Path $path
            $raw=Get-Content -LiteralPath $path -Raw
            if(-not($raw|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'portable-container-transfer-journal.schema.json') -ErrorAction Stop)){throw 'TRANSFER_JOURNAL_INVALID'}
            $journal=$raw|ConvertFrom-Json -Depth 35
            if($journal.OperationId -cne $operationId -or $journal.RequestHash -cne $requestHash){throw 'TRANSFER_REQUEST_CHANGED'}
            if($journal.Status -in @('SUCCEEDED','FAILED_CLEANED')){return New-LabTransferResult $journal}
            try {Remove-LabTransferOwnedRun -Journal $journal -StateRoot $StateRoot;$journal.Status='FAILED_CLEANED';$journal.CleanupStatus='CLEANED'}
            catch {$journal.Status='RECOVERY_REQUIRED';$journal.CleanupStatus='RECOVERY_REQUIRED'}
            Write-LabTransferJournal -Journal $journal -Path $path
            return New-LabTransferResult $journal
        }
        if(Get-LabOperationOwnedRun -OperationId $operationId -StateRoot $StateRoot){throw 'TRANSFER_OPERATION_COLLISION'}
        $source=Get-LabTransferBinding -RunId $Request.SourceRunId -InstanceId $Request.SourceInstanceId -StateRoot $StateRoot
        $sourceObservation=Get-LabTransferSourceObservation -Binding $source -DatabaseName $Request.SourceDatabaseName -StateRoot $StateRoot
        $backup=Get-LabTransferBackup -Request $Request -DataRoot $DataRoot
        $journal=[pscustomobject][ordered]@{ContractVersion='SqlServerLab.PortableContainerTransferJournal/1.0';OperationId=$operationId;RequestHash=$requestHash;Status='INTENT';Source=(Get-LabTransferBindingIdentity $source);SourceObservationHash=(Get-LabTransferHash $sourceObservation);BackupSha256=$backup.Public.Sha256;BackupBytes=[long]$backup.Public.Bytes;Target=$null;Files=@();RestoreStarted=$false;Comparison='NOT_EXECUTED';CleanupStatus='NOT_STARTED';FailureCode=$null;UpdatedAt=Get-LabTimestamp}
        Write-LabTransferJournal -Journal $journal -Path $path
        $connection=$null
        try {
            $journal.Status='CREATE_STARTED';Write-LabTransferJournal -Journal $journal -Path $path
            $createParameters=@{Version='2025';Provider=$source.Provider;Profile='compact';Cpu=1;MemoryMB=2560;LabName="transfer-$operationId";StateRoot=$StateRoot;GenerateSaPassword=$true;NonInteractive=$true;Drives=@([pscustomobject]@{id='transfer-data';containerPath='/var/opt/mssql'})}
            $created=Invoke-WithLabWorkflowOperationContext -OperationId $operationId -ScriptBlock {param($Parameters)New-SqlServerLab @Parameters} -ArgumentList @($createParameters)
            $target=Get-LabTransferBinding -RunId $created.RunId -InstanceId primary -StateRoot $StateRoot -OperationId $operationId
            if($target.Provider -cne $source.Provider -or $target.RuntimeScopeId -cne $source.RuntimeScopeId -or $target.ContainerId -ceq $source.ContainerId){throw 'TRANSFER_TARGET_BINDING_INVALID'}
            $journal.Target=Get-LabTransferBindingIdentity $target;$journal.Status='TARGET_CREATED';Write-LabTransferJournal -Journal $journal -Path $path
            $source=Assert-LabTransferBinding -Expected $journal.Source -StateRoot $StateRoot
            if((Get-LabTransferHash (Get-LabTransferSourceObservation -Binding $source -DatabaseName $Request.SourceDatabaseName -StateRoot $StateRoot)) -cne $journal.SourceObservationHash){throw 'TRANSFER_SOURCE_DRIFT'}
            $backup=Get-LabTransferBackup -Request $Request -DataRoot $DataRoot
            if($backup.Public.Sha256 -cne $journal.BackupSha256 -or $backup.Public.Bytes -ne $journal.BackupBytes){throw 'TRANSFER_BACKUP_DRIFT'}
            $stage="/var/opt/mssql/transfer-$operationId.bak"
            $free=@(Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'df','--output=avail','-B1','/var/opt/mssql'))
            if($free.Count -ne 2 -or ([string]$free[1]).Trim() -notmatch '^\d+$' -or [decimal]([string]$free[1]).Trim() -lt ($journal.BackupBytes+512MB)){throw 'TRANSFER_STAGE_CAPACITY_INSUFFICIENT'}
            $null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'test','!','-e',$stage)
            $null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'test','!','-L',$stage)
            $null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('cp',$backup.SourcePath,"$($target.ContainerId):$stage") -TimeoutSeconds 600
            $null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec','--user','root',$target.ContainerId,'chown','mssql:root','--',$stage)
            $stageHash=@(Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'sha256sum','--',$stage))
            $stageSize=@(Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'stat','-c','%s','--',$stage))
            if($stageHash.Count -ne 1 -or [string]$stageHash[0] -cne "$($journal.BackupSha256)  $stage" -or $stageSize.Count -ne 1 -or [string]$stageSize[0] -cne [string]$journal.BackupBytes){throw 'TRANSFER_STAGE_INTEGRITY_FAILED'}
            $journal.Status='STAGED';Write-LabTransferJournal -Journal $journal -Path $path
            $secret=Get-LabRelationalCoreSecret -RunId $target.RunId -StateRoot $StateRoot
            try {Invoke-LabPortableContainerTransferPreflightSql -Binding $target -Secret $secret -SqlBackupPath $stage -ExpectedDatabaseName $Request.SourceDatabaseName}finally{$secret=$null}
            $connection=New-LabTransferConnection -Binding $target -OperationId $operationId -StateRoot $StateRoot;$connection.Open()
            $header=@(Invoke-LabTransferSqlRows -Connection $connection -Query 'RESTORE HEADERONLY FROM DISK=@path;' -Parameters @{'@path'=$stage})
            if($header.Count -ne 1 -or $header[0].IsReadOnly -isnot [bool] -or -not $header[0].IsReadOnly -or [string]$header[0].BindingID -ine [string]$sourceObservation.DatabaseGuid){throw 'TRANSFER_BACKUP_SNAPSHOT_BINDING_INVALID'}
            $rows=@(Invoke-LabTransferSqlRows -Connection $connection -Query 'RESTORE FILELISTONLY FROM DISK=@path WITH FILE=1;' -Parameters @{'@path'=$stage})
            $journal.Files=@(ConvertTo-LabTransferFilePlan -Rows $rows -OperationId $operationId)
            $free=@(Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'df','--output=avail','-B1','/var/opt/mssql'))
            $requiredBytes=[long](($journal.Files|Measure-Object Bytes -Sum).Sum)+512MB
            if($free.Count -ne 2 -or ([string]$free[1]).Trim() -notmatch '^\d+$' -or [decimal]([string]$free[1]).Trim() -lt $requiredBytes){throw 'TRANSFER_RESTORE_CAPACITY_INSUFFICIENT'}
            foreach($file in $journal.Files){$null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'test','!','-e',$file.Path);$null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'test','!','-L',$file.Path)}
            $empty=@(Invoke-LabTransferSqlRows -Connection $connection -Query 'SELECT COUNT(*) AS UserDatabases FROM sys.databases WHERE database_id>4;')
            if($empty.Count -ne 1 -or [int]$empty[0].UserDatabases -ne 0){throw 'TRANSFER_TARGET_DATABASE_COLLISION'}
            $null=Assert-LabTransferBinding -Expected $journal.Target -StateRoot $StateRoot -OperationId $operationId
            $source=Assert-LabTransferBinding -Expected $journal.Source -StateRoot $StateRoot
            if((Get-LabTransferHash (Get-LabTransferSourceObservation -Binding $source -DatabaseName $Request.SourceDatabaseName -StateRoot $StateRoot)) -cne $journal.SourceObservationHash){throw 'TRANSFER_SOURCE_DRIFT'}
            $journal.Status='RESTORE_STARTED';$journal.RestoreStarted=$true;Write-LabTransferJournal -Journal $journal -Path $path
            $moves=@($journal.Files|ForEach-Object {"MOVE N'$($_.LogicalName.Replace("'","''"))' TO N'$($_.Path)'"}) -join ', '
            $command=$connection.CreateCommand();$command.CommandTimeout=$Request.RestoreTimeoutSeconds
            $command.CommandText="IF EXISTS(SELECT 1 FROM sys.databases WHERE database_id>4) THROW 51000, 'TRANSFER_TARGET_DATABASE_COLLISION', 1; RESTORE DATABASE [$($Request.TargetDatabaseName)] FROM DISK=@path WITH FILE=1, CHECKSUM, STOP_ON_ERROR, $moves, RECOVERY;"
            $null=$command.Parameters.AddWithValue('@path',$stage)
            try {$null=$command.ExecuteNonQuery()}finally{$command.Dispose()}
            $journal.Status='RESTORED';Write-LabTransferJournal -Journal $journal -Path $path
            $actualFiles=@(Invoke-LabTransferSqlRows -Connection $connection -Query 'SELECT name AS LogicalName, physical_name AS Path FROM sys.master_files WHERE database_id=DB_ID(@database);' -Parameters @{'@database'=$Request.TargetDatabaseName})
            if($actualFiles.Count -ne $journal.Files.Count){throw 'TRANSFER_RESTORED_FILES_MISMATCH'}
            foreach($file in $journal.Files){if(@($actualFiles|Where-Object {$_.LogicalName -ceq $file.LogicalName -and $_.Path -ceq $file.Path}).Count -ne 1){throw 'TRANSFER_RESTORED_FILES_MISMATCH'}}
            $command=$connection.CreateCommand();$command.CommandTimeout=60;$command.CommandText="ALTER DATABASE [$($Request.TargetDatabaseName)] SET READ_ONLY;"
            try{$null=$command.ExecuteNonQuery()}finally{$command.Dispose()}
            $connection.Dispose();$connection=$null
            $pair=[pscustomobject]@{PairId='transfer';SourceRunId=$Request.SourceRunId;SourceInstanceId=$Request.SourceInstanceId;SourceDatabaseName=$Request.SourceDatabaseName;TargetRunId=$target.RunId;TargetInstanceId='primary';TargetDatabaseName=$Request.TargetDatabaseName}
            $comparison=Invoke-LabRelationalCoreComparison -ComparisonPair @($pair) -StateRoot $StateRoot -TimeoutSeconds 300 -ExpectedBindings ([pscustomobject]@{Source=$source;Target=$target})
            $journal.Comparison=if($comparison.Status -eq 'MATCH'){'MATCH'}else{'DIFFERENT_OR_UNSUPPORTED'}
            if($comparison.Status -ne 'MATCH'){throw 'TRANSFER_CONTENT_COMPARISON_FAILED'}
            $source=Assert-LabTransferBinding -Expected $journal.Source -StateRoot $StateRoot
            if((Get-LabTransferHash (Get-LabTransferSourceObservation -Binding $source -DatabaseName $Request.SourceDatabaseName -StateRoot $StateRoot)) -cne $journal.SourceObservationHash){throw 'TRANSFER_SOURCE_DRIFT'}
            $target=Assert-LabTransferBinding -Expected $journal.Target -StateRoot $StateRoot -OperationId $operationId
            $journal.Status='VERIFIED';Write-LabTransferJournal -Journal $journal -Path $path
            $null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'rm','--',$stage)
            $null=Invoke-LabTransferNative -Provider $target.Provider -Arguments @('exec',$target.ContainerId,'test','!','-e',$stage)
            $journal.Status='SUCCEEDED';$journal.CleanupStatus='STAGE_CLEANED_TARGET_RETAINED';Write-LabTransferJournal -Journal $journal -Path $path
        } catch {
            if($connection){$connection.Dispose();$connection=$null}
            $journal.FailureCode=if($_.Exception.Message -match '^TRANSFER_[A-Z_]+$'){$_.Exception.Message}else{'TRANSFER_EXECUTION_FAILED'}
            # Missing durable acknowledgement is intentionally not a replay signal.
            try {Remove-LabTransferOwnedRun -Journal $journal -StateRoot $StateRoot;$journal.Status='FAILED_CLEANED';$journal.CleanupStatus='CLEANED'}
            catch {$journal.Status='RECOVERY_REQUIRED';$journal.CleanupStatus='RECOVERY_REQUIRED'}
            Write-LabTransferJournal -Journal $journal -Path $path
        } finally {if($connection){$connection.Dispose()}}
        return New-LabTransferResult $journal
    }finally{$lock.Dispose()}
}
