#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/AiRagContainerAcceptance.ps1')
$results=[Collections.Generic.List[object]]::new()
function Check {param([string]$Name,[bool]$Success)$results.Add([pscustomobject]@{Name=$Name;Success=$Success})}
function Reject {param([scriptblock]$Action,[string]$Code)try{& $Action|Out-Null;$false}catch{$_.Exception.Message -eq $Code}}
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
    $source=Get-Content -LiteralPath (Join-Path $repoRoot 'Tests/Integration/Invoke-AiRagContainerAcceptance.ps1') -Raw -Encoding utf8
    Check 'Golden-Harness hält Mutex, Bind-Mount und nicht sensitive RAG-Phasen fest' ($source -match 'Global\\SQL_Server_Lab_Runtime_Smoke' -and $source -match '\$RuntimeMutexAlreadyHeld' -and $source -match '--cidfile' -and $source -match ':/root/\.ollama' -and $source -match 'phase=\$phase' -and $source -match "'FIRST_RAG'" -and $source -match "'RESTART_RAG'" -and $source -match 'Assert-LabTransferNoResidue')
}
finally {if(Test-Path -LiteralPath $data){Remove-Item -LiteralPath $data -Recurse -Force -ErrorAction SilentlyContinue}}
foreach($result in $results){Write-Host "$(if($result.Success){'PASS'}else{'FAIL'}): $($result.Name)"}
if(@($results|Where-Object{-not $_.Success}).Count){throw 'AI RAG container acceptance checks failed'}
Write-Host "AI RAG CONTAINER ACCEPTANCE CHECKS: PASS ($($results.Count))"
