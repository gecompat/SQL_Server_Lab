# Persistente synthetische Generationen; der bestehende Modellwechsel-Plan bleibt separat.
function Assert-LabAiPersistentPath {
    param([string]$Path)
    $existing=[IO.Path]::GetFullPath($Path)
    while(-not(Test-Path -LiteralPath $existing)){$parent=Split-Path $existing -Parent;if(-not $parent -or $parent -eq $existing){throw 'AI_PERSISTENT_STATE_PATH_INVALID'};$existing=$parent}
    Assert-LabPortableContainerTransferPreflightNoReparsePath -Root ([IO.Path]::GetPathRoot($existing)) -Path $existing
}

function Get-LabAiPersistentModel {
    param($Context,$Plan,[scriptblock]$MetadataTransport,$Expected)
    if($Context.Timer.Elapsed.TotalSeconds+45 -gt $Context.TimeoutSeconds){throw 'AI_PERSISTENT_DEADLINE_EXCEEDED'}
    $actual=Get-LabAiHostModelBinding -Plan $Plan.EndpointPlan -MetadataTransport $MetadataTransport
    if($Expected -and (Get-LabAiPlanKey $actual) -cne (Get-LabAiPlanKey $Expected)){throw 'AI_PERSISTENT_MODEL_DRIFT'}
    return $actual
}

function Get-LabAiPersistentEmbedding {
    param($Context,$Plan,[string]$Text,[scriptblock]$Transport)
    if($Context.Timer.Elapsed.TotalSeconds+60 -gt $Context.TimeoutSeconds){throw 'AI_PERSISTENT_DEADLINE_EXCEEDED'}
    Invoke-LabAiEndpointRequest -Plan $Plan.EndpointPlan -InputText $Text -Transport $Transport
}

function New-LabAiPersistentPlan {
    param([string]$RunId,[string]$InstanceId,[string]$CollectionId,[string]$Action,[string]$FixtureRevision,[string]$QueryId,[int]$LocalPort,[int]$TimeoutSeconds,[switch]$Resume)
    if($Resume -and $Action -ne 'Apply'){throw 'AI_PERSISTENT_RESUME_ACTION_INVALID'}
    try{$RunId=([guid]::ParseExact($RunId,'D')).ToString('D');$CollectionId=([guid]::ParseExact($CollectionId,'D')).ToString('D')}catch{throw 'AI_PERSISTENT_IDENTITY_INVALID'}
    $fixturePath=Join-Path $script:ModuleRoot 'Scenarios/Ai/persistent-retrieval/1.0/fixture.json'
    $fixture=Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8|ConvertFrom-Json -Depth 10
    if($fixture.contract -cne 'SqlServerLab.AiPersistentFixture/1.0' -or $fixture.modelKey -cne 'ollama-embeddinggemma-latest' -or $fixture.dimension -ne 768){throw 'AI_PERSISTENT_FIXTURE_INVALID'}
    $documents=@($fixture.revisions.$FixtureRevision|Sort-Object Id|ForEach-Object{[pscustomobject]@{Id=[string]$_.Id;Content=[string]$_.Content;ContentHash=Get-LabAiSha256Text ([string]$_.Content)}})
    if($documents.Count -ne 3 -or @($documents.Id|Select-Object -Unique).Count -ne 3){throw 'AI_PERSISTENT_FIXTURE_INVALID'}
    foreach($document in $documents){if($document.Id -notmatch '^[a-z][a-z0-9-]{2,95}$' -or -not $document.Content -or $document.Content.Length -gt 4000){throw 'AI_PERSISTENT_FIXTURE_INVALID'}}
    $endpoint=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $LocalPort -MaximumRequests 1 -RetryCount 0 -TimeoutSeconds 60
    if($endpoint.Status -eq 'BLOCKED' -or $endpoint.Dimension -ne 768){throw 'AI_PERSISTENT_MODEL_PLAN_INVALID'}
    $datasetHash=Get-LabAiPlanKey @($documents|ForEach-Object{[ordered]@{Id=$_.Id;Hash=$_.ContentHash}})
    $identity=[ordered]@{Contract='SqlServerLab.AiPersistentRetrieval/1.0';RunId=$RunId;InstanceId=$InstanceId;CollectionId=$CollectionId;Revision=$FixtureRevision;DatasetHash=$datasetHash;EndpointPlanKey=$endpoint.PlanKey}
    [pscustomobject]@{RunId=$RunId;InstanceId=$InstanceId;CollectionId=$CollectionId;Action=$Action;Revision=$FixtureRevision;Generation=$(if($FixtureRevision -eq 'Initial'){1}else{2});QueryId=$QueryId;Question=[string]$fixture.queries.$QueryId;Documents=$documents;DatasetHash=$datasetHash;PlanKey=Get-LabAiPlanKey $identity;EndpointPlan=$endpoint;TimeoutSeconds=$TimeoutSeconds;Resume=[bool]$Resume}
}

