#Requires -Version 7.2
<#
.SYNOPSIS Exercises bounded Docker and Podman status reads using synthetic native results.
.DESCRIPTION Starts no container runtime and makes no host or provider configuration changes.
#>
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$records = [Collections.Generic.List[object]]::new()
function Assert-ContainerObservation {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "FAIL: $Name" }
    Write-Host "PASS: $Name"
}
function Get-LabHostToolInvocation {
    param([string]$Name)
    if ($Name -notin @('docker','podman')) { throw 'UNEXPECTED_PROVIDER' }
    return "synthetic-$Name"
}
function Invoke-LabContainerRuntimeCommand {
    [CmdletBinding()]
    param(
        [string]$Provider,
        [string]$StateRoot,
        [string]$Invocation,
        [string[]]$ArgumentList,
        [switch]$NativeResult,
        [int]$TimeoutSeconds,
        [DateTimeOffset]$DeadlineUtc
    )
    $records.Add([pscustomobject]@{
        Provider = $Provider
        Invocation = $Invocation
        Arguments = @($ArgumentList)
        NativeResult = [bool]$NativeResult
        TimeoutSeconds = $TimeoutSeconds
        DeadlineUtc = $DeadlineUtc
    })
    if ($script:throwObservationTimeout) { throw 'LAB_NATIVE_OPERATION_TIMEOUT' }
    if ($DeadlineUtc -ne [DateTimeOffset]::MinValue -and [DateTimeOffset]::UtcNow -ge $DeadlineUtc) { throw 'LAB_NATIVE_OPERATION_TIMEOUT' }
    if ($script:delayInspect -and $ArgumentList[0] -ceq 'inspect') { Start-Sleep -Milliseconds 1200 }
    if ($ArgumentList[0] -ceq 'inspect' -and $script:invalidInspect) {
        return [pscustomobject]@{ ExitCode=125; Stdout=@(); Stderr=@('synthetic private stderr') }
    }
    if ($ArgumentList[0] -ceq 'inspect') {
        $json = '[{"State":{"Status":"running","Health":{"Status":"healthy"}},"HostConfig":{"RestartPolicy":{"Name":"unless-stopped"}}}]'
        return [pscustomobject]@{ ExitCode=0; Stdout=@($json); Stderr=@('synthetic non-json diagnostic') }
    }
    if ($ArgumentList[0] -ceq 'info') {
        return [pscustomobject]@{ ExitCode=0; Stdout=@('synthetic info'); Stderr=@() }
    }
    throw 'UNEXPECTED_SYNTHETIC_ARGUMENT'
}

. (Join-Path $repoRoot 'Providers/Docker/DockerProvider.ps1')
. (Join-Path $repoRoot 'Providers/Podman/PodmanProvider.ps1')

foreach ($provider in @('docker','podman')) {
    $records.Clear()
    $script:throwObservationTimeout = $false
    $script:delayInspect = $false
    $script:invalidInspect = $false
    $reader = if ($provider -ceq 'docker') { 'Get-DockerInstanceStatus' } else { 'Get-PodmanInstanceStatus' }
    $status = & $reader -ContainerIdOrName 'synthetic-container'
    Assert-ContainerObservation ($status.Available -and $status.Exists -and $status.Running -and $status.Healthy -and $status.AutoStart) "$provider parses only stdout from bounded inspect"
    Assert-ContainerObservation ($records.Count -eq 1 -and $records[0].NativeResult -and $records[0].TimeoutSeconds -eq 30 -and $records[0].Arguments[0] -ceq 'inspect') "$provider inspect uses structured result and default timeout"

    $records.Clear()
    $script:delayInspect = $true
    $script:invalidInspect = $true
    $fallback = & $reader -ContainerIdOrName 'synthetic-container'
    Assert-ContainerObservation ($fallback.Available -and -not $fallback.Exists -and $records.Count -eq 2 -and $records[1].Arguments[0] -ceq 'info') "$provider checks runtime availability after missing inspect"
    Assert-ContainerObservation ($records[1].TimeoutSeconds -eq 30 -and $records[0].DeadlineUtc -eq $records[1].DeadlineUtc) "$provider info fallback receives the same absolute deadline"

    $records.Clear()
    $script:throwObservationTimeout = $true
    $timedOut = & $reader -ContainerIdOrName 'synthetic-container' -TimeoutSeconds 2
    Assert-ContainerObservation (-not $timedOut.Available -and -not $timedOut.Exists -and $null -eq $timedOut.Raw -and $records.Count -eq 1 -and $records[0].TimeoutSeconds -eq 2) "$provider timeout becomes sanitized unavailable"
    $script:throwObservationTimeout = $false

    $records.Clear()
    $expired = & $reader -ContainerIdOrName 'synthetic-container' -DeadlineUtc ([DateTimeOffset]::UtcNow.AddSeconds(-1))
    Assert-ContainerObservation (-not $expired.Available -and $null -eq $expired.Raw -and $records.Count -eq 1) "$provider refuses to start a read after its absolute deadline"
}
