<#
.SYNOPSIS
    Changes a registered Hyper-V automatic start action in place.
.DESCRIPTION
    Applies only a matching bound plan and records recovery state.
.PARAMETER RunId
    Registered Hyper-V run identifier.
.PARAMETER AutoStart
    Requested on/off policy.
.PARAMETER ExpectedAutoStartPlanKey
    Key returned by the plan.
.PARAMETER StateRoot
    Optional managed state root.
.EXAMPLE
    Set-SqlServerLabHyperVAutoStart -RunId $runId -AutoStart on -ExpectedAutoStartPlanKey $plan.PlanKey
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Set-SqlServerLabHyperVAutoStart {
    <#
    .SYNOPSIS Changes a registered Hyper-V lab's automatic start action in place.
    .DESCRIPTION Uses a fresh bound plan, journal and readback without changing VM identity or power state.
    .PARAMETER RunId Registered Hyper-V run to change.
    .PARAMETER AutoStart Requested on/off policy.
    .PARAMETER ExpectedAutoStartPlanKey Key returned by the fresh plan.
    .PARAMETER StateRoot Optional managed state root.
    #>
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][string]$RunId,[Parameter(Mandatory)][ValidateSet('on','off')][string]$AutoStart,[Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}$')][string]$ExpectedAutoStartPlanKey,[string]$StateRoot)
    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_AutoStart_$($RunId.Replace('-',''))");$acquired=$false;$journal=$null;$path=$null
    try { $acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not $acquired){throw 'HYPERV_AUTOSTART_LOCK_TIMEOUT'}
        $plan=Get-LabHyperVAutoStartApplyPlan -RunId $RunId -AutoStart $AutoStart -StateRoot $StateRoot
        if($plan.PlanKey-ne$ExpectedAutoStartPlanKey){throw 'HYPERV_AUTOSTART_STALE_OR_UNAVAILABLE: Vorschau erneut lesen.'}
        if($plan.NoChange){return [pscustomobject]@{RunId=$RunId;InstanceId=$plan.Lab.Instance.id;Provider='hyperv';Changed=$false;Status='NO_OP'}}
        if(-not $PSCmdlet.ShouldProcess([string]$plan.Lab.Instance.vmName,"Autostart auf '$AutoStart' ändern")){return}
        $path=Get-LabHyperVAutoStartJournalPath -RunDirectory $plan.Lab.RunDirectory;$target=if($AutoStart-eq'on'){'Start'}else{'Nothing'}
        $journal=[pscustomobject]@{ContractVersion='SqlServerLab.HyperVAutoStartJournal/1.0';OperationId=[guid]::NewGuid().ToString('D');RunId=$RunId;ScopeId=[string]$plan.Lab.Run.scopeId;InstanceId=[string]$plan.Lab.Instance.id;Provider='hyperv';Status='PREPARED';Before=[pscustomobject]@{AutoStart=$plan.CurrentAutoStart;AutomaticStartAction=[string]$plan.Managed.VM.AutomaticStartAction;State=[string]$plan.Managed.VM.State;PersistedAutoStart=[string]$plan.DesiredInstance.AutoStart};Target=[pscustomobject]@{AutoStart=$AutoStart;AutomaticStartAction=$target};Runtime=[pscustomobject]@{VMId=[string]$plan.Managed.VM.Id};Recovery=[pscustomobject]@{Status='RESUME_STATE_COMMIT';Attempts=0;ErrorCode=$null};UpdatedAt=Get-LabTimestamp};$null=Write-LabHyperVAutoStartJournal $journal $path
        $null=Set-VM -VM $plan.Managed.VM -AutomaticStartAction $target -ErrorAction Stop;$journal.Status='POLICY_MUTATED';$null=Write-LabHyperVAutoStartJournal $journal $path
        Complete-LabHyperVAutoStartState -Plan $plan -Journal $journal;$journal.Status='STATE_COMMITTED';$journal.Recovery.Status='NOT_REQUIRED';$null=Write-LabHyperVAutoStartJournal $journal $path;$journal.Status='COMPLETED';$null=Write-LabHyperVAutoStartJournal $journal $path
        [pscustomobject]@{RunId=$RunId;InstanceId=$plan.Lab.Instance.id;Provider='hyperv';Changed=$true;Status='SUCCEEDED';OperationId=$journal.OperationId;AutoStart=$AutoStart}
    } catch {if($journal){try{$journal.Status='RECOVERY_REQUIRED';$journal.Recovery.Attempts=[int]$journal.Recovery.Attempts+1;$journal.Recovery.ErrorCode=$_.Exception.Message;$null=Write-LabHyperVAutoStartJournal $journal $path}catch{}};throw} finally {if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
