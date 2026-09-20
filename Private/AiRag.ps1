<#
.SYNOPSIS
    SQL-zentrierte, flüchtige RAG-Orchestrierung für lokale Ollama-Modelle.
#>

function ConvertTo-LabAiVectorLiteral {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Vector,[Parameter(Mandatory)][int]$Dimension)

    if ($Vector.Count -ne $Dimension) { throw 'AI_RAG_VECTOR_DIMENSION_MISMATCH' }
    $values=[Collections.Generic.List[string]]::new()
    foreach($value in $Vector) {
        try { $number=[Convert]::ToDouble($value,[Globalization.CultureInfo]::InvariantCulture) }
        catch { throw 'AI_RAG_VECTOR_VALUE_INVALID' }
        if ([double]::IsNaN($number) -or [double]::IsInfinity($number)) { throw 'AI_RAG_VECTOR_VALUE_INVALID' }
        $values.Add($number.ToString('R',[Globalization.CultureInfo]::InvariantCulture))
    }
    return '[' + ($values -join ',') + ']'
}

function New-LabAiRagPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string]$Question,
        [Parameter(Mandatory)][object[]]$Document,
        [Parameter(Mandatory)][string]$EmbeddingModelKey,
        [Parameter(Mandatory)][string]$GenerationModelKey,
        [Parameter(Mandatory)][int]$LocalPort,
        [Parameter(Mandatory)][int]$TopK,
        [AllowNull()]$EvaluationBinding,
        [ValidateSet('local','cloud')][string]$GenerationLane='local',
        [switch]$AllowCloudEgress,
        [ValidateSet('synthetic-only','public-or-redistributable','internal-explicit')][string]$DataClassification,
        [ValidateRange(1,230)][int]$GenerationTimeoutSeconds=60,
        [ValidateRange(0,1)][int]$GenerationRetryCount=1
    )

    if ($Document.Count -lt 1 -or $Document.Count -gt 20) { throw 'AI_RAG_DOCUMENT_COUNT_INVALID' }
    if ($Question.Length -gt 8192) { throw 'AI_RAG_QUESTION_TOO_LONG' }
    $normalized=[Collections.Generic.List[object]]::new()
    $ids=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach($item in $Document) {
        $id=[string]$item.Id;$content=[string]$item.Content
        if ($id -notmatch '^[a-z][a-z0-9-]{2,95}$') { throw 'AI_RAG_DOCUMENT_ID_INVALID' }
        if (-not $ids.Add($id)) { throw 'AI_RAG_DOCUMENT_ID_DUPLICATE' }
        if ([string]::IsNullOrWhiteSpace($content) -or $content.Length -gt 8192) { throw 'AI_RAG_DOCUMENT_CONTENT_INVALID' }
        $normalized.Add([PSCustomObject]@{Id=$id;Content=$content;ContentHash=Get-LabAiSha256Text -Text $content})
    }
    if ($TopK -gt $normalized.Count) { throw 'AI_RAG_TOP_K_EXCEEDS_DOCUMENT_COUNT' }
    $embeddingPlan=New-LabAiEndpointPlan -ModelKey $EmbeddingModelKey -EndpointRef ollama-local -Lane local -LocalPort $LocalPort -MaximumRequests 2 -RetryCount 1
    if($GenerationLane -eq 'cloud' -and $DataClassification -notin @('synthetic-only','public-or-redistributable')){throw 'AI_RAG_DATA_CLASSIFICATION_REQUIRED'}
    if($GenerationLane -eq 'local' -and $AllowCloudEgress){throw 'AI_RAG_CLOUD_EGRESS_UNEXPECTED'}
    $generationRef=if($GenerationLane -eq 'cloud'){'ollama-cloud'}else{'ollama-local'}
    $generationPlan=New-LabAiEndpointPlan -ModelKey $GenerationModelKey -EndpointRef $generationRef -Lane $GenerationLane -LocalPort $LocalPort -MaximumRequests (1+$GenerationRetryCount) -RetryCount $GenerationRetryCount -TimeoutSeconds $GenerationTimeoutSeconds -AllowCloudEgress:$AllowCloudEgress
    if ($embeddingPlan.Purpose -ne 'embedding' -or $generationPlan.Purpose -ne 'generation') { throw 'AI_RAG_MODEL_PURPOSE_INVALID' }
    if ($embeddingPlan.Status -eq 'BLOCKED' -or $generationPlan.Status -eq 'BLOCKED') { throw 'AI_RAG_ENDPOINT_PLAN_BLOCKED' }
    $normalizedBinding = $null
    if ($null -ne $EvaluationBinding) {
        if ([string]$EvaluationBinding.DatasetId -notmatch '^[a-z][a-z0-9-]{2,63}$' -or
            [string]$EvaluationBinding.DatasetVersion -notmatch '^[1-9][0-9]*\.[0-9]+$' -or
            [string]$EvaluationBinding.DatasetHash -notmatch '^[a-f0-9]{64}$' -or
            [string]$EvaluationBinding.CaseId -notmatch '^[a-z][a-z0-9-]{2,63}$') {
            throw 'AI_RAG_EVALUATION_BINDING_INVALID'
        }
        $normalizedBinding = [PSCustomObject]@{
            DatasetId = [string]$EvaluationBinding.DatasetId
            DatasetVersion = [string]$EvaluationBinding.DatasetVersion
            DatasetHash = [string]$EvaluationBinding.DatasetHash
            CaseId = [string]$EvaluationBinding.CaseId
        }
    }
    $identity=[ordered]@{Contract='SqlServerLab.AiRagPlan/1.0';RunId=$RunId;InstanceId=$InstanceId;QuestionHash=Get-LabAiSha256Text -Text $Question;Documents=@($normalized|ForEach-Object{[ordered]@{Id=$_.Id;ContentHash=$_.ContentHash}});EmbeddingPlanKey=$embeddingPlan.PlanKey;GenerationPlanKey=$generationPlan.PlanKey;TopK=$TopK}
    if ($null -ne $normalizedBinding) { $identity.EvaluationBinding = $normalizedBinding }
    $hostValidation=$EmbeddingModelKey -eq 'ollama-embeddinggemma-latest' -or $GenerationLane -eq 'cloud'
    if($hostValidation){$identity.HostModelValidation='LIVE_LOCAL_IDENTITY';$identity.DataClassification=$DataClassification}
    [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiRagPlan';Version='1.0'};Status='READY';RunId=$RunId;InstanceId=$InstanceId;ScenarioId='rag-local-vector';TopK=$TopK;DocumentCount=$normalized.Count;EmbeddingModelKey=$EmbeddingModelKey;GenerationModelKey=$GenerationModelKey;PlanKey=Get-LabAiPlanKey -InputObject $identity;EvaluationBinding=$normalizedBinding;Documents=@($normalized);EmbeddingPlan=$embeddingPlan;GenerationPlan=$generationPlan;HostModelValidation=$hostValidation;DataClassification=$DataClassification}
}

