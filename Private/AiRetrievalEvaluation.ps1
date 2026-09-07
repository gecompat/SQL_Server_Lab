<#
.SYNOPSIS
    Deterministische Retrieval-Metriken für SQL-zentrierte RAG-Szenarien.
#>
function Measure-LabAiRetrieval {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateNotNullOrEmpty()][string[]]$ExpectedDocumentId,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$RankedDocumentId,
        [ValidateRange(1,100)][int]$K = 5,
        [ValidateRange(0,1)][double]$MinimumRecall = 1,
        [ValidateRange(0,1)][double]$MinimumMrr = 1,
        [ValidateRange(0,1)][double]$MinimumNdcg = 1
    )

    $expected=@($ExpectedDocumentId | ForEach-Object { [string]$_ } | Select-Object -Unique)
    $ranked=@($RankedDocumentId | ForEach-Object { [string]$_ })
    if ($expected.Count -ne $ExpectedDocumentId.Count) { throw 'AI_EVALUATION_EXPECTED_ID_DUPLICATE' }
    if (@($ranked | Select-Object -Unique).Count -ne $ranked.Count) { throw 'AI_EVALUATION_RANKED_ID_DUPLICATE' }
    if (@($expected | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' }).Count) { throw 'AI_EVALUATION_DOCUMENT_ID_INVALID' }
    if (@($ranked | Where-Object { $_ -notmatch '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' }).Count) { throw 'AI_EVALUATION_DOCUMENT_ID_INVALID' }

    $top=@($ranked | Select-Object -First $K)
    $hits=@($top | Where-Object { $expected -ccontains $_ }).Count
    $recall=[double]$hits/[double]$expected.Count
    $precision=[double]$hits/[double]$K
    $firstRank=0
    $dcg=0.0
    for($index=0;$index -lt $top.Count;$index++) {
        if ($expected -ccontains $top[$index]) {
            if ($firstRank -eq 0) { $firstRank=$index+1 }
            $dcg += 1.0/[Math]::Log($index+2,2)
        }
    }
    $mrr=if($firstRank){1.0/[double]$firstRank}else{0.0}
    $idealCount=[Math]::Min($expected.Count,$K)
    $idcg=0.0
    for($index=0;$index -lt $idealCount;$index++) { $idcg += 1.0/[Math]::Log($index+2,2) }
    $ndcg=if($idcg -gt 0){$dcg/$idcg}else{0.0}
    $blockers=[Collections.Generic.List[string]]::new()
    if($recall -lt $MinimumRecall){$blockers.Add('AI_EVALUATION_RECALL_BELOW_THRESHOLD')}
    if($mrr -lt $MinimumMrr){$blockers.Add('AI_EVALUATION_MRR_BELOW_THRESHOLD')}
    if($ndcg -lt $MinimumNdcg){$blockers.Add('AI_EVALUATION_NDCG_BELOW_THRESHOLD')}

    return [PSCustomObject]@{
        Contract=[PSCustomObject]@{Name='SqlServerLab.AiRetrievalEvaluation';Version='1.0'}
        Status=if($blockers.Count){'BLOCKED'}else{'PASSED'};K=$K
        ExpectedCount=$expected.Count;ReturnedCount=$top.Count;RelevantCount=$hits
        RecallAtK=[Math]::Round($recall,6);PrecisionAtK=[Math]::Round($precision,6)
        Mrr=[Math]::Round($mrr,6);NdcgAtK=[Math]::Round($ndcg,6)
        Thresholds=[PSCustomObject]@{MinimumRecall=$MinimumRecall;MinimumMrr=$MinimumMrr;MinimumNdcg=$MinimumNdcg}
        Blockers=@($blockers)
    }
}

function Read-LabAiRetrievalGoldenDataset {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$DatasetId,
        [Parameter(Mandatory)][ValidatePattern('^[1-9][0-9]*\.[0-9]+$')][string]$Version
    )

    $datasetPath = Join-Path (Join-Path (Join-Path (Get-LabAiScenarioRoot) 'rag-local-vector') $Version) 'golden-dataset.json'
    if (-not (Test-Path -LiteralPath $datasetPath -PathType Leaf)) {
        throw "AI_GOLDEN_DATASET_NOT_FOUND: $DatasetId/$Version"
    }
    $raw = Get-Content -LiteralPath $datasetPath -Raw -Encoding utf8
    $schemaPath = Join-Path $script:SchemasPath 'ai-retrieval-golden-dataset.schema.json'
    if (-not (Test-Json -Json $raw -SchemaFile $schemaPath -ErrorAction SilentlyContinue)) {
        throw "AI_GOLDEN_DATASET_SCHEMA_INVALID: $DatasetId/$Version"
    }
    $dataset = $raw | ConvertFrom-Json -Depth 30
    if ([string]$dataset.id -cne $DatasetId -or [string]$dataset.version -cne $Version) {
        throw "AI_GOLDEN_DATASET_IDENTITY_MISMATCH: $DatasetId/$Version"
    }

    $documentIds = @($dataset.documents | ForEach-Object { [string]$_.id })
    $caseIds = @($dataset.cases | ForEach-Object { [string]$_.id })
    if (@($documentIds | Select-Object -Unique).Count -ne $documentIds.Count) { throw 'AI_GOLDEN_DATASET_DOCUMENT_ID_DUPLICATE' }
    if (@($caseIds | Select-Object -Unique).Count -ne $caseIds.Count) { throw 'AI_GOLDEN_DATASET_CASE_ID_DUPLICATE' }
    foreach ($case in @($dataset.cases)) {
        if ([int]$case.topK -gt $documentIds.Count) { throw "AI_GOLDEN_DATASET_TOP_K_INVALID: $($case.id)" }
        if (@($case.expectedDocumentIds | Where-Object { $documentIds -cnotcontains [string]$_ }).Count -gt 0) {
            throw "AI_GOLDEN_DATASET_EXPECTED_DOCUMENT_UNKNOWN: $($case.id)"
        }
    }

    return [PSCustomObject]@{
        Dataset = $dataset
        DatasetHash = Get-LabAiArtifactSha256 -Path $datasetPath
    }
}

