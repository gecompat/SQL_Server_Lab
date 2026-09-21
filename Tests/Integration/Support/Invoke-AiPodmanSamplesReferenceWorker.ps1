#Requires -Version 7.2
[CmdletBinding()]
param([Parameter(Mandatory)][string]$EvidenceRoot,[Parameter(Mandatory)][guid]$OperationId,
    [Parameter(Mandatory)][ValidateSet('ACCEPTANCE','CLEANUP')][string]$Stage)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$receipt=[ordered]@{OperationId=$OperationId.ToString('D');Stage=$Stage;Status='FAILED';Assertions=0}
$exitCode=1
try {
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $count=& $module {
        param($Root,$Operation,$Phase,$Helper)
        . $Helper
        $record=Read-AiPodmanSamplesOperation -EvidenceRoot $Root -OperationId $Operation
        $env:SQL_SERVER_LAB_STATE=$record.StateRoot;$env:SQL_SERVER_LAB_DATA_ROOT=$record.DataRoot
        if($Phase -ceq 'CLEANUP'){Remove-AiPodmanSamplesOwnedRun $record;return 1}
        Assert-AiPodmanSamplesRuntime $record
        $endpoint=New-LabAiEndpointPlan -ModelKey ollama-embeddinggemma-latest -EndpointRef ollama-local -Lane local -LocalPort $record.LocalPort
        $model=Get-LabAiHostModelBinding -Plan $endpoint
        if($model.Model -cne 'embeddinggemma:latest' -or $model.Dimension -ne 768){throw 'SAMPLES_MODEL_INVALID'}
        if($record.NewStarted){throw 'SAMPLES_ALREADY_STARTED'}
        $record.NewStarted=$true
        Write-LabArtifactJsonAtomic -Path (Join-Path $Root 'operation.json') -InputObject $record
        $lab=Invoke-WithLabWorkflowOperationContext -OperationId $Operation -ScriptBlock {
            param($State,$Data)
            New-SqlServerLab -Version 2025 -Provider podman -Profile compact -Port 0 -Cpu 1 -MemoryMB 2560 `
                -LabName 'ai-podman-samples-reference' -Sample @('northwind:script','chinook:sql-server') `
                -Drives @([pscustomobject]@{id='ai-data';containerPath='/var/opt/mssql'}) `
                -GenerateSaPassword -NonInteractive -StateRoot $State -DataRoot $Data
        } -ArgumentList @($record.StateRoot,$record.DataRoot)
        if($lab.State -ine 'RUNNING' -or @($lab.Instances).Count -ne 1){throw 'SAMPLES_NEW_FAILED'}
        $binding=Get-LabTransferBinding -RunId $lab.RunId -InstanceId primary -StateRoot $record.StateRoot -OperationId $Operation
        if($binding.Provider -cne 'podman' -or $binding.RuntimeScopeId -cne $record.RuntimeScopeId){throw 'SAMPLES_BINDING_INVALID'}
        $identity=Get-LabTransferBindingIdentity $binding
        $before=Get-AiPodmanSamplesContentEvidence -Binding $binding -StateRoot $record.StateRoot
        if(-not (Test-AiPodmanSamplesContentEvidence $before)){throw 'SAMPLES_CONTENT_INVALID'}
        $retrievalArguments=@{RunId=$lab.RunId;InstanceId='primary';CollectionId=$record.CollectionId;StateRoot=$record.StateRoot;LocalPort=$record.LocalPort;TimeoutSeconds=300;Confirm=$false}
        $applied=Invoke-SqlServerLabAiPersistentRetrieval @retrievalArguments -FixtureRevision Initial
        $query=Invoke-SqlServerLabAiPersistentRetrieval @retrievalArguments -Action Query -QueryId backup
        if($applied.Status -cne 'COMMITTED' -or $query.Status -cne 'QUERIED' -or $query.Ranked[0].ChunkId -cne 'backup-policy'){throw 'SAMPLES_RETRIEVAL_FAILED'}
        $restart=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force -Confirm:$false
        if($restart.Status -cne 'RUNNING' -or $restart.Errors){throw 'SAMPLES_RESTART_FAILED'}
        $afterBinding=Assert-LabTransferBinding -Expected $identity -StateRoot $record.StateRoot -OperationId $Operation
        $after=Get-AiPodmanSamplesContentEvidence -Binding $afterBinding -StateRoot $record.StateRoot
        $query=Invoke-SqlServerLabAiPersistentRetrieval @retrievalArguments -Action Query -QueryId backup
        if(-not (Test-AiPodmanSamplesContentEvidence $after) -or $after.NorthwindOrders -ne $before.NorthwindOrders -or $after.ChinookArtists -ne $before.ChinookArtists){throw 'SAMPLES_RESTART_CONTENT_INVALID'}
        if($query.Status -cne 'QUERIED' -or $query.Generation -ne 1 -or $query.Ranked[0].ChunkId -cne 'backup-policy'){throw 'SAMPLES_RESTART_RETRIEVAL_FAILED'}
        Assert-LabAiHostModelBinding -Plan $endpoint -Expected $model
        return 9
    } $EvidenceRoot $OperationId.ToString('D') $Stage (Join-Path $repoRoot 'Tests/Common/AiPodmanSamplesReferenceScenario.ps1')
    $receipt.Assertions=[int]$count;$receipt.Status='COMPLETED';$exitCode=0
}
catch {
    # Only fixed test failure codes can reach even the private diagnostic stream.
    if($_.Exception.Message -cmatch '^SAMPLES_[A-Z_]{1,64}$'){Write-Host $_.Exception.Message}
    else{Write-Host 'AI_PODMAN_SAMPLES_WORKER_FAILED'}
}
finally {[IO.File]::WriteAllText((Join-Path $EvidenceRoot ($Stage+'.receipt.json')),($receipt|ConvertTo-Json -Compress))}
exit $exitCode
