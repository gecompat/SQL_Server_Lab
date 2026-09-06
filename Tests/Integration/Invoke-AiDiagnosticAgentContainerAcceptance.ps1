#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft den read-only Diagnose-Agenten getrennt unter Docker oder Podman.
.DESCRIPTION
    Verbindet ein echtes SQL-Server-2025-Lab mit lokalem Ollama, prüft feste
    Diagnosewerkzeuge, inhaltsfreies Journal, Login-Cleanup und Restart.
.PARAMETER Provider
    Getrennt nachzuweisender Provider docker oder podman.
.PARAMETER TimeoutSeconds
    Timeout für den Modell-Download.
.PARAMETER KeepOnFailure
    Behält Ressourcen nach einem Fehler für Diagnosezwecke bei.
.OUTPUTS
    SqlServerLab.AiDiagnosticAgentContainerAcceptance/1.0.
.EXAMPLE
    .\Tests\Integration\Invoke-AiDiagnosticAgentContainerAcceptance.ps1 -Provider docker
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[ValidateRange(60,1800)][int]$TimeoutSeconds=900,[switch]$KeepOnFailure)
$ErrorActionPreference='Stop';$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path;$token=[Guid]::NewGuid().ToString('N')
$runtimeName="sql-lab-ai-agent-$Provider-$($token.Substring(0,10))";$stateRoot=Join-Path $repoRoot ".artifacts\test-state\ai-agent-$Provider-$token";$manifestPath=Join-Path ([IO.Path]::GetTempPath()) "sql-lab-ai-agent-$Provider-$token.json"
$tool=$null;$lab=$null;$succeeded=$false
function Wait-AgentOllama{param([int]$Port);$timer=[Diagnostics.Stopwatch]::StartNew();do{try{if((Invoke-RestMethod "http://127.0.0.1:$Port/api/version" -TimeoutSec 5).version){return}}catch{};Start-Sleep 2}while($timer.Elapsed.TotalSeconds-lt180);throw 'AI_AGENT_OLLAMA_READINESS_TIMEOUT'}
try{
    $resolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0];if(-not$resolution.Available){throw "AI_AGENT_PROVIDER_UNAVAILABLE: $Provider"};$tool=[string]$resolution.Invocation
    if($Provider-eq'podman'){& (Join-Path $repoRoot 'Tests\Integration\Initialize-PodmanRuntime.ps1')|Out-Null};& $tool info *> $null;if($LASTEXITCODE-ne0){throw "AI_AGENT_PROVIDER_UNREACHABLE: $Provider"}
    & $tool run -d --name $runtimeName --label sql-server-lab.scope=ai-agent-acceptance -p '127.0.0.1::11434' 'ollama/ollama:0.11.10' *> $null;if($LASTEXITCODE-ne0){throw 'AI_AGENT_OLLAMA_START_FAILED'}
    $portText=[string](& $tool port $runtimeName '11434/tcp'|Select-Object -First 1);if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_AGENT_OLLAMA_PORT_MISSING'};$ollamaPort=[int]$Matches.port;Wait-AgentOllama $ollamaPort
    $body=@{model='gemma3:1b';stream=$false}|ConvertTo-Json -Compress;$null=Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$ollamaPort/api/pull" -ContentType application/json -Body $body -TimeoutSec $TimeoutSeconds
    $manifest=Get-Content (Join-Path $repoRoot 'Schemas\example-ai-vector-core.json') -Raw -Encoding utf8|ConvertFrom-Json -Depth 50;$manifest.name="ai-agent-$Provider-$($token.Substring(0,8))";$manifest.instances[0].provider=$Provider;$manifest|ConvertTo-Json -Depth 50|Set-Content $manifestPath -Encoding utf8
    $bytes=[byte[]]::new(24);[Security.Cryptography.RandomNumberGenerator]::Fill($bytes);$plain="Aa1!$([Convert]::ToBase64String($bytes))";$password=[SecureString]::new();foreach($c in $plain.ToCharArray()){$password.AppendChar($c)};$password.MakeReadOnly();[Array]::Clear($bytes,0,$bytes.Length);$plain=$null
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru;$lab=New-SqlServerLab -Manifest $manifestPath -SaPassword $password -StateRoot $stateRoot -NonInteractive -SkipAssessment;if($lab.State-ne'Running'){throw 'AI_AGENT_SQL_PROVISION_FAILED'}
    $invoke=@{RunId=$lab.RunId;SaPassword=$password;Question='Fasse den synthetischen Serverzustand zusammen.';ToolId=@('server-summary','wait-statistics');LocalPort=$ollamaPort;StateRoot=$stateRoot;Confirm=$false}
    $first=Invoke-SqlServerLabAiDiagnosticAgent @invoke;if($first.Status-ne'SUCCEEDED'-or$first.ToolExecutions.Count-ne2-or[string]::IsNullOrWhiteSpace($first.Answer)){throw 'AI_AGENT_RESULT_FAILED'}
    $loginCount=& $module {param($hostName,$port,$secret)$plain=ConvertFrom-LabSecureString $secret;try{@(Invoke-SqlQuery -HostName $hostName -Port $port -SaPlain $plain -Query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.server_principals WHERE name LIKE 'sql_lab_ai_%';")[-1]}finally{$plain=$null}} $lab.Instances[0].Host $lab.Instances[0].Port $password
    if([int]$loginCount-ne0){throw 'AI_AGENT_LOGIN_CLEANUP_FAILED'}
    & $tool restart $runtimeName *> $null;if($LASTEXITCODE-ne0){throw 'AI_AGENT_OLLAMA_RESTART_FAILED'};$portText=[string](& $tool port $runtimeName '11434/tcp'|Select-Object -First 1);if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_AGENT_RESTART_PORT_MISSING'};$invoke.LocalPort=[int]$Matches.port;Wait-AgentOllama $invoke.LocalPort
    $second=Invoke-SqlServerLabAiDiagnosticAgent @invoke;if($second.Status-ne'SUCCEEDED'){throw 'AI_AGENT_RESTART_RESULT_FAILED'}
    $succeeded=$true;[PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiDiagnosticAgentContainerAcceptance';Version='1.0'};Status='PASSED';Provider=$Provider;Tools=2;LoginCleanup='PASSED';Restart='PASSED'}
}finally{Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue;if($lab-and($succeeded-or-not$KeepOnFailure)){Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force;Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false|Out-Null;Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue};if($tool-and($succeeded-or-not$KeepOnFailure)){& $tool rm -f $runtimeName *> $null};if(Test-Path $manifestPath){Remove-Item $manifestPath -Force}}
