<#
.SYNOPSIS
    Completes pending Hyper-V autostart state persistence.
.DESCRIPTION
    Verifies the journal target and never repeats Set-VM.
.PARAMETER RunId
    Registered Hyper-V run identifier.
.PARAMETER StateRoot
    Optional managed state root.
.EXAMPLE
    Resume-SqlServerLabHyperVAutoStart -RunId $runId
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Resume-SqlServerLabHyperVAutoStart {
    <#
    .SYNOPSIS Completes persisted state after a verified Hyper-V policy mutation.
    .DESCRIPTION Does not issue a second Set-VM mutation.
    .PARAMETER RunId Registered Hyper-V run with the recovery journal.
    .PARAMETER StateRoot Optional managed state root.
    #>
    [CmdletBinding(SupportsShouldProcess)]param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot)
    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_AutoStart_$($RunId.Replace('-',''))");$acquired=$false
    try {$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not $acquired){throw 'HYPERV_AUTOSTART_LOCK_TIMEOUT'}
        $lab=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $StateRoot;$path=Get-LabHyperVAutoStartJournalPath -RunDirectory $lab.RunDirectory
        if(-not(Test-Path -LiteralPath $path -PathType Leaf)){throw 'HYPERV_AUTOSTART_RECOVERY_JOURNAL_MISSING'}
        $journal=Get-Content -LiteralPath $path -Raw -Encoding utf8|ConvertFrom-Json -Depth 30
        if(-not(($journal|ConvertTo-Json -Depth 30)|Test-Json -SchemaFile (Join-Path $script:SchemasPath 'hyperv-autostart-journal.schema.json') -ErrorAction SilentlyContinue)){throw 'HYPERV_AUTOSTART_JOURNAL_SCHEMA_INVALID'}
        if([string]$journal.RunId-ne$RunId -or [string]$journal.ScopeId-ne[string]$lab.Run.scopeId -or [string]$journal.InstanceId-ne[string]$lab.Instance.id -or [string]$journal.Status-cnotin@('POLICY_MUTATED','RECOVERY_REQUIRED')){throw 'HYPERV_AUTOSTART_RECOVERY_JOURNAL_INVALID'}
        $plan=Get-LabHyperVAutoStartApplyPlan -RunId $RunId -AutoStart ([string]$journal.Target.AutoStart) -StateRoot $StateRoot
        if([string]$plan.Managed.VM.Id-ne[string]$journal.Runtime.VMId -or [string]$plan.Managed.VM.State-ne[string]$journal.Before.State -or [string]$plan.Managed.VM.AutomaticStartAction-ne[string]$journal.Target.AutomaticStartAction){throw 'HYPERV_AUTOSTART_RECOVERY_READBACK_CHANGED'}
        if(-not $PSCmdlet.ShouldProcess([string]$lab.Instance.vmName,'Autostart-Statepersistenz wiederaufnehmen')){return}
        Complete-LabHyperVAutoStartState -Plan $plan -Journal $journal;$journal.Status='STATE_COMMITTED';$journal.Recovery.Status='NOT_REQUIRED';$null=Write-LabHyperVAutoStartJournal $journal $path;$journal.Status='COMPLETED';$null=Write-LabHyperVAutoStartJournal $journal $path
        [pscustomobject]@{RunId=$RunId;InstanceId=$lab.Instance.id;Provider='hyperv';Changed=$true;Status='RECOVERY_SUCCEEDED';OperationId=$journal.OperationId}
    } finally {if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
