#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[Parameter(Mandatory)][guid]$OperationId,
    [Parameter(Mandatory)][ValidateSet('ACCEPTANCE','CLEANUP')][string]$Stage)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$receipt=[ordered]@{OperationId=$OperationId.ToString('D');Stage=$Stage;Status='FAILED';Assertions=0;FailureCode='NONE'}
$failureCodes=@('SAMPLES_ALREADY_STARTED','SAMPLES_BINDING_INVALID','SAMPLES_CONTENT_INVALID','SAMPLES_MODEL_INVALID',
    'SAMPLES_NEW_FAILED','SAMPLES_RESTART_CONTENT_INVALID','SAMPLES_RESTART_FAILED',
    'SAMPLES_RESTART_RETRIEVAL_FAILED','SAMPLES_RETRIEVAL_FAILED',
    'AI_RAG_HOST_ENDPOINT_INVALID','AI_RAG_HOST_VERSION_UNSUPPORTED','AI_RAG_HOST_MODEL_IDENTITY_INVALID',
    'AI_RAG_HOST_REMOTE_MODEL_FORBIDDEN','AI_RAG_HOST_CAPABILITY_INVALID','AI_RAG_HOST_DIMENSION_INVALID',
    'AI_RAG_HOST_METADATA_FAILED','AI_RAG_HOST_MODEL_DRIFT',
    'AI_RAG_HOST_METADATA_VERSION_FAILED','AI_RAG_HOST_METADATA_TAGS_FAILED','AI_RAG_HOST_METADATA_SHOW_FAILED')
$metadataDiagnosticFailureCodes=@('AI_RAG_HOST_METADATA_TIMEOUT_FAILED','AI_RAG_HOST_METADATA_TLS_FAILED',
    'AI_RAG_HOST_METADATA_TRANSPORT_FAILED','AI_RAG_HOST_METADATA_HTTP_FAILED','AI_RAG_HOST_METADATA_JSON_FAILED',
    'AI_RAG_HOST_METADATA_UNCLASSIFIED_FAILED')
$failureCodes+= $metadataDiagnosticFailureCodes
$workerStages=@('HOST_TOOL_INITIALIZATION','MODULE_IMPORT','WORKER_INVOCATION','SCENARIO_HELPER_LOAD','OPERATION_READ','RUNTIME_ASSERTION','ENDPOINT_PLAN','MODEL_BINDING',
    'OPERATION_RECORD_WRITE','LAB_CREATE','TRANSFER_BINDING','TRANSFER_BINDING_IDENTITY','INITIAL_CONTENT_EVIDENCE',
    'INITIAL_RETRIEVAL','RESTART','RESTART_TRANSFER_BINDING','RESTART_CONTENT_EVIDENCE','RESTART_RETRIEVAL',
    'MODEL_REVALIDATION','OWNED_RUN_CLEANUP')
