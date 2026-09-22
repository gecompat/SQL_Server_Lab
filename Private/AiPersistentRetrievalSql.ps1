# SQL-Vertrag des begrenzten synthetischen Persistenz-Slices.
function Invoke-LabAiPersistentSql {
    param($Context,[string]$Step,[string]$Sql,[hashtable]$Parameters=@{})
    if($Context.Timer.Elapsed.TotalSeconds -ge $Context.TimeoutSeconds){throw 'AI_PERSISTENT_DEADLINE_EXCEEDED'}
    if($Context.SqlExecutor){return @(& $Context.SqlExecutor $Step $Sql $Parameters)}
    $seconds=[Math]::Max(1,[Math]::Min(60,[int]($Context.TimeoutSeconds-$Context.Timer.Elapsed.TotalSeconds)))
    return @(Invoke-LabTransferSqlRows -Connection $Context.Connection -Query $Sql -Parameters $Parameters -TimeoutSeconds $seconds)
}

function Get-LabAiPersistentDatabase {
    param($Context,$Journal)
    @(Invoke-LabAiPersistentSql $Context Database "SELECT CONVERT(nvarchar(36),r.database_guid) AS DatabaseGuid,d.state_desc AS State,d.is_read_only AS IsReadOnly FROM sys.databases d JOIN sys.database_recovery_status r ON r.database_id=d.database_id WHERE d.name=@name AND d.database_id>4;" @{name=$Journal.databaseName})
}

function Assert-LabAiPersistentOwner {
    param($Context,$Journal)
    $db=@(Get-LabAiPersistentDatabase $Context $Journal)
    if($db.Count -ne 1 -or $db[0].State -cne 'ONLINE' -or [bool]$db[0].IsReadOnly){throw 'AI_PERSISTENT_DATABASE_UNAVAILABLE'}
    $rows=@(Invoke-LabAiPersistentSql $Context Owner "SELECT OwnerToken,RunId,ScopeId,InstanceId,CollectionId,DatabaseGuid,ActiveGeneration FROM [$($Journal.databaseName)].dbo.LabOwner WHERE Singleton=1;")
    if($rows.Count -ne 1){throw 'AI_PERSISTENT_OWNERSHIP_UNPROVEN'}
    $owner=$rows[0]
    foreach($pair in @(@('OwnerToken','ownerToken'),@('RunId','runId'),@('ScopeId','scopeId'),@('InstanceId','instanceId'),@('CollectionId','collectionId'))){if([string]$owner.($pair[0]) -cne [string]$Journal.($pair[1])){throw 'AI_PERSISTENT_OWNERSHIP_MISMATCH'}}
    if([string]$owner.DatabaseGuid -cne [string]$db[0].DatabaseGuid -or ($Journal.databaseGuid -and [string]$Journal.databaseGuid -cne [string]$db[0].DatabaseGuid)){throw 'AI_PERSISTENT_DATABASE_IDENTITY_DRIFT'}
    return $owner
}

function Initialize-LabAiPersistentDatabase {
    param($Context,$Journal)
    # CREATE DATABASE kann nicht gemeinsam mit dem Receipt transaktional sein.
    # Eine vorhandene DB ohne Receipt wird deshalb niemals nachträglich adoptiert.
    $name=$Journal.databaseName
    $null=Invoke-LabAiPersistentSql $Context Create @'
IF DB_ID(@name) IS NOT NULL THROW 51000,'AI_PERSISTENT_DATABASE_COLLISION',1;
DECLARE @data nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath')),
 @log nvarchar(4000)=CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultLogPath'));
IF @data IS NULL OR @log IS NULL THROW 51000,'AI_PERSISTENT_STORAGE_UNAVAILABLE',1;
DECLARE @sql nvarchar(max)=N'CREATE DATABASE '+QUOTENAME(@name)+N' ON PRIMARY (NAME='+QUOTENAME(@name,N'''')+N',FILENAME='+QUOTENAME(@data+@name+N'.mdf',N'''')+N',SIZE=8MB,MAXSIZE=64MB,FILEGROWTH=8MB) LOG ON (NAME='+QUOTENAME(@name+N'_log',N'''')+N',FILENAME='+QUOTENAME(@log+@name+N'.ldf',N'''')+N',SIZE=8MB,MAXSIZE=32MB,FILEGROWTH=8MB);';
EXEC(@sql);
'@ @{name=$name}
    $null=Invoke-LabAiPersistentSql $Context Initialize @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
CREATE TABLE [$name].dbo.LabOwner(Singleton int NOT NULL PRIMARY KEY CHECK(Singleton=1),OwnerToken char(64) NOT NULL,RunId varchar(36) NOT NULL,ScopeId varchar(36) NOT NULL,InstanceId nvarchar(64) NOT NULL,CollectionId varchar(36) NOT NULL,DatabaseGuid varchar(36) NOT NULL,ActiveGeneration int NOT NULL);
CREATE TABLE [$name].dbo.LabGenerations(Generation int NOT NULL PRIMARY KEY,OperationId varchar(36) NOT NULL,PlanKey char(64) NOT NULL,Revision varchar(16) NOT NULL,DatasetHash char(64) NOT NULL,ModelHash char(64) NOT NULL,Status varchar(16) NOT NULL);
CREATE TABLE [$name].dbo.LabChunks(Generation int NOT NULL,ChunkId nvarchar(96) COLLATE Latin1_General_100_BIN2 NOT NULL,Content nvarchar(4000) NOT NULL,ContentHash char(64) NOT NULL,Embedding VECTOR(768) NOT NULL,VectorHash char(64) NOT NULL,PRIMARY KEY(Generation,ChunkId));
INSERT [$name].dbo.LabOwner SELECT 1,@token,@run,@scope,@instance,@collection,CONVERT(varchar(36),database_guid),0 FROM sys.database_recovery_status WHERE database_id=DB_ID(@name);
IF @@ROWCOUNT<>1 THROW 51000,'AI_PERSISTENT_DATABASE_RECEIPT_FAILED',1;
COMMIT;
"@ @{name=$name;token=$Journal.ownerToken;run=$Journal.runId;scope=$Journal.scopeId;instance=$Journal.instanceId;collection=$Journal.collectionId}
}

