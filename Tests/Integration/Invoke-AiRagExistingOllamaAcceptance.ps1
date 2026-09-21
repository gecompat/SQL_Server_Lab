#Requires -Version 7.2
<#
.SYNOPSIS
    Prüft vorhandene Host-Embeddings und explizite Cloudgeneration auf eigenem SQL-Run.
.DESCRIPTION
    Keine Hostmodell-Downloads, kein Hostservice-Lifecycle. Zwei synthetische
    RAG-Aufrufe mit höchstens zwei Cloudrequests, eigener SQLrestart und
    scopegebundenes Cleanup. LocalGeneration verwendet stattdessen vorhandenes
    Qwen; IncludeDiagnostic prüft dabei zusätzlich Login-Cleanup vor/nach Restart.
    Dies ersetzt nicht das lokale Golden-v1-Gate.
#>
[CmdletBinding(DefaultParameterSetName='Cloud')]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory,ParameterSetName='Cloud')][string]$SecretFilePath,
    [Parameter(Mandatory,ParameterSetName='Local')][switch]$LocalGeneration,
    [Parameter(ParameterSetName='Local')][switch]$IncludeDiagnostic,
    [ValidateRange(1024,65535)][int]$LocalPort=11434,
    [ValidateRange(90,230)][int]$GenerationTimeoutSeconds=120,
    [switch]$RuntimeMutexAlreadyHeld
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-host-acceptance-'+[guid]::NewGuid().ToString('N'))
$state=Join-Path $root 'state';$data=Join-Path $root 'Lab_Data'
$operation=[guid]::NewGuid().ToString('D');$module=$null;$binding=$null;$password=$null
$oldState=$env:SQL_SERVER_LAB_STATE;$oldData=$env:SQL_SERVER_LAB_DATA_ROOT
$complete=$false;$cleanupFailed=$false;$mutex=$null;$acquired=$false
function Assert-HostRag {param([bool]$Condition,[string]$Name)if(-not $Condition){throw "AI_HOST_RAG_ACCEPTANCE_FAILED: $Name"};Write-Host "PASS: $Name"}
function Get-HostRagInventoryKey {
    param($Module,[int]$Port)
    & $Module {
        param($Port)
        $tags=Invoke-LabAiHostMetadata -Port $Port -Path /api/tags
        # Die API garantiert keine Reihenfolge ihrer Modellliste.
        Get-LabAiPlanKey -InputObject @($tags.models|Sort-Object -Property name -CaseSensitive)
    } $Port
}
function Assert-HostRagDiagnostic {
    param($Module,$Binding,[SecureString]$Password,[string]$StateRoot,[int]$Port)
    $result=Invoke-SqlServerLabAiDiagnosticAgent -RunId $Binding.RunId -SaPassword $Password -Question 'Fasse den SQL-Testserverzustand knapp zusammen.' -ToolId server-summary,wait-statistics -GenerationModelKey ollama-qwen25-coder-7b-local -LocalPort $Port -StateRoot $StateRoot -Confirm:$false
    $count=& $Module {
        param($Binding,$Password)
        $rows=@(Invoke-LabAiSqlCommand -HostName $Binding.HostName -Port $Binding.Port -Credential ([PSCredential]::new('sa',$Password)) -Sql "SELECT COUNT(*) AS LoginCount FROM sys.server_principals WHERE name LIKE 'sql_lab_ai_%';")
        if($rows.Count -ne 1){throw 'AI_HOST_RAG_LOGIN_PROBE_INVALID'}
        [int]$rows[0].LoginCount
    } $Binding $Password
    Assert-HostRag ($result.Status -eq 'SUCCEEDED' -and $result.ToolExecutions.Count -eq 2 -and $result.Metrics.RequestCount -eq 1 -and $count -eq 0) 'Lokale Diagnose mit genau einem Request und vollständigem Login-Cleanup'
}
try{
    if(-not $RuntimeMutexAlreadyHeld){$mutex=[Threading.Mutex]::new($false,$(if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}));$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(10));if(-not $acquired){throw 'AI_HOST_RAG_LOCK_TIMEOUT'}}
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    Assert-HostRag ([bool]$resolution.Available) 'Providerwerkzeug verfügbar'
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $hostTags=Get-HostRagInventoryKey -Module $module -Port $LocalPort
    $probe=& $module {param($Port)$p=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $Port;Get-LabAiHostModelBinding -Plan $p} $LocalPort
    Assert-HostRag ($probe.Dimension -eq 768) 'Vorhandenes lokales Embeddingmodell geprüft'
    if($LocalGeneration){
        $null=& $module {param($Port)$p=New-LabAiEndpointPlan -ModelKey ollama-qwen25-coder-7b-local -EndpointRef ollama-local -Lane local -LocalPort $Port;Get-LabAiHostModelBinding -Plan $p} $LocalPort
    }
    $null=New-Item -ItemType Directory -Path $root
    $env:SQL_SERVER_LAB_STATE=$state;$env:SQL_SERVER_LAB_DATA_ROOT=$data
    & $module {param($Data)$null=Initialize-LabManagedDataRoot -DataRoot $Data -ControllerId ([guid]::NewGuid().ToString('D')) -Confirm:$false} $data
    $lab=& $module {
        param($Provider,$State,$Operation)
        Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($Provider,$State)
            New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 -LabName 'ai-host-rag-acceptance' -StateRoot $State -GenerateSaPassword -NonInteractive -Drives @([pscustomobject]@{id='rag-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($Provider,$State)
    } $Provider $state $operation
    Assert-HostRag ($lab.State -eq 'Running') 'Eigener SQL-2025-Run läuft'
    $binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    $password=& $module {param($Run,$State)Get-LabRelationalCoreSecret -RunId $Run -StateRoot $State} $lab.RunId $state
    $documents=@(
        @{Id='backup-policy';Content='SQL Server Lab überprüft synthetische Sicherungen täglich.'},
        @{Id='network-policy';Content='Das synthetische Labnetz verwendet ausschließlich isolierte Testadressen.'},
        @{Id='cleanup-policy';Content='Run-eigene Testressourcen werden nach der Abnahme vollständig entfernt.'}
    )
    $parameters=@{RunId=$lab.RunId;SaPassword=$password;Document=$documents;TopK=2;EmbeddingModelKey='ollama-embeddinggemma-latest';GenerationTimeoutSeconds=$GenerationTimeoutSeconds;GenerationRetryCount=0;LocalPort=$LocalPort;StateRoot=$state;Question='Wie oft werden synthetische Sicherungen überprüft?'}
    if($LocalGeneration){$parameters.GenerationModelKey='ollama-qwen25-coder-7b-local';$parameters.GenerationLane='local'}
    else{$parameters.GenerationModelKey='ollama-gpt-oss-120b-cloud';$parameters.GenerationLane='cloud';$parameters.AllowCloudEgress=$true;$parameters.DataClassification='synthetic-only';$parameters.SecretFilePath=$SecretFilePath}
    $preview=Invoke-SqlServerLabAiRag @parameters -WhatIf
    Assert-HostRag ($preview.GenerationLane -eq $parameters.GenerationLane -and $preview.Egress -eq $(if($LocalGeneration){'denied'}else{'explicit'})) 'WhatIf zeigt exakt die ausgewählte Generationlane'
    $first=Invoke-SqlServerLabAiRag @parameters -Confirm:$false
    Assert-HostRag ($first.Status -eq 'SUCCEEDED' -and $first.Citations.Count -eq 2 -and $first.Citations[0] -ceq 'backup-policy' -and -not [string]::IsNullOrWhiteSpace($first.Answer)) 'SQL-Retrieval trifft backup-policy und das gewählte Modell antwortet'
    Assert-HostRag ($first.Metrics.RequestCount -ge 5 -and $first.Metrics.RequestCount -le 9 -and $first.HostEmbeddingBinding.Digest -ceq $probe.Digest) 'Begrenzte Requests und Live-Modellbindung'
    if($IncludeDiagnostic){Assert-HostRagDiagnostic -Module $module -Binding $binding -Password $password -StateRoot $state -Port $LocalPort}
    $null=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false
    $afterBinding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $lab.RunId $state $operation
    Assert-HostRag ($afterBinding.ContainerId -ceq $binding.ContainerId) 'Eigener SQLrestart ist bereit und identitätsgleich'
    $parameters.Question='Was geschieht nach der Abnahme mit run-eigenen Testressourcen?'
    $second=Invoke-SqlServerLabAiRag @parameters -Confirm:$false
    Assert-HostRag ($second.Status -eq 'SUCCEEDED' -and $second.Citations.Count -eq 2 -and $second.Citations[0] -ceq 'cleanup-policy' -and -not [string]::IsNullOrWhiteSpace($second.Answer)) 'Nach SQLrestart trifft Retrieval cleanup-policy'
    if($IncludeDiagnostic){Assert-HostRagDiagnostic -Module $module -Binding $afterBinding -Password $password -StateRoot $state -Port $LocalPort}
    $tagsAfter=Get-HostRagInventoryKey -Module $module -Port $LocalPort
    Assert-HostRag ($hostTags -ceq $tagsAfter -and $second.HostEmbeddingBinding.Digest -ceq $probe.Digest) 'Hostmodellinventar und Modelldigest bleiben unverändert'
    $complete=$true
}finally{
    if($password){$password.Dispose()}
    if($module){
        try{
            $owned=& $module {param($Op,$State)Get-LabOperationOwnedRun -OperationId $Op -StateRoot $State} $operation $state
            if($owned){
                if(-not $binding){$binding=& $module {param($Run,$State,$Op)Get-LabTransferBinding -RunId $Run -InstanceId primary -StateRoot $State -OperationId $Op} $owned.runId $state $operation}
                $removed=Remove-SqlServerLab -RunId $owned.runId -StateRoot $state -Force -Confirm:$false
                if($removed.Status -ne 'REMOVED'){throw 'cleanup'}
            }
            if($binding){& $module {param($Binding)Assert-LabTransferNoResidue -Binding $Binding} $binding}
        }catch{$cleanupFailed=$true;Write-Warning 'AI_HOST_RAG_CLEANUP_RECOVERY_REQUIRED'}
    }
    $env:SQL_SERVER_LAB_STATE=$oldState;$env:SQL_SERVER_LAB_DATA_ROOT=$oldData
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    if($mutex){if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if(-not $cleanupFailed -and (Test-Path -LiteralPath $root)){
        $resolved=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
        if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-ai-host-acceptance-*'){throw 'AI_HOST_RAG_CLEANUP_SCOPE_INVALID'}
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
if($cleanupFailed -or -not $complete){throw 'AI_HOST_RAG_ACCEPTANCE_INCOMPLETE'}
Write-Host "AI EXISTING HOST OLLAMA RAG ACCEPTANCE: PASS ($Provider; GenerationLane=$($parameters.GenerationLane); Diagnostic=$([bool]$IncludeDiagnostic); SQLrestart; own cleanup)"
