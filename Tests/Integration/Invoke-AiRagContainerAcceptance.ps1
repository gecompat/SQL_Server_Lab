#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft lokales Ollama-RAG mit echter SQL-2025-Vektorsuche unter Docker oder Podman.
.DESCRIPTION
    Startet einen run-eigenen Ollama-Container mit testlokalem Bind-Mount und ein
    SQL-Server-2025-Lab. Der Lauf hält den gemeinsamen Runtime-Mutex, bindet
    Container, Storage und State vor der Mutation und prüft Cleanup unabhängig
    vom Testresultat. -KeepOnFailure behält ausschließlich den fehlgeschlagenen
    eigenen Lauf für die lokale Recovery.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [ValidateRange(60,1800)][int]$TimeoutSeconds=900,
    [switch]$KeepOnFailure,
    [switch]$RuntimeMutexAlreadyHeld
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Tests/Common/AiRagContainerAcceptance.ps1')
$token=[Guid]::NewGuid().ToString('N');$operation=[Guid]::NewGuid().ToString('D')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-ai-rag-$Provider-$token"
$stateRoot=Join-Path $testRoot 'state';$ollamaData=Join-Path $testRoot 'ollama';$manifestPath=Join-Path $testRoot 'manifest.json';$journalPath=Join-Path $testRoot 'journal.json';$cidPath=Join-Path $testRoot 'ollama.cid'
$runtimeName="sql-lab-ai-rag-$Provider-$($token.Substring(0,10))"
$tool=$null;$module=$null;$lab=$null;$binding=$null;$runtimeId=$null;$runtimeStartAttempted=$false;$arrangeStarted=$false;$complete=$false;$testFailed=$false;$cleanupFailed=$false;$cleanupReason=$null;$mutex=$null;$mutexAcquired=$false;$result=$null;$password=$null

function Write-RagAcceptanceJournal {
    param([Parameter(Mandatory)][string]$Status,[string]$RecoveryReason=$null,[bool]$TestFailed=$false)
    $journal=[ordered]@{contract='SqlServerLab.AiRagContainerAcceptance/1.1';provider=$Provider;operationId=$operation;runtimeName=$runtimeName;runtimeId=$runtimeId;status=$Status;recoveryReason=$RecoveryReason;testFailed=$TestFailed}
    $temporary="$journalPath.partial"
    [IO.File]::WriteAllText($temporary,($journal|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary,$journalPath,$true)
}

function Invoke-RagRuntimeCommand {
    param([Parameter(Mandatory)][string[]]$Arguments)
    $output=@(& $tool @Arguments 2>&1)
    [pscustomobject]@{ExitCode=$LASTEXITCODE;Output=$output}
}

function Remove-RagAcceptanceRoot {
    param([Parameter(Mandatory)][string]$Path)
    $temporaryRoot=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar,[IO.Path]::AltDirectorySeparatorChar)
    $candidate=[IO.Path]::GetFullPath($Path)
    $prefix="$temporaryRoot$([IO.Path]::DirectorySeparatorChar)"
    if(-not $candidate.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or (Split-Path -Leaf $candidate) -notmatch '^sql-lab-ai-rag-(docker|podman)-[a-f0-9]{32}$'){
        throw 'AI_RAG_ACCEPTANCE_ROOT_INVALID'
    }
    Remove-Item -LiteralPath $candidate -Recurse -Force
}

