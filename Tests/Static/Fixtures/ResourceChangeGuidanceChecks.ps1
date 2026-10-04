# Real plan/executor and CLI handlers; only provider/state/console boundaries are synthetic.
. (Join-Path $repoRoot 'Private/ContainerReconcile.ps1')
. (Join-Path $repoRoot 'Public/Update-SqlServerLabContainer.ps1')
$actualResourceRepair = ${function:Repair-LabContainerReconcileJournal}
$rawCases=@(
    @{Host=@{NanoCpus=1250000000}; Expected=[decimal]1.25},
    @{Host=@{NanoCpus=0;CpuQuota=375000;CpuPeriod=100000}; Expected=[decimal]3.75},
    @{Host=@{CpuQuota=-1;CpuPeriod=100000}; Expected=$null},
    @{Host=@{CpuQuota=200000}; Expected=$null},
    @{Host=@{CpuQuota=200000;CpuPeriod='invalid'}; Expected=$null},
    @{Host=@{NanoCpus=2000000000;CpuQuota=300000;CpuPeriod=100000}; Expected=$null},
    @{Host=@{}; Expected=$null}
)
foreach($case in $rawCases){
    $actual=Get-LabContainerMeasuredCpu -Inspect ([pscustomobject]@{HostConfig=[pscustomobject]$case.Host})
    if($actual -ne $case.Expected){throw 'Measured CPU reader guessed or rounded a limit'}
}
$script:SchemasPath = Join-Path $repoRoot 'Schemas'
$script:run | Add-Member -NotePropertyName state -NotePropertyValue 'RUNNING' -Force
$script:providerState='RUNNING'
function Get-LabProviderSubRuns { param($RunId,$StateRoot) [pscustomobject]@{provider='docker';state=$script:providerState} }
$script:protected = $false
function Test-LabAutomatedTestEnvironmentRun { param($RunId) $script:protected }
function Get-LabConnectionCenterCmsConfiguration { param($StateRoot) $script:resourceCms }
$script:resourceContext = [pscustomobject]@{
    Run=$script:run; RunId=$runId; RunDirectory=$runDirectory; StateRoot=$testRoot
    Provider='docker'; InstanceId='primary'; ContainerId='synthetic-id'; WasRunning=$true
    CurrentPort=14333; CurrentAutoStartLabel='off'; CurrentCpu=[decimal]2; CurrentMemoryMB=2048
    MountFingerprint=('a'*64)
    Inspect=[pscustomobject]@{
        Id='synthetic-id'
        Config=[pscustomobject]@{ Labels=@{ 'sql-server-lab.instance-id'='primary' } }
        HostConfig=[pscustomobject]@{ Memory=[long]2GB; NanoCpus=[long]2000000000; RestartPolicy=@{Name='no'; MaximumRetryCount=0} }
        NetworkSettings=[pscustomobject]@{Ports=@{'1433/tcp'=@(@{HostIp='127.0.0.1';HostPort='14333'})}}
    }
}
$script:resourceReads=0
function Get-LabContainerReconcileContext { param($RunId,$InstanceId,$StateRoot) $script:resourceReads++; $script:resourceContext }
$script:repairCalls=0
function Repair-LabContainerReconcileJournal { param($Context) $script:repairCalls++; throw 'Unexpected repair' }
function Assert-ResourceFailure { param([scriptblock]$Action,[string]$Pattern) try { & $Action; throw 'Expected failure missing' } catch { if ($_.Exception.Message -notmatch $Pattern) { throw } } }
$argsPlan=@{RunId=$runId; InstanceId='primary'; Provider='docker'; StateRoot=$testRoot}
$plan=Get-LabResourceChangePlan @argsPlan
if (-not $plan.NoChange -or $plan.Actual.Cpu -ne 2 -or $plan.Actual.MemoryMB -ne 2048) { throw 'Measured no-op plan invalid' }
if($plan.Preview.Mounts.Status -ne 'UNKNOWN' -or $null -ne $plan.Preview.Mounts.TotalMountCount){throw 'Missing guided mounts guessed as empty'}
$script:resourceContext.Inspect | Add-Member -NotePropertyName Mounts -NotePropertyValue @(
    [pscustomobject]@{Type='volume';RW=$true;Name='synthetic-private-volume';Destination='/synthetic/private/data'},
    [pscustomobject]@{Type='bind';RW=$true;Source='/synthetic/private/host';Destination='/synthetic/private/bind'},
    [pscustomobject]@{Type='tmpfs';RW=$false}
) -Force
$readsBefore=$script:resourceReads
$mountPlan=Get-LabResourceChangePlan @argsPlan
if($script:resourceReads -ne $readsBefore+1 -or $mountPlan.PlanKey -ne $plan.PlanKey -or
    $mountPlan.Preview.Mounts.Status -ne 'MEASURED' -or $mountPlan.Preview.Mounts.TotalMountCount -ne 3 -or
    $mountPlan.Preview.Mounts.VolumeMountCount -ne 1 -or $mountPlan.Preview.Mounts.HostBindCount -ne 1 -or
    $mountPlan.Preview.Mounts.WritableHostBindCount -ne 1 -or $mountPlan.Preview.Mounts.OtherMountCount -ne 1 -or
    $mountPlan.Preview.Mounts.VolumeOwnership -ne 'NOT_CHECKED'){throw 'Guided mount projection changed binding or repeated context read'}