$workerFailureCodes=@($workerStages|ForEach-Object {'AI_PODMAN_SAMPLES_WORKER_FAILED_AT_'+$_})
$failureCodes+= $workerFailureCodes
$workerStage='MODULE_IMPORT'
$exitCode=1
try {
    $workerStage='HOST_TOOL_INITIALIZATION'
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name podman | Where-Object Name -ceq 'podman')[0]
    if (-not $resolution -or -not $resolution.Available -or [string]::IsNullOrWhiteSpace([string]$resolution.Invocation) -or
        -not [IO.Path]::IsPathFullyQualified([string]$resolution.Invocation)) { throw 'AI_PODMAN_SAMPLES_HOST_TOOL_UNAVAILABLE' }
    $env:SQL_SERVER_LAB_PODMAN_PATH=[string]$resolution.Invocation
    $workerStage='MODULE_IMPORT'
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $workerStage='WORKER_INVOCATION'
    $count=& $module {
        param($Root,$Operation,$Phase,$Helper,$AllowedFailureCodes,$AllowedWorkerFailureCodes)
        $workerStage='SCENARIO_HELPER_LOAD'
        try {
            . $Helper
            $workerStage='OPERATION_READ'
            $record=Read-AiPodmanSamplesOperation -EvidenceRoot $Root -OperationId $Operation
            $env:SQL_SERVER_LAB_STATE=$record.StateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$record.DataRoot
            if($Phase -ceq 'CLEANUP'){
                $workerStage='OWNED_RUN_CLEANUP'
                Remove-AiPodmanSamplesOwnedRun $record
                return 1
            }
            $workerStage='RUNTIME_ASSERTION'
            Assert-AiPodmanSamplesRuntime $record
            $workerStage='ENDPOINT_PLAN'
            $endpoint=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $record.LocalPort
            $workerStage='MODEL_BINDING'
            $metadataTransport={
                param($Path,$Model)
                $metadataStage=switch($Path){'/api/version'{'VERSION'}'/api/tags'{'TAGS'}'/api/show'{'SHOW'}default{$null}}
                if(-not $metadataStage){throw 'AI_RAG_HOST_METADATA_FAILED'}
                try {Invoke-LabAiHostMetadata -Port $endpoint.Port -Path $Path -Model $Model -ExposeFailureCategory}
                catch {
                    if($_.Exception.Message -ceq 'AI_RAG_HOST_METADATA_FAILED'){
                        throw ('AI_RAG_HOST_METADATA_'+$metadataStage+'_FAILED')
                    }
                    if($metadataDiagnosticFailureCodes -ccontains $_.Exception.Message){throw $_}
                    throw
                }
            }
            $model=Get-LabAiHostModelBinding -Plan $endpoint -MetadataTransport $metadataTransport
            if($model.Model -cne 'embeddinggemma:latest' -or $model.Dimension -ne 768){throw 'SAMPLES_MODEL_INVALID'}
            if($record.NewStarted){throw 'SAMPLES_ALREADY_STARTED'}
            $record.NewStarted=$true
            $workerStage='OPERATION_RECORD_WRITE'
            Write-LabArtifactJsonAtomic -Path (Join-Path $Root 'operation.json') -InputObject $record
            $workerStage='LAB_CREATE'
            $lab=Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
                param($State,$Data)
                New-SqlServerLab -Version 2025 -Provider podman -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 `
                    -LabName 'ai-podman-samples-reference' -Sample @('northwind:script','chinook:sql-server') `
                    -Drives @([pscustomobject]@{id='ai-data';containerPath='/var/opt/mssql'}) `
                    -GenerateSaPassword -NonInteractive -StateRoot $State -DataRoot $Data
            } -ArgumentList @($record.StateRoot,$record.DataRoot)
            if($lab.State -ine 'RUNNING' -or @($lab.Instances).Count -ne 1){throw 'SAMPLES_NEW_FAILED'}
            $workerStage='TRANSFER_BINDING'
            $binding=Get-LabTransferBinding -RunId $lab.RunId -InstanceId primary -StateRoot $record.StateRoot -OperationId $Operation
            if($binding.Provider -cne 'podman' -or $binding.RuntimeScopeId -cne $record.RuntimeScopeId){throw 'SAMPLES_BINDING_INVALID'}
            $workerStage='TRANSFER_BINDING_IDENTITY'
            $identity=Get-LabTransferBindingIdentity $binding
            $workerStage='INITIAL_CONTENT_EVIDENCE'
            $before=Get-AiPodmanSamplesContentEvidence -Binding $binding -StateRoot $record.StateRoot
            if(-not (Test-AiPodmanSamplesContentEvidence $before)){throw 'SAMPLES_CONTENT_INVALID'}
            $retrievalArguments=@{RunId=$lab.RunId;InstanceId='primary';CollectionId=$record.CollectionId;StateRoot=$record.StateRoot;LocalPort=$record.LocalPort;TimeoutSeconds=300;Confirm=$false}
            $workerStage='INITIAL_RETRIEVAL'
            $applied=Invoke-SqlServerLabAiPersistentRetrieval @retrievalArguments -FixtureRevision Initial
            $query=Invoke-SqlServerLabAiPersistentRetrieval @retrievalArguments -Action Query -QueryId backup
            if($applied.Status -cne 'COMMITTED' -or $query.Status -cne 'QUERIED' -or $query.Ranked[0].ChunkId -cne 'backup-policy'){throw 'SAMPLES_RETRIEVAL_FAILED'}
            $workerStage='RESTART'
            $restart=Restart-SqlServerLab -RunId $lab.RunId -StateRoot $record.StateRoot -TimeoutSeconds 180 -Force -Confirm:$false
            if($restart.Status -cne 'RUNNING' -or $restart.Errors){throw 'SAMPLES_RESTART_FAILED'}
            $workerStage='RESTART_TRANSFER_BINDING'
            $afterBinding=Assert-LabTransferBinding -Expected $identity -StateRoot $record.StateRoot -OperationId $Operation
            $workerStage='RESTART_CONTENT_EVIDENCE'
            $after=Get-AiPodmanSamplesContentEvidence -Binding $afterBinding -StateRoot $record.StateRoot
            $workerStage='RESTART_RETRIEVAL'
            $query=Invoke-SqlServerLabAiPersistentRetrieval @retrievalArguments -Action Query -QueryId backup
            if(-not (Test-AiPodmanSamplesContentEvidence $after) -or $after.NorthwindOrders -ne $before.NorthwindOrders -or $after.ChinookArtists -ne $before.ChinookArtists){throw 'SAMPLES_RESTART_CONTENT_INVALID'}
            if($query.Status -cne 'QUERIED' -or $query.Generation -ne 1 -or $query.Ranked[0].ChunkId -cne 'backup-policy'){throw 'SAMPLES_RESTART_RETRIEVAL_FAILED'}
            $workerStage='MODEL_REVALIDATION'
            Assert-LabAiHostModelBinding -Plan $endpoint -Expected $model
            return 9
        }
        catch {
            if($AllowedFailureCodes -ccontains $_.Exception.Message){throw $_}
            $stageFailureCode='AI_PODMAN_SAMPLES_WORKER_FAILED_AT_'+$workerStage
            if($AllowedWorkerFailureCodes -ccontains $stageFailureCode){throw $stageFailureCode}
            throw 'AI_PODMAN_SAMPLES_WORKER_FAILED'
        }
    } $EvidenceRoot $OperationId.ToString('D') $Stage (Join-Path $repoRoot 'Tests/Common/AiPodmanSamplesReferenceScenario.ps1') $failureCodes $workerFailureCodes
    $receipt.Assertions=[int]$count;$receipt.Status='COMPLETED';$exitCode=0
}
catch {
    # Only explicitly enumerated test failures cross into the sanitized receipt.
    if($failureCodes -ccontains $_.Exception.Message){$receipt.FailureCode=$_.Exception.Message}
    else {
        $stageFailureCode='AI_PODMAN_SAMPLES_WORKER_FAILED_AT_'+$workerStage
        if($workerFailureCodes -ccontains $stageFailureCode){$receipt.FailureCode=$stageFailureCode}
        else{$receipt.FailureCode='AI_PODMAN_SAMPLES_WORKER_FAILED'}
    }
    Write-Host $receipt.FailureCode
}
finally {[IO.File]::WriteAllText((Join-Path $EvidenceRoot ($Stage+'.receipt.json')),($receipt|ConvertTo-Json -Compress))}
exit $exitCode
