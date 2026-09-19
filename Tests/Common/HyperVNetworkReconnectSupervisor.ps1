# Testinterne Prozessaufsicht; der Aufrufer haelt den Runtime-Hostlock.
function Wait-HyperVNetworkAcceptanceChild {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Process,[ValidateRange(1,10800)][int]$TimeoutSeconds=5400)
    $terminated=$false
    try {
        if($Process.WaitForExit($TimeoutSeconds * 1000)){
            $terminated=$true
            return [pscustomobject]@{Terminated=$true;TimedOut=$false;ExitCode=$Process.ExitCode}
        }
        $Process.Kill($true)
        $terminated=$Process.WaitForExit(30000)
        [pscustomobject]@{Terminated=$terminated;TimedOut=$true;ExitCode=$null}
    }
    catch {
        # Unknown termination must never race cleanup against a live creator.
        try { $Process.Kill($true);$terminated=$Process.WaitForExit(30000) } catch { $terminated=$false }
        [pscustomobject]@{Terminated=$terminated;TimedOut=$false;ExitCode=$null}
    }
}

function Remove-HyperVNetworkAcceptanceOwnedRun {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Module,[Parameter(Mandatory)][string]$OperationId,
        [Parameter(Mandatory)][guid]$SourceRunId,[Parameter(Mandatory)][string]$StateRoot)
    & $Module {
        param($Op,$Source,$Root)
        $owned=Get-LabOperationOwnedRun -OperationId $Op -StateRoot $Root
        if(-not $owned){return}
        if([string]$owned.runId -eq $Source.ToString() -or
            [string]$owned.metadata.workflowOperationId -cne $Op -or
            [string]$owned.metadata.sourceRunId -ine $Source.ToString() -or
            [string]$owned.metadata.workflowKind -ne 'hyperv-lab'){
            throw 'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_OWNERSHIP_INVALID'
        }
        $id=[guid]::Parse([string]$owned.runId)
        $directory=Join-Path (Join-Path $Root 'runs') $id.ToString()
        $plan=Get-CleanupPlan -RunDir $directory
        if([string]$plan.runId -ine $id.ToString() -or [string]$plan.scopeId -ine [string]$owned.scopeId -or
            @($plan.steps | Where-Object { $_.provider -ne 'hyperv' -or $_.resourceType -notin @('vm','vhdx','ipam-lease') }).Count){
            throw 'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_PLAN_INVALID'
        }
        $paths=@($plan.steps | Where-Object resourceType -eq 'vhdx' | ForEach-Object resourceId)
        foreach($path in $paths){
            if(-not(Test-HyperVPathWithinRunDirectory -Path $path -RunDirectory $directory)){
                throw 'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_PATH_INVALID'
            }
        }
        $vmIds=@()
        foreach($step in @($plan.steps | Where-Object resourceType -eq 'vm')){
            $managed=Get-HyperVManagedVM -VMName ([string]$step.resourceId) -ExpectedRunId $id.ToString() -ExpectedScopeId ([string]$owned.scopeId)
            if($managed){$vmIds+= $managed.VM.Id}
        }
        $cleanup=Remove-SqlServerLab -RunId $id.ToString() -StateRoot $Root -Force -Confirm:$false
        if([string]$cleanup.Status -notin @('REMOVED','COMPLETED','ALREADY_REMOVED')){throw 'HYPERV_NETWORK_ACCEPTANCE_CLEANUP_FAILED'}
        foreach($vmId in $vmIds){if(Get-VM -Id $vmId -ErrorAction SilentlyContinue){throw 'HYPERV_NETWORK_ACCEPTANCE_VM_REMAINS'}}
        foreach($path in $paths){if(Test-Path -LiteralPath $path){throw 'HYPERV_NETWORK_ACCEPTANCE_VHDX_REMAINS'}}
    } $OperationId $SourceRunId $StateRoot
}
