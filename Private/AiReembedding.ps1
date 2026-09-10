<#
.SYNOPSIS
    Rein lesender Vertrag für deterministische Re-Embedding-Rebuild-Pläne.
.DESCRIPTION
    Bindet ausschliesslich bereits ermittelte, sanitierte Identitäten. Diese
    Funktionen kontaktieren weder Provider noch Modell oder Netzwerk und
    schreiben kein Journal. Ein späterer Executor muss den PlanKey und die
    vollständige Zielmenge vor einer Umschaltung erneut prüfen.
#>

function ConvertTo-LabAiReembeddingModelBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding)

    $modelKey = [string]$Binding.ModelKey
    $digest = [string]$Binding.ModelIdentitySha256
    $dimension = [int]$Binding.Dimension
    if ($modelKey -notmatch '^[a-z][a-z0-9-]{2,95}$' -or $digest -notmatch '^[a-fA-F0-9]{64}$' -or $dimension -lt 1 -or $dimension -gt 1998) {
        throw 'AI_REEMBEDDING_MODEL_BINDING_INVALID'
    }
    return [PSCustomObject]@{ ModelKey=$modelKey; Dimension=$dimension; ModelIdentitySha256=$digest.ToLowerInvariant() }
}

function ConvertTo-LabAiReembeddingDatasetBinding {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Binding)

    $datasetId = [string]$Binding.DatasetId
    $version = [string]$Binding.DatasetVersion
    $datasetSha = [string]$Binding.DatasetSha256
    $chunkingSha = [string]$Binding.ChunkingSha256
    if ($datasetId -notmatch '^[a-z][a-z0-9-]{2,63}$' -or $version -notmatch '^[1-9][0-9]*\.[0-9]+$' -or
        $datasetSha -notmatch '^[a-fA-F0-9]{64}$' -or $chunkingSha -notmatch '^[a-fA-F0-9]{64}$') {
        throw 'AI_REEMBEDDING_DATASET_BINDING_INVALID'
    }
    return [PSCustomObject]@{ DatasetId=$datasetId; DatasetVersion=$version; DatasetSha256=$datasetSha.ToLowerInvariant(); ChunkingSha256=$chunkingSha.ToLowerInvariant() }
}

function ConvertTo-LabAiReembeddingChunks {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object[]]$Chunk)

    if ($Chunk.Count -lt 1) { throw 'AI_REEMBEDDING_CHUNK_SET_EMPTY' }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $normalized = [Collections.Generic.List[object]]::new()
    foreach ($item in $Chunk) {
        $id = [string]$item.ChunkId
        $chunkSha = [string]$item.ChunkSha256
        $vectorSha = [string]$item.SourceVectorSha256
        if ($id -notmatch '^[a-z][a-z0-9-]{2,95}$' -or $chunkSha -notmatch '^[a-fA-F0-9]{64}$' -or $vectorSha -notmatch '^[a-fA-F0-9]{64}$') {
            throw 'AI_REEMBEDDING_CHUNK_IDENTITY_INVALID'
        }
        if (-not $seen.Add($id)) { throw "AI_REEMBEDDING_CHUNK_DUPLICATE: $id" }
        $normalized.Add([PSCustomObject]@{ ChunkId=$id; ChunkSha256=$chunkSha.ToLowerInvariant(); SourceVectorSha256=$vectorSha.ToLowerInvariant() })
    }
    return @($normalized | Sort-Object ChunkId)
}

