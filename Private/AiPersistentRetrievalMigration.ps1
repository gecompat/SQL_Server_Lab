# Begrenzter Modellwechsel: bestätigte Embeddinggemma-Generation nach Nomic.
function Get-LabAiPersistentProfile {
    param([ValidateSet('raw','nomic-search')][string]$Name)
    [pscustomobject][ordered]@{Contract='SqlServerLab.AiEmbeddingProfile/1.0';Name=$Name;DocumentPrefix=$(if($Name -eq 'raw'){''}else{'search_document: '});QueryPrefix=$(if($Name -eq 'raw'){''}else{'search_query: '});Dimension=768}
}

function Assert-LabAiPersistentMigrationInput {
    param([string]$Text)
    if([Text.Encoding]::UTF8.GetByteCount($Text) -gt 512){throw 'AI_PERSISTENT_MODEL_INPUT_LIMIT_EXCEEDED'}
}

function Get-LabAiPersistentMigrationSourceGeneration {
    param($Migration)
    if($null -eq $Migration){return 2}
    if('sourceGeneration' -in $Migration.PSObject.Properties.Name){return [int]$Migration.sourceGeneration}
    return 2
}

function Get-LabAiPersistentMigrationTargetGeneration {
    param($Migration)
    if($null -eq $Migration){return 3}
    if('targetGeneration' -in $Migration.PSObject.Properties.Name){return [int]$Migration.targetGeneration}
    return 3
}

function Get-LabAiPersistentMigrationDatasetMode {
    param($Migration)
    if($null -eq $Migration){return 'Fixture'}
    if('datasetMode' -in $Migration.PSObject.Properties.Name){return [string]$Migration.datasetMode}
    return 'Fixture'
}

function Get-LabAiPersistentMigrationSourceRevision {
    param($Migration)
    if($null -eq $Migration){return 'Delta'}
    if('sourceRevision' -in $Migration.PSObject.Properties.Name){return [string]$Migration.sourceRevision}
    return 'Delta'
}

function New-LabAiPersistentMigrationSourcePlan {
    param($Plan,$Journal,[int]$LocalPort)
    $migration=if('migration' -in $Journal.PSObject.Properties.Name){$Journal.migration}else{$null}
    $datasetMode=if($migration){Get-LabAiPersistentMigrationDatasetMode $migration}else{[string]$Plan.DatasetMode}
    if($datasetMode -ceq 'CallerSupplied'){
        return New-LabAiPersistentPlan -RunId $Plan.RunId -InstanceId $Plan.InstanceId -CollectionId $Plan.CollectionId -Action Apply -FixtureRevision Initial -QueryId backup -Documents $Plan.Documents -LocalPort $LocalPort -TimeoutSeconds $Plan.TimeoutSeconds
    }
    return New-LabAiPersistentPlan -RunId $Plan.RunId -InstanceId $Plan.InstanceId -CollectionId $Plan.CollectionId -Action Apply -FixtureRevision Delta -QueryId backup -LocalPort $LocalPort -TimeoutSeconds $Plan.TimeoutSeconds
}

