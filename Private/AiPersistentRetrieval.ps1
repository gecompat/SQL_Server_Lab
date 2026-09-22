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

function Assert-LabAiPersistentInput {
    param([string]$Text)
    if([Text.Encoding]::UTF8.GetByteCount($Text) -gt 512){throw 'AI_PERSISTENT_MODEL_INPUT_LIMIT_EXCEEDED'}
}

function ConvertTo-LabAiPersistentDocuments {
    param([object[]]$Documents)
    if($null -eq $Documents -or $Documents.Count -lt 1 -or $Documents.Count -gt 16){throw 'AI_PERSISTENT_DOCUMENTS_INVALID'}
    $result=@($Documents|ForEach-Object{[pscustomobject]@{Id=[string]$_.Id;Content=[string]$_.Content;ContentHash=Get-LabAiSha256Text ([string]$_.Content)}}|Sort-Object Id -CaseSensitive)
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($document in $result){if(-not $ids.Add($document.Id) -or $document.Id -notmatch '^[a-z][a-z0-9-]{2,95}$' -or [string]::IsNullOrWhiteSpace($document.Content) -or $document.Content.Length -gt 4000){throw 'AI_PERSISTENT_DOCUMENTS_INVALID'}}
    return $result
}

function New-LabAiPersistentPlan {
    param([string]$RunId,[string]$InstanceId,[string]$CollectionId,[string]$Action,[string]$FixtureRevision,[string]$QueryId,[object[]]$Documents,[object[]]$ExpectedDocuments,[string]$Question,[ValidateSet('Vector','Hybrid')][string]$SearchMode='Vector',[int]$LocalPort,[int]$TimeoutSeconds,[switch]$Resume,[string]$TargetModelKey,[ValidateSet('ollama-embeddinggemma-latest','ollama-bge-m3-latest','ollama-nomic-embed-text-v2-moe')][string]$EmbeddingModelKey='ollama-embeddinggemma-latest',[int]$KeepGenerations=2)
    if($Resume -and $Action -notin @('Apply','Migrate','Sync')){throw 'AI_PERSISTENT_RESUME_ACTION_INVALID'}
    $callerSupplied=$null -ne $Documents
    if($Action -eq 'Migrate'){
        if($TargetModelKey -cne 'ollama-nomic-embed-text-v2-moe' -or ($callerSupplied -and $FixtureRevision -cne 'Initial') -or (-not $callerSupplied -and $FixtureRevision -cne 'Delta')){throw 'AI_PERSISTENT_MIGRATION_REQUEST_INVALID'}
    }elseif($TargetModelKey){throw 'AI_PERSISTENT_MIGRATION_TARGET_UNEXPECTED'}
    if($Action -ne 'Prune' -and $KeepGenerations -ne 2){throw 'AI_PERSISTENT_RETENTION_UNEXPECTED'}
    if($SearchMode -eq 'Hybrid' -and $Action -ne 'Query'){throw 'AI_PERSISTENT_SEARCH_MODE_INVALID'}
    try{$RunId=([guid]::ParseExact($RunId,'D')).ToString('D');$CollectionId=([guid]::ParseExact($CollectionId,'D')).ToString('D')}catch{throw 'AI_PERSISTENT_IDENTITY_INVALID'}
    if($Action -eq 'Prune'){
        if($callerSupplied -or $null -ne $ExpectedDocuments -or $Question -or $TargetModelKey -or $FixtureRevision -cne 'Initial' -or $QueryId -cne 'backup' -or $KeepGenerations -lt 1 -or $KeepGenerations -gt 31){throw 'AI_PERSISTENT_RETENTION_REQUEST_INVALID'}
        $identity=[ordered]@{Contract='SqlServerLab.AiPersistentRetention/1.0';RunId=$RunId;InstanceId=$InstanceId;CollectionId=$CollectionId;KeepGenerations=$KeepGenerations}
        return [pscustomobject]@{RunId=$RunId;InstanceId=$InstanceId;CollectionId=$CollectionId;Action=$Action;Revision=$null;Generation=0;DatasetMode=$null;SearchMode='Vector';Documents=@();DatasetHash=$null;PlanKey=Get-LabAiPlanKey $identity;ExpectedDocuments=@();EndpointPlan=$null;TimeoutSeconds=$TimeoutSeconds;Resume=$false;KeepGenerations=$KeepGenerations}
    }
    if($callerSupplied){
        if($Action -notin @('Apply','Query','Sync','Migrate') -or $FixtureRevision -cne 'Initial' -or ($Action -ne 'Migrate' -and $TargetModelKey)){throw 'AI_PERSISTENT_DOCUMENTS_ACTION_INVALID'}
        $documents=ConvertTo-LabAiPersistentDocuments $Documents
        if($Action -eq 'Migrate'){
            $prefixBytes=[Text.Encoding]::UTF8.GetByteCount('search_document: ')
            foreach($document in $documents){if($prefixBytes+[Text.Encoding]::UTF8.GetByteCount($document.Content) -gt 512){throw 'AI_PERSISTENT_MODEL_INPUT_LIMIT_EXCEEDED'}}
        }
        if($Action -eq 'Sync'){$expected=ConvertTo-LabAiPersistentDocuments $ExpectedDocuments}
        elseif($null -ne $ExpectedDocuments){throw 'AI_PERSISTENT_EXPECTED_DOCUMENTS_UNEXPECTED'}
        if($Action -eq 'Query' -and [string]::IsNullOrWhiteSpace($Question)){throw 'AI_PERSISTENT_QUESTION_INVALID'}
        if($Action -ne 'Query' -and $Question){throw 'AI_PERSISTENT_QUESTION_INVALID'}
        $questionText=$Question
        $datasetMode='CallerSupplied'
    }else{
        if($Action -eq 'Sync'){throw 'AI_PERSISTENT_DOCUMENTS_INVALID'}
        if($null -ne $ExpectedDocuments){throw 'AI_PERSISTENT_EXPECTED_DOCUMENTS_UNEXPECTED'}
        if($Question){throw 'AI_PERSISTENT_QUESTION_INVALID'}
        $fixturePath=Join-Path $script:ModuleRoot 'Scenarios/Ai/persistent-retrieval/1.0/fixture.json'
        $fixture=Get-Content -LiteralPath $fixturePath -Raw -Encoding utf8|ConvertFrom-Json -Depth 10
        if($fixture.contract -cne 'SqlServerLab.AiPersistentFixture/1.0' -or $fixture.modelKey -cne 'ollama-embeddinggemma-latest' -or $fixture.dimension -ne 768){throw 'AI_PERSISTENT_FIXTURE_INVALID'}
        $documents=@($fixture.revisions.$FixtureRevision|Sort-Object Id|ForEach-Object{[pscustomobject]@{Id=[string]$_.Id;Content=[string]$_.Content;ContentHash=Get-LabAiSha256Text ([string]$_.Content)}})
        if($documents.Count -ne 3 -or @($documents.Id|Select-Object -Unique).Count -ne 3){throw 'AI_PERSISTENT_FIXTURE_INVALID'}
        foreach($document in $documents){if($document.Id -notmatch '^[a-z][a-z0-9-]{2,95}$' -or -not $document.Content -or $document.Content.Length -gt 4000){throw 'AI_PERSISTENT_FIXTURE_INVALID'}}
        $questionText=[string]$fixture.queries.$QueryId
        $datasetMode='Fixture'
    }
    $modelKey=if($Action -eq 'Migrate'){$TargetModelKey}else{$EmbeddingModelKey}
    $endpoint=New-LabAiEndpointPlan -ModelKey $modelKey -EndpointRef ollama-local -Lane local -LocalPort $LocalPort -MaximumRequests 1 -RetryCount 0 -TimeoutSeconds 60
    if($endpoint.Status -eq 'BLOCKED' -or $endpoint.Dimension -notin @(768,1024)){throw 'AI_PERSISTENT_MODEL_PLAN_INVALID'}
    if($endpoint.InputProfile -ceq 'nomic-search'){
        foreach($document in $documents){Assert-LabAiPersistentInput (ConvertTo-LabAiEmbeddingInput -Plan $endpoint -Role document -Text $document.Content)}
        if($Action -eq 'Query'){Assert-LabAiPersistentInput (ConvertTo-LabAiEmbeddingInput -Plan $endpoint -Role query -Text $questionText)}
    }
    $datasetHash=Get-LabAiPlanKey @($documents|ForEach-Object{[ordered]@{Id=$_.Id;Hash=$_.ContentHash}})
    $identity=[ordered]@{Contract='SqlServerLab.AiPersistentRetrieval/1.0';RunId=$RunId;InstanceId=$InstanceId;CollectionId=$CollectionId;Revision=$FixtureRevision;DatasetHash=$datasetHash;EndpointPlanKey=$endpoint.PlanKey}
    if($callerSupplied){$identity.DatasetMode=$datasetMode}
    if($Action -eq 'Migrate'){
        $identity.Contract='SqlServerLab.AiPersistentMigration/2.0'
        if(-not $callerSupplied){$identity.SourceGeneration=2;$identity.TargetGeneration=3}
        $identity.ProfileHash=Get-LabAiPlanKey (Get-LabAiPersistentProfile nomic-search)
    }
    $expectedDatasetHash=$null;$expectedPlanKey=$null
    if($Action -eq 'Sync'){
        $expectedDatasetHash=Get-LabAiPlanKey @($expected|ForEach-Object{[ordered]@{Id=$_.Id;Hash=$_.ContentHash}})
        $expectedIdentity=[ordered]@{Contract='SqlServerLab.AiPersistentRetrieval/1.0';RunId=$RunId;InstanceId=$InstanceId;CollectionId=$CollectionId;Revision='Initial';DatasetHash=$expectedDatasetHash;EndpointPlanKey=$endpoint.PlanKey}
        $expectedIdentity.DatasetMode='CallerSupplied'
        $expectedPlanKey=Get-LabAiPlanKey $expectedIdentity
    }
    [pscustomobject]@{RunId=$RunId;InstanceId=$InstanceId;CollectionId=$CollectionId;Action=$Action;Revision=$(if($Action -eq 'Sync' -or ($Action -eq 'Migrate' -and $callerSupplied)){'Managed'}else{$FixtureRevision});Generation=$(if($Action -eq 'Sync' -or ($Action -eq 'Migrate' -and $callerSupplied)){0}elseif($FixtureRevision -eq 'Initial'){1}else{2});QueryId=$QueryId;Question=$questionText;DatasetMode=$datasetMode;SearchMode=$SearchMode;Documents=$documents;DatasetHash=$datasetHash;PlanKey=Get-LabAiPlanKey $identity;ExpectedDocuments=$expected;ExpectedDatasetHash=$expectedDatasetHash;ExpectedPlanKey=$expectedPlanKey;EndpointPlan=$endpoint;TimeoutSeconds=$TimeoutSeconds;Resume=[bool]$Resume}
}

