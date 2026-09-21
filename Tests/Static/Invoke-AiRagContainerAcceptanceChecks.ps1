#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/AiRagContainerAcceptance.ps1')
$results=[Collections.Generic.List[object]]::new()
function Check {param([string]$Name,[bool]$Success)$results.Add([pscustomobject]@{Name=$Name;Success=$Success})}
function Reject {param([scriptblock]$Action,[string]$Code)try{& $Action|Out-Null;$false}catch{$_.Exception.Message -eq $Code}}
function New-PullFailure {param([int]$StatusCode)$exception=[Exception]::new('synthetic transport failure');$exception|Add-Member -NotePropertyName Response -NotePropertyValue ([pscustomobject]@{StatusCode=$StatusCode});$exception}
$data=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-rag-check-'+[guid]::NewGuid().ToString('N'))
$id=('a'*64 -join '');$name='sql-lab-ai-rag-podman-0123456789';$operation='11111111-1111-4111-8111-111111111111'
function New-Inspection {
    param([string]$Id=$id,[string]$Operation=$operation,[string]$MountType='bind')
    [pscustomobject]@{Id=$Id;Name="/$name";Config=@{Labels=@{'sql-server-lab.scope'='ai-rag-acceptance';'sql-server-lab.operation'=$Operation}};Mounts=@([pscustomobject]@{Type=$MountType;Source=$data;Destination='/root/.ollama'})}|ConvertTo-Json -Depth 10 -Compress
}
try {
    $ownedInspection=New-Inspection
    $foreignInspection=New-Inspection -Operation '22222222-2222-4222-8222-222222222222'
    $steps=[Collections.Queue]::new();@('inspect-before','remove','inspect-after')|ForEach-Object{$steps.Enqueue($_)}
    $runner={param([string[]]$Arguments)$step=$steps.Dequeue();switch($step){'inspect-before'{[pscustomobject]@{ExitCode=0;Output=$ownedInspection}}'remove'{[pscustomobject]@{ExitCode=0;Output=@()}}'inspect-after'{[pscustomobject]@{ExitCode=1;Output=@('Error: No such container')}}}}.GetNewClosure()
    Remove-AiRagOwnedOllamaContainer -Runner $runner -RuntimeId $id -RuntimeName $name -OperationId $operation
    Check 'Tokengebundener Ollama-Container wird per ID entfernt und auf Abwesenheit geprüft' $true
    $steps=[Collections.Queue]::new();@('inspect-before','remove')|ForEach-Object{$steps.Enqueue($_)}
    $failedRemove={param([string[]]$Arguments)$step=$steps.Dequeue();if($step -eq 'inspect-before'){[pscustomobject]@{ExitCode=0;Output=$ownedInspection}}else{[pscustomobject]@{ExitCode=1;Output=@()}}}.GetNewClosure()
    Check 'Fehlgeschlagenes Container-Cleanup bleibt sichtbar' (Reject {Remove-AiRagOwnedOllamaContainer -Runner $failedRemove -RuntimeId $id -RuntimeName $name -OperationId $operation} 'AI_RAG_OLLAMA_CLEANUP_FAILED')
    $steps=[Collections.Queue]::new();@('inspect-before','remove','inspect-after')|ForEach-Object{$steps.Enqueue($_)}
    $residue={param([string[]]$Arguments)$step=$steps.Dequeue();if($step -eq 'inspect-before'){[pscustomobject]@{ExitCode=0;Output=$ownedInspection}}elseif($step -eq 'remove'){[pscustomobject]@{ExitCode=0;Output=@()}}else{[pscustomobject]@{ExitCode=0;Output=$ownedInspection}}}.GetNewClosure()
    Check 'Verbliebener Container nach rm wird nicht als Cleanup akzeptiert' (Reject {Remove-AiRagOwnedOllamaContainer -Runner $residue -RuntimeId $id -RuntimeName $name -OperationId $operation} 'AI_RAG_OLLAMA_RESIDUE')
    $steps=[Collections.Queue]::new();@('inspect-before','remove','inspect-after')|ForEach-Object{$steps.Enqueue($_)}
    $offline={param([string[]]$Arguments)$step=$steps.Dequeue();if($step -eq 'inspect-before'){[pscustomobject]@{ExitCode=0;Output=$ownedInspection}}elseif($step -eq 'remove'){[pscustomobject]@{ExitCode=0;Output=@()}}else{[pscustomobject]@{ExitCode=125;Output=@('Cannot connect to the container runtime')}}}.GetNewClosure()
    Check 'Offline-Runtime wird nicht als Containerabwesenheit akzeptiert' (Reject {Remove-AiRagOwnedOllamaContainer -Runner $offline -RuntimeId $id -RuntimeName $name -OperationId $operation} 'AI_RAG_OLLAMA_ABSENCE_UNVERIFIABLE')
    $foreignCalls=[Collections.Generic.List[string]]::new()
    $badOwnership={param([string[]]$Arguments)$foreignCalls.Add(($Arguments -join ' '));[pscustomobject]@{ExitCode=0;Output=$foreignInspection}}.GetNewClosure()
    Check 'Fremdes Token blockiert vor name- oder ID-basierter Löschung' ((Reject {Remove-AiRagOwnedOllamaContainer -Runner $badOwnership -RuntimeId $id -RuntimeName $name -OperationId $operation} 'AI_RAG_OLLAMA_OWNERSHIP_INVALID') -and $foreignCalls.Count -eq 1 -and $foreignCalls[0] -eq "inspect $id")
    Check 'Anonymer Ollama-Volume-Mount wird vor Cleanup blockiert' (Reject {Assert-AiRagOwnedOllamaContainer -Inspection (ConvertFrom-AiRagContainerInspection (New-Inspection -MountType volume)) -RuntimeId $id -RuntimeName $name -OperationId $operation} 'AI_RAG_OLLAMA_VOLUME_UNEXPECTED')
    $script:sqlCalls=0;$script:ollamaCalls=0;$script:rootCalls=0;$script:recovery=@()
    $arrangeThrow=Invoke-AiRagAcceptanceFinalization -ArrangeStarted $true -KeepOnFailure $false -Completed $false -SqlCleanup {$script:sqlCalls++;throw 'new failed after run registration'} -OllamaCleanup {$script:ollamaCalls++} -RootCleanup {$script:rootCalls++} -WriteRecovery {param($reason)$script:recovery+=$reason}
    Check 'Registrierter SQL-Run nach New-Throw wird scoped bereinigt versucht und Root bleibt' ($script:sqlCalls -eq 1 -and $script:ollamaCalls -eq 1 -and $script:rootCalls -eq 0 -and $arrangeThrow.CleanupFailed -and $script:recovery -contains 'SQL_CLEANUP_UNVERIFIABLE')
    $script:sqlCalls=0;$script:ollamaCalls=0;$script:rootCalls=0;$script:recovery=@()
    $cleanupFailure=Invoke-AiRagAcceptanceFinalization -ArrangeStarted $true -KeepOnFailure $false -Completed $true -SqlCleanup {$script:sqlCalls++;throw 'remove failed'} -OllamaCleanup {$script:ollamaCalls++} -RootCleanup {$script:rootCalls++} -WriteRecovery {param($reason)$script:recovery+=$reason}
    Check 'SQL-Cleanupfehler versucht dennoch Ollama-Cleanup und journalisiert Recovery' ($script:sqlCalls -eq 1 -and $script:ollamaCalls -eq 1 -and $script:rootCalls -eq 0 -and $cleanupFailure.CleanupFailed -and $script:recovery -contains 'SQL_CLEANUP_UNVERIFIABLE')
    $mutexName="SQL_Server_Lab_AiRag_Finalization_$([guid]::NewGuid().ToString('N'))";$mutex=[Threading.Mutex]::new($false,$mutexName);$held=$mutex.WaitOne(0);$script:recovery=@()
    $beforeJob=Start-Job -ScriptBlock {param($Name)$probe=[Threading.Mutex]::new($false,$Name);try{$got=$probe.WaitOne(150);if($got){$probe.ReleaseMutex()};$got}finally{$probe.Dispose()}} -ArgumentList $mutexName;Wait-Job $beforeJob|Out-Null;$blocked=-not [bool](Receive-Job $beforeJob);Remove-Job $beforeJob
    $rootFailure=Invoke-AiRagAcceptanceFinalization -ArrangeStarted $false -KeepOnFailure $false -Completed $true -SqlCleanup {} -OllamaCleanup {} -RootCleanup {throw 'root delete failed'} -WriteRecovery {param($reason)$script:recovery+=$reason} -Mutex $mutex -MutexAcquired $held
    $afterJob=Start-Job -ScriptBlock {param($Name)$probe=[Threading.Mutex]::new($false,$Name);try{$got=$probe.WaitOne(150);if($got){$probe.ReleaseMutex()};$got}finally{$probe.Dispose()}} -ArgumentList $mutexName;Wait-Job $afterJob|Out-Null;$released=[bool](Receive-Job $afterJob);Remove-Job $afterJob
    Check 'Root-Deletefehler journalisiert Recovery und gibt den Mutex prozessübergreifend frei' ($blocked -and $rootFailure.CleanupFailed -and $script:recovery -contains 'TEST_ROOT_CLEANUP_FAILED' -and $released)
    $ragSource=Join-Path $repoRoot 'Private/AiRag.ps1'
    $embeddingLine=(Select-String -LiteralPath $ragSource -SimpleMatch 'Invoke-LabAiEndpointRequest -Plan $Plan.EmbeddingPlan'|Select-Object -First 1).LineNumber
    $generationLine=(Select-String -LiteralPath $ragSource -SimpleMatch 'Invoke-LabAiEndpointRequest -Plan $Plan.GenerationPlan'|Select-Object -First 1).LineNumber
    $embedding=Get-AiRagFailureReceipt -Provider podman -Phase FIRST_RAG -ErrorRecord ([pscustomobject]@{Exception=[Exception]::new('AI_ENDPOINT_TIMEOUT');ScriptStackTrace="at Invoke-LabAiRag, /synthetic/Private/AiRag.ps1: line $embeddingLine"})
    $generation=Get-AiRagFailureReceipt -Provider podman -Phase RESTART_RAG -ErrorRecord ([pscustomobject]@{Exception=[Exception]::new('AI_ENDPOINT_TIMEOUT');ScriptStackTrace="at Invoke-LabAiRag, /synthetic/Private/AiRag.ps1: line $generationLine"})
    Check 'Failure-Receipt klassifiziert nur allowlisted Code, Phase und RAG-Callsite' ($embedding.Phase -eq 'FIRST_RAG' -and $embedding.Callsite -eq 'EMBEDDING' -and $generation.Phase -eq 'RESTART_RAG' -and $generation.Callsite -eq 'GENERATION')
    $unknown=Get-AiRagFailureReceipt -Provider podman -Phase FIRST_RAG -ErrorRecord ([pscustomobject]@{Exception=[Exception]::new('synthetic private text');ScriptStackTrace='at Other, /untrusted/AiRag.ps1: line 124'})
    Check 'Unbekannte Fehler und fremde Callsite bleiben inhaltsfrei unklassifiziert' ($unknown.ErrorCode -ceq 'UNCLASSIFIED' -and $unknown.Callsite -ceq 'UNCLASSIFIED' -and ($unknown|ConvertTo-Json) -notmatch 'private text|untrusted')
    $script:pullAttempts=0;$script:elapsed=0;$script:delays=@()
    $retryRequest={param($Uri,$Body,$Timeout)$script:pullAttempts++;if($script:pullAttempts-eq 1){throw (New-PullFailure 429)};[pscustomobject]@{status='success'}}
    $retryResult=Invoke-AiRagModelPull -ModelRole EMBEDDING -Model 'synthetic' -Port 11434 -TimeoutSeconds 60 -Request $retryRequest -ElapsedMilliseconds {[long]$script:elapsed} -Delay {param($Milliseconds)$script:delays+=$Milliseconds}
    Check 'Transientes HTTP 429 wird genau einmal innerhalb des Modellbudgets wiederholt' ($retryResult.status-ceq'success' -and $script:pullAttempts-eq 2 -and @($script:delays).Count-eq 1 -and $script:delays[0]-eq 1000)
    $script:pullAttempts=0
    $exhaustedRequest={param($Uri,$Body,$Timeout)$script:pullAttempts++;throw (New-PullFailure 503)}
    Check 'Zwei transiente Fehler erschöpfen die feste Pull-Versuchsgrenze' ((Reject {Invoke-AiRagModelPull -ModelRole GENERATION -Model 'synthetic' -Port 11434 -TimeoutSeconds 60 -Request $exhaustedRequest -ElapsedMilliseconds {0} -Delay {param($Milliseconds)}} 'AI_RAG_MODEL_PULL_TRANSIENT_EXHAUSTED') -and $script:pullAttempts-eq 2)
    $script:pullAttempts=0;$script:elapsed=0;$script:delays=@()
    $deadlineRequest={param($Uri,$Body,$Timeout)$script:pullAttempts++;if($script:pullAttempts-eq 2){$script:elapsed=60000};throw (New-PullFailure 503)}
    Check 'Retry und Wartezeit teilen eine monotone Modell-Deadline über beide Versuche' ((Reject {Invoke-AiRagModelPull -ModelRole EMBEDDING -Model 'synthetic' -Port 11434 -TimeoutSeconds 60 -Request $deadlineRequest -ElapsedMilliseconds {[long]$script:elapsed} -Delay {param($Milliseconds)$script:delays+=$Milliseconds;$script:elapsed+=$Milliseconds}} 'AI_RAG_MODEL_PULL_TIMEOUT') -and $script:pullAttempts-eq 2 -and $script:delays[0]-eq 1000)
    $script:pullAttempts=0
    $nonRetryableRequest={param($Uri,$Body,$Timeout)$script:pullAttempts++;throw (New-PullFailure 400)}
    Check 'Nichttransientes HTTP 400 wird ohne Retry als redigierter Pullfehler beendet' ((Reject {Invoke-AiRagModelPull -ModelRole EMBEDDING -Model 'synthetic' -Port 11434 -TimeoutSeconds 60 -Request $nonRetryableRequest -ElapsedMilliseconds {0} -Delay {param($Milliseconds)}} 'AI_RAG_MODEL_PULL_REQUEST_FAILED') -and $script:pullAttempts-eq 1)
    $http400=[Net.Http.HttpRequestException]::new('synthetic',[Exception]::new('inner'),[Net.HttpStatusCode]::BadRequest)
    Check 'Ein HTTP-Status 400 bleibt auch bei typisierter HTTP-Ausnahme nicht retrybar' (-not (Test-AiRagModelPullRetryableFailure -ErrorRecord ([pscustomobject]@{Exception=$http400})))
    Check 'Ein HTTP-Erfolg ohne exakten success-Status wird nicht als Modellpull akzeptiert' (Reject {Invoke-AiRagModelPull -ModelRole GENERATION -Model 'synthetic' -Port 11434 -TimeoutSeconds 60 -Request {param($Uri,$Body,$Timeout)[pscustomobject]@{status='error'}} -ElapsedMilliseconds {0} -Delay {param($Milliseconds)}} 'AI_RAG_MODEL_PULL_RESPONSE_INVALID')
    $source=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-AiRagContainerAcceptance.ps1') -Raw -Encoding utf8
    Check 'Golden-Harness hält Mutex, Bind-Mount sowie redigierte Pull- und RAG-Phasen fest' ($source -match 'Global\\SQL_Server_Lab_Runtime_Smoke' -and $source -match '\$RuntimeMutexAlreadyHeld' -and $source -match '--cidfile' -and $source -match ':/root/\.ollama' -and $source -match 'phase=\$phase' -and $source -match "'MODEL_PULL'" -and $source -match "'FIRST_RAG'" -and $source -match "'RESTART_RAG'" -and $source -match 'Invoke-AiRagModelPull' -and $source -match 'Assert-LabTransferNoResidue')
}
finally {if(Test-Path -LiteralPath $data){Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue}}
foreach($result in $results){Write-Host "$(if($result.Success){'PASS'}else{'FAIL'}): $($result.Name)"}
if(@($results|Where-Object{-not $_.Success}).Count){throw 'AI RAG container acceptance checks failed'}
Write-Host "AI RAG CONTAINER ACCEPTANCE CHECKS: PASS ($($results.Count))"