function Write-LabAiPersistentJournal {
    param([string]$Path,$Journal)
    Assert-LabAiPersistentPath $Path
    $json=$Journal|ConvertTo-Json -Depth 15
    if(-not ($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-persistent-retrieval-journal.schema.json') -ErrorAction SilentlyContinue)){throw 'AI_PERSISTENT_JOURNAL_INVALID'}
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Read-LabAiPersistentJournal {
    param([string]$Path,$Plan,[string]$BindingHash)
    $json=Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if(-not ($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-persistent-retrieval-journal.schema.json') -ErrorAction SilentlyContinue)){throw 'AI_PERSISTENT_JOURNAL_INVALID'}
    $journal=$json|ConvertFrom-Json -Depth 15
    if((Get-LabAiPlanKey $journal.modelBinding) -cne $journal.modelHash){throw 'AI_PERSISTENT_JOURNAL_MODEL_INVALID'}
    if($journal.runId -cne $Plan.RunId -or $journal.instanceId -cne $Plan.InstanceId -or $journal.collectionId -cne $Plan.CollectionId -or $journal.bindingHash -cne $BindingHash){throw 'AI_PERSISTENT_REQUEST_BINDING_DRIFT'}
    return $journal
}

function Invoke-LabAiPersistentRetrieval {
    param($Plan,[string]$StateRoot,[scriptblock]$SqlExecutor,[scriptblock]$MetadataTransport,[scriptblock]$EmbeddingTransport,[scriptblock]$FaultInjector)
    $context=[pscustomobject]@{Connection=$null;SqlExecutor=$SqlExecutor;Timer=[Diagnostics.Stopwatch]::StartNew();TimeoutSeconds=$Plan.TimeoutSeconds}
    $connection=$null;$secret=$null;$lock=$null;$journal=$null;$requests=0;$copied=0
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $StateRoot=[IO.Path]::GetFullPath($StateRoot)
    $directory=Join-Path (Join-Path (Join-Path $StateRoot 'runs') $Plan.RunId) 'ai-persistent'
    $path=Join-Path $directory "$($Plan.InstanceId)-$($Plan.CollectionId).json"
    foreach($target in @($directory,$path,"$path.lock")){Assert-LabAiPersistentPath $target}
    $binding=Get-LabTransferBinding -RunId $Plan.RunId -InstanceId $Plan.InstanceId -StateRoot $StateRoot
    $identity=Get-LabTransferBindingIdentity $binding;$bindingHash=Get-LabAiPlanKey $identity
    $null=New-Item -ItemType Directory -Path $directory -Force
    Assert-LabAiPersistentPath $directory
    try{$lock=[IO.File]::Open("$path.lock",[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)}catch{throw 'AI_PERSISTENT_LOCKED'}
    try{
        if(Test-Path -LiteralPath $path){$journal=Read-LabAiPersistentJournal $path $Plan $bindingHash;if($Plan.Action -eq 'Apply' -and $journal.status -notin @('COMMITTED','REMOVED') -and -not $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUIRED'}}
        elseif($Plan.Action -ne 'Apply' -or $Plan.Revision -ne 'Initial' -or $Plan.Resume){throw 'AI_PERSISTENT_COLLECTION_NOT_FOUND'}
        $model=$null
        if($Plan.Action -ne 'Remove'){
            $model=Get-LabAiPersistentModel $context $Plan $MetadataTransport
            if($model.Dimension -ne 768){throw 'AI_PERSISTENT_MODEL_DIMENSION_INVALID'}
            $modelHash=Get-LabAiPlanKey $model
            if($journal -and $journal.modelHash -cne $modelHash){throw 'AI_PERSISTENT_MODEL_DRIFT'}
        }
        if(-not $journal){
            $token=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $journal=[pscustomobject][ordered]@{contract='SqlServerLab.AiPersistentJournal/1.0';runId=$Plan.RunId;scopeId=$binding.ScopeId;instanceId=$Plan.InstanceId;collectionId=$Plan.CollectionId;bindingHash=$bindingHash;databaseName=('SqlLabAi_'+[guid]::NewGuid().ToString('N'));databaseGuid=$null;ownerToken=$token;modelBinding=$model;modelHash=$modelHash;operationId=[guid]::NewGuid().ToString('D');revision=$Plan.Revision;planKey=$Plan.PlanKey;datasetHash=$Plan.DatasetHash;status='CREATE_PENDING';activeGeneration=0;completedChunks=@()}
            Write-LabAiPersistentJournal $path $journal
        }
        if($journal.status -eq 'REMOVED'){
            if($Plan.Action -ne 'Remove'){throw 'AI_PERSISTENT_COLLECTION_REMOVED'}
        }
        $null=Assert-LabTransferBinding -Expected $identity -StateRoot $StateRoot
        if(-not $SqlExecutor){
            $storedSecret=Get-LabRelationalCoreSecret -RunId $Plan.RunId -StateRoot $StateRoot
            try{$secret=$storedSecret.Copy();$secret.MakeReadOnly()}finally{$storedSecret.Dispose()}
            $connection=New-LabRelationalCoreConnection -Binding $binding -DatabaseName master -Secret $secret
            $connection.Open();$context.Connection=$connection
        }
        $sqlLock=@(Invoke-LabAiPersistentSql $context Lock @'
IF CONVERT(int,SERVERPROPERTY('ProductMajorVersion'))<>17 OR NOT EXISTS(SELECT 1 FROM sys.dm_os_host_info WHERE host_platform=N'Linux') THROW 51000,'AI_PERSISTENT_SQL_UNSUPPORTED',1;
DECLARE @result int; EXEC @result=sys.sp_getapplock @Resource=@resource,@LockMode='Exclusive',@LockOwner='Session',@LockTimeout=0; SELECT @result AS LockResult;
'@ @{resource="SqlServerLab.AiPersistent.$($Plan.CollectionId)"})
        if($sqlLock.Count -ne 1 -or [int]$sqlLock[0].LockResult -lt 0){throw 'AI_PERSISTENT_SQL_LOCKED'}
        $exists=@(Get-LabAiPersistentDatabase $context $journal)
        if($Plan.Action -eq 'Remove'){
            if($exists.Count -eq 0 -and $journal.status -in @('REMOVING','REMOVED')){$journal.status='REMOVED';Write-LabAiPersistentJournal $path $journal;return [pscustomobject]@{Status='REMOVED';CollectionId=$Plan.CollectionId;Generation=0;EmbeddingRequests=0}}
            if($journal.status -eq 'REMOVED'){throw 'AI_PERSISTENT_DATABASE_IDENTITY_DRIFT'}
            $removeOwner=Assert-LabAiPersistentOwner $context $journal
            if(-not $journal.databaseGuid){$journal.databaseGuid=[string]$removeOwner.DatabaseGuid}
            $null=Assert-LabTransferBinding -Expected $identity -StateRoot $StateRoot
            $journal.status='REMOVING';Write-LabAiPersistentJournal $path $journal
            $null=Invoke-LabAiPersistentSql $context Remove "IF NOT EXISTS(SELECT 1 FROM [$($journal.databaseName)].dbo.LabOwner WHERE OwnerToken=@token AND DatabaseGuid=@guid) THROW 51000,'AI_PERSISTENT_OWNERSHIP_MISMATCH',1; IF NOT EXISTS(SELECT 1 FROM sys.database_recovery_status WHERE database_id=DB_ID(@name) AND CONVERT(varchar(36),database_guid)=@guid) THROW 51000,'AI_PERSISTENT_DATABASE_IDENTITY_DRIFT',1; DROP DATABASE [$($journal.databaseName)];" @{token=$journal.ownerToken;guid=$journal.databaseGuid;name=$journal.databaseName}
            if(@(Get-LabAiPersistentDatabase $context $journal).Count){throw 'AI_PERSISTENT_REMOVE_UNCONFIRMED'}
            $journal.status='REMOVED';Write-LabAiPersistentJournal $path $journal
            return [pscustomobject]@{Status='REMOVED';CollectionId=$Plan.CollectionId;Generation=0;EmbeddingRequests=0}
        }
        if($journal.status -eq 'REMOVING'){throw 'AI_PERSISTENT_REMOVE_RECOVERY_REQUIRED'}
        if($exists.Count -eq 0){
            if($Plan.Action -ne 'Apply'){throw 'AI_PERSISTENT_DATABASE_MISSING'}
            if($journal.status -ne 'CREATE_PENDING' -or $journal.databaseGuid){throw 'AI_PERSISTENT_DATABASE_MISSING'}
            Initialize-LabAiPersistentDatabase $context $journal
        }
        # Auch bei verlorenem Initialize-Response ist ausschließlich das SQL-Receipt maßgeblich.
        $owner=Assert-LabAiPersistentOwner $context $journal
        if(-not $journal.databaseGuid){if($Plan.Action -ne 'Apply'){throw 'AI_PERSISTENT_RESUME_REQUIRED'};$journal.databaseGuid=[string]$owner.DatabaseGuid;Write-LabAiPersistentJournal $path $journal}
        if($Plan.Action -eq 'Query'){
            if([int]$owner.ActiveGeneration -notin @(1,2)){throw 'AI_PERSISTENT_ACTIVE_GENERATION_MISSING'}
            $activeRevision=if([int]$owner.ActiveGeneration -eq 1){'Initial'}else{'Delta'}
            $active=New-LabAiPersistentPlan -RunId $Plan.RunId -InstanceId $Plan.InstanceId -CollectionId $Plan.CollectionId -Action Query -FixtureRevision $activeRevision -QueryId $Plan.QueryId -LocalPort $Plan.EndpointPlan.Port -TimeoutSeconds $Plan.TimeoutSeconds
            $generation=@(Get-LabAiPersistentGeneration $context $journal ([int]$owner.ActiveGeneration))
            if($generation.Count -ne 1 -or $generation[0].Status -cne 'COMMITTED' -or $generation[0].ModelHash -cne $journal.modelHash -or $generation[0].DatasetHash -cne $active.DatasetHash){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
            $chunks=@(Get-LabAiPersistentChunks $context $journal ([int]$owner.ActiveGeneration));Assert-LabAiPersistentChunks $chunks $active.Documents -Complete
            $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
            $embedding=Get-LabAiPersistentEmbedding $context $Plan $Plan.Question $EmbeddingTransport;$requests+=$embedding.Attempts
            $vector=ConvertTo-LabAiVectorLiteral -Vector @($embedding.Vector) -Dimension 768
            $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
            $null=Assert-LabTransferBinding -Expected $identity -StateRoot $StateRoot
            $ranked=@(Invoke-LabAiPersistentSql $context Query "DECLARE @v VECTOR(768)=CAST(@vector AS VECTOR(768));SELECT TOP(3) c.ChunkId,c.ContentHash,CONVERT(float,VECTOR_DISTANCE('cosine',@v,c.Embedding)) AS Distance FROM [$($journal.databaseName)].dbo.LabChunks c JOIN [$($journal.databaseName)].dbo.LabOwner o ON c.Generation=o.ActiveGeneration WHERE o.Singleton=1 AND o.ActiveGeneration=@generation ORDER BY VECTOR_DISTANCE('cosine',@v,c.Embedding),c.ChunkId;" @{vector=$vector;generation=[int]$owner.ActiveGeneration})
            if($ranked.Count -ne 3 -or @($ranked.ChunkId|Select-Object -Unique).Count -ne 3){throw 'AI_PERSISTENT_QUERY_INVALID'}
            foreach($row in $ranked){$expectedDocument=@($active.Documents|Where-Object Id -CEQ $row.ChunkId);if($expectedDocument.Count -ne 1 -or [string]$row.ContentHash -cne $expectedDocument[0].ContentHash -or [double]::IsNaN([double]$row.Distance) -or [double]::IsInfinity([double]$row.Distance)){throw 'AI_PERSISTENT_QUERY_INVALID'}}
            return [pscustomobject]@{Status='QUERIED';CollectionId=$Plan.CollectionId;Generation=[int]$owner.ActiveGeneration;Revision=$activeRevision;Ranked=$ranked;EmbeddingRequests=$requests}
        }
        if([int]$owner.ActiveGeneration -gt $Plan.Generation){throw 'AI_PERSISTENT_STALE_REVISION'}
        if($Plan.Generation -eq 2 -and [int]$owner.ActiveGeneration -lt 1){throw 'AI_PERSISTENT_INITIAL_REQUIRED'}
        if($Plan.Generation -eq 2 -and [int]$owner.ActiveGeneration -eq 1){
            $sourcePlan=New-LabAiPersistentPlan -RunId $Plan.RunId -InstanceId $Plan.InstanceId -CollectionId $Plan.CollectionId -Action Apply -FixtureRevision Initial -QueryId backup -LocalPort $Plan.EndpointPlan.Port -TimeoutSeconds $Plan.TimeoutSeconds
            $sourceGeneration=@(Get-LabAiPersistentGeneration $context $journal 1)
            if($sourceGeneration.Count -ne 1 -or $sourceGeneration[0].Status -cne 'COMMITTED' -or $sourceGeneration[0].ModelHash -cne $journal.modelHash -or $sourceGeneration[0].DatasetHash -cne $sourcePlan.DatasetHash -or $sourceGeneration[0].PlanKey -cne $sourcePlan.PlanKey){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
            Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $context $journal 1) $sourcePlan.Documents -Complete
        }
        if($journal.revision -cne $Plan.Revision){
            if($journal.status -ne 'COMMITTED' -or $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUEST_MISMATCH'}
            $journal.operationId=[guid]::NewGuid().ToString('D');$journal.revision=$Plan.Revision;$journal.planKey=$Plan.PlanKey;$journal.datasetHash=$Plan.DatasetHash;$journal.completedChunks=@();$journal.status='STAGING'
            Write-LabAiPersistentJournal $path $journal
        }
        if($journal.planKey -cne $Plan.PlanKey -or $journal.datasetHash -cne $Plan.DatasetHash){throw 'AI_PERSISTENT_RESUME_REQUEST_MISMATCH'}
        $generations=@(Get-LabAiPersistentGeneration $context $journal $Plan.Generation)
        if($generations.Count){
            $g=$generations[0]
            if($generations.Count -ne 1 -or $g.OperationId -cne $journal.operationId -or $g.PlanKey -cne $Plan.PlanKey -or $g.ModelHash -cne $journal.modelHash -or $g.DatasetHash -cne $Plan.DatasetHash){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
            if($g.Status -eq 'COMMITTED' -and [int]$owner.ActiveGeneration -eq $Plan.Generation){
                Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $context $journal $Plan.Generation) $Plan.Documents -Complete
                $journal.status='COMMITTED';$journal.activeGeneration=$Plan.Generation;Write-LabAiPersistentJournal $path $journal
                return [pscustomobject]@{Status='COMMITTED';CollectionId=$Plan.CollectionId;Generation=$Plan.Generation;EmbeddingRequests=0;CopiedChunks=0}
            }
            if($g.Status -ne 'STAGING' -or -not $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUIRED'}
        }else{
            $null=Invoke-LabAiPersistentSql $context Stage "INSERT [$($journal.databaseName)].dbo.LabGenerations VALUES(@generation,@operation,@plan,@revision,@dataset,@model,'STAGING');" @{generation=$Plan.Generation;operation=$journal.operationId;plan=$Plan.PlanKey;revision=$Plan.Revision;dataset=$Plan.DatasetHash;model=$journal.modelHash}
        }
        $journal.status='STAGING';Write-LabAiPersistentJournal $path $journal
        $rows=@(Get-LabAiPersistentChunks $context $journal $Plan.Generation);Assert-LabAiPersistentChunks $rows $Plan.Documents
        foreach($document in $Plan.Documents){
            if($document.Id -cin $rows.ChunkId){continue}
            $null=Assert-LabTransferBinding -Expected $identity -StateRoot $StateRoot
            $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
            $old=@(Get-LabAiPersistentChunks $context $journal ([int]$owner.ActiveGeneration)|Where-Object {$_.ChunkId -ceq $document.Id -and $_.ContentHash -ceq $document.ContentHash})
            if($old.Count){
                Assert-LabAiPersistentChunks $old @($document) -Complete
                $null=Invoke-LabAiPersistentSql $context Copy "INSERT [$($journal.databaseName)].dbo.LabChunks SELECT @generation,ChunkId,Content,ContentHash,Embedding,VectorHash FROM [$($journal.databaseName)].dbo.LabChunks WHERE Generation=@previous AND ChunkId=@id AND ContentHash=@hash;" @{generation=$Plan.Generation;previous=[int]$owner.ActiveGeneration;id=$document.Id;hash=$document.ContentHash};$copied++
            }else{
                $embedding=Get-LabAiPersistentEmbedding $context $Plan $document.Content $EmbeddingTransport;$requests+=$embedding.Attempts
                $vector=ConvertTo-LabAiVectorLiteral -Vector @($embedding.Vector) -Dimension 768
                $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
                $null=Invoke-LabAiPersistentSql $context Insert "DECLARE @v VECTOR(768)=CAST(@vector AS VECTOR(768));INSERT [$($journal.databaseName)].dbo.LabChunks VALUES(@generation,@id,@content,@hash,@v,LOWER(CONVERT(char(64),HASHBYTES('SHA2_256',CAST(@v AS varchar(max))),2)));" @{generation=$Plan.Generation;id=$document.Id;content=$document.Content;hash=$document.ContentHash;vector=$vector}
            }
            if($FaultInjector){& $FaultInjector 'AfterChunkSql' $document.Id}
            $rows=@(Get-LabAiPersistentChunks $context $journal $Plan.Generation);Assert-LabAiPersistentChunks $rows $Plan.Documents
            $journal.completedChunks=@($rows.ChunkId);Write-LabAiPersistentJournal $path $journal
        }
        Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $context $journal $Plan.Generation) $Plan.Documents -Complete
        $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
        $null=Assert-LabTransferBinding -Expected $identity -StateRoot $StateRoot
        $null=Assert-LabAiPersistentOwner $context $journal
        Complete-LabAiPersistentGeneration $context $journal $Plan ([int]$owner.ActiveGeneration)
        if($FaultInjector){& $FaultInjector 'AfterCommitSql' ''}
        $journal.status='COMMITTED';$journal.activeGeneration=$Plan.Generation;Write-LabAiPersistentJournal $path $journal
        [pscustomobject]@{Status='COMMITTED';CollectionId=$Plan.CollectionId;Generation=$Plan.Generation;EmbeddingRequests=$requests;CopiedChunks=$copied}
    }catch{
        # Keine blinde SQL-Wiederholung oder Cleanup bei unbekanntem Ausgang.
        $code=if($_.Exception.Message -match '^AI_PERSISTENT_[A-Z_]+$'){$_.Exception.Message}else{'AI_PERSISTENT_RECOVERY_REQUIRED'}
        throw $code
    }finally{
        if($connection){$connection.Dispose()};if($secret){$secret.Dispose()};if($lock){$lock.Dispose()}
    }
}
