#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
. (Join-Path $root 'Tools/Common/NativeLinuxContainerHost.ps1')
$count=0
function Assert-Decision {
    param($Result,[string]$Status,[string]$Reason)
    if($Result.Status -ne $Status -or ($Reason -and $Reason -notin $Result.Reasons) -or $Result.RequiresHyperV -or $Result.SqlLanguageEvidence -ne 'NOT_EXECUTED'){throw 'NATIVE_HOST_DECISION_INVALID'}
    $script:count++
}
$docker=[pscustomobject]@{OSType='linux';CgroupVersion='1';SecurityOptions=@('name=seccomp');MemoryLimit=$true;PidsLimit=$true}
$podman=[pscustomobject]@{host=[pscustomobject]@{os='linux';cgroupVersion='v1';cgroupControllers=@('cpu','memory','pids');security=[pscustomobject]@{rootless=$false}}}
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $docker $true $true) COMPATIBLE
Assert-Decision (Get-NativeLinuxContainerHostDecision podman $podman $true $true) COMPATIBLE
$docker.MemoryLimit=$false
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $docker $true $true) BLOCKED RESOURCE_CONTROLLERS_UNAVAILABLE
$docker.MemoryLimit=$true
$podman.host.cgroupControllers=@('cpu','pids')
Assert-Decision (Get-NativeLinuxContainerHostDecision podman $podman $true $true) BLOCKED RESOURCE_CONTROLLERS_UNAVAILABLE
$podman.host.cgroupControllers=@('cpu','memory','pids')
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $null $false $false) BLOCKED PROVIDER_TOOL_MISSING
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $null $true $false) BLOCKED PROVIDER_RUNTIME_UNREACHABLE
$docker.CgroupVersion='2'
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $docker $true $true) BLOCKED CGROUP_VERSION_UNSUPPORTED
$docker.CgroupVersion='garbage1'
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $docker $true $true) BLOCKED CGROUP_VERSION_UNSUPPORTED
$docker.CgroupVersion='1';$docker.SecurityOptions=@('name=rootless')
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $docker $true $true) BLOCKED ROOTFUL_PROVIDER_REQUIRED
$podman.host.security.rootless=$true
Assert-Decision (Get-NativeLinuxContainerHostDecision podman $podman $true $true) BLOCKED ROOTFUL_PROVIDER_REQUIRED
$podman.host.security.rootless=$null
Assert-Decision (Get-NativeLinuxContainerHostDecision podman $podman $true $true) BLOCKED ROOTFUL_STATUS_UNKNOWN
Assert-Decision (Get-NativeLinuxContainerHostDecision podman $podman $true $true '# CONFIG_MEMCG_V1 is not set') BLOCKED KERNEL_MEMCG_V1_DISABLED
$docker.OSType='windows'
Assert-Decision (Get-NativeLinuxContainerHostDecision docker $docker $true $true) BLOCKED LINUX_RUNTIME_REQUIRED
$tool=Join-Path $root 'Tools/Invoke-SqlServerLabNativeLinuxContainerHost.ps1'
$tokens=$null;$errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($tool,[ref]$tokens,[ref]$errors)
if($errors){throw 'NATIVE_HOST_SYNTAX_INVALID'};$count++
$commands=@($ast.FindAll({param($n)$n -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object {$_.GetCommandName()})
if($commands|Where-Object {$_ -match '^(New|Get|Set|Start|Stop|Remove)-VM'}){throw 'NATIVE_HOST_HYPERV_DEPENDENCY'};$count++
if($IsLinux){
    Assert-NativeLinuxContainerHostStorage /srv/fixture/Lab_Data /srv/fixture/Lab_Base '' ''; $count++
    foreach($case in @(
        @('/','/srv/fixture/Lab_Base','','','NATIVE_HOST_ABSOLUTE_LINUX_STORAGE_REQUIRED'),
        @('/srv/../fixture','/srv/fixture/Lab_Base','','','NATIVE_HOST_ABSOLUTE_LINUX_STORAGE_REQUIRED'),
        @('/srv/fixture','/srv/fixture/child','','','NATIVE_HOST_STORAGE_OVERLAP'),
        @('/srv/fixture/Lab_Data','/srv/fixture/Lab_Base','/srv/other/Lab_Data','','NATIVE_HOST_EXISTING_DEFAULTS_DIFFER')
    )){
        try {Assert-NativeLinuxContainerHostStorage $case[0] $case[1] $case[2] $case[3];throw 'EXPECTED_REJECTION_MISSING'}catch{if($_ -notmatch $case[4]){throw}}
        $count++
    }
    $fixture=Join-Path ([IO.Path]::GetTempPath()) "sqllab-native-links-$([guid]::NewGuid().ToString('N'))"
    New-Item -ItemType Directory $fixture|Out-Null
    try{
        New-Item -ItemType SymbolicLink -Path "$fixture/link" -Target /tmp|Out-Null
        try{Assert-NativeLinuxContainerHostStorage "$fixture/link/Lab_Data" "$fixture/Lab_Base" '' '';throw 'EXPECTED_REJECTION_MISSING'}catch{if($_ -notmatch 'NATIVE_HOST_STORAGE_LINK_REJECTED'){throw}};$count++
    }finally{Remove-Item -LiteralPath "$fixture/link" -Force;Remove-Item -LiteralPath $fixture}
}
if($IsWindows){
    # Exercise the WSL boundary with synthetic command responses, no WSL calls.
    $body=Get-Content $tool -Raw
    $body=$body.Replace(". (Join-Path `$PSScriptRoot 'Common/LinuxContainerHostContract.ps1')",'')
    $body=$body.Replace(". (Join-Path `$PSScriptRoot 'Common/NativeLinuxContainerHost.ps1')",'')
    $body=$body.Replace('$sourceRoot=Split-Path $PSScriptRoot -Parent',"`$sourceRoot='fixture'")
    & {
        param($Source)
        $script:calls=0
        function Invoke-LinuxContainerHostNative {
            param($Executable,$Arguments,$TimeoutSeconds)
            if($Executable -ne 'wsl' -or $TimeoutSeconds -ne 20){throw 'WSL_CALL_CONTRACT_INVALID'}
            $script:calls++
            if($Arguments[0] -eq '--list'){return [pscustomobject]@{ExitCode=0;Output="fixture`n"}}
            if($Arguments -contains '--shutdown' -or $Arguments -contains '--terminate'){throw 'UNEXPECTED_WSL_MUTATION'}
            [pscustomobject]@{ExitCode=0;Output="# CONFIG_MEMCG_V1 is not set`n"}
        }
        $scriptBlock=[scriptblock]::Create($Source)
        $result=& $scriptBlock -Backend Wsl -Distribution fixture -Action Plan
        Assert-Decision $result BLOCKED KERNEL_MEMCG_V1_DISABLED
        if($script:calls -ne 2){throw 'WSL_PREFLIGHT_UNEXPECTED_CALLS'}
        try {& $scriptBlock -Backend Wsl -Distribution fixture -Action Initialize;throw 'EXPECTED_BLOCK_MISSING'}catch{if($_ -notmatch 'NATIVE_HOST_KERNEL_MEMCG_V1_DISABLED'){throw}}
        try {& $scriptBlock -Backend Wsl -Distribution stopped -Action Initialize;throw 'EXPECTED_BLOCK_MISSING'}catch{if($_ -notmatch 'NATIVE_HOST_WSL_NOT_RUNNING'){throw}}
    } $body
    $count+=2
}
Write-Output "PASS: $count native Linux container host checks"
