#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repo=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$root=Join-Path $repo ('.artifacts/test-runs/run-artifact-removal-'+[guid]::NewGuid().ToString('N'))
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
try {
    & $module {
        param($Root,$Repo)
        $script:checks=0; $script:provider='docker'; $script:runtime='runtime-scope-'+('1'*24)
        $script:present=$false; $script:unknown=$false
        $script:realWrite=${function:Write-LabArtifactJsonAtomic}
        function Assert-RunArtifact {param([bool]$Value,[string]$Name)
            if (-not $Value) {throw "RUN_ARTIFACT_CHECK_FAILED: $Name"}
            $script:checks++; Write-Host "PASS: $Name"
        }
        function Reset-RunArtifact {
            $script:data=Join-Path $Root ([guid]::NewGuid().ToString('N'))
            $script:stateRoot=Join-Path $script:data 'State'
            $script:configuration=[pscustomobject]@{ControllerId=[guid]::NewGuid().ToString('D');LabDataLocations=@(
                [pscustomobject]@{LocationId=[guid]::NewGuid().ToString('D');LabDataRoot=$script:data;VolumeId='synthetic-volume'})}
            $script:run=New-LabRunState -StateRoot $script:stateRoot -Metadata @{persistentData=$false;artifactRemovalRuntimeScopes=@(
                [pscustomobject]@{Provider=$script:provider;Status='AVAILABLE';OriginStatus='PINNED_CREATION';RuntimeScopeId=$script:runtime;RoutingKey='synthetic-route';IncarnationKey='synthetic-incarnation'})}
            $state=Get-LabRunState -RunId $script:run.RunId -StateRoot $script:stateRoot
            $state.state='REMOVED'; Write-LabArtifactJsonAtomic -Path (Join-Path $script:run.RunDir 'run-state.json') -InputObject $state
            $cleanup=[pscustomobject]@{runId=$script:run.RunId;scopeId=$script:run.ScopeId;status='COMPLETED';steps=@(
                [pscustomobject]@{provider=$script:provider;resourceType='container';resourceId='synthetic-container';action='remove';state='COMPLETED'},
                [pscustomobject]@{provider=$script:provider;resourceType='volume';resourceId='synthetic-volume';action='remove';state='COMPLETED'})}
            Write-LabArtifactJsonAtomic -Path (Join-Path $script:run.RunDir 'cleanup-plan.json') -InputObject $cleanup
            $script:artifactArguments=@{RunId=$script:run.RunId;StateRoot=$script:stateRoot;DataRoot=$script:data}
            $script:present=$false; $script:unknown=$false; $script:writeFault=$false
            Set-Item Function:Write-LabArtifactJsonAtomic -Value $script:realWrite
        }
        function Get-ArtifactPlan {Get-SqlServerLabRunArtifactRemovalPlan @script:artifactArguments}
        function Assert-Blocked {
            param([string]$Code)
            $plan=Get-ArtifactPlan
            Assert-RunArtifact ($plan.Status -ceq 'BLOCKED' -and -not $plan.CanApply -and $plan.ReasonCode -ceq $Code) $Code
            Assert-RunArtifact (Test-Path -LiteralPath (Join-Path $script:run.RunDir 'run-state.json')) 'Blocked leaves original evidence'
        }
        function Edit-Run {param([scriptblock]$Edit)
            $state=Get-LabRunState -RunId $script:run.RunId -StateRoot $script:stateRoot
            & $Edit $state
            Write-LabArtifactJsonAtomic -Path (Join-Path $script:run.RunDir 'run-state.json') -InputObject $state
        }
        Set-Item Function:Resolve-LabDataRootForUse -Value {param($DataRoot)$DataRoot}
        Set-Item Function:Get-LabStorageConfiguration -Value {param($DataRoot)$script:configuration}
        Set-Item Function:Test-LabDataRootOwnership -Value {param($DataRoot,$ControllerId)$true}
        Set-Item Function:Get-LabDataRootMarker -Value {param($DataRoot)[pscustomobject]@{VolumeId='synthetic-volume'}}
        Set-Item Function:Get-LabVolumeIdentity -Value {param($Path)[pscustomobject]@{VolumeId='synthetic-volume'}}
        Set-Item Function:Get-LabRunArtifactRuntimeIncarnation -Value {param($Context,$StateRoot)'synthetic-incarnation'}
        Set-Item Function:Get-LabRunArtifactRuntimeContext -Value {param($Provider,$StateRoot)
            if($script:unknown){throw 'SYNTHETIC_UNAVAILABLE'}
            [pscustomobject]@{Provider=$Provider;RuntimeScopeId=$script:runtime;RoutingKey='synthetic-route';StateRoot=$null;Endpoint='npipe://synthetic-original';IdentityPath=$null}
        }
        Set-Item Function:Invoke-LabRunArtifactNative -Value {param($Context,$Arguments)
            if ($script:unknown) {return [pscustomobject]@{ExitCode=1;Output=@('private synthetic failure')}}
            [pscustomobject]@{ExitCode=0;Output=if ($script:present) {@('synthetic-container')} else {@()}}
        }
        foreach ($provider in @('docker','podman')) {
            $script:provider=$provider; Reset-RunArtifact
            $before=@(Get-ChildItem -LiteralPath $script:data -Recurse -File | Get-FileHash | ForEach-Object Hash) -join '|'
            $plan=Get-ArtifactPlan
            Assert-RunArtifact ($plan.Status -ceq 'READY' -and $plan.CanApply -and $plan.PlanKey -cmatch '^[a-f0-9]{64}$') "$provider preview READY"
            Assert-RunArtifact (($before -ceq (@(Get-ChildItem -LiteralPath $script:data -Recurse -File | Get-FileHash | ForEach-Object Hash) -join '|'))) 'Preview writes nothing'
            $view=$plan | ConvertTo-Json
            Assert-RunArtifact ($view -notmatch [regex]::Escape($script:data) -and $view -notmatch 'synthetic-container|synthetic-volume') 'Public view contains no paths or native IDs'
            $cancel=Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $plan.PlanKey -WhatIf
            Assert-RunArtifact ($cancel.Status -ceq 'CANCELLED' -and -not (Test-Path -LiteralPath (Join-Path $script:stateRoot 'run-artifact-removals'))) 'WhatIf writes no journal'
            $result=Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $plan.PlanKey -Confirm:$false
            Assert-RunArtifact ($result.Status -ceq 'REMOVED' -and -not (Test-Path -LiteralPath $script:run.RunDir)) "$provider exact removal"
            Assert-RunArtifact (-not (Test-Path -LiteralPath (Join-Path $script:stateRoot ('scope-markers/'+$script:run.ScopeId+'.json')))) 'Scope marker removed'
            $repeat=Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $plan.PlanKey -Confirm:$false
            Assert-RunArtifact (-not $repeat.Changed -and $repeat.Status -ceq 'REMOVED') 'Completion is idempotent'
        }
        Reset-RunArtifact; Edit-Run {param($s)$s.state='RECOVERY_REQUIRED'}; Assert-Blocked 'RUN_ARTIFACT_REMOVED_STATE_REQUIRED'
        Reset-RunArtifact; Edit-Run {param($s)$s.metadata.persistentData=$true}; Assert-Blocked 'RUN_ARTIFACT_RETAINED_OR_PROTECTED'
        Reset-RunArtifact; Edit-Run {param($s)$s.metadata | Add-Member desiredState ([pscustomobject]@{Instances=@([pscustomobject]@{Drives=@([pscustomobject]@{Binding='host-mount';Persistence='run-scoped'})})})}; Assert-Blocked 'RUN_ARTIFACT_RETAINED_OR_PROTECTED'
        foreach ($name in @('automatedTestEnvironment','testGroupId','workflowOperationId')) {
            Reset-RunArtifact; Edit-Run {param($s)$s.metadata | Add-Member $name 'synthetic-membership'}; Assert-Blocked 'RUN_ARTIFACT_RETAINED_OR_PROTECTED'
        }
        Reset-RunArtifact
        $s=Get-LabRunState -RunId $script:run.RunId -StateRoot $script:stateRoot
        $image='hyperv-os-sealed-'+('a'*64)
        $s.metadata | Add-Member workflowKind 'hyperv-lab'; $s.metadata | Add-Member imageArtifactId $image
        $s.metadata | Add-Member windowsPoolMember ([pscustomobject]@{contractVersion='SqlServerLab.WindowsPoolMember/1.0';poolId=[guid]::NewGuid().ToString();creationOperationId=[guid]::NewGuid().ToString();runId=$s.runId;scopeId=$s.scopeId;evidenceEpoch=[guid]::NewGuid().ToString();provider='hyperv';imageArtifactId=$image;revision=1;index=1;state='REMOVED';instanceId='primary'})
        Write-LabArtifactJsonAtomicRaw (Join-Path $script:run.RunDir 'run-state.json') $s
        Assert-Blocked 'RUN_ARTIFACT_RETAINED_OR_PROTECTED'
        Reset-RunArtifact; Edit-Run {param($s)$s.metadata.artifactRemovalRuntimeScopes[0].IncarnationKey='replaced-engine'}; Assert-Blocked 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE'
        Reset-RunArtifact; Edit-Run {param($s)$s.metadata.artifactRemovalRuntimeScopes[0].OriginStatus='OBSERVED_ONLY'}; Assert-Blocked 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE'
        Reset-RunArtifact; Edit-Run {param($s)$s.metadata.artifactRemovalRuntimeScopes[0].RoutingKey='changed-endpoint'}; Assert-Blocked 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE'
        Reset-RunArtifact; Edit-Run {param($s)$s.metadata.artifactRemovalRuntimeScopes=@()}; Assert-Blocked 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE'
        Reset-RunArtifact; $script:runtime='runtime-scope-'+('2'*24); Assert-Blocked 'RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE'; $script:runtime='runtime-scope-'+('1'*24)
        Reset-RunArtifact; $script:present=$true; Assert-Blocked 'RUN_ARTIFACT_RESOURCE_PRESENT'
        Reset-RunArtifact; $script:unknown=$true; Assert-Blocked 'RUN_ARTIFACT_EVIDENCE_UNVERIFIABLE'
        Reset-RunArtifact
        $cleanup=Get-Content (Join-Path $script:run.RunDir 'cleanup-plan.json') -Raw | ConvertFrom-Json
        $cleanup.steps[1].state='FAILED'; Write-LabArtifactJsonAtomic (Join-Path $script:run.RunDir 'cleanup-plan.json') $cleanup
        Assert-Blocked 'RUN_ARTIFACT_CLEANUP_INCOMPLETE'
        Reset-RunArtifact
        Write-LabArtifactJsonAtomic (Join-Path $script:data 'reference.json') ([pscustomobject]@{RunId=$script:run.RunId;Retention='RETAINED'})
        Assert-Blocked 'RUN_ARTIFACT_REFERENCED_OR_RETAINED'
        Reset-RunArtifact
        Write-LabArtifactJsonAtomic (Join-Path $script:run.RunDir 'reconcile-journal.json') ([pscustomobject]@{Status='RECOVERY_REQUIRED'})
        Assert-Blocked 'RUN_ARTIFACT_RECOVERY_REQUIRED'
        Reset-RunArtifact
        $nested=Join-Path $script:run.RunDir 'ai-agent'; $null=New-Item $nested -ItemType Directory
        Write-LabArtifactJsonAtomic (Join-Path $nested 'diagnostic-synthetic.json') ([pscustomobject]@{Status='PENDING';cleanupStatus='RECOVERY_REQUIRED'})
        Assert-Blocked 'RUN_ARTIFACT_RECOVERY_REQUIRED'
        foreach ($name in @('retained.json','retained.txt','retained.log')) {
            Reset-RunArtifact; [IO.File]::WriteAllText((Join-Path $script:run.RunDir $name),'{}'); Assert-Blocked 'RUN_ARTIFACT_UNKNOWN_PAYLOAD'
        }
        Reset-RunArtifact; [IO.File]::WriteAllBytes((Join-Path $script:run.RunDir 'unclassified.bak'),[byte[]](1,2,3)); Assert-Blocked 'RUN_ARTIFACT_UNKNOWN_PAYLOAD'
        Reset-RunArtifact; $plan=Get-ArtifactPlan
        [IO.File]::WriteAllText((Join-Path $script:run.RunDir 'extra.txt'),'synthetic unexpected leaf')
        $rejected=$false
        try {Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $plan.PlanKey -Confirm:$false | Out-Null} catch {$rejected=$_.Exception.Message -ceq 'RUN_ARTIFACT_UNKNOWN_PAYLOAD'}
        Assert-RunArtifact ($rejected -and (Test-Path -LiteralPath $script:run.RunDir)) 'Stale preview refuses added file'
        Reset-RunArtifact; $plan=Get-ArtifactPlan
        # Real staging and deletion with one deterministic interrupted write.
        Set-Item Function:Write-LabArtifactJsonAtomic -Value {param($Path,$InputObject)
            if ($InputObject.Status -ceq 'DELETING' -and -not $script:writeFault) {$script:writeFault=$true;throw 'SYNTHETIC_INTERRUPTION'}
            & $script:realWrite -Path $Path -InputObject $InputObject
        }
        $interrupted=$false
        try {Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $plan.PlanKey -Confirm:$false | Out-Null} catch {$interrupted=$_.Exception.Message -ceq 'RUN_ARTIFACT_RECOVERY_REQUIRED'}
        Assert-RunArtifact ($interrupted -and -not (Test-Path -LiteralPath $script:run.RunDir)) 'Interrupted staged operation records recovery'
        Set-Item Function:Write-LabArtifactJsonAtomic -Value $script:realWrite
        $resume=Get-ArtifactPlan
        Assert-RunArtifact ($resume.Status -ceq 'RECOVERY_REQUIRED' -and $resume.PlanKey -ceq $plan.PlanKey) 'Resume keeps exact authorization'
        $result=Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $resume.PlanKey -Confirm:$false
        Assert-RunArtifact ($result.Status -ceq 'REMOVED') 'Resume completes own staged operation'
        Reset-RunArtifact; $plan=Get-ArtifactPlan
        $markerPath=Join-Path $script:stateRoot ('scope-markers/'+$script:run.ScopeId+'.json')
        $handle=$null
        if ($IsWindows) {$handle=[IO.File]::Open($markerPath,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)}
        else {
            # Unix unlink does not honor Windows delete sharing. Exercise the
            # same terminating permission failure at the exact marker leaf.
            function Remove-Item {
                [CmdletBinding()]param([string]$LiteralPath,[switch]$Force)
                if ($LiteralPath -ceq $markerPath) {Write-Error 'SYNTHETIC_MARKER_PERMISSION_DENIED';return}
                Microsoft.PowerShell.Management\Remove-Item @PSBoundParameters
            }
        }
        $failed=$false; $oldPreference=$ErrorActionPreference; $ErrorActionPreference='Continue'
        try { Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $plan.PlanKey -Confirm:$false | Out-Null } catch {$failed=$_.Exception.Message -ceq 'RUN_ARTIFACT_RECOVERY_REQUIRED'}
        finally {
            if ($handle) {$handle.Dispose()} else {Remove-Item Function:Remove-Item}
            $ErrorActionPreference=$oldPreference
        }
        Assert-RunArtifact ($failed -and (Test-Path -LiteralPath $markerPath)) 'Locked marker cannot report successful removal'
        $resume=Get-ArtifactPlan
        if ($resume.Status -cne 'RECOVERY_REQUIRED') {Write-Host ('Marker recovery diagnostic: '+($resume | ConvertTo-Json -Compress))}
        Assert-RunArtifact ($resume.Status -ceq 'RECOVERY_REQUIRED') 'Locked marker preserves recovery journal'
        $result=Invoke-SqlServerLabRunArtifactRemoval @script:artifactArguments -ExpectedPlanKey $resume.PlanKey -Confirm:$false
        Assert-RunArtifact ($result.Status -ceq 'REMOVED' -and -not (Test-Path -LiteralPath $markerPath)) 'Marker-only recovery completes after unlocking'
        Write-LabArtifactJsonAtomic $markerPath ([pscustomobject]@{runId=$script:run.RunId;scopeId=$script:run.ScopeId})
        $conflict=Get-ArtifactPlan; Assert-RunArtifact ($conflict.ReasonCode -ceq 'RUN_ARTIFACT_TOMBSTONE_CONFLICT') 'Terminal receipt detects recreated scope marker'
        $bindings=@((New-LabRunArtifactCreationBinding -Provider docker,podman -StateRoot $script:stateRoot).Records)
        Assert-RunArtifact ($bindings.Count -eq 2 -and @($bindings | Where-Object Status -CNE 'AVAILABLE').Count -eq 0) 'Producer captures separate provider identities'
        $creation=New-LabRunArtifactCreationBinding -Provider docker -StateRoot $script:stateRoot
        Assert-RunArtifact ($creation.Records[0].OriginStatus -ceq 'PINNED_CREATION') 'Creation origin requires fixed transport'
        Set-Item Function:Get-LabHostToolInvocation -Value {param($Name)(Get-Command pwsh).Source}
        Set-Item Function:Invoke-LabOwnedHostNativeProcess -Value {param($StartInfo,$TimeoutSeconds)
            $script:observedArguments=@($StartInfo.ArgumentList)
            $script:observedRouting=@($StartInfo.Environment.Keys | Where-Object {$_ -cin @('DOCKER_CONTEXT','DOCKER_HOST','CONTAINER_CONNECTION')})
            [pscustomobject]@{ExitCode=17;Stdout='synthetic-output';Stderr=''}
        }
        $priorContext=$env:DOCKER_CONTEXT; $priorConnection=$env:CONTAINER_CONNECTION
        try {
            $env:DOCKER_CONTEXT='synthetic-changed-target';$env:CONTAINER_CONNECTION='synthetic-changed-target'
            $script:LabRunArtifactCreationBinding=$creation
            $native=Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $script:stateRoot -ArgumentList @('create','synthetic-image') -NativeResult
            Assert-RunArtifact ($script:observedArguments[0] -ceq '--host' -and $script:observedArguments[1] -ceq 'npipe://synthetic-original' -and $script:observedRouting.Count -eq 0) 'Creation uses original endpoint despite changed ambient selection'
            Assert-RunArtifact ($native.ExitCode -eq 17 -and $native.Output[0] -ceq 'synthetic-output') 'Pinned creation preserves native result'
            $global:LASTEXITCODE=0
            $operation=Invoke-LabProviderOperation -Provider docker -Phase 'synthetic-exitcode' -NativeResult -StateRoot $script:stateRoot -Action {
                Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $script:stateRoot -ArgumentList @('create','synthetic-image') -NativeResult
            }
            Assert-RunArtifact (-not $operation.Succeeded -and $operation.ExitCode -eq 17) 'Actual provider action propagates pinned failure despite global success'
            Set-Item Function:Invoke-LabOwnedHostNativeProcess -Value {param($StartInfo,$TimeoutSeconds)
                $script:observedTimeout=$TimeoutSeconds
                [pscustomobject]@{ExitCode=0;Stdout='synthetic-output';Stderr=''}
            }
            $global:LASTEXITCODE=1
            $operation=Invoke-LabProviderOperation -Provider docker -Phase 'synthetic-exitcode' -NativeResult -StateRoot $script:stateRoot -Action {
                Invoke-LabContainerRuntimeCommand -Provider docker -StateRoot $script:stateRoot -ArgumentList @('create','synthetic-image') -NativeResult
            }
            Assert-RunArtifact ($operation.Succeeded -and $operation.ExitCode -eq 0) 'Actual provider action propagates pinned success despite prior failure'
            Set-Item Function:Get-LabStateRoot -Value {param($ExplicitPath)if($ExplicitPath){$ExplicitPath}else{$script:stateRoot}}
            Stop-DockerInstance -ContainerIdOrName 'synthetic-container' -TimeoutSeconds 120 -StateRoot $script:stateRoot
            Assert-RunArtifact ($script:observedTimeout -eq 150) 'Actual stop process budget covers requested grace plus overhead'
        }
        finally {$script:LabRunArtifactCreationBinding=$null;$env:DOCKER_CONTEXT=$priorContext;$env:CONTAINER_CONNECTION=$priorConnection}
        Write-Host "RUN ARTIFACT REMOVAL CHECKS: $script:checks PASS"
    } $root $repo
}
finally {
    $boundary=[IO.Path]::GetFullPath((Join-Path $repo '.artifacts/test-runs')).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
    if ([IO.Path]::GetFullPath($root).StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $root)) {Remove-Item -LiteralPath $root -Recurse -Force}
    Remove-Module $module.Name -Force
}
