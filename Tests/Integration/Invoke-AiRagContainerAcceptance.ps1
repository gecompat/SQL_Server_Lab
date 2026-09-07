#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft lokales Ollama-RAG mit echter SQL-2025-Vektorsuche unter Docker oder Podman.
.DESCRIPTION
    Startet einen run-eigenen Ollama-Container und ein SQL-Server-2025-Lab,
    lädt die katalogisierten Modelle, führt synthetisches RAG vor und nach
    einem Restart aus und entfernt alle Ressourcen im finally-Block.
.PARAMETER Provider
    Getrennt nachzuweisender Provider docker oder podman.
.PARAMETER TimeoutSeconds
    Timeout für Modell-Downloads.
.PARAMETER KeepOnFailure
    Behält Ressourcen nach einem Fehler für die Diagnose bei.
.OUTPUTS
    SqlServerLab.AiRagContainerAcceptance/1.0.
.EXAMPLE
    .\Tests\Integration\Invoke-AiRagContainerAcceptance.ps1 -Provider docker
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[ValidateRange(60,1800)][int]$TimeoutSeconds=900,[switch]$KeepOnFailure)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$token=[Guid]::NewGuid().ToString('N');$runtimeName="sql-lab-ai-rag-$Provider-$($token.Substring(0,10))"
$stateRoot=Join-Path $repoRoot ".artifacts\test-state\ai-rag-$Provider-$token"
$manifestPath=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-ai-rag-$Provider-$token.json"
$tool=$null;$lab=$null;$succeeded=$false
function Wait-RagOllama { param([int]$Port,[int]$Timeout=180);$timer=[Diagnostics.Stopwatch]::StartNew();do{try{if((Invoke-RestMethod "http://127.0.0.1:$Port/api/version" -TimeoutSec 5).version){return}}catch{};Start-Sleep 2}while($timer.Elapsed.TotalSeconds-lt$Timeout);throw 'AI_RAG_OLLAMA_READINESS_TIMEOUT' }
try {
    $resolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if(-not $resolution.Available){throw "AI_RAG_PROVIDER_UNAVAILABLE: $Provider"};$tool=[string]$resolution.Invocation
    if($Provider-eq'podman'){& (Join-Path $repoRoot 'Tests\Integration\Initialize-PodmanRuntime.ps1')|Out-Null}
    & $tool info *> $null;if($LASTEXITCODE-ne 0){throw "AI_RAG_PROVIDER_UNREACHABLE: $Provider"}
    $image='ollama/ollama:0.11.10';& $tool pull $image *> $null;if($LASTEXITCODE-ne 0){throw 'AI_RAG_OLLAMA_PULL_FAILED'}
    & $tool run -d --name $runtimeName --label sql-server-lab.scope=ai-rag-acceptance -p '127.0.0.1::11434' $image *> $null
    if($LASTEXITCODE-ne 0){throw 'AI_RAG_OLLAMA_START_FAILED'}
    $portText=[string](& $tool port $runtimeName '11434/tcp'|Select-Object -First 1);if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_RAG_OLLAMA_PORT_MISSING'};$ollamaPort=[int]$Matches.port
    Wait-RagOllama -Port $ollamaPort
    foreach($model in @('embeddinggemma:300m-qat-q4_0','gemma3:1b')){$body=@{model=$model;stream=$false}|ConvertTo-Json -Compress;$null=Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$ollamaPort/api/pull" -ContentType application/json -Body $body -TimeoutSec $TimeoutSeconds}

    $manifest=Get-Content (Join-Path $repoRoot 'Schemas\example-ai-vector-core.json') -Raw -Encoding utf8|ConvertFrom-Json -Depth 50
    $manifest.name="ai-rag-$Provider-$($token.Substring(0,8))";$manifest.instances[0].provider=$Provider
    $manifest|ConvertTo-Json -Depth 50|Set-Content -LiteralPath $manifestPath -Encoding utf8
    $bytes=[byte[]]::new(24);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes);$plain="Aa1!$([Convert]::ToBase64String($bytes))";$password=[SecureString]::new();foreach($c in $plain.ToCharArray()){$password.AppendChar($c)};$password.MakeReadOnly();[Array]::Clear($bytes,0,$bytes.Length);$plain=$null
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $lab=New-SqlServerLab -Manifest $manifestPath -SaPassword $password -StateRoot $stateRoot -NonInteractive -SkipAssessment
    if($lab.State-ne'Running'){throw 'AI_RAG_SQL_PROVISION_FAILED'}
    $invoke=@{RunId=$lab.RunId;InstanceId='primary';SaPassword=$password;CaseId='backup-frequency';LocalPort=$ollamaPort;StateRoot=$stateRoot;Confirm=$false}
    $first=Invoke-SqlServerLabAiRag @invoke
    if($first.Status-ne'SUCCEEDED'-or $first.Citations[0]-ne'backup-policy'-or [string]::IsNullOrWhiteSpace($first.Answer)){throw 'AI_RAG_RESULT_FAILED'}
    $evaluation=Measure-SqlServerLabAiRetrieval -QueryResult $first -CaseId backup-frequency
    if($evaluation.Status-ne'PASSED'-or $evaluation.Binding.PlanKey-ne$first.PlanKey){throw 'AI_RAG_GOLDEN_EVALUATION_FAILED'}
    & $tool restart ([string]$lab.Instances[0].ContainerName) *> $null;if($LASTEXITCODE-ne 0){throw 'AI_RAG_SQL_RESTART_FAILED'}
    & $module { param($hostName,$port,$secret,$provider,$containerName) Wait-SqlReady -HostName $hostName -Port $port -SaPassword $secret -TimeoutSeconds 180 -ExpectedMajorVersion 17 -Provider $provider -ContainerIdOrName $containerName | Out-Null } ([string]$lab.Instances[0].Host) ([int]$lab.Instances[0].Port) $password $Provider ([string]$lab.Instances[0].ContainerName)
    & $tool restart $runtimeName *> $null;if($LASTEXITCODE-ne 0){throw 'AI_RAG_OLLAMA_RESTART_FAILED'}
    $portText=[string](& $tool port $runtimeName '11434/tcp'|Select-Object -First 1);if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_RAG_RESTART_PORT_MISSING'};$ollamaPort=[int]$Matches.port;Wait-RagOllama -Port $ollamaPort;$invoke.LocalPort=$ollamaPort
    $second=Invoke-SqlServerLabAiRag @invoke;if($second.Status-ne'SUCCEEDED'-or $second.Citations[0]-ne'backup-policy'){throw 'AI_RAG_RESTART_RESULT_FAILED'}
    $succeeded=$true;[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiRagContainerAcceptance';Version='1.0'};Status='PASSED';Provider=$Provider;SqlRetrieval='EXACT_COSINE';TopCitation='backup-policy';GoldenEvaluation='PASSED';Restart='PASSED'}
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($lab-and($succeeded-or-not $KeepOnFailure)){Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force;Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false|Out-Null;Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue}
    if($tool-and($succeeded-or-not $KeepOnFailure)){& $tool rm -f $runtimeName *> $null}
    if(Test-Path $manifestPath){Remove-Item -LiteralPath $manifestPath -Force}
}
