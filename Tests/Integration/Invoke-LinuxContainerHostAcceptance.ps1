#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft SQL 2025 mit Python/R/Java auf einem vorbereiteten Linux-Containerhost.
.DESCRIPTION
    Eigener Run und temporaerer State; echte SQL-Sprachprobes vor/nach Restart.
    Kein Reconcile-Nachweis. Wiederverwendbare Images bleiben im Providercache.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Per-run synthetic test password generated in memory; no real credentials are embedded or logged.')]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][string]$RepositoryRoot,
    [Parameter(Mandatory)][string]$EvidencePath
)
$ErrorActionPreference='Stop'
if(-not $IsLinux){throw 'LINUX_HOST_ACCEPTANCE_REQUIRES_LINUX'}
$token=[guid]::NewGuid().ToString('N')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) "sqllab-host-acceptance-$token"
$stateRoot=Join-Path $testRoot 'state'
$priorState=$env:SQL_SERVER_LAB_STATE
$priorNetwork=$env:SQL_SERVER_LAB_PODMAN_NETWORK
$priorSubnet=$env:SQL_SERVER_LAB_PODMAN_SUBNET
$lab=$null;$network=$null;$cleanupStatus=$null;$failure=$null
function Assert-HostAcceptance {
    param([bool]$Condition,[string]$Name)
    if(-not $Condition){throw "LINUX_HOST_ACCEPTANCE_FAILED: $Name"}
    Write-Host "PASS: $Name"
}
try {
    New-Item -ItemType Directory -Path $testRoot|Out-Null
    & chmod 700 $testRoot
    if($LASTEXITCODE -ne 0){throw 'LINUX_HOST_ACCEPTANCE_PERMISSIONS_FAILED'}
    $env:SQL_SERVER_LAB_STATE=$stateRoot
    $runtime=@(& (Join-Path $RepositoryRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    Assert-HostAcceptance ([bool]$runtime.Available) 'Provider CLI resolved'
    $runtimePath=[string]$runtime.Invocation
    if($Provider -eq 'podman') {
        $network="SQLLAB_HOST_TEST_$($token.Substring(0,12))"
        $env:SQL_SERVER_LAB_PODMAN_NETWORK=$network
        $env:SQL_SERVER_LAB_PODMAN_SUBNET='10.254.28.0/24'
    }
    $manifest=[ordered]@{
        name='linux-container-host-acceptance';automation=@{mode='unattended'}
        instances=@(@{id='languages';version='2025';provider=$Provider;profile='performance'
            software=@('sql-python','sql-r','sql-java'|ForEach-Object {@{id=$_;scope='sqlExternalRuntime'}})
            # R/BLAS also consumes tasks on hosts with many visible CPUs.
            # Keep a finite pool limit with room for all three language probes.
            serverConfig=@{externalScripts=@{enabled=$true;resourceGovernor=@{maxMemoryPercent=40;maxProcesses=128}}}
        })
    }
    $manifestPath=Join-Path $testRoot 'manifest.json'
    $manifest|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $manifestPath
    $password=ConvertTo-SecureString "HostTest_$token!Aa7" -AsPlainText -Force
    $module=Import-Module (Join-Path $RepositoryRoot 'SqlServerLab.psd1') -Force -PassThru
    $lab=New-SqlServerLab -Manifest $manifestPath -SaPassword $password -StateRoot $stateRoot -NonInteractive
    Assert-HostAcceptance ([string]$lab.State -eq 'Running') 'SQL 2025 provisioned through public lifecycle'
    $instance=@($lab.Instances)[0]
    Assert-HostAcceptance ([string]$instance.ExternalRuntime.Status -eq 'EXTENSIONS_READY_RUN' -and @($instance.ExternalRuntime.Receipts).Count -eq 3) 'All three language installation receipts ready'
    $probeOperation={
        param($ProviderName,$LabInstance,$Password)
        $plans=@('sql-python','sql-r','sql-java'|ForEach-Object {
            Resolve-LabExternalRuntimePlan -SoftwareItem ([pscustomobject]@{
                Id=$_;Version=$null;Variant=$null;InstallMethod=$null;Packages=@();RequestSource='host-acceptance'
            }) -SqlVersion '2025' -Provider $ProviderName -OperatingSystem linux
        })
        $imagePlan=New-LabExternalRuntimeContainerImagePlan -Provider $ProviderName -SqlVersion '2025' -SoftwarePlans $plans
        $hostStatus=Test-LabExternalRuntimeContainerHost -Provider $ProviderName -ImagePlan $imagePlan
        $recover={
            Restart-LabExternalRuntimeContainer -Provider $ProviderName -ContainerIdOrName ([string]$LabInstance.ContainerId)
            $ready=Wait-SqlReady -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password -TimeoutSeconds 300 -ExpectedMajorVersion 17 -Provider $ProviderName -ContainerIdOrName ([string]$LabInstance.ContainerId)
            if(-not $ready.Ready){throw 'LINUX_HOST_ACCEPTANCE_SQL_NOT_READY'}
        }
        $probes=@(foreach($plan in $plans) {
            switch([string]$plan.Language) {
                'Python' {Invoke-LabExternalRuntimeProbeWithRetry -RecoveryOperation $recover -Operation {Invoke-LabPythonExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password}}
                'R' {Invoke-LabExternalRuntimeProbeWithRetry -RecoveryOperation $recover -Operation {Invoke-LabRExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password}}
                'Java' {Invoke-LabExternalRuntimeProbeWithRetry -RecoveryOperation $recover -Operation {Invoke-LabJavaExternalRuntimeProbe -Plan $plan -HostName ([string]$LabInstance.Host) -Port ([int]$LabInstance.Port) -SaPassword $Password -Database master}}
            }
        })
        [pscustomobject]@{Host=$hostStatus;Probes=$probes}
    }
    $before=& $module $probeOperation $Provider $instance $password
    Assert-HostAcceptance ($before.Host.Status -eq 'READY' -and $before.Host.CgroupVersion -eq '1' -and -not $before.Host.Rootless) 'Rootful provider with cgroup v1'
    Assert-HostAcceptance (@($before.Probes).Count -eq 3 -and @($before.Probes|Where-Object Status -ne 'PASS').Count -eq 0) 'Python/R/Java SQL probes before restart'
    $restart=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 300 -Force
    Assert-HostAcceptance ($restart.Status -eq 'RUNNING' -and $restart.Errors -eq 0) 'Public SQL restart succeeded'
    $after=& $module $probeOperation $Provider $instance $password
    Assert-HostAcceptance (@($after.Probes).Count -eq 3 -and @($after.Probes|Where-Object Status -ne 'PASS').Count -eq 0) 'Python/R/Java SQL probes after restart'
} catch {
    $failure=$_
    if($lab -and $instance -and $instance.ContainerId) {
        try {
            $diagnostic=Join-Path $testRoot 'provider-failure.log'
            & $runtimePath logs --tail 120 ([string]$instance.ContainerId) *> $diagnostic
            Write-Host "Failure diagnostics retained: $diagnostic"
        } catch {Write-Warning 'LINUX_HOST_ACCEPTANCE_DIAGNOSTICS_UNAVAILABLE'}
    }
}
finally {
    if($lab) {
        try {
            $cleanup=Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false
            Assert-HostAcceptance ($cleanup.Status -eq 'REMOVED') 'Owned SQL run cleanup completed'
            $cleanupStatus='REMOVED'
        } catch {Write-Warning 'LINUX_HOST_ACCEPTANCE_CLEANUP_FAILED';$failure=$_}
    }
    if($network -and $runtimePath) {
        & $runtimePath network exists $network
        if($LASTEXITCODE -eq 0) {
            & $runtimePath network rm $network 1>$null
            if($LASTEXITCODE -ne 0){$failure=[Exception]::new('LINUX_HOST_ACCEPTANCE_NETWORK_CLEANUP_FAILED')}
        }
    }
    $env:SQL_SERVER_LAB_STATE=$priorState
    $env:SQL_SERVER_LAB_PODMAN_NETWORK=$priorNetwork
    $env:SQL_SERVER_LAB_PODMAN_SUBNET=$priorSubnet
    if(-not $failure -and $cleanupStatus -eq 'REMOVED') {Remove-Item -LiteralPath $testRoot -Recurse -Force}
}
if($failure){throw $failure}
if($cleanupStatus -ne 'REMOVED'){throw 'LINUX_HOST_ACCEPTANCE_CLEANUP_NOT_CONFIRMED'}
$evidence=[ordered]@{
    contract='SqlServerLab.LinuxContainerHostAcceptance/1.0';status='PASS';provider=$Provider;sqlVersion='2025';cgroupVersion='1'
    languages=@('Python','R','Java');beforeRestart='PASS';afterRestart='PASS';cleanup=$cleanupStatus
    reconcile='NOT_EXECUTED';createdAt=[DateTime]::UtcNow.ToString('o')
}
$directory=Split-Path $EvidencePath -Parent
if($directory){New-Item -ItemType Directory -Path $directory -Force|Out-Null}
$evidence|ConvertTo-Json -Depth 10|Set-Content -LiteralPath $EvidencePath
Write-Host "PASS: $Provider Linux container host acceptance"