function New-LabAiReembeddingPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$DatasetBinding,
        [Parameter(Mandatory)]$SourceModelBinding,
        [Parameter(Mandatory)]$TargetModelBinding,
        [Parameter(Mandatory)][object[]]$Chunk,
        $ResumeJournal
    )

    $dataset = ConvertTo-LabAiReembeddingDatasetBinding -Binding $DatasetBinding
    $source = ConvertTo-LabAiReembeddingModelBinding -Binding $SourceModelBinding
    $target = ConvertTo-LabAiReembeddingModelBinding -Binding $TargetModelBinding
    $chunks = ConvertTo-LabAiReembeddingChunks -Chunk $Chunk
    if ($source.ModelKey -ceq $target.ModelKey -and $source.Dimension -ne $target.Dimension) {
        throw 'AI_REEMBEDDING_MODEL_DIMENSION_CONFLICT'
    }
    if ($source.ModelKey -ceq $target.ModelKey -and $source.ModelIdentitySha256 -ceq $target.ModelIdentitySha256 -and $source.Dimension -eq $target.Dimension) {
        throw 'AI_REEMBEDDING_TARGET_IDENTITY_UNCHANGED'
    }

    $identity = [ordered]@{ Contract='SqlServerLab.AiReembeddingPlan/1.0'; Operation='REBUILD_SEPARATE_TARGET'; Dataset=$dataset; SourceModel=$source; TargetModel=$target; Chunks=@($chunks) }
    $planKey = Get-LabAiPlanKey -InputObject $identity
    $resumeByChunk = @{}
    if ($null -ne $ResumeJournal) {
        if ([string]$ResumeJournal.planKey -cne $planKey) { throw 'AI_REEMBEDDING_RESUME_PLAN_MISMATCH' }
        foreach ($entry in @($ResumeJournal.chunks)) {
            $chunkId = [string]$entry.chunkId
            if ($resumeByChunk.ContainsKey($chunkId)) { throw "AI_REEMBEDDING_RESUME_CHUNK_DUPLICATE: $chunkId" }
            $resumeByChunk[$chunkId] = $entry
        }
    }

    $journalChunks = [Collections.Generic.List[object]]::new()
    foreach ($chunk in $chunks) {
        $entry = $resumeByChunk[$chunk.ChunkId]
        $targetStatus = 'PENDING'; $targetVectorSha = $null
        if ($null -ne $entry) {
            if ([string]$entry.chunkSha256 -cne $chunk.ChunkSha256 -or [string]$entry.sourceVectorSha256 -cne $chunk.SourceVectorSha256) { throw "AI_REEMBEDDING_RESUME_CHUNK_IDENTITY_MISMATCH: $($chunk.ChunkId)" }
            if ([string]$entry.targetStatus -notin @('PENDING','SUCCEEDED')) { throw "AI_REEMBEDDING_RESUME_STATUS_INVALID: $($chunk.ChunkId)" }
            $targetStatus = [string]$entry.targetStatus
            $targetVectorSha = if ($entry.targetVectorSha256) { [string]$entry.targetVectorSha256 } else { $null }
            if ($targetStatus -eq 'SUCCEEDED' -and $targetVectorSha -notmatch '^[a-fA-F0-9]{64}$') { throw "AI_REEMBEDDING_RESUME_TARGET_VECTOR_INVALID: $($chunk.ChunkId)" }
            if ($targetStatus -eq 'PENDING' -and $null -ne $targetVectorSha) { throw "AI_REEMBEDDING_RESUME_PENDING_VECTOR_INVALID: $($chunk.ChunkId)" }
        }
        $journalChunks.Add([PSCustomObject]@{ chunkId=$chunk.ChunkId;chunkSha256=$chunk.ChunkSha256;sourceVectorSha256=$chunk.SourceVectorSha256;targetVectorSha256=if($targetVectorSha){$targetVectorSha.ToLowerInvariant()}else{$null};targetStatus=$targetStatus })
    }
    foreach ($resumeId in $resumeByChunk.Keys) { if ($resumeId -notin @($chunks.ChunkId)) { throw "AI_REEMBEDDING_RESUME_CHUNK_UNKNOWN: $resumeId" } }
    $completed = @($journalChunks | Where-Object targetStatus -eq 'SUCCEEDED').Count
    $journal = [PSCustomObject]@{ contract=[PSCustomObject]@{name='SqlServerLab.AiReembeddingJournal';version='1.0'};planKey=$planKey;status=if($completed -eq $journalChunks.Count){'COMPLETE'}elseif($completed -gt 0){'PARTIAL'}else{'PLANNED'};dataset=$dataset;sourceModel=$source;targetModel=$target;chunks=@($journalChunks) }
    return [PSCustomObject]@{ Contract=[PSCustomObject]@{Name='SqlServerLab.AiReembeddingPlan';Version='1.0'};Status='READY';Operation='REBUILD_SEPARATE_TARGET';Dataset=$dataset;SourceModel=$source;TargetModel=$target;ChunkCount=$journalChunks.Count;Resume=[PSCustomObject]@{PendingChunks=$journalChunks.Count-$completed;CompletedChunks=$completed};Retrieval=[PSCustomObject]@{State='BLOCKED_UNTIL_TARGET_COMPLETE';ReasonCode='AI_REEMBEDDING_MIXED_OPERATION_BLOCKED'};Blockers=@();PlanKey=$planKey;Journal=$journal }
}
