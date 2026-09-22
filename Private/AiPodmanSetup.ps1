# Own Podman creation workflow. Existing retrieval and provider contracts remain authoritative.
function Get-LabAiPodmanSetupRuntimeScope {
    # UI preflight runs outside the supervised worker, so every native probe is bounded.
    $null=Initialize-LabHostToolPath -Name podman
    $evidence=[ordered]@{
        Provider='podman';Available=$true
        HostPlatform=$(if($IsWindows){'windows'}elseif($IsMacOS){'macos'}else{'linux'})
        Info=$null;Machines=@();Connections=@()
    }
    $commands=[ordered]@{
        Info=@('info','--format','json')
        Machines=@('machine','list','--format','json')
        Connections=@('system','connection','list','--format','json')
    }
    try {
        foreach($key in $commands.Keys) {
            $json=(Invoke-LabTransferNative -Provider podman -Arguments $commands[$key] -TimeoutSeconds 20)-join "`n"
            $evidence[$key]=$json|ConvertFrom-Json -Depth 30 -ErrorAction Stop
        }
        return ConvertTo-LabContainerRuntimeScope -Evidence ([pscustomobject]$evidence)
    }
    catch { throw 'AI_PODMAN_SETUP_RUNTIME_NOT_READY' }
}

function New-LabAiPodmanSetupPlan {
    [CmdletBinding()]
    param(
        [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9 _-]{0,63}$')][string]$Name='Podman KI',
        [ValidateRange(1024,65535)][int]$LocalPort=11434,
        [ValidateRange(1,8)][int]$Cpu=2,
        [ValidateRange(2560,65536)][int]$MemoryMB=4096,
        [ValidateSet('ollama-embeddinggemma-latest','ollama-bge-m3-latest','ollama-nomic-embed-text-v2-moe','ollama-all-minilm-latest')][string]$EmbeddingModelKey='ollama-embeddinggemma-latest'
    )
    $readiness=Get-LabClientRuntimeReadiness -Provider podman
    if ($readiness.Status -cne 'PASS') { throw 'AI_PODMAN_SETUP_RUNTIME_NOT_READY' }
    $scope=Get-LabAiPodmanSetupRuntimeScope
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cnotmatch '^runtime-scope-[a-f0-9]{24}$') { throw 'AI_PODMAN_SETUP_RUNTIME_NOT_READY' }
    $endpoint=New-LabAiEndpointPlan -ModelKey $EmbeddingModelKey -EndpointRef ollama-local -Lane local -LocalPort $LocalPort
    try { $model=Get-LabAiHostModelBinding -Plan $endpoint }
    catch { throw 'AI_PODMAN_SETUP_MODEL_UNAVAILABLE' }
    if ($model.ModelKey -cne $endpoint.ModelKey -or $model.Dimension -ne $endpoint.Dimension -or $model.Model -cne $endpoint.InternalModel) { throw 'AI_PODMAN_SETUP_MODEL_UNAVAILABLE' }
    [pscustomobject][ordered]@{
        contract='SqlServerLab.AiPodmanSetup/1.0';operationId=[guid]::NewGuid().ToString('N')
        collectionId=[guid]::NewGuid().ToString('D');runId=$null;name=$Name;port=$LocalPort;cpu=$Cpu;memoryMB=$MemoryMB
        runtimeScopeId=$scope.RuntimeId;modelBinding=$model
        searchMode=$(if($EmbeddingModelKey -ceq 'ollama-all-minilm-latest'){'Hybrid'}else{'Vector'})
        binding=$null;status='PREPARED'
        primaryReason='NONE';cleanupStatus='NOT_STARTED';collectionCleanup='NOT_NEEDED';newStarted=$false
    }
}