function Get-LabAiPersistentMigrationIdentity {
    param($Journal,$Migration)
    $datasetMode=Get-LabAiPersistentMigrationDatasetMode $Migration
    $dataset=[pscustomobject]@{DatasetId=$(if($datasetMode -ceq 'CallerSupplied'){'persistent-retrieval-caller'}else{'persistent-retrieval-synthetic'});DatasetVersion='1.0';DatasetSha256=$Journal.datasetHash;ChunkingSha256=Get-LabAiPlanKey @{Contract='SqlServerLab.WholeDocumentChunk/1.0'}}
    $source=[pscustomobject]@{ModelKey=$Journal.modelBinding.ModelKey;Dimension=768;ModelIdentitySha256=$Journal.modelBinding.Digest}
    $target=[pscustomobject]@{ModelKey=$Migration.targetBinding.ModelKey;Dimension=768;ModelIdentitySha256=$Migration.targetBinding.Digest}
    $rebuild=New-LabAiReembeddingPlan -DatasetBinding $dataset -SourceModelBinding $source -TargetModelBinding $target -Chunk @($Migration.sourceChunks)
    if($datasetMode -ceq 'Fixture'){
        $identity=[ordered]@{Contract='SqlServerLab.AiPersistentMigration/2.0';Run=$Journal.runId;Scope=$Journal.scopeId;Instance=$Journal.instanceId;Collection=$Journal.collectionId;DatabaseGuid=$Journal.databaseGuid;BindingHash=$Journal.bindingHash;Operation=$Migration.operationId;RequestKey=$Migration.requestKey;SourceGeneration=2;TargetGeneration=3;SourcePlan=$Journal.planKey;SourceOperation=$Journal.operationId;SourceModel=$Journal.modelBinding;TargetModel=$Migration.targetBinding;SourceProfile=Get-LabAiPersistentProfile raw;TargetProfile=Get-LabAiPersistentProfile nomic-search;ReembeddingPlanKey=$rebuild.PlanKey}
    }else{
        $identity=[ordered]@{Contract='SqlServerLab.AiPersistentMigration/2.0';Run=$Journal.runId;Scope=$Journal.scopeId;Instance=$Journal.instanceId;Collection=$Journal.collectionId;DatabaseGuid=$Journal.databaseGuid;BindingHash=$Journal.bindingHash;Operation=$Migration.operationId;RequestKey=$Migration.requestKey;DatasetMode=$datasetMode;SourceGeneration=Get-LabAiPersistentMigrationSourceGeneration $Migration;TargetGeneration=Get-LabAiPersistentMigrationTargetGeneration $Migration;SourceRevision=Get-LabAiPersistentMigrationSourceRevision $Migration;SourcePlan=$Journal.planKey;SourceOperation=$Journal.operationId;SourceModel=$Journal.modelBinding;TargetModel=$Migration.targetBinding;SourceProfile=Get-LabAiPersistentProfile raw;TargetProfile=Get-LabAiPersistentProfile nomic-search;ReembeddingPlanKey=$rebuild.PlanKey}
    }
    [pscustomobject]@{PlanKey=Get-LabAiPlanKey $identity;ReembeddingPlanKey=$rebuild.PlanKey}
}

