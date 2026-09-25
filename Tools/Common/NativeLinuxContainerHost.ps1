function Get-NativeLinuxContainerHostDecision {
    param([string]$Provider, $RuntimeInfo, [bool]$ToolAvailable, [bool]$RuntimeReachable,
        [string]$KernelConfig='', [string]$RequiredCgroupVersion='1')
    $reasons=[Collections.Generic.List[string]]::new()
    $cgroup=$null;$rootless=$null
    if(-not $ToolAvailable){$reasons.Add('PROVIDER_TOOL_MISSING')}
    elseif(-not $RuntimeReachable){$reasons.Add('PROVIDER_RUNTIME_UNREACHABLE')}
    elseif($Provider -eq 'docker') {
        if($RuntimeInfo.OSType -ne 'linux'){$reasons.Add('LINUX_RUNTIME_REQUIRED')}
        $cgroup=[string]$RuntimeInfo.CgroupVersion
        $rootless=@($RuntimeInfo.SecurityOptions|Where-Object {$_ -match 'rootless'}).Count -gt 0
        if($RuntimeInfo.MemoryLimit -ne $true -or $RuntimeInfo.PidsLimit -ne $true){$reasons.Add('RESOURCE_CONTROLLERS_UNAVAILABLE')}
    } else {
        if($RuntimeInfo.host.os -ne 'linux'){$reasons.Add('LINUX_RUNTIME_REQUIRED')}
        $cgroup=[string]$RuntimeInfo.host.cgroupVersion
        if(-not $cgroup){$cgroup=[string]$RuntimeInfo.host.cgroupsVersion}
        if($null -eq $RuntimeInfo.host.security.rootless){$reasons.Add('ROOTFUL_STATUS_UNKNOWN')}
        else {$rootless=[bool]$RuntimeInfo.host.security.rootless}
        foreach($controller in @('cpu','memory','pids')){
            if($controller -notin @($RuntimeInfo.host.cgroupControllers)){$reasons.Add('RESOURCE_CONTROLLERS_UNAVAILABLE');break}
        }
    }
    if($RuntimeReachable -and $ToolAvailable){
        $cgroup=$cgroup -replace '^v',''
        if($cgroup -ne $RequiredCgroupVersion){$reasons.Add('CGROUP_VERSION_UNSUPPORTED')}
        if($rootless){$reasons.Add('ROOTFUL_PROVIDER_REQUIRED')}
    }
    if($KernelConfig -match '(?m)^# CONFIG_MEMCG_V1 is not set\s*$'){$reasons.Add('KERNEL_MEMCG_V1_DISABLED')}
    [pscustomobject]@{Contract='SqlServerLab.NativeLinuxContainerHost/1.0';Provider=$Provider;
        Status=$(if($reasons.Count){'BLOCKED'}else{'COMPATIBLE'});Reasons=@($reasons);
        CgroupVersion=$cgroup;Rootless=$rootless;RequiresHyperV=$false;
        SqlLanguageEvidence='NOT_EXECUTED';HostChanges='NONE'}
}

function Assert-NativeLinuxContainerHostStorage {
    param([string]$DataRoot,[string]$MediaRoot,[string]$ExistingDataRoot,[string]$ExistingMediaRoot)
    foreach($path in @($DataRoot,$MediaRoot)){
        if(-not $path.StartsWith('/') -or $path -match '[\r\n]' -or $path -eq '/' -or
            [IO.Path]::GetFullPath($path) -cne $path.TrimEnd('/')){throw 'NATIVE_HOST_ABSOLUTE_LINUX_STORAGE_REQUIRED'}
        $current=$path
        while($current -and $current -ne '/'){
            if((Test-Path -LiteralPath $current) -and ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)){throw 'NATIVE_HOST_STORAGE_LINK_REJECTED'}
            $current=Split-Path $current -Parent
        }
    }
    if($DataRoot -ceq $MediaRoot -or $DataRoot.StartsWith($MediaRoot+'/') -or $MediaRoot.StartsWith($DataRoot+'/')){throw 'NATIVE_HOST_STORAGE_OVERLAP'}
    if(($ExistingDataRoot -and $ExistingDataRoot -cne $DataRoot) -or ($ExistingMediaRoot -and $ExistingMediaRoot -cne $MediaRoot)){throw 'NATIVE_HOST_EXISTING_DEFAULTS_DIFFER: Use the existing roots; migration is a separate operation.'}
}