function Get-LabAiPersistentGeneration {
    param($Context,$Journal,[int]$Generation)
    @(Invoke-LabAiPersistentSql $Context Generation "SELECT Generation,OperationId,PlanKey,Revision,DatasetHash,ModelHash,Status FROM [$($Journal.databaseName)].dbo.LabGenerations WHERE Generation=@generation;" @{generation=$Generation})
}

function Get-LabAiPersistentChunks {
    param($Context,$Journal,[int]$Generation)
    @(Invoke-LabAiPersistentSql $Context Chunks "SELECT ChunkId,Content,ContentHash,VectorHash,LOWER(CONVERT(char(64),HASHBYTES('SHA2_256',CAST(Embedding AS varchar(max))),2)) AS ActualVectorHash FROM [$($Journal.databaseName)].dbo.LabChunks WHERE Generation=@generation ORDER BY ChunkId;" @{generation=$Generation})
}

function Assert-LabAiPersistentChunks {
    param([object[]]$Rows,[object[]]$Documents,[switch]$Complete)
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($row in $Rows){
        $document=@($Documents|Where-Object Id -CEQ $row.ChunkId)
        if(-not $seen.Add([string]$row.ChunkId) -or $document.Count -ne 1 -or [string]$row.Content -cne $document[0].Content -or [string]$row.ContentHash -cne $document[0].ContentHash -or [string]$row.VectorHash -notmatch '^[a-f0-9]{64}$' -or [string]$row.VectorHash -cne [string]$row.ActualVectorHash){throw 'AI_PERSISTENT_CHUNK_DRIFT'}
    }
    if($Complete -and $Rows.Count -ne $Documents.Count){throw 'AI_PERSISTENT_GENERATION_INCOMPLETE'}
}