function Wait-RagOllama { param([int]$Port,[int]$Timeout=180);$timer=[Diagnostics.Stopwatch]::StartNew();do{try{if((Invoke-RestMethod "http://127.0.0.1:$Port/api/version" -TimeoutSec 5).version){return}}catch{};Start-Sleep 2}while($timer.Elapsed.TotalSeconds-lt$Timeout);throw 'AI_RAG_OLLAMA_READINESS_TIMEOUT' }
try {
    if(-not $RuntimeMutexAlreadyHeld){
        $mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}))
        try{$mutexAcquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10))}catch [Threading.AbandonedMutexException]{$mutexAcquired=$true}
        if(-not $mutexAcquired){throw 'AI_RAG_ACCEPTANCE_LOCK_TIMEOUT'}
    }
    $null=New-Item -ItemType Directory -Path $testRoot
    $null=New-Item -ItemType Directory -Path $ollamaData
    Write-RagAcceptanceJournal -Status 'ARRANGE_PENDING'
    $resolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available){throw "AI_RAG_PROVIDER_UNAVAILABLE: $Provider"};$tool=[string]$resolution.Invocation
    if($Provider-eq'podman'){& (Join-Path $repoRoot 'Tests\Integration\Initialize-PodmanRuntime.ps1')|Out-Null}
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $info=Invoke-RagRuntimeCommand @('info');if($info.ExitCode-ne 0){throw "AI_RAG_PROVIDER_UNREACHABLE: $Provider"}
    $image='ollama/ollama:0.11.10';$pull=Invoke-RagRuntimeCommand @('pull',$image);if($pull.ExitCode-ne 0){throw 'AI_RAG_OLLAMA_PULL_FAILED'}
    $runtimeStartAttempted=$true
    $start=Invoke-RagRuntimeCommand @('run','-d','--cidfile',$cidPath,'--name',$runtimeName,'--label','sql-server-lab.scope=ai-rag-acceptance','--label',"sql-server-lab.operation=$operation",'-p','127.0.0.1::11434','-v',"${ollamaData}:/root/.ollama",$image)
    if($start.ExitCode-ne 0){throw 'AI_RAG_OLLAMA_START_FAILED'}
    if(-not(Test-Path -LiteralPath $cidPath -PathType Leaf)){throw 'AI_RAG_OLLAMA_ID_MISSING'}
    $runtimeId=(Get-Content -LiteralPath $cidPath -Raw -Encoding utf8).Trim()
    if($runtimeId-notmatch '^[a-f0-9]{12,64}$'){throw 'AI_RAG_OLLAMA_ID_INVALID'}
    $inspection=Invoke-RagRuntimeCommand @('inspect',$runtimeId);if($inspection.ExitCode-ne 0){throw 'AI_RAG_OLLAMA_INSPECTION_FAILED'}
    $dataMount=Assert-AiRagOwnedOllamaContainer -Inspection (ConvertFrom-AiRagContainerInspection $inspection.Output) -RuntimeId $runtimeId -RuntimeName $runtimeName -OperationId $operation
    $mountVerified=& $module {param($Provider,$Source,$HostRoot)Test-LabPortableContainerTransferPreflightBoundBackupMount -Provider $Provider -MountSource $Source -HostRoot $HostRoot} $Provider ([string]$dataMount.Source) $ollamaData
    if(-not $mountVerified){throw 'AI_RAG_OLLAMA_STORAGE_BINDING_INVALID'}
    Write-RagAcceptanceJournal -Status 'OLLAMA_OWNED'
    $portResult=Invoke-RagRuntimeCommand @('port',$runtimeId,'11434/tcp');if($portResult.ExitCode-ne 0){throw 'AI_RAG_OLLAMA_PORT_MISSING'}
    $portText=[string]($portResult.Output|Select-Object -First 1);if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_RAG_OLLAMA_PORT_MISSING'};$ollamaPort=[int]$Matches.port
    Wait-RagOllama -Port $ollamaPort
    foreach($model in @('embeddinggemma:300m-qat-q4_0','gemma3:1b')){$body=@{model=$model;stream=$false}|ConvertTo-Json -Compress;$null=Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$ollamaPort/api/pull" -ContentType application/json -Body $body -TimeoutSec $TimeoutSeconds}
    $manifest=Get-Content (Join-Path $repoRoot 'Schemas\example-ai-vector-core.json') -Raw -Encoding utf8|ConvertFrom-Json -Depth 50
    $manifest.name="ai-rag-$Provider-$($token.Substring(0,8))";$manifest.instances[0].provider=$Provider
    $manifest.instances[0] | Add-Member -NotePropertyName drives -NotePropertyValue @([pscustomobject]@{id='ai-golden-data';containerPath='/var/opt/mssql'}) -Force
    $manifest|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $manifestPath -Encoding utf8
    $bytes=[byte[]]::new(24);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes);$plain="Aa1!$([Convert]::ToBase64String($bytes))";$password=[SecureString]::new();foreach($c in $plain.ToCharArray()){$password.AppendChar($c)};$password.MakeReadOnly();[Array]::Clear($bytes,0,$bytes.Length);$plain=$null
    $arrangeStarted=$true
    $lab=& $module {param($Manifest,$Password,$State,$Operation)Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {param($Manifest,$Password,$State)New-SqlServerLab -Manifest $Manifest -SaPassword $Password -StateRoot $State -NonInteractive -SkipAssessment} -ArgumentList @($Manifest,$Password,$State)} $manifestPath $password $stateRoot $operation
    if($lab.State-ne'Running'){throw 'AI_RAG_SQL_PROVISION_FAILED'}
    $binding=& $module {param($Run,$State,$Operation)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Operation} $lab.RunId $stateRoot $operation
    Write-RagAcceptanceJournal -Status 'SQL_OWNED'
    $invoke=@{RunId=$lab.RunId;InstanceId='primary';SaPassword=$password;CaseId='backup-frequency';LocalPort=$ollamaPort;StateRoot=$stateRoot;Confirm=$false}
    $first=Invoke-SqlServerLabAiRag @invoke
    if($first.Status-ne'SUCCEEDED'-or $first.Citations[0]-ne'backup-policy'-or [string]::IsNullOrWhiteSpace($first.Answer)){throw 'AI_RAG_RESULT_FAILED'}
    $evaluation=Measure-SqlServerLabAiRetrieval -QueryResult $first -CaseId backup-frequency
    if($evaluation.Status-ne'PASSED'-or $evaluation.Binding.PlanKey-ne$first.PlanKey){throw 'AI_RAG_GOLDEN_EVALUATION_FAILED'}
    $sqlRestart=Invoke-RagRuntimeCommand @('restart',[string]$lab.Instances[0].ContainerName);if($sqlRestart.ExitCode-ne 0){throw 'AI_RAG_SQL_RESTART_FAILED'}
    & $module { param($hostName,$port,$secret,$provider,$containerName) Wait-SqlReady -HostName $hostName -Port $port -SaPassword $secret -TimeoutSeconds 180 -ExpectedMajorVersion 17 -Provider $provider -ContainerIdOrName $containerName | Out-Null } ([string]$lab.Instances[0].Host) ([int]$lab.Instances[0].Port) $password $Provider ([string]$lab.Instances[0].ContainerName)
    $ollamaRestart=Invoke-RagRuntimeCommand @('restart',$runtimeId);if($ollamaRestart.ExitCode-ne 0){throw 'AI_RAG_OLLAMA_RESTART_FAILED'}
    $portResult=Invoke-RagRuntimeCommand @('port',$runtimeId,'11434/tcp');if($portResult.ExitCode-ne 0){throw 'AI_RAG_RESTART_PORT_MISSING'}
    $portText=[string]($portResult.Output|Select-Object -First 1);if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_RAG_RESTART_PORT_MISSING'};$ollamaPort=[int]$Matches.port;Wait-RagOllama -Port $ollamaPort;$invoke.LocalPort=$ollamaPort
    $second=Invoke-SqlServerLabAiRag @invoke;if($second.Status-ne'SUCCEEDED'-or $second.Citations[0]-ne'backup-policy'){throw 'AI_RAG_RESTART_RESULT_FAILED'}
    $secondEvaluation=Measure-SqlServerLabAiRetrieval -QueryResult $second -CaseId backup-frequency;if($secondEvaluation.Status-ne'PASSED'-or $secondEvaluation.Binding.PlanKey-ne$second.PlanKey){throw 'AI_RAG_RESTART_EVALUATION_FAILED'}
    $complete=$true;$result=[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiRagContainerAcceptance';Version='1.1'};Status='PASSED';Provider=$Provider;SqlRetrieval='EXACT_COSINE';TopCitation='backup-policy';GoldenEvaluation='PASSED';Restart='PASSED'}
}
catch { $testFailed=$true; throw }
finally {
    $finalization=Invoke-AiRagAcceptanceFinalization -ArrangeStarted $arrangeStarted -KeepOnFailure $KeepOnFailure -Completed $complete -SqlCleanup {
        $owned=& $module {param($Operation,$State)Get-LabOperationOwnedRun -OperationId $Operation -StateRoot $State} $operation $stateRoot
        if(-not $owned){throw 'AI_RAG_SQL_CLEANUP_UNVERIFIABLE'}
        $binding=& $module {param($Run,$State,$Operation)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Operation} $owned.runId $stateRoot $operation
        $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $stateRoot -Force -Confirm:$false
        if($removed.Status-ne'REMOVED'){throw 'AI_RAG_SQL_CLEANUP_FAILED'}
        & $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $binding
    } -OllamaCleanup {
        if($tool -and $runtimeId){Remove-AiRagOwnedOllamaContainer -Runner ${function:Invoke-RagRuntimeCommand} -RuntimeId $runtimeId -RuntimeName $runtimeName -OperationId $operation}
        if(($runtimeId -and -not $tool) -or ($runtimeStartAttempted -and -not $runtimeId)){throw 'AI_RAG_OLLAMA_ID_UNVERIFIABLE'}
    } -RootCleanup {
        if(Test-Path -LiteralPath $testRoot){Remove-RagAcceptanceRoot -Path $testRoot}
    } -WriteRecovery {
        param($Reason)
        if(Test-Path -LiteralPath $journalPath){Write-RagAcceptanceJournal -Status 'RECOVERY_REQUIRED' -RecoveryReason $Reason -TestFailed $testFailed}
    } -Mutex $mutex -MutexAcquired $mutexAcquired
    $cleanupFailed=$finalization.CleanupFailed
    if($password){$password.Dispose()}
    if($module){Remove-Module $module.Name -Force -ErrorAction SilentlyContinue}
}
if(-not $complete-or$cleanupFailed){throw 'AI_RAG_CONTAINER_ACCEPTANCE_INCOMPLETE'}
$result
