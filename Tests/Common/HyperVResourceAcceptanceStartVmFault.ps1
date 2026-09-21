<#
.SYNOPSIS
    Installs a narrowly scoped, acceptance-only Start-VM fault wrapper.
.DESCRIPTION
    This helper is test support.  It never changes the product module and is
    only installed into an already loaded module for one owned native
    acceptance operation.  The wrapper consumes one exact VM-id match before
    delegating all other calls to the captured original command.
#>

function New-HyperVResourceAcceptanceStartVmFaultTarget {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$RunId,
        [Parameter(Mandatory)][string]$ScopeId,
        [Parameter(Mandatory)][string]$InstanceId,
        [Parameter(Mandatory)][string]$VMId
    )
    [PSCustomObject]@{
        RunId=$RunId; ScopeId=$ScopeId; InstanceId=$InstanceId; VMId=$VMId
        Armed=$true; Used=$false
    }
}

function Install-HyperVResourceAcceptanceStartVmFaultWrapper {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module,
        [Parameter(Mandatory)]$Target,
        [Parameter(Mandatory)][string]$ExpectedRunId,
        [Parameter(Mandatory)][string]$ExpectedScopeId,
        [Parameter(Mandatory)][string]$ExpectedInstanceId,
        [Parameter(Mandatory)][string]$ExpectedVMId,
        [Parameter(Mandatory)][scriptblock]$OriginalStartVm
    )
    foreach($name in @('RunId','ScopeId','InstanceId','VMId','Armed','Used')) {
        if(-not $Target.PSObject.Properties[$name]) { throw "HYPERV_RESOURCE_ACCEPTANCE_FAULT_TARGET_PROPERTY_MISSING: $name" }
    }
    if([string]$Target.RunId -cne $ExpectedRunId -or [string]$Target.ScopeId -cne $ExpectedScopeId -or
       [string]$Target.InstanceId -cne $ExpectedInstanceId -or [string]$Target.VMId -cne $ExpectedVMId -or
       -not [bool]$Target.Armed -or [bool]$Target.Used) {
        throw 'HYPERV_RESOURCE_ACCEPTANCE_FAULT_TARGET_IDENTITY_MISMATCH'
    }

    & $Module {
        param($FaultTarget,$Original)
        if(Test-Path -LiteralPath Function:\Start-VM) { throw 'HYPERV_RESOURCE_ACCEPTANCE_START_VM_WRAPPER_PRESENT' }
        $script:hyperVResourceAcceptanceStartVmFaultTarget=$FaultTarget
        $script:hyperVResourceAcceptanceOriginalStartVm=$Original
        function script:Start-VM {
            [CmdletBinding()]
            param([Parameter(Mandatory)]$VM)
            $fault=$script:hyperVResourceAcceptanceStartVmFaultTarget
            if($fault -and [bool]$fault.Armed -and -not [bool]$fault.Used -and [string]$VM.Id -ceq [string]$fault.VMId) {
                $fault.Armed=$false
                $fault.Used=$true
                throw 'HYPERV_RESOURCE_RECONCILE_ACCEPTANCE_INJECTED_PRESTART_FAILURE'
            }
            & $script:hyperVResourceAcceptanceOriginalStartVm -VM $VM
        }
        $script:hyperVResourceAcceptanceStartVmFaultWrapper=(Get-Command Start-VM -CommandType Function -ErrorAction Stop).ScriptBlock
    } $Target $OriginalStartVm
    return $Target
}

function Remove-HyperVResourceAcceptanceStartVmFaultWrapper {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module)
    & $Module {
        if(-not (Test-Path -LiteralPath Function:\Start-VM)) { throw 'HYPERV_RESOURCE_ACCEPTANCE_START_VM_WRAPPER_MISSING' }
        $current=(Get-Command Start-VM -CommandType Function -ErrorAction Stop).ScriptBlock
        if($current -ne $script:hyperVResourceAcceptanceStartVmFaultWrapper) { throw 'HYPERV_RESOURCE_ACCEPTANCE_START_VM_WRAPPER_IDENTITY_MISMATCH' }
        Remove-Item -LiteralPath Function:\Start-VM -Force
        Remove-Variable -Name hyperVResourceAcceptanceStartVmFaultTarget -Scope Script -Force
        Remove-Variable -Name hyperVResourceAcceptanceOriginalStartVm -Scope Script -Force
        Remove-Variable -Name hyperVResourceAcceptanceStartVmFaultWrapper -Scope Script -Force
    }
}

function Get-HyperVResourceAcceptanceStartVmFaultWrapperState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Management.Automation.PSModuleInfo]$Module)
    & $Module {
        [PSCustomObject]@{
            WrapperPresent=[bool](Test-Path -LiteralPath Function:\Start-VM)
            Target=$script:hyperVResourceAcceptanceStartVmFaultTarget
        }
    }
}