function Assert-LabAiPodmanSetupRecord {
    param($Record,[string]$OperationId)
    $json=$Record|ConvertTo-Json -Depth 15
    if ($OperationId -cnotmatch '^[a-f0-9]{32}$' -or $OperationId -ceq ('0'*32) -or
        $Record.operationId -cne $OperationId -or
        -not ($json|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'ai-podman-setup.schema.json') -ErrorAction SilentlyContinue)) {
        throw 'AI_PODMAN_SETUP_RECORD_INVALID'
    }
    if ($Record.binding -and ($Record.binding.RunId -cne $Record.runId -or $Record.binding.RuntimeScopeId -cne $Record.runtimeScopeId)) {
        throw 'AI_PODMAN_SETUP_RECORD_INVALID'
    }
}

function Get-LabAiPodmanSetupDirectory {
    param([string]$StateRoot,[string]$OperationId)
    if ($OperationId -cnotmatch '^[a-f0-9]{32}$') { throw 'AI_PODMAN_SETUP_ID_INVALID' }
    $directory=Join-Path ([IO.Path]::GetFullPath($StateRoot)) ('ai-environments/'+$OperationId)
    Assert-LabAiPersistentPath $directory
    return $directory
}

function Write-LabAiPodmanSetupRecord {
    param($Record,[string]$StateRoot)
    Assert-LabAiPodmanSetupRecord -Record $Record -OperationId $Record.operationId
    $directory=Get-LabAiPodmanSetupDirectory -StateRoot $StateRoot -OperationId $Record.operationId
    Write-LabArtifactJsonAtomic -Path (Join-Path $directory 'setup.json') -InputObject $Record
}

function Read-LabAiPodmanSetupRecord {
    param([string]$StateRoot,[string]$OperationId)
    $directory=Get-LabAiPodmanSetupDirectory -StateRoot $StateRoot -OperationId $OperationId
    $record=Get-Content -LiteralPath (Join-Path $directory 'setup.json') -Raw -ErrorAction Stop|ConvertFrom-Json -Depth 15
    Assert-LabAiPodmanSetupRecord -Record $record -OperationId $OperationId
    return $record
}

function Assert-LabAiPodmanSetupPreflight {
    param($Record)
    $scope=Get-LabAiPodmanSetupRuntimeScope
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cne $Record.runtimeScopeId) { throw 'AI_PODMAN_SETUP_RUNTIME_CHANGED' }
    $endpoint=New-LabAiEndpointPlan -ModelKey $Record.modelBinding.ModelKey -EndpointRef ollama-local -Lane local -LocalPort $Record.port
    try { Assert-LabAiHostModelBinding -Plan $endpoint -Expected $Record.modelBinding }
    catch { throw 'AI_PODMAN_SETUP_MODEL_CHANGED' }
}

