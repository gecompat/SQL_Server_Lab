$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) -Parent
. (Join-Path $repositoryRoot 'Private/ContainerReconcile.ps1')
. (Join-Path $repositoryRoot 'Public/Update-SqlServerLabContainer.ps1')

# Exercise the real plan and executor up to the first new journal. No runtime
# is resolved, and the journal sentinel prevents all provider mutations.
function Test-LabAutomatedTestEnvironmentRun { return $false }
function Get-LabContainerReconcileContext { return $script:context }
function Repair-LabContainerReconcileJournal {
    $script:repairCalls++
    if ($null -ne $script:recoveredInspect) { $script:context.Inspect = $script:recoveredInspect }
}
function Test-LabEndpointBinding { return [pscustomobject]@{ Available=$true } }
function New-LabContainerReconcileJournal {
    $script:journalCalls++
    throw 'SYNTHETIC_JOURNAL_BOUNDARY'
}
function Invoke-LabContainerReconcileCommand {
    $script:providerCalls++
    throw 'UNEXPECTED_PROVIDER_MUTATION'
}

function Assert-Check([bool]$Condition, [string]$Name) {
    if (-not $Condition) { throw "FAIL: $Name" }
    $script:passed++
}
function New-Mount([string]$Type='bind', [bool]$Writable=$true) {
    return [pscustomobject]@{ Type=$Type; RW=$Writable; Source='/synthetic-private/source'; Destination='/data'; Name='synthetic-volume' }
}
function Set-Context($Inspect, [string]$Provider) {
    $script:context = [pscustomobject]@{
        Inspect=$Inspect; Provider=$Provider; RunId='synthetic-mount-guard'; InstanceId='primary'
        ContainerName='synthetic-container'; CurrentCpu=2; CurrentMemoryMB=2048; CurrentPort=14333
        CurrentAutoStart='off'; CurrentRestartPolicy='no'; CurrentAutoStartLabel='off'
        ConfiguredSqlMemory='MSSQL_MEMORY_LIMIT_MB=1638'; HealthCommand='sqlcmd -C'
    }
    $script:journalCalls=0; $script:providerCalls=0; $script:repairCalls=0; $script:recoveredInspect=$null
}
function Invoke-Boundary([hashtable]$Changes) {
    $outcome=$null
    try {
        $result=Update-SqlServerLabContainer -RunId 'synthetic-mount-guard' -InstanceId primary -StateRoot $script:syntheticRoot -Confirm:$false @Changes
        $outcome=[string]$result.Status
    }
    catch { $outcome=$_.Exception.Message }
    Assert-Check ($script:providerCalls -eq 0 -and $script:repairCalls -eq 1) 'recovery precedes fresh guard; no provider call'
    Assert-Check ($outcome -notmatch 'synthetic-private') 'error does not disclose mount source'
    return $outcome
}

