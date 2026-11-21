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
    .PARAMETER ExpectedRecoveryOperationId Operation shown by the operator's recovery preview.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string]$RunId,[string]$StateRoot,[guid]$ExpectedRecoveryOperationId)
    $mutex=[Threading.Mutex]::new($false,"Global\SQL_Server_Lab_HyperV_AutoStart_$($RunId.Replace('-',''))");$acquired=$false
    try {$acquired=$mutex.WaitOne([TimeSpan]::FromMinutes(5));if(-not $acquired){throw 'HYPERV_AUTOSTART_LOCK_TIMEOUT'}
        $parameters = @{ RunId = $RunId; StateRoot = $StateRoot }
        if ($PSBoundParameters.ContainsKey('ExpectedRecoveryOperationId')) { $parameters.ExpectedRecoveryOperationId = $ExpectedRecoveryOperationId }
        $recovery = Get-LabHyperVAutoStartRecoveryPlan @parameters
        $plan = $recovery.Plan
        $journal = $recovery.Journal
        $lab = $plan.Lab
        $path = Get-LabHyperVAutoStartJournalPath -RunDirectory $lab.RunDirectory
        if(-not $PSCmdlet.ShouldProcess([string]$lab.Instance.vmName,'Autostart-Statepersistenz wiederaufnehmen')){return}
        $null = Assert-LabHyperVResourceMigrationLifecycleAllowed -RunId $RunId -Operation 'SET_AUTOSTART' -StateRoot $plan.Lab.StateRoot
        Assert-LabWindowsPoolMutationAllowed -RunId $RunId -StateRoot $plan.Lab.StateRoot -InvalidateEvidence
        Complete-LabHyperVAutoStartState -Plan $plan -Journal $journal;$journal.Status='STATE_COMMITTED';$journal.Recovery.Status='NOT_REQUIRED';$null=Write-LabHyperVAutoStartJournal $journal $path;$journal.Status='COMPLETED';$null=Write-LabHyperVAutoStartJournal $journal $path
        [pscustomobject]@{RunId=$RunId;InstanceId=$lab.Instance.id;Provider='hyperv';Changed=$true;Status='RECOVERY_SUCCEEDED';OperationId=$journal.OperationId}
    } finally {if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
}