function Invoke-LabAiPodmanSetupApply {
    param([string]$StateRoot,[string]$OperationId)
    $record=Read-LabAiPodmanSetupRecord -StateRoot $StateRoot -OperationId $OperationId
    if ($record.status -cne 'PREPARED') { throw 'AI_PODMAN_SETUP_ALREADY_STARTED' }
    $reason='WORKER_FAILED'
    try {
        $reason='RUNTIME_CHANGED'
        $ready=Get-LabClientRuntimeReadiness -Provider podman
        if ($ready.Status -cne 'PASS') { throw 'AI_PODMAN_SETUP_RUNTIME_NOT_READY' }
        $reason='MODEL_CHANGED'
        Assert-LabAiPodmanSetupPreflight $record
        $record.status='CREATING';$record.newStarted=$true;Write-LabAiPodmanSetupRecord $record $StateRoot
        $reason='NEW_FAILED'
        $lab=Invoke-WithLabWorkflowOperationContext -OperationId $OperationId -ScriptBlock {
            param($Intent,$Root)
            New-SqlServerLab -Version 2025 -Provider podman -Profile compact -Port 0 -Cpu $Intent.cpu -MemoryMB $Intent.memoryMB `
                -LabName $Intent.name -StateRoot $Root -GenerateSaPassword -NonInteractive `
                -Drives @([pscustomobject]@{id='ai-data';containerPath='/var/opt/mssql'})
        } -ArgumentList @($record,$StateRoot)
        if ($lab.State -ine 'RUNNING' -or @($lab.Instances).Count -ne 1) { throw 'AI_PODMAN_SETUP_NEW_FAILED' }
        $record.runId=[string]$lab.RunId
        $binding=Get-LabTransferBinding -RunId $record.runId -InstanceId primary -StateRoot $StateRoot -OperationId $OperationId
        if ($binding.Provider -cne 'podman' -or $binding.RuntimeScopeId -cne $record.runtimeScopeId -or @($binding.Volumes).Count -ne 1) { throw 'AI_PODMAN_SETUP_RUNTIME_CHANGED' }
        $record.binding=Get-LabTransferBindingIdentity $binding
        $record.status='APPLYING';Write-LabAiPodmanSetupRecord $record $StateRoot
        $reason='MODEL_CHANGED';Assert-LabAiPodmanSetupPreflight $record
        $reason='APPLY_FAILED'
        $null=Assert-LabTransferBinding -Expected $record.binding -StateRoot $StateRoot -OperationId $OperationId
        $arguments=@{RunId=$record.runId;InstanceId='primary';CollectionId=$record.collectionId;StateRoot=$StateRoot;LocalPort=$record.port;EmbeddingModelKey=$record.modelBinding.ModelKey;TimeoutSeconds=300;Confirm=$false}
        $applied=Invoke-SqlServerLabAiPersistentRetrieval @arguments -Action Apply -FixtureRevision Initial
        if ($applied.Status -cne 'COMMITTED' -or $applied.CollectionId -cne $record.collectionId -or $applied.Generation -ne 1) { throw 'AI_PODMAN_SETUP_APPLY_FAILED' }
        $record.status='QUERYING';Write-LabAiPodmanSetupRecord $record $StateRoot
        $reason='QUERY_FAILED'
        $null=Assert-LabTransferBinding -Expected $record.binding -StateRoot $StateRoot -OperationId $OperationId
        $query=Invoke-SqlServerLabAiPersistentRetrieval @arguments -Action Query -QueryId backup -SearchMode $record.searchMode
        if ($query.Status -cne 'QUERIED' -or $query.CollectionId -cne $record.collectionId -or $query.Generation -ne 1 -or @($query.Ranked).Count -ne 3 -or $query.Ranked[0].ChunkId -cne 'backup-policy') { throw 'AI_PODMAN_SETUP_QUERY_FAILED' }
        Assert-LabAiPodmanSetupPreflight $record
        $plan=New-LabAiPersistentPlan -RunId $record.runId -InstanceId primary -CollectionId $record.collectionId -Action Query -FixtureRevision Initial -QueryId backup -SearchMode $record.searchMode -LocalPort $record.port -EmbeddingModelKey $record.modelBinding.ModelKey -TimeoutSeconds 300
        $journalPath=Join-Path $StateRoot ('runs/'+$record.runId+'/ai-persistent/primary-'+$record.collectionId+'.json')
        $current=Assert-LabTransferBinding -Expected $record.binding -StateRoot $StateRoot -OperationId $OperationId
        $retrievalIdentity=Get-LabTransferBindingIdentity $current
        # The public retrieval producer binds the instance without operation-volume ownership.
        # Validate our stronger ownership first, then use its exact journal identity projection.
        $retrievalIdentity.Volumes=@()
        $journal=Read-LabAiPersistentJournal -Path $journalPath -Plan $plan -BindingHash (Get-LabAiPlanKey $retrievalIdentity)
        if ($journal.status -cne 'COMMITTED' -or $journal.activeGeneration -ne 1 -or
            $journal.modelHash -cne (Get-LabAiPlanKey $record.modelBinding)) { throw 'AI_PODMAN_SETUP_QUERY_FAILED' }
        $record.status='PROVISIONED';Write-LabAiPodmanSetupRecord $record $StateRoot
    }
    catch {
        if ($_.Exception.Message -cin @('AI_PODMAN_SETUP_RUNTIME_CHANGED','AI_PODMAN_SETUP_MODEL_CHANGED','AI_PODMAN_SETUP_RUNTIME_NOT_READY')) {
            $reason=$_.Exception.Message.Substring('AI_PODMAN_SETUP_'.Length)
        }
        $record.status='ROLLBACK_REQUIRED';$record.primaryReason=$reason
        Write-LabAiPodmanSetupRecord $record $StateRoot
        throw ('AI_PODMAN_SETUP_'+$reason)
    }
}

