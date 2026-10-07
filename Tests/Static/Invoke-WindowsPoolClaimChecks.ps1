#Requires -Version 7.2
[CmdletBinding()]
param([switch]$SkipProcessChecks)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
$fixture=Join-Path (Join-Path $repoRoot '.artifacts/windows-pool-checks') ([guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $fixture -Force
$result=& $module {
    param($fixture,$repoRoot)
    $script:PoolCheckCount=0
    function Assert-Pool($condition,$name){if(-not $condition){throw "WINDOWS_POOL_CHECK_FAILED: $name"};$script:PoolCheckCount++}
    function Assert-PoolThrows([scriptblock]$body,[string]$code){$failed=$false;$observed=$null;try{& $body}catch{$observed=$_.Exception.Message;$failed=$observed -like ($code+'*')};Assert-Pool $failed ($code+'; actual='+$observed)}
    $root=Join-Path $fixture state
    Assert-PoolThrows {Assert-LabWindowsPoolRootSupport -StateRoot ([IO.Path]::GetPathRoot($fixture))} WINDOWS_POOL_ROOT_TOO_BROAD
    if($IsWindows){Assert-PoolThrows {Assert-LabWindowsPoolRootSupport -StateRoot '\\synthetic-unreachable\share\state'} WINDOWS_POOL_NETWORK_ROOT_UNSUPPORTED}
    if($IsWindows){
        $realDriveIdentity=${function:Get-LabWindowsPoolLocalDriveIdentity}
        function Get-LabWindowsPoolLocalDriveIdentity {param($DriveRoot) $script:PoolCheckDriveIdentity}
        foreach($identity in @(
            [pscustomobject]@{Type=[IO.DriveType]::Network;Device='\Device\LanmanRedirector\synthetic'},
            [pscustomobject]@{Type=[IO.DriveType]::Unknown;Device=$null},
            [pscustomobject]@{Type=[IO.DriveType]::Fixed;Device='\??\C:\synthetic-subst'})){
            $script:PoolCheckDriveIdentity=$identity
            Assert-PoolThrows {Assert-LabWindowsPoolRootSupport -StateRoot $root} WINDOWS_POOL_ROOT_LOCALITY_UNSUPPORTED
        }
        # Generic canonical lock use does not invoke pool-locality authority.
        $entered=Invoke-WithLabWindowsPoolLock -StateRoot $root -Body {'NON_POOL_COMPATIBLE'}
        Assert-Pool ($entered -ceq 'NON_POOL_COMPATIBLE') 'non-pool canonical lock preserves root compatibility'
        $ordinaryRoot=Join-Path $fixture ordinary-state
        $ordinary=New-LabRunState -StateRoot $ordinaryRoot -Metadata @{name='synthetic-non-pool';workflowKind='synthetic-non-pool'}
        Set-LabRunState -RunId $ordinary.RunId -StateRoot $ordinaryRoot -NewState PROVISIONING
        Assert-Pool ((Get-LabRunState -RunId $ordinary.RunId -StateRoot $ordinaryRoot).state -ceq 'PROVISIONING') 'non-pool run writer and lifecycle do not inherit pool locality restriction'
        Set-Item Function:Get-LabWindowsPoolLocalDriveIdentity -Value $realDriveIdentity
    }
    $parentPath=Join-Path $fixture parent.vhdx
    [IO.File]::WriteAllText($parentPath,'synthetic immutable parent')
    (Get-Item -LiteralPath $parentPath).IsReadOnly=$true
    $artifactId='hyperv-os-sealed-'+('a'*64)
    $poolId=[guid]::NewGuid().ToString();$vmId=[guid]::NewGuid().ToString()
    $script:PoolCheckFixture=[pscustomobject]@{Root=$root;Parent=$parentPath;ArtifactId=$artifactId;VMId=$vmId;VMState='Off';RunId=$null;ScopeId=$null;Notes=$null}
    function Test-LabAutomatedTestEnvironmentRun {param($RunId) return $false}
    function Get-HyperVImageArtifact {param($ArtifactId,$StateRoot,[switch]$SkipIntegrityCheck)
        if($ArtifactId -cne $script:PoolCheckFixture.ArtifactId){throw 'SYNTHETIC_ARTIFACT_SCOPE'}
        [pscustomobject]@{artifactId=$ArtifactId;sha256=('a'*64);artifactState='OS_SEALED';generalized=$true;Path=$script:PoolCheckFixture.Parent}
    }
    function Get-HyperVManagedVM {param($VMName,$ExpectedRunId,$ExpectedScopeId)
        if($ExpectedRunId -and $ExpectedRunId -cne $script:PoolCheckFixture.RunId){throw 'SYNTHETIC_VM_SCOPE'}
        [pscustomobject]@{VM=[pscustomobject]@{Id=$script:PoolCheckFixture.VMId;Name='synthetic-pool-01';State=$script:PoolCheckFixture.VMState};Identity=$script:PoolCheckFixture.Notes}
    }
    function Get-VMHardDiskDrive {param($VM) [pscustomobject]@{Path=(Join-Path $script:PoolCheckFixture.Root ('runs/'+$script:PoolCheckFixture.RunId+'/child.vhdx'))}}
    function Get-VMSnapshot {param($VM) @()}
    function Get-VHD {param($Path) [pscustomobject]@{ParentPath=$script:PoolCheckFixture.Parent}}
    function Get-HyperVLabVMs {param($RunId,$ScopeId) @()}
    function Get-VM {
        [CmdletBinding()]param($Name)
        if($script:PoolCheckInventoryFault){Write-Error 'synthetic inventory permission failure' -Category PermissionDenied;return}
        @($script:PoolCheckInventory)
    }
    $script:PoolCheckInventory=@();$script:PoolCheckInventoryFault=$false
    $script:PoolCheckCpu=4;$script:PoolCheckMemory=4GB;$script:PoolCheckProviderFault=$null
    function Set-VMProcessor {param($VM,$Count) if($script:PoolCheckProviderFault -ceq 'CPU'){throw 'SYNTHETIC_CPU_FAULT'};$script:PoolCheckCpu=$Count}
    function Set-VMMemory {param($VM,$DynamicMemoryEnabled,$MinimumBytes,$StartupBytes,$MaximumBytes) if($script:PoolCheckProviderFault -ceq 'RAM'){throw 'SYNTHETIC_RAM_FAULT'};$script:PoolCheckMemory=$StartupBytes}
    function Get-VMProcessor {param($VM) [pscustomobject]@{Count=$(if($script:PoolCheckProviderFault -ceq 'POSTCONDITION'){1}else{$script:PoolCheckCpu})}}
    function Get-VMMemory {param($VM) [pscustomobject]@{Startup=$script:PoolCheckMemory}}
    function Get-LabSlotReserveState {[pscustomobject]@{Status='CONFIGURED';Policy=[pscustomobject]@{MinimumDaysRemaining=30;WarningDaysRemaining=10;WindowsReserve=0;SqlReserve=0}}}
    $prepare=New-LabWindowsPoolOperationIntent -PoolId $poolId -Purpose Prepare -StateRoot $root
    $context=[pscustomobject]@{StateRoot=(Resolve-LabWindowsPoolRoot $root);PoolId=$poolId;OperationId=$prepare.operationId;RunId=$null;Kind='Prepare';Index=1}
    $created=Invoke-WithLabWindowsPoolOperation -Context $context -Body {
        $run=New-LabRunState -StateRoot $root -Metadata @{name='synthetic-pool-01';workflowKind='hyperv-lab';workload='windows';imageArtifactId=$artifactId
            windowsLocale=[pscustomobject]@{Region='AT';SystemLocale='de-AT';UiLanguage='en-US';InputLocale='0407:00000407';TimeZone='W. Europe Standard Time'}}
        $script:PoolCheckFixture.RunId=$run.RunId;$script:PoolCheckFixture.ScopeId=$run.ScopeId
        $notes=ConvertTo-HyperVLabNotes -RunId $run.RunId -ScopeId $run.ScopeId -InstanceId primary -ChildVhdxPath (Join-Path $run.RunDir child.vhdx)
        $script:PoolCheckFixture.Notes=ConvertFrom-HyperVLabNotes -Notes $notes
        $connection=[pscustomobject]@{instances=@([pscustomobject]@{id='primary';provider='hyperv';imageArtifactId=$artifactId;vmId=$vmId;vmName='synthetic-pool-01';workload='windows';windowsProvisioning=[pscustomobject]@{state='COMPLETE'}})}
        Write-LabArtifactJsonAtomic -Path (Join-Path $run.RunDir connection-info.json) -InputObject $connection
        $state=Get-LabRunState -RunId $run.RunId -StateRoot $root
        $null=Set-LabWindowsPoolMemberState -RunId $run.RunId -StateRoot $root -ExpectedRevision $state.metadata.windowsPoolMember.revision -Change {param($member)$member.vmId=$vmId}
        $cause=$null;try{throw 'WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID: synthetic raw diagnostic not for persistence'}catch{$cause=$_}
        $cause.Exception.Data['WindowsPoolCaptureMismatchCodes']=@('UI_LANGUAGE_MISMATCH','synthetic raw diagnostic','UI_LANGUAGE_MISMATCH')
        Write-LabWindowsPoolFailureReceipt -Failure $cause -Context $context -RunId $run.RunId -Stage Prepare
        $causeFile=@(Get-ChildItem $run.RunDir -Filter windows-pool-cause-*.json)[0]
        $causeText=Get-Content $causeFile.FullName -Raw;$causeDto=$causeText|ConvertFrom-Json
        Assert-Pool ($causeDto.code -ceq 'WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID' -and $causeDto.runId -ceq $run.RunId -and $causeDto.scopeId -ceq $run.ScopeId -and $causeText -notmatch 'raw diagnostic') 'canonical operation-bound cause receipt preserves code and omits raw diagnostic'
        Assert-Pool (@($causeDto.captureMismatchCodes).Count -eq 1 -and $causeDto.captureMismatchCodes[0] -ceq 'UI_LANGUAGE_MISMATCH') 'capture cause codes are allowlisted and deduplicated'
        foreach($next in @('PROVISIONING','SQL_READY','DATABASES_CREATED','RUNNING','STOPPED')){Set-LabRunState -RunId $run.RunId -StateRoot $root -NewState $next}
        Complete-LabWindowsPoolPreparation -RunId $run.RunId -StateRoot $root -Receipt ([pscustomobject]@{observedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o');evaluationExpiresAt=[datetime]::UtcNow.AddDays(90).ToString('o');licenseStatus=1;provisioningComplete=$true})
        return $run
    }
    $runId=$created.RunId;$statePath=Join-Path $created.RunDir run-state.json
    # Compose both real executors; a mock that omits their Context/Body
    # parameters would conceal dynamic-scope recursion in the wrapper.
    $compositionRoot=Join-Path $fixture cleanup-composition
    $compositionRun=[guid]::NewGuid().ToString()
    $compositionSource=New-LabWindowsPoolOperationIntent -PoolId $poolId -Purpose Claim -RunId $compositionRun -StateRoot $compositionRoot
    $compositionCleanup=New-LabWindowsPoolOperationIntent -PoolId $poolId -Purpose Cleanup -RunId $compositionRun -StateRoot $compositionRoot
    $compositionContext=[pscustomobject]@{StateRoot=$compositionRoot;PoolId=$poolId;OperationId=$compositionCleanup.operationId;RunId=$compositionRun;Kind='Cleanup'}
    $compositionPreviousContext=$script:LabWindowsPoolContext
    $compositionPreviousSource=$script:LabWindowsPoolCleanupSourceId
    $script:PoolCleanupBodyCount=0
    $compositionResult=Invoke-WithLabWindowsPoolCleanupSource -Context $compositionContext -SourceOperationId $compositionSource.operationId -Body {
        $script:PoolCleanupBodyCount++
        [pscustomobject]@{Kind=$script:LabWindowsPoolContext.Kind;OperationId=$script:LabWindowsPoolContext.OperationId;SourceId=$script:LabWindowsPoolCleanupSourceId}
    }
    Assert-Pool ($script:PoolCleanupBodyCount -eq 1 -and $compositionResult.Kind -ceq 'Cleanup' -and $compositionResult.OperationId -ceq $compositionCleanup.operationId) 'real cleanup composition enters target body exactly once'
    Assert-Pool ($compositionResult.SourceId -ceq $compositionSource.operationId) 'real cleanup composition retains original source authority'
    Assert-Pool ($script:LabWindowsPoolContext -eq $compositionPreviousContext -and $script:LabWindowsPoolCleanupSourceId -eq $compositionPreviousSource) 'real cleanup composition restores both contexts'
    Assert-PoolThrows {Invoke-WithLabWindowsPoolCleanupSource -Context $compositionContext -SourceOperationId $compositionSource.operationId -Body {throw 'SYNTHETIC_COMPOSITION_FAILURE'}} SYNTHETIC_COMPOSITION_FAILURE
    $compositionResume=Invoke-WithLabWindowsPoolCleanupSource -Context $compositionContext -SourceOperationId $compositionSource.operationId -Body {'CLEANUP_REENTERED'}
    Assert-Pool ($compositionResume -ceq 'CLEANUP_REENTERED' -and $script:LabWindowsPoolContext -eq $compositionPreviousContext -and $script:LabWindowsPoolCleanupSourceId -eq $compositionPreviousSource) 'failed cleanup composition releases both executors and restores contexts'
    $actualBoundReader=${function:Get-LabWindowsPoolBoundMember}
    $actualReserveReader=${function:Get-LabSlotReserveState}
    function Get-LabWindowsPoolBoundMember {throw 'SYNTHETIC_PROVIDER_UNAVAILABLE'}
    function Get-LabSlotReserveState {[pscustomobject]@{Status='CONFIGURED';Policy=[pscustomobject]@{MinimumDaysRemaining=30;WarningDaysRemaining=10;WindowsReserve=3;SqlReserve=0}}}
    $unknownInventory=Get-LabSlotReserveInventory -StateRoot $root
    Assert-Pool ($unknownInventory.WindowsCoverage -ceq 'UNKNOWN' -and $null -eq $unknownInventory.WindowsVerifiedAvailable -and $null -eq $unknownInventory.WindowsDeficit -and $unknownInventory.WindowsVerifiedLowerBound -eq 0) 'unknown member binding makes aggregate unknown with explicit lower bound'
    Set-Item Function:Get-LabWindowsPoolBoundMember -Value $actualBoundReader
    Set-Item Function:Get-LabSlotReserveState -Value $actualReserveReader
    $initial=Get-LabRunState -RunId $runId -StateRoot $root
    Assert-Pool ($initial.metadata.windowsPoolMember.state -ceq 'FREE') 'complete member free'
    Assert-Pool (($initial.metadata.windowsPoolMember | ConvertTo-Json -Depth 12) | Test-Json -SchemaFile (Join-Path $script:SchemasPath windows-pool-member.schema.json)) 'member schema'
    $bound=Get-LabWindowsPoolBoundMember -RunId $runId -StateRoot $root -RequireOff
    $evidence=Get-LabWindowsPoolEvidenceStatus -Bound $bound -MinimumDaysRemaining 30 -WarningDaysRemaining 120
    Assert-Pool ($evidence.VerifiedAvailable -and $evidence.Warning -ceq 'WARNING') 'fresh independent warning and minimum'
    $script:PoolCheckDefaultRoot=$root
    function Get-LabStateRoot {$script:PoolCheckDefaultRoot}
    $defaultPreview=New-LabWindowsPoolMemberPreview -RunId $runId -Action Claim
    $script:PoolCheckDefaultRoot=Join-Path $fixture changed-default
    Assert-PoolThrows {Invoke-LabWindowsPoolMemberPreview -PreviewId $defaultPreview.PreviewId -Confirm} WINDOWS_POOL_SELECTED_ROOT_CHANGED
    $script:PoolCheckDefaultRoot=$root
    $harness=Join-Path $script:ModuleRoot Tests/Integration/Invoke-WindowsPoolClaimAcceptance.ps1
    Assert-PoolThrows {& $harness -StateRoot $root -ArtifactId $artifactId -MediaRoot $fixture -SqlMediaPath synthetic-media} WINDOWS_POOL_NATIVE_EXPLICIT_EXECUTION_AND_CLEANUP_REQUIRED
    Assert-PoolThrows {& $harness -StateRoot $root -ArtifactId $artifactId -MediaRoot $fixture -SqlMediaPath synthetic-media -ConfirmNativeExecution} WINDOWS_POOL_NATIVE_EXPLICIT_EXECUTION_AND_CLEANUP_REQUIRED
    foreach($mutation in @('epoch','pool','run','scope','vm','parent','revision','future','stale','window','expired')){
        $copy=$bound | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
        switch($mutation){
            epoch {$copy.Member.evidence.evidenceEpoch=[guid]::NewGuid().ToString()}
            pool {$copy.Member.evidence.poolId=[guid]::NewGuid().ToString()}
            run {$copy.Member.evidence.runId=[guid]::NewGuid().ToString()}
            scope {$copy.Member.evidence.scopeId=[guid]::NewGuid().ToString()}
            vm {$copy.Member.evidence.vmId=[guid]::NewGuid().ToString()}
            parent {$copy.ParentFingerprint='wrong'}
            revision {$copy.Member.evidence.preparationRevision=$copy.Member.revision+1}
            future {$copy.Member.evidence.observedAt=[datetime]::UtcNow.AddMinutes(1).ToString('o')}
            stale {$copy.Member.evidence.observedAt=[datetime]::UtcNow.AddHours(-25).ToString('o');$copy.Member.evidence.freshUntil=[datetime]::UtcNow.AddHours(-1).ToString('o')}
            window {$copy.Member.evidence.freshUntil=[datetime]::UtcNow.AddHours(25).ToString('o')}
            expired {$copy.Member.evidence.evaluationExpiresAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o')}
        }
        Assert-Pool (-not (Get-LabWindowsPoolEvidenceStatus -Bound $copy).VerifiedAvailable) ('unavailable '+$mutation)
    }
    # Execute the actual HTTP adapter and workflow together against this own
    # synthetic default root; callers still cannot inject a different root.
    . (Join-Path $repoRoot 'Tools/WorkflowUiJsonBody.ps1')
    $uiAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tools/Start-SqlServerLabUi.ps1'),[ref]$null,[ref]$null)
    $requestFunction=$uiAst.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Invoke-UiSlotReserveRequest'},$true)
    Invoke-Expression $requestFunction.Extent.Text
    function New-PoolHttpRequest($Payload){
        @{HttpMethod='POST';ContentType='application/json';Headers=@{Origin='http://127.0.0.1:8484'};Url=[uri]'http://127.0.0.1:8484/api/slot-reserve'
            ContentEncoding=[Text.Encoding]::UTF8;InputStream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes(($Payload|ConvertTo-Json -Depth 12)))}
    }
    # The generic real route must reject member actions before replayable batch
    # or job dispatch; only the dedicated adapter owns their parameter boundary.
    $genericRoute=$uiAst.Find({param($node)$node -is [Management.Automation.Language.IfStatementAst] -and $node.Extent.Text.StartsWith('if ($path -eq ''/api/actions''')},$true)
    & {
        $script:poolGenericDispatch=0
        function New-SqlServerLabBatch {$script:poolGenericDispatch++;throw 'UNEXPECTED_GENERIC_BATCH'}
        function Start-UiWorkflowJob {$script:poolGenericDispatch++;throw 'UNEXPECTED_GENERIC_JOB'}
        function Invoke-SqlServerLabWorkflowAction {$script:poolGenericDispatch++;throw 'UNEXPECTED_GENERIC_WORKFLOW'}
        foreach($action in @('PlanWindowsPoolMember','ApplyWindowsPoolMember','CancelWindowsPoolMember')){
            $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes((@{action=$action;parameters=@{RunId=$runId;StateRoot=(Join-Path $fixture 'unselected-foreign-root');SlotReservePreviewId=[guid]::NewGuid().ToString();ConfirmSlotReserveMember=$true}}|ConvertTo-Json -Depth 8)))
            try{
                $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';InputStream=$stream;ContentEncoding=[Text.Encoding]::UTF8}}
                $path='/api/actions';$jobs=@{}
                Assert-PoolThrows {. ([scriptblock]::Create('foreach ($once in @(1)) { '+$genericRoute.Extent.Text+' }'))} INITIAL_SETUP_DIRECT_ENDPOINT_REQUIRED
                Assert-Pool ($script:poolGenericDispatch -eq 0 -and $jobs.Count -eq 0) ('generic route blocks '+$action+' before dispatch')
            }finally{$stream.Dispose()}
        }
        # A legitimate generic one-shot action still reaches only the job helper.
        function Start-UiWorkflowJob {param($Action,$Parameters) $script:poolGenericDispatch++;[pscustomobject]@{Id='synthetic-refresh';Action=$Action}}
        function Write-UiResponse {param($Context,$Body,$ContentType,$StatusCode) $script:poolGenericResponse=$Body|ConvertFrom-Json;$script:poolGenericStatus=$StatusCode}
        $stream=[IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('{"action":"Refresh","parameters":{}}'))
        try{
            $context=[pscustomobject]@{Request=[pscustomobject]@{HttpMethod='POST';InputStream=$stream;ContentEncoding=[Text.Encoding]::UTF8}}
            $path='/api/actions';$jobs=@{}
            . ([scriptblock]::Create('foreach ($once in @(1)) { '+$genericRoute.Extent.Text+' }'))
            Assert-Pool ($script:poolGenericDispatch -eq 1 -and $jobs.Count -eq 1 -and $script:poolGenericStatus -eq 202 -and $script:poolGenericResponse.id -ceq 'synthetic-refresh') 'generic legitimate Refresh one-shot route preserved'
        }finally{$stream.Dispose()}
    }
    $httpPlan=(Invoke-UiSlotReserveRequest (New-PoolHttpRequest @{action='PlanWindowsPoolMember';parameters=@{RunId=$runId;SlotReserveOperation='Claim'}})).Result
    Assert-Pool ($httpPlan.RunId -ceq $runId -and $httpPlan.PoolId -ceq $poolId) 'actual HTTP workflow binds RunId to canonical member under selected default root'
    Assert-PoolThrows {Invoke-UiSlotReserveRequest (New-PoolHttpRequest @{action='PlanWindowsPoolMember';parameters=@{RunId=$runId;StateRoot=$root;SlotReserveOperation='Claim'}})} SLOT_RESERVE_PARAMETER_INVALID
    Assert-PoolThrows {Invoke-UiSlotReserveRequest (New-PoolHttpRequest @{action='ApplyWindowsPoolMember';parameters=@{SlotReservePreviewId=$httpPlan.PreviewId}})} WINDOWS_POOL_CONFIRMATION_REQUIRED
    $httpCancel=(Invoke-UiSlotReserveRequest (New-PoolHttpRequest @{action='CancelWindowsPoolMember';parameters=@{SlotReservePreviewId=$httpPlan.PreviewId}})).Result
    Assert-Pool ($httpCancel.Status -ceq 'CANCELLED' -and -not $httpCancel.ProviderMutation -and (Get-LabRunState -RunId $runId -StateRoot $root).metadata.windowsPoolMember.state -ceq 'FREE') 'actual HTTP cancel preserves member and performs no provider mutation'
    $plan=(Invoke-SqlServerLabWorkflowAction -Action PlanWindowsPoolMember -RunId $runId -StateRoot $root -SlotReserveOperation Claim).Result
    Assert-Pool ($plan.RunId -ceq $runId -and $plan.PoolId -ceq $poolId) 'actual workflow binds explicit RunId and StateRoot to canonical member preview'
    Assert-PoolThrows {Invoke-LabWindowsPoolMemberPreview -PreviewId $plan.PreviewId} WINDOWS_POOL_CONFIRMATION_REQUIRED
    $null=Invoke-LabWindowsPoolMemberPreview -PreviewId $plan.PreviewId -Cancel
    Assert-Pool ((Get-LabRunState -RunId $runId -StateRoot $root).metadata.windowsPoolMember.state -ceq 'FREE') 'cancel no claim'
    $oldSnapshot=Get-LabRunState -RunId $runId -StateRoot $root
    $plan=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Claim
    $claim=Invoke-LabWindowsPoolMemberPreview -PreviewId $plan.PreviewId -Confirm
    Assert-Pool ($claim.Status -ceq 'CLAIMED') 'confirmed atomic claim'
    $publicStateHash=(Get-FileHash $statePath).Hash
    $publicSyncOriginal=${function:Sync-LabRunRuntimeState}
    $script:PoolPublicSyncCalled=$false
    function Sync-LabRunRuntimeState {param($Run,$StateRoot) $script:PoolPublicSyncCalled=$true;[pscustomobject]@{Run=$Run}}
    try {
        Assert-PoolThrows {Stop-SqlServerLab -RunId $runId -StateRoot $root -Confirm:$false} WINDOWS_POOL_MEMBER_RESERVED
        Assert-PoolThrows {Start-SqlServerLab -RunId $runId -StateRoot $root} WINDOWS_POOL_MEMBER_RESERVED
        Assert-Pool (-not $script:PoolPublicSyncCalled -and (Get-FileHash $statePath).Hash -ceq $publicStateHash) 'real public start/stop rejects claimed stopped member before runtime sync and preserves state bytes'
    } finally {Set-Item Function:Sync-LabRunRuntimeState -Value $publicSyncOriginal}
    Assert-PoolThrows {Assert-LabWindowsPoolMutationAllowed -RunId $runId -StateRoot $root -InvalidateEvidence} WINDOWS_POOL_MEMBER_RESERVED
    Assert-PoolThrows {Write-LabArtifactJsonAtomic -Path $statePath -InputObject $oldSnapshot} WINDOWS_POOL_STATE_SNAPSHOT_STALE
    Assert-PoolThrows {Set-LabRunState -RunId $runId -StateRoot $root -NewState RUNNING} WINDOWS_POOL_MEMBER_RESERVED
    Assert-PoolThrows {Start-HyperVInstance -VMName synthetic-pool-01 -ExpectedRunId $runId -ExpectedScopeId $created.ScopeId -StateRoot $root} WINDOWS_POOL_MEMBER_RESERVED
    $syntheticPassword=[securestring]::new();foreach($character in 'synthetic-only-fixture'.ToCharArray()){$syntheticPassword.AppendChar($character)};$syntheticPassword.MakeReadOnly()
    $syntheticCredential=[pscredential]::new('synthetic-only-fixture',$syntheticPassword)
    $guestArguments=@{VMName='synthetic-pool-01';ExpectedRunId=$runId;ExpectedScopeId=$created.ScopeId;StateRoot=$root;Credential=$syntheticCredential}
    $syntheticComputerName='owned-test'
    Assert-PoolThrows {Set-HyperVWindowsGuestSpecialization @guestArguments -ComputerName $syntheticComputerName} WINDOWS_POOL_MEMBER_RESERVED
    Assert-PoolThrows {Confirm-HyperVWindowsManualOobeSpecialization @guestArguments} WINDOWS_POOL_MEMBER_RESERVED
    Assert-PoolThrows {Wait-HyperVGuestSqlReady @guestArguments -SaPassword $syntheticPassword} WINDOWS_POOL_MEMBER_RESERVED
    Assert-PoolThrows {Initialize-HyperVWindowsGuestDrives @guestArguments} WINDOWS_POOL_MEMBER_RESERVED
    $managed=Get-HyperVManagedVM -VMName synthetic-pool-01
    Assert-PoolThrows {Assert-LabWindowsPoolProviderMutation -Managed $managed -StateRoot (Join-Path $fixture other-root)} WINDOWS_POOL_NOTES_ROOT_MISMATCH
    $savedNotes=$script:PoolCheckFixture.Notes
    $script:PoolCheckFixture.Notes=$savedNotes | ConvertTo-Json -Depth 12 | ConvertFrom-Json -Depth 12
    $script:PoolCheckFixture.Notes.PSObject.Properties.Remove('windowsPoolMember')
    Assert-PoolThrows {Assert-LabWindowsPoolProviderMutation -Managed (Get-HyperVManagedVM -VMName synthetic-pool-01) -StateRoot $root} WINDOWS_POOL_NOTES_BINDING_INVALID
    $actualDefaultReader=${function:Get-LabStateRoot}
    $script:PoolCheckOtherDefault=Join-Path $fixture unrelated-empty-default
    function Get-LabStateRoot {$script:PoolCheckOtherDefault}
    $script:PoolCheckProviderStartCalled=$false
    function Start-VM {$script:PoolCheckProviderStartCalled=$true}
    Assert-PoolThrows {Start-HyperVInstance -VMName synthetic-pool-01 -ExpectedRunId $runId -ExpectedScopeId $created.ScopeId} WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED
    Assert-Pool (-not $script:PoolCheckProviderStartCalled) 'missing marker and unrelated default cannot invoke provider'
    Set-Item Function:Get-LabStateRoot -Value $actualDefaultReader
    $legacyRoot=Join-Path $fixture legacy-bound-state
    $legacyRun=New-LabRunState -StateRoot $legacyRoot -Metadata @{name='synthetic-legacy';workflowKind='synthetic'}
    $legacyManaged=[pscustomobject]@{VM=[pscustomobject]@{Id=[guid]::NewGuid().ToString()};Identity=[pscustomobject]@{provider='hyperv';runId=$legacyRun.RunId;scopeId=$legacyRun.ScopeId;instanceId='primary'}}
    Write-LabArtifactJsonAtomic -Path (Join-Path $legacyRun.RunDir connection-info.json) -InputObject ([pscustomobject]@{instances=@([pscustomobject]@{id='primary';provider='hyperv';vmId=$legacyManaged.VM.Id})})
    Assert-LabWindowsPoolProviderMutation -Managed $legacyManaged -StateRoot $legacyRoot
    Assert-Pool $true 'independently bound non-pool legacy run preserves provider authority'
    $legacyVmId=$legacyManaged.VM.Id;$legacyManaged.VM.Id=[guid]::NewGuid().ToString()
    Assert-PoolThrows {Assert-LabWindowsPoolProviderMutation -Managed $legacyManaged -StateRoot $legacyRoot} WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED
    $legacyManaged.VM.Id=$legacyVmId
    $legacyManaged.Identity.scopeId=[guid]::NewGuid().ToString()
    Assert-PoolThrows {Assert-LabWindowsPoolProviderMutation -Managed $legacyManaged -StateRoot $legacyRoot} WINDOWS_POOL_PROVIDER_AUTHORITY_REQUIRED
    $script:PoolCheckFixture.Notes=$savedNotes
    $release=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Release
    $script:PoolCheckOriginalWriter=${function:Write-LabArtifactJsonAtomicRaw}
    $script:PoolCheckFaultPath=Join-Path (Join-Path $root operations) ($claim.OperationId+'.json')
    $script:PoolCheckFaultArmed=$true
    function Write-LabArtifactJsonAtomicRaw {
        param($Path,$InputObject)
        if($script:PoolCheckFaultArmed -and $Path -eq $script:PoolCheckFaultPath){
            if($script:PoolCheckJournalSkip -gt 0){$script:PoolCheckJournalSkip--}else{$script:PoolCheckFaultArmed=$false;throw 'SYNTHETIC_JOURNAL_WRITE_FAULT'}
        }
        & $script:PoolCheckOriginalWriter -Path $Path -InputObject $InputObject
    }
    $result=Invoke-LabWindowsPoolMemberPreview -PreviewId $release.PreviewId -Confirm
    Assert-Pool ($result.Status -ceq 'RECOVERY_REQUIRED' -and $result.OriginalError -ceq 'WINDOWS_POOL_OPERATION_FAILED' -and -not $result.CleanupError) 'journal fault remains reserved with separate error'
    $recovery=Get-LabRunState -RunId $runId -StateRoot $root
    Assert-Pool ($recovery.metadata.windowsPoolMember.state -ceq 'RECOVERY_REQUIRED' -and $recovery.metadata.windowsPoolMember.claim.operationId -ceq $claim.OperationId) 'same claim ids survive journal fault'
    $release=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Release
    $result=Invoke-LabWindowsPoolMemberPreview -PreviewId $release.PreviewId -Confirm
    Assert-Pool ($result.Status -ceq 'RELEASED') 'safe release without provider work'
    # The failed journal discarded evidence; the synthetic preparation owner
    # explicitly recaptures before a subsequent availability claim.
    Invoke-WithLabWindowsPoolOperation -Context $context -Body {
        $free=Get-LabRunState -RunId $runId -StateRoot $root
        $null=Set-LabWindowsPoolMemberState -RunId $runId -StateRoot $root -ExpectedRevision $free.metadata.windowsPoolMember.revision -Change {
            param($value)$value.state='PREPARING';$value.claim=[pscustomobject]@{claimId=[guid]::NewGuid().ToString();operationId=$context.OperationId;purpose='Prepare';providerMutationStarted=$false}
        }
        Complete-LabWindowsPoolPreparation -RunId $runId -StateRoot $root -Receipt ([pscustomobject]@{observedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o');evaluationExpiresAt=[datetime]::UtcNow.AddDays(90).ToString('o');licenseStatus=1;provisioningComplete=$true})
    }
    $plan1=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Claim
    $plan2=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Claim
    $claimed=Invoke-LabWindowsPoolMemberPreview -PreviewId $plan1.PreviewId -Confirm
    Assert-PoolThrows {Invoke-LabWindowsPoolMemberPreview -PreviewId $plan2.PreviewId -Confirm} WINDOWS_POOL_PREVIEW_STALE
    $cleanupPath=Join-Path $created.RunDir cleanup-plan.json
    $cleanup=[pscustomobject]@{runId=$runId;scopeId=$created.ScopeId;providerSubRuns=@([pscustomobject]@{provider='hyperv'});steps=@()}
    Write-LabArtifactJsonAtomic -Path $cleanupPath -InputObject $cleanup
    $cleanupPreview=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Cleanup
    $null=Invoke-LabWindowsPoolMemberPreview -PreviewId $cleanupPreview.PreviewId -Cancel
    Assert-Pool ((Get-LabRunState -RunId $runId -StateRoot $root).metadata.windowsPoolMember.claim.operationId -ceq $claimed.OperationId) 'cleanup cancel retains original claim'
    $cleanup.scopeId=[guid]::NewGuid().ToString();Write-LabArtifactJsonAtomic -Path $cleanupPath -InputObject $cleanup
    Assert-PoolThrows {New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Cleanup} WINDOWS_POOL_CLEANUP_PLAN_BINDING_INVALID
    $cleanup.scopeId=$created.ScopeId;Write-LabArtifactJsonAtomic -Path $cleanupPath -InputObject $cleanup
    $cleanupPreview=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Cleanup
    $cleanup.steps=@([pscustomobject]@{provider='docker'});Write-LabArtifactJsonAtomic -Path $cleanupPath -InputObject $cleanup
    Assert-PoolThrows {Invoke-LabWindowsPoolMemberPreview -PreviewId $cleanupPreview.PreviewId -Confirm} WINDOWS_POOL_CLEANUP_PLAN_BINDING_INVALID
    $cleanup.steps=@();Write-LabArtifactJsonAtomic -Path $cleanupPath -InputObject $cleanup
    if($IsWindows){
        $alias=Join-Path $fixture root-junction
        $null=New-Item -ItemType Junction -Path $alias -Target $root
        Assert-PoolThrows {Resolve-LabWindowsPoolRoot -StateRoot $alias} WINDOWS_POOL_ROOT_REPARSE
        Assert-PoolThrows {Assert-LabWindowsPoolRootSupport -StateRoot $alias} WINDOWS_POOL_ROOT_LOCALITY_UNSUPPORTED
    }
    $current=Get-LabRunState -RunId $runId -StateRoot $root
    $claimContext=[pscustomobject]@{StateRoot=(Resolve-LabWindowsPoolRoot $root);PoolId=$poolId;OperationId=$claimed.OperationId;RunId=$runId;Kind='Consume'}
    $sqlPlan=@{SqlVersion='2025';DeploymentMode='adhoc-install';MediaEdition='Eval';SqlMediaPath='synthetic-media';SqlFeatures=@('SQLENGINE');ProcessorCount=8;MemoryStartupMB=8192}
    Assert-PoolThrows {New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Consume -SqlDeploymentPlan ($sqlPlan+@{NetworkMode='invalid'})} WINDOWS_POOL_CONSUME_PLAN_INVALID
    Assert-PoolThrows {New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Consume -SqlDeploymentPlan ($sqlPlan+@{ServerConfig=@{password='synthetic-only-fixture'}})} WINDOWS_POOL_CONSUME_SERVER_CONFIG_INVALID
    Assert-PoolThrows {New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Consume -SqlDeploymentPlan ($sqlPlan+@{StorageConfiguration=@{password='synthetic-only-fixture'}})} WINDOWS_POOL_CONSUME_STORAGE_CONFIG_INVALID
    $validConfig=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action consume -SqlDeploymentPlan ($sqlPlan+@{ServerConfig=@{memory=@{minMB=0;maxMB=512};maxDop=1;costThreshold=5;traceFlags=@();spConfigure=@{'optimize for ad hoc workloads'=1}};StorageConfiguration=@{dataPath='E:\SQLData';logPath='L:\SQLLog';tempDbPaths=@('T:\TempDB');backupPath='R:\SQLBackup'}})
    Assert-Pool ($validConfig.Action -ceq 'Consume') 'canonical action and existing structured SQL contracts accepted'
    $null=Invoke-LabWindowsPoolMemberPreview -PreviewId $validConfig.PreviewId -Cancel
    Assert-Pool ((Get-LabWindowsPoolPlanKey @{a=1;b=@{c=2;d=3}}) -ceq (Get-LabWindowsPoolPlanKey @{b=@{d=3;c=2};a=1})) 'canonical plan property ordering'
    foreach($fault in @('CPU','RAM','PERSIST','JOURNAL','POSTCONDITION')){
        $script:PoolCheckProviderFault=$null;$script:PoolCheckFaultArmed=$false
        Invoke-WithLabWindowsPoolOperation -Context $claimContext -Body {
            Complete-LabWindowsPoolPreparation -RunId $runId -StateRoot $root -KeepClaim -Receipt ([pscustomobject]@{observedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o');evaluationExpiresAt=[datetime]::UtcNow.AddDays(90).ToString('o');licenseStatus=1;provisioningComplete=$true})
        }
        $consume=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Consume -SqlDeploymentPlan $sqlPlan
        $script:PoolCheckProviderFault=$fault
        if($fault -in @('PERSIST','JOURNAL')){
            $script:PoolCheckFaultPath=if($fault -ceq 'PERSIST'){Join-Path $created.RunDir connection-info.json}else{Join-Path (Join-Path $root operations) ($claimed.OperationId+'.json')}
            # JOURNAL fires on the result write, after the persisted intent.
            $script:PoolCheckFaultArmed=$true;$script:PoolCheckJournalSkip=if($fault -ceq 'JOURNAL'){1}else{0}
        }
        $failed=Invoke-LabWindowsPoolMemberPreview -PreviewId $consume.PreviewId -Confirm
        $held=Get-LabRunState -RunId $runId -StateRoot $root
        Assert-Pool ($failed.Status -ceq 'RECOVERY_REQUIRED' -and $held.metadata.windowsPoolMember.state -ceq 'RECOVERY_REQUIRED' -and $held.metadata.windowsPoolMember.claim.operationId -ceq $claimed.OperationId -and $held.metadata.windowsPoolMember.claim.providerMutationStarted) ('consume '+$fault+' reserved same operation')
    }
    $script:PoolCheckProviderFault=$null;$script:PoolCheckFaultArmed=$false
    function Stop-HyperVLabEnvironment {param($RunId,$StateRoot)
        Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $StateRoot -InvalidateEvidence
        $script:PoolCheckFixture.VMState='Off'
    }
    $script:PoolCheckFixture.VMState='Running'
    $stop=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Stop
    $stopped=Invoke-LabWindowsPoolMemberPreview -PreviewId $stop.PreviewId -Confirm
    Assert-Pool ($stopped.Status -ceq 'STOPPED_CLAIM_HELD' -and (Get-LabRunState -RunId $runId -StateRoot $root).metadata.windowsPoolMember.claim.operationId -ceq $claimed.OperationId) 'explicit held recovery stop preserves claim'
    Invoke-WithLabWindowsPoolOperation -Context $claimContext -Body {
        Complete-LabWindowsPoolPreparation -RunId $runId -StateRoot $root -KeepClaim -Receipt ([pscustomobject]@{observedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o');evaluationExpiresAt=[datetime]::UtcNow.AddDays(90).ToString('o');licenseStatus=1;provisioningComplete=$true})
    }
    Invoke-WithLabWindowsPoolOperation -Context $claimContext -Body {
        Assert-LabWindowsPoolMutationAllowed -RunId $runId -StateRoot $root -InvalidateEvidence
        $changed=Get-LabRunState -RunId $runId -StateRoot $root
        Assert-Pool ($changed.metadata.windowsPoolMember.claim.providerMutationStarted -and -not $changed.metadata.windowsPoolMember.evidence) 'invalidate before provider'
    }
    Assert-PoolThrows {New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Release} WINDOWS_POOL_RELEASE_NOT_PROVEN_SAFE
    $prior=Get-LabRunState -RunId $runId -StateRoot $root
    Invoke-WithLabWindowsPoolOperation -Context $claimContext -Body {
        Complete-LabWindowsPoolPreparation -RunId $runId -StateRoot $root -KeepClaim -Receipt ([pscustomobject]@{observedAt=[datetime]::UtcNow.AddMinutes(-1).ToString('o');evaluationExpiresAt=[datetime]::UtcNow.AddDays(90).ToString('o');licenseStatus=1;provisioningComplete=$true})
    }
    $consume=New-LabWindowsPoolMemberPreview -RunId $runId -StateRoot $root -Action Consume -SqlDeploymentPlan $sqlPlan
    $consumed=Invoke-LabWindowsPoolMemberPreview -PreviewId $consume.PreviewId -Confirm
    Assert-Pool ($consumed.Status -ceq 'CONSUMED' -and (Get-LabRunState -RunId $runId -StateRoot $root).metadata.windowsPoolMember.state -ceq 'CONSUMED') 'consume fully persisted CPU RAM then terminal'
    Assert-PoolThrows {Write-LabArtifactJsonAtomic -Path $statePath -InputObject $prior} WINDOWS_POOL_STATE_SNAPSHOT_STALE
    $terminal=Get-LabRunState -RunId $runId -StateRoot $root
    $terminal.metadata.windowsPoolMember.state='FREE';$terminal.metadata.windowsPoolMember.claim=$null
    Write-LabArtifactJsonAtomic -Path $statePath -InputObject $terminal
    Assert-Pool ((Get-LabRunState -RunId $runId -StateRoot $root).metadata.windowsPoolMember.state -ceq 'CONSUMED') 'terminal member preserved against forged snapshot'
    Set-LabRunState -RunId $runId -StateRoot $root -NewState RUNNING
    Assert-Pool ((Get-LabRunState -RunId $runId -StateRoot $root).state -ceq 'RUNNING') 'consumed normal lifecycle'
    $movingPlan=[pscustomobject]@{StateRoot=$root;Source=[pscustomobject]@{LabDataRoot=$fixture};Target=[pscustomobject]@{LabDataRoot=(Join-Path $fixture relocated)}}
    Assert-PoolThrows {Assert-LabWindowsPoolStateRootMigrationAllowed -Plan $movingPlan} WINDOWS_POOL_STATE_ROOT_MIGRATION_BLOCKED
    $movingPlan.Source.LabDataRoot=Join-Path $fixture other-storage
    Assert-LabWindowsPoolStateRootMigrationAllowed -Plan $movingPlan
    Assert-Pool $true 'storage migration without canonical root move allowed'
    $script:PoolCheckDefaultRoot=Join-Path $fixture unrelated-default
    Assert-PoolThrows {Initialize-HyperVWindowsGuestDrives @guestArguments} HYPERV_GUEST_DRIVE_PLAN_MISSING
    $script:PoolCheckDefaultRoot=$root
    $syntheticPassword.Dispose()
    $movingPlan.Source.LabDataRoot=$fixture
    $consumedSnapshot=Get-LabRunState -RunId $runId -StateRoot $root
    $removedSnapshot=$consumedSnapshot | ConvertTo-Json -Depth 20 | ConvertFrom-Json -Depth 20
    $removedSnapshot.state='REMOVED';$removedSnapshot.metadata.windowsPoolMember.state='REMOVED'
    Write-LabArtifactJsonAtomicRaw -Path $statePath -InputObject $removedSnapshot
    Assert-LabWindowsPoolStateRootMigrationAllowed -Plan $movingPlan
    Assert-Pool $true 'removed tombstone without live binding allows root move'
    # Exercise the real native inventory boundary, including nonterminating
    # errors and recorded IDs whose Notes can no longer be rediscovered.
    $script:PoolCheckInventoryFault=$true
    Assert-PoolThrows {Assert-LabWindowsPoolStateRootMigrationAllowed -Plan $movingPlan} WINDOWS_POOL_STATE_ROOT_MIGRATION_BLOCKED
    Assert-PoolThrows {Get-LabWindowsPoolCleanupBinding -RunId $runId -StateRoot $root} WINDOWS_POOL_VM_INVENTORY_UNKNOWN
    $creationConfig=[pscustomobject]@{StartIndex=1;Count=1;NamePrefix='synthetic-new-pool'}
    $creationPoolId=[guid]::NewGuid().ToString()
    $creationContext=[pscustomobject]@{StateRoot=$root;PoolId=$creationPoolId}
    Assert-PoolThrows {Get-LabWindowsPoolCreationPreview -PoolId $creationPoolId -Configuration $creationConfig -StateRoot $root} WINDOWS_POOL_VM_INVENTORY_UNKNOWN
    Assert-PoolThrows {Invoke-LabWindowsPoolPreparation -Context $creationContext -Configuration $creationConfig} WINDOWS_POOL_VM_INVENTORY_UNKNOWN
    $script:PoolCheckInventoryFault=$false
    $script:PoolCheckInventory=@([pscustomobject]@{Id=$vmId;Name='renamed-synthetic-vm';Notes='';State='Off'})
    Assert-PoolThrows {Assert-LabWindowsPoolStateRootMigrationAllowed -Plan $movingPlan} WINDOWS_POOL_STATE_ROOT_MIGRATION_BLOCKED
    Assert-PoolThrows {Get-LabWindowsPoolCleanupBinding -RunId $runId -StateRoot $root} WINDOWS_POOL_VM_BINDING_INVALID
    $script:PoolCheckInventory=@([pscustomobject]@{Id=$vmId;Name='renamed-synthetic-vm';Notes=(ConvertTo-HyperVLabNotes -RunId ([guid]::NewGuid().ToString()) -ScopeId ([guid]::NewGuid().ToString()) -InstanceId primary -ChildVhdxPath (Join-Path $fixture foreign-child.vhdx));State='Off'})
    Assert-PoolThrows {Assert-LabWindowsPoolStateRootMigrationAllowed -Plan $movingPlan} WINDOWS_POOL_STATE_ROOT_MIGRATION_BLOCKED
    Assert-PoolThrows {Get-LabWindowsPoolCleanupBinding -RunId $runId -StateRoot $root} WINDOWS_POOL_VM_BINDING_INVALID
    $script:PoolCheckInventory=@([pscustomobject]@{Id=[guid]::NewGuid().ToString();Name='synthetic-pool-01';Notes='';State='Off'})
    Assert-PoolThrows {Assert-LabWindowsPoolStateRootMigrationAllowed -Plan $movingPlan} WINDOWS_POOL_STATE_ROOT_MIGRATION_BLOCKED
    Assert-PoolThrows {Get-LabWindowsPoolCleanupBinding -RunId $runId -StateRoot $root} WINDOWS_POOL_VM_BINDING_INVALID
    $script:PoolCheckInventory=@()
    Assert-Pool (-not (Get-LabWindowsPoolCleanupBinding -RunId $runId -StateRoot $root).LiveVMExists) 'successful empty native inventory proves cleanup absence'
    Assert-Pool (@(Get-LabWindowsPoolCreationPreview -PoolId $creationPoolId -Configuration $creationConfig -StateRoot $root)[0].Action -ceq 'CREATE') 'successful empty native inventory permits creation preview'
    Write-LabArtifactJsonAtomicRaw -Path $statePath -InputObject $consumedSnapshot
    # Own fixture remains for the separate-process race phase; no runtime or secret.
    . (Join-Path $repoRoot 'Tests/Common/WindowsPoolNativeAcceptance.ps1')
    $captureOriginalFunctions=@{}
    foreach($name in @('Get-LabWindowsPoolGuestReceipt','ConvertTo-LabWindowsPoolUtc','Test-LabWindowsPoolOperationContext','Invoke-HyperVPowerShellDirect','Get-CimInstance','Get-ItemProperty','Get-WinSystemLocale','Get-UICulture','Get-TimeZone','Get-WinHomeLocation','Get-WinUserLanguageList')){
        $item=Get-Item ('Function:'+$name) -ErrorAction SilentlyContinue
        $captureOriginalFunctions[$name]=if($item){$item.ScriptBlock}else{$null}
    }
    $captureModule=New-Module -ScriptBlock ([scriptblock]::Create(({
        param($capture,$utc)
        Set-Item Function:Get-LabWindowsPoolGuestReceipt -Value ([scriptblock]::Create($capture.ToString()))
        Set-Item Function:ConvertTo-LabWindowsPoolUtc -Value ([scriptblock]::Create($utc.ToString()))
        function Test-LabWindowsPoolOperationContext {param($Member,$StateRoot) $script:ContextValid}
        function Invoke-HyperVPowerShellDirect {param($VMName,$ExpectedRunId,$ExpectedScopeId,$ExpectedVmId,$Credential,$TimeoutSeconds,$ScriptBlock)
            if([string]$ExpectedVmId -cne $script:ExpectedVmId){throw 'WINDOWS_POOL_CAPTURE_IDENTITY_INVALID'}
            & $ScriptBlock
        }
        function Get-CimInstance {param($ClassName,$Filter) $script:Product}
        function Get-ItemProperty {param($Path) if($Path -like '*CurrentVersion'){[pscustomobject]@{EditionID=$script:Edition}}else{[pscustomobject]@{OOBEInProgress=0;SystemSetupInProgress=0}}}
        function Get-WinSystemLocale {[pscustomobject]@{Name='de-AT'}}
        function Get-UICulture {[pscustomobject]@{Name=$script:UiLanguage}}
        function Get-TimeZone {[pscustomobject]@{Id='W. Europe Standard Time'}}
        function Get-WinHomeLocation {[pscustomobject]@{GeoId=[Globalization.RegionInfo]::new('AT').GeoId}}
        function Get-WinUserLanguageList {[pscustomobject]@{InputMethodTips=@($script:InputLocale)}}
        $script:ContextValid=$true;$script:Edition='ServerStandardEval';$script:UiLanguage='en-US';$script:InputLocale='0407:00000407';$script:ExpectedVmId=[guid]::NewGuid().ToString()
        $script:Product=[pscustomobject]@{PartialProductKey='synthetic';LicenseIsAddon=$false;LicenseStatus=1;GracePeriodRemaining=1440;EvaluationEndDate=$null}
    }).ToString())) -ArgumentList ${function:Get-LabWindowsPoolGuestReceipt},${function:ConvertTo-LabWindowsPoolUtc}
    $captureVm=& $captureModule {$script:ExpectedVmId}
    $captureBound=[pscustomobject]@{Member=[pscustomobject]@{};StateRoot=$root;Managed=[pscustomobject]@{VM=[pscustomobject]@{State='Running';Name='synthetic';Id=[guid]$captureVm}};Run=[pscustomobject]@{runId='synthetic-run';scopeId='synthetic-scope';metadata=[pscustomobject]@{windowsLocale=[pscustomobject]@{Region='AT';SystemLocale='de-AT';UiLanguage='en-US';InputLocale='0407:00000407';TimeZone='W. Europe Standard Time'}}}}
    $captureSecret=[Security.SecureString]::new()
    foreach($character in [guid]::NewGuid().ToString().ToCharArray()){$captureSecret.AppendChar($character)}
    $captureSecret.MakeReadOnly()
    $captureCredential=[pscredential]::new('synthetic',$captureSecret)
    function Invoke-CaptureFixture {& $captureModule {param($b,$c)Get-LabWindowsPoolGuestReceipt -Bound $b -Credential $c} $captureBound $captureCredential}
    $freshCapture=Invoke-CaptureFixture
    Assert-Pool ([math]::Abs((([datetime]$freshCapture.evaluationExpiresAt)-([datetime]$freshCapture.observedAt)).TotalMinutes-1440) -lt 0.01) 'actual guest script positiveGrace without endDate uses fresh observedAt'
    & $captureModule {$script:Product.EvaluationEndDate=[datetime]::new(1601,1,1)}
    $sentinelCapture=Invoke-CaptureFixture
    Assert-Pool ([math]::Abs((([datetime]$sentinelCapture.evaluationExpiresAt)-([datetime]$sentinelCapture.observedAt)).TotalMinutes-1440) -lt 0.01) 'actual guest script normalized sentinel date uses fresh positive grace'
    & $captureModule {$script:Product.GracePeriodRemaining=0}
    Assert-PoolThrows {Invoke-CaptureFixture} WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID
    & $captureModule {$script:Product.GracePeriodRemaining=1440;$script:Product.LicenseStatus=0}
    Assert-PoolThrows {Invoke-CaptureFixture} WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID
    & $captureModule {$script:Product.LicenseStatus=1;$script:Product.EvaluationEndDate=$null}
    & $captureModule {$script:UiLanguage='de-DE';$script:InputLocale='0409:00000409'}
    $fieldFailure=$null;try{Invoke-CaptureFixture}catch{$fieldFailure=$_}
    Assert-Pool ($fieldFailure.Exception.Message -ceq 'WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID' -and
        @($fieldFailure.Exception.Data['WindowsPoolCaptureMismatchCodes']).Count -eq 2 -and
        $fieldFailure.Exception.Data['WindowsPoolCaptureMismatchCodes'][0] -ceq 'UI_LANGUAGE_MISMATCH' -and
        $fieldFailure.Exception.Data['WindowsPoolCaptureMismatchCodes'][1] -ceq 'INPUT_LOCALE_MISMATCH') 'actual capture diagnoses both mismatches without weakening guard or exposing values'
    & $captureModule {$script:UiLanguage='en-US';$script:InputLocale='0407:00000407'}
    & $captureModule {$script:Product.GracePeriodRemaining=0}
    Assert-PoolThrows {Invoke-CaptureFixture} WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID
    & $captureModule {$script:Product.GracePeriodRemaining=1440;$script:Product.LicenseStatus=0}
    Assert-PoolThrows {Invoke-CaptureFixture} WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID
    & $captureModule {$script:Product.LicenseStatus=1;$script:Edition='ServerStandard'}
    Assert-PoolThrows {Invoke-CaptureFixture} WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID
    & $captureModule {$script:Edition='ServerStandardEval';$script:Product.EvaluationEndDate=[datetime]::UtcNow.AddDays(3);$script:Product.GracePeriodRemaining=0}
    $endCapture=Invoke-CaptureFixture
    Assert-Pool ([datetime]$endCapture.evaluationExpiresAt -gt [datetime]::UtcNow.AddDays(2)) 'actual guest script explicit endDate remains supported'
    & $captureModule {$script:Product.EvaluationEndDate='malformed';$script:Product.GracePeriodRemaining=1440}
    $invalidEndFailed=$false;try{Invoke-CaptureFixture}catch{$invalidEndFailed=$true};Assert-Pool $invalidEndFailed 'invalid explicit endDate never falls back'
    & $captureModule {$script:Product.EvaluationEndDate=[datetime]::UtcNow.AddMinutes(-1)}
    $expiredFailure=$null;try{Invoke-CaptureFixture}catch{$expiredFailure=$_}
    Assert-Pool ($expiredFailure.Exception.Message -ceq 'WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID' -and
        @($expiredFailure.Exception.Data['WindowsPoolCaptureMismatchCodes']).Count -eq 1 -and
        $expiredFailure.Exception.Data['WindowsPoolCaptureMismatchCodes'][0] -ceq 'EXPIRY_NOT_AFTER_CAPTURE') 'real expired end date keeps priority over positive grace'
    & $captureModule {$script:ExpectedVmId=[guid]::NewGuid().ToString()}
    Assert-PoolThrows {Invoke-CaptureFixture} WINDOWS_POOL_CAPTURE_IDENTITY_INVALID
    & $captureModule {$script:ContextValid=$false}
    Assert-PoolThrows {Invoke-CaptureFixture} WINDOWS_POOL_CAPTURE_CONTEXT_REQUIRED
    $captureSecret.Dispose()
    foreach($name in $captureOriginalFunctions.Keys){
        if($captureOriginalFunctions[$name]){Set-Item ('Function:script:'+$name) -Value $captureOriginalFunctions[$name]}
        else{Remove-Item ('Function:script:'+$name) -ErrorAction SilentlyContinue}
    }
    Assert-Pool (${function:Test-LabWindowsPoolOperationContext}.ToString() -ceq $captureOriginalFunctions['Test-LabWindowsPoolOperationContext'].ToString()) 'actual canonical operation-context function restored after isolated guest mocks'
    $safeFailure=$null;try{throw 'WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID: synthetic private diagnostic'}catch{$safeFailure=$_}
    $safeDetail=Get-WindowsPoolNativeFailureDetail -Failure $safeFailure -Fallback SYNTHETIC_FALLBACK
    Assert-Pool ($safeDetail.Code -ceq 'WINDOWS_POOL_CAPTURE_EVIDENCE_INVALID' -and ($safeDetail|ConvertTo-Json) -notmatch 'private diagnostic') 'native cause detail retains fixed code without raw diagnostic'
    $nativeMediaRoot=Join-Path $fixture native-media
    $nativeRelative='SQL/2025/Enterprise/ISO/synthetic-EntDev.iso'
    $nativeIso=Join-Path $nativeMediaRoot $nativeRelative
    $nativeHashPath=Join-Path (Join-Path $nativeMediaRoot Hashes) ($nativeRelative+'.sha256')
    $null=New-Item -ItemType Directory -Path (Split-Path $nativeIso),(Split-Path $nativeHashPath) -Force
    Set-Content -LiteralPath $nativeIso -Value 'synthetic ISO boundary only' -Encoding utf8
    $nativeDigest=(Get-FileHash -LiteralPath $nativeIso -Algorithm SHA256).Hash.ToLowerInvariant()
    Set-Content -LiteralPath $nativeHashPath -Value ($nativeDigest+'  '+$nativeRelative) -Encoding utf8
    # Actual product resolver/path-edition contract; only the ISO/mount and
    # path-platform probes are synthetic. Never mount media in offline checks.
    $nativeMediaModule=New-Module -ScriptBlock ([scriptblock]::Create(({
        param($resolver,$editionParser)
        Set-Item Function:Resolve-HyperVSqlInstallationMedia -Value ([scriptblock]::Create($resolver.ToString()))
        Set-Item Function:Get-HyperVSqlMediaEditionFromPath -Value ([scriptblock]::Create($editionParser.ToString()))
        function Get-HyperVSqlInstallationMediaInfo {param($IsoPath)[pscustomobject]@{SqlVersion=$script:Version}}
        function Test-WindowsInstallationIso {param($Path) $true}
        function Test-LabPathWithinRoot {param($Root,$Path)[pscustomobject]@{Valid=$true}}
        function Get-DiskImage {param($ImagePath) $script:ImageProbes++;[pscustomobject]@{Attached=($script:AlreadyAttached -or ($script:LeaveAttached -and $script:ImageProbes -gt 1))}}
        $script:Version='2025'
    }).ToString())) -ArgumentList ${function:Resolve-HyperVSqlInstallationMedia},${function:Get-HyperVSqlMediaEditionFromPath}
    $nativeMediaArgs=@{Module=$nativeMediaModule;MediaRoot=$nativeMediaRoot;MediaEdition='Enterprise';SqlMediaPath=$nativeRelative}
    $nativeMedia=Resolve-WindowsPoolNativeSqlMedia @nativeMediaArgs
    Assert-Pool ($nativeMedia.IsoPath -ceq $nativeIso -and $nativeMedia.RelativePath -ceq $nativeRelative -and $nativeMedia.MediaEdition -ceq 'Enterprise') 'native Developer mapped Enterprise; absolute ISO and relative consume binding'
    Assert-Pool ((ConvertTo-HyperVSqlMediaEdition EnterpriseDeveloper) -ceq 'Enterprise' -and (ConvertTo-HyperVSqlMediaEdition StandardDeveloper) -ceq 'Standard') 'existing Developer media edition mapping'
    & $nativeMediaModule {$script:AlreadyAttached=$true}
    Assert-PoolThrows {Resolve-WindowsPoolNativeSqlMedia @nativeMediaArgs} WINDOWS_POOL_NATIVE_EXISTING_ISO_MOUNT_NOT_ADOPTED
    & $nativeMediaModule {$script:AlreadyAttached=$false;$script:LeaveAttached=$true;$script:ImageProbes=0}
    Assert-PoolThrows {Resolve-WindowsPoolNativeSqlMedia @nativeMediaArgs} WINDOWS_POOL_NATIVE_OWN_ISO_MOUNT_RETAINED
    & $nativeMediaModule {$script:Version='2022';$script:ImageProbes=0}
    $mountFailure=$null;try{Resolve-WindowsPoolNativeSqlMedia @nativeMediaArgs}catch{$mountFailure=$_.Exception}
    Assert-Pool ($mountFailure.Data['OriginalError'] -like 'HYPERV_SQL_MEDIA_VERSION_MISMATCH*' -and $mountFailure.Data['CleanupError'] -ceq 'WINDOWS_POOL_NATIVE_OWN_ISO_MOUNT_RETAINED') 'own ISO failure preserves resolver error and cleanup error separately'
    & $nativeMediaModule {$script:Version='2025';$script:LeaveAttached=$false;$script:ImageProbes=0}
    Assert-PoolThrows {Resolve-WindowsPoolNativeSqlMedia -Module $nativeMediaModule -MediaRoot $nativeMediaRoot -MediaEdition Enterprise -SqlMediaPath $nativeIso} HYPERV_SQL_MEDIA_PATH_INVALID
    Assert-PoolThrows {Resolve-WindowsPoolNativeSqlMedia -Module $nativeMediaModule -MediaRoot $nativeMediaRoot -MediaEdition Eval -SqlMediaPath $nativeRelative} HYPERV_SQL_MEDIA_EDITION_MISMATCH
    & $nativeMediaModule {$script:Version='2022'}
    Assert-PoolThrows {Resolve-WindowsPoolNativeSqlMedia @nativeMediaArgs} HYPERV_SQL_MEDIA_VERSION_MISMATCH
    & $nativeMediaModule {$script:Version='2025'}
    Set-Content -LiteralPath $nativeIso -Value 'synthetic drift' -Encoding utf8
    Assert-PoolThrows {Resolve-WindowsPoolNativeSqlMedia @nativeMediaArgs} WINDOWS_POOL_NATIVE_SQL_MEDIA_HASH_MISMATCH
    Remove-Item -LiteralPath $nativeHashPath
    Assert-PoolThrows {Resolve-WindowsPoolNativeSqlMedia @nativeMediaArgs} WINDOWS_POOL_NATIVE_SELECTED_SQL_MEDIA_REQUIRED
    $nativeAcceptanceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Tests/Integration/Invoke-WindowsPoolClaimAcceptance.ps1'),[ref]$null,[ref]$null)
    $nativeSqlAst=$nativeAcceptanceAst.Find({param($node)$node -is [Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -ceq '$sql'},$true)
    Assert-Pool ($nativeSqlAst.Right.Extent.Text -match 'MediaEdition=\$media.MediaEdition' -and $nativeSqlAst.Right.Extent.Text -match 'SqlMediaPath=\$media.RelativePath') 'actual native consume AST uses resolved edition and relative path'
    $nativeBindings=[ordered]@{}
    $nativeRun=[pscustomobject]@{runId=[guid]::NewGuid().ToString();scopeId=[guid]::NewGuid().ToString();state='STOPPED';metadata=[pscustomobject]@{name='before-rename';windowsPoolMember=$null}}
    $nativeRun.metadata.windowsPoolMember=[pscustomobject]@{poolId=$poolId;runId=$nativeRun.runId;scopeId=$nativeRun.scopeId;vmId=[guid]::NewGuid().ToString();state='CONSUMED'}
    $nativeSnapshot=[pscustomobject]@{Run=$nativeRun;VmId=$nativeRun.metadata.windowsPoolMember.vmId;RunDirectory=(Join-Path $fixture native-own-run);ChildPaths=@((Join-Path $fixture native-own-child.vhdx));AdapterIds=@('own-adapter')}
    Update-WindowsPoolNativeAcceptanceBindings -Bindings $nativeBindings -Snapshots @($nativeSnapshot) -PoolId $poolId
    $nativeRun.metadata.name='after-rename'
    Update-WindowsPoolNativeAcceptanceBindings -Bindings $nativeBindings -Snapshots @($nativeSnapshot) -PoolId $poolId
    Assert-Pool ($nativeBindings.Count -eq 1 -and $nativeBindings[$nativeRun.runId].VmId -ceq $nativeSnapshot.VmId) 'native rename preserves original identity'
    Assert-PoolThrows {Update-WindowsPoolNativeAcceptanceBindings -Bindings $nativeBindings -Snapshots @() -PoolId $poolId} WINDOWS_POOL_NATIVE_OWN_DISCOVERY_MISSING
    Assert-Pool ($nativeBindings.Contains($nativeRun.runId)) 'empty rediscovery cannot erase original bindings'
    $originalNativeVm=$nativeSnapshot.VmId;$nativeSnapshot.VmId=[guid]::NewGuid().ToString()
    Assert-PoolThrows {Update-WindowsPoolNativeAcceptanceBindings -Bindings $nativeBindings -Snapshots @($nativeSnapshot) -PoolId $poolId} WINDOWS_POOL_NATIVE_ORIGINAL_BINDING_CHANGED
    $nativeSnapshot.VmId=$originalNativeVm
    $nativeRun.state='REMOVED';$nativeRun.metadata.windowsPoolMember.state='REMOVED'
    $nativeProof=@{Binding=$nativeBindings[$nativeRun.runId];Run=$nativeRun}
    foreach($resource in @('LiveVms','ExistingChildren','LiveAdapterIds','ActiveLeases','SecretExists')){
        $proof=@{}+$nativeProof;$proof[$resource]=if($resource -ceq 'SecretExists'){$true}else{@('synthetic-own-resource')}
        Assert-PoolThrows {Assert-WindowsPoolNativeCleanupProof @proof} WINDOWS_POOL_NATIVE_OWN_RESOURCE_REMAINED
    }
    Assert-WindowsPoolNativeCleanupProof @nativeProof
    Assert-Pool $true 'complete native cleanup proof accepted'
    $nativeBindings[$nativeRun.runId].IpamRequired=$true
    Assert-PoolThrows {Assert-WindowsPoolNativeCleanupProof @nativeProof -IpamAvailable:$false} WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN
    $ipamRoot=Join-Path $fixture native-ipam-proof
    $ipamNetwork=[pscustomobject]@{Name='synthetic-ipam-network';Subnet='192.0.2.0/24';PrefixLength=24;HostAddress='192.0.2.1'}
    $canonicalLease=Reserve-LabHyperVNetworkAddress -Network $ipamNetwork -RunId $nativeRun.runId -ScopeId $nativeRun.scopeId -InstanceId primary -StateRoot $ipamRoot
    $ipamPath=Get-LabHyperVIpamPath -StateRoot $ipamRoot
    $canonicalActive=Read-LabWorkflowJson -Path $ipamPath
    $released=Release-LabHyperVNetworkAddress -Address $canonicalLease.address -RunId $nativeRun.runId -ScopeId $nativeRun.scopeId -StateRoot $ipamRoot
    Assert-Pool $released 'canonical own IPAM lease release'
    $canonicalReleased=Read-LabWorkflowJson -Path $ipamPath
    $acceptanceAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot Tests/Integration/Invoke-WindowsPoolClaimAcceptance.ps1),[ref]$null,[ref]$null)
    $ipamAst=$acceptanceAst.Find({param($node)$node -is [Management.Automation.Language.ScriptBlockAst] -and $node.Extent.Text -match '^\{param\(\$root,\$id,\$scope\)'},$true)
    if(-not $ipamAst){throw 'WINDOWS_POOL_NATIVE_IPAM_AST_MISSING'}
    $ipamLookup=[scriptblock]::Create($ipamAst.Extent.Text.Substring(1,$ipamAst.Extent.Text.Length-2))
    $realIpamReader=${function:Read-LabWorkflowJson}
    function Read-LabWorkflowJson {param($Path) $script:PoolCheckIpamRegistry}
    try{
        $cases=@(
            [pscustomobject]@{Name='null registry';Registry=$null;Error='WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'},
            [pscustomobject]@{Name='missing registry structure';Registry=('{}'|ConvertFrom-Json);Error='WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'},
            [pscustomobject]@{Name='null leases';Registry=(' {"contractVersion":"1","leases":null}'|ConvertFrom-Json);Error='WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'},
            [pscustomobject]@{Name='object leases';Registry=(' {"contractVersion":"1","leases":{}}'|ConvertFrom-Json);Error='WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'},
            [pscustomobject]@{Name='noncanonical numeric version';Registry=(' {"contractVersion":1,"leases":[]}'|ConvertFrom-Json);Error='WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'},
            [pscustomobject]@{Name='canonical active own lease';Registry=$canonicalActive;Error='WINDOWS_POOL_NATIVE_OWN_RESOURCE_REMAINED'},
            [pscustomobject]@{Name='canonical released own lease';Registry=$canonicalReleased;Error=$null},
            [pscustomobject]@{Name='canonical empty registry';Registry=(' {"contractVersion":"1","leases":[]}'|ConvertFrom-Json);Error=$null}
        )
        foreach($mutation in @('UNKNOWN','partialScope','missingInstance','invalidLeaseId','missingReleaseTime','foreignActive')){
            $copy=$canonicalReleased|ConvertTo-Json -Depth 10|ConvertFrom-Json -Depth 10
            switch($mutation){
                UNKNOWN {$copy.leases[0].state='UNKNOWN'}
                partialScope {$copy.leases[0].scopeId=[guid]::NewGuid().ToString()}
                missingInstance {$copy.leases[0].PSObject.Properties.Remove('instanceId')}
                invalidLeaseId {$copy.leases[0].leaseId='malformed'}
                missingReleaseTime {$copy.leases[0].releasedAt=$null}
                foreignActive {$copy.leases[0].runId=[guid]::NewGuid().ToString();$copy.leases[0].scopeId=[guid]::NewGuid().ToString();$copy.leases[0].state='ACTIVE';$copy.leases[0].releasedAt=$null}
            }
            $cases+=[pscustomobject]@{Name=$mutation;Registry=$copy;Error=$(if($mutation -ceq 'foreignActive'){$null}else{'WINDOWS_POOL_NATIVE_OWN_IPAM_UNKNOWN'})}
        }
        foreach($case in $cases){
            $script:PoolCheckIpamRegistry=$case.Registry;$failure=$null
            try{$leases=@(& $ipamLookup $ipamRoot $nativeRun.runId $nativeRun.scopeId);Assert-WindowsPoolNativeCleanupProof @nativeProof -ActiveLeases $leases -IpamAvailable:$true}catch{$failure=$_.Exception.Message}
            Assert-Pool ($failure -ceq $case.Error) ('actual native IPAM AST + cleanup helper: '+$case.Name)
        }
    }finally{Set-Item Function:Read-LabWorkflowJson -Value $realIpamReader}
    $nativeRun.state='STOPPED'
    Assert-PoolThrows {Assert-WindowsPoolNativeCleanupProof @nativeProof} WINDOWS_POOL_NATIVE_OWN_TERMINAL_MISSING
    $nativeParentBefore=Get-WindowsPoolNativeParentFingerprint -Path $parentPath
    Assert-WindowsPoolNativeParentUnchanged -Before $nativeParentBefore -After (Get-WindowsPoolNativeParentFingerprint -Path $parentPath)
    Assert-Pool $true 'independent parent fingerprint accepted'
    foreach($property in @('Path','Sha256','Length','WriteTicks','Attributes')){
        $changedParent=$nativeParentBefore|ConvertTo-Json|ConvertFrom-Json;$changedParent.$property='synthetic-drift'
        Assert-PoolThrows {Assert-WindowsPoolNativeParentUnchanged -Before $nativeParentBefore -After $changedParent} WINDOWS_POOL_NATIVE_PARENT_CHANGED
    }
    $nativeRun.state='REMOVED'
    $nativeRecovery=& {
        param($repoRoot,$fixture,$nativeRun,$nativeBindings,$poolId,$parentPath,$parentBefore)
        $StateRoot=$fixture;$prefix='synthetic-renamed';$ArtifactId='synthetic-pinned-parent'
        $bindings=$nativeBindings;$success=$true;$evidenceDirectory=Join-Path $fixture native-finally-proof
        $null=New-Item -ItemType Directory -Path $evidenceDirectory -Force
        $report=[ordered]@{RunIds=@($bindings.Keys);OriginalBindings=@($bindings.Values);StopErrors=@();CleanupErrors=@();Checks=@();Status='RUNNING';ParentAfter=$null}
        $module={
            param([scriptblock]$body)
            function Get-LabWindowsPoolRuns {@()}
            function Get-LabRunState {$nativeRun}
            & $body @args
        }.GetNewClosure()
        function Get-SqlServerLabHyperVImageArtifact {[pscustomobject]@{IntegrityStatus='VERIFIED'}}
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot Tests/Integration/Invoke-WindowsPoolClaimAcceptance.ps1),[ref]$null,[ref]$null)
        $discover=$ast.Find({param($node)$node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OwnNativeMembers'},$true)
        . ([scriptblock]::Create($discover.Extent.Text))
        $acceptanceTry=@($ast.EndBlock.Statements|Where-Object {$_ -is [Management.Automation.Language.TryStatementAst]})[-1]
        . ([scriptblock]::Create($acceptanceTry.Finally.Statements.Extent.Text -join "`n"))
        $report
    } $repoRoot $fixture $nativeRun $nativeBindings ([guid]$poolId) $parentPath $nativeParentBefore
    Assert-Pool ($nativeRecovery.Status -ceq 'CLEANUP_RECOVERY_REQUIRED' -and $nativeRecovery.RunIds[0] -ceq $nativeRun.runId -and
        @($nativeRecovery.StopErrors|Where-Object Code -ceq 'WINDOWS_POOL_NATIVE_OWN_INVENTORY_FAILED').Count -eq 1) 'actual native finally cannot PASS or lose original identity after empty rediscovery or missing state'
    [pscustomobject]@{Passed=$script:PoolCheckCount;StateRoot=$root;RunId=$runId;PoolId=$poolId;PrepareOperationId=$prepare.operationId;ClaimOperationId=$claimed.OperationId;ParentPath=$parentPath}
} $fixture $repoRoot
$result | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $fixture result.json) -Encoding utf8
if($SkipProcessChecks){Write-Host ('Windows pool focus: '+$result.Passed+' PASS; fixture='+$fixture);return}
$race=& $module {
    param($root)
    $pool=[guid]::NewGuid().ToString();$op=New-LabWindowsPoolOperationIntent -PoolId $pool -Purpose Prepare -StateRoot $root
    $context=[pscustomobject]@{StateRoot=(Resolve-LabWindowsPoolRoot $root);PoolId=$pool;OperationId=$op.operationId;RunId=$null;Kind='Prepare';Index=1}
    Invoke-WithLabWindowsPoolOperation -Context $context -Body {
        $created=New-LabRunState -StateRoot $root -Metadata @{name='process-race-synthetic';workflowKind='hyperv-lab';workload='windows';imageArtifactId=('hyperv-os-sealed-'+('b'*64))}
        $null=Set-LabWindowsPoolMemberState -RunId $created.RunId -StateRoot $root -ExpectedRevision 1 -Change {param($member)$member.vmId=[guid]::NewGuid().ToString();$member.state='FREE';$member.claim=$null}
        [pscustomobject]@{StateRoot=$root;RunId=$created.RunId;PoolId=$pool;Revision=2}
    }
} (Join-Path $fixture race-state)
$worker=Join-Path $PSScriptRoot Fixtures/WindowsPoolClaimWorker.ps1
$pwsh=(Get-Command pwsh -ErrorAction Stop).Source
$processes=[Collections.Generic.List[object]]::new()
function Start-PoolCheckWorker($id,$mode,$operationId,$root){
    $arguments=@('-NoLogo','-NoProfile','-File',$worker,'-RepositoryRoot',$repoRoot,'-StateRoot',$root,'-RunId',$race.RunId,'-PoolId',$race.PoolId,'-Directory',$fixture,'-WorkerId',$id,'-Mode',$mode)
    if($operationId){$arguments+=@('-OperationId',$operationId)}
    $processOptions=@{
        FilePath=$pwsh; ArgumentList=$arguments; PassThru=$true
        RedirectStandardOutput=(Join-Path $fixture ($id+'.stdout.log'))
        RedirectStandardError=(Join-Path $fixture ($id+'.stderr.log'))
    }
    if($IsWindows){$processOptions.WindowStyle='Hidden'}
    $process=Start-Process @processOptions
    $processes.Add($process);return $process
}
function Wait-PoolCheckFile($leaf){$deadline=[datetime]::UtcNow.AddSeconds(35);while(-not(Test-Path -LiteralPath (Join-Path $fixture $leaf))){if([datetime]::UtcNow -ge $deadline){throw ('WINDOWS_POOL_PROCESS_TIMEOUT: '+$leaf)};Start-Sleep -Milliseconds 50}}
function Read-PoolCheckResult($id){Wait-PoolCheckFile ($id+'.result.json');Get-Content -LiteralPath (Join-Path $fixture ($id+'.result.json')) -Raw | ConvertFrom-Json}
try {
    $one=Start-PoolCheckWorker race-1 Race $null $race.StateRoot
    $alias=if($IsWindows){$race.StateRoot.ToUpperInvariant()}else{$race.StateRoot}
    $two=Start-PoolCheckWorker race-2 Race $null $alias
    Wait-PoolCheckFile race-1.ready;Wait-PoolCheckFile race-2.ready
    [IO.File]::WriteAllText((Join-Path $fixture go),'go')
    $outcomes=@((Read-PoolCheckResult race-1),(Read-PoolCheckResult race-2))
    if(@($outcomes | Where-Object Status -eq WON).Count -ne 1 -or @($outcomes | Where-Object Status -eq WINDOWS_POOL_PREVIEW_STALE).Count -ne 1){throw 'WINDOWS_POOL_PROCESS_RACE_NOT_EXCLUSIVE'}
    $winner=@($outcomes | Where-Object Status -eq WON)[0]
    $hold=Start-PoolCheckWorker slot-holder Hold $winner.OperationId $race.StateRoot
    Wait-PoolCheckFile slot-holder.holding
    $contender=Start-PoolCheckWorker slot-contender Resume $winner.OperationId $alias
    $busy=Read-PoolCheckResult slot-contender
    if($busy.Status -cne 'WINDOWS_POOL_OPERATION_RUNNING'){throw 'WINDOWS_POOL_IDENTICAL_RESUME_NOT_EXCLUSIVE'}
    $cleanupBlocked=& $module {
        param($root,$pool,$run,$source)
        $operation=New-LabWindowsPoolOperationIntent -PoolId $pool -Purpose Cleanup -RunId $run -StateRoot $root
        $context=[pscustomobject]@{StateRoot=(Resolve-LabWindowsPoolRoot $root);PoolId=$pool;OperationId=$operation.operationId;RunId=$run;Kind='Cleanup'}
        $entered=$false;$failure=$null
        try{Invoke-WithLabWindowsPoolCleanupSource -Context $context -SourceOperationId $source -Body {$entered=$true}}catch{$failure=$_.Exception.Message}
        return (-not $entered -and $failure -ceq 'WINDOWS_POOL_OPERATION_RUNNING')
    } $race.StateRoot $race.PoolId $race.RunId $winner.OperationId
    if(-not $cleanupBlocked){throw 'WINDOWS_POOL_CLEANUP_STOLE_RUNNING_ORIGINAL_OPERATION'}
    # Kill only the test-owned worker by its returned process handle. The
    # canonical claim must survive, and the same operation may explicitly resume.
    Stop-Process -Id $hold.Id -Force -ErrorAction Stop
    $resume=Start-PoolCheckWorker crash-resume Resume $winner.OperationId $race.StateRoot
    $resumed=Read-PoolCheckResult crash-resume
    if($resumed.Status -cne 'RESUMED_SAME_OPERATION' -or $resumed.OperationId -cne $winner.OperationId){throw 'WINDOWS_POOL_CRASH_RESUME_FAILED'}
    $persisted=& $module {param($id,$root) Get-LabRunState -RunId $id -StateRoot $root} $race.RunId $race.StateRoot
    if($persisted.metadata.windowsPoolMember.state -cne 'CLAIMED' -or $persisted.metadata.windowsPoolMember.claim.operationId -cne $winner.OperationId){throw 'WINDOWS_POOL_CRASH_FREED_CLAIM'}
    if($IsWindows){
        $portable=Start-PoolCheckWorker portable Portable $null $race.StateRoot
        if((Read-PoolCheckResult portable).Status -cne 'PORTABLE_NON_POOL_READY_POOL_BLOCKED'){throw 'WINDOWS_POOL_PLATFORM_INTEROP_FAILCLOSED_FAILED'}
    }
    Write-Host ('Windows pool focus: '+$result.Passed+' PASS; process race / root alias / identical executor / cleanup source / crash resume: 5 PASS; platform interop denied / non-pool lifecycle: '+$(if($IsWindows){'PASS'}else{'NOT_APPLICABLE'})+'; fixture='+$fixture)
} finally {
    foreach($process in $processes){$process.Refresh();if(-not $process.HasExited){Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue};$process.Dispose()}
}
