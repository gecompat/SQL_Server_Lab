<#
.SYNOPSIS
    Reads a bound direct container autostart plan.
.DESCRIPTION
    Measures and binds one registered container lab without mutating it.
.PARAMETER RunId
    Registered run identifier.
.PARAMETER InstanceId
    Registered instance identifier.
.PARAMETER AutoStart
    Requested on/off policy.
.PARAMETER StateRoot
    Optional managed state root.
.EXAMPLE
    Get-SqlServerLabContainerAutoStartPlan -RunId $runId -InstanceId primary -AutoStart on
.OUTPUTS
    System.Management.Automation.PSCustomObject
#>
function Get-SqlServerLabContainerAutoStartPlan {
    <#
    .SYNOPSIS Produces a bound plan for a direct container autostart change.
    .PARAMETER RunId Registered run to inspect.
    .PARAMETER InstanceId Registered container instance.
    .PARAMETER AutoStart Requested on/off policy.
    .PARAMETER StateRoot Optional managed state root.
    .DESCRIPTION The plan has no runtime identity, local path, port, secret or
    host-login data. Its key authorizes only the matching direct executor call;
    it expires when the measured policy, persisted intent or lifecycle binding
    changes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][ValidateSet('on','off')][string]$AutoStart,
        [string]$StateRoot
    )
    $plan = Get-LabContainerAutoStartApplyPlan -RunId $RunId -InstanceId $InstanceId -AutoStart $AutoStart -StateRoot $StateRoot
    [pscustomobject]@{
        Contract=[pscustomobject]@{Name='SqlServerLab.ContainerAutoStartPlan';Version='1.0'}
        RunId=$RunId;InstanceId=$InstanceId;Provider=[string]$plan.Context.Provider
        Actual=[pscustomobject]@{AutoStart=([string]$plan.Context.CurrentAutoStart).ToUpperInvariant();Lifecycle=if($plan.Context.WasRunning){'RUNNING'}else{'STOPPED'}}
        Desired=[pscustomobject]@{AutoStart=$AutoStart.ToUpperInvariant()}
        NoChange=[bool]$plan.NoChange;ChangeClass=if($plan.NoChange){'no-op'}else{'live'}
        CanApply=$true;MutationAllowed=(-not $plan.NoChange);Preview=[pscustomobject]@{Downtime='NONE';DataImpact='NONE';Recovery='RESUME_STATE_COMMIT'}
        PlanKey=[string]$plan.PlanKey
    }
}