function Get-LabAiPodmanSetupCleanupTarget {
    param([string]$StateRoot,[string]$OperationId)
    $record=Read-LabAiPodmanSetupRecord -StateRoot $StateRoot -OperationId $OperationId
    if ($record.status -ceq 'READY') { throw 'AI_PODMAN_SETUP_RETAINED_RUN_PROTECTED' }
    $owned=Get-LabOperationOwnedRun -OperationId $OperationId -StateRoot $StateRoot
    $terminal=$false
    if (-not $record.newStarted) {
        if ($owned -or $record.binding -or $record.runId) { throw 'AI_PODMAN_SETUP_CLEANUP_OWNERSHIP_CHANGED' }
        return [pscustomobject]@{Record=$record;Owned=$null;Terminal=$null}
    }
    if (-not $owned -and -not $record.binding) {
        $terminalCandidates=@(foreach($item in @(Get-ChildItem -LiteralPath (Join-Path $StateRoot 'runs') -Directory -ErrorAction SilentlyContinue)) {
            $path=Join-Path $item.FullName 'run-state.json'
            Assert-LabAiPersistentPath $path
            $candidate=Read-LabWorkflowJson -Path $path
            if($candidate -and $candidate.metadata.workflowOperationId -ceq $OperationId){$candidate}
        })
        if($terminalCandidates.Count -ne 1 -or $terminalCandidates[0].state -cnotin @('CLEANED_UP','REMOVED') -or
            $terminalCandidates[0].runId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$' -or
            $terminalCandidates[0].scopeId -cnotmatch '^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$') { throw 'AI_PODMAN_SETUP_CLEANUP_UNVERIFIABLE' }
        $owned=$terminalCandidates[0];$terminal=$true
        $runDirectory=Join-Path $StateRoot ('runs/'+$owned.runId)
        Assert-LabAiPersistentPath (Join-Path $runDirectory 'cleanup-plan.json')
        $cleanupPlan=Get-CleanupPlan -RunDir $runDirectory
        if(-not $cleanupPlan -or $cleanupPlan.runId -cne $owned.runId -or $cleanupPlan.scopeId -cne $owned.scopeId -or
            $cleanupPlan.status -cne 'COMPLETED' -or
            @($cleanupPlan.steps|Where-Object {$_.state -cne 'COMPLETED' -or $_.provider -cne 'podman' -or $_.resourceType -cnotin @('container','volume') -or -not $_.resourceId}).Count -or
            @($cleanupPlan.providerSubRuns).Count -ne 1 -or $cleanupPlan.providerSubRuns[0].provider -cne 'podman' -or
            $cleanupPlan.providerSubRuns[0].state -cne 'COMPLETED' -or $cleanupPlan.providerSubRuns[0].errors -ne 0) {
            throw 'AI_PODMAN_SETUP_CLEANUP_UNVERIFIABLE'
        }
    }
    $scope=Get-LabAiPodmanSetupRuntimeScope
    if ($scope.Status -cne 'AVAILABLE' -or $scope.RuntimeId -cne $record.runtimeScopeId) { throw 'AI_PODMAN_SETUP_CLEANUP_RUNTIME_CHANGED' }
    if ($owned) {
        if ($owned.metadata.workflowOperationId -cne $OperationId -or $owned.metadata.persistentData -or
            ($record.runId -and $record.runId -cne $owned.runId) -or
            ($record.binding -and ($record.binding.RunId -cne $owned.runId -or $record.binding.ScopeId -cne $owned.scopeId -or $record.binding.RuntimeScopeId -cne $scope.RuntimeId))) {
            throw 'AI_PODMAN_SETUP_CLEANUP_OWNERSHIP_CHANGED'
        }
        $subRuns=@(Get-LabProviderSubRuns -RunId $owned.runId -StateRoot $StateRoot)
        if ($subRuns.Count -ne 1 -or $subRuns[0].provider -cne 'podman' -or
            ($terminal -and $subRuns[0].state -cnotin @('CLEANED_UP','REMOVED'))) { throw 'AI_PODMAN_SETUP_CLEANUP_PROVIDER_CHANGED' }
        $record.runId=[string]$owned.runId;Write-LabAiPodmanSetupRecord $record $StateRoot
    }
    [pscustomobject]@{Record=$record;Owned=$(if(-not $terminal){$owned});Terminal=$(if($terminal){$cleanupPlan})}
}