function Write-LabAiPersistentJournal {
    param([string]$Path,$Journal)
    Assert-LabAiPersistentPath $Path
    $json=$Journal|ConvertTo-Json -Depth 15
    $schema=if($Journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0'){'ai-persistent-retrieval-journal-v2.schema.json'}else{'ai-persistent-retrieval-journal.schema.json'}
    if(-not ($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath $schema) -ErrorAction SilentlyContinue)){throw 'AI_PERSISTENT_JOURNAL_INVALID'}
    if($Journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0'){Assert-LabAiPersistentMigrationJournal $Journal}
    Write-LabArtifactJsonAtomic -Path $Path -InputObject $Journal
}

function Read-LabAiPersistentJournal {
    param([string]$Path,$Plan,[string]$BindingHash)
    $json=Get-Content -LiteralPath $Path -Raw -Encoding utf8
    $journal=$json|ConvertFrom-Json -Depth 15
    $schema=if($journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0'){'ai-persistent-retrieval-journal-v2.schema.json'}else{'ai-persistent-retrieval-journal.schema.json'}
    if(-not ($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath $schema) -ErrorAction SilentlyContinue)){throw 'AI_PERSISTENT_JOURNAL_INVALID'}
    if($journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0'){Assert-LabAiPersistentMigrationJournal $journal}
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
        if(Test-Path -LiteralPath $path){$journal=Read-LabAiPersistentJournal $path $Plan $bindingHash;if($Plan.Action -in @('Apply','Sync') -and $journal.status -notin @('COMMITTED','REMOVED') -and -not $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUIRED'}}
        elseif($Plan.Action -ne 'Apply' -or $Plan.Revision -ne 'Initial' -or $Plan.Resume){throw 'AI_PERSISTENT_COLLECTION_NOT_FOUND'}
        $model=$null
        if($Plan.Action -notin @('Remove','Migrate','Prune') -and (-not $journal -or $journal.contract -ceq 'SqlServerLab.AiPersistentJournal/1.0')){
            $model=Get-LabAiPersistentModel $context $Plan $MetadataTransport
            if($model.Dimension -ne $Plan.EndpointPlan.Dimension){throw 'AI_PERSISTENT_MODEL_DIMENSION_INVALID'}
            $modelHash=Get-LabAiPlanKey $model
            if($journal -and $journal.modelHash -cne $modelHash){throw 'AI_PERSISTENT_MODEL_DRIFT'}
        }
        if(-not $journal){
            $token=[Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)).ToLowerInvariant()
            $journal=[pscustomobject][ordered]@{contract='SqlServerLab.AiPersistentJournal/1.0';runId=$Plan.RunId;scopeId=$binding.ScopeId;instanceId=$Plan.InstanceId;collectionId=$Plan.CollectionId;bindingHash=$bindingHash;databaseName=('SqlLabAi_'+[guid]::NewGuid().ToString('N'));databaseGuid=$null;ownerToken=$token;modelBinding=$model;modelHash=$modelHash;operationId=[guid]::NewGuid().ToString('D');revision=$Plan.Revision;planKey=$Plan.PlanKey;datasetHash=$Plan.DatasetHash;status='CREATE_PENDING';activeGeneration=0;completedChunks=@()}
            Write-LabAiPersistentJournal $path $journal
        }
        $dimension=[int]$journal.modelBinding.Dimension
        if($dimension -lt 1 -or $dimension -gt 1998 -or
            ($Plan.Action -notin @('Remove','Prune') -and $dimension -ne [int]$Plan.EndpointPlan.Dimension)) {
            throw 'AI_PERSISTENT_MODEL_DIMENSION_INVALID'
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
        if($Plan.Action -eq 'Prune'){
            if($journal.contract -cne 'SqlServerLab.AiPersistentJournal/1.0' -or $journal.status -cne 'COMMITTED' -or $journal.revision -cne 'Managed' -or [int]$owner.ActiveGeneration -ne [int]$journal.activeGeneration){throw 'AI_PERSISTENT_RETENTION_UNSUPPORTED'}
            $rows=@(Invoke-LabAiPersistentSql $context Prune @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF NOT EXISTS(SELECT 1 FROM [$($journal.databaseName)].dbo.LabOwner WITH(UPDLOCK,HOLDLOCK) WHERE Singleton=1 AND OwnerToken=@token AND DatabaseGuid=@guid AND ActiveGeneration=@active) THROW 51000,'AI_PERSISTENT_OWNERSHIP_MISMATCH',1;
IF EXISTS(SELECT 1 FROM [$($journal.databaseName)].dbo.LabGenerations WITH(UPDLOCK,HOLDLOCK) WHERE Status<>'COMMITTED') THROW 51000,'AI_PERSISTENT_RETENTION_INCOMPLETE',1;
DECLARE @retained TABLE(Generation int PRIMARY KEY);
INSERT @retained SELECT TOP(@keep) Generation FROM [$($journal.databaseName)].dbo.LabGenerations ORDER BY Generation DESC;
IF NOT EXISTS(SELECT 1 FROM @retained WHERE Generation=@active) THROW 51000,'AI_PERSISTENT_ACTIVE_GENERATION_MISSING',1;
DECLARE @deletedGenerations int=(SELECT COUNT(*) FROM [$($journal.databaseName)].dbo.LabGenerations WHERE Generation NOT IN(SELECT Generation FROM @retained));
DECLARE @deletedChunks int=(SELECT COUNT(*) FROM [$($journal.databaseName)].dbo.LabChunks WHERE Generation NOT IN(SELECT Generation FROM @retained));
DECLARE @retainedGenerations int=(SELECT COUNT(*) FROM @retained);
DELETE FROM [$($journal.databaseName)].dbo.LabChunks WHERE Generation NOT IN(SELECT Generation FROM @retained);
DELETE FROM [$($journal.databaseName)].dbo.LabGenerations WHERE Generation NOT IN(SELECT Generation FROM @retained);
COMMIT TRANSACTION;
SELECT @retainedGenerations AS RetainedGenerations,@deletedGenerations AS DeletedGenerations,@deletedChunks AS DeletedChunks;
"@ @{token=$journal.ownerToken;guid=$journal.databaseGuid;active=[int]$owner.ActiveGeneration;keep=$Plan.KeepGenerations})
            if($rows.Count -ne 1 -or [int]$rows[0].RetainedGenerations -lt 1 -or [int]$rows[0].RetainedGenerations -gt $Plan.KeepGenerations -or [int]$rows[0].DeletedGenerations -lt 0 -or [int]$rows[0].DeletedChunks -lt 0){throw 'AI_PERSISTENT_RETENTION_UNCONFIRMED'}
            return [pscustomobject]@{Status='PRUNED';CollectionId=$Plan.CollectionId;Generation=[int]$owner.ActiveGeneration;RetainedGenerations=[int]$rows[0].RetainedGenerations;DeletedGenerations=[int]$rows[0].DeletedGenerations;DeletedChunks=[int]$rows[0].DeletedChunks;EmbeddingRequests=0}
        }
        if($Plan.Action -eq 'Sync' -and $journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0'){throw 'AI_PERSISTENT_SYNC_MIGRATION_UNSUPPORTED'}
        if($Plan.Action -eq 'Migrate' -or $journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0'){
            if($Plan.Action -eq 'Query' -and $Plan.SearchMode -eq 'Hybrid'){throw 'AI_PERSISTENT_HYBRID_MIGRATION_UNSUPPORTED'}
            return Invoke-LabAiPersistentMigration -Context $context -Plan $Plan -Journal $journal -Owner $owner -Path $path -Identity $identity -StateRoot $StateRoot -MetadataTransport $MetadataTransport -EmbeddingTransport $EmbeddingTransport -FaultInjector $FaultInjector
        }
        if($Plan.Action -eq 'Query'){
            if($Plan.DatasetMode -ceq 'CallerSupplied'){
                if([int]$owner.ActiveGeneration -lt 1 -or [int]$owner.ActiveGeneration -gt 32){throw 'AI_PERSISTENT_ACTIVE_GENERATION_MISSING'}
                $activeRevision='Managed';$active=$Plan
            }else{
                if([int]$owner.ActiveGeneration -notin @(1,2)){throw 'AI_PERSISTENT_ACTIVE_GENERATION_MISSING'}
                $activeRevision=if([int]$owner.ActiveGeneration -eq 1){'Initial'}else{'Delta'}
                $active=New-LabAiPersistentPlan -RunId $Plan.RunId -InstanceId $Plan.InstanceId -CollectionId $Plan.CollectionId -Action Query -FixtureRevision $activeRevision -QueryId $Plan.QueryId -SearchMode $Plan.SearchMode -LocalPort $Plan.EndpointPlan.Port -TimeoutSeconds $Plan.TimeoutSeconds -EmbeddingModelKey $journal.modelBinding.ModelKey
            }
            $generation=@(Get-LabAiPersistentGeneration $context $journal ([int]$owner.ActiveGeneration))
            if($generation.Count -ne 1 -or $generation[0].Status -cne 'COMMITTED' -or $generation[0].ModelHash -cne $journal.modelHash -or $generation[0].DatasetHash -cne $active.DatasetHash -or $generation[0].PlanKey -cne $active.PlanKey){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
            if($Plan.DatasetMode -ceq 'CallerSupplied'){$activeRevision=[string]$generation[0].Revision}
            $chunks=@(Get-LabAiPersistentChunks $context $journal ([int]$owner.ActiveGeneration));Assert-LabAiPersistentChunks $chunks $active.Documents -Complete
            $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
            $queryInput=ConvertTo-LabAiEmbeddingInput -Plan $Plan.EndpointPlan -Role query -Text $Plan.Question
            if($Plan.EndpointPlan.InputProfile -ceq 'nomic-search'){Assert-LabAiPersistentInput $queryInput}
            $embedding=Get-LabAiPersistentEmbedding $context $Plan $queryInput $EmbeddingTransport;$requests+=$embedding.Attempts
            $vector=ConvertTo-LabAiVectorLiteral -Vector @($embedding.Vector) -Dimension $dimension
            $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
            $null=Assert-LabTransferBinding -Expected $identity -StateRoot $StateRoot
            if($Plan.SearchMode -eq 'Hybrid'){
                $ranked=@(Invoke-LabAiPersistentSql $context HybridQuery @"
DECLARE @v VECTOR($dimension)=CAST(@vector AS VECTOR($dimension));
WITH QueryTerms AS (
 SELECT DISTINCT LOWER(value) AS Term
 FROM STRING_SPLIT(TRANSLATE(@question,N'.,;:!?()[]{}',N'            '),N' ')
 WHERE LEN(value)>=4
), Ranked AS (
 SELECT c.ChunkId,c.ContentHash,CONVERT(float,VECTOR_DISTANCE('cosine',@v,c.Embedding)) AS Distance,
        COALESCE(CONVERT(float,(SELECT COUNT(*) FROM QueryTerms q WHERE CHARINDEX(q.Term,LOWER(c.Content))>0))/NULLIF(CONVERT(float,(SELECT COUNT(*) FROM QueryTerms)),0.0),0.0) AS LexicalScore
 FROM [$($journal.databaseName)].dbo.LabChunks c
 JOIN [$($journal.databaseName)].dbo.LabOwner o ON c.Generation=o.ActiveGeneration AND o.Singleton=1
 WHERE c.Generation=@generation
)
SELECT TOP(3) ChunkId,ContentHash,Distance,LexicalScore,
       (0.7*(1.0-Distance))+(0.3*LexicalScore) AS HybridScore
FROM Ranked ORDER BY HybridScore DESC,Distance,ChunkId;
"@ @{vector=$vector;question=$Plan.Question;generation=[int]$owner.ActiveGeneration})
            }else{
                $ranked=@(Invoke-LabAiPersistentSql $context Query "DECLARE @v VECTOR($dimension)=CAST(@vector AS VECTOR($dimension));SELECT TOP(3) c.ChunkId,c.ContentHash,CONVERT(float,VECTOR_DISTANCE('cosine',@v,c.Embedding)) AS Distance FROM [$($journal.databaseName)].dbo.LabChunks c JOIN [$($journal.databaseName)].dbo.LabOwner o ON c.Generation=o.ActiveGeneration WHERE o.Singleton=1 AND o.ActiveGeneration=@generation ORDER BY VECTOR_DISTANCE('cosine',@v,c.Embedding),c.ChunkId;" @{vector=$vector;generation=[int]$owner.ActiveGeneration})
            }
            $expectedRankedCount=[Math]::Min(3,$active.Documents.Count)
            if($ranked.Count -ne $expectedRankedCount -or @($ranked.ChunkId|Select-Object -Unique).Count -ne $expectedRankedCount){throw 'AI_PERSISTENT_QUERY_INVALID'}
            foreach($row in $ranked){
                $expectedDocument=@($active.Documents|Where-Object Id -CEQ $row.ChunkId)
                if($expectedDocument.Count -ne 1 -or [string]$row.ContentHash -cne $expectedDocument[0].ContentHash -or [double]::IsNaN([double]$row.Distance) -or [double]::IsInfinity([double]$row.Distance)){throw 'AI_PERSISTENT_QUERY_INVALID'}
                if($Plan.SearchMode -eq 'Hybrid' -and ([double]::IsNaN([double]$row.LexicalScore) -or [double]::IsInfinity([double]$row.LexicalScore) -or [double]$row.LexicalScore -lt 0 -or [double]$row.LexicalScore -gt 1 -or [double]::IsNaN([double]$row.HybridScore) -or [double]::IsInfinity([double]$row.HybridScore))){throw 'AI_PERSISTENT_QUERY_INVALID'}
            }
            return [pscustomobject]@{Status='QUERIED';CollectionId=$Plan.CollectionId;Generation=[int]$owner.ActiveGeneration;Revision=$activeRevision;DatasetMode=$Plan.DatasetMode;SearchMode=$Plan.SearchMode;Ranked=$ranked;EmbeddingRequests=$requests}
        }
        if($Plan.Action -eq 'Sync'){
            $resumingSync=$journal.revision -ceq 'Managed' -and $journal.status -eq 'STAGING'
            if($resumingSync){
                if('targetGeneration' -notin $journal.PSObject.Properties.Name){throw 'AI_PERSISTENT_JOURNAL_INVALID'}
                $Plan.Generation=[int]$journal.targetGeneration
                if($journal.planKey -cne $Plan.PlanKey -or $journal.datasetHash -cne $Plan.DatasetHash){throw 'AI_PERSISTENT_RESUME_REQUEST_MISMATCH'}
                $receipt=@(Get-LabAiPersistentGeneration $context $journal $Plan.Generation)
                if($receipt.Count -eq 1 -and $receipt[0].Status -ceq 'COMMITTED' -and [int]$owner.ActiveGeneration -eq $Plan.Generation){
                    if($receipt[0].OperationId -cne $journal.operationId -or $receipt[0].PlanKey -cne $Plan.PlanKey -or $receipt[0].ModelHash -cne $journal.modelHash -or $receipt[0].DatasetHash -cne $Plan.DatasetHash){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
                    Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $context $journal $Plan.Generation) $Plan.Documents -Complete
                    $journal.status='COMMITTED';$journal.activeGeneration=$Plan.Generation;Write-LabAiPersistentJournal $path $journal
                    return [pscustomobject]@{Status='COMMITTED';CollectionId=$Plan.CollectionId;Generation=$Plan.Generation;DatasetMode=$Plan.DatasetMode;EmbeddingRequests=0;CopiedChunks=0}
                }
                if(-not $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUIRED'}
                if([int]$owner.ActiveGeneration -ne ($Plan.Generation-1)){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
            }else{
                if($journal.status -ne 'COMMITTED' -or $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUEST_MISMATCH'}
                $Plan.Generation=[int]$owner.ActiveGeneration+1
                if($Plan.Generation -gt 32){throw 'AI_PERSISTENT_GENERATION_LIMIT_REACHED'}
            }
            $sourceGeneration=@(Get-LabAiPersistentGeneration $context $journal ([int]$owner.ActiveGeneration))
            if($sourceGeneration.Count -ne 1 -or $sourceGeneration[0].Status -cne 'COMMITTED' -or $sourceGeneration[0].ModelHash -cne $journal.modelHash -or $sourceGeneration[0].DatasetHash -cne $Plan.ExpectedDatasetHash -or $sourceGeneration[0].PlanKey -cne $Plan.ExpectedPlanKey){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
            try{Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $context $journal ([int]$owner.ActiveGeneration)) $Plan.ExpectedDocuments -Complete}catch{throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
            if(-not $resumingSync){
                $journal.operationId=[guid]::NewGuid().ToString('D');$journal.revision='Managed';$journal.planKey=$Plan.PlanKey;$journal.datasetHash=$Plan.DatasetHash;$journal.completedChunks=@();$journal.status='STAGING'
                if('targetGeneration' -in $journal.PSObject.Properties.Name){$journal.targetGeneration=$Plan.Generation}else{$journal|Add-Member -NotePropertyName targetGeneration -NotePropertyValue $Plan.Generation}
                Write-LabAiPersistentJournal $path $journal
            }
        }
        if([int]$owner.ActiveGeneration -gt $Plan.Generation){throw 'AI_PERSISTENT_STALE_REVISION'}
        if($Plan.Action -ne 'Sync' -and $Plan.Generation -eq 2 -and [int]$owner.ActiveGeneration -lt 1){throw 'AI_PERSISTENT_INITIAL_REQUIRED'}
        if($Plan.Action -ne 'Sync' -and $Plan.Generation -eq 2 -and [int]$owner.ActiveGeneration -eq 1){
            $sourcePlan=New-LabAiPersistentPlan -RunId $Plan.RunId -InstanceId $Plan.InstanceId -CollectionId $Plan.CollectionId -Action Apply -FixtureRevision Initial -QueryId backup -LocalPort $Plan.EndpointPlan.Port -TimeoutSeconds $Plan.TimeoutSeconds
            $sourceGeneration=@(Get-LabAiPersistentGeneration $context $journal 1)
            if($sourceGeneration.Count -ne 1 -or $sourceGeneration[0].Status -cne 'COMMITTED' -or $sourceGeneration[0].ModelHash -cne $journal.modelHash -or $sourceGeneration[0].DatasetHash -cne $sourcePlan.DatasetHash -or $sourceGeneration[0].PlanKey -cne $sourcePlan.PlanKey){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
            Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $context $journal 1) $sourcePlan.Documents -Complete
        }
        if($Plan.Action -ne 'Sync' -and $journal.revision -cne $Plan.Revision){
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
                return [pscustomobject]@{Status='COMMITTED';CollectionId=$Plan.CollectionId;Generation=$Plan.Generation;DatasetMode=$Plan.DatasetMode;EmbeddingRequests=0;CopiedChunks=0}
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
                $documentInput=ConvertTo-LabAiEmbeddingInput -Plan $Plan.EndpointPlan -Role document -Text $document.Content
                if($Plan.EndpointPlan.InputProfile -ceq 'nomic-search'){Assert-LabAiPersistentInput $documentInput}
                $embedding=Get-LabAiPersistentEmbedding $context $Plan $documentInput $EmbeddingTransport;$requests+=$embedding.Attempts
                $vector=ConvertTo-LabAiVectorLiteral -Vector @($embedding.Vector) -Dimension $dimension
                $null=Get-LabAiPersistentModel $context $Plan $MetadataTransport $model
                $null=Invoke-LabAiPersistentSql $context Insert "DECLARE @v VECTOR($dimension)=CAST(@vector AS VECTOR($dimension));INSERT [$($journal.databaseName)].dbo.LabChunks VALUES(@generation,@id,@content,@hash,@v,LOWER(CONVERT(char(64),HASHBYTES('SHA2_256',CAST(@v AS varchar(max))),2)));" @{generation=$Plan.Generation;id=$document.Id;content=$document.Content;hash=$document.ContentHash;vector=$vector}
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
        [pscustomobject]@{Status='COMMITTED';CollectionId=$Plan.CollectionId;Generation=$Plan.Generation;DatasetMode=$Plan.DatasetMode;EmbeddingRequests=$requests;CopiedChunks=$copied}
    }catch{
        # Keine blinde SQL-Wiederholung oder Cleanup bei unbekanntem Ausgang.
        $code=if($_.Exception.Message -match '^AI_PERSISTENT_[A-Z_]+$'){$_.Exception.Message}else{'AI_PERSISTENT_RECOVERY_REQUIRED'}
        throw $code
    }finally{
        if($connection){$connection.Dispose()};if($secret){$secret.Dispose()};if($lock){$lock.Dispose()}
    }
}