$script:passed=0
$script:syntheticRoot=Join-Path ([IO.Path]::GetTempPath()) ('SqlServerLab-MountGuard-' + [guid]::NewGuid().ToString('N'))
$invalid=@(
    [pscustomobject]@{ Name='missing mounts'; Inspect=[pscustomobject]@{}; Code='EVIDENCE_INVALID' }
    [pscustomobject]@{ Name='null mounts'; Inspect=[pscustomobject]@{Mounts=$null}; Code='EVIDENCE_INVALID' }
    [pscustomobject]@{ Name='scalar mounts'; Inspect=[pscustomobject]@{Mounts=(New-Mount)}; Code='EVIDENCE_INVALID' }
    [pscustomobject]@{ Name='null item'; Inspect=[pscustomobject]@{Mounts=@($null)}; Code='EVIDENCE_INVALID' }
    [pscustomobject]@{ Name='tmpfs'; Inspect=[pscustomobject]@{Mounts=@((New-Mount tmpfs))}; Code='TYPE_UNSUPPORTED' }
    [pscustomobject]@{ Name='mixed unsupported'; Inspect=[pscustomobject]@{Mounts=@((New-Mount), (New-Mount tmpfs))}; Code='TYPE_UNSUPPORTED' }
    [pscustomobject]@{ Name='uppercase type'; Inspect=[pscustomobject]@{Mounts=@((New-Mount BIND))}; Code='TYPE_UNSUPPORTED' }
    [pscustomobject]@{ Name='oversized list'; Inspect=[pscustomobject]@{Mounts=@(1..1025|ForEach-Object { New-Mount })}; Code='EVIDENCE_INVALID' }
)
foreach ($entry in @(
    @{Field='RW'; Value='true'}, @{Field='RW'; Value=$null}, @{Field='Type'; Value=''},
    @{Field='Source'; Value=$null}, @{Field='Source'; Value=42}, @{Field='Source'; Value="/source`nprivate"},
    @{Field='Source'; Value='/synthetic/source:segment'}, @{Field='Source'; Value='relative-source'},
    @{Field='Source'; Value='C:relative-source'}, @{Field='Source'; Value='C:\source:segment'},
    @{Field='Destination'; Value=$null}, @{Field='Destination'; Value='relative'},
    @{Field='Destination'; Value='/data:ro'}, @{Field='Destination'; Value="/data`nprivate"},
    @{Field='Name'; Value=$null}, @{Field='Name'; Value=42}, @{Field='Name'; Value='volume:ro'}
    @{Field='Name'; Value='/synthetic/path'}, @{Field='Name'; Value='\synthetic\path'},
    @{Field='Name'; Value='relative/path'}, @{Field='Name'; Value='relative\path'}
)) {
    $mount=New-Mount
    if ($entry.Field -eq 'Name') { $mount.Type='volume' }
    $mount.($entry.Field)=$entry.Value
    $invalid += [pscustomobject]@{Name="invalid $($entry.Field): $($entry.Value)"; Inspect=[pscustomobject]@{Mounts=@($mount)}; Code='EVIDENCE_INVALID'}
}
foreach ($provider in @('docker','podman')) {
    foreach ($case in $invalid) {
        Set-Context $case.Inspect $provider
        $outcome=Invoke-Boundary @{Port=15433}
        Assert-Check ($outcome.StartsWith("CONTAINER_RECONCILE_MOUNT_$($case.Code):") -and $script:journalCalls -eq 0) "$provider rejects $($case.Name) before new journal"
    }
    $bind=New-Mount; $bindReadOnly=New-Mount -Writable $false
    $volume=New-Mount volume; $volumeReadOnly=New-Mount volume $false
    $valid=[pscustomobject]@{Mounts=@($bind,$bindReadOnly,$volume,$volumeReadOnly)}
    $actual=@(Get-LabContainerRecreateMountArguments -Inspect $valid -Provider $provider)
    $volumeSuffix=if($provider -eq 'podman'){':U'}else{''}
    $readOnlySuffix=if($provider -eq 'podman'){':U,ro'}else{':ro'}
    $expected=@('-v','/synthetic-private/source:/data','-v','/synthetic-private/source:/data:ro','-v',"synthetic-volume:/data$volumeSuffix",'-v',"synthetic-volume:/data$readOnlySuffix")
    Assert-Check (($actual -join '|') -ceq ($expected -join '|')) "$provider preserves bind/volume argv and read-only options"
    foreach($source in @('C:\synthetic-private\source','D:/synthetic-private/source','\\synthetic-host\share\source')) {
        $windowsBind=New-Mount
        $windowsBind.Source=$source
        $windowsArguments=@(Get-LabContainerRecreateMountArguments -Inspect ([pscustomobject]@{Mounts=@($windowsBind)}) -Provider $provider)
        Assert-Check ($windowsArguments.Count -eq 2 -and $windowsArguments[0] -eq '-v' -and $windowsArguments[1] -ceq "${source}:/data") "$provider preserves unambiguous Windows source argv"
    }
    foreach($inspect in @($valid, [pscustomobject]@{Mounts=@()})) {
        Set-Context $inspect $provider
        $outcome=Invoke-Boundary @{Port=15433}
        Assert-Check ($outcome -eq 'SYNTHETIC_JOURNAL_BOUNDARY' -and $script:journalCalls -eq 1) "$provider valid recreate reaches journal boundary"
    }
    Assert-Check (@(Get-LabContainerRecreateMountArguments -Inspect ([pscustomobject]@{Mounts=@()}) -Provider $provider).Count -eq 0) 'explicit empty mounts produce no argv'
    foreach($inspect in @($invalid[0].Inspect,$invalid[4].Inspect)) {
        Set-Context $inspect $provider
        $outcome=Invoke-Boundary @{}
        Assert-Check ($outcome -eq 'NO_OP' -and $script:journalCalls -eq 0) "$provider no-op remains available"
        Set-Context $inspect $provider
        $outcome=Invoke-Boundary @{Cpu=3}
        Assert-Check ($outcome -eq 'SYNTHETIC_JOURNAL_BOUNDARY' -and $script:journalCalls -eq 1) "$provider live update remains available"
    }
    Set-Context $invalid[4].Inspect $provider
    $script:recoveredInspect=$valid
    $outcome=Invoke-Boundary @{Port=15433}
    Assert-Check ($outcome -eq 'SYNTHETIC_JOURNAL_BOUNDARY' -and $script:journalCalls -eq 1) 'fresh inspect after prior recovery is accepted'
    Set-Context $valid $provider
    $script:recoveredInspect=$invalid[4].Inspect
    $outcome=Invoke-Boundary @{Port=15433}
    Assert-Check ($outcome.StartsWith('CONTAINER_RECONCILE_MOUNT_TYPE_UNSUPPORTED:') -and $script:journalCalls -eq 0) 'fresh inspect after prior recovery is guarded'
    Set-Context $invalid[4].Inspect $provider
    $outcome=Invoke-Boundary @{Port=15433; WhatIf=$true}
    Assert-Check ($outcome.StartsWith('CONTAINER_RECONCILE_MOUNT_TYPE_UNSUPPORTED:') -and $script:journalCalls -eq 0) 'WhatIf rejects unsupported recreate without a new journal'
}
Assert-Check (-not (Test-Path -LiteralPath $script:syntheticRoot)) 'synthetic state directory was never created'
Write-Host "Container recreate mount boundary: $script:passed PASS; provider mutations 0."