function Remove-LabAiPodmanSetupCollection {
    param([string]$StateRoot,[string]$OperationId)
    $target=Get-LabAiPodmanSetupCleanupTarget -StateRoot $StateRoot -OperationId $OperationId
    $record=$target.Record
    if ($target.Owned) {
        $journal=Join-Path $StateRoot ('runs/'+$record.runId+'/ai-persistent/primary-'+$record.collectionId+'.json')
        if (Test-Path -LiteralPath $journal) {
            try {
                $removed=Invoke-SqlServerLabAiPersistentRetrieval -RunId $record.runId -CollectionId $record.collectionId -Action Remove -LocalPort $record.port -StateRoot $StateRoot -TimeoutSeconds 60 -Confirm:$false
                if ($removed.Status -cne 'REMOVED') { throw 'AI_PODMAN_SETUP_COLLECTION_REMOVE_FAILED' }
                $record.collectionCleanup='REMOVED'
            }
            catch { $record.collectionCleanup='FAILED' }
        }
    }
    Write-LabAiPodmanSetupRecord $record $StateRoot
    if ($record.collectionCleanup -ceq 'FAILED') { throw 'AI_PODMAN_SETUP_COLLECTION_REMOVE_FAILED' }
}

function Remove-LabAiPodmanSetupOwnedRun {
    param([string]$StateRoot,[string]$OperationId)
    $target=Get-LabAiPodmanSetupCleanupTarget -StateRoot $StateRoot -OperationId $OperationId
    $record=$target.Record
    if ($target.Owned) {
        # Whole own-run removal is independently authorized even if SQL ownership cannot be proven.
        $removedRun=Remove-SqlServerLab -RunId $record.runId -StateRoot $StateRoot -Force -Confirm:$false
        if ($removedRun.Status -cne 'REMOVED' -or $removedRun.Cleanup -cne 'CLEANUP_SUCCEEDED' -or $removedRun.Errors) { throw 'AI_PODMAN_SETUP_RUN_REMOVE_FAILED' }
    }
    if ($record.newStarted -and $record.runId) {
        foreach ($kind in @('containers','volumes')) {
            $arguments=if ($kind -ceq 'containers') { @('ps','-a','--filter',"label=sql-server-lab.run-id=$($record.runId)",'--format','{{.ID}}') }
                else { @('volume','ls','--filter',"label=sql-server-lab.run-id=$($record.runId)",'--format','{{.Name}}') }
            if (@(Invoke-LabTransferNative -Provider podman -Arguments $arguments).Count) { throw 'AI_PODMAN_SETUP_CLEANUP_RESIDUE' }
        }
    }
    if ($target.Terminal) {
        # New already removed these resources. Check recorded exact names and run labels read-only.
        $containerNames=@(Invoke-LabTransferNative -Provider podman -Arguments @('ps','-a','--format','{{.Names}}'))
        $volumeNames=@(Invoke-LabTransferNative -Provider podman -Arguments @('volume','ls','--format','{{.Name}}'))
        foreach($step in @($target.Terminal.steps)) {
            if(($step.resourceType -ceq 'container' -and $step.resourceId -cin $containerNames) -or
                ($step.resourceType -ceq 'volume' -and $step.resourceId -cin $volumeNames)) { throw 'AI_PODMAN_SETUP_CLEANUP_RESIDUE' }
        }
    }
    if ($record.binding) { Assert-LabTransferNoResidue -Binding $record.binding }
    $record.cleanupStatus='COMPLETED';Write-LabAiPodmanSetupRecord $record $StateRoot
}

