<#
.SYNOPSIS
    Changes a registered container restart policy in place.
.DESCRIPTION
    Applies only a matching bound plan and records recovery state.
.PARAMETER RunId
    Registered run identifier.
.PARAMETER InstanceId
    Registered instance identifier.
.PARAMETER AutoStart
    Requested on/off policy.
.PARAMETER ExpectedAutoStartPlanKey
    Key returned by the plan.
.PARAMETER StateRoot
    Optional managed state root.
.EXAMPLE
    Set-SqlServerLabContainerAutoStart -RunId $runId -InstanceId primary -AutoStart on -ExpectedAutoStartPlanKey $plan.PlanKey
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Set-SqlServerLabContainerAutoStart {
    <#
    .SYNOPSIS Changes a registered container lab's restart policy in place.
    .PARAMETER RunId Registered run to change.
    .PARAMETER InstanceId Registered container instance.
    .PARAMETER AutoStart Requested on/off policy.
    .PARAMETER ExpectedAutoStartPlanKey Key returned by the fresh plan.
    .PARAMETER StateRoot Optional managed state root.
    .DESCRIPTION Applies only a fresh, bound direct-autostart plan. The exact
    container ID and its power state are checked before and after `update
    --restart`; no recreate, start, stop, backup or restore is performed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('on','off')][string]$AutoStart,
        [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedAutoStartPlanKey,
        [string]$StateRoot
    )
    if(-not $StateRoot){$StateRoot=Get-LabStateRoot}
    $featureGuard=Enter-LabSqlFeatureConflictGuard -RunId $RunId -StateRoot $StateRoot
    try {
    if (-not $StateRoot) { $StateRoot = Get-LabStateRoot }
    $StateRoot = Get-LabCanonicalResourceRoot -StateRoot $StateRoot
    if ((Test-LabAutomatedTestEnvironmentRun -RunId $RunId) -and -not $script:LabAutomatedTestEnvironmentGroupOperation) {
        throw 'TEST_ENVIRONMENT_GROUP_PROTECTED: Autostart ist für einzelne Testumgebungen gesperrt.'
    }
    $mutex = [Threading.Mutex]::new($false, (Get-LabContainerResourceLockName -StateRoot $StateRoot -RunId $RunId))
    $acquired = $false
    try {
        try { $acquired = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired = $true }
        if (-not $acquired) { throw 'AUTOSTART_APPLY_BUSY' }
        $plan = Get-LabContainerAutoStartApplyPlan -RunId $RunId -InstanceId $InstanceId -AutoStart $AutoStart -StateRoot $StateRoot
        if ($plan.PlanKey -ne $ExpectedAutoStartPlanKey) { throw 'AUTOSTART_APPLY_STALE_OR_UNAVAILABLE: Vorschau erneut lesen.' }
        if ($plan.NoChange) {
            return [pscustomobject]@{ RunId=$RunId; InstanceId=$InstanceId; Provider=$plan.Context.Provider; Changed=$false; NoChange=$true; Status='NO_OP' }
        }
        if (-not $PSCmdlet.ShouldProcess($plan.Context.ContainerName, "Autostart auf '$AutoStart' ändern")) { return }
        $journalInfo = New-LabContainerAutoStartJournal -Plan $plan
        $journal = $journalInfo.Journal; $journalPath = $journalInfo.Path
        try {
            if ($plan.RuntimeMutationRequired) {
                $null = Invoke-LabContainerReconcileCommand -Provider $plan.Context.Provider -Arguments @('update','--restart',$plan.TargetRestartPolicy,[string]$plan.Context.ContainerId) -ErrorCode 'AUTOSTART_APPLY_UPDATE_FAILED'
            }
            $post = Assert-LabContainerReconcileRuntimeIdentity -Provider $plan.Context.Provider -Identity ([string]$plan.Context.ContainerId) -RunId $RunId -ScopeId ([string]$plan.Context.Run.scopeId)
            if ([string]$post.Id -ne [string]$plan.Context.ContainerId -or [bool]$post.State.Running -ne [bool]$plan.Context.WasRunning -or
                [string]$post.Config.Labels.'sql-server-lab.instance-id' -ne $InstanceId -or [string]$post.HostConfig.RestartPolicy.Name -ne $plan.TargetRestartPolicy) {
                throw 'AUTOSTART_APPLY_POSTCONDITION_FAILED'
            }
            $journal.Status='POLICY_MUTATED'; $null=Write-LabContainerAutoStartJournal -Journal $journal -Path $journalPath
            $context = Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
            if ([string]$context.ContainerId -ne [string]$plan.Context.ContainerId -or [bool]$context.WasRunning -ne [bool]$plan.Context.WasRunning -or [string]$context.CurrentAutoStart -ne $AutoStart) {
                throw 'AUTOSTART_APPLY_READBACK_CHANGED'
            }
            $context.Instance | Add-Member -NotePropertyName autostart -NotePropertyValue $AutoStart -Force
            $desired = @($context.Run.metadata.desiredState.Instances | Where-Object { [string]$_.Id -ceq $InstanceId -and [string]$_.Provider -ceq [string]$context.Provider })
            if ($desired.Count -ne 1) { throw 'AUTOSTART_APPLY_DESIRED_INSTANCE_INVALID' }
            $desired[0].AutoStart = $AutoStart
            Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $context.Connection
            Write-LabArtifactJsonAtomic -Path (Join-Path $context.RunDirectory 'run-state.json') -InputObject $context.Run
            if ((Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot).Status -ne 'VALID') { throw 'AUTOSTART_APPLY_DESIRED_STATE_COMMIT_INVALID' }
            $journal.Status='STATE_COMMITTED'; $journal.Recovery.Status='NOT_REQUIRED'; $null=Write-LabContainerAutoStartJournal -Journal $journal -Path $journalPath
            $journal.Status='COMPLETED'; $null=Write-LabContainerAutoStartJournal -Journal $journal -Path $journalPath
            return [pscustomobject]@{ RunId=$RunId; InstanceId=$InstanceId; Provider=$context.Provider; Changed=$true; NoChange=$false; Status='SUCCEEDED'; OperationId=$journal.OperationId; AutoStart=$AutoStart }
        }
        catch {
            if ($journal) {
                try { $journal.Status='RECOVERY_REQUIRED'; $journal.Recovery.Status='RESUME_STATE_COMMIT'; $journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1; $journal.Recovery.ErrorCode=$_.Exception.Message; $null=Write-LabContainerAutoStartJournal -Journal $journal -Path $journalPath } catch {}
            }
            throw
        }
    }
    finally { if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose() }
    } finally {$featureGuard.ReleaseMutex();$featureGuard.Dispose()}
}