if(($mountPlan.Preview | ConvertTo-Json -Depth 8) -match 'synthetic-private|/synthetic/private'){throw 'Guided mount preview leaked private inspect'}
$script:resourceContext.Inspect.Mounts=@()
$emptyMountPlan=Get-LabResourceChangePlan @argsPlan
if($emptyMountPlan.Preview.Mounts.Status -ne 'MEASURED' -or $emptyMountPlan.Preview.Mounts.TotalMountCount -ne 0){throw 'Explicit empty guided mounts not measured'}
$script:resourceContext.Inspect.Mounts=[pscustomobject]@{Type='bind';RW=$true}
$invalidMountPlan=Get-LabResourceChangePlan @argsPlan
if($invalidMountPlan.Preview.Mounts.Status -ne 'UNKNOWN' -or $null -ne $invalidMountPlan.Preview.Mounts.TotalMountCount){throw 'Scalar guided mounts counted'}
$script:resourceContext.Inspect.PSObject.Properties.Remove('Mounts')
$result=Update-SqlServerLabContainer -RunId $runId -InstanceId primary -StateRoot $testRoot -Cpu 2 -MemoryMB 2048 -ExpectedResourcePlanKey $plan.PlanKey -Confirm:$false
if ($result.Changed -or $script:repairCalls) { throw 'No-op reached executor/recovery' }
Assert-ResourceFailure { Update-SqlServerLabContainer -RunId $runId -InstanceId primary -StateRoot $testRoot -Cpu 2 -MemoryMB 2048 -Port 14334 -ExpectedResourcePlanKey $plan.PlanKey -Confirm:$false } 'ARGUMENTS_INVALID'
$script:run.state='RECOVERY_REQUIRED'
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan } 'LIFECYCLE_BLOCKED'
$script:run.state='RUNNING'; $script:providerState='RECOVERY_REQUIRED'
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan } 'LIFECYCLE_BLOCKED'
$script:providerState='STOPPED'
$stoppedPlan=Get-LabResourceChangePlan @argsPlan
if($stoppedPlan.PlanKey -eq $plan.PlanKey){throw 'Lifecycle not bound to preview'}
$script:providerState='RUNNING'
$aliasRoot=$testRoot+[IO.Path]::DirectorySeparatorChar
if((Get-LabContainerResourceLockName -StateRoot $aliasRoot -RunId $runId) -ne (Get-LabContainerResourceLockName -StateRoot $testRoot -RunId $runId)){throw 'Root aliases use different locks'}
$held=[Threading.ManualResetEventSlim]::new($false);$release=[Threading.ManualResetEventSlim]::new($false)
$worker=[PowerShell]::Create()
try {
    $null=$worker.AddScript({param($name,$held,$release) $m=[Threading.Mutex]::new($false,$name);$null=$m.WaitOne();try{$held.Set();$null=$release.Wait(10000)}finally{$m.ReleaseMutex();$m.Dispose()}}).AddArgument((Get-LabContainerResourceLockName -StateRoot $testRoot -RunId $runId)).AddArgument($held).AddArgument($release)
    $pending=$worker.BeginInvoke()
    if(-not $held.Wait(5000)){throw 'Lock fixture failed to acquire'}
    Assert-ResourceFailure { Update-SqlServerLabContainer -RunId $runId -InstanceId primary -StateRoot $aliasRoot -Cpu 2 -MemoryMB 2048 -ExpectedResourcePlanKey $plan.PlanKey -Confirm:$false } 'RESOURCE_CHANGE_BUSY'
}finally{$release.Set();if($pending){$null=$worker.EndInvoke($pending)};$worker.Dispose();$held.Dispose();$release.Dispose()}
$changed=Get-LabResourceChangePlan @argsPlan -Cpu 2.5 -MemoryMB 3072
if ($changed.ChangeClass -ne 'live' -or $changed.NoChange) { throw 'Live plan invalid' }
$script:resourceContext.ContainerId='replacement'
Assert-ResourceFailure { Update-SqlServerLabContainer -RunId $runId -InstanceId primary -StateRoot $testRoot -Cpu 2.5 -MemoryMB 3072 -ExpectedResourcePlanKey $changed.PlanKey -Confirm:$false } 'STALE'
$script:resourceContext.ContainerId='synthetic-id'
$script:resourceContext.Inspect.HostConfig.Memory=0
$unknown=Get-LabResourceChangePlan @argsPlan
if ($unknown.CanApply -or $null -ne $unknown.Actual.MemoryMB) { throw 'Unlimited falsely treated as measured' }
$script:resourceContext.Inspect.HostConfig.Memory=[long]2GB
$script:resourceContext.Inspect.HostConfig.NanoCpus=0
$unknown=Get-LabResourceChangePlan @argsPlan
if ($unknown.CanApply -or $null -ne $unknown.Actual.Cpu) { throw 'Unknown CPU falsely substituted' }
$script:resourceContext.Inspect.HostConfig.NanoCpus=[long]2000000000
$script:protected=$true
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan } 'PROTECTED'
$script:protected=$false
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan -Cpu 1.234 } 'CPU_RANGE'
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan -MemoryMB 1048577 } 'MEMORY_RANGE'
Assert-ResourceFailure { Get-LabResourceChangePlan -RunId $runId -InstanceId other -Provider docker -StateRoot $testRoot } 'TARGET_MISMATCH'
'{}' | Set-Content -LiteralPath (Join-Path $runDirectory 'container-reconcile-journal.json')
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan } 'JOURNAL_SCHEMA_INVALID'
Remove-Item -LiteralPath (Join-Path $runDirectory 'container-reconcile-journal.json')
# Import the real CLI handler without invoking its application entrypoint.
$tokens=$null;$parseErrors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'),[ref]$tokens,[ref]$parseErrors)
$handler=$ast.Find({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Set-LabResourcesInteractive'},$true)
. ([scriptblock]::Create($handler.Extent.Text))
function Get-LabActiveRuns { $script:run }
function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $null }
function Write-LabInfo { param($Message) }
function Write-LabWarning { param($Message) }
function Write-LabError { param($Message) throw $Message }
function Wait-LabConsoleAcknowledgement {}
Set-LabResourcesInteractive -RunId $runId
if ($script:repairCalls) { throw 'Cancel mutated' }
# Exercise the real executor's live branch; external command and journal persistence are boundaries.
$script:resourceContext | Add-Member -Force -NotePropertyMembers @{
    ContainerName='synthetic-container'; Connection=$containerConnection; ConnectionPath=(Join-Path $runDirectory 'connection-info.json'); Instance=$containerConnection.instances[0]
    CurrentRestartPolicy='no'; CurrentAutoStart='off'; ConfiguredSqlMemory=@('MSSQL_MEMORY_LIMIT_MB=1638'); HealthCommand='sqlcmd -C'
}
$journalPlan=New-LabContainerReconcilePlan -RunId $runId -InstanceId primary -Cpu 2.5 -MemoryMB 3072 -StateRoot $testRoot
$journalInfo=New-LabContainerReconcileJournal -Context $script:resourceContext -Plan $journalPlan
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan } 'JOURNAL_BLOCKED'
$journalInfo.Journal.Status='COMPLETED'
$journalInfo.Journal.InstanceId='foreign-instance'
Write-LabArtifactJsonAtomic -Path $journalInfo.Path -InputObject $journalInfo.Journal
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan } 'JOURNAL_BLOCKED'
$journalInfo.Journal.InstanceId='primary'
Write-LabArtifactJsonAtomic -Path $journalInfo.Path -InputObject $journalInfo.Journal
$terminal=Get-LabResourceChangePlan @argsPlan
if (-not $terminal.CanApply) { throw 'Owned terminal journal should permit fresh plan' }
$journalInfo.Journal.Status='LIVE_MUTATED'
Write-LabArtifactJsonAtomic -Path $journalInfo.Path -InputObject $journalInfo.Journal
$script:rollbackTargets=@()
function Assert-LabContainerReconcileRuntimeIdentity { param($Provider,$Identity,$RunId,$ScopeId) if($Identity -eq 'synthetic-container'){throw 'Old name now belongs to neighbor'}; $script:resourceContext.Inspect }
function Invoke-LabContainerReconcileCommand { param($Provider,$Arguments,$ErrorCode) $script:rollbackTargets += [string]$Arguments[-1] }
$recovered=& $actualResourceRepair -Context $script:resourceContext
if($recovered.Status -ne 'ROLLED_BACK' -or $script:rollbackTargets.Count -ne 1 -or $script:rollbackTargets[0] -ne 'synthetic-id'){throw 'Rollback followed reused name instead of original ID'}
Remove-Item -LiteralPath $journalInfo.Path
$script:commands=@()
function Repair-LabContainerReconcileJournal { param($Context) $script:repairCalls++ }
function New-LabContainerReconcileJournal { param($Context,$Plan) [pscustomobject]@{ Journal=[pscustomobject]@{ Status='PREPARED'; OperationId='synthetic-operation' }; Path='synthetic-journal' } }
function Set-LabContainerReconcileJournalStatus { param($Journal,$Path,$Status) $Journal.Status=$Status; $Journal }
function Invoke-LabContainerReconcileCommand { param($Provider,$Arguments,$ErrorCode) $script:commands += ,$Arguments; $script:resourceContext.Inspect.HostConfig.NanoCpus=[long]2500000000; $script:resourceContext.Inspect.HostConfig.Memory=[long]3GB }
function Assert-LabContainerReconcileRuntimeIdentity { param($Provider,$Identity,$RunId,$ScopeId) $script:resourceContext.Inspect }
$live=Get-LabResourceChangePlan @argsPlan -Cpu 2.5 -MemoryMB 3072
$result=Update-SqlServerLabContainer -RunId $runId -InstanceId primary -StateRoot $testRoot -Cpu 2.5 -MemoryMB 3072 -ExpectedResourcePlanKey $live.PlanKey -Confirm:$false
if (-not $result.Changed -or $result.Recreated -or $result.ChangeClass -ne 'live' -or $script:commands.Count -ne 1 -or ($script:commands[0] -join ' ') -ne 'update --cpus 2.5 --memory 3072m synthetic-id') { throw 'Bound executor changed more than CPU/RAM' }
$script:resourceContext.Inspect.HostConfig | Add-Member -Force -NotePropertyMembers @{NanoCpus=[long]0;CpuQuota=[long]250000;CpuPeriod=[long]100000}
$quotaPlan=Get-LabResourceChangePlan @argsPlan
if($quotaPlan.Actual.Cpu -ne [decimal]2.5 -or -not $quotaPlan.NoChange){throw 'Guidance did not preserve fractional quota limit'}
$script:resourceContext.Inspect.HostConfig.CpuQuota=0
$script:resourceContext.Inspect.HostConfig.NanoCpus=[long]2500000000
function Invoke-LabContainerReconcileCommand { param($Provider,$Arguments,$ErrorCode) $script:resourceContext.Inspect.HostConfig.NanoCpus=[long]2750000000 }
$mismatch=Get-LabResourceChangePlan @argsPlan -Cpu 3 -MemoryMB 3072
Assert-ResourceFailure { Update-SqlServerLabContainer -RunId $runId -InstanceId primary -StateRoot $testRoot -Cpu 3 -MemoryMB 3072 -ExpectedResourcePlanKey $mismatch.PlanKey -Confirm:$false } 'LIVE_POSTCONDITION_FAILED'
$script:resourceContext.Inspect.HostConfig.NanoCpus=[long]2500000000
function Assert-LabContainerReconcileRuntimeIdentity { param($Provider,$Identity,$RunId,$ScopeId) $post=$script:resourceContext.Inspect | Select-Object *; $post.Id='neighbor-id'; $post }
$identityPlan=Get-LabResourceChangePlan @argsPlan -Cpu 3 -MemoryMB 3072
Assert-ResourceFailure { Update-SqlServerLabContainer -RunId $runId -InstanceId primary -StateRoot $testRoot -Cpu 3 -MemoryMB 3072 -ExpectedResourcePlanKey $identityPlan.PlanKey -Confirm:$false } 'LIVE_IDENTITY_MISMATCH'
$script:resourceContext.Inspect.HostConfig.NanoCpus=[long]2500000000
# CLI cancel at confirmation and no-op both bypass the executor; selected instance is retained.
$script:cliCalls=0
function Update-SqlServerLabContainer { param($RunId,$InstanceId,$Cpu,$MemoryMB,$ExpectedResourcePlanKey,$Confirm) $script:cliCalls++; if($InstanceId -ne 'primary' -or $Cpu -ne 3 -or $MemoryMB -ne 3072 -or -not $ExpectedResourcePlanKey){throw 'CLI target binding lost'}; [pscustomobject]@{Status='SUCCEEDED'} }
function Select-LabConsoleDataItem { param($ScreenId,$Title,$Items) $Items[0].Data }
$script:answers=[Collections.Generic.Queue[string]]::new()
function Read-Host { param($Prompt) $script:answers.Dequeue() }
function Read-LabConfirm { param($Prompt,$Default) $script:confirmResource }
function Write-LabSuccess { param($Message) }
$script:answers.Enqueue('');$script:answers.Enqueue('')
Set-LabResourcesInteractive -RunId $runId
if($script:cliCalls){throw 'CLI no-op dispatched'}
$script:confirmResource=$false
$script:answers.Enqueue('3');$script:answers.Enqueue('3072')
Set-LabResourcesInteractive -RunId $runId
if($script:cliCalls){throw 'CLI declined confirmation dispatched'}
$script:confirmResource=$true
$script:answers.Enqueue('3');$script:answers.Enqueue('3072')
Set-LabResourcesInteractive -RunId $runId
if($script:cliCalls -ne 1){throw 'CLI confirmed plan not dispatched'}
$script:resourceCms=[pscustomobject]@{RunId=$runId}
Assert-ResourceFailure { Get-LabResourceChangePlan @argsPlan } 'SYSTEM_SERVICE'
$script:resourceCms=$null
$script:vm | Add-Member -NotePropertyName Id -NotePropertyValue 'synthetic-vm-id' -Force
$hypervConnection=[pscustomobject]@{instances=@([pscustomobject]@{id='vm';provider='hyperv';vmName='resource-test-vm';vmId='synthetic-vm-id'})}
Write-LabArtifactJsonAtomic -Path (Join-Path $runDirectory 'connection-info.json') -InputObject $hypervConnection
$hypervPlan=Get-LabResourceChangePlan -RunId $runId -InstanceId vm -Provider hyperv -Cpu 8 -MemoryMB 8192 -StateRoot $testRoot
if($hypervPlan.CanApply -or $hypervPlan.ChangeClass -ne 'unsupported' -or $hypervPlan.Actual.Cpu -ne 6 -or $hypervPlan.Desired.Cpu -ne 8 -or $script:vm.MemoryStartup -ne 6GB){throw 'Hyper-V preview mutated or claimed Apply'}
if($null -ne $hypervPlan.Preview.Mounts){throw 'Hyper-V guessed container mount evidence'}
Write-Host 'Resource guidance checks: 43 PASS, 0 FAIL'
