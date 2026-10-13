#Requires -Version 7.2
# Creates an isolated, run-owned differencing VM from an explicitly approved off source.
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$SourceVMName,
    [Parameter(Mandatory)][string]$StateRoot,
    [switch]$UseExplicitManagedSource
)
$ErrorActionPreference='Stop'
$repo=[IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
$module=Import-Module (Join-Path $repo 'SqlServerLab.psd1') -Force -PassThru
$runId=$null;$primary=$null;$cleanup=$null
try {
    $created=& $module {
        param($Source,$Root,[bool]$UseExplicitManagedSource)
        if($UseExplicitManagedSource){
            $vm=Get-VM -Name $Source -ErrorAction Stop
            $disks=@(Get-VMHardDiskDrive -VMName $Source -ErrorAction Stop|Where-Object{$_.Path -and [IO.Path]::GetExtension([string]$_.Path) -ieq '.vhdx'})
            if([string]$vm.State -ne 'Off' -or [int]$vm.Generation -ne 2 -or $disks.Count -ne 1 -or -not(Test-Path -LiteralPath $disks[0].Path -PathType Leaf)){throw 'HYPERV_AUTOSTART_ACCEPTANCE_SOURCE_INVALID'}
            $script:explicitAcceptanceSource=[pscustomobject]@{VMName=$Source;SourceVhdxPath=[IO.Path]::GetFullPath([string]$disks[0].Path);LicenseNotice='Explicit operator authorization for isolated acceptance clone.'}
            function script:Get-HyperVExistingVmLabSource { @($script:explicitAcceptanceSource) }
        }
        New-HyperVLabEnvironmentFromExistingVm -SourceVMName $Source -LabName 'p1-autostart-acceptance' -InstanceId primary `
            -MemoryStartupMB 512 -ProcessorCount 1 -AutoStart off -Isolated -ConfirmSourceLicense -StateRoot $Root
    } $SourceVMName $StateRoot ([bool]$UseExplicitManagedSource)
    $runId=[string]$created.RunId
    $result=& $module {
        param($RunId,$Root)
        $lab=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
        $before=Get-VM -Name ([string]$lab.Instance.vmName) -ErrorAction Stop
        if([string]$before.State -ne 'Off' -or [string]$before.AutomaticStartAction -ne 'Nothing'){throw 'HYPERV_AUTOSTART_ACCEPTANCE_INITIAL_STATE'}
        $on=Get-SqlServerLabHyperVAutoStartPlan -RunId $RunId -AutoStart on -StateRoot $Root
        $onResult=Set-SqlServerLabHyperVAutoStart -RunId $RunId -AutoStart on -ExpectedAutoStartPlanKey $on.PlanKey -StateRoot $Root -Confirm:$false
        $afterOn=Get-VM -Name ([string]$lab.Instance.vmName) -ErrorAction Stop
        if([string]$afterOn.Id -ne [string]$before.Id -or [string]$afterOn.State -ne [string]$before.State -or [string]$afterOn.AutomaticStartAction -ne 'Start'){throw 'HYPERV_AUTOSTART_ACCEPTANCE_ON_READBACK'}
        $off=Get-SqlServerLabHyperVAutoStartPlan -RunId $RunId -AutoStart off -StateRoot $Root
        $offResult=Set-SqlServerLabHyperVAutoStart -RunId $RunId -AutoStart off -ExpectedAutoStartPlanKey $off.PlanKey -StateRoot $Root -Confirm:$false
        $afterOff=Get-VM -Name ([string]$lab.Instance.vmName) -ErrorAction Stop
        if([string]$afterOff.Id -ne [string]$before.Id -or [string]$afterOff.State -ne [string]$before.State -or [string]$afterOff.AutomaticStartAction -ne 'Nothing'){throw 'HYPERV_AUTOSTART_ACCEPTANCE_OFF_READBACK'}
        [pscustomobject]@{RunId=$RunId;IdentityPreserved=$true;PowerStatePreserved=$true;On=$onResult.Status;Off=$offResult.Status}
    } $runId $StateRoot
    $result|ConvertTo-Json -Depth 5
}
catch {$primary=$_;throw}
finally {
    if($runId){
        try {$cleanup=Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false;if($cleanup.Status -ne 'REMOVED'){throw 'HYPERV_AUTOSTART_ACCEPTANCE_CLEANUP_UNCONFIRMED'}}
        catch {if(-not $primary){throw}}
    }
    if($module){Remove-Module $module -Force -ErrorAction SilentlyContinue}
}
