#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den expliziten SQL-2025-cgroup-v2-Labmodus getrennt unter Docker/Podman.
.DESCRIPTION
    Oeffentliche Manifest-Provisionierung, echte Python/R/Java-Roundtrips,
    oeffentlicher Restart, Mount-/Isolationsevidence und eigenes Cleanup.
    Lokale Diagnose und wiederverwendbare Images bleiben erhalten. Keine Hostumstellung.
.PARAMETER InstallViaReconcile
    Installiert die Sprachen nachtraeglich in einem eigenen Basislab und prueft
    zusaetzlich den Erhalt einer synthetischen Datenbank beim Containerwechsel.
.PARAMETER Language
    Gewuenschte Sprachen. Der Standard prueft das kombinierte Image;
    Java allein prueft den separaten finalen Java-Stage.
#>
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingConvertToSecureStringWithPlainText','',Justification='Ephemeral synthetic test password generated in memory.')]
param(
    [Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,
    [Parameter(Mandatory)][string]$EvidenceRoot,
    [ValidateSet('Python','R','Java')][string[]]$Language=@('Python','R','Java'),
    [switch]$InstallViaReconcile
)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$mutexName=if($IsWindows){'Global\SQL_Server_Lab_Runtime_Smoke'}else{'SQL_Server_Lab_Runtime_Smoke'}
$mutex=[Threading.Mutex]::new($false,$mutexName)
$locked=$false; $failure=$null; $cleanupFailure=$null; $lab=$null; $stateRoot=$null
$priorState=$env:SQL_SERVER_LAB_STATE
function Assert-V2 { param([bool]$Condition,[string]$Name)
    if(-not $Condition){throw "CGROUP_V2_ACCEPTANCE_FAILED: $Name"}
    Write-Host "PASS: $Name"
}
try {
    try {$locked=$mutex.WaitOne(0)} catch [Threading.AbandonedMutexException] {$locked=$true}
    if(-not $locked){throw 'CGROUP_V2_RUNTIME_RESERVED'}
    if(Test-Path -LiteralPath $EvidenceRoot){throw 'CGROUP_V2_EVIDENCE_ROOT_EXISTS'}
    $null=New-Item -ItemType Directory -Path $EvidenceRoot
    $EvidenceRoot=(Resolve-Path -LiteralPath $EvidenceRoot).Path
    $stateRoot=Join-Path $EvidenceRoot 'state'
    $env:SQL_SERVER_LAB_STATE=$stateRoot
    $runtime=& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider
    Assert-V2 ([bool]$runtime.Available) 'Provider CLI resolved'
    $runtimePath=[string]$runtime.Invocation
    $module=Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force -PassThru
    $hostEvidence=& $module {
        param($P)
        Get-LabExternalRuntimeHostCapability -Provider $P -SqlVersion 2025 -RequiredCgroupVersion 2
    } $Provider
    Assert-V2 ($hostEvidence.Supported -and $hostEvidence.CgroupVersion -eq '2' -and -not $hostEvidence.Rootless) 'Rootful cgroup-v2 provider'
    $token=[guid]::NewGuid().ToString('N')
    $runtimeIds=@($Language|ForEach-Object {'sql-'+$_.ToLowerInvariant()}|Sort-Object -Unique)
    Assert-V2 ($runtimeIds.Count -gt 0) 'At least one language selected'
    $manifest=[ordered]@{
        name="cgroup-v2-$($token.Substring(0,12))"; automation=@{mode='unattended'}
        instances=@(@{id='languages';version='2025';provider=$Provider;profile='performance'
            software=@($runtimeIds|ForEach-Object {@{id=$_;variant="$_-2025-shared-user-v2";scope='sqlExternalRuntime';optional=$false}})
        })
    }
    $manifestPath=Join-Path $EvidenceRoot 'manifest.json'
    $desiredSoftware=@($manifest.instances[0].software)
    if($InstallViaReconcile){$manifest.instances[0].software=@()}
    $manifest|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $manifestPath
    $password=ConvertTo-SecureString "CgroupV2_$token!Aa7" -AsPlainText -Force
    $lab=New-SqlServerLab -Manifest $manifestPath -SaPassword $password -StateRoot $stateRoot -NonInteractive
    Assert-V2 ($lab.State -eq 'Running') 'Public manifest provisioned'
    $instance=@($lab.Instances)[0]
    if($InstallViaReconcile) {
        & $module {
            param($I,$Password)
            $plain=ConvertFrom-LabSecureString -SecureString $Password
            try {
                $null=Invoke-SqlQuery -HostName $I.Host -Port $I.Port -SaPlain $plain -TimeoutSeconds 30 -Query "CREATE DATABASE CgroupV2Persistence; EXEC(N'USE CgroupV2Persistence; CREATE TABLE dbo.Marker(value int NOT NULL); INSERT dbo.Marker VALUES (42);');"
            } finally {$plain=$null}
        } $instance $password
        $manifest.instances[0].software=$desiredSoftware
        $manifest|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $manifestPath
        $installPlan=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -ManifestPath $manifestPath -InstanceId languages -StateRoot $stateRoot
        Assert-V2 ($installPlan.HighestChangeClass -eq 'recreate' -and @($installPlan.Actions).Count -eq 1) 'First installation plans one recreate'
        $installed=Invoke-SqlServerLabReconcileAction -RunId $lab.RunId -ManifestPath $manifestPath -InstanceId languages -ReadinessTimeoutSeconds 300 -StateRoot $stateRoot -Confirm:$false
        $installed.ExecutionSummary|ConvertTo-Json -Depth 20|Set-Content (Join-Path $EvidenceRoot 'reconcile-result.json')
        Assert-V2 ($installed.ExecutionSummary.Status -eq 'SUCCEEDED') ('Public reconcile first installation: '+(@($installed.ExecutionSummary.Errors) -join ' | '))
        $connection=Get-Content (Join-Path (Join-Path (Join-Path $stateRoot 'runs') $lab.RunId) 'connection-info.json') -Raw|ConvertFrom-Json -Depth 60
        $instance=@($connection.instances|Where-Object id -eq 'languages')[0]
    }
    Assert-V2 ($instance.ExternalRuntime.LaunchMode -eq 'sql2025-shared-user-v2' -and @($instance.ExternalRuntime.Receipts).Count -eq $runtimeIds.Count) 'Bound profile and selected SQL installation receipts'
    $probe={
        param($P,$I,$Password,$CheckMarker,$RuntimeIds)
        $results=@(foreach($id in $RuntimeIds) {
            $plan=Resolve-LabExternalRuntimePlan -SoftwareItem ([pscustomobject]@{Id=$id;Variant="$id-2025-shared-user-v2";Version=$null;InstallMethod='catalog';Packages=@();RequestSource='acceptance'}) -SqlVersion 2025 -Provider $P -OperatingSystem linux
            switch($id) {
                'sql-python' {Invoke-LabPythonExternalRuntimeProbe -Plan $plan -HostName $I.Host -Port $I.Port -SaPassword $Password}
                'sql-r' {Invoke-LabRExternalRuntimeProbe -Plan $plan -HostName $I.Host -Port $I.Port -SaPassword $Password}
                'sql-java' {Invoke-LabJavaExternalRuntimeProbe -Plan $plan -HostName $I.Host -Port $I.Port -SaPassword $Password -Database master}
            }
        })
        $plain=ConvertFrom-LabSecureString -SecureString $Password
        $query="SET NOCOUNT ON; SELECT 'SQLLAB_VERSION|' + CONVERT(varchar(32),SERVERPROPERTY('ProductVersion'));"
        if($CheckMarker){$query+=" SELECT 'SQLLAB_PERSISTENCE|' + CONVERT(varchar(10),value) FROM CgroupV2Persistence.dbo.Marker;"}
        try {$version=@(Invoke-SqlQuery -HostName $I.Host -Port $I.Port -SaPlain $plain -Query $query -TimeoutSeconds 30) -join "`n"}
        finally {$plain=$null}
        [pscustomobject]@{Probes=$results;Version=$version}
    }
    $mountProbe='set -eu; stat -fc %T /sys/fs/cgroup; cat /sys/fs/cgroup/cgroup.controllers; cat /proc/self/cgroup; if grep -Eq " - cgroup " /proc/self/mountinfo; then exit 78; fi; grep " - cgroup2 " /proc/self/mountinfo'
    foreach($phase in @('before','after')) {
        if($phase -eq 'after') {
            $restart=Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 300 -Force
            Assert-V2 ($restart.Status -eq 'RUNNING' -and $restart.Errors -eq 0) 'Public restart ready'
        }
        $mounts=@(& $runtimePath exec $instance.ContainerId bash -c $mountProbe 2>&1)
        Assert-V2 ($LASTEXITCODE -eq 0 -and $mounts -contains 'cgroup2fs' -and ($mounts -join ' ') -match '\bcpu\b') "${phase}: pure cgroup v2"
        $mounts|Set-Content (Join-Path $EvidenceRoot "$phase-mounts.txt")
        $result=& $module $probe $Provider $instance $password ([bool]$InstallViaReconcile) $runtimeIds
        Assert-V2 ($result.Version -match 'SQLLAB_VERSION\|17\.0\.5005\.3') "${phase}: SQL CU9"
        if($InstallViaReconcile){Assert-V2 ($result.Version -match 'SQLLAB_PERSISTENCE\|42') "${phase}: SQL data survived recreate"}
        Assert-V2 (@($result.Probes).Count -eq $runtimeIds.Count -and @($result.Probes|Where-Object {$_.Status -ne 'PASS' -or $_.WorkerIdentity -ne 'mssql_launchpadd'}).Count -eq 0) "${phase}: selected language roundtrip and worker"
        $result|ConvertTo-Json -Depth 20|Set-Content (Join-Path $EvidenceRoot "$phase-probes.json")
    }
    $inspect=@(& $runtimePath inspect $instance.ContainerId)|ConvertFrom-Json -Depth 60
    Assert-V2 (-not $inspect.HostConfig.Privileged -and @($inspect.Mounts|Where-Object Destination -eq '/sys/fs/cgroup').Count -eq 0) 'No privileged container and no cgroup bind'
    $plan=Get-SqlServerLabReconcilePlan -RunId $lab.RunId -ManifestPath $manifestPath -InstanceId languages -StateRoot $stateRoot
    Assert-V2 ([bool]$plan.IsNoOp) 'Persisted shared-user variants survive reconcile planning'
}
catch {$failure=$_}
finally {
    if($stateRoot -and (Test-Path (Join-Path $stateRoot 'runs'))) {
        # The fresh private state root contains only this acceptance's own runs,
        # including a partially created run when New-SqlServerLab did not return.
        foreach($runDir in @(Get-ChildItem (Join-Path $stateRoot 'runs') -Directory)) {
            try {
                $cleanup=Remove-SqlServerLab -RunId $runDir.Name -StateRoot $stateRoot -Force -Confirm:$false
                Assert-V2 ($cleanup.Status -eq 'REMOVED') 'Owned run cleanup'
            } catch {$cleanupFailure=$_}
        }
    }
    $env:SQL_SERVER_LAB_STATE=$priorState
    if($locked){$mutex.ReleaseMutex()};$mutex.Dispose()
}
if($cleanupFailure){throw "CGROUP_V2_RECOVERY_REQUIRED: $cleanupFailure; primary: $failure"}
if($failure){throw $failure}
@{status='PASS';provider=$Provider;languages=$runtimeIds;sqlVersion='17.0.5005.3';mode='sql2025-shared-user-v2';cleanup='REMOVED';reconcile=$(if($InstallViaReconcile){'FIRST_INSTALL_AND_NO_OP'}else{'NO_OP_ONLY'})}|ConvertTo-Json|Set-Content (Join-Path $EvidenceRoot 'result.json')
