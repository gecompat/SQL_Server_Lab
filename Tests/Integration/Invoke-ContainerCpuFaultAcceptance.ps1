#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt den internen CPU-Puls getrennt auf einem frischen Docker-/Podman-SQL-2025-Run.
.DESCRIPTION
    Verwendet einen eigenen temporären State-Root, operationseigene Lifecycle-Labels
    und ausschließlich eigene Run-IDs. Bestehende Labs werden nicht inventarisiert.
    Behält bei Cleanupfehlern den lokalen State als Recovery-Evidence.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-cpu-fault-'+$Provider+'-'+[guid]::NewGuid().ToString('N'))
$stateRoot=Join-Path $testRoot 'state'
$operationId=[guid]::NewGuid().ToString()
$previous=@{}
foreach ($name in @('SQL_SERVER_LAB_STATE','SQL_SERVER_LAB_RESOURCE_LIFECYCLE','SQL_SERVER_LAB_TEST_OPERATION_ID','DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY')) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$lab=$null; $module=$null; $binding=$null; $completed=$false; $cleanupSucceeded=$false
$mutex=[Threading.Mutex]::new($false,$(if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }))
$acquired=$false
try {
    $readiness=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if ($readiness.Status -notin @('READY','READY_WITH_WARNINGS') -or @($readiness.MissingPrerequisites).Count -gt 0) { throw 'CPU_FAULT_ACCEPTANCE_READINESS_BLOCKED' }
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if (-not $resolution.Available) { throw 'CPU_FAULT_ACCEPTANCE_CLI_UNAVAILABLE' }
    $acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(30))
    if (-not $acquired) { throw 'CPU_FAULT_ACCEPTANCE_LOCK_TIMEOUT' }
    $null=New-Item -ItemType Directory -Path $testRoot
    $env:SQL_SERVER_LAB_STATE=$stateRoot
    $env:SQL_SERVER_LAB_RESOURCE_LIFECYCLE='test'
    $env:SQL_SERVER_LAB_TEST_OPERATION_ID=$operationId
    Import-Module (Join-Path $repoRoot 'SqlServerLab.psd1') -Force
    $module=Get-Module SqlServerLab
    $binding=& $module { param($Provider) New-LabCpuFaultRuntimeBinding $Provider } $Provider
    if ($Provider -eq 'docker') { $env:DOCKER_HOST=$binding.Arguments[1]; $env:DOCKER_CONTEXT=$null }
    elseif ($binding.Arguments.Count -gt 1) { $env:CONTAINER_HOST=$binding.Arguments[2]; $env:CONTAINER_SSHKEY=$binding.Arguments[4]; $env:CONTAINER_CONNECTION=$null }
    $createdAfter=[DateTimeOffset]::UtcNow.ToString('o')
    $secret=[Security.SecureString]::new()
    foreach ($character in ('CpuFault_'+[guid]::NewGuid().ToString('N')+'!Aa7').ToCharArray()) { $secret.AppendChar($character) }
    $secret.MakeReadOnly()
    $key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $lab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 2 -MemoryMB 2048 -AutoStart off -LabName ('cpu-fault-'+$operationId.Substring(0,8)) -SaPassword $secret -StateRoot $stateRoot -SkipAssessment
    $connection=Get-Content -LiteralPath (Join-Path $stateRoot ('runs/'+$lab.RunId+'/connection-info.json')) -Raw | ConvertFrom-Json
    $instance=@($connection.instances)[0]
    $target=[ordered]@{ ContractVersion='SqlServerLab.InternalContainerCpuFaultTarget/0.1'; Profile='container.cpu-limit'; Provider=$Provider; OperationId=$operationId; RunId=[string]$lab.RunId; ScopeId=[string]$lab.ScopeId; InstanceId=[string]$instance.id; ContainerId=[string]$instance.containerId; CreatedAfterUtc=$createdAfter }
    $baseline=& $module { param($Binding,$Target) Get-LabCpuFaultSnapshot $Binding $Target -Fresh } $binding $target
    Write-Host ('CPU_FAULT_BASELINE: '+($baseline.Cpu | ConvertTo-Json -Compress))
    $result=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerCpuFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password } $target $testRoot $key $secret
    if ($result.Status -ne 'PASSED' -or -not $result.AppliedVerified -or -not $result.RestoredVerified -or $result.CleanupStatus -ne 'PASSED') { throw 'CPU_FAULT_ACCEPTANCE_PULSE_FAILED' }
    $resume=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerCpuFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password -Resume } $target $testRoot $key $secret
    if (($resume | ConvertTo-Json -Compress) -cne ($result | ConvertTo-Json -Compress)) { throw 'CPU_FAULT_ACCEPTANCE_RESUME_FAILED' }
    $completed=$true
}
finally {
    try {
        if ($module -and (Test-Path -LiteralPath (Join-Path $stateRoot 'runs'))) {
            # The unique root existed only for this operation; no ambient state discovery.
            $runs=@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'runs') -Directory)
            foreach ($run in $runs) { Remove-SqlServerLab -RunId $run.Name -StateRoot $stateRoot -Force -Confirm:$false | Out-Null }
            $remaining=& $module { param($Binding,$OperationId) Invoke-LabCpuFaultNative $Binding @('ps','-a','--filter',('label=sql-server-lab.test-operation-id='+$OperationId),'--format','{{.ID}}') } $binding $operationId
            if ($remaining) { throw 'CPU_FAULT_ACCEPTANCE_CLEANUP_REMAINS' }
        }
        $cleanupSucceeded=$true
    }
    catch { Write-Warning 'CPU_FAULT_ACCEPTANCE_CLEANUP_FAILED: local state retained' }
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
    if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    if ($cleanupSucceeded -and (Test-Path -LiteralPath $testRoot)) {
        if (-not ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))) -or -not (Split-Path $testRoot -Leaf).StartsWith('sql-lab-cpu-fault-')) { throw 'CPU_FAULT_ACCEPTANCE_CLEANUP_PATH_UNSAFE' }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    Write-Host ('CPU_FAULT_ACCEPTANCE: provider='+$Provider+' primary='+$(if ($completed) {'PASSED'} else {'FAILED'})+' cleanup='+$(if ($cleanupSucceeded) {'PASSED'} else {'RECOVERY_REQUIRED'}))
    if (-not $cleanupSucceeded) { throw 'CPU_FAULT_ACCEPTANCE_RECOVERY_REQUIRED' }
}
