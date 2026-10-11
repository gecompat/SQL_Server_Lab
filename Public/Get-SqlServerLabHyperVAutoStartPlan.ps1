<#
.SYNOPSIS
    Reads a bound direct Hyper-V autostart plan.
.DESCRIPTION
    Measures and binds one registered Hyper-V lab without mutation.
.PARAMETER RunId
    Registered run identifier.
.PARAMETER AutoStart
    Requested on/off policy.
.PARAMETER StateRoot
    Optional managed state root.
.EXAMPLE
    Get-SqlServerLabHyperVAutoStartPlan -RunId $runId -AutoStart on
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Get-SqlServerLabHyperVAutoStartPlan {
    <#
    .SYNOPSIS Produces a bound plan for a direct Hyper-V autostart change.
    .PARAMETER RunId Registered Hyper-V run to inspect.
    .PARAMETER AutoStart Requested on/off policy.
    .PARAMETER StateRoot Optional managed state root.
    .DESCRIPTION The public result intentionally excludes the VM GUID and host
    details. Its key can only be used for the same run, measured VM state and
    requested target by the corresponding executor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][ValidateSet('on','off')][string]$AutoStart,
        [string]$StateRoot
    )

    $plan = Get-LabHyperVAutoStartApplyPlan -RunId $RunId -AutoStart $AutoStart -StateRoot $StateRoot
    [pscustomobject]@{
        Contract = [pscustomobject]@{ Name = 'SqlServerLab.HyperVAutoStartPlan'; Version = '1.0' }
        RunId = $RunId; InstanceId = [string]$plan.Lab.Instance.id; Provider = 'hyperv'
        Actual = [pscustomobject]@{
            AutoStart = $plan.CurrentAutoStart.ToUpperInvariant()
            Lifecycle = if ([string]$plan.Managed.VM.State -eq 'Running') { 'RUNNING' } else { 'STOPPED' }
        }
        Desired = [pscustomobject]@{ AutoStart = $AutoStart.ToUpperInvariant() }
        NoChange = [bool]$plan.NoChange
        ChangeClass = if ($plan.NoChange) { 'no-op' } else { 'live' }
        CanApply = $true; MutationAllowed = (-not $plan.NoChange)
        Preview = [pscustomobject]@{ Downtime = 'NONE'; DataImpact = 'NONE'; Recovery = 'RESUME_STATE_COMMIT' }
        PlanKey = [string]$plan.PlanKey
    }
}
