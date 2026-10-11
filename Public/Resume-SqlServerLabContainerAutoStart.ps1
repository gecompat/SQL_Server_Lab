<#
.SYNOPSIS
    Completes pending container autostart state persistence.
.DESCRIPTION
    Verifies the journal target and never repeats the provider update.
.PARAMETER RunId
    Registered run identifier.
.PARAMETER InstanceId
    Registered instance identifier.
.PARAMETER StateRoot
    Optional managed state root.
.EXAMPLE
    Resume-SqlServerLabContainerAutoStart -RunId $runId -InstanceId primary
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Resume-SqlServerLabContainerAutoStart {
    <#
.SYNOPSIS
    Completes only the persisted state portion of a verified direct autostart change.
.PARAMETER RunId
    Registered run with the recovery journal.
.PARAMETER InstanceId
    Registered container instance.
.PARAMETER StateRoot
    Optional managed state root.
    .DESCRIPTION Never repeats `update --restart`. Recovery succeeds only when
    the exact original container still has the journal target policy and its
    captured power state; otherwise the journal remains visible for review.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][string]$InstanceId,[string]$StateRoot)
    if (-not $StateRoot) { $StateRoot=Get-LabStateRoot };$StateRoot=Get-LabCanonicalResourceRoot -StateRoot $StateRoot
    $mutex=[Threading.Mutex]::new($false,(Get-LabContainerResourceLockName -StateRoot $StateRoot -RunId $RunId));$acquired=$false
    try {
        try { $acquired=$mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $acquired=$true }
        if(-not $acquired){throw 'AUTOSTART_APPLY_BUSY'}
        $context=Get-LabContainerReconcileContext -RunId $RunId -InstanceId $InstanceId -StateRoot $StateRoot
        $path=Get-LabContainerAutoStartJournalPath -RunDirectory $context.RunDirectory
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'AUTOSTART_APPLY_RECOVERY_JOURNAL_MISSING'}
        $journal=Get-Content -LiteralPath $path -Raw -Encoding utf8|ConvertFrom-Json -Depth 60;Assert-LabContainerAutoStartJournal -Journal $journal
        if([string]$journal.RunId-ne$RunId -or [string]$journal.ScopeId-ne[string]$context.Run.scopeId -or [string]$journal.InstanceId-ne$InstanceId -or [string]$journal.Provider-ne[string]$context.Provider -or [string]$journal.Status-cnotin@('POLICY_MUTATED','RECOVERY_REQUIRED')){throw 'AUTOSTART_APPLY_RECOVERY_JOURNAL_INVALID'}
        if([string]$context.ContainerId-ne[string]$journal.Runtime.OriginalId -or [bool]$context.WasRunning-ne[bool]$journal.Before.Running -or [string]$context.CurrentRestartPolicy-ne[string]$journal.Target.RestartPolicy){throw 'AUTOSTART_APPLY_RECOVERY_READBACK_CHANGED'}
        if(-not $PSCmdlet.ShouldProcess($context.ContainerName,'Autostart-Statepersistenz wiederaufnehmen')){return}
        $context.Instance|Add-Member -NotePropertyName autostart -NotePropertyValue ([string]$journal.Target.AutoStart) -Force
        $desired=@($context.Run.metadata.desiredState.Instances|Where-Object{[string]$_.Id -ceq $InstanceId -and [string]$_.Provider -ceq [string]$context.Provider})
        if($desired.Count-ne1){throw 'AUTOSTART_APPLY_DESIRED_INSTANCE_INVALID'};$desired[0].AutoStart=[string]$journal.Target.AutoStart
        Write-LabArtifactJsonAtomic -Path $context.ConnectionPath -InputObject $context.Connection
        Write-LabArtifactJsonAtomic -Path (Join-Path $context.RunDirectory 'run-state.json') -InputObject $context.Run
        if((Get-LabPersistedDesiredState -RunId $RunId -StateRoot $StateRoot).Status-ne'VALID'){throw 'AUTOSTART_APPLY_DESIRED_STATE_COMMIT_INVALID'}
        $journal.Status='STATE_COMMITTED';$journal.Recovery.Status='NOT_REQUIRED';$null=Write-LabContainerAutoStartJournal -Journal $journal -Path $path
        $journal.Status='COMPLETED';$null=Write-LabContainerAutoStartJournal -Journal $journal -Path $path
        [pscustomobject]@{RunId=$RunId;InstanceId=$InstanceId;Provider=$context.Provider;Changed=$true;Status='RECOVERY_SUCCEEDED';OperationId=$journal.OperationId}
    } finally {if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
