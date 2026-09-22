#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-ai-setup-checks-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory $root
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root)
        $script:count=0;$script:newCalls=0;$script:mode='none'
        function Check([bool]$Condition,[string]$Name) {
            if(-not $Condition){throw "AI_SETUP_CHECK_FAILED: $Name"}
            $script:count++;Write-Host "PASS: $Name"
        }
        function Reject([scriptblock]$Action,[string]$Code) {
            $caught=$null;try{& $Action|Out-Null}catch{$caught=$_.Exception.Message}
            Check ($caught -and $caught -match $Code) "Reject $Code"
        }
        $script:probeKeys=[Collections.Generic.List[string]]::new();$script:probeFails=$false
        function Initialize-LabHostToolPath {param($Name) Check ($Name -ceq 'podman') 'Every preflight initializes the requested host tool'}
        function Invoke-LabTransferNative {
            param($Provider,$Arguments,$TimeoutSeconds)
            Check ($Provider -ceq 'podman' -and $TimeoutSeconds -eq 20) 'Preflight runtime metadata uses bounded Podman probes'
            if($script:probeFails){throw 'SYNTHETIC_PROBE_TIMEOUT'}
            $key=$Arguments -join ' ';$script:probeKeys.Add($key)
            switch($key) {
                'info --format json' {return '{"Version":{"Version":"5.0.0"},"Store":{"GraphDriverName":"overlay","GraphRoot":"/synthetic"},"Host":{"Security":{"Rootless":true}}}'}
                'machine list --format json' {return '[]'}
                'system connection list --format json' {return '[{"Name":"synthetic","URI":"unix:///synthetic/podman.sock","IsMachine":false,"Default":true}]'}
                default {throw 'SYNTHETIC_UNEXPECTED_COMMAND'}
            }
        }
        $boundedScope=Get-LabAiPodmanSetupRuntimeScope
        Check ($boundedScope.Status -ceq 'AVAILABLE' -and $boundedScope.RuntimeId -cmatch '^runtime-scope-[a-f0-9]{24}$') 'Existing scope converter binds bounded producer-shaped Podman evidence'
        Check (($script:probeKeys -join '|') -ceq 'info --format json|machine list --format json|system connection list --format json') 'Preflight never starts or changes a machine'
        $script:probeFails=$true
        Reject {Get-LabAiPodmanSetupRuntimeScope} 'AI_PODMAN_SETUP_RUNTIME_NOT_READY'
        $script:runtime='runtime-scope-'+('a'*24)
        function Get-LabClientRuntimeReadiness {
            param($Provider)
            [pscustomobject]@{Status=$(if($script:mode -ceq 'runtime-missing'){'BLOCKED'}else{'PASS'})}
        }
        function Get-LabContainerRuntimeScope {param($Provider)[pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:runtime}}
        function Get-LabAiPodmanSetupRuntimeScope {[pscustomobject]@{Status='AVAILABLE';RuntimeId=$script:runtime}}
        function Invoke-LabAiHostMetadata {
            param($Port,$Path,$Model)
            $expectedDimension=if($Model -cin @('bge-m3:latest','snowflake-arctic-embed2:latest')){1024}elseif($Model -ceq 'all-minilm:latest'){384}else{768}
            Check ($Port -eq 11434 -and $Model -cin @('embeddinggemma:latest','bge-m3:latest','nomic-embed-text-v2-moe:latest','all-minilm:latest','paraphrase-multilingual:latest','snowflake-arctic-embed2:latest')) 'Preflight uses only a cataloged local model and selected loopback port'
            switch($Path) {
                /api/version {return [pscustomobject]@{version=$(if($script:mode -ceq 'version'){'0.1.0'}else{'0.34.2'})}}
                /api/tags {
                    $models=@([pscustomobject]@{name=$Model;digest=('b'*64)})
                    if($script:mode -ceq 'missing'){$models=@()}
                    if($script:mode -ceq 'digest'){$models[0].digest='invalid'}
                    if($script:mode -ceq 'drift'){$models[0].digest=('c'*64)}
                    return [pscustomobject]@{models=$models}
                }
                /api/show {
                    $show=[pscustomobject]@{capabilities=@('embedding');model_info=[pscustomobject]@{'synthetic.embedding_length'=$expectedDimension};remote_host=''}
                    if($script:mode -ceq 'dimension'){$show.model_info.'synthetic.embedding_length'=$expectedDimension+1}
                    if($script:mode -ceq 'capability'){$show.capabilities=@('completion')}
                    if($script:mode -ceq 'remote'){$show.remote_host='https://synthetic.invalid'}
                    return $show
                }
            }
        }
        foreach($mode in @('runtime-missing','missing','digest','version','dimension','capability','remote')) {
            $script:mode=$mode
            Reject {New-LabAiPodmanSetupPlan} $(if($mode -ceq 'runtime-missing'){'RUNTIME_NOT_READY'}else{'MODEL_UNAVAILABLE'})
            Check ($script:newCalls -eq 0 -and @(Get-ChildItem $Root).Count -eq 0) "$mode blocks before any New or operation state"
        }
        $script:mode='none';$plan=New-LabAiPodmanSetupPlan
        Assert-LabAiPodmanSetupRecord $plan $plan.operationId
        $bgePlan=New-LabAiPodmanSetupPlan -EmbeddingModelKey ollama-bge-m3-latest
        Assert-LabAiPodmanSetupRecord $bgePlan $bgePlan.operationId
        Check ($bgePlan.modelBinding.Model -ceq 'bge-m3:latest' -and $bgePlan.modelBinding.Dimension -eq 1024) 'BGE-M3 plan persists its exact 1024-dimensional binding'
        $nomicPlan=New-LabAiPodmanSetupPlan -EmbeddingModelKey ollama-nomic-embed-text-v2-moe
        Assert-LabAiPodmanSetupRecord $nomicPlan $nomicPlan.operationId
        Check ($nomicPlan.modelBinding.Model -ceq 'nomic-embed-text-v2-moe:latest' -and $nomicPlan.modelBinding.Dimension -eq 768) 'Nomic v2 plan persists its exact 768-dimensional binding'
        $miniPlan=New-LabAiPodmanSetupPlan -EmbeddingModelKey ollama-all-minilm-latest
        Assert-LabAiPodmanSetupRecord $miniPlan $miniPlan.operationId
        Check ($miniPlan.modelBinding.Model -ceq 'all-minilm:latest' -and $miniPlan.modelBinding.Dimension -eq 384 -and $miniPlan.searchMode -ceq 'Hybrid') 'All-MiniLM plan persists its exact 384-dimensional binding and hybrid reference query'
        $paraphrasePlan=New-LabAiPodmanSetupPlan -EmbeddingModelKey ollama-paraphrase-multilingual-latest
        Assert-LabAiPodmanSetupRecord $paraphrasePlan $paraphrasePlan.operationId
        Check ($paraphrasePlan.modelBinding.Model -ceq 'paraphrase-multilingual:latest' -and $paraphrasePlan.modelBinding.Dimension -eq 768 -and $paraphrasePlan.searchMode -ceq 'Vector') 'Paraphrase Multilingual plan persists its exact 768-dimensional binding and vector reference query'
        $snowflakePlan=New-LabAiPodmanSetupPlan -EmbeddingModelKey ollama-snowflake-arctic-embed2-latest
        Assert-LabAiPodmanSetupRecord $snowflakePlan $snowflakePlan.operationId
        Check ($snowflakePlan.modelBinding.Model -ceq 'snowflake-arctic-embed2:latest' -and $snowflakePlan.modelBinding.Dimension -eq 1024 -and $snowflakePlan.searchMode -ceq 'Vector') 'Snowflake Arctic Embed 2 plan persists its exact 1024-dimensional binding and vector reference query'
        $cancelled=Invoke-LabAiPodmanSetup -Plan $plan -StateRoot $Root -WhatIf
        Check ($cancelled.Status -ceq 'CANCELLED' -and @(Get-ChildItem $Root).Count -eq 0) 'WhatIf creates neither worker nor state'
        $cancel=[Threading.CancellationTokenSource]::new();$cancel.Cancel()
        try{$result=Invoke-LabAiPodmanSetup -Plan $plan -StateRoot $Root -CancellationToken $cancel.Token -Confirm:$false}
        finally{$cancel.Dispose()}
        Check ($result.Status -ceq 'CANCELLED' -and @(Get-ChildItem $Root).Count -eq 0) 'Cancelled request is side-effect free'
        $script:mode='drift'
        Reject {Invoke-LabAiPodmanSetup -Plan $plan -StateRoot $Root -Confirm:$false} 'MODEL_CHANGED'
        Check (@(Get-ChildItem $Root).Count -eq 0) 'Preview-to-apply model drift creates no operation or runtime'
        $script:mode='none'
        function New-SqlServerLab {
            param($Version,$Provider,[Alias('Profile')]$LabProfile,$Port,$Cpu,$MemoryMB,$LabName,$StateRoot,[switch]$GenerateSaPassword,[switch]$NonInteractive,$Drives)
            $op=Get-LabWorkflowOperationContext
            $intent=Read-LabAiPodmanSetupRecord $StateRoot $op
            Check ($intent.status -ceq 'CREATING' -and $intent.newStarted -and $intent.collectionId -and $Version -eq '2025' -and $Provider -ceq 'podman' -and
                $GenerateSaPassword -and $NonInteractive -and $Drives.Count -eq 1) 'Real New receives persisted operation/collection, SQL2025 Podman and managed secret intent'
            $script:newCalls++;$script:events.Add('New')
            if($script:mode -ceq 'no-new-state'){throw 'RAW_NEW_SECRET_CANARY'}
            $script:run=@{runId=[guid]::NewGuid().ToString('D');scopeId=[guid]::NewGuid().ToString('D');state='RUNNING';metadata=@{workflowOperationId=$op;persistentData=$false}}
            $path=Join-Path $StateRoot ('runs/'+$script:run.runId);$null=New-Item -ItemType Directory $path -Force
            $script:run|ConvertTo-Json|Set-Content (Join-Path $path 'run-state.json')
            if($script:mode -like 'auto-clean*'){
                $cleanup=New-CleanupPlan -RunDir $path -RunId $script:run.runId -ScopeId $script:run.scopeId -ProviderSubRuns @([pscustomobject]@{id='provider-podman';provider='podman'})
                $null=Add-CleanupStep -RunDir $path -ResourceType volume -ResourceId synthetic-own -Action remove -Provider podman -ProviderSubRunId provider-podman
                $null=Add-CleanupStep -RunDir $path -ResourceType container -ResourceId synthetic-container -Action remove -Provider podman -ProviderSubRunId provider-podman
                $cleanup=Get-CleanupPlan -RunDir $path
                $cleanup.status='COMPLETED';$cleanup.providerSubRuns[0].state='COMPLETED'
                foreach($step in $cleanup.steps){$step.state='COMPLETED'}
                if($script:mode -ceq 'auto-clean-plan'){$cleanup.status='PARTIAL'}
                $cleanup|ConvertTo-Json -Depth 15|Set-Content (Join-Path $path 'cleanup-plan.json')
                $script:run.state='CLEANED_UP'
                if($script:mode -ceq 'auto-clean-operation'){$script:run.metadata.workflowOperationId=[guid]::NewGuid().ToString('N')}
                $script:run|ConvertTo-Json|Set-Content (Join-Path $path 'run-state.json')
                if($script:mode -ceq 'auto-clean-duplicate'){
                    $duplicate=Join-Path $StateRoot ('runs/'+[guid]::NewGuid().ToString('D'))
                    $null=New-Item -ItemType Directory $duplicate
                    $script:run|ConvertTo-Json|Set-Content (Join-Path $duplicate 'run-state.json')
                }
                throw 'RAW_NEW_SECRET_CANARY'
            }
            if($script:mode -ceq 'lost-new'){throw 'RAW_NEW_SECRET_CANARY'}
            [pscustomobject]@{State='RUNNING';RunId=$script:run.runId;Instances=@(@{})}
        }
        function Get-LabTransferBinding {
            param($RunId,$InstanceId,$StateRoot,$OperationId)
            if($OperationId){Check ($OperationId -ceq $script:run.metadata.workflowOperationId) 'Creation binds live run with exact operation'}
            $volumes=if($OperationId){@('synthetic-own')}else{@()}
            [pscustomobject]@{RunId=$RunId;ScopeId=$script:run.scopeId;InstanceId='primary';Provider='podman';RuntimeScopeId=$script:runtime;ContainerId=('d'*64);Volumes=@($volumes);HostName='127.0.0.1';Port=14333}
        }
        function Get-LabProviderSubRuns {
            param($RunId,$StateRoot)
            [pscustomobject]@{
                provider=$(if($script:mode -cin @('provider-drift','auto-clean-provider')){'docker'}else{'podman'})
                state=$(if($script:mode -like 'auto-clean*'){'CLEANED_UP'}else{'RUNNING'})
            }
        }
        function Invoke-SqlServerLabAiPersistentRetrieval {
            param($RunId,$InstanceId,$CollectionId,$StateRoot,$LocalPort,$EmbeddingModelKey,$TimeoutSeconds,$Action,$FixtureRevision,$QueryId,$SearchMode='Vector',[switch]$Confirm)
            $script:events.Add($Action)
            $record=Read-LabAiPodmanSetupRecord $StateRoot $script:operation
            Check ($RunId -ceq $script:run.runId -and $LocalPort -eq 11434 -and ($Action -ceq 'Remove' -or $EmbeddingModelKey -ceq $record.modelBinding.ModelKey)) 'Public retrieval receives exact own run and selected host model binding'
            if($Action -ceq 'Query') { Check ($SearchMode -ceq $record.searchMode) 'Reference query uses the search mode persisted by the setup plan' }
            if($Action -ceq 'Apply') {
                Check ($FixtureRevision -ceq 'Initial' -and $InstanceId -ceq 'primary') 'Only fixed Initial collection is applied'
                $directory=Join-Path $StateRoot ('runs/'+$RunId+'/ai-persistent');$null=New-Item -ItemType Directory $directory -Force
                $plan=New-LabAiPersistentPlan -RunId $RunId -InstanceId primary -CollectionId $CollectionId -Action Apply -FixtureRevision Initial -QueryId backup -SearchMode $SearchMode -LocalPort $LocalPort -EmbeddingModelKey $EmbeddingModelKey -TimeoutSeconds 300
                # Match the real retrieval producer: no OperationId means no volume list in its hash.
                $identity=Get-LabTransferBindingIdentity (Get-LabTransferBinding -RunId $RunId -InstanceId primary -StateRoot $StateRoot)
                $model=$record.modelBinding
                if($script:mode -ceq 'journal-model'){$model.Digest='e'*64}
                $journal=[pscustomobject][ordered]@{
                    contract='SqlServerLab.AiPersistentJournal/1.0';runId=$RunId;scopeId=$script:run.scopeId
                    instanceId='primary';collectionId=$CollectionId;bindingHash=(Get-LabAiPlanKey $identity)
                    databaseName=('SqlLabAi_'+[guid]::NewGuid().ToString('N'));databaseGuid=[guid]::NewGuid().ToString('D')
                    ownerToken=('f'*64);modelBinding=$model;modelHash=(Get-LabAiPlanKey $model)
                    operationId=[guid]::NewGuid().ToString('D');revision='Initial';planKey=$plan.PlanKey
                    datasetHash=$plan.DatasetHash;status='COMMITTED';activeGeneration=1
                    completedChunks=@('backup-policy','cleanup-policy','network-policy')
                }
                Write-LabAiPersistentJournal -Path (Join-Path $directory ('primary-'+$CollectionId+'.json')) -Journal $journal
                Check ($journal.bindingHash -cne (Get-LabAiPlanKey $record.binding)) 'Real retrieval journal identity differs from stronger setup volume ownership identity'
                if($script:mode -ceq 'apply'){throw 'RAW_APPLY_SECRET_CANARY'}
                return [pscustomobject]@{Status='COMMITTED';CollectionId=$CollectionId;Generation=1}
            }
            if($Action -ceq 'Query') {
                Check ($QueryId -ceq 'backup') 'Only fixed backup question is executed'
                if($script:mode -cin @('query','collection-remove','run-remove','runtime-drift','provider-drift','residue','collection-timeout','collection-throws','cleanup-throws')){throw 'RAW_QUERY_SECRET_CANARY'}
                $ranked=@([pscustomobject]@{ChunkId='backup-policy'},[pscustomobject]@{ChunkId='cleanup-policy'},[pscustomobject]@{ChunkId='network-policy'})
                if($script:mode -ceq 'wrong-answer'){$ranked[0].ChunkId='network-policy'}
                return [pscustomobject]@{Status='QUERIED';CollectionId=$CollectionId;Generation=1;Ranked=$ranked}
            }
            if($Action -ceq 'Remove'){
                if($script:mode -ceq 'collection-remove'){throw 'RAW_COLLECTION_SECRET_CANARY'}
                return [pscustomobject]@{Status='REMOVED'}
            }
        }
        function Remove-SqlServerLab {
            param($RunId,$StateRoot,[switch]$Force,[switch]$Confirm)
            Check ($RunId -ceq $script:run.runId -and $Force) 'Whole-run rollback uses only exact owned RunId'
            $script:events.Add('RemoveRun')
            if($script:mode -ceq 'run-remove'){return [pscustomobject]@{Status='RECOVERY_REQUIRED';Cleanup='FAILED';Errors=1}}
            $script:run.state='REMOVED'
            $script:run|ConvertTo-Json|Set-Content (Join-Path $StateRoot ('runs/'+$RunId+'/run-state.json'))
            [pscustomobject]@{Status='REMOVED';Cleanup='CLEANUP_SUCCEEDED';Errors=0}
        }
        function Invoke-LabTransferNative {param($Provider,$Arguments) if($script:mode -cin @('residue','auto-clean-residue')){return 'synthetic-residue'}}
        function Assert-LabTransferNoResidue {param($Binding) if($script:run.state -cne 'REMOVED'){throw 'SYNTHETIC_RESIDUE'}}
        function Invoke-LabAiPodmanSetupChild {
            param($AcceptanceRunner,$Provider,$StateRoot,$OperationId,$EvidenceRoot,$TimeoutSeconds,$Control,$CancellationToken,[string]$Stage='ACCEPTANCE')
            $script:stages.Add($Stage)
            if($Control){$Control.TerminationConfirmed=$true}
            if($Stage -ceq 'ACCEPTANCE' -and $script:mode -ceq 'unconfirmed') {
                $Control.TerminationConfirmed=$false
                return [pscustomobject]@{Status='FAILED';ReasonCode='TERMINATION_UNCONFIRMED';TerminationConfirmed=$false}
            }
            if($Stage -ceq 'COLLECTION_CLEANUP' -and $script:mode -ceq 'collection-throws'){throw 'RAW_COLLECTION_WRAPPER_CANARY'}
            if($Stage -ceq 'CLEANUP' -and $script:mode -ceq 'cleanup-throws'){throw 'RAW_RUN_WRAPPER_CANARY'}
            if($Stage -ceq 'COLLECTION_CLEANUP' -and $script:mode -ceq 'collection-timeout') {
                return [pscustomobject]@{Status='FAILED';ReasonCode='TIMEOUT';TerminationConfirmed=$true}
            }
            try {
                if($Stage -ceq 'ACCEPTANCE'){Invoke-LabAiPodmanSetupApply -StateRoot $StateRoot -OperationId $OperationId}
                elseif($Stage -ceq 'COLLECTION_CLEANUP'){
                    if($script:mode -cin @('runtime-drift','auto-clean-runtime')){$script:runtime='runtime-scope-'+('f'*24)}
                    Remove-LabAiPodmanSetupCollection -StateRoot $StateRoot -OperationId $OperationId
                }else{Remove-LabAiPodmanSetupOwnedRun -StateRoot $StateRoot -OperationId $OperationId}
                [pscustomobject]@{Status='COMPLETED';ReasonCode='NONE';TerminationConfirmed=$true}
            }catch{[pscustomobject]@{Status='FAILED';ReasonCode='CHILD_FAILED';TerminationConfirmed=$true}}
        }
        foreach($mode in @('success','lost-new','apply','query','wrong-answer','journal-model','collection-remove','run-remove','runtime-drift','provider-drift','residue','collection-timeout','collection-throws','cleanup-throws','unconfirmed',
            'auto-clean','auto-clean-residue','auto-clean-plan','auto-clean-runtime','auto-clean-operation','auto-clean-provider','auto-clean-duplicate','no-new-state')) {
            $script:mode='none';$script:runtime='runtime-scope-'+('a'*24)
            $plan=New-LabAiPodmanSetupPlan;$script:operation=$plan.operationId
            $script:mode=$mode;$script:state=Join-Path $Root $mode;$script:run=$null
            $script:events=[Collections.Generic.List[string]]::new();$script:stages=[Collections.Generic.List[string]]::new()
            $result=Invoke-LabAiPodmanSetup -Plan $plan -StateRoot $script:state -Confirm:$false
            Check (($result|ConvertTo-Json -Depth 8) -notmatch 'RAW_|CANARY|runtime-scope|Digest|ContainerId') "$mode result contains no raw runtime/credential output"
            Check (-not (Get-LabWorkflowOperationContext)) 'New operation context restored after success and fault'
            if($mode -ceq 'success'){
                Check ($result.Status -ceq 'READY' -and ($script:events -join '|') -ceq 'New|Apply|Query' -and $script:run.state -ceq 'RUNNING') 'Successful setup retains run, volume and collection without cleanup'
                $entries=@(Get-LabAiPodmanSetupEntries -StateRoot $script:state)
                Check ($entries.Count -eq 1 -and $entries[0].RunId -ceq $result.RunId -and $entries[0].CollectionId -ceq $result.CollectionId) 'Fresh read rediscovers durable run and collection IDs'
                Reject {Remove-LabAiPodmanSetupOwnedRun -StateRoot $script:state -OperationId $plan.operationId} 'RETAINED_RUN_PROTECTED'
                Reject {Invoke-LabAiPodmanSetup -Plan $plan -StateRoot $script:state -Confirm:$false} 'ALREADY_STARTED'
                Check (($script:events -join '|') -ceq 'New|Apply|Query') 'Replay cannot recreate or remove successful run'
            }elseif($mode -like 'auto-clean*' -or $mode -ceq 'no-new-state'){
                Check ($result.PrimaryReason -ceq 'NEW_FAILED' -and ($script:events -join '|') -ceq 'New') "$mode keeps New failure and never mutates terminal or unknown resources"
                if($mode -ceq 'auto-clean'){
                    Check ($result.Status -ceq 'FAILED' -and $result.CleanupStatus -ceq 'COMPLETED' -and $result.RunId -ceq $script:run.runId) 'Producer-shaped successful New auto-cleanup is recognized through exact own terminal evidence'
                }else{Check ($result.Status -ceq 'RECOVERY_REQUIRED') "$mode remains fail-closed without proof of complete own cleanup"}
            }elseif($mode -ceq 'unconfirmed'){
                Check ($result.Status -ceq 'RECOVERY_REQUIRED' -and $script:stages.Count -eq 1) 'Unconfirmed child termination forbids competing cleanup'
            }elseif($mode -cin @('run-remove','runtime-drift','provider-drift','residue','cleanup-throws')){
                Check ($result.Status -ceq 'RECOVERY_REQUIRED' -and $result.PrimaryReason -ceq 'QUERY_FAILED') "$mode preserves primary and reports uncertain cleanup"
                if($mode -like '*drift'){Check (-not $script:events.Contains('RemoveRun')) 'Changed cleanup identity forbids run deletion'}
            }else{
                Check ($result.Status -ceq 'FAILED' -and $result.CleanupStatus -ceq 'COMPLETED' -and $script:run.state -ceq 'REMOVED') "$mode compensates exact own run without claiming success"
                Check (($script:stages -join '|') -ceq 'ACCEPTANCE|COLLECTION_CLEANUP|CLEANUP') 'Independent run cleanup follows completed or terminated collection child'
                if($mode -cin @('collection-remove','collection-timeout','collection-throws')){Check ($result.CollectionCleanup -ceq 'FAILED' -and $script:events.Contains('RemoveRun')) 'Collection failure or timeout never strands own run'}
                if($mode -ceq 'lost-new'){Check ($result.RunId -ceq $script:run.runId) 'Real disk operation discovery recovers lost New reply'}
            }
            Check (Test-Path (Join-Path $script:state ('ai-environments/'+$plan.operationId+'/setup.json'))) 'Operation state remains discoverable after every outcome'
        }
        function Read-LabConsoleTextInput {
            param($Prompt,$Default)
            $script:inputIndex++
            if($script:inputIndex -eq $script:cancelAt){return [pscustomobject]@{Status='Cancelled';Value=$null}}
            [pscustomobject]@{Status='Confirmed';Value=$Default}
        }
        function Read-LabChoice {param($Options,$Prompt,$Default) $script:modelChoice}
        function Read-LabConfirm {param($Prompt,$Default) $script:confirmSetup}
        function Write-LabInfo {param($Message)$script:uiText.Add([string]$Message)}
        function Write-LabWarning {param($Message)$script:uiText.Add([string]$Message)}
        function Write-LabSuccess {param($Message)$script:uiText.Add([string]$Message)}
        function Write-LabStatus {param($Label,$Value,$Color)$script:uiText.Add("${Label}: $Value")}
        function Invoke-LabAiPodmanSetup {
            param($Plan,[switch]$Confirm)
            $script:uiCreates++
            $script:lastUiModel=$Plan.modelBinding
            [pscustomobject]@{Status='READY';RunId='11111111-2222-4333-8444-555555555555';CollectionId=$Plan.collectionId}
        }
        function Get-LabWorkflowLifecycleFingerprint {'synthetic'}
        function Sync-LabConnectionCenterAfterLifecycle {$script:syncCalls++}
        foreach($cancelAt in @(1,2,3,4,5,0)) {
            $script:mode='none';$script:runtime='runtime-scope-'+('a'*24)
            $script:cancelAt=$cancelAt;$script:inputIndex=0;$script:uiCreates=0;$script:syncCalls=0;$script:modelChoice=0
            $script:confirmSetup=$cancelAt -ne 5;$script:uiText=[Collections.Generic.List[string]]::new()
            $action=Invoke-LabActionWithResult -ActionName AiPodmanSetup
            if($cancelAt){Check ($action.Status -ceq 'Cancelled' -and $script:uiCreates -eq 0 -and $script:syncCalls -eq 0) "UI cancel $cancelAt creates no run and triggers no connection sync"}
            else {
                Check ($action.Status -ceq 'Changed' -and $action.ConnectionCenterImpact -ceq 'EndpointSet' -and $script:uiCreates -eq 1 -and $script:syncCalls -eq 1) 'Actual menu dispatch returns ActionResult and synchronizes connection center exactly once'
                Check (($script:uiText -join '|') -match 'RunId: 11111111-' -and ($script:uiText -join '|') -match 'CollectionId:' -and ($script:uiText -join '|') -match 'Suchmodus Vector' -and
                    ($script:uiText -join '|') -notmatch 'Password=|RAW_|Digest|ContainerId') 'UI prints useful IDs without secret or internal runtime details'
            }
        }
        $script:cancelAt=0;$script:inputIndex=0;$script:uiCreates=0;$script:confirmSetup=$true;$script:modelChoice=1;$script:uiText=[Collections.Generic.List[string]]::new()
        $bgeAction=Invoke-LabAiPodmanSetupInteractive
        Check ($bgeAction.Status -ceq 'Changed' -and $script:lastUiModel.ModelKey -ceq 'ollama-bge-m3-latest' -and $script:lastUiModel.Dimension -eq 1024) 'UI selection reaches creation with the exact BGE-M3 binding'
        $script:mode='none';$script:inputIndex=0;$script:cancelAt=0;$script:uiCreates=0;$script:confirmSetup=$true;$script:modelChoice=2;$script:uiText=[Collections.Generic.List[string]]::new()
        $nomicAction=Invoke-LabAiPodmanSetupInteractive
        Check ($nomicAction.Status -ceq 'Changed' -and $script:lastUiModel.ModelKey -ceq 'ollama-nomic-embed-text-v2-moe' -and $script:lastUiModel.Dimension -eq 768) 'UI selection reaches creation with the exact Nomic-v2 binding'
        $script:mode='none';$script:inputIndex=0;$script:cancelAt=0;$script:uiCreates=0;$script:confirmSetup=$true;$script:modelChoice=3;$script:uiText=[Collections.Generic.List[string]]::new()
        $miniAction=Invoke-LabAiPodmanSetupInteractive
        Check ($miniAction.Status -ceq 'Changed' -and $script:lastUiModel.ModelKey -ceq 'ollama-all-minilm-latest' -and $script:lastUiModel.Dimension -eq 384) 'UI selection reaches creation with the exact All-MiniLM binding'
        $script:mode='none';$script:inputIndex=0;$script:cancelAt=0;$script:uiCreates=0;$script:confirmSetup=$true;$script:modelChoice=4;$script:uiText=[Collections.Generic.List[string]]::new()
        $paraphraseAction=Invoke-LabAiPodmanSetupInteractive
        Check ($paraphraseAction.Status -ceq 'Changed' -and $script:lastUiModel.ModelKey -ceq 'ollama-paraphrase-multilingual-latest' -and $script:lastUiModel.Dimension -eq 768) 'UI selection reaches creation with the exact Paraphrase-Multilingual binding'
        $script:mode='none';$script:inputIndex=0;$script:cancelAt=0;$script:uiCreates=0;$script:confirmSetup=$true;$script:modelChoice=5;$script:uiText=[Collections.Generic.List[string]]::new()
        $snowflakeAction=Invoke-LabAiPodmanSetupInteractive
        Check ($snowflakeAction.Status -ceq 'Changed' -and $script:lastUiModel.ModelKey -ceq 'ollama-snowflake-arctic-embed2-latest' -and $script:lastUiModel.Dimension -eq 1024) 'UI selection reaches creation with the exact Snowflake-Arctic-Embed-2 binding'
        $script:mode='missing';$script:inputIndex=0;$script:cancelAt=0;$script:uiCreates=0
        $action=Invoke-LabAiPodmanSetupInteractive
        Check ($action.Status -ceq 'Failed' -and $script:uiCreates -eq 0) 'UI missing model cannot reach creation'
        function Show-LabSubMenu {param($ScreenId,$Title,$Subtitle,$Items)$Items}
        $menu=@(Show-LabAiMenu)
        Check (@($menu|Where-Object Id -ceq AiPodmanSetup).Count -eq 1 -and @($menu|Where-Object Id -ceq AiPodmanEnvironments).Count -eq 1 -and
            @($menu|Where-Object Id -ceq AiGoldenRagEvaluation).Count -eq 1) 'Rendered AI menu exposes creation and discovery while preserving Golden entry'
        Write-Host "AI PODMAN SETUP: $script:count PASS"
    } $root
}
finally {
    $absolute=[IO.Path]::GetFullPath($root);$boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if(-not $absolute.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($absolute) -notmatch '^sql-lab-ai-setup-checks-[a-f0-9]{32}$'){throw 'SYNTHETIC_ROOT_INVALID'}
    Remove-Item -LiteralPath $absolute -Recurse -Force
}
