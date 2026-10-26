# Reuse the actual typed OS/cgroup/rootful classifier; this file adds no second
# compatibility table. The private source contains function definitions only.
. (Join-Path $PSScriptRoot '../../Private/ContainerImageArtifact.ps1')

function Get-NativeLinuxControllerEvidence {
    param([ValidateSet('docker','podman')][string]$Provider,$RuntimeInfo)
    $required=if($Provider -ceq 'docker'){@('memory','pids')}else{@('cpu','memory','pids')}
    $available=[Collections.Generic.List[string]]::new()
    $missing=[Collections.Generic.List[string]]::new()
    $unknown=[Collections.Generic.List[string]]::new()
    if($Provider -ceq 'docker') {
        foreach($pair in @(@('memory','MemoryLimit'),@('pids','PidsLimit'))) {
            $property=if($RuntimeInfo -is [pscustomobject]){$RuntimeInfo.PSObject.Properties[$pair[1]]}else{$null}
            if(-not $property -or $property.Value -isnot [bool]){$unknown.Add($pair[0])}
            elseif($property.Value){$available.Add($pair[0])}else{$missing.Add($pair[0])}
        }
    } else {
        $hostProperty=if($RuntimeInfo -is [pscustomobject]){$RuntimeInfo.PSObject.Properties['host']}else{$null}
        $property=if($hostProperty -and $hostProperty.Value -is [pscustomobject]){
            $hostProperty.Value.PSObject.Properties['cgroupControllers']
        }else{$null}
        $valid=$property -and $property.Value -is [array] -and $property.Value.Count -le 32
        if($valid){$valid=@($property.Value|Where-Object {$_ -isnot [string] -or $_ -cnotmatch '^[a-z][a-z0-9_]{0,31}$'}).Count -eq 0}
        if(-not $valid){foreach($name in $required){$unknown.Add($name)}}
        else {foreach($name in $required){if($name -cin $property.Value){$available.Add($name)}else{$missing.Add($name)}}}
    }
    $status=if($missing.Count){'MISSING'}elseif($unknown.Count){'UNKNOWN'}else{'AVAILABLE'}
    [pscustomobject]@{Status=$status;Required=$required;Available=@($available);Missing=@($missing);Unknown=@($unknown);
        Source='SELECTED_PROVIDER_INFO';Scope='CONTROLLER_ADVERTISEMENT_NOT_DELEGATION_OR_WRITE_TEST'}
}

function Test-NativeLinuxPositiveInteger {
    param($Value)
    ($Value -is [int] -or $Value -is [long] -or $Value -is [uint32] -or $Value -is [uint64]) -and $Value -gt 0
}

function Get-NativeLinuxCapacityEvidence {
    param([ValidateSet('docker','podman')][string]$Provider,$RuntimeInfo,$Requirements)
    $memory='NOT_CHECKED';$cpu='NOT_CHECKED';$requiredMemory=$null;$requiredCpu=$null
    if($null -ne $Requirements) {
        if($Requirements -isnot [pscustomobject] -or -not $Requirements.PSObject.Properties['maxMemoryMB'] -or
            -not $Requirements.PSObject.Properties['maxCpus'] -or -not (Test-NativeLinuxPositiveInteger $Requirements.maxMemoryMB) -or
            -not (Test-NativeLinuxPositiveInteger $Requirements.maxCpus) -or
            $Requirements.maxMemoryMB -gt 1048576 -or $Requirements.maxCpus -gt 1024){throw 'NATIVE_HOST_RESOURCE_PROFILE_INVALID'}
        $requiredMemory=[long]$Requirements.maxMemoryMB;$requiredCpu=[long]$Requirements.maxCpus
        $hostProperty=if($RuntimeInfo -is [pscustomobject]){$RuntimeInfo.PSObject.Properties['host']}else{$null}
        $source=if($Provider -ceq 'docker'){$RuntimeInfo}elseif($hostProperty){$hostProperty.Value}else{$null}
        $memoryProperty=if($source -is [pscustomobject]){$source.PSObject.Properties[$(if($Provider -ceq 'docker'){'MemTotal'}else{'memTotal'})]}else{$null}
        $cpuProperty=if($source -is [pscustomobject]){$source.PSObject.Properties[$(if($Provider -ceq 'docker'){'NCPU'}else{'cpus'})]}else{$null}
        $memory=if(-not $memoryProperty -or -not(Test-NativeLinuxPositiveInteger $memoryProperty.Value)){'UNKNOWN'}
            elseif($memoryProperty.Value -ge $requiredMemory*1MB){'CAPACITY_SUFFICIENT'}else{'CAPACITY_INSUFFICIENT'}
        $cpu=if(-not $cpuProperty -or -not(Test-NativeLinuxPositiveInteger $cpuProperty.Value)){'UNKNOWN'}
            elseif($cpuProperty.Value -ge $requiredCpu){'CAPACITY_SUFFICIENT'}else{'CAPACITY_INSUFFICIENT'}
    }
    # Real inventory values remain private. Totals are not free/reserved capacity.
    [pscustomobject]@{MemoryStatus=$memory;CpuStatus=$cpu;RequiredMemoryMB=$requiredMemory;RequiredCpus=$requiredCpu;
        Scope='ENGINE_TOTAL_CAPACITY_ONLY';FreeMemory='NOT_CHECKED';Reservation='NOT_CHECKED';Source='SELECTED_PROVIDER_INFO'}
}

