#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $root 'Tools/Common/LinuxContainerHostContract.ps1')
$count=0
function Expect-Rejection {
    param([scriptblock]$Action,[string]$Code)
    try {& $Action;throw 'EXPECTED_REJECTION_MISSING'} catch {if ($_.Exception.Message -notlike "*$Code*"){throw}}
    $script:count++
}
$id='12345678-1234-1234-1234-123456789abc'
$state=[pscustomobject]@{Contract='SqlServerLab.LinuxContainerHost/1.0';HostId=$id;Status='READY';Disk='os.vhdx';VmId=$id;VmName='SQLLAB-LINUX-12345678'}
Assert-LinuxContainerHostState $state $id;$count++
Assert-LinuxContainerHostRevision '' ('a'*40);$count++
Assert-LinuxContainerHostRevision ('a'*40) ('a'*40);$count++
Expect-Rejection {Assert-LinuxContainerHostRevision ('a'*40) ('b'*40)} 'LINUX_HOST_REPOSITORY_REVISION_MISMATCH'
Expect-Rejection {Assert-LinuxContainerHostRevision '' 'not-a-commit'} 'LINUX_HOST_REPOSITORY_COMMIT_INVALID'
foreach($invalid in @('../other','','ABCDEF12-1234-1234-1234-123456789abc','12345678-1234-1234-1234-123456789abc/child')) {Expect-Rejection {Assert-LinuxContainerHostId $invalid} 'LINUX_HOST_ID_INVALID'}
$state.Disk='../other.vhdx';Expect-Rejection {Assert-LinuxContainerHostState $state $id} 'LINUX_HOST_STATE_INVALID';$state.Disk='os.vhdx'
$state.HostId='aaaaaaaa-1234-1234-1234-123456789abc';Expect-Rejection {Assert-LinuxContainerHostState $state $id} 'LINUX_HOST_STATE_INVALID';$state.HostId=$id
$temp=Join-Path ([IO.Path]::GetTempPath()) "sqllab-host-check-$([guid]::NewGuid().ToString('N'))"
New-Item -ItemType Directory $temp|Out-Null
try {
    $disk=Join-Path $temp 'os.vhdx'
    Assert-LinuxContainerHostPath $disk $temp;$count++
    Expect-Rejection {Assert-LinuxContainerHostPath (Join-Path "$temp-other" 'os.vhdx') $temp} 'LINUX_HOST_PATH_ESCAPE'
    $vm=[pscustomobject]@{Id=$id;Name=$state.VmName;Notes="SqlServerLab.LinuxContainerHost/1.0:$id"}
    Assert-LinuxContainerHostVm $state $vm $disk @($disk);$count++
    $vm.Id='aaaaaaaa-1234-1234-1234-123456789abc';Expect-Rejection {Assert-LinuxContainerHostVm $state $vm $disk @($disk)} 'LINUX_HOST_VM_BINDING_MISMATCH';$vm.Id=$id
    $vm.Notes='foreign';Expect-Rejection {Assert-LinuxContainerHostVm $state $vm $disk @($disk)} 'LINUX_HOST_VM_BINDING_MISMATCH';$vm.Notes="SqlServerLab.LinuxContainerHost/1.0:$id"
    Expect-Rejection {Assert-LinuxContainerHostVm $state $vm $disk @($disk,(Join-Path $temp 'foreign.vhdx'))} 'LINUX_HOST_VM_BINDING_MISMATCH'
    $exe=(Get-Process -Id $PID).Path
    $result=Invoke-LinuxContainerHostNative $exe @('-NoProfile','-Command','[Console]::Out.Write("ok"); [Console]::Error.Write("stderr"); exit 7')
    if($result.ExitCode -ne 7 -or $result.Output -ne 'ok' -or $result.Error -ne 'stderr'){throw 'PROCESS_DRAIN_OR_EXIT_FAILED'};$count++
    Expect-Rejection {Invoke-LinuxContainerHostNative $exe @('-NoProfile','-Command','Start-Sleep -Seconds 30') 1} 'LINUX_HOST_NATIVE_TIMEOUT'
    $gitResult=Invoke-LinuxContainerHostNative git @('--version')
    if($gitResult.ExitCode -ne 0 -or $gitResult.Output -notmatch '^git version '){throw 'NATIVE_PATH_RESOLUTION_FAILED'};$count++
    $files=@('Tools/Invoke-SqlServerLabLinuxContainerHost.ps1','Tools/Common/LinuxContainerHostBootstrap.ps1','Tools/Common/LinuxContainerHostContract.ps1','Tests/Integration/Invoke-ExternalRuntimeContainerHyperVHost.ps1','Tests/Integration/Invoke-LinuxContainerHostAcceptance.ps1')
    foreach($file in $files){$tokens=$null;$errors=$null;[void][Management.Automation.Language.Parser]::ParseFile((Join-Path $root $file),[ref]$tokens,[ref]$errors);if($errors){throw "SYNTAX_ERROR: $file"};$count++}
    $source=Get-Content (Join-Path $root $files[0]) -Raw
    $hostAst=[Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
    $bindingFunction=$hostAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-OwnedVm'},$true).Extent.Text
    & {
        param($FunctionSource,$FixtureState,$FixtureVm,$FixtureDisk)
        function Get-VM {param($Id) $FixtureVm}
        function Get-VMHardDiskDrive {param($VM) [pscustomobject]@{Path=$FixtureDisk}}
        $state=$FixtureState;$osVhdPath=$FixtureDisk
        . ([scriptblock]::Create($FunctionSource))
        $WhatIfPreference=$true
        $owned=Get-OwnedVm
        if($owned.Id -ne $FixtureVm.Id){throw 'WHATIF_OWNERSHIP_READ_FAILED'}
    } $bindingFunction $state $vm $disk
    $count++
    if($source -notmatch 'StrictHostKeyChecking=yes' -or $source -match 'StrictHostKeyChecking=no' -or $source -notmatch 'SetAccessRuleProtection\(\$true,\$false\)'){throw 'SSH_BOUNDARY_INVALID'};$count++
    if($source -notmatch 'Set-VMMemory -VM \$vm -DynamicMemoryEnabled \$false' -or $source -notmatch 'LINUX_HOST_STATIC_MEMORY_REQUIRED'){throw 'STATIC_MEMORY_CONTRACT_MISSING'};$count++
    $recipe=Get-Content (Join-Path $root 'Images/ExternalLanguages/Linux/recipe.json') -Raw|ConvertFrom-Json
    if($recipe.launchContract.requiredCgroupVersion -ne '1'){throw 'EXISTING_GUARD_CHANGED'};$count++
    Write-Host "PASS: $count Linux container host checks"
} finally {
    if([IO.Path]::GetFullPath($temp).StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase)){Remove-Item -LiteralPath $temp -Recurse -Force}
}
