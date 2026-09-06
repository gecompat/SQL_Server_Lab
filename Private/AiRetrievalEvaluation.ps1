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
