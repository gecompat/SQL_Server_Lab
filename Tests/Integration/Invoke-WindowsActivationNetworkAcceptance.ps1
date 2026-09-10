#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Adapter-Eigentum mit einer eigenen ausgeschalteten VM und Private-Switch.
.DESCRIPTION
    Kein Internet, kein Gast und keine Lizenzaktivierung. Native Hyper-V-Adapter
    bestaetigen Erfolg, induzierten Fehler, Resume und Fremdobjektschutz.
#>
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$module=Import-Module (Join-Path $PSScriptRoot '../../SqlServerLab.psd1') -Force -PassThru
$root=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-activation-native-'+[guid]::NewGuid().ToString('N'))
$name='activation-native-'+[guid]::NewGuid().ToString('N').Substring(0,12)
$mutex=[Threading.Mutex]::new($false,'Global\SQL_Server_Lab_Runtime_Smoke')
$acquired=$false;$vm=$null;$switch=$null;$ownsRoot=$false;$cleanupFailed=$false
try {
    $acquired=$mutex.WaitOne(0)
    if(-not $acquired){throw 'ACTIVATION_NATIVE_HOST_BUSY'}
    $null=Get-VMHost -ErrorAction Stop
    if((Get-PSDrive -Name ([IO.Path]::GetPathRoot($root).Substring(0,1))).Free -lt 512MB){throw 'ACTIVATION_NATIVE_DISK_RESERVE_REQUIRED'}
    if((Get-VM -Name $name -ErrorAction SilentlyContinue) -or (Get-VMSwitch -Name $name -ErrorAction SilentlyContinue)){throw 'ACTIVATION_NATIVE_NAME_COLLISION'}
    $null=New-Item -ItemType Directory -Path $root;$ownsRoot=$true
    $disk=Join-Path $root 'synthetic.vhdx'
    $null=New-VHD -Path $disk -Dynamic -SizeBytes 64MB
    $vm=New-VM -Name $name -Generation 2 -MemoryStartupBytes 256MB -VHDPath $disk -Path $root
    $switch=New-VMSwitch -Name $name -SwitchType Private
    $run=[guid]::NewGuid().ToString();$scope=[guid]::NewGuid().ToString()
    $notes=& $module {param($Run,$Scope,$Disk);ConvertTo-HyperVLabNotes -RunId $Run -ScopeId $Scope -InstanceId activation-native -ChildVhdxPath $Disk -Lifecycle test -ExpiresAt ([datetime]::UtcNow.AddHours(1).ToString('o'))} $run $scope $disk
    $null=Set-VM -VM $vm -Notes $notes -AutomaticCheckpointsEnabled $false
    $foreign=Add-VMNetworkAdapter -VM $vm -SwitchName $switch.Name -Name SQL_SERVER_LAB_ACTIVATION_TEMP -Passthru
    $lab=[pscustomobject]@{RunDirectory=$root;Run=@{runId=$run;scopeId=$scope};Instance=@{vmName=$name}}
    foreach($mode in @('success','controlled-failure','resume')){
        $own=& $module {param($Lab,$Switch);New-LabWindowsActivationAdapter -Lab $Lab -ExternalSwitch $Switch} $lab $switch
        if(-not $own.Id -or [string]$own.Id -eq [string]$foreign.Id){throw 'ACTIVATION_NATIVE_IDENTITY_FAILED'}
        try {if($mode -eq 'controlled-failure'){throw 'INDUCED_ACTIVATION_STEP_FAILURE'}}
        catch {if($_.Exception.Message -ne 'INDUCED_ACTIVATION_STEP_FAILURE'){throw}}
        finally {
            if($mode -ne 'resume'){& $module {param($Lab);Remove-LabWindowsActivationAdapter -Lab $Lab} $lab}
        }
        if($mode -eq 'resume'){
            $next=& $module {param($Lab,$Switch);New-LabWindowsActivationAdapter -Lab $Lab -ExternalSwitch $Switch} $lab $switch
            if(@(Get-VMNetworkAdapter -VM $vm | Where-Object Id -eq $own.Id).Count){throw 'ACTIVATION_NATIVE_RESUME_STALE_ADAPTER'}
            if(-not $next.Id){throw 'ACTIVATION_NATIVE_RESUME_NEW_ID_REQUIRED'}
            & $module {param($Lab);Remove-LabWindowsActivationAdapter -Lab $Lab} $lab
        }
        $remaining=@(Get-VMNetworkAdapter -VM $vm)
        $preserved=@($remaining | Where-Object {[string]$_.Id -eq [string]$foreign.Id -and [string]$_.SwitchId -eq [string]$switch.Id})
        if($preserved.Count -ne 1 -or @($remaining | Where-Object Name -like 'SQL_SERVER_LAB_ACTIVATION_*').Count -ne 1){throw 'ACTIVATION_NATIVE_FOREIGN_ADAPTER_CHANGED'}
        Write-Host "PASS: $mode entfernt eigene Adapter und bewahrt fremde ID/Switch-Bindung"
    }
}
finally {
    try {
        if($vm){
            $live=Get-VM -Id $vm.Id -ErrorAction SilentlyContinue
            if($live){if($live.Name -ne $name -or $live.State -ne 'Off'){throw 'ACTIVATION_NATIVE_VM_CLEANUP_CONFLICT'};Remove-VM -VM $live -Force}
        }
        if($switch){
            $liveSwitch=Get-VMSwitch -Id $switch.Id -ErrorAction SilentlyContinue
            if($liveSwitch){
                if($liveSwitch.Name -ne $name -or $liveSwitch.SwitchType -ne 'Private' -or @(Get-VM | Get-VMNetworkAdapter | Where-Object SwitchId -eq $switch.Id).Count){throw 'ACTIVATION_NATIVE_SWITCH_CLEANUP_CONFLICT'}
                Remove-VMSwitch -VMSwitch $liveSwitch -Force
            }
        }
        if($ownsRoot){
            $resolved=(Get-Item -LiteralPath $root).FullName
            $boundary=[IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\','/')+[IO.Path]::DirectorySeparatorChar
            if(-not $resolved.StartsWith($boundary,[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetFileName($resolved) -notlike 'sql-lab-activation-native-*' -or @(Get-ChildItem -LiteralPath $resolved -Recurse -Force -Attributes ReparsePoint).Count){throw 'ACTIVATION_NATIVE_ROOT_CLEANUP_CONFLICT'}
            Remove-Item -LiteralPath $resolved -Recurse -Force
        }
    }
    catch {$cleanupFailed=$true;Write-Warning 'ACTIVATION_NATIVE_CLEANUP_FAILED: Eigene Ressourcen fuer Recovery bewahrt.'}
    finally {if($acquired){$mutex.ReleaseMutex()};$mutex.Dispose()}
    if($cleanupFailed){throw 'ACTIVATION_NATIVE_CLEANUP_FAILED'}
}
Write-Host 'WINDOWS ACTIVATION ADAPTER NATIVE: PASS; CLEANUP_SUCCEEDED'