function New-LabAiPodmanSetupDirectory {
    param([string]$StateRoot,[string]$OperationId)
    $directory=Get-LabAiPodmanSetupDirectory -StateRoot $StateRoot -OperationId $OperationId
    if (Test-Path -LiteralPath $directory) { throw 'AI_PODMAN_SETUP_ALREADY_STARTED' }
    $null=New-Item -ItemType Directory -Path $directory -ErrorAction Stop
    Assert-LabAiPersistentPath $directory
    if ($IsWindows) {
        $identity=[Security.Principal.WindowsIdentity]::GetCurrent().User
        $acl=Get-Acl -LiteralPath $directory
        $acl.SetAccessRuleProtection($true,$false);$acl.SetOwner($identity)
        $acl.SetAccessRule([Security.AccessControl.FileSystemAccessRule]::new($identity,'FullControl','ContainerInherit,ObjectInherit','None','Allow'))
        Set-Acl -LiteralPath $directory -AclObject $acl
    } else {
        $chmod=@(Get-Command chmod -CommandType Application -ErrorAction Stop)[0].Source
        & $chmod 700 $directory 1>$null 2>$null
        if ($LASTEXITCODE -ne 0) { throw 'AI_PODMAN_SETUP_PERMISSIONS_FAILED' }
    }
    # CreateNew makes concurrent replay fail before any worker or record replacement.
    $claim=[IO.File]::Open((Join-Path $directory 'claim'),[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    $claim.Dispose()
    return $directory
}

function ConvertTo-LabAiPodmanSetupResult {
    param($Record)
    [pscustomobject]@{
        Status=$Record.status;OperationId=$Record.operationId;RunId=$Record.runId;CollectionId=$Record.collectionId
        Name=$Record.name;LocalPort=$Record.port;EmbeddingModelKey=$Record.modelBinding.ModelKey;Dimension=$Record.modelBinding.Dimension;SearchMode=$Record.searchMode;PrimaryReason=$Record.primaryReason
        CleanupStatus=$Record.cleanupStatus;CollectionCleanup=$Record.collectionCleanup
    }
}

function Invoke-LabAiPodmanSetup {
    [CmdletBinding(SupportsShouldProcess,ConfirmImpact='High')]
    param(
        [Parameter(Mandatory)]$Plan,[string]$StateRoot,
        [ValidateRange(1,1800)][int]$TimeoutSeconds=1200,
        [Threading.CancellationToken]$CancellationToken=[Threading.CancellationToken]::None
    )
    Assert-LabAiPodmanSetupRecord -Record $Plan -OperationId $Plan.operationId
    if ($Plan.status -cne 'PREPARED' -or $Plan.runId -or $Plan.binding) { throw 'AI_PODMAN_SETUP_PLAN_INVALID' }
    if ($CancellationToken.IsCancellationRequested -or -not $PSCmdlet.ShouldProcess($Plan.name,'Podman-KI-Testumgebung erstellen und bei Erfolg behalten')) {
        return [pscustomobject]@{Status='CANCELLED';RunId=$null;CollectionId=$null}
    }
    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    $StateRoot=[IO.Path]::GetFullPath($StateRoot)
    Assert-LabAiPodmanSetupPreflight $Plan
    $directory=New-LabAiPodmanSetupDirectory -StateRoot $StateRoot -OperationId $Plan.operationId
    # Clone the preview; worker and caller cannot mutate each other's in-memory plan.
    $record=$Plan|ConvertTo-Json -Depth 15|ConvertFrom-Json -Depth 15
    Write-LabAiPodmanSetupRecord $record $StateRoot
    $parameters=@{
        AcceptanceRunner=(Join-Path $script:ModuleRoot 'Tools/Invoke-AiPodmanSetupWorker.ps1')
        Provider='podman';StateRoot=$StateRoot;OperationId=$record.operationId;EvidenceRoot=$directory
    }
    $control=@{TerminationConfirmed=$true};$retained=$false;$reason='SUPERVISOR_FAILED'
    try {
        $outcome=Invoke-LabAiPodmanSetupChild @parameters -TimeoutSeconds $TimeoutSeconds -Control $control -CancellationToken $CancellationToken
        $reason=$outcome.ReasonCode
        $record=Read-LabAiPodmanSetupRecord $StateRoot $Plan.operationId
        if ($outcome.Status -ceq 'COMPLETED' -and $record.status -ceq 'PROVISIONED' -and $record.runId -and $record.binding) {
            $record.status='READY';$record.cleanupStatus='NOT_REQUIRED';$record.primaryReason='NONE'
            Write-LabAiPodmanSetupRecord $record $StateRoot
            $retained=$true
        }
    }
    catch { $reason='SUPERVISOR_FAILED' }
    finally {
        if (-not $retained) {
            $record=Read-LabAiPodmanSetupRecord $StateRoot $Plan.operationId
            # A successful durable handoff survives cancellation immediately after its write.
            if ($record.status -ceq 'READY') { $retained=$true }
            else {
                if ($record.primaryReason -ceq 'NONE') { $record.primaryReason=if($reason -ceq 'NONE'){'WORKER_FAILED'}else{$reason} }
                $record.status='ROLLBACK_REQUIRED';Write-LabAiPodmanSetupRecord $record $StateRoot
                if ($control.TerminationConfirmed) {
                    $collectionControl=@{TerminationConfirmed=$true}
                    $collection=$null
                    try { $collection=Invoke-LabAiPodmanSetupChild @parameters -Stage COLLECTION_CLEANUP -TimeoutSeconds 120 -Control $collectionControl }
                    catch { $collection=[pscustomobject]@{Status='FAILED'} }
                    $record=Read-LabAiPodmanSetupRecord $StateRoot $Plan.operationId
                    if ($collection.Status -cne 'COMPLETED') { $record.collectionCleanup='FAILED';Write-LabAiPodmanSetupRecord $record $StateRoot }
                    if ($collectionControl.TerminationConfirmed) {
                        $cleanup=$null
                        try { $cleanup=Invoke-LabAiPodmanSetupChild @parameters -Stage CLEANUP -TimeoutSeconds 600 }
                        catch { $cleanup=[pscustomobject]@{Status='FAILED'} }
                        $record=Read-LabAiPodmanSetupRecord $StateRoot $Plan.operationId
                        $record.cleanupStatus=if($cleanup.Status -ceq 'COMPLETED' -and $record.cleanupStatus -ceq 'COMPLETED'){'COMPLETED'}else{'FAILED'}
                    } else { $record.cleanupStatus='FAILED' }
                } else { $record.cleanupStatus='FAILED' }
                $record.status=if($record.cleanupStatus -ceq 'COMPLETED'){'FAILED'}else{'RECOVERY_REQUIRED'}
                Write-LabAiPodmanSetupRecord $record $StateRoot
            }
        }
    }
    ConvertTo-LabAiPodmanSetupResult $record
}

function Get-LabAiPodmanSetupEntries {
    [CmdletBinding()]
    param([string]$StateRoot)
    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot }
    $directory=Join-Path $StateRoot 'ai-environments'
    if (-not (Test-Path -LiteralPath $directory)) { return }
    Assert-LabAiPersistentPath $directory
    foreach ($item in @(Get-ChildItem -LiteralPath $directory -Directory|Sort-Object Name)) {
        try {
            $record=Read-LabAiPodmanSetupRecord -StateRoot $StateRoot -OperationId $item.Name
            $entry=ConvertTo-LabAiPodmanSetupResult $record
            $runState='UNKNOWN'
            if($record.runId){try{$runState=[string](Get-LabRunState -RunId $record.runId -StateRoot $StateRoot).state}catch{}}
            $entry|Add-Member -NotePropertyName RunState -NotePropertyValue $runState
            $entry
        } catch { Write-Warning 'Ein KI-Erstellungsvorgang ist nicht lesbar; sein lokaler Recovery-State bleibt erhalten.' }
    }
}
