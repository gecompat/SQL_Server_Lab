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

function Get-AiRagModelPullHttpStatus {
    param($ErrorRecord)
    foreach ($candidate in @(
        $ErrorRecord.Exception.Response,
        $ErrorRecord.Exception.StatusCode,
        $ErrorRecord.Response,
        $ErrorRecord.StatusCode
    )) {
        if ($null -eq $candidate) { continue }
        try {
            $status = if ($null -ne $candidate.StatusCode) { [int]$candidate.StatusCode } else { [int]$candidate }
            if ($status -ge 100 -and $status -le 599) { return $status }
        }
        catch {}
    }
    return $null
}

function Test-AiRagModelPullRetryableFailure {
    param($ErrorRecord)
    $status = Get-AiRagModelPullHttpStatus -ErrorRecord $ErrorRecord
    if ($null -ne $status) { return ($status -in 408,429 -or ($status -ge 500 -and $status -le 599)) }
    $exception = $ErrorRecord.Exception
    if ($exception -is [TimeoutException] -or
        $exception -is [OperationCanceledException] -or
        $exception -is [Net.Http.HttpRequestException]) { return $true }
    if ($exception -is [Net.WebException] -and $exception.Status -ne [Net.WebExceptionStatus]::ProtocolError) { return $true }
    return $false
}

function Invoke-AiRagModelPull {
    param(
        [Parameter(Mandatory)][ValidateSet('EMBEDDING','GENERATION')][string]$ModelRole,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][ValidateRange(60,1800)][int]$TimeoutSeconds,
        [scriptblock]$Request,
        [scriptblock]$ElapsedMilliseconds,
        [scriptblock]$Delay
    )
    if (-not $Request) {
        $Request = {
            param($Uri,$Body,$RequestTimeoutSeconds)
            Invoke-RestMethod -Method Post -Uri $Uri -ContentType application/json -Body $Body -TimeoutSec $RequestTimeoutSeconds
        }
    }
    $timer = [Diagnostics.Stopwatch]::StartNew()
    if (-not $ElapsedMilliseconds) { $ElapsedMilliseconds = { [long]$timer.ElapsedMilliseconds } }
    if (-not $Delay) { $Delay = { param([int]$Milliseconds) Start-Sleep -Milliseconds $Milliseconds } }
    $body = @{ model = $Model; stream = $false } | ConvertTo-Json -Compress
    $uri = "http://127.0.0.1:$Port/api/pull"
    $budgetMilliseconds = [long]$TimeoutSeconds * 1000
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        $remainingMilliseconds = $budgetMilliseconds - [long](& $ElapsedMilliseconds)
        # Invoke-RestMethod accepts whole seconds only. A conservative floor never extends the shared deadline.
        if ($remainingMilliseconds -lt 1000) { throw 'AI_RAG_MODEL_PULL_TIMEOUT' }
        $requestTimeoutSeconds = [int][Math]::Floor($remainingMilliseconds / 1000)
        try {
            $response = & $Request $uri $body $requestTimeoutSeconds
            if ($null -eq $response -or [string]$response.status -cne 'success') { throw 'AI_RAG_MODEL_PULL_RESPONSE_INVALID' }
            return $response
        }
        catch {
            if ($_.Exception.Message -eq 'AI_RAG_MODEL_PULL_RESPONSE_INVALID') { throw }
            if (-not (Test-AiRagModelPullRetryableFailure -ErrorRecord $_)) { throw 'AI_RAG_MODEL_PULL_REQUEST_FAILED' }
            $remainingMilliseconds = $budgetMilliseconds - [long](& $ElapsedMilliseconds)
            if ($remainingMilliseconds -le 0) { throw 'AI_RAG_MODEL_PULL_TIMEOUT' }
            if ($attempt -eq 2) { throw 'AI_RAG_MODEL_PULL_TRANSIENT_EXHAUSTED' }
            & $Delay ([int][Math]::Min(1000,$remainingMilliseconds))
        }
    }
    throw 'AI_RAG_MODEL_PULL_TRANSIENT_EXHAUSTED'
}

function Get-AiRagFailureReceipt {
    param([string]$Provider,[string]$Phase,$ErrorRecord)
    $message=[string]$ErrorRecord.Exception.Message
    $code=if($message -cin @('AI_ENDPOINT_TIMEOUT','AI_ENDPOINT_NETWORK_FAILURE','AI_ENDPOINT_RESPONSE_INVALID','AI_RAG_MODEL_PULL_TIMEOUT','AI_RAG_MODEL_PULL_TRANSIENT_EXHAUSTED','AI_RAG_MODEL_PULL_RESPONSE_INVALID','AI_RAG_MODEL_PULL_REQUEST_FAILED')){$message}else{'UNCLASSIFIED'}
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
