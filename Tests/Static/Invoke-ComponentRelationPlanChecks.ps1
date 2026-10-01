#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-component-check-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo SqlServerLab.psd1) -Force -PassThru -WarningAction SilentlyContinue
try {
    & $module {
        param($Root)
        $script:checks=0
        function Assert-Component($condition,$name) {if(-not$condition){throw ('COMPONENT_CHECK_FAILED: '+$name)};$script:checks++;Write-Host ('PASS: '+$name)}
        function Write-ComponentJson($path,$value) {$null=New-Item -ItemType Directory (Split-Path $path) -Force;$value|ConvertTo-Json -Depth 64|Set-Content -LiteralPath $path -Encoding utf8}
        function Get-ComponentFiles {(@(Get-ChildItem $Root -Recurse -File|Sort-Object FullName|ForEach-Object {$_.FullName+':'+(Get-FileHash $_.FullName).Hash})-join'|')}
        function New-ComponentRun($dataRoot,$instances) {
            $desired=New-LabDesiredStateSnapshot -ResolvedLab ([pscustomobject]@{name='Synthetic SQL dependency';instances=$instances}) -ProvisioningMode adhoc -PersistentData $false
            $sub=@($instances|Group-Object provider|ForEach-Object {[pscustomobject]@{provider=$_.Name;instanceIds=@($_.Group.id)}})
            $run=New-LabRunState -StateRoot (Join-Path $dataRoot State) -Metadata @{desiredState=$desired;persistentData=$false} -ProviderSubRuns $sub
            $rows=@($instances|ForEach-Object {[pscustomobject]@{id=$_.id;provider=$_.provider;containerId=if($_.provider-ceq'docker'){'a'*64}else{'b'*64};containerName='CANARY_PRIVATE_NATIVE';host='127.0.0.1';port=14330}})
            Write-ComponentJson (Join-Path $run.RunDir connection-info.json) @{instances=$rows}
            $run
        }
        $dataRoot=Join-Path $Root data;$controller=[guid]::NewGuid().ToString('D');$location=[guid]::NewGuid().ToString('D')
        Write-ComponentJson (Join-Path $dataRoot '.sql-server-lab-root.json') @{ContractVersion='SqlServerLab.DataRoot/2.0';ManagedBy='SQL_Server_Lab';ControllerId=$controller;VolumeId='CANARY_PRIVATE_VOLUME';DataRoot=$dataRoot}
        Write-ComponentJson (Join-Path $dataRoot 'Catalog/storage-locations.json') @{ContractVersion='SqlServerLab.Storage/2.0';ControllerId=$controller;LabDataLocations=@(@{LocationId=$location;ControllerId=$controller;LabDataRoot=$dataRoot;VolumeId='CANARY_PRIVATE_VOLUME'})}
        $instances=@([pscustomobject]@{id='consumer';provider='docker';version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()},[pscustomobject]@{id='prerequisite';provider='podman';version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()})
        $own=New-ComponentRun $dataRoot $instances
        $shared=New-ComponentRun $dataRoot @([pscustomobject]@{id='sharedSql';provider='docker';version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()})
        $relation=[pscustomobject]@{SourceInstanceId='consumer';Type='requires-sql';Target=[pscustomobject]@{RunId=$own.RunId;ScopeId=$own.ScopeId;InstanceId='prerequisite';ManagementMode='PROVISIONED'}}
        $sharedRelation=[pscustomobject]@{SourceInstanceId='prerequisite';Type='requires-sql';Target=[pscustomobject]@{RunId=$shared.RunId;ScopeId=$shared.ScopeId;InstanceId='sharedSql';ManagementMode='EXTERNAL_READ_ONLY'}}
        # Every prohibited dependency throws if the actual new route reaches it.
        function Get-ContainerRuntime {throw 'FORBIDDEN_RUNTIME_CALL'}
        function Get-LabHostToolInvocation {throw 'FORBIDDEN_HOSTTOOL_CALL'}
        function Sync-LabRunRuntimeState {throw 'FORBIDDEN_RUNTIME_CALL'}
        function New-LabActualState {throw 'FORBIDDEN_ACTUAL_RUNTIME_CALL'}
        function Get-LabSecret {throw 'FORBIDDEN_SECRET_CALL'}
        function Wait-SqlReady {throw 'FORBIDDEN_SQL_CALL'}
        $before=Get-ComponentFiles
        $plan=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations @($relation,$sharedRelation)
        Assert-Component (($plan.PrerequisiteOrder.InstanceId-join',')-ceq'sharedSql,prerequisite,consumer') 'Actual plan orders prerequisites including exact shared SQL reference'
        Assert-Component ($plan.Contract.Version-ceq'1.2'-and$plan.Mode-ceq'COMPONENT_RELATIONS_PLAN_ONLY'-and-not$plan.MutationAllowed-and-not$plan.ExecutionSupported-and$plan.Actions.Count-eq0) 'Plan version and mode convey no execution authority'
        Assert-Component ($plan.SqlPurposeClass-ceq'INTEGRATION_SCENARIO') 'SQL purpose is fixed instead of reflecting caller text'
        Assert-Component ($plan.Status-ceq'BLOCKED_SQL_READINESS_NOT_CHECKED'-and$plan.Actual.SqlReadiness-ceq'NOT_CHECKED') 'Persisted state cannot become SQL readiness'
        Assert-Component ($plan.SharedRemovalPolicy-ceq'PRESERVE'-and@($plan.Actual.Components|Where-Object ManagementMode -CEQ EXTERNAL_READ_ONLY).Count-eq1) 'Shared consumer reference never adopts ownership'
        $json=$plan|ConvertTo-Json -Depth 20
        Assert-Component ($json-notmatch'CANARY_PRIVATE|containerId|containerName|127\.0\.0\.1|14330'-and-not$json.Contains($Root)) 'Actual DTO excludes private root native and endpoint values'
        $reordered=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations @($sharedRelation,$relation)
        Assert-Component ($reordered.ObservedContentSha256-ceq$plan.ObservedContentSha256) 'Observed plan input digest is deterministic for relation permutation'
        Assert-Component ($before-ceq(Get-ComponentFiles)) 'All owned and shared registered files remain byte identical'
        function Test-ComponentReject($name,$relations,$expected) {$code=$null;try{$null=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations $relations}catch{$code=$_.Exception.Message};Assert-Component ($code-ceq$expected) $name}
        function Copy-Component($value){$value|ConvertTo-Json -Depth 15|ConvertFrom-Json -Depth 15}
        $bad=Copy-Component $relation;$bad.SourceInstanceId='unregistered'
        Test-ComponentReject 'Unknown consumer fails before dispatch' @($bad) COMPONENT_RELATION_TARGET_INVALID
        Test-ComponentReject 'Duplicate relation rejects' @($relation,$relation) COMPONENT_RELATION_TARGET_INVALID
        $bad=Copy-Component $relation;$bad.Target.InstanceId='consumer'
        Test-ComponentReject 'Self dependency rejects' @($bad) COMPONENT_RELATION_TARGET_INVALID
        $bad=Copy-Component $relation;$bad.SourceInstanceId='prerequisite';$bad.Target.InstanceId='consumer'
        Test-ComponentReject 'Actual two-node cycle rejects' @($relation,$bad) COMPONENT_RELATION_CYCLE
        $bad=Copy-Component $sharedRelation;$bad.Target.ScopeId=[guid]::NewGuid().ToString('D')
        Test-ComponentReject 'Shared scope drift rejects' @($bad) COMPONENT_RELATION_TARGET_INVALID
        $bad=Copy-Component $sharedRelation;$bad.Target.ManagementMode='EXTERNAL_MUTABLE'
        Test-ComponentReject 'External mutable adoption rejects' @($bad) COMPONENT_RELATION_TARGET_INVALID
        $bad=Copy-Component $relation;$bad|Add-Member StateRoot 'CANARY_PRIVATE'
        Test-ComponentReject 'Unrecognized relation fields reject' @($bad) COMPONENT_RELATION_INPUT_INVALID
        $bad=Copy-Component $relation;$bad|Add-Member SqlPurpose 'CANARY_PRIVATE_SECRET_OR_HOST'
        Test-ComponentReject 'Free SQL purpose text cannot enter plan DTO' @($bad) COMPONENT_RELATION_INPUT_INVALID
        Test-ComponentReject 'Five relations exceed the bounded input contract' @($relation,$relation,$relation,$relation,$relation) COMPONENT_RELATION_COUNT_LIMIT
        $empty=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations @()
        Assert-Component ($empty.IsNoOp-and$empty.Status-ceq'NO_RELATION_CHANGE'-and$empty.Actions.Count-eq0) 'Legacy relation absence yields plan-only no change without adoption'
        $code=$null;try{$null=Invoke-SqlServerLabReconcileAction -RunId $own.RunId -ProposedRelations @($relation) -StateRoot $own.StateRoot}catch{$code=$_.Exception.Message}
        Assert-Component ($code-ceq'RECONCILE_PLAN_NOT_EXECUTABLE') 'Actual action proposed-relations parameter set rejects before observation'
        $code=$null;try{$null=$plan|Invoke-SqlServerLabReconcileAction -TargetState RUNNING -StateRoot $own.StateRoot}catch{$code=$_.Exception.Message}
        Assert-Component ($code-ceq'RECONCILE_PLAN_NOT_EXECUTABLE') 'Actual pipeline plan contract and mode cannot execute lifecycle'
        $withoutMode=$plan|Select-Object * -ExcludeProperty Mode
        $code=$null;try{$null=$withoutMode|Invoke-SqlServerLabReconcileAction -TargetState RUNNING -StateRoot $own.StateRoot}catch{$code=$_.Exception.Message}
        Assert-Component ($code-ceq'RECONCILE_PLAN_NOT_EXECUTABLE') 'Plan version alone rejects when caller strips plan-only mode'
        $statePath=Join-Path $own.RunDir run-state.json;$original=Get-Content $statePath -Raw
        $state=$original|ConvertFrom-Json -Depth 64;$state.state='RUNNING';Write-ComponentJson $statePath $state
        $running=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations @($relation)
        Assert-Component ($running.Status-ceq'BLOCKED_SQL_READINESS_NOT_CHECKED'-and$running.Actual.SqlReadiness-ceq'NOT_CHECKED') 'RUNNING lifecycle observation never promotes SQL readiness'
        $state.state='RECOVERY_REQUIRED';Write-ComponentJson $statePath $state
        $failed=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations @($relation)
        Assert-Component ($failed.Status-ceq'BLOCKED_COMPONENT_RECOVERY_REQUIRED'-and-not$failed.ExecutionSupported) 'Partial recovery component blocks aggregate plan without dispatch'
        $state.state='RUNNING';$state.providerSubRuns[0].state='RECOVERY_REQUIRED';Write-ComponentJson $statePath $state
        $failed=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot $own.StateRoot -ProposedRelations @($relation)
        Assert-Component ($failed.Status-ceq'BLOCKED_COMPONENT_RECOVERY_REQUIRED') 'Provider subrun recovery blocks even when parent state is RUNNING'
        [IO.File]::WriteAllText($statePath,$original,[Text.UTF8Encoding]::new($false))
        $before=Get-ComponentFiles
        $script:realBinding=${function:Read-LabComponentRelationBinding};$script:bindingReads=0
        function Read-LabComponentRelationBinding {param($RunId,$StateRoot);$b=& $script:realBinding @PSBoundParameters;if(++$script:bindingReads-eq2){$b.Digest='f'*64};$b}
        Test-ComponentReject 'Fresh second source observation detects changed content' @($relation) COMPONENT_RELATION_BINDING_CHANGED
        Set-Item Function:Read-LabComponentRelationBinding $script:realBinding
        $script:bindingReads=0
        function Read-LabComponentRelationBinding {param($RunId,$StateRoot);$b=& $script:realBinding @PSBoundParameters;if(++$script:bindingReads-eq4){$b.Digest='f'*64};$b}
        Test-ComponentReject 'Fresh second shared observation detects replacement' @($relation,$sharedRelation) COMPONENT_RELATION_BINDING_CHANGED
        Set-Item Function:Read-LabComponentRelationBinding $script:realBinding
        $connectionPath=Join-Path $own.RunDir connection-info.json;$connectionOriginal=Get-Content $connectionPath -Raw
        $connection=$connectionOriginal|ConvertFrom-Json -Depth 20;$connection.instances[0].provider='podman';Write-ComponentJson $connectionPath $connection
        Test-ComponentReject 'Actual connection provider mismatch blocks relation composition' @($relation) COMPONENT_RELATION_CONNECTION_INVALID
        [IO.File]::WriteAllText($connectionPath,$connectionOriginal,[Text.UTF8Encoding]::new($false))
        $before=Get-ComponentFiles
        $code=$null;try{$null=Get-SqlServerLabReconcilePlan -RunId $own.RunId -StateRoot (Join-Path $Root unregistered/State) -ProposedRelations @($relation)}catch{$code=$_.Exception.Message}
        Assert-Component ($code-ceq'COMPONENT_RELATION_BINDING_UNAVAILABLE') 'Unregistered missing root is not adopted or initialized'
        Assert-Component ($before-ceq(Get-ComponentFiles)) 'Negative paths preserve source and shared files without secret/runtime calls'
        $three=New-ComponentRun $dataRoot @($instances+[pscustomobject]@{id='third';provider='docker';version='2025';profile='standard';autostart='manual';drives=@();databases=@();software=@()})
        $code=$null;try{$null=Get-SqlServerLabReconcilePlan -RunId $three.RunId -StateRoot $three.StateRoot -ProposedRelations @()}catch{$code=$_.Exception.Message}
        Assert-Component ($code-ceq'COMPONENT_RELATION_SCOPE_UNSUPPORTED') 'More than two owned SQL targets reject even with empty relations'
        $another=New-ComponentRun $dataRoot @($instances[0])
        $bad=Copy-Component $sharedRelation;$bad.SourceInstanceId='consumer';$bad.Target.RunId=$another.RunId;$bad.Target.ScopeId=$another.ScopeId;$bad.Target.InstanceId='consumer'
        Test-ComponentReject 'Two distinct registered shared SQL references reject' @($sharedRelation,$bad) COMPONENT_RELATION_SCOPE_UNSUPPORTED
        $markerPath=Join-Path $dataRoot '.sql-server-lab-root.json';$markerOriginal=Get-Content $markerPath -Raw
        $marker=$markerOriginal|ConvertFrom-Json;$marker.ControllerId=[guid]::NewGuid().ToString('D');Write-ComponentJson $markerPath $marker
        Test-ComponentReject 'Actual registered controller mismatch fails closed without repair' @($relation) COMPONENT_RELATION_BINDING_UNAVAILABLE
        [IO.File]::WriteAllText($markerPath,$markerOriginal,[Text.UTF8Encoding]::new($false))
        # Execute the actual action routing with isolated plan/repair spies.
        # Existing ExternalRuntime 1.1 container and Hyper-V plans must remain valid.
        $script:realPlan=${function:Get-SqlServerLabReconcilePlan};$script:legacyProvider='docker';$script:legacyPlanCalls=0
        function Get-SqlServerLabReconcilePlan {param($RunId,$ManifestPath,$InstanceId,$StateRoot);$script:legacyPlanCalls++;[pscustomobject]@{Contract=[pscustomobject]@{Name='SqlServerLab.ReconcilePlan';Version='1.1'};RunId=$RunId;InstanceId=$InstanceId;Desired=[pscustomobject]@{Provider=$script:legacyProvider};Actions=@([pscustomobject]@{Operation='SyntheticExternalRuntime'});IsNoOp=$false;Warnings=@()}}
        function Invoke-LabExternalRuntimeReconcileRefresh {throw 'FORBIDDEN_LEGACY_REPAIR'}
        function Invoke-LabHyperVExternalRuntimeReconcileRepair {throw 'FORBIDDEN_LEGACY_REPAIR'}
        foreach($provider in @('docker','hyperv')){
            $script:legacyProvider=$provider
            $legacy=[pscustomobject]@{RunId=$own.RunId;Contract=[pscustomobject]@{Name='SqlServerLab.ReconcilePlan';Version='1.1'}}
            $result=Invoke-SqlServerLabReconcileAction -RunId $own.RunId -Contract $legacy.Contract -ManifestPath synthetic.json -InstanceId consumer -StateRoot $own.StateRoot -WhatIf
            Assert-Component ($result.ExecutionSummary.Status-ceq'WOULD_EXECUTE'-and$result.ExecutionSummary.ExecutedActions-eq0) ('Actual existing '+$provider+' ExternalRuntime 1.1 action route remains supported')
        }
        Assert-Component ($script:legacyPlanCalls-eq2) 'Both legacy routes reach their existing plan branch without provider execution'
        Set-Item Function:Get-SqlServerLabReconcilePlan $script:realPlan
        $script:realDiagnostic=${function:Get-LabDiagnosticBinding};$script:realPersisted=${function:Get-LabPersistedDesiredState}
        $script:threeDesired=(Get-LabRunState -RunId $three.RunId -StateRoot $three.StateRoot).metadata.desiredState
        function Get-LabDiagnosticBinding {param($RunId,$InstanceId,$DataRoot);$b=& $script:realDiagnostic @PSBoundParameters;$b.Run.metadata.desiredState=$script:threeDesired;$b}
        function Get-LabPersistedDesiredState {param($RunId,$StateRoot);[pscustomobject]@{Status='VALID';Snapshot=$script:threeDesired}}
        Test-ComponentReject 'Alternating initial two versus bound three snapshots never publish three components' @() COMPONENT_RELATION_BINDING_CHANGED
        Set-Item Function:Get-LabDiagnosticBinding $script:realDiagnostic
        Set-Item Function:Get-LabPersistedDesiredState $script:realPersisted
        function Get-LabDiagnosticBinding {param($RunId,$InstanceId,$DataRoot);$b=& $script:realDiagnostic @PSBoundParameters;$b.Run.scopeId=[guid]::NewGuid().ToString('D');$b}
        Test-ComponentReject 'Diagnostic read cannot replace the initial source scope' @() COMPONENT_RELATION_BINDING_CHANGED
        Set-Item Function:Get-LabDiagnosticBinding $script:realDiagnostic
        $script:planCalls=0;$script:dispatchCalls=0
        function Get-SqlServerLabReconcilePlan {param($RunId,$TargetState,$ManifestPath,$InstanceId,$StateRoot,[switch]$Container,[switch]$RepairSqlRuntimeContract,[switch]$HyperVNetwork,[switch]$HyperVResources,[switch]$HyperVStorage,[switch]$HyperVSqlStorage,[switch]$HyperVSqlConfiguration,[switch]$HyperVSqlPort,[switch]$HyperVTestDatabases);$script:planCalls++;[pscustomobject]@{IsNoOp=$true;HighestChangeClass='no-op';Actions=@();Desired=[pscustomobject]@{Provider='docker'};Warnings=@()}}
        function Start-SqlServerLab {$script:dispatchCalls++;throw 'FORBIDDEN_START'}
        function Stop-SqlServerLab {$script:dispatchCalls++;throw 'FORBIDDEN_STOP'}
        foreach($case in @('exact-mode','case-mode','unknown-mode','empty-mode','false-capability-no-mode','unknown-capability','version-only','changed-version')){
            $dto=[pscustomobject]@{RunId=$own.RunId}
            switch($case){
                'exact-mode' {$dto|Add-Member Mode COMPONENT_RELATIONS_PLAN_ONLY}
                'case-mode' {$dto|Add-Member Mode component_relations_plan_only;$dto|Add-Member Contract ([pscustomobject]@{Name='SqlServerLab.ReconcilePlan';Version='1.0'})}
                'unknown-mode' {$dto|Add-Member Mode CANARY_PRIVATE_UNKNOWN_MODE}
                'empty-mode' {$dto|Add-Member Mode ''}
                'false-capability-no-mode' {$dto|Add-Member ExecutionSupported $false;$dto|Add-Member Contract ([pscustomobject]@{Name='ChangedCallerFamily';Version='1.0'})}
                'unknown-capability' {$dto|Add-Member ExecutionSupported 'false'}
                'version-only' {$dto|Add-Member Contract ([pscustomobject]@{Name='SqlServerLab.ReconcilePlan';Version='1.2'})}
                'changed-version' {$dto|Add-Member Contract ([pscustomobject]@{Name='sqlserverlab.reconcileplan';Version='1.3'})}
            }
            $script:planCalls=0;$script:dispatchCalls=0;$code=$null
            try{$null=$dto|Invoke-SqlServerLabReconcileAction -TargetState RUNNING -Confirm:$false}catch{$code=$_.Exception.Message}
            Assert-Component ($code-ceq'RECONCILE_PLAN_NOT_EXECUTABLE'-and$script:planCalls-eq0-and$script:dispatchCalls-eq0) ('Actual action '+$case+' rejects before plan and dispatch')
        }
        # Test inventory mirrors existing public parameter sets, never a product registry.
        $families=@(
            @{Name='SqlServerLab.ReconcilePlan';Version='1.0';Args=@{TargetState='RUNNING'}},
            @{Name='SqlServerLab.ReconcilePlan';Version='1.1';Args=@{ManifestPath='synthetic.json';InstanceId='consumer'}},
            @{Name='SqlServerLab.ContainerReconcilePlan';Version='1.0';Args=@{Container=$true;InstanceId='consumer'}},
            @{Name='SqlServerLab.HyperVNetworkReconcilePlan';Version='1.0';Args=@{RepairHyperVNetwork=$true;InstanceId='consumer'}},
            @{Name='SqlServerLab.HyperVResourceReconcilePlan';Version='1.0';Args=@{RepairHyperVResources=$true;InstanceId='consumer'}},
            @{Name='SqlServerLab.HyperVStorageReconcilePlan';Version='1.0';Args=@{RepairHyperVStorage=$true;InstanceId='consumer'}},
            @{Name='SqlServerLab.HyperVSqlStorageReconcilePlan';Version='1.0';Args=@{RepairHyperVSqlStorage=$true;InstanceId='consumer'}},
            @{Name='SqlServerLab.HyperVSqlConfigurationReconcilePlan';Version='1.0';Args=@{RepairHyperVSqlConfiguration=$true;InstanceId='consumer'}},
            @{Name='SqlServerLab.HyperVSqlPortReconcilePlan';Version='1.0';Args=@{RepairHyperVSqlPort=$true;InstanceId='consumer'}},
            @{Name='SqlServerLab.HyperVTestDatabaseReconcilePlan';Version='1.0';Args=@{RepairHyperVTestDatabases=$true;ManifestPath='synthetic.json';InstanceId='consumer'}}
        )
        foreach($family in $families){
            $script:planCalls=0;$script:dispatchCalls=0
            $dto=[pscustomobject]@{RunId=$own.RunId;Contract=[pscustomobject]@{Name=$family.Name;Version=$family.Version}}
            $argsForRoute=$family.Args
            $result=if($family.Version-ceq'1.1'){
                Invoke-SqlServerLabReconcileAction -RunId $own.RunId -Contract $dto.Contract @argsForRoute -StateRoot $own.StateRoot -WhatIf
            }else{$dto|Invoke-SqlServerLabReconcileAction -RunId $own.RunId @argsForRoute -StateRoot $own.StateRoot -WhatIf}
            Assert-Component ($result.ExecutionSummary.Status-ceq'NO_OP'-and$script:planCalls-eq1-and$script:dispatchCalls-eq0) ('Existing mode-less '+$family.Name+'/'+$family.Version+' pipeline remains compatible')
        }
        Set-Item Function:Get-SqlServerLabReconcilePlan $script:realPlan
        Write-Host ('COMPONENT_RELATION_CHECKS: '+$script:checks+' PASS; 0 FAIL')
    } $root
} finally {
    Remove-Module $module -Force
    # Only synthetic files created by this exact invocation.
    $resolved=[IO.Path]::GetFullPath($root);$temporary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if ($resolved.StartsWith($temporary,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('sql-lab-component-check-')) {Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop}
}