function Assert-LabAiPersistentMigrationJournal {
    param($Journal)
    $m=$Journal.migration
    $identity=Get-LabAiPersistentMigrationIdentity $Journal $m
    $datasetMode=Get-LabAiPersistentMigrationDatasetMode $m
    if($datasetMode -ceq 'Fixture'){
        $sourcePlan=New-LabAiPersistentPlan -RunId $Journal.runId -InstanceId $Journal.instanceId -CollectionId $Journal.collectionId -Action Apply -FixtureRevision Delta -QueryId backup -LocalPort $m.localPort -TimeoutSeconds 300
        $request=New-LabAiPersistentPlan -RunId $Journal.runId -InstanceId $Journal.instanceId -CollectionId $Journal.collectionId -Action Migrate -FixtureRevision Delta -QueryId backup -LocalPort $m.localPort -TimeoutSeconds 300 -TargetModelKey ollama-nomic-embed-text-v2-moe
        if($Journal.revision -cne 'Delta' -or $Journal.planKey -cne $sourcePlan.PlanKey -or $Journal.datasetHash -cne $sourcePlan.DatasetHash -or $m.requestKey -cne $request.PlanKey){throw 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT'}
        $documents=$sourcePlan.Documents
    }else{
        if($datasetMode -cne 'CallerSupplied' -or $Journal.revision -notin @('Initial','Managed') -or (Get-LabAiPersistentMigrationSourceRevision $m) -cne $Journal.revision){throw 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT'}
        $sourceGeneration=Get-LabAiPersistentMigrationSourceGeneration $m;$targetGeneration=Get-LabAiPersistentMigrationTargetGeneration $m
        if($sourceGeneration -lt 1 -or $sourceGeneration -gt 31 -or $targetGeneration -ne ($sourceGeneration+1) -or $targetGeneration -gt 32){throw 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT'}
        $endpoint=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $m.localPort -MaximumRequests 1 -RetryCount 0 -TimeoutSeconds 60
        $sourceIdentity=[ordered]@{Contract='SqlServerLab.AiPersistentRetrieval/1.0';RunId=$Journal.runId;InstanceId=$Journal.instanceId;CollectionId=$Journal.collectionId;Revision='Initial';DatasetHash=$Journal.datasetHash;EndpointPlanKey=$endpoint.PlanKey;DatasetMode='CallerSupplied'}
        $targetEndpoint=New-LabAiEndpointPlan -ModelKey ollama-nomic-embed-text-v2-moe -EndpointRef ollama-local -Lane local -LocalPort $m.localPort -MaximumRequests 1 -RetryCount 0 -TimeoutSeconds 60
        $requestIdentity=[ordered]@{Contract='SqlServerLab.AiPersistentMigration/2.0';RunId=$Journal.runId;InstanceId=$Journal.instanceId;CollectionId=$Journal.collectionId;Revision='Initial';DatasetHash=$Journal.datasetHash;EndpointPlanKey=$targetEndpoint.PlanKey;DatasetMode='CallerSupplied';ProfileHash=Get-LabAiPlanKey (Get-LabAiPersistentProfile nomic-search)}
        if($Journal.planKey -cne (Get-LabAiPlanKey $sourceIdentity) -or $m.requestKey -cne (Get-LabAiPlanKey $requestIdentity)){throw 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT'}
        $documents=@($m.sourceChunks|ForEach-Object{[pscustomobject]@{Id=$_.ChunkId;ContentHash=$_.ChunkSha256}})
        $datasetHash=Get-LabAiPlanKey @($documents|Sort-Object Id -CaseSensitive|ForEach-Object{[ordered]@{Id=$_.Id;Hash=$_.ContentHash}})
        if($Journal.datasetHash -cne $datasetHash){throw 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT'}
    }
    if($m.planKey -cne $identity.PlanKey -or $m.reembeddingPlanKey -cne $identity.ReembeddingPlanKey -or
        $m.sourceProfileHash -cne (Get-LabAiPlanKey (Get-LabAiPersistentProfile raw)) -or $m.targetProfileHash -cne (Get-LabAiPlanKey (Get-LabAiPersistentProfile nomic-search)) -or
        $m.targetModelHash -cne (Get-LabAiPlanKey $m.targetBinding)){throw 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT'}
    $seen=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($chunk in $m.sourceChunks){
        $doc=@($documents|Where-Object Id -CEQ $chunk.ChunkId)
        if(-not $seen.Add($chunk.ChunkId) -or $doc.Count -ne 1 -or $chunk.ChunkSha256 -cne $doc[0].ContentHash){throw 'AI_PERSISTENT_MIGRATION_JOURNAL_DRIFT'}
    }
}

function Get-LabAiPersistentMigrationReceipt {
    param($Context,$Journal)
    @(Invoke-LabAiPersistentSql $Context MigrationReceipt "IF OBJECT_ID(@receipt,N'U') IS NOT NULL SELECT Contract,UpgradeId,PlanKey,Receipt FROM [$($Journal.databaseName)].dbo.LabMigrationReceipt;" @{receipt="$($Journal.databaseName).dbo.LabMigrationReceipt"})
}

function Assert-LabAiPersistentMigrationReceipt {
    param([object[]]$Rows,$Journal)
    if($Rows.Count -ne 1 -or $Rows[0].Contract -cne 'SqlServerLab.AiPersistentSql/2.0' -or $Rows[0].UpgradeId -cne $Journal.migration.operationId -or $Rows[0].PlanKey -cne $Journal.migration.planKey){throw 'AI_PERSISTENT_MIGRATION_RECEIPT_DRIFT'}
    try{$receipt=$Rows[0].Receipt|ConvertFrom-Json -Depth 15 -ErrorAction Stop}catch{throw 'AI_PERSISTENT_MIGRATION_RECEIPT_DRIFT'}
    if((Get-LabAiPlanKey $receipt) -cne (Get-LabAiPlanKey $Journal.migration)){throw 'AI_PERSISTENT_MIGRATION_RECEIPT_DRIFT'}
}

function Assert-LabAiPersistentMigrationSource {
    param($Context,$Journal,$Plan,[int]$SourceGeneration=0)
    $migration=if('migration' -in $Journal.PSObject.Properties.Name){$Journal.migration}else{$null}
    $sourceGeneration=if($SourceGeneration -gt 0){$SourceGeneration}else{Get-LabAiPersistentMigrationSourceGeneration $migration}
    $generation=@(Get-LabAiPersistentGeneration $Context $Journal $sourceGeneration)
    if($generation.Count -ne 1 -or $generation[0].Status -cne 'COMMITTED' -or $generation[0].ModelHash -cne $Journal.modelHash -or $generation[0].DatasetHash -cne $Plan.DatasetHash -or $generation[0].PlanKey -cne $Journal.planKey -or $generation[0].OperationId -cne $Journal.operationId){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
    $sourceRevision=if($migration){Get-LabAiPersistentMigrationSourceRevision $migration}else{[string]$Journal.revision}
    if($generation[0].Revision -cne $sourceRevision){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
    $rows=@(Get-LabAiPersistentChunks $Context $Journal $sourceGeneration)
    Assert-LabAiPersistentChunks $rows $Plan.Documents -Complete
    if($Journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0'){
        foreach($row in $rows){$expected=@($Journal.migration.sourceChunks|Where-Object ChunkId -CEQ $row.ChunkId);if($expected.Count -ne 1 -or $expected[0].SourceVectorSha256 -cne $row.ActualVectorHash){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}}
    }
    return $rows
}

function Initialize-LabAiPersistentMigration {
    param($Context,$Journal)
    $name=$Journal.databaseName
    $sourceGeneration=Get-LabAiPersistentMigrationSourceGeneration $Journal.migration
    $null=Invoke-LabAiPersistentSql $Context Upgrade @"
SET XACT_ABORT ON;
BEGIN TRANSACTION;
IF NOT EXISTS(SELECT 1 FROM [$name].dbo.LabOwner WITH(UPDLOCK,HOLDLOCK) WHERE Singleton=1 AND OwnerToken=@token AND DatabaseGuid=@guid AND ActiveGeneration=@sourceGeneration) THROW 51000,'AI_PERSISTENT_CUTOVER_CONFLICT',1;
IF OBJECT_ID(@receiptName) IS NOT NULL THROW 51000,'AI_PERSISTENT_MIGRATION_RECEIPT_DRIFT',1;
IF NOT EXISTS(SELECT 1 FROM [$name].dbo.LabGenerations WITH(UPDLOCK,HOLDLOCK) WHERE Generation=@sourceGeneration AND Status='COMMITTED' AND PlanKey=@sourcePlan AND OperationId=@sourceOperation AND ModelHash=@sourceModel AND DatasetHash=@dataset AND Revision=@sourceRevision) THROW 51000,'AI_PERSISTENT_SOURCE_GENERATION_DRIFT',1;
CREATE TABLE [$name].dbo.LabMigrationReceipt(Singleton int NOT NULL PRIMARY KEY CHECK(Singleton=1),Contract varchar(64) NOT NULL,UpgradeId varchar(36) NOT NULL,PlanKey char(64) NOT NULL,Receipt nvarchar(max) NOT NULL CHECK(ISJSON(Receipt)=1));
INSERT [$name].dbo.LabMigrationReceipt VALUES(1,'SqlServerLab.AiPersistentSql/2.0',@operation,@plan,@receipt);
COMMIT;
"@ @{token=$Journal.ownerToken;guid=$Journal.databaseGuid;receiptName="$name.dbo.LabMigrationReceipt";sourceGeneration=$sourceGeneration;sourceRevision=Get-LabAiPersistentMigrationSourceRevision $Journal.migration;sourcePlan=$Journal.planKey;sourceOperation=$Journal.operationId;sourceModel=$Journal.modelHash;dataset=$Journal.datasetHash;operation=$Journal.migration.operationId;plan=$Journal.migration.planKey;receipt=($Journal.migration|ConvertTo-Json -Depth 15 -Compress)}
}

function Invoke-LabAiPersistentMigrationQuery {
    param($Context,$Plan,$Journal,$Owner,$Identity,[string]$StateRoot,[scriptblock]$MetadataTransport,[scriptblock]$EmbeddingTransport)
    $generation=[int]$Owner.ActiveGeneration
    $sourceGeneration=Get-LabAiPersistentMigrationSourceGeneration $Journal.migration
    $targetGeneration=Get-LabAiPersistentMigrationTargetGeneration $Journal.migration
    $datasetMode=Get-LabAiPersistentMigrationDatasetMode $Journal.migration
    if($generation -notin @($sourceGeneration,$targetGeneration)){throw 'AI_PERSISTENT_ACTIVE_GENERATION_MISSING'}
    $receipts=@(Get-LabAiPersistentMigrationReceipt $Context $Journal)
    if($receipts.Count){Assert-LabAiPersistentMigrationReceipt $receipts $Journal}
    elseif($Journal.status -cne 'UPGRADE_PENDING' -or $generation -ne $sourceGeneration){throw 'AI_PERSISTENT_MIGRATION_RECEIPT_MISSING'}
    if($datasetMode -ceq 'CallerSupplied'){
        if($Plan.DatasetMode -cne 'CallerSupplied' -or $Plan.DatasetHash -cne $Journal.datasetHash){throw 'AI_PERSISTENT_REQUEST_BINDING_DRIFT'}
        $active=$Plan.PSObject.Copy()
    }else{
        $active=New-LabAiPersistentPlan -RunId $Plan.RunId -InstanceId $Plan.InstanceId -CollectionId $Plan.CollectionId -Action Apply -FixtureRevision Delta -QueryId $Plan.QueryId -LocalPort $Journal.migration.localPort -TimeoutSeconds $Plan.TimeoutSeconds
    }
    $expected=$Journal.modelBinding;$expectedPlan=$Journal.planKey;$expectedOperation=$Journal.operationId;$profile=Get-LabAiPersistentProfile raw
    if($generation -eq $targetGeneration){
        $expected=$Journal.migration.targetBinding;$expectedPlan=$Journal.migration.planKey;$expectedOperation=$Journal.migration.operationId;$profile=Get-LabAiPersistentProfile nomic-search
        $active.EndpointPlan=New-LabAiEndpointPlan -ModelKey ollama-nomic-embed-text-v2-moe -EndpointRef ollama-local -Lane local -LocalPort $Journal.migration.localPort -MaximumRequests 1 -RetryCount 0 -TimeoutSeconds 60
    }
    $g=@(Get-LabAiPersistentGeneration $Context $Journal $generation)
    $expectedRevision=if($datasetMode -ceq 'CallerSupplied' -and $generation -eq $sourceGeneration){Get-LabAiPersistentMigrationSourceRevision $Journal.migration}elseif($datasetMode -ceq 'CallerSupplied'){'Managed'}else{'Delta'}
    if($g.Count -ne 1 -or $g[0].Status -cne 'COMMITTED' -or $g[0].ModelHash -cne (Get-LabAiPlanKey $expected) -or $g[0].PlanKey -cne $expectedPlan -or $g[0].OperationId -cne $expectedOperation -or $g[0].DatasetHash -cne $active.DatasetHash -or $g[0].Revision -cne $expectedRevision){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
    $chunks=@(Get-LabAiPersistentChunks $Context $Journal $generation)
    Assert-LabAiPersistentChunks $chunks $active.Documents -Complete
    if($generation -eq $sourceGeneration){
        foreach($chunk in $chunks){
            $source=@($Journal.migration.sourceChunks|Where-Object ChunkId -CEQ $chunk.ChunkId)
            if($source.Count -ne 1 -or $source[0].SourceVectorSha256 -cne $chunk.ActualVectorHash){throw 'AI_PERSISTENT_SOURCE_GENERATION_DRIFT'}
        }
    }
    $null=Get-LabAiPersistentModel $Context $active $MetadataTransport $expected
    $queryInput=$profile.QueryPrefix+$active.Question
    if($profile.Name -ceq 'nomic-search'){Assert-LabAiPersistentMigrationInput $queryInput}
    $embedding=Get-LabAiPersistentEmbedding $Context $active $queryInput $EmbeddingTransport
    $vector=ConvertTo-LabAiVectorLiteral -Vector @($embedding.Vector) -Dimension 768
    $null=Get-LabAiPersistentModel $Context $active $MetadataTransport $expected
    $null=Assert-LabTransferBinding -Expected $Identity -StateRoot $StateRoot
    $ranked=@(Invoke-LabAiPersistentSql $Context Query "DECLARE @v VECTOR(768)=CAST(@vector AS VECTOR(768));SELECT TOP(3) c.ChunkId,c.ContentHash,CONVERT(float,VECTOR_DISTANCE('cosine',@v,c.Embedding)) AS Distance FROM [$($Journal.databaseName)].dbo.LabChunks c JOIN [$($Journal.databaseName)].dbo.LabOwner o ON c.Generation=o.ActiveGeneration WHERE o.Singleton=1 AND o.ActiveGeneration=@generation ORDER BY VECTOR_DISTANCE('cosine',@v,c.Embedding),c.ChunkId;" @{vector=$vector;generation=$generation})
    $expectedCount=[Math]::Min(3,$active.Documents.Count)
    if($ranked.Count -ne $expectedCount -or @($ranked.ChunkId|Select-Object -Unique).Count -ne $expectedCount){throw 'AI_PERSISTENT_QUERY_INVALID'}
    foreach($row in $ranked){$doc=@($active.Documents|Where-Object Id -CEQ $row.ChunkId);if($doc.Count -ne 1 -or [string]$row.ContentHash -cne $doc[0].ContentHash -or [double]::IsNaN([double]$row.Distance) -or [double]::IsInfinity([double]$row.Distance)){throw 'AI_PERSISTENT_QUERY_INVALID'}}
    [pscustomobject]@{Status='QUERIED';CollectionId=$Plan.CollectionId;Generation=$generation;Revision=$expectedRevision;DatasetMode=$datasetMode;ModelKey=$expected.ModelKey;Profile=$profile.Name;Ranked=$ranked;EmbeddingRequests=$embedding.Attempts}
}

function Invoke-LabAiPersistentMigration {
    param($Context,$Plan,$Journal,$Owner,[string]$Path,$Identity,[string]$StateRoot,[scriptblock]$MetadataTransport,[scriptblock]$EmbeddingTransport,[scriptblock]$FaultInjector)
    if($Plan.Action -eq 'Apply'){throw 'AI_PERSISTENT_STALE_REVISION'}
    if($Journal.contract -ceq 'SqlServerLab.AiPersistentJournal/2.0' -and $Plan.EndpointPlan.Port -ne $Journal.migration.localPort){throw 'AI_PERSISTENT_RESUME_REQUEST_MISMATCH'}
    if($Plan.Action -eq 'Query'){return Invoke-LabAiPersistentMigrationQuery $Context $Plan $Journal $Owner $Identity $StateRoot $MetadataTransport $EmbeddingTransport}
    if($Plan.Action -ne 'Migrate'){throw 'AI_PERSISTENT_MIGRATION_REQUEST_INVALID'}
    if($Journal.contract -ceq 'SqlServerLab.AiPersistentJournal/1.0'){
        $sourceGeneration=[int]$Owner.ActiveGeneration;$targetGeneration=$sourceGeneration+1
        if($targetGeneration -gt 32){throw 'AI_PERSISTENT_GENERATION_LIMIT_REACHED'}
        if($Plan.Resume -or $Journal.status -cne 'COMMITTED' -or $Journal.activeGeneration -ne $sourceGeneration -or $sourceGeneration -lt 1){throw 'AI_PERSISTENT_MIGRATION_SOURCE_REQUIRED'}
        if(($Plan.DatasetMode -ceq 'Fixture' -and ($sourceGeneration -ne 2 -or $Journal.revision -cne 'Delta')) -or ($Plan.DatasetMode -ceq 'CallerSupplied' -and $Journal.revision -notin @('Initial','Managed'))){throw 'AI_PERSISTENT_MIGRATION_SOURCE_REQUIRED'}
        $rows=@(Assert-LabAiPersistentMigrationSource $Context $Journal $Plan $sourceGeneration)
        if(@(Get-LabAiPersistentMigrationReceipt $Context $Journal).Count){throw 'AI_PERSISTENT_MIGRATION_RECEIPT_DRIFT'}
        if(@(Get-LabAiPersistentGeneration $Context $Journal $targetGeneration).Count){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
        $sourcePlan=New-LabAiPersistentMigrationSourcePlan $Plan $Journal $Plan.EndpointPlan.Port
        $null=Get-LabAiPersistentModel $Context $sourcePlan $MetadataTransport $Journal.modelBinding
        $target=Get-LabAiPersistentModel $Context $Plan $MetadataTransport
        $migration=[pscustomobject][ordered]@{operationId=[guid]::NewGuid().ToString('D');localPort=$Plan.EndpointPlan.Port;requestKey=$Plan.PlanKey;planKey='';reembeddingPlanKey='';targetBinding=$target;targetModelHash=Get-LabAiPlanKey $target;sourceProfileHash=Get-LabAiPlanKey (Get-LabAiPersistentProfile raw);targetProfileHash=Get-LabAiPlanKey (Get-LabAiPersistentProfile nomic-search);sourceChunks=@($rows|Sort-Object ChunkId|ForEach-Object{[pscustomobject]@{ChunkId=$_.ChunkId;ChunkSha256=$_.ContentHash;SourceVectorSha256=$_.ActualVectorHash}})}
        if($Plan.DatasetMode -ceq 'CallerSupplied'){
            $migration|Add-Member -NotePropertyName datasetMode -NotePropertyValue 'CallerSupplied'
            $migration|Add-Member -NotePropertyName sourceGeneration -NotePropertyValue $sourceGeneration
            $migration|Add-Member -NotePropertyName targetGeneration -NotePropertyValue $targetGeneration
            $migration|Add-Member -NotePropertyName sourceRevision -NotePropertyValue $Journal.revision
        }
        $keys=Get-LabAiPersistentMigrationIdentity $Journal $migration;$migration.planKey=$keys.PlanKey;$migration.reembeddingPlanKey=$keys.ReembeddingPlanKey
        $Journal.contract='SqlServerLab.AiPersistentJournal/2.0';$Journal.status='UPGRADE_PENDING';$Journal.completedChunks=@()
        if('targetGeneration' -in $Journal.PSObject.Properties.Name){$Journal.PSObject.Properties.Remove('targetGeneration')}
        $Journal|Add-Member -NotePropertyName migration -NotePropertyValue $migration
        Write-LabAiPersistentJournal $Path $Journal
        if($FaultInjector){& $FaultInjector 'AfterUpgradeIntent' ''}
    }elseif($Journal.status -ne 'COMMITTED' -and -not $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUIRED'}
    $m=$Journal.migration
    $sourceGeneration=Get-LabAiPersistentMigrationSourceGeneration $m
    $targetGeneration=Get-LabAiPersistentMigrationTargetGeneration $m
    if($Plan.PlanKey -cne $m.requestKey){throw 'AI_PERSISTENT_RESUME_REQUEST_MISMATCH'}
    if($Owner.ActiveGeneration -eq $sourceGeneration){
        $sourcePlan=New-LabAiPersistentMigrationSourcePlan $Plan $Journal $m.localPort
        $null=Get-LabAiPersistentModel $Context $sourcePlan $MetadataTransport $Journal.modelBinding
    }
    $null=Assert-LabAiPersistentMigrationSource $Context $Journal $Plan
    $receipts=@(Get-LabAiPersistentMigrationReceipt $Context $Journal)
    if(-not $receipts.Count){
        if($Journal.status -cne 'UPGRADE_PENDING' -or $Owner.ActiveGeneration -ne $sourceGeneration){throw 'AI_PERSISTENT_MIGRATION_RECEIPT_MISSING'}
        if(@(Get-LabAiPersistentGeneration $Context $Journal $targetGeneration).Count){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
        $null=Get-LabAiPersistentModel $Context $Plan $MetadataTransport $m.targetBinding
        $null=Assert-LabTransferBinding -Expected $Identity -StateRoot $StateRoot
        Initialize-LabAiPersistentMigration $Context $Journal
        if($FaultInjector){& $FaultInjector 'AfterUpgradeSql' ''}
        $receipts=@(Get-LabAiPersistentMigrationReceipt $Context $Journal)
    }
    Assert-LabAiPersistentMigrationReceipt $receipts $Journal
    $null=Get-LabAiPersistentModel $Context $Plan $MetadataTransport $m.targetBinding
    $generation=@(Get-LabAiPersistentGeneration $Context $Journal $targetGeneration)
    if($generation.Count){
        $g=$generation[0]
        if($generation.Count -ne 1 -or $g.OperationId -cne $m.operationId -or $g.PlanKey -cne $m.planKey -or $g.ModelHash -cne $m.targetModelHash -or $g.DatasetHash -cne $Plan.DatasetHash -or $g.Revision -cne $Plan.Revision){throw 'AI_PERSISTENT_GENERATION_DRIFT'}
        if($g.Status -ceq 'COMMITTED' -and $Owner.ActiveGeneration -eq $targetGeneration){
            Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $Context $Journal $targetGeneration) $Plan.Documents -Complete
            $Journal.status='COMMITTED';$Journal.activeGeneration=$targetGeneration;Write-LabAiPersistentJournal $Path $Journal
            return [pscustomobject]@{Status='COMMITTED';CollectionId=$Plan.CollectionId;Generation=$targetGeneration;DatasetMode=$Plan.DatasetMode;EmbeddingRequests=0;CopiedChunks=0}
        }
        if($g.Status -cne 'STAGING' -or -not $Plan.Resume){throw 'AI_PERSISTENT_RESUME_REQUIRED'}
    }else{
        if($Owner.ActiveGeneration -ne $sourceGeneration){throw 'AI_PERSISTENT_CUTOVER_CONFLICT'}
        $Journal.status='STAGING';Write-LabAiPersistentJournal $Path $Journal
        $null=Invoke-LabAiPersistentSql $Context Stage "INSERT [$($Journal.databaseName)].dbo.LabGenerations VALUES(@generation,@operation,@plan,@revision,@dataset,@model,'STAGING');" @{generation=$targetGeneration;operation=$m.operationId;plan=$m.planKey;revision=$Plan.Revision;dataset=$Plan.DatasetHash;model=$m.targetModelHash}
    }
    $Journal.status='STAGING';Write-LabAiPersistentJournal $Path $Journal
    if($Owner.ActiveGeneration -ne $sourceGeneration){throw 'AI_PERSISTENT_CUTOVER_CONFLICT'}
    $rows=@(Get-LabAiPersistentChunks $Context $Journal $targetGeneration);Assert-LabAiPersistentChunks $rows $Plan.Documents
    $requests=0;$profile=Get-LabAiPersistentProfile nomic-search
    foreach($document in $Plan.Documents){
        if($document.Id -cin $rows.ChunkId){continue}
        $null=Assert-LabTransferBinding -Expected $Identity -StateRoot $StateRoot
        $null=Get-LabAiPersistentModel $Context $Plan $MetadataTransport $m.targetBinding
        $documentInput=$profile.DocumentPrefix+$document.Content;Assert-LabAiPersistentMigrationInput $documentInput
        $embedding=Get-LabAiPersistentEmbedding $Context $Plan $documentInput $EmbeddingTransport;$requests+=$embedding.Attempts
        $vector=ConvertTo-LabAiVectorLiteral -Vector @($embedding.Vector) -Dimension 768
        $null=Get-LabAiPersistentModel $Context $Plan $MetadataTransport $m.targetBinding
        $null=Invoke-LabAiPersistentSql $Context Insert "DECLARE @v VECTOR(768)=CAST(@vector AS VECTOR(768));INSERT [$($Journal.databaseName)].dbo.LabChunks VALUES(@generation,@id,@content,@hash,@v,LOWER(CONVERT(char(64),HASHBYTES('SHA2_256',CAST(@v AS varchar(max))),2)));" @{generation=$targetGeneration;id=$document.Id;content=$document.Content;hash=$document.ContentHash;vector=$vector}
        if($FaultInjector){& $FaultInjector 'AfterChunkSql' $document.Id}
        $rows=@(Get-LabAiPersistentChunks $Context $Journal $targetGeneration);Assert-LabAiPersistentChunks $rows $Plan.Documents
        $Journal.completedChunks=@($rows.ChunkId);Write-LabAiPersistentJournal $Path $Journal
    }
    Assert-LabAiPersistentChunks @(Get-LabAiPersistentChunks $Context $Journal $targetGeneration) $Plan.Documents -Complete
    $null=Get-LabAiPersistentModel $Context $Plan $MetadataTransport $m.targetBinding
    $null=Assert-LabTransferBinding -Expected $Identity -StateRoot $StateRoot
    $null=Get-LabAiPersistentModel $Context $sourcePlan $MetadataTransport $Journal.modelBinding
    $null=Assert-LabAiPersistentOwner $Context $Journal
    $targetJournal=$Journal.PSObject.Copy();$targetJournal.modelHash=$m.targetModelHash;$targetJournal.operationId=$m.operationId
    $targetPlan=$Plan.PSObject.Copy();$targetPlan.Generation=$targetGeneration;$targetPlan.PlanKey=$m.planKey
    Complete-LabAiPersistentGeneration $Context $targetJournal $targetPlan $sourceGeneration -MigrationJournal $Journal
    if($FaultInjector){& $FaultInjector 'AfterCommitSql' ''}
    $Journal.status='COMMITTED';$Journal.activeGeneration=$targetGeneration;Write-LabAiPersistentJournal $Path $Journal
    [pscustomobject]@{Status='COMMITTED';CollectionId=$Plan.CollectionId;Generation=$targetGeneration;DatasetMode=$Plan.DatasetMode;EmbeddingRequests=$requests;CopiedChunks=0}
}
