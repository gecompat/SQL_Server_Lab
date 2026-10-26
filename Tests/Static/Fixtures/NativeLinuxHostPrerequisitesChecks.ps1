# Actual shared classifier and Plan reducer; synthetic facts only.
& {
    Set-StrictMode -Version Latest
    function Assert-Prerequisite {param([bool]$Condition,[string]$Name)
        if(-not $Condition){throw "NATIVE_PREREQUISITE_FAILED: $Name"};$script:count++
    }
    function New-HostInfo {param([string]$Provider)
        if($Provider -ceq 'docker'){
            [pscustomobject]@{OSType='linux';CgroupVersion='1';SecurityOptions=@();MemoryLimit=$true;PidsLimit=$true;MemTotal=8GB;NCPU=4}
        }else{
            [pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='v1';security=[pscustomobject]@{rootless=$false};
                cgroupControllers=@('cpu','memory','pids');memTotal=8GB;cpus=4}}
        }
    }
    # No implicit fallback may invoke a native command, including valid JSON null.
    function Get-LabHostToolInvocation {throw 'NATIVE_PREREQUISITE_NATIVE_FORBIDDEN'}
    function Resolve-LabHostTool {throw 'NATIVE_PREREQUISITE_NATIVE_FORBIDDEN'}
    $profile=[pscustomobject]@{maxMemoryMB=4096;maxCpus=4}
    foreach($provider in @('docker','podman')) {
        $info=New-HostInfo $provider
        $d=Get-NativeLinuxContainerHostDecision $provider $info $true $true -ResourceRequirements $profile
        Assert-Prerequisite ($d.Status -ceq 'COMPATIBLE' -and $d.Controllers.Status -ceq 'AVAILABLE') "$provider actual classifier and advertised controllers"
        Assert-Prerequisite ($d.ResourceCapacity.MemoryStatus -ceq 'CAPACITY_SUFFICIENT' -and $d.ResourceCapacity.CpuStatus -ceq 'CAPACITY_SUFFICIENT') "$provider total-capacity comparison"
        Assert-Prerequisite ($d.FullLaunchReadiness -ceq 'INCOMPLETE' -and -not $d.ExecutionSupported -and -not $d.MutationAllowed -and
            $d.ResourceCapacity.FreeMemory -ceq 'NOT_CHECKED' -and $d.ResourceCapacity.Reservation -ceq 'NOT_CHECKED') "$provider capacity is no free-memory or execution proof"
        Assert-Prerequisite (-not $d.SharedKernel.IsolationProven -and $d.SharedKernel.ProviderKernelBinding -ceq 'NOT_CHECKED') "$provider does not invent backend independence"
        foreach($bad in @($null,[pscustomobject]@{},'PRIVATE_CANARY',@('PRIVATE_CANARY'))) {
            $invalid=Get-NativeLinuxContainerHostDecision $provider $bad $true $true -ResourceRequirements $profile
            Assert-Prerequisite ($invalid.Status -cne 'COMPATIBLE' -and 'PROVIDER_RESPONSE_INVALID' -cin $invalid.Reasons) "$provider malformed facts never native fallback or PASS"
        }
        $source=if($provider -ceq 'docker'){$info}else{$info.host}
        $memoryKey=if($provider -ceq 'docker'){'MemTotal'}else{'memTotal'}
        $cpuKey=if($provider -ceq 'docker'){'NCPU'}else{'cpus'}
        $source.$memoryKey=4095MB;$source.$cpuKey=3
        $d=Get-NativeLinuxContainerHostDecision $provider $info $true $true -ResourceRequirements $profile
        Assert-Prerequisite ($d.ResourceCapacity.MemoryStatus -ceq 'CAPACITY_INSUFFICIENT' -and $d.ResourceCapacity.CpuStatus -ceq 'CAPACITY_INSUFFICIENT' -and
            $d.Status -ceq 'BLOCKED' -and 'RESOURCE_PROFILE_CAPACITY_INSUFFICIENT' -cin $d.Reasons) "$provider below selected profile blocks the existing action gate"
        foreach($bad in @($null,'4096',$false,0,-1,1.5)) {
            $source.$memoryKey=$bad;$source.$cpuKey=$bad
            $d=Get-NativeLinuxContainerHostDecision $provider $info $true $true -ResourceRequirements $profile
            Assert-Prerequisite ($d.ResourceCapacity.MemoryStatus -ceq 'UNKNOWN' -and $d.ResourceCapacity.CpuStatus -ceq 'UNKNOWN' -and
                $d.Status -ceq 'UNKNOWN' -and 'RESOURCE_PROFILE_CAPACITY_UNKNOWN' -cin $d.Reasons) "$provider invalid capacity stays unknown and fails closed"
        }
        Assert-Prerequisite (($d|ConvertTo-Json -Depth 12 -Compress) -notmatch 'PRIVATE_CANARY|hostname|endpoint|distributionName') "$provider closed evidence has no raw inventory"
    }
    foreach($bad in @($null,'true',1)) {
        $info=New-HostInfo docker;$info.MemoryLimit=$bad
        $d=Get-NativeLinuxContainerHostDecision docker $info $true $true
        Assert-Prerequisite ($d.Status -ceq 'UNKNOWN' -and $d.Controllers.Status -ceq 'UNKNOWN' -and 'memory' -cin $d.Controllers.Unknown) 'Missing or mistyped Docker controller is unknown'
    }
    $info=New-HostInfo docker;$info.PSObject.Properties.Remove('PidsLimit')
    Assert-Prerequisite ((Get-NativeLinuxContainerHostDecision docker $info $true $true).Controllers.Status -ceq 'UNKNOWN') 'Absent Docker flag is not missing controller'
    $info.MemoryLimit=$false
    $d=Get-NativeLinuxContainerHostDecision docker $info $true $true
    Assert-Prerequisite ($d.Status -ceq 'BLOCKED' -and $d.Controllers.Status -ceq 'MISSING' -and 'pids' -cin $d.Controllers.Unknown) 'Known missing and unknown facts stay separately visible'
    foreach($bad in @($null,'cpu',@('CPU','memory','pids'),@('cpu',7,'pids'))) {
        $info=New-HostInfo podman;$info.host.cgroupControllers=$bad
        Assert-Prerequisite ((Get-NativeLinuxContainerHostDecision podman $info $true $true).Controllers.Status -ceq 'UNKNOWN') 'Malformed Podman controller list is unknown'
    }
    $info=New-HostInfo podman;$info.host.cgroupControllers=@()
    $d=Get-NativeLinuxContainerHostDecision podman $info $true $true
    Assert-Prerequisite ($d.Controllers.Status -ceq 'MISSING' -and $d.Controllers.Missing.Count -eq 3) 'Valid empty Podman list is a missing-controller observation'
    $info=New-HostInfo podman;$info.host|Add-Member cgroupsVersion 'v2'
    Assert-Prerequisite ((Get-NativeLinuxContainerHostDecision podman $info $true $true).Status -cne 'COMPATIBLE') 'Conflicting cgroup aliases reuse canonical rejection'
    foreach($case in @(
        @('', 'NOT_CHECKED'),@('CONFIG_MEMCG_V1=y','AVAILABLE'),@('# CONFIG_MEMCG_V1 is not set','MISSING'),
        @('config_memcg_v1=y','UNKNOWN'),@("CONFIG_MEMCG_V1=y`n# CONFIG_MEMCG_V1 is not set",'UNKNOWN'),@('CONFIG_MEMCG=y','UNKNOWN'))) {
        Assert-Prerequisite ((Get-NativeLinuxKernelMemoryV1Evidence $case[0]) -ceq $case[1]) 'Typed kernelconfig evidence'
    }
    $info=New-HostInfo docker;$info.CgroupVersion='2'
    $d=Get-NativeLinuxContainerHostDecision docker $info $true $true '# CONFIG_MEMCG_V1 is not set' -RequiredCgroupVersion 2 -SqlVersion 2025
    Assert-Prerequisite ($d.Status -ceq 'COMPATIBLE' -and 'KERNEL_MEMCG_V1_DISABLED' -cnotin $d.Reasons) 'Disabled v1 does not exclude explicitly selected v2'
    foreach($context in @('UNKNOWN_PROVIDER_BACKEND','SELECTED_WSL_DISTRIBUTION')) {
        $a=Get-NativeLinuxSharedKernelEvidence -MemoryV1 AVAILABLE -Context $context
        Assert-Prerequisite ($a.Context -ceq $context -and -not $a.IsolationProven -and $a.ParallelWorkloads -ceq 'NOT_CHECKED' -and
            $a.ProviderKernelBinding -ceq 'NOT_CHECKED') 'WSL context and positive kernelconfig do not prove workload compatibility'
    }
    foreach($bad in @([pscustomobject]@{},[pscustomobject]@{maxMemoryMB='4096';maxCpus=4},[pscustomobject]@{maxMemoryMB=4096;maxCpus=$false})) {
        try {Get-NativeLinuxCapacityEvidence docker (New-HostInfo docker) $bad;throw 'EXPECTED_RESOURCE_REJECTION'}
        catch {if($_.Exception.Message -cne 'NATIVE_HOST_RESOURCE_PROFILE_INVALID'){throw}}
        $script:count++
    }
    $coreAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $root 'Private/ContainerImageArtifact.ps1'),[ref]$null,[ref]$null)
    Assert-Prerequisite (@($coreAst.EndBlock.Statements|Where-Object {$_ -isnot [Management.Automation.Language.FunctionDefinitionAst]}).Count -eq 0) 'Shared classifier source has no top-level effects'
    if($IsWindows) {
        $source=Get-Content (Join-Path $root 'Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1') -Raw
        $source=$source.Replace(". (Join-Path `$PSScriptRoot 'Common/LinuxContainerHostContract.ps1')",'')
        $source=$source.Replace(". (Join-Path `$PSScriptRoot 'Common/NativeLinuxContainerHost.ps1')",'')
        $source=$source.Replace('$sourceRoot=Split-Path $PSScriptRoot -Parent',"`$sourceRoot='fixture'")
        $command=[scriptblock]::Create($source)
        $script:wslMode='available';$script:wslCalls=0
        function Invoke-LinuxContainerHostNative {
            param($Executable,$Arguments,$TimeoutSeconds)
            if($Executable -cne 'wsl' -or $Arguments -contains '--shutdown' -or $Arguments -contains '--terminate'){throw 'UNEXPECTED_WSL_MUTATION'}
            $script:wslCalls++
            if($Arguments[0] -ceq '--list'){return [pscustomobject]@{ExitCode=0;Output="fixture`nfixture2`n"}}
            if($Arguments -contains 'sh') {
                if($TimeoutSeconds -ne 20){throw 'KERNEL_TIMEOUT_CHANGED'}
                return [pscustomobject]@{ExitCode=$(if($script:wslMode -ceq 'unknown'){3}else{0});Output='CONFIG_MEMCG_V1=y'}
            }
            if($TimeoutSeconds -ne 120 -or $Arguments -notcontains '-EncodedCommand'){throw 'WSL_DISPATCH_CHANGED'}
            $decoded=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Arguments[-1]))
            if($decoded -notmatch "FromBase64String\('([^']+)'\)"){throw 'WSL_PAYLOAD_MISSING'}
            $payload=[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches[1]))|ConvertFrom-Json
            if($payload.ResourceProfile -cne 'compact' -or $payload.Provider -cne 'docker' -or $payload.Action -cne 'Plan'){throw 'WSL_PROFILE_NOT_BOUND'}
            $d=Get-NativeLinuxContainerHostDecision docker (New-HostInfo docker) $true $true
            if($script:wslMode -ceq 'forged'){$d.ExecutionSupported=$true}
            [pscustomobject]@{ExitCode=0;Output=($d|ConvertTo-Json -Depth 15 -Compress)}
        }
        foreach($mode in @('available','unknown')) {
            $script:wslMode=$mode;$before=$script:wslCalls
            foreach($distribution in @('fixture','fixture2')) {
                $result=& $command -Backend Wsl -Distribution $distribution -RepositoryRoot /fixture -Action Plan -ResourceProfile compact
                Assert-Prerequisite ($result.SharedKernel.Context -ceq 'SELECTED_WSL_DISTRIBUTION' -and -not $result.SharedKernel.IsolationProven) 'Actual WSL Plan carries closed shared-kernel context'
                Assert-Prerequisite ($result.SharedKernel.MemoryV1 -ceq $(if($mode -ceq 'available'){'AVAILABLE'}else{'UNKNOWN'}) -and
                    $result.SharedKernel.ProviderKernelBinding -ceq 'NOT_CHECKED') 'Config observation is separate from provider kernel binding'
            }
            Assert-Prerequisite ($script:wslCalls -eq $before+6) 'One running-list, kernel probe and selected dispatch per WSL Plan'
        }
        $script:wslMode='forged'
        try {& $command -Backend Wsl -Distribution fixture -RepositoryRoot /fixture -Action Plan -ResourceProfile compact;throw 'EXPECTED_WSL_REJECTION'}
        catch {if($_.Exception.Message -cne 'NATIVE_HOST_WSL_PLAN_INVALID'){throw}}
        $script:count++
    }
}