function Invoke-LabAiRag {
    [CmdletBinding()]
    param($Plan,[SecureString]$SaPassword,$Target,[string]$Question,[scriptblock]$EmbeddingTransport,[scriptblock]$GenerationTransport,[scriptblock]$SqlExecutor,[SecureString]$GenerationCredential,[scriptblock]$MetadataTransport)

    if (($Target.Version -split '-',2)[0] -ne '2025') { throw 'AI_RAG_SQL_VERSION_UNSUPPORTED' }
    if ([string]$Target.Provider -notin @('docker','podman','hyperv')) { throw 'AI_RAG_PROVIDER_UNSUPPORTED' }
    if($Plan.GenerationPlan.Lane -eq 'cloud' -and -not $GenerationCredential){throw 'AI_ENDPOINT_CREDENTIAL_MISSING'}
    $hostBinding=$null
    if($Plan.HostModelValidation){
        $hostBinding=Get-LabAiHostModelBinding -Plan $Plan.EmbeddingPlan -MetadataTransport $MetadataTransport
        if($Plan.GenerationPlan.Lane -eq 'local'){$generationBinding=Get-LabAiHostModelBinding -Plan $Plan.GenerationPlan -MetadataTransport $MetadataTransport}
    }
    $timer=[Diagnostics.Stopwatch]::StartNew();$requests=0
    $rows=[Collections.Generic.List[string]]::new()
    foreach($document in $Plan.Documents) {
        if($hostBinding){Assert-LabAiHostModelBinding -Plan $Plan.EmbeddingPlan -Expected $hostBinding -MetadataTransport $MetadataTransport}
        $result=Invoke-LabAiEndpointRequest -Plan $Plan.EmbeddingPlan -InputText $document.Content -Transport $EmbeddingTransport
        $requests += $result.Attempts
        $literal=ConvertTo-LabAiVectorLiteral -Vector @($result.Vector) -Dimension ([int]$Plan.EmbeddingPlan.Dimension)
        $rows.Add("(N'$($document.Id)',CAST('$literal' AS VECTOR($($Plan.EmbeddingPlan.Dimension))))")
    }
    if($hostBinding){Assert-LabAiHostModelBinding -Plan $Plan.EmbeddingPlan -Expected $hostBinding -MetadataTransport $MetadataTransport}
    $queryResult=Invoke-LabAiEndpointRequest -Plan $Plan.EmbeddingPlan -InputText $Question -Transport $EmbeddingTransport
    $requests += $queryResult.Attempts
    $queryLiteral=ConvertTo-LabAiVectorLiteral -Vector @($queryResult.Vector) -Dimension ([int]$Plan.EmbeddingPlan.Dimension)
    if($hostBinding){Assert-LabAiHostModelBinding -Plan $Plan.EmbeddingPlan -Expected $hostBinding -MetadataTransport $MetadataTransport}
    $sql="SET NOCOUNT ON; DECLARE @docs TABLE(DocumentId nvarchar(96) PRIMARY KEY, Embedding VECTOR($($Plan.EmbeddingPlan.Dimension)) NOT NULL); INSERT INTO @docs VALUES $($rows -join ','); DECLARE @query VECTOR($($Plan.EmbeddingPlan.Dimension))=CAST('$queryLiteral' AS VECTOR($($Plan.EmbeddingPlan.Dimension))); SELECT CONCAT('AI_RAG_ROW|',DocumentId,'|',CONVERT(varchar(64),VECTOR_DISTANCE('cosine',@query,Embedding),2)) FROM @docs ORDER BY VECTOR_DISTANCE('cosine',@query,Embedding),DocumentId OFFSET 0 ROWS FETCH NEXT $($Plan.TopK) ROWS ONLY;"
    if ($SqlExecutor) { $output=@(& $SqlExecutor $sql) }
    else {
        $plain=ConvertFrom-LabSecureString -SecureString $SaPassword
        try { $output=@(Invoke-SqlQuery -HostName $Target.HostName -Port $Target.Port -SaPlain $plain -Query $sql -TimeoutSeconds 60) }
        finally { $plain=$null }
    }
    $ranked=@($output|ForEach-Object{if(([string]$_) -match '^AI_RAG_ROW\|([a-z][a-z0-9-]{2,95})\|([-+0-9.eE]+)$'){[PSCustomObject]@{Id=$Matches[1];Distance=[double]::Parse($Matches[2],[Globalization.CultureInfo]::InvariantCulture)}}}|Where-Object{$_})
    if ($ranked.Count -ne $Plan.TopK) { throw 'AI_RAG_SQL_RESULT_INVALID' }
    if(@($ranked.Id|Select-Object -Unique).Count -ne $ranked.Count){throw 'AI_RAG_SQL_RESULT_INVALID'}
    foreach($row in $ranked){if($row.Id -cnotin @($Plan.Documents.Id) -or [double]::IsNaN($row.Distance) -or [double]::IsInfinity($row.Distance)){throw 'AI_RAG_SQL_RESULT_INVALID'}}
    $context=@($ranked|ForEach-Object{$id=$_.Id;$doc=@($Plan.Documents|Where-Object Id -CEQ $id)[0];"[$id] $($doc.Content)"}) -join "`n"
    $prompt="Beantworte die Frage ausschließlich anhand des Kontexts. Zitiere verwendete Quellen als [document-id]. Wenn der Kontext nicht genügt, sage das ausdrücklich.`nFrage: $Question`nKontext:`n$context"
    if($hostBinding -and $Plan.GenerationPlan.Lane -eq 'local'){Assert-LabAiHostModelBinding -Plan $Plan.GenerationPlan -Expected $generationBinding -MetadataTransport $MetadataTransport}
    $answer=Invoke-LabAiEndpointRequest -Plan $Plan.GenerationPlan -InputText $prompt -Transport $GenerationTransport -Credential $GenerationCredential
    if($hostBinding -and $Plan.GenerationPlan.Lane -eq 'local'){Assert-LabAiHostModelBinding -Plan $Plan.GenerationPlan -Expected $generationBinding -MetadataTransport $MetadataTransport}
    $requests += $answer.Attempts;$timer.Stop()
    $queryResult = [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiQueryResult';Version='1.0'};Status='SUCCEEDED';Mode='Rag';RunId=$Plan.RunId;InstanceId=$Plan.InstanceId;ScenarioId=$Plan.ScenarioId;PlanKey=$Plan.PlanKey;ModelKey=$Plan.GenerationModelKey;Answer=$answer.Text;Citations=@($ranked.Id);ToolExecutions=@([PSCustomObject]@{ToolId='sql-vector-search';Status='SUCCEEDED';RowCount=$ranked.Count});Metrics=[PSCustomObject]@{RequestCount=$requests;LatencyMilliseconds=[int]$timer.ElapsedMilliseconds}}
    if ($null -ne $Plan.EvaluationBinding) {
        $queryResult | Add-Member -NotePropertyName EvaluationBinding -NotePropertyValue $Plan.EvaluationBinding
    }
    if($hostBinding){
        $queryResult|Add-Member -NotePropertyName HostEmbeddingBinding -NotePropertyValue $hostBinding
        $executionIdentity=[ordered]@{PlanKey=$Plan.PlanKey;HostEmbeddingBinding=$hostBinding}
        if($Plan.GenerationPlan.Lane -eq 'local'){$executionIdentity.HostGenerationBinding=$generationBinding}
        $queryResult|Add-Member -NotePropertyName ExecutionKey -NotePropertyValue (Get-LabAiPlanKey -InputObject $executionIdentity)
    }
    return $queryResult
}
