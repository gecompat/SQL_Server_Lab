function ConvertFrom-AiRagContainerInspection {
    param($Output)
    try { $items = @((@($Output) -join "`n") | ConvertFrom-Json -Depth 30 -ErrorAction Stop) }
    catch { throw 'AI_RAG_OLLAMA_INSPECTION_INVALID' }
    if ($items.Count -ne 1) { throw 'AI_RAG_OLLAMA_INSPECTION_INVALID' }
    return $items[0]
}

function Assert-AiRagOwnedOllamaContainer {
    param($Inspection,[string]$RuntimeId,[string]$RuntimeName,[string]$OperationId)
    if ([string]$Inspection.Id -cne $RuntimeId) { throw 'AI_RAG_OLLAMA_OWNERSHIP_INVALID' }
    if (([string]$Inspection.Name).TrimStart('/') -cne $RuntimeName) { throw 'AI_RAG_OLLAMA_OWNERSHIP_INVALID' }
    $labels = $Inspection.Config.Labels
    if ([string]$labels.'sql-server-lab.scope' -cne 'ai-rag-acceptance' -or [string]$labels.'sql-server-lab.operation' -cne $OperationId) { throw 'AI_RAG_OLLAMA_OWNERSHIP_INVALID' }
    $mounts = @($Inspection.Mounts)
    if (@($mounts | Where-Object { [string]$_.Type -eq 'volume' }).Count -ne 0) { throw 'AI_RAG_OLLAMA_VOLUME_UNEXPECTED' }
    $dataMount = @($mounts | Where-Object { [string]$_.Destination -ceq '/root/.ollama' })
    if ($dataMount.Count -ne 1 -or [string]$dataMount[0].Type -cne 'bind' -or [string]::IsNullOrWhiteSpace([string]$dataMount[0].Source)) { throw 'AI_RAG_OLLAMA_STORAGE_BINDING_INVALID' }
    return $dataMount[0]
}

function Remove-AiRagOwnedOllamaContainer {
    param([scriptblock]$Runner,[string]$RuntimeId,[string]$RuntimeName,[string]$OperationId)
    $before = & $Runner @('inspect',$RuntimeId)
    if ([int]$before.ExitCode -ne 0) { throw 'AI_RAG_OLLAMA_OWNERSHIP_UNPROVEN' }
    Assert-AiRagOwnedOllamaContainer -Inspection (ConvertFrom-AiRagContainerInspection $before.Output) -RuntimeId $RuntimeId -RuntimeName $RuntimeName -OperationId $OperationId | Out-Null
    $removed = & $Runner @('rm','-f',$RuntimeId)
    if ([int]$removed.ExitCode -ne 0) { throw 'AI_RAG_OLLAMA_CLEANUP_FAILED' }
    $after = & $Runner @('inspect',$RuntimeId)
    if ([int]$after.ExitCode -eq 0) { throw 'AI_RAG_OLLAMA_RESIDUE' }
    $absence = @($after.Output) -join "`n"
    if ($absence -notmatch '(?i)(no such (object|container)|not found|does not exist)') { throw 'AI_RAG_OLLAMA_ABSENCE_UNVERIFIABLE' }
}

function Invoke-AiRagAcceptanceFinalization {
    param(
        [bool]$ArrangeStarted,
        [bool]$KeepOnFailure,
        [bool]$Completed,
        [scriptblock]$SqlCleanup,
        [scriptblock]$OllamaCleanup,
        [scriptblock]$RootCleanup,
        [scriptblock]$WriteRecovery,
        [Threading.Mutex]$Mutex,
        [bool]$MutexAcquired
    )
    $cleanupFailed = $false
    $reason = $null
    try {
        if ($Completed -or -not $KeepOnFailure) {
            if ($ArrangeStarted) {
                try { & $SqlCleanup } catch { $cleanupFailed = $true; $reason = 'SQL_CLEANUP_UNVERIFIABLE' }
            }
            try { & $OllamaCleanup } catch { $cleanupFailed = $true; if (-not $reason) { $reason = 'OLLAMA_CLEANUP_UNVERIFIABLE' } }
            if (-not $cleanupFailed) {
                try { & $RootCleanup } catch { $cleanupFailed = $true; $reason = 'TEST_ROOT_CLEANUP_FAILED' }
            }
        }
        else { $cleanupFailed = $true; $reason = 'KEEP_ON_FAILURE' }
        if ($cleanupFailed) { try { & $WriteRecovery $reason } catch {} }
        return [pscustomobject]@{ CleanupFailed = $cleanupFailed; RecoveryReason = $reason }
    }
    finally {
        if ($Mutex) { if ($MutexAcquired) { try { $Mutex.ReleaseMutex() } catch {} }; $Mutex.Dispose() }
    }
}

function Get-AiRagFailureReceipt {
    param([string]$Provider,[string]$Phase,$ErrorRecord)
    $message=[string]$ErrorRecord.Exception.Message
    $code=if($message -cin @('AI_ENDPOINT_TIMEOUT','AI_ENDPOINT_NETWORK_FAILURE','AI_ENDPOINT_RESPONSE_INVALID')){$message}else{'UNCLASSIFIED'}
    $stack=[string]$ErrorRecord.ScriptStackTrace
    $callsite='UNCLASSIFIED'
    if($stack -match '(?m)^at Invoke-LabAiRag, [^\r\n]*[\\/]AiRag\.ps1: line (?<line>[1-9][0-9]*)\s*$'){
        # Nur die bekannte Repositoryquelle lesen; keine Pfade aus dem Fehler übernehmen.
        $source=Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../Private/AiRag.ps1')
        $line=[int]$Matches.line
        if($line -le $source.Count -and $source[$line-1] -match '\bInvoke-LabAiEndpointRequest\s+-Plan\s+\$Plan\.(EmbeddingPlan|GenerationPlan)\b'){
            $callsite=if($Matches[1] -ceq 'EmbeddingPlan'){'EMBEDDING'}else{'GENERATION'}
        }
    }
    [pscustomobject]@{Provider=$Provider;Phase=$Phase;ErrorCode=$code;Callsite=$callsite}
}