function Get-LabAiRetrievalGoldenCase {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$GoldenDataset,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]{2,63}$')][string]$CaseId
    )

    $matches = @($GoldenDataset.Dataset.cases | Where-Object { [string]$_.id -ceq $CaseId })
    if ($matches.Count -ne 1) { throw "AI_GOLDEN_DATASET_CASE_NOT_FOUND: $CaseId" }
    return $matches[0]
}

function Measure-LabAiGoldenRagResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$QueryResult,
        [Parameter(Mandatory)][string]$DatasetId,
        [Parameter(Mandatory)][string]$DatasetVersion,
        [Parameter(Mandatory)][string]$CaseId
    )

    $queryResultJson = $QueryResult | ConvertTo-Json -Depth 30 -Compress
    if (-not ($queryResultJson | Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-query-result.schema.json') -ErrorAction SilentlyContinue) -or
        [string]$QueryResult.Contract.Name -cne 'SqlServerLab.AiQueryResult' -or
        [string]$QueryResult.Contract.Version -cne '1.0' -or [string]$QueryResult.Mode -cne 'Rag' -or
        [string]$QueryResult.Status -cne 'SUCCEEDED') {
        throw 'AI_EVALUATION_QUERY_RESULT_INVALID'
    }
    $golden = Read-LabAiRetrievalGoldenDataset -DatasetId $DatasetId -Version $DatasetVersion
    $case = Get-LabAiRetrievalGoldenCase -GoldenDataset $golden -CaseId $CaseId
    $binding = $QueryResult.EvaluationBinding
    if ($null -eq $binding -or [string]$binding.DatasetId -cne $DatasetId -or
        [string]$binding.DatasetVersion -cne $DatasetVersion -or
        [string]$binding.DatasetHash -cne [string]$golden.DatasetHash -or
        [string]$binding.CaseId -cne $CaseId -or
        [string]$QueryResult.ScenarioId -cne [string]$golden.Dataset.scenarioId) {
        throw 'AI_EVALUATION_GOLDEN_BINDING_MISMATCH'
    }
    if (@($QueryResult.Citations).Count -ne [int]$case.topK) { throw 'AI_EVALUATION_RANKING_COUNT_MISMATCH' }

    $evaluation = Measure-LabAiRetrieval -ExpectedDocumentId @($case.expectedDocumentIds) `
        -RankedDocumentId @($QueryResult.Citations) -K ([int]$case.topK) `
        -MinimumRecall ([double]$case.thresholds.minimumRecall) `
        -MinimumMrr ([double]$case.thresholds.minimumMrr) `
        -MinimumNdcg ([double]$case.thresholds.minimumNdcg)
    $evaluation | Add-Member -NotePropertyName Binding -NotePropertyValue ([PSCustomObject]@{
        DatasetId = $DatasetId
        DatasetVersion = $DatasetVersion
        DatasetHash = [string]$golden.DatasetHash
        CaseId = $CaseId
        RunId = [string]$QueryResult.RunId
        ScenarioId = [string]$QueryResult.ScenarioId
        PlanKey = [string]$QueryResult.PlanKey
        ModelKey = [string]$QueryResult.ModelKey
    })
    return $evaluation
}