function Complete-LabAiPersistentGeneration {
    param($Context,$Journal,$Plan,[int]$Previous,$MigrationJournal)
    $manifest=@($Plan.Documents|ForEach-Object{[ordered]@{Id=$_.Id;Content=$_.Content;ContentHash=$_.ContentHash}})|ConvertTo-Json -Compress
    $name=$Journal.databaseName
    $migrationGuard=''
    $parameters=@{token=$Journal.ownerToken;databaseGuid=$Journal.databaseGuid;previous=$Previous;generation=$Plan.Generation;operation=$Journal.operationId;plan=$Plan.PlanKey;model=$Journal.modelHash;manifest=$manifest;documentCount=$Plan.Documents.Count;dataset=$Plan.DatasetHash;revision=$Plan.Revision}
    if($MigrationJournal){
        $parameters.receipt=$MigrationJournal.migration|ConvertTo-Json -Depth 15 -Compress
        $parameters.sourcePlan=$MigrationJournal.planKey;$parameters.sourceModel=$MigrationJournal.modelHash;$parameters.sourceOperation=$MigrationJournal.operationId
        $migrationGuard=@"
IF NOT EXISTS(SELECT 1 FROM [$name].dbo.LabMigrationReceipt WITH(UPDLOCK,HOLDLOCK) WHERE Singleton=1 AND Contract='SqlServerLab.AiPersistentSql/2.0' AND UpgradeId=@operation AND PlanKey=@plan AND Receipt COLLATE Latin1_General_100_BIN2=@receipt COLLATE Latin1_General_100_BIN2 AND DATALENGTH(Receipt)=DATALENGTH(@receipt)) THROW 51000,'AI_PERSISTENT_MIGRATION_RECEIPT_DRIFT',1;
IF NOT EXISTS(SELECT 1 FROM [$name].dbo.LabGenerations WITH(UPDLOCK,HOLDLOCK) WHERE Generation=2 AND Status='COMMITTED' AND PlanKey=@sourcePlan AND ModelHash=@sourceModel AND OperationId=@sourceOperation AND DatasetHash=@dataset AND Revision='Delta') THROW 51000,'AI_PERSISTENT_SOURCE_GENERATION_DRIFT',1;
IF (SELECT COUNT(*) FROM [$name].dbo.LabChunks WITH(UPDLOCK,HOLDLOCK) WHERE Generation=2)<>3 OR EXISTS(SELECT ChunkId COLLATE Latin1_General_100_BIN2,ChunkSha256,SourceVectorSha256 FROM OPENJSON(@receipt,'$.sourceChunks') WITH(ChunkId nvarchar(96),ChunkSha256 char(64),SourceVectorSha256 char(64)) EXCEPT SELECT ChunkId,ContentHash,LOWER(CONVERT(char(64),HASHBYTES('SHA2_256',CAST(Embedding AS varchar(max))),2)) FROM [$name].dbo.LabChunks WHERE Generation=2) OR EXISTS(SELECT Id COLLATE Latin1_General_100_BIN2,DATALENGTH(Id),Content COLLATE Latin1_General_100_BIN2,DATALENGTH(Content),ContentHash FROM OPENJSON(@manifest) WITH(Id nvarchar(96),Content nvarchar(4000),ContentHash char(64)) EXCEPT SELECT ChunkId,DATALENGTH(ChunkId),Content COLLATE Latin1_General_100_BIN2,DATALENGTH(Content),ContentHash FROM [$name].dbo.LabChunks WHERE Generation=2) THROW 51000,'AI_PERSISTENT_SOURCE_GENERATION_DRIFT',1;
"@
    }
    $null=Invoke-LabAiPersistentSql $Context Commit @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF NOT EXISTS(SELECT 1 FROM [$name].dbo.LabOwner WITH(UPDLOCK,HOLDLOCK) WHERE Singleton=1 AND OwnerToken=@token AND DatabaseGuid=@databaseGuid AND ActiveGeneration=@previous) THROW 51000,'AI_PERSISTENT_CUTOVER_CONFLICT',1;
$migrationGuard
IF NOT EXISTS(SELECT 1 FROM [$name].dbo.LabGenerations WITH(UPDLOCK,HOLDLOCK) WHERE Generation=@generation AND OperationId=@operation AND PlanKey=@plan AND ModelHash=@model AND DatasetHash=@dataset AND Revision=@revision AND Status='STAGING') THROW 51000,'AI_PERSISTENT_GENERATION_DRIFT',1;
IF (SELECT COUNT(*) FROM [$name].dbo.LabChunks WITH(UPDLOCK,HOLDLOCK) WHERE Generation=@generation)<>@documentCount OR EXISTS(SELECT Id COLLATE Latin1_General_100_BIN2,DATALENGTH(Id),Content COLLATE Latin1_General_100_BIN2,DATALENGTH(Content),ContentHash FROM OPENJSON(@manifest) WITH(Id nvarchar(96),Content nvarchar(4000),ContentHash char(64)) EXCEPT SELECT ChunkId,DATALENGTH(ChunkId),Content COLLATE Latin1_General_100_BIN2,DATALENGTH(Content),ContentHash FROM [$name].dbo.LabChunks WHERE Generation=@generation) OR EXISTS(SELECT 1 FROM [$name].dbo.LabChunks WHERE Generation=@generation AND VectorHash<>LOWER(CONVERT(char(64),HASHBYTES('SHA2_256',CAST(Embedding AS varchar(max))),2))) THROW 51000,'AI_PERSISTENT_GENERATION_INCOMPLETE',1;
UPDATE [$name].dbo.LabGenerations SET Status='COMMITTED' WHERE Generation=@generation;
UPDATE [$name].dbo.LabOwner SET ActiveGeneration=@generation WHERE Singleton=1;
COMMIT;
"@ $parameters
}
