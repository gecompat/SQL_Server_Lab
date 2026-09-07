#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft RAG und read-only Diagnose-Agent gegen einen vorhandenen Hyper-V-SQL-2025-Run.
.DESCRIPTION
    Startet Ollama scopegebunden unter Docker oder Podman, bindet einen bereits
    verwalteten Hyper-V-SQL-2025-Run an den providerneutralen KI-Controller und
    prüft RAG, Agent, Login-Cleanup sowie einen erneuten Lauf nach VM- und
    Ollama-Neustart. Der übergebene Hyper-V-Run wird weder erzeugt noch entfernt.
    Bei einem geschützten Testgruppenmitglied wird der Einzelneustart nicht
    umgangen und das Ergebnis als PARTIAL markiert.
.OUTPUTS
    SqlServerLab.AiHyperVAcceptance/1.0.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F-]{36}$')][string]$RunId,
    [Parameter(Mandatory)][SecureString]$SaPassword,
    [ValidateSet('docker','podman')][string]$OllamaProvider='docker',
    [ValidateRange(60,1800)][int]$TimeoutSeconds=900,
    [switch]$KeepOllamaOnFailure
)

$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$token=[Guid]::NewGuid().ToString('N')
$runtimeName="sql-lab-ai-hyperv-$($token.Substring(0,10))"
$tool=$null
$succeeded=$false

function Wait-HyperVAiOllama {
    param([int]$Port)
    $timer=[Diagnostics.Stopwatch]::StartNew()
    do {
        try { if((Invoke-RestMethod "http://127.0.0.1:$Port/api/version" -TimeoutSec 5).version){return} } catch {}
        Start-Sleep 2
    } while($timer.Elapsed.TotalSeconds-lt180)
    throw 'AI_HYPERV_OLLAMA_READINESS_TIMEOUT'
}