function Get-NativeLinuxSharedKernelEvidence {
    param([ValidateSet('NOT_CHECKED','AVAILABLE','MISSING','UNKNOWN')][string]$MemoryV1='NOT_CHECKED',
        [ValidateSet('UNKNOWN_PROVIDER_BACKEND','SELECTED_WSL_DISTRIBUTION')][string]$Context='UNKNOWN_PROVIDER_BACKEND')
    [pscustomobject]@{Context=$Context;MemoryV1=$MemoryV1;ProviderKernelBinding='NOT_CHECKED';
        ParallelWorkloads='NOT_CHECKED';IsolationProven=$false;ReasonCode='SHARED_KERNEL_COMPATIBILITY_UNASSESSED';
        Scope='NO_DISTRIBUTION_NAME_PROVES_KERNEL_INDEPENDENCE'}
}

function Get-NativeLinuxKernelMemoryV1Evidence {
    param([string]$KernelConfig)
    if(-not $KernelConfig){return 'NOT_CHECKED'}
    $missing=$KernelConfig -cmatch '(?m)^# CONFIG_MEMCG_V1 is not set\s*$'
    $available=$KernelConfig -cmatch '(?m)^CONFIG_MEMCG_V1=y\s*$'
    if($missing -and -not $available){return 'MISSING'}
    if($available -and -not $missing){return 'AVAILABLE'}
    return 'UNKNOWN'
}

function Get-NativeLinuxContainerHostDecision {
    param([ValidateSet('docker','podman')][string]$Provider,$RuntimeInfo,[bool]$ToolAvailable,[bool]$RuntimeReachable,
        [string]$KernelConfig='',[ValidateSet('1','2')][string]$RequiredCgroupVersion='1',$ResourceRequirements,
        [ValidateSet('2019','2022','2025')][string]$SqlVersion='2022')
    # Malformed JSON is an unknown observation, never a native fallback.
    $classifierInfo=if($RuntimeInfo -is [pscustomobject]){$RuntimeInfo}else{[pscustomobject]@{}}
    $base=Get-LabExternalRuntimeHostCapability -Provider $Provider -SqlVersion $SqlVersion -RuntimeInfo $classifierInfo `
        -ToolAvailable $ToolAvailable -RuntimeReachable $RuntimeReachable -RequiredCgroupVersion $RequiredCgroupVersion
    $reasons=[Collections.Generic.List[string]]::new()
    if($base.ReasonCode -cne 'NONE'){$reasons.Add($base.ReasonCode)}
    $status=if($base.Status -ceq 'READY'){'COMPATIBLE'}elseif($base.Status -ceq 'UNKNOWN'){'UNKNOWN'}else{'BLOCKED'}
    $controllers=$null;$capacity=$null
    if($ToolAvailable -and $RuntimeReachable) {
        $controllers=Get-NativeLinuxControllerEvidence $Provider $RuntimeInfo
        $capacity=Get-NativeLinuxCapacityEvidence $Provider $RuntimeInfo $ResourceRequirements
        if($controllers.Status -ceq 'MISSING'){$reasons.Add('RESOURCE_CONTROLLERS_UNAVAILABLE');$status='BLOCKED'}
        elseif($controllers.Status -ceq 'UNKNOWN'){
            $reasons.Add('RESOURCE_CONTROLLERS_UNKNOWN');if($status -ceq 'COMPATIBLE'){$status='UNKNOWN'}
        }
        if('CAPACITY_INSUFFICIENT' -cin @($capacity.MemoryStatus,$capacity.CpuStatus)) {
            $reasons.Add('RESOURCE_PROFILE_CAPACITY_INSUFFICIENT');$status='BLOCKED'
        } elseif('UNKNOWN' -cin @($capacity.MemoryStatus,$capacity.CpuStatus)) {
            $reasons.Add('RESOURCE_PROFILE_CAPACITY_UNKNOWN');if($status -ceq 'COMPATIBLE'){$status='UNKNOWN'}
        }
    }
    $memoryV1=Get-NativeLinuxKernelMemoryV1Evidence $KernelConfig
    if($RequiredCgroupVersion -ceq '1' -and $memoryV1 -ceq 'MISSING'){$reasons.Add('KERNEL_MEMCG_V1_DISABLED');$status='BLOCKED'}
    [pscustomobject]@{Contract='SqlServerLab.NativeLinuxContainerHost/1.1';Provider=$Provider;Status=$status;Reasons=@($reasons);
        CgroupVersion=$base.CgroupVersion;Rootless=$base.Rootless;RequiresHyperV=$false;
        CompatibilityScope='LINUX_CGROUP_ROOTFUL_AND_ADVERTISED_CONTROLLERS';Controllers=$controllers;ResourceCapacity=$capacity;
        SharedKernel=(Get-NativeLinuxSharedKernelEvidence -MemoryV1 $memoryV1);FullLaunchReadiness='INCOMPLETE';
        ExecutionSupported=$false;MutationAllowed=$false;SqlLanguageEvidence='NOT_EXECUTED';HostChanges='NONE'}
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
