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
try {
    foreach($source in @('Private/DiagnosticBundleReader.ps1','Private/SqlGuestEvaluationEvidence.ps1','Private/EvaluationRefreshPlan.ps1','Private/VersionCatalog.ps1','Private/PathSafety.ps1','Public/Get-SqlServerLabEvaluationRefreshPlan.ps1','Public/Get-SqlServerLabEvaluationWatch.ps1')){Import-RefreshFunctions $source}
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
    $connection=@{schemaVersion=1;instances=@(@{id='primary';provider='hyperv';workload='sql';vmId=[guid]::NewGuid().ToString('D');vmName='CANARY_PRIVATE_VM';host='CANARY_PRIVATE_HOST';imageArtifactId=$run.metadata.imageArtifactId;sqlEdition='Evaluation';sqlReadiness=@{status='SQL_READY_RUN';instanceName='MSSQLSERVER';majorVersion=17;edition='Enterprise Evaluation Edition'};windowsActivation=@{state='EVALUATION_ACTIVE';edition='ServerStandardEval';evaluationExpiresAt=[datetime]::UtcNow.AddDays(3).ToString('o')}})}
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