try {
    $resolution=@(& (Join-Path $repoRoot 'Tools\Initialize-SqlServerLabHostTools.ps1') -Name $OllamaProvider)[0]
    if(-not $resolution.Available){throw "AI_HYPERV_OLLAMA_PROVIDER_UNAVAILABLE: $OllamaProvider"}
    $tool=[string]$resolution.Invocation
    if($OllamaProvider-eq'podman'){& (Join-Path $repoRoot 'Tests\Integration\Initialize-PodmanRuntime.ps1')|Out-Null}
    & $tool info *> $null
    if($LASTEXITCODE-ne0){throw "AI_HYPERV_OLLAMA_PROVIDER_UNREACHABLE: $OllamaProvider"}

    & $tool run -d --name $runtimeName --label sql-server-lab.scope=ai-hyperv-acceptance -p '127.0.0.1::11434' 'ollama/ollama:0.11.10' *> $null
    if($LASTEXITCODE-ne0){throw 'AI_HYPERV_OLLAMA_START_FAILED'}
    $portText=[string](& $tool port $runtimeName '11434/tcp'|Select-Object -First 1)
    if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_HYPERV_OLLAMA_PORT_MISSING'}
    $ollamaPort=[int]$Matches.port
    Wait-HyperVAiOllama -Port $ollamaPort
    foreach($model in @('embeddinggemma:300m-qat-q4_0','gemma3:1b')){
        $body=@{model=$model;stream=$false}|ConvertTo-Json -Compress
        $null=Invoke-RestMethod -Method Post -Uri "http://127.0.0.1:$ollamaPort/api/pull" -ContentType application/json -Body $body -TimeoutSec $TimeoutSeconds
    }

    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $target=& $module {param($id) Resolve-LabRunInstance -RunId $id -InstanceId primary} $RunId
    if($target.Provider-ne'hyperv'){throw 'AI_HYPERV_TARGET_PROVIDER_INVALID'}
    if(($target.Version-split'-',2)[0]-ne'2025'){throw 'AI_HYPERV_TARGET_SQL_VERSION_INVALID'}

    $documents=@(
        @{Id='backup-policy';Content='SQL Server Lab überprüft synthetische Sicherungen täglich.'},
        @{Id='cleanup-policy';Content='Run-eigene Testressourcen werden nach der Abnahme vollständig entfernt.'}
    )
    $ragArgs=@{RunId=$RunId;SaPassword=$SaPassword;Question='Wie oft werden Sicherungen überprüft?';Document=$documents;LocalPort=$ollamaPort;TopK=1;Confirm=$false}
    $agentArgs=@{RunId=$RunId;SaPassword=$SaPassword;Question='Fasse den synthetischen Serverzustand zusammen.';ToolId=@('server-summary','wait-statistics');LocalPort=$ollamaPort;Confirm=$false}
    $rag=Invoke-SqlServerLabAiRag @ragArgs
    $agent=Invoke-SqlServerLabAiDiagnosticAgent @agentArgs
    if($rag.Status-ne'SUCCEEDED'-or$rag.Citations[0]-ne'backup-policy'){throw 'AI_HYPERV_RAG_RESULT_FAILED'}
    if($agent.Status-ne'SUCCEEDED'-or$agent.ToolExecutions.Count-ne2){throw 'AI_HYPERV_AGENT_RESULT_FAILED'}

    $loginCount=& $module {param($hostName,$port,$secret)$plain=ConvertFrom-LabSecureString $secret;try{@(Invoke-SqlQuery -HostName $hostName -Port $port -SaPlain $plain -Query "SET NOCOUNT ON; SELECT COUNT(*) FROM sys.server_principals WHERE name LIKE 'sql_lab_ai_%';")[-1]}finally{$plain=$null}} $target.HostName $target.Port $SaPassword
    if([int]$loginCount-ne0){throw 'AI_HYPERV_AGENT_LOGIN_CLEANUP_FAILED'}

    $sqlRestart='PASSED'
    try {
        $restart=Restart-SqlServerLab -RunId $RunId -TimeoutSeconds 300 -Force
        if($restart.Action-in@('CANCELLED','SKIPPED')){throw 'AI_HYPERV_SQL_RESTART_FAILED'}
    }
    catch {
        if($_.Exception.Message -match '^TEST_ENVIRONMENT_GROUP_PROTECTED:'){$sqlRestart='PROTECTED_GROUP_NOT_EXECUTED'}
        else { throw }
    }
    & $tool restart $runtimeName *> $null
    if($LASTEXITCODE-ne0){throw 'AI_HYPERV_OLLAMA_RESTART_FAILED'}
    $portText=[string](& $tool port $runtimeName '11434/tcp'|Select-Object -First 1)
    if($portText-notmatch':(?<port>[0-9]+)$'){throw 'AI_HYPERV_OLLAMA_RESTART_PORT_MISSING'}
    $ragArgs.LocalPort=[int]$Matches.port
    $agentArgs.LocalPort=$ragArgs.LocalPort
    Wait-HyperVAiOllama -Port $ragArgs.LocalPort
    if((Invoke-SqlServerLabAiRag @ragArgs).Status-ne'SUCCEEDED'){throw 'AI_HYPERV_RAG_RESTART_RESULT_FAILED'}
    if((Invoke-SqlServerLabAiDiagnosticAgent @agentArgs).Status-ne'SUCCEEDED'){throw 'AI_HYPERV_AGENT_RESTART_RESULT_FAILED'}

    $succeeded=$true
    [PSCustomObject]@{Contract=[PSCustomObject]@{Name='SqlServerLab.AiHyperVAcceptance';Version='1.0'};Status=$(if($sqlRestart-eq'PASSED'){'PASSED'}else{'PARTIAL'});Provider='hyperv';OllamaProvider=$OllamaProvider;Rag='PASSED';Agent='PASSED';LoginCleanup='PASSED';SqlRestart=$sqlRestart;OllamaRestart='PASSED'}
}
finally {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($tool-and($succeeded-or-not$KeepOllamaOnFailure)){& $tool rm -f $runtimeName *> $null}
}
