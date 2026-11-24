#Requires -Version 7.2
[CmdletBinding()]param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path $repo ('.artifacts/evaluation-refresh-fixtures/'+[guid]::NewGuid().ToString('N'))
$checks=0
function Assert-Refresh($condition,$name){if(-not$condition){throw ('REFRESH_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
function Import-RefreshFunctions($relative){$tokens=$null;$errorsFound=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repo $relative),[ref]$tokens,[ref]$errorsFound);if($errorsFound.Count){throw 'FIXTURE_PARSE_FAILED'};foreach($s in $ast.EndBlock.Statements){if($s-is[Management.Automation.Language.FunctionDefinitionAst]){. ([scriptblock]::Create(($s.Extent.Text-replace'^function ','function script:')))}}}
function Write-Refresh($path,$value){$null=New-Item -ItemType Directory -Path (Split-Path $path) -Force;$value|ConvertTo-Json -Depth 40|Set-Content -LiteralPath $path -Encoding utf8}
function Get-RefreshHashes{(@(Get-ChildItem $root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})-join'|')}
function New-RefreshTargetFixture($DataRoot,$SourceRun,$SourceConnection,$State='STOPPED') {
    $targetRun=$SourceRun | ConvertTo-Json -Depth 40 | ConvertFrom-Json -AsHashtable
    $targetRun.runId=[guid]::NewGuid().ToString('D')
    $targetRun.scopeId=[guid]::NewGuid().ToString('D')
    $targetRun.state=$State
    $targetRun.providerSubRuns[0].state=$State
    $state=Join-Path $DataRoot 'State'
    $directory=Join-Path $state ('runs/'+$targetRun.runId)
    $targetConnection=$SourceConnection | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
    $targetConnection.instances[0].vmId=[guid]::NewGuid().ToString('D')
    $connectionFile=Join-Path $directory 'connection-info.json'
    Write-Refresh (Join-Path $directory 'run-state.json') $targetRun
    Write-Refresh (Join-Path $state ('scope-markers/'+$targetRun.scopeId+'.json')) @{runId=$targetRun.runId;scopeId=$targetRun.scopeId}
    Write-Refresh $connectionFile $targetConnection
    [pscustomobject]@{RunId=$targetRun.runId;ScopeId=$targetRun.scopeId;Run=$targetRun;Connection=$targetConnection;ConnectionFile=$connectionFile}
}
try {
    foreach($source in @('Private/DiagnosticBundleReader.ps1','Private/SqlGuestEvaluationEvidence.ps1','Private/EvaluationRefreshPlan.ps1','Private/VersionCatalog.ps1','Private/PathSafety.ps1','Public/Get-SqlServerLabEvaluationRefreshPlan.ps1','Public/Get-SqlServerLabEvaluationWatch.ps1','Public/Invoke-SqlServerLabWorkflowAction.ps1')){Import-RefreshFunctions $source}
    $script:VersionCatalog=Get-Content (Join-Path $repo Catalogs/sql-server-versions.json) -Raw|ConvertFrom-Json
    $script:SchemasPath=Join-Path $repo Schemas
    foreach($forbidden in @('Get-LabStateRoot','Get-LabStorageConfiguration','Get-LabSecret','Get-LabHostToolInvocation','Get-ContainerRuntime','Get-VM','Invoke-Sqlcmd','Get-LabDatabaseMigrationDependencyInventory','Invoke-LabArtifactStoreLock','New-SqlServerLab','Stop-SqlServerLab','Remove-SqlServerLab')){Set-Item ('Function:script:'+$forbidden) ([scriptblock]::Create("throw 'FORBIDDEN_REFRESH_BOUNDARY'"))}
    $runId=[guid]::NewGuid().ToString('D');$scope=[guid]::NewGuid().ToString('D');$controller=[guid]::NewGuid().ToString('D')
    $stateRoot=Join-Path $root State;$runDirectory=Join-Path $stateRoot ('runs/'+$runId)
    Write-Refresh (Join-Path $root '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='CANARY_PRIVATE_VOLUME';DataRoot=$root}
    Write-Refresh (Join-Path $root 'Catalog/storage-locations.json') @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=[guid]::NewGuid().ToString('D');ControllerId=$controller;VolumeId='CANARY_PRIVATE_VOLUME';LabDataRoot=$root})}
    $run=@{contractVersion='SqlServerLab.RunState/1.0';runId=$runId;scopeId=$scope;state='RUNNING';instances=@();stateHistory=@();errors=@();providerSubRuns=@(@{provider='hyperv';state='RUNNING';instanceIds=@('primary')});metadata=@{persistentData=$false;workflowKind='hyperv-lab';workload='sql';imageArtifactId='hyperv-sql-prepared-sealed-'+('a'*64);desiredState=@{Contract=@{Name='SqlServerLab.RunDesiredState';Version='1.0'};PersistentData=$false;ProvisioningMode='adhoc';Instances=@(@{Id='primary';Provider='hyperv';Version='2025'})}}}
    $runPath=Join-Path $runDirectory run-state.json;Write-Refresh $runPath $run
    Write-Refresh (Join-Path $stateRoot ('scope-markers/'+$scope+'.json')) @{runId=$runId;scopeId=$scope}
    $connection=@{schemaVersion=1;instances=@(@{id='primary';provider='hyperv';workload='sql';vmId=[guid]::NewGuid().ToString('D');vmName='CANARY_PRIVATE_VM';host='CANARY_PRIVATE_HOST';imageArtifactId=$run.metadata.imageArtifactId;sqlVersion='2025';sqlEdition='Evaluation';sqlReadiness=@{status='SQL_READY_RUN';instanceName='MSSQLSERVER';majorVersion=17;edition='Enterprise Evaluation Edition'};windowsActivation=@{state='EVALUATION_ACTIVE';edition='ServerStandardEval';evaluationExpiresAt=[datetime]::UtcNow.AddDays(3).ToString('o')}})}
    $connectionPath=Join-Path $runDirectory connection-info.json;Write-Refresh $connectionPath $connection
    $argsForPlan=@{RunId=$runId;InstanceId='primary';DataRoot=$root;Mode='STATEFUL_MIGRATION'}
    $before=Get-RefreshHashes
    $missing=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
    Assert-Refresh ($missing.Evaluations[1].EvidenceStatus-ceq'EVIDENCE_MISSING') 'Actual guest reader reports missing SQL evidence without acquisition'
    Assert-Refresh ($missing.Evaluations[0].Status-ceq'CRITICAL'-and-not$missing.Evaluations[0].FreshLicenseProof) 'Stored Windows deadline uses Watch classification without fresh license claim'
    $evidence=@{Contract=@{Name='SqlServerLab.SqlGuestEvaluationEvidence';Version='1.0'};EvidenceId=[guid]::NewGuid().ToString('D');RunId=$runId;ScopeId=$scope;InstanceId='primary';Provider='hyperv';VmId=$connection.instances[0].vmId;ImageArtifactId=$run.metadata.imageArtifactId;SqlInstanceName='MSSQLSERVER';SqlMajorVersion=17;SqlEdition='Enterprise Evaluation Edition';ObservedAt=[datetime]::UtcNow.AddMinutes(-5).ToString('o');EvidenceFreshUntil=[datetime]::UtcNow.AddHours(12).ToString('o');LicenseClassification='EVALUATION';DeadlineSource='SQL_GUEST_OBSERVED';ObservationStatus='CAPTURED';EvaluationExpiresAt=[datetime]::UtcNow.AddDays(3).ToString('o');PreviousEvidenceId=$null}
    $evidencePath=Join-Path $runDirectory sql-guest-evaluation-evidence.json;Write-Refresh $evidencePath $evidence
    $before=Get-RefreshHashes
    foreach($mode in @('FREE_SLOT_REPLACEMENT','RECONSTRUCT_LAB','STATEFUL_MIGRATION')){
        $argsForPlan.Mode=$mode;$plan=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
        Assert-Refresh ($plan.Mode-ceq$mode-and$plan.Status-ceq'BLOCKED'-and$plan.Actions.Count-eq0-and-not$plan.ExecutionSupported-and-not$plan.MutationAllowed-and-not$plan.FullInstanceMigration-and$plan.EquivalenceStatus-ceq'NOT_VERIFIED') ('Actual public '+$mode+' is informational without execution/equivalence')
        Assert-Refresh ($plan.Evaluations[1].EvidenceStatus-ceq'CURRENT'-and$plan.Evaluations[1].Status-ceq'CRITICAL'-and$plan.SqlReadiness-ceq'NOT_CHECKED') ('Actual reader and Watch SQL classification compose for '+$mode)
        Assert-Refresh ($plan.NextSteps.Count-eq2-and$plan.Blockers.Count-ge2) ('Mode '+$mode+' provides fixed concrete gaps and next steps')
    }
    $json=$plan|ConvertTo-Json -Depth 20
    Assert-Refresh ($json-notmatch'CANARY_PRIVATE|vmId|vmName|MSSQLSERVER'-and-not$json.Contains($root)) 'Public projection excludes raw paths endpoints guest identifiers and errors'
    Assert-Refresh ((Get-RefreshHashes)-ceq$before) 'All registered source and receipt files remain byte identical'
    $evidence.EvidenceFreshUntil=[datetime]::UtcNow.AddMinutes(-1).ToString('o');Write-Refresh $evidencePath $evidence
    $stale=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
    Assert-Refresh ($stale.Evaluations[1].EvidenceStatus-ceq'EVIDENCE_STALE'-and$stale.Evaluations[1].Status-ceq'UNKNOWN'-and'SQL_EVALUATION_EVIDENCE_REQUIRED'-cin$stale.Blockers) 'Stale guest deadline never becomes current or unrestricted'
    $evidence.EvidenceFreshUntil=[datetime]::UtcNow.AddHours(12).ToString('o');$evidence.ScopeId=[guid]::NewGuid().ToString('D');Write-Refresh $evidencePath $evidence
    $invalid=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
    Assert-Refresh ($invalid.Evaluations[1].EvidenceStatus-ceq'EVIDENCE_INVALID') 'Real guest reader rejects mismatched scope evidence'
    $evidence.ScopeId=$scope;Write-Refresh $evidencePath $evidence
    function Assert-RefreshReject($name,[scriptblock]$invoke,$expected){$code=$null;try{& $invoke|Out-Null}catch{$code=$_.Exception.Message};Assert-Refresh ($code-ceq$expected) $name}
    $run.metadata.desiredState.ProvisioningMode='manifest'
    $run.metadata.Remove('persistentData')
    Write-Refresh $runPath $run
    try {
        $legacyBefore=Get-RefreshHashes
        $legacy=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
        Assert-Refresh ($legacy.Status -ceq 'BLOCKED' -and $legacy.TransferAuthority -ceq 'NONE' -and
            (Get-RefreshHashes) -ceq $legacyBefore) 'Native manifest-shaped Hyper-V metadata supports read-only evaluation without writing a missing run flag'
        Assert-RefreshReject 'General diagnostic binding still requires the runtime persistence flag' {
            Get-LabDiagnosticBinding -RunId $runId -InstanceId primary -DataRoot $root
        } DIAGNOSTIC_DESIRED_BINDING_INVALID
        $connection.instances[0].persistentStorage=@{mode='cataloged-data-root-vhdx'}
        Write-Refresh $connectionPath $connection
        Assert-RefreshReject 'Omitted hypervisor persistence metadata never overrides a cataloged persistent attachment' {
            Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
        } EVALUATION_REFRESH_BINDING_INVALID
        $connection.instances[0].Remove('persistentStorage')
        Write-Refresh $connectionPath $connection
        $run.metadata.desiredState.PersistentData=$true
        Write-Refresh $runPath $run
        Assert-RefreshReject 'Legacy desired persistent runs still need the explicit registered data-root binding' {
            Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
        } EVALUATION_REFRESH_BINDING_UNAVAILABLE
        $run.metadata.desiredState.PersistentData=$false
        $run.metadata.persistentData=$null
        Write-Refresh $runPath $run
        Assert-RefreshReject 'Explicit null is invalid rather than an omitted legacy metadata field' {
            Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
        } EVALUATION_REFRESH_BINDING_UNAVAILABLE
    } finally {
        $connection.instances[0].Remove('persistentStorage')
        $run.metadata.persistentData=$false
        $run.metadata.desiredState.PersistentData=$false
        $run.metadata.desiredState.ProvisioningMode='adhoc'
        Write-Refresh $connectionPath $connection
        Write-Refresh $runPath $run
    }
    $markerPath=Join-Path $root '.sql-server-lab-root.json';$original=Get-Content $markerPath -Raw;$marker=$original|ConvertFrom-Json;$marker.ControllerId=[guid]::NewGuid().ToString('D');Write-Refresh $markerPath $marker
    Assert-RefreshReject 'Registered controller mismatch fails before acquisition' {Get-SqlServerLabEvaluationRefreshPlan @argsForPlan} EVALUATION_REFRESH_BINDING_UNAVAILABLE
    [IO.File]::WriteAllText($markerPath,$original,[Text.UTF8Encoding]::new($false))
    $run.metadata.desiredState.Instances+=@{Id='second';Provider='hyperv';Version='2025'};$run.providerSubRuns[0].instanceIds+= 'second';Write-Refresh $runPath $run
    Assert-RefreshReject 'Two intended instances reject instead of choosing one' {Get-SqlServerLabEvaluationRefreshPlan @argsForPlan} EVALUATION_REFRESH_SCOPE_UNSUPPORTED
    $run.metadata.desiredState.Instances=@($run.metadata.desiredState.Instances[0]);$run.providerSubRuns[0].instanceIds=@('primary');Write-Refresh $runPath $run
    $script:realSnapshot=${function:Read-LabEvaluationRefreshSnapshot};$script:readCount=0
    function Read-LabEvaluationRefreshSnapshot {param($RunId,$InstanceId,$DataRoot);$s=& $script:realSnapshot @PSBoundParameters;if(++$script:readCount-eq1){$script:run.state='STOPPED';Write-Refresh $script:runPath $script:run};$s}
    Assert-RefreshReject 'Changed second observation discards the plan' {Get-SqlServerLabEvaluationRefreshPlan @argsForPlan} EVALUATION_REFRESH_BINDING_CHANGED
    Set-Item Function:Read-LabEvaluationRefreshSnapshot $script:realSnapshot
    $run.state='RUNNING';Write-Refresh $runPath $run
    $run.metadata.desiredState.Instances[0].Provider='docker';$run.providerSubRuns[0].provider='docker';Write-Refresh $runPath $run
    Assert-RefreshReject 'Other registered providers are explicitly outside the guest-receipt slice' {Get-SqlServerLabEvaluationRefreshPlan @argsForPlan} EVALUATION_REFRESH_SCOPE_UNSUPPORTED
    $run.metadata.desiredState.Instances[0].Provider='hyperv';$run.providerSubRuns[0].provider='hyperv';Write-Refresh $runPath $run
    $savedInstance=$connection.instances[0].id;$connection.instances[0].id='foreign';Write-Refresh $connectionPath $connection
    Assert-RefreshReject 'Connection instance cannot replace selected desired identity' {Get-SqlServerLabEvaluationRefreshPlan @argsForPlan} EVALUATION_REFRESH_BINDING_INVALID
    $connection.instances[0].id=$savedInstance;Write-Refresh $connectionPath $connection
    $code=$null;try{Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -DependencyInventory @{FullInstanceMigration=$true}|Out-Null}catch{$code=$_.FullyQualifiedErrorId}
    Assert-Refresh ($code-like'NamedParameterNotFound*') 'Unbound caller inventory and asserted equivalence are not accepted inputs'
    $targetFixture=New-RefreshTargetFixture $root $run $connection
    $targetArguments=@{}+$argsForPlan
    $targetArguments.TargetRunId=$targetFixture.RunId
    $targetArguments.TargetInstanceId='primary'
    $beforeTarget=Get-RefreshHashes
    $pair=Get-SqlServerLabEvaluationRefreshPlan @targetArguments
    Assert-Refresh ($pair.TargetAssessment.Status -ceq 'METADATA_ONLY' -and $pair.TargetAssessment.RunId -ceq $targetFixture.RunId -and
        $pair.TargetAssessment.ScopeId -ceq $targetFixture.ScopeId -and $pair.TargetAssessment.RegisteredState -ceq 'STOPPED' -and
        $pair.TargetAssessment.ObservedContentSha256 -cne $pair.ObservedContentSha256 -and $pair.Actions.Count -eq 0 -and
        $pair.TransferAuthority -ceq 'NONE' -and $pair.Status -ceq 'BLOCKED' -and
        ($pair | ConvertTo-Json -Depth 12) -cnotmatch 'CANARY_PRIVATE|vmId|vmName') 'Distinct target binds two registered snapshots with no transfer authority'
    Assert-Refresh ((Get-RefreshHashes) -ceq $beforeTarget) 'Target preview leaves both registered fixtures untouched'
    Assert-RefreshReject 'A run cannot be its own target' { Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -TargetRunId $runId -TargetInstanceId primary } EVALUATION_REFRESH_TARGET_SELECTION_INVALID
    Assert-RefreshReject 'A partial target is rejected' { Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -TargetRunId $targetFixture.RunId } EVALUATION_REFRESH_TARGET_SELECTION_INVALID
    $targetArguments.Mode='RECONSTRUCT_LAB'
    Assert-RefreshReject 'Target is only supported in stateful migration' { Get-SqlServerLabEvaluationRefreshPlan @targetArguments } EVALUATION_REFRESH_TARGET_SELECTION_INVALID
    $targetArguments.Mode='STATEFUL_MIGRATION'
    $targetVm=$targetFixture.Connection.instances[0].vmId
    $targetFixture.Connection.instances[0].vmId=$connection.instances[0].vmId
    Write-Refresh $targetFixture.ConnectionFile $targetFixture.Connection
    Assert-RefreshReject 'A distinct run pointing at the same VM is rejected' { Get-SqlServerLabEvaluationRefreshPlan @targetArguments } EVALUATION_REFRESH_TARGET_SELECTION_INVALID
    $targetFixture.Connection.instances[0].vmId=$targetVm
    Write-Refresh $targetFixture.ConnectionFile $targetFixture.Connection
    $script:targetReads=0
    function Read-LabEvaluationRefreshSnapshot {
        param($RunId,$InstanceId,$DataRoot)
        $result=& $script:realSnapshot @PSBoundParameters
        if ($RunId -ceq $targetFixture.RunId -and ++$script:targetReads -eq 1) {
            $targetFixture.Connection.instances[0].vmName='CANARY_PRIVATE_TARGET_DRIFT'
            Write-Refresh $targetFixture.ConnectionFile $targetFixture.Connection
        }
        $result
    }
    Assert-RefreshReject 'A target changed after selection invalidates the pair' { Get-SqlServerLabEvaluationRefreshPlan @targetArguments } EVALUATION_REFRESH_BINDING_CHANGED
    Set-Item Function:Read-LabEvaluationRefreshSnapshot $script:realSnapshot
    $liveTarget=New-RefreshTargetFixture $root $run $connection RUNNING
    $before = Get-RefreshHashes
    $script:observationCalls = 0
    $script:contextReads = 0
    $script:injectInventoryDrift = $false
    $script:expectedSqlTarget = $null
    $script:expectStorage = $false
    $script:storageVolumes = @()
    $script:wrongSqlEdition = $false
    $script:guestCounts = [pscustomobject]@{
        UserDatabases=[long]3; NonOnlineUserDatabases=[long]1; EncryptedUserDatabases=[long]0; DatabaseSnapshots=[long]0
        FilestreamFileDatabases=[long]0; SsisCatalogCandidateDatabases=[long]0
        ServerPrincipals=[long]10; Credentials=[long]0; LinkedServers=[long]1; AgentJobs=[long]3; AgentProxies=[long]0
    }
    function Get-LabSqlGuestCaptureContext {
        param($RunId,$StateRoot)
        $script:contextReads++
        $observedRun = if ($script:expectedSqlTarget) { $script:expectedSqlTarget.Run } else { $run }
        $observedConnection = if ($script:expectedSqlTarget) { $script:expectedSqlTarget.Connection } else { $connection }
        if ($RunId -ne [guid]$observedRun.runId -or $StateRoot -cne $stateRoot) { throw 'SYNTHETIC_GUEST_TARGET_MISMATCH' }
        [pscustomobject]@{
            Run=[pscustomobject]$observedRun; Instance=($observedConnection.instances[0] | ConvertTo-Json -Depth 8 | ConvertFrom-Json)
            Fingerprint=if ($script:injectInventoryDrift -and $script:contextReads -gt 1) { 'changed' } else { 'known' }
        }
    }
    function Invoke-LabSqlGuestCaptureProbe {
        param($Context,$TimeoutSeconds,[switch]$IncludeSourceInventory,[switch]$IncludeTargetStorage)
        $script:observationCalls++
        if ($IncludeSourceInventory.IsPresent -eq [bool]$script:expectedSqlTarget -or $TimeoutSeconds -ne 60 -or
            $IncludeTargetStorage.IsPresent -ne $script:expectStorage) {
            throw 'SYNTHETIC_GUEST_REQUEST_MISMATCH'
        }
        [pscustomobject]@{
            MajorVersion=17; InstanceName='MSSQLSERVER'; SourceInventory=$script:guestCounts; Private='CANARY_PRIVATE_DO_NOT_RETURN'
            TargetStorage=if ($IncludeTargetStorage) { ,$script:storageVolumes } else { $null }
            Edition=if ($script:wrongSqlEdition) { 'Different edition' } else { 'Enterprise Evaluation Edition' }
        }
    }
    function Get-LabTimestamp { [datetime]::UtcNow.ToString('o') }
    $script:licenseCalls = 0
    $script:licenseMode = 'LICENSED'
    $script:expectedLiveTarget = $null
    $script:injectLicenseTargetDrift = $false
    function Get-HyperVWindowsSlotLicenseStatus {
        param($RunId,$StateRoot,$ExpectedVmId,$ExpectedScopeId,$ExpectedInstanceId,$TimeoutSeconds,[switch]$BoundReadOnly)
        $script:licenseCalls++
        $expectedRun = if ($script:expectedLiveTarget) { $script:expectedLiveTarget.RunId } else { $runId }
        $expectedScope = if ($script:expectedLiveTarget) { $script:expectedLiveTarget.ScopeId } else { $scope }
        $expectedVm = if ($script:expectedLiveTarget) { $script:expectedLiveTarget.Connection.instances[0].vmId } else { $connection.instances[0].vmId }
        if ($RunId -ne [guid]$expectedRun -or $StateRoot -cne $stateRoot -or $ExpectedVmId -ne [guid]$expectedVm -or
            $ExpectedScopeId -cne $expectedScope -or $ExpectedInstanceId -cne 'primary' -or $TimeoutSeconds -ne 30 -or
            -not $BoundReadOnly) { throw 'SYNTHETIC_LICENSE_REQUEST_MISMATCH' }
        if ($script:injectLicenseTargetDrift) {
            $changed = Get-Content -LiteralPath $script:expectedLiveTarget.ConnectionFile -Raw | ConvertFrom-Json -Depth 20
            $changed.instances[0].vmName = 'TARGET_DRIFT_CANARY'
            Write-Refresh $script:expectedLiveTarget.ConnectionFile $changed
        }
        if ($script:licenseMode -ceq 'DRIFT') { throw 'HYPERV_LAB_EXPECTED_VM_RUNTIME_MISMATCH' }
        $now = [datetime]::UtcNow
        [pscustomobject]@{
            RunId=if ($script:licenseMode -ceq 'FOREIGN') { [guid]::NewGuid() } else { $RunId }
            State=$script:licenseMode
            LicenseStatus=1
            ObservedAt=if ($script:licenseMode -ceq 'STALE') { $now.AddHours(-1).ToString('o') } else { $now.ToString('o') }
            EvaluationEndDate=if ($script:licenseMode -ceq 'EVALUATION_EXPIRED') { $now.AddDays(-2).ToString('o') }
            EvaluationExpiresAt=if ($script:licenseMode -ceq 'EVALUATION_ACTIVE') { $now.AddDays(2).ToString('o') }
            VMName='CANARY_PRIVATE_DO_NOT_RETURN'
        }
    }
    $hostPlatform = $IsWindows
    Set-Variable -Name IsWindows -Scope Script -Value $true -Force
    try {
        $ordinary = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
        Assert-Refresh ($script:observationCalls -eq 0 -and $script:licenseCalls -eq 0 -and
            -not $ordinary.PSObject.Properties['SqlSourceInventory'] -and -not $ordinary.PSObject.Properties['WindowsLicenseObservation']) 'Default migration preview still opens no connection'
        $licenseJobParams = @{ Action='ReadHyperVEvaluationWindowsLicense'; RunId=$runId; InstanceId='primary'; DataRoot=$root; ExpectedPlanKey='0' * 64 }
        Assert-RefreshReject 'Stale Windows license request cannot query a guest' { Invoke-SqlServerLabWorkflowAction @licenseJobParams } EVALUATION_REFRESH_BINDING_CHANGED
        Assert-Refresh ($script:licenseCalls -eq 0) 'Stale Windows license request invokes no probe'
        $licenseJobParams.ExpectedPlanKey = $ordinary.ObservedContentSha256
        $licenseJob = Invoke-SqlServerLabWorkflowAction @licenseJobParams
        Assert-Refresh ($script:licenseCalls -eq 1 -and $script:observationCalls -eq 0 -and
            $licenseJob.Result.Status -ceq 'OBSERVED' -and $licenseJob.Result.LicenseState -ceq 'LICENSED' -and
            $null -eq $licenseJob.Result.EvaluationExpiresAt -and
            ($licenseJob | ConvertTo-Json -Depth 8) -cnotmatch 'CANARY_PRIVATE|ScopeId|VMName') 'Explicit Windows job returns only bound live license fields'
        Assert-RefreshReject 'Target observation requires an explicit registered target' { Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveTargetWindowsLicense } EVALUATION_REFRESH_TARGET_SELECTION_INVALID
        $stoppedTarget=Get-SqlServerLabEvaluationRefreshPlan @targetArguments -ObserveTargetWindowsLicense
        Assert-Refresh ($script:licenseCalls -eq 1 -and $stoppedTarget.TargetAssessment.WindowsLicenseObservation.Status -ceq 'NOT_OBSERVED') 'Stopped target yields no guest probe or valid license'
        $liveArguments = @{}+$targetArguments
        $liveArguments.TargetRunId = $liveTarget.RunId
        $livePreview = Get-SqlServerLabEvaluationRefreshPlan @liveArguments
        $binding = @{}+$licenseJobParams
        $binding.TargetRunId = $liveTarget.RunId
        $binding.TargetInstanceId = 'primary'
        $binding.ExpectedTargetPlanKey = '0' * 64
        Assert-RefreshReject 'Stale live target digest fails before either guest is probed' { Invoke-SqlServerLabWorkflowAction @binding } EVALUATION_REFRESH_BINDING_CHANGED
        $binding.ExpectedTargetPlanKey = $livePreview.TargetAssessment.ObservedContentSha256
        Assert-Refresh ($script:licenseCalls -eq 1) 'Preview and invalid target do not invoke a Windows probe'
        $script:expectedLiveTarget = $liveTarget
        $targetJob = Invoke-SqlServerLabWorkflowAction @binding
        Assert-Refresh ($script:licenseCalls -eq 2 -and $targetJob.Result.TargetRunId -ceq $liveTarget.RunId -and
            $targetJob.Result.WindowsLicenseObservation.Status -ceq 'OBSERVED' -and
            ($targetJob | ConvertTo-Json -Depth 10) -cnotmatch 'CANARY_PRIVATE|ScopeId|VMName') 'Workflow queries just the bound target and logs only its safe identity and observation'
        $script:licenseMode = 'EVALUATION_EXPIRED'
        $expiredTarget = Get-SqlServerLabEvaluationRefreshPlan @liveArguments -ObserveTargetWindowsLicense
        Assert-Refresh ($expiredTarget.Status -ceq 'BLOCKED' -and $expiredTarget.TransferAuthority -ceq 'NONE' -and
            'TARGET_WINDOWS_EVALUATION_EXPIRED' -cin $expiredTarget.TargetAssessment.Checks -and
            $expiredTarget.SqlReadiness -ceq 'NOT_CHECKED' -and -not $expiredTarget.PSObject.Properties['WindowsLicenseObservation']) 'Expired target is shown independently of the source and cannot permit transfer'
        $savedTargetBytes = [IO.File]::ReadAllBytes($liveTarget.ConnectionFile)
        try {
            $script:injectLicenseTargetDrift = $true
            Assert-RefreshReject 'Target drift after the Windows read suppresses the result' { Invoke-SqlServerLabWorkflowAction @binding } EVALUATION_REFRESH_BINDING_CHANGED
        } finally {
            $script:injectLicenseTargetDrift = $false
            $script:expectedLiveTarget = $null
            [IO.File]::WriteAllBytes($liveTarget.ConnectionFile,$savedTargetBytes)
        }
        $script:licenseMode = 'EVALUATION_ACTIVE'
        $active = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveWindowsLicense
        Assert-Refresh ($active.WindowsLicenseObservation.Status -ceq 'OBSERVED' -and $active.WindowsLicenseObservation.EvaluationExpiresAt -and
            $active.Evaluations[0].EvidenceStatus -ceq 'HISTORICAL_METADATA' -and $active.TransferAuthority -ceq 'NONE') 'Live Windows expiry remains distinct from saved metadata and grants no transfer authority'
        $script:licenseMode = 'EVALUATION_EXPIRED'
        $expired = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveWindowsLicense
        Assert-Refresh ($expired.WindowsLicenseObservation.LicenseState -ceq 'EVALUATION_EXPIRED' -and
            'WINDOWS_EVALUATION_EXPIRED' -cin $expired.Blockers -and $expired.Status -ceq 'BLOCKED') 'An expired live Windows license blocks the plan even when historical metadata is active'
        foreach ($mode in @('STALE','FOREIGN','ACTIVATION_REQUIRED')) {
            $script:licenseMode = $mode
            $unknown = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveWindowsLicense
            Assert-Refresh ($unknown.WindowsLicenseObservation.Status -ceq 'NOT_OBSERVED' -and
                'CURRENT_WINDOWS_LICENSE_PROOF_NOT_AVAILABLE' -cin $unknown.Blockers) ('Windows observation rejects '+$mode)
        }
        $script:licenseMode = 'DRIFT'
        Assert-RefreshReject 'Changed VM binding invalidates the Windows observation' { Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveWindowsLicense } EVALUATION_REFRESH_BINDING_CHANGED
        $observed = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveSqlSource
        Assert-Refresh ($script:observationCalls -eq 1 -and $observed.SqlSourceInventory.Status -ceq 'PARTIALLY_OBSERVED' -and
            $observed.SqlSourceInventory.Items.Count -eq 11 -and ($observed.SqlSourceInventory.Items | Where-Object Category -CEQ UserDatabases).Count -eq 3 -and
            ($observed.SqlSourceInventory.DependencyFindings.Code -join ',') -ceq
                'DATABASE_STATE_REVIEW_REQUIRED,LINKED_SERVER_REBIND_REQUIRED,SQL_AGENT_JOB_INVENTORY_REQUIRED' -and
            $observed.Status -ceq 'BLOCKED' -and 'FULL_INSTANCE_INVENTORY_NOT_AVAILABLE' -cin $observed.Blockers -and -not $observed.MutationAllowed -and
            ($observed | ConvertTo-Json -Depth 10) -cnotmatch 'CANARY_PRIVATE|MSSQLSERVER') 'Opt-in reads aggregate SQL counts without raising transfer authority'
        $jobParams = @{ Action='ReadHyperVEvaluationSqlSource'; RunId=$runId; InstanceId='primary'; DataRoot=$root; ExpectedPlanKey=$ordinary.ObservedContentSha256 }
        Assert-RefreshReject 'Browser job cannot replace the selected digest before guest access' {
            $staleJob = @{} + $jobParams
            $staleJob.ExpectedPlanKey = '0' * 64
            Invoke-SqlServerLabWorkflowAction @staleJob
        } EVALUATION_REFRESH_BINDING_CHANGED
        Assert-Refresh ($script:observationCalls -eq 1) 'Stale interactive request opens no guest connection'
        $job = Invoke-SqlServerLabWorkflowAction @jobParams
        Assert-Refresh ($script:observationCalls -eq 2 -and $job.Result.Status -ceq 'PARTIALLY_OBSERVED' -and $job.Result.DependencyFindings.Count -eq 3 -and
            ($job | ConvertTo-Json -Depth 10) -cnotmatch 'CANARY_PRIVATE|MSSQLSERVER|ScopeId') 'The browser job returns only the aggregate source result'
        $script:guestCounts.AgentJobs = [long]-1
        $invalidInventory = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveSqlSource
        Assert-Refresh ($invalidInventory.SqlSourceInventory.Status -ceq 'NOT_OBSERVED' -and $invalidInventory.SqlSourceInventory.Items.Count -eq 0 -and
            $invalidInventory.SqlSourceInventory.DependencyFindings.Count -eq 0) 'Invalid guest counters do not become observed zero or report a dependency'
        $script:guestCounts.AgentJobs = [long]3
        foreach ($invalidCount in @(@{Category='FilestreamFileDatabases';Value=[long]4}, @{Category='SsisCatalogCandidateDatabases';Value=[long]2})) {
            $script:guestCounts.($invalidCount.Category) = $invalidCount.Value
            $invalidFeature = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveSqlSource
            Assert-Refresh ($invalidFeature.SqlSourceInventory.Status -ceq 'NOT_OBSERVED' -and
                $invalidFeature.SqlSourceInventory.DependencyFindings.Count -eq 0) ('Out-of-range feature evidence is unavailable: '+$invalidCount.Category)
            $script:guestCounts.($invalidCount.Category) = [long]0
        }
        $script:guestCounts.EncryptedUserDatabases = [long]1
        $script:guestCounts.DatabaseSnapshots = [long]1
        $script:guestCounts.FilestreamFileDatabases = [long]2
        $script:guestCounts.SsisCatalogCandidateDatabases = [long]1
        $script:guestCounts.Credentials = [long]2
        $script:guestCounts.AgentProxies = [long]1
        $blocked = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveSqlSource
        Assert-Refresh ($blocked.SqlSourceInventory.DependencyFindings.Count -eq 9 -and
            'TDE_KEY_TRANSFER_REQUIRED' -cin $blocked.SqlSourceInventory.DependencyFindings.Code -and
            'DATABASE_SNAPSHOT_DISPOSITION_REQUIRED' -cin $blocked.SqlSourceInventory.DependencyFindings.Code -and
            'CREDENTIAL_REBIND_REQUIRED' -cin $blocked.SqlSourceInventory.DependencyFindings.Code -and
            'SQL_AGENT_PROXY_REBIND_REQUIRED' -cin $blocked.SqlSourceInventory.DependencyFindings.Code -and
            $blocked.TransferAuthority -ceq 'NONE') 'Observed dependencies get actionable fixed codes without transfer authority'
        $filestream = $blocked.SqlSourceInventory.DependencyFindings | Where-Object Category -CEQ 'FilestreamFileDatabases'
        $ssis = $blocked.SqlSourceInventory.DependencyFindings | Where-Object Category -CEQ 'SsisCatalogCandidateDatabases'
        Assert-Refresh ($filestream.Count -eq 2 -and $filestream.Code -ceq 'FILESTREAM_STORAGE_REVIEW_REQUIRED' -and
            $ssis.Count -eq 1 -and $ssis.Code -ceq 'SSIS_CATALOG_REVIEW_REQUIRED' -and $blocked.Status -ceq 'BLOCKED') 'Database feature candidates produce bounded review findings'
        foreach ($property in $script:guestCounts.PSObject.Properties) { $property.Value = [long]0 }
        $empty = Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveSqlSource
        Assert-Refresh ($empty.SqlSourceInventory.Status -ceq 'PARTIALLY_OBSERVED' -and
            $empty.SqlSourceInventory.DependencyFindings.Count -eq 0 -and $empty.Status -ceq 'BLOCKED') 'Observed zeros produce no dependency findings and retain the blocked plan'
        $script:contextReads = 0
        $script:injectInventoryDrift = $true
        Assert-RefreshReject 'Changed live source binding invalidates the inventory preview' { Get-SqlServerLabEvaluationRefreshPlan @argsForPlan -ObserveSqlSource } EVALUATION_REFRESH_BINDING_CHANGED
        Assert-RefreshReject 'Only stateful migration accepts a live SQL source selection' {
            Get-SqlServerLabEvaluationRefreshPlan -RunId $runId -InstanceId primary -DataRoot $root -Mode RECONSTRUCT_LAB -ObserveSqlSource
        } EVALUATION_REFRESH_SQL_SOURCE_MODE_INVALID
        $script:injectInventoryDrift = $false
        $script:expectedSqlTarget = $liveTarget
        $targetRequest = @{}+$binding
        $targetRequest.Action = 'ReadHyperVEvaluationTargetSqlReadiness'
        $priorCalls = $script:observationCalls
        $targetSqlPlan = Get-SqlServerLabEvaluationRefreshPlan @liveArguments -ObserveTargetSqlReadiness
        Assert-Refresh ($script:observationCalls -eq $priorCalls+1 -and $targetSqlPlan.Status -ceq 'BLOCKED' -and
            $targetSqlPlan.TargetAssessment.SqlReadinessObservation.Status -ceq 'OBSERVED' -and
            'TARGET_SQL_READINESS_OBSERVED' -cin $targetSqlPlan.TargetAssessment.Checks -and
            $targetSqlPlan.SqlReadiness -ceq 'NOT_CHECKED' -and $targetSqlPlan.TransferAuthority -ceq 'NONE') 'Only readiness of the bound target is observed'
        $targetSql = Invoke-SqlServerLabWorkflowAction @targetRequest
        Assert-Refresh ($targetSql.Result.TargetRunId -ceq $liveTarget.RunId -and $targetSql.Result.TargetInstanceId -ceq 'primary' -and
            $targetSql.Result.SqlReadinessObservation.ObservedAt -and ($targetSql | ConvertTo-Json -Depth 8) -cnotmatch
            'CANARY_PRIVATE|ScopeId|Edition|SourceInventory') 'Workflow returns only safe target identity and current readiness'
        $staleTarget = @{}+$targetRequest; $staleTarget.ExpectedTargetPlanKey = '0' * 64
        Assert-RefreshReject 'Target SQL readiness rejects stale digest before guest access' { Invoke-SqlServerLabWorkflowAction @staleTarget } EVALUATION_REFRESH_BINDING_CHANGED
        $unboundTarget = @{}+$targetRequest; $unboundTarget.Remove('ExpectedTargetPlanKey')
        Assert-RefreshReject 'Target SQL readiness requires both digests' { Invoke-SqlServerLabWorkflowAction @unboundTarget } EVALUATION_REFRESH_INPUT_INVALID
        $stoppedSql = Get-SqlServerLabEvaluationRefreshPlan @targetArguments -ObserveTargetSqlReadiness
        Assert-Refresh ($script:observationCalls -eq $priorCalls+2 -and $stoppedSql.TargetAssessment.SqlReadinessObservation.Status -ceq 'NOT_OBSERVED') 'Stopped target opens no SQL session'
        $script:wrongSqlEdition = $true
        $wrongSql = Invoke-SqlServerLabWorkflowAction @targetRequest
        Assert-Refresh ($wrongSql.Result.SqlReadinessObservation.Status -ceq 'NOT_OBSERVED' -and
            $null -eq $wrongSql.Result.SqlReadinessObservation.ObservedAt) 'A different live SQL edition cannot prove readiness'
        $script:wrongSqlEdition = $false
        $script:contextReads = 0
        $script:injectInventoryDrift = $true
        Assert-RefreshReject 'Target runtime drift discards SQL readiness' { Invoke-SqlServerLabWorkflowAction @targetRequest } EVALUATION_REFRESH_BINDING_CHANGED
        $script:injectInventoryDrift = $false
        $script:expectStorage = $true
        $storageCallCount = $script:observationCalls
        $storageRequest = @{}+$targetRequest
        $storageRequest.Action = 'ReadHyperVEvaluationTargetStorage'
        $wireVolumes = [Management.Automation.PSSerializer]::Serialize(@(
            [pscustomobject]@{Roles=@('Data','Log');AvailableBytes=[long]30GB},
            [pscustomobject]@{Roles=@('Backup');AvailableBytes=[long]90GB}
        ), 5)
        $script:storageVolumes = [Management.Automation.PSSerializer]::Deserialize($wireVolumes)
        $storagePlan = Get-SqlServerLabEvaluationRefreshPlan @liveArguments -ObserveTargetStorage
        Assert-Refresh ($storagePlan.Status -ceq 'BLOCKED' -and $storagePlan.TransferAuthority -ceq 'NONE' -and
            -not $storagePlan.MutationAllowed -and $storagePlan.TargetAssessment.StorageObservation.Status -ceq 'OBSERVED' -and
            $storagePlan.TargetAssessment.StorageObservation.Volumes.Count -eq 2 -and
            'TARGET_STORAGE_AND_TRANSFER_NOT_VERIFIED' -cin $storagePlan.TargetAssessment.Checks -and
            ($storagePlan.TargetAssessment.StorageObservation.Volumes[0].Roles -join ',') -ceq 'Data,Log') 'Shared volumes are grouped after real remoting serialization without transfer authority'
        $storageJob = Invoke-SqlServerLabWorkflowAction @storageRequest
        Assert-Refresh ($storageJob.Result.TargetRunId -ceq $liveTarget.RunId -and
            $storageJob.Result.StorageObservation.Volumes[1].AvailableBytes -eq 90GB -and
            ($storageJob | ConvertTo-Json -Depth 10) -cnotmatch 'CANARY_PRIVATE|ScopeId|Edition|SourceInventory|UniqueId') 'Target storage job exposes only the selected identity, roles and bytes'
        $staleStorage = @{}+$storageRequest; $staleStorage.ExpectedTargetPlanKey = '0' * 64
        Assert-RefreshReject 'Target storage rejects stale digest before guest access' { Invoke-SqlServerLabWorkflowAction @staleStorage } EVALUATION_REFRESH_BINDING_CHANGED
        $unboundStorage = @{}+$storageRequest; $unboundStorage.Remove('ExpectedTargetPlanKey')
        Assert-RefreshReject 'Target storage requires both digests' { Invoke-SqlServerLabWorkflowAction @unboundStorage } EVALUATION_REFRESH_INPUT_INVALID
        $stoppedStorage = Get-SqlServerLabEvaluationRefreshPlan @targetArguments -ObserveTargetStorage
        Assert-Refresh ($script:observationCalls -eq $storageCallCount+2 -and $stoppedStorage.TargetAssessment.StorageObservation.Status -ceq 'NOT_OBSERVED') 'Stopped target opens no storage probe'
        foreach ($invalidVolume in @(
            [pscustomobject]@{Roles=@('Data','Log','Log');AvailableBytes=[long]0},
            [pscustomobject]@{Roles=@('Data','Log','Backup');AvailableBytes=[long]-1},
            [pscustomobject]@{Roles=@('Data','Log','Backup');AvailableBytes=[long]0;Path='CANARY_PRIVATE'}
        )) {
            $script:storageVolumes = @($invalidVolume)
            $unknownStorage = Invoke-SqlServerLabWorkflowAction @storageRequest
            Assert-Refresh ($unknownStorage.Result.StorageObservation.Status -ceq 'NOT_OBSERVED' -and
                $unknownStorage.Result.StorageObservation.Volumes.Count -eq 0) 'Invalid or extra volume data is rejected completely'
        }
        $script:storageVolumes = @([pscustomobject]@{Roles=@('Data','Log','Backup');AvailableBytes=[long]0})
        $explicitZero = Invoke-SqlServerLabWorkflowAction @storageRequest
        Assert-Refresh ($explicitZero.Result.StorageObservation.Status -ceq 'OBSERVED' -and
            $explicitZero.Result.StorageObservation.Volumes[0].AvailableBytes -eq 0) 'Observed zero remains distinct from unavailable storage'
        $script:contextReads = 0
        $script:injectInventoryDrift = $true
        Assert-RefreshReject 'Target runtime drift discards storage observation' { Invoke-SqlServerLabWorkflowAction @storageRequest } EVALUATION_REFRESH_BINDING_CHANGED
        Assert-Refresh ((Get-RefreshHashes)-ceq$before) 'Live SQL observations leave all artifacts unchanged'
    }
    finally { Set-Variable -Name IsWindows -Scope Script -Value $hostPlatform -Force }
    # Actual existing Watch path, bounded inventory leaves contain only the fixture.
    function Get-SqlServerLabHyperVImageArtifact {param($MinimumEvaluationDaysRemaining,$StateRoot);[pscustomobject]@{ArtifactId=$run.metadata.imageArtifactId;ArtifactState='SQL_PREPARED_SEALED';Evaluation=[pscustomobject]@{LicenseType='evaluation';ExpiresAt=$connection.instances[0].windowsActivation.evaluationExpiresAt};Sql=[pscustomobject]@{Evaluation=[pscustomobject]@{LicenseType='';ExpiresAt=$null}}}}
    function Get-LabActiveRuns {param($StateRoot);$run}
    foreach($days in @(-1,2,7.1,20,30.1,90)){
        $connection.instances[0].windowsActivation.evaluationExpiresAt=[datetime]::UtcNow.AddDays($days).ToString('o');Write-Refresh $connectionPath $connection
        $watch=Get-SqlServerLabEvaluationWatch -StateRoot $stateRoot
        $plan=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
        $row=@($watch.InstanceItems|Where-Object Component -CEQ Windows)[0]
        Assert-Refresh ($row.Status-ceq$plan.Evaluations[0].Status-and$row.EvaluationExpiresAt-ceq$plan.Evaluations[0].EvaluationExpiresAt-and$row.DaysRemaining-eq$plan.Evaluations[0].DaysRemaining) ('Actual Watch and public plan instant/status/days equivalence at '+$days+' days')
    }
    $connection.instances[0].windowsActivation.evaluationExpiresAt=[datetimeoffset]::UtcNow.AddDays(3).ToOffset([timespan]::FromHours(3)).ToString('o');Write-Refresh $connectionPath $connection
    $watch=Get-SqlServerLabEvaluationWatch -StateRoot $stateRoot;$plan=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
    $row=@($watch.InstanceItems|Where-Object Component -CEQ Windows)[0]
    $expected=[datetimeoffset]::Parse($connection.instances[0].windowsActivation.evaluationExpiresAt).UtcDateTime.ToString('o')
    Assert-Refresh ($row.EvaluationExpiresAt-ceq$expected-and$plan.Evaluations[0].EvaluationExpiresAt-ceq$expected) 'Actual offset JSON roundtrip preserves UTC instant and fractional ticks'
    $again=Get-SqlServerLabEvaluationWatch -StateRoot $stateRoot
    Assert-Refresh ((@($again.InstanceItems|Where-Object Component -CEQ Windows)[0]).EventId-ceq$row.EventId) 'Canonical corrected Watch event fingerprint is stable for unchanged bytes'
    $connection.instances[0].windowsActivation.evaluationExpiresAt='invalid';Write-Refresh $connectionPath $connection
    $watch=Get-SqlServerLabEvaluationWatch -StateRoot $stateRoot;$plan=Get-SqlServerLabEvaluationRefreshPlan @argsForPlan
    Assert-Refresh ((@($watch.InstanceItems|Where-Object Component -CEQ Windows)[0]).Status-ceq'UNKNOWN'-and$plan.Evaluations[0].Status-ceq'UNKNOWN'-and$null-eq$plan.Evaluations[0].DaysRemaining) 'Invalid Windows deadline remains unknown without license uplift'
    $fixedNow=[datetime]::SpecifyKind([datetime]'2030-01-01',[DateTimeKind]::Utc)
    foreach($case in @(@{Days=0;Expected='EXPIRED'},@{Days=7;Expected='CRITICAL'},@{Days=30;Expected='WARNING'},@{Days=31;Expected='OK'})){
        Assert-Refresh ((Get-LabEvaluationDeadlineStatus -ExpiresAt $fixedNow.AddDays($case.Days) -Now $fixedNow -WarningDaysRemaining 30 -CriticalDaysRemaining 7)-ceq$case.Expected) ('Shared classifier exact '+$case.Days+' day boundary')
    }
    Write-Host ('EVALUATION_REFRESH_PLAN_CHECKS: '+$checks+' PASS; 0 FAIL')
} finally {
    $resolved=[IO.Path]::GetFullPath($root);$expected=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/evaluation-refresh-fixtures'))
    if($resolved.StartsWith($expected+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)-and[IO.Path]::GetFileName($resolved)-match'^[a-f0-9]{32}$'){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
}
