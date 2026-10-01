#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$root=(Resolve-Path "$PSScriptRoot/../..").Path
. "$root/Private/ContainerRuntimeScope.ps1"
. "$root/Private/StoppedHostMemory.ps1"
$targetImplementation=${function:Get-LabStopMemoryTarget}
$failures=[Collections.Generic.List[string]]::new(); $passed=0
. "$PSScriptRoot/../Common/CheckResult.ps1"
function Write-LabWarning { param($Message) }
function Start-Sleep { param($Milliseconds) }
function Get-LabStopHostMemory {
    $script:reads++
    if ($script:noHost) { return $null }
    return [pscustomobject]@{TotalMB=96000; AvailableMB=if($script:reads -gt 1){$script:after}else{$script:before}}
}
function Get-LabStopMemoryTarget {
    param($Provider)
    $script:bindings++
    if ($script:unsupported) { return $null }
    return [pscustomobject]@{Invocation='synthetic-wsl';Distribution='synthetic-distro';RuntimeId=if($script:changed -and $script:bindings -gt 1){'other'}else{'bound'}}
}
function Invoke-LabStopMemoryCommand {
    param($Invocation,$Arguments)
    $script:commands.Add(($Arguments -join ' '))
    if ($script:fail) { throw 'secret-host-path-must-not-escape' }
    if ($Arguments -contains '/proc/meminfo') {
        $cache=if($script:reclaimed){512}else{$script:cache}
        return "Cached: $($cache*1024) kB`nBuffers: 0 kB`nShmem: 0 kB"
    }
    $script:reclaimed=$true
}
function Reset-Case {
    $script:reads=0; $script:bindings=0; $script:before=12000; $script:after=40000
    $script:cache=32000; $script:reclaimed=$false; $script:changed=$false
    $script:noHost=$false; $script:unsupported=$false; $script:fail=$false
    $script:commands=[Collections.Generic.List[string]]::new()
}
Reset-Case
$result=Invoke-LabStoppedHostMemoryRelease -Provider docker
Add-CheckResult 'Pressure plus large cache releases only page cache and observes host return' ($result.Status -eq 'HOST_RETURN_OBSERVED' -and $result.CacheReleaseRequested -and $script:commands.Count -eq 3 -and $script:commands[1] -match 'sync && echo 1 > /proc/sys/vm/drop_caches')
Reset-Case; $script:before=30000
$result=Invoke-LabStoppedHostMemoryRelease -Provider docker
Add-CheckResult 'Healthy host performs no backend operation' ($result.Status -eq 'NOT_REQUIRED' -and $script:commands.Count -eq 0 -and $script:bindings -eq 0)
Reset-Case; $script:cache=1000
$result=Invoke-LabStoppedHostMemoryRelease -Provider podman
Add-CheckResult 'Small cache is preserved' ($result.Status -eq 'NOT_REQUIRED' -and -not $script:reclaimed)
Reset-Case; $script:after=12000
$result=Invoke-LabStoppedHostMemoryRelease -Provider podman
Add-CheckResult 'Linux cache release does not falsely claim Windows memory return' ($result.Status -eq 'RETURN_PENDING' -and $result.CacheReleaseRequested -and $script:reads -eq 6)
Reset-Case; $script:changed=$true
$result=Invoke-LabStoppedHostMemoryRelease -Provider docker
Add-CheckResult 'Changed runtime selection blocks mutation' ($result.Status -eq 'BACKEND_CHANGED' -and -not $script:reclaimed)
Reset-Case; $script:unsupported=$true
$result=Invoke-LabStoppedHostMemoryRelease -Provider docker,podman
Add-CheckResult 'Unbound backend is not mutated' ($result.Status -eq 'UNSUPPORTED_BACKEND' -and $script:commands.Count -eq 0)
Reset-Case; $script:fail=$true
$result=Invoke-LabStoppedHostMemoryRelease -Provider docker
Add-CheckResult 'Failures are sanitized and do not change stopped state' ($result.Status -eq 'CHECK_FAILED' -and ($result|ConvertTo-Json) -notmatch 'secret-host-path')
Reset-Case
$result=Invoke-LabStoppedHostMemoryRelease -Provider docker -Skip
Add-CheckResult 'Explicit opt-out has no host access' ($result.Status -eq 'DISABLED' -and $script:reads -eq 0)
Reset-Case; $script:noHost=$true
$result=Invoke-LabStoppedHostMemoryRelease -Provider podman
Add-CheckResult 'Non-Windows host has no backend operations' ($result.Status -eq 'NOT_APPLICABLE' -and $script:commands.Count -eq 0)
Add-CheckResult 'Shared memory is excluded from cache estimate' ((Get-LabStopLinuxCacheMB "Cached: 4096 kB`nBuffers: 1024 kB`nShmem: 2048 kB") -eq 3)
$rejected=$false; try { Get-LabStopLinuxCacheMB 'invalid' } catch {$rejected=$true}
Add-CheckResult 'Invalid memory measurement is rejected' $rejected
Set-Item function:Get-LabStopMemoryTarget $targetImplementation
$savedEnvironment=@{}
foreach($name in @('DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION')) {
    $savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name)
    [Environment]::SetEnvironmentVariable($name,$null)
}
function Get-LabHostToolInvocation { param($Name) return "synthetic-$Name" }
function Get-Command { param($Name,$CommandType,$ErrorAction) return @([pscustomobject]@{Source='synthetic-wsl'},[pscustomobject]@{Source='other-wsl'}) }
function Invoke-LabStopMemoryCommand {
    param($Invocation,$Arguments)
    $key=$Arguments -join ' '
    if($Invocation -eq 'synthetic-wsl') {return $script:running}
    if($key -eq 'context inspect') {return '[{"Name":"desktop-linux","Endpoints":{"docker":{"Host":"npipe:////./pipe/dockerDesktopLinuxEngine"}}}]'}
    if($key -eq 'info --format {{json .}}') {return '{"OperatingSystem":"Docker Desktop","KernelVersion":"6.6-microsoft-standard-WSL2"}'}
    if($key -eq 'info --format json') {return '{}'}
    if($key -eq 'machine list --format json') {return '[{"Name":"podman-machine-default","VMType":"wsl","Running":true}]'}
    if($key -eq 'system connection list --format json') {return $script:connections}
    throw 'Unexpected command'
}
try {
    $script:running="docker-desktop`npodman-machine-default"
    $script:connections='[{"Name":"podman-machine-default-root","URI":"ssh://root@127.0.0.1:7000/run/podman/podman.sock","IsMachine":true,"Default":true}]'
    Add-CheckResult 'Local Docker Desktop WSL2 maps to running distribution' ((Get-LabStopMemoryTarget docker).Distribution -eq 'docker-desktop')
    Add-CheckResult 'Podman uses actual machine name without invented prefix' ((Get-LabStopMemoryTarget podman).Distribution -eq 'podman-machine-default')
    $script:running='other-distro'
    Add-CheckResult 'Stopped distribution is not started for cache cleanup' ($null -eq (Get-LabStopMemoryTarget docker))
    $script:running='podman-machine-default'
    $script:connections='[{"Name":"remote","URI":"ssh://example.invalid:7000/run/podman/podman.sock","IsMachine":false,"Default":true}]'
    Add-CheckResult 'Remote endpoint cannot authorize local cache mutation' ($null -eq (Get-LabStopMemoryTarget podman))
    [Environment]::SetEnvironmentVariable('DOCKER_HOST','tcp://example.invalid:2376')
    Add-CheckResult 'Environment endpoint override blocks default-context inference' ($null -eq (Get-LabStopMemoryTarget docker))
} finally { foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name])} }
& {
    . "$root/Private/WindowsPoolClaims.ps1"
    . "$root/Public/Stop-SqlServerLab.ps1"
    $testRoot=Join-Path ([IO.Path]::GetTempPath()) ('stop-memory-contract-'+[guid]::NewGuid().ToString('N'))
    $runId='00000000-0000-0000-0000-000000000123'
    $runDirectory=Join-Path $testRoot "runs/$runId"
    $null=New-Item -ItemType Directory -Path $runDirectory
    '{"instances":[{"provider":"docker"}]}' | Set-Content (Join-Path $runDirectory 'connection-info.json')
    function Test-LabAutomatedTestEnvironmentRun {param($RunId) return $false}
    function Get-LabRunState {param($RunId,$StateRoot) return [pscustomobject]@{state='RUNNING';metadata=[pscustomobject]@{name='synthetic';workflowKind='container'}}}
    function Sync-LabRunRuntimeState {param($Run,$StateRoot) return [pscustomobject]@{Run=$Run}}
    function Get-Command {param($Name,$CommandType,$ErrorAction) return $null}
    function Get-ContainerRuntime {param($PreferredRuntime) return $PreferredRuntime}
    function Get-LabHostToolInvocation {param($Name) return 'Invoke-SyntheticContainer'}
    function Invoke-SyntheticContainer {
        param($Verb)
        $global:LASTEXITCODE=0
        if($Verb -eq 'ps'){return 'synthetic-container'}
        if($Verb -eq 'inspect'){return 'synthetic-container'}
        if($Verb -eq 'stop' -and $script:stopFails){$global:LASTEXITCODE=1}
    }
    function Set-LabProviderSubRunState {}
    function Set-LabRunState {}
    function Write-LabInfo {}
    function Write-LabSuccess {}
    function Write-LabError {}
    function Invoke-LabStoppedHostMemoryRelease {param($Provider,[switch]$Skip) $script:maintenanceCalls++; return [pscustomobject]@{Status='NOT_REQUIRED'}}
    try {
        $script:LabAutomatedTestEnvironmentGroupOperation=$false
        $script:maintenanceCalls=0; $script:stopFails=$false
        $preview=Stop-SqlServerLab -RunId $runId -StateRoot $testRoot -WhatIf
        Add-CheckResult 'Public WhatIf never invokes host maintenance' ($preview.Action -eq 'CANCELLED' -and $script:maintenanceCalls -eq 0)
        $script:stopFails=$true
        $failed=Stop-SqlServerLab -RunId $runId -StateRoot $testRoot -Confirm:$false
        Add-CheckResult 'Failed public stop never invokes host maintenance' ($failed.Action -eq 'PARTIAL' -and $script:maintenanceCalls -eq 0)
        $script:stopFails=$false
        $stopped=Stop-SqlServerLab -RunId $runId -StateRoot $testRoot -Confirm:$false
        Add-CheckResult 'Successful public stop returns separate host evidence once' ($stopped.Action -eq 'STOPPED' -and $stopped.HostMemory.Status -eq 'NOT_REQUIRED' -and $script:maintenanceCalls -eq 1)
        $script:LabAutomatedTestEnvironmentGroupOperation=$true
        $grouped=Stop-SqlServerLab -RunId $runId -StateRoot $testRoot -Confirm:$false
        Add-CheckResult 'Grouped child stop defers shared maintenance to coordinator' ($grouped.HostMemory.Status -eq 'GROUP_DEFERRED' -and $script:maintenanceCalls -eq 1)
    } finally {
        $script:LabAutomatedTestEnvironmentGroupOperation=$false
        Remove-Item -LiteralPath (Join-Path $runDirectory 'connection-info.json')
        Remove-Item -LiteralPath $runDirectory
        Remove-Item -LiteralPath (Join-Path $testRoot 'runs')
        Remove-Item -LiteralPath $testRoot
    }
}
if ($failures.Count) { throw ($failures -join '; ') }
Write-Host "Stopped host memory: $passed PASS"
