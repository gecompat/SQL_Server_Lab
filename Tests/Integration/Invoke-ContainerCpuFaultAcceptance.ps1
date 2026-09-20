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
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[switch]$HardInterrupt)
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-cpu-fault-'+$Provider+'-'+[guid]::NewGuid().ToString('N'))
$stateRoot=Join-Path $testRoot 'state'
$operationId=[guid]::NewGuid().ToString()
$previous=@{}
foreach ($name in @('SQL_SERVER_LAB_STATE','SQL_SERVER_LAB_RESOURCE_LIFECYCLE','SQL_SERVER_LAB_TEST_OPERATION_ID','DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY')) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$lab=$null; $module=$null; $binding=$null; $child=$null; $secret=$null; $completed=$false; $cleanupSucceeded=$false
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
    $journalPath=Join-Path $testRoot ($operationId+'.cpu-fault.json')
    if ($HardInterrupt) {
        & $module { param($Binding,$Target,$Password) Test-LabCpuFaultSql $Binding $Target $Password } $binding $target $secret
        $targetHash=& $module { param($Target) Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $Target) } $target
        $inputPath=Join-Path $testRoot 'child.json'
        # Only the operation key and target cross into the child; never the SA secret.
        [IO.File]::WriteAllText($inputPath,(@{Target=$target; Directory=$testRoot; Key=[Convert]::ToBase64String($key)} | ConvertTo-Json -Depth 15))
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach ($name in @('SQLCMDPASSWORD','MSSQL_SA_PASSWORD','SA_PASSWORD','SQL_SERVER_LAB_STATE')) { $null=$start.Environment.Remove($name) }
        foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $repoRoot 'Tests/Fixtures/ContainerCpuFault/Invoke-NativeInterruptedFixture.ps1'),'-InputPath',$inputPath)) { $start.ArgumentList.Add($argument) }
        $child=[Diagnostics.Process]::Start($start)
        $childOut=$child.StandardOutput.ReadToEndAsync(); $childError=$child.StandardError.ReadToEndAsync()
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $checkpoint=$null
        while (-not $child.HasExited -and $clock.ElapsedMilliseconds -lt 20000) {
            if (Test-Path -LiteralPath $journalPath) {
                $candidate=& $module { param($Path,$Key,$Hash) Read-LabCpuFaultJournal $Path $Key $Hash } $journalPath $key $targetHash
                if ($candidate.AppliedVerified) { $checkpoint=$candidate; break }
            }
            [Threading.Thread]::Sleep(50)
        }
        if ($null -eq $checkpoint -or $child.HasExited) { throw 'CPU_FAULT_ACCEPTANCE_CHECKPOINT_MISSING' }
        if ($checkpoint.Status -ne 'RESTORE_REQUIRED' -or $checkpoint.PrimaryStatus -ne 'NOT_EXECUTED' -or $checkpoint.CleanupStatus -ne 'PENDING' -or $checkpoint.CleanupAttempts -ne 0 -or $checkpoint.RestoredVerified) { throw 'CPU_FAULT_ACCEPTANCE_CHECKPOINT_INVALID' }
        $sameBaseline=& $module { param($Left,$Right) (ConvertTo-LabCpuFaultCanonicalJson $Left) -ceq (ConvertTo-LabCpuFaultCanonicalJson $Right) } $baseline $checkpoint.Baseline
        if (-not $sameBaseline) { throw 'CPU_FAULT_ACCEPTANCE_BASELINE_MISMATCH' }
        $child.Kill($true)
        if (-not $child.WaitForExit(5000)) { throw 'CPU_FAULT_ACCEPTANCE_CHILD_TERMINATION_UNCONFIRMED' }
        $applied=& $module { param($Binding,$Target) Get-LabCpuFaultSnapshot $Binding $Target } $binding $target
        $expected=$checkpoint.Baseline | ConvertTo-Json -Depth 15 -Compress | ConvertFrom-Json -AsHashtable
        if ($checkpoint.Mode -eq 'NANO') { $expected.Cpu.NanoCpus=1000000000 } else { $expected.Cpu.CpuQuota=100000 }
        if ($checkpoint.Mode -eq 'PODMAN_QUOTA') { $expected.Cpu.NanoCpus=1000000000 }
        $sameApplied=& $module { param($Left,$Right) (ConvertTo-LabCpuFaultCanonicalJson $Left) -ceq (ConvertTo-LabCpuFaultCanonicalJson $Right) } $applied $expected
        if (-not $sameApplied) { throw 'CPU_FAULT_ACCEPTANCE_CHILD_FINALLY_RAN' }
        # Observe the real native boundary during parent resume; activation is forbidden.
        & $module {
            $script:CpuFaultAcceptanceNative=${function:Invoke-LabCpuFaultNative}
            $script:CpuFaultAcceptanceRestores=0; $script:CpuFaultAcceptanceActivations=0; $script:CpuFaultAcceptanceSql=0
            function script:Invoke-LabCpuFaultNative {
                param($Binding,[string[]]$Arguments,[int]$TimeoutMilliseconds=5000,[Security.SecureString]$Password)
                if ($Arguments[0] -eq 'update') {
                    if ($Arguments -contains '1' -or ($Arguments -contains '100000' -and $Arguments -notcontains '200000')) {
                        $script:CpuFaultAcceptanceActivations++; throw 'CPU_FAULT_ACCEPTANCE_ACTIVATION_REPLAY'
                    }
                    $script:CpuFaultAcceptanceRestores++
                }
                if ($Arguments[0] -eq 'exec') { $script:CpuFaultAcceptanceSql++ }
                & $script:CpuFaultAcceptanceNative $Binding $Arguments $TimeoutMilliseconds $Password
            }
        }
        $result=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerCpuFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password -Resume } $target $testRoot $key $secret
        if ($result.Status -ne 'INTERRUPTED' -or $result.PrimaryStatus -ne 'INTERRUPTED' -or -not $result.AppliedVerified -or -not $result.RestoredVerified -or $result.CleanupStatus -ne 'PASSED') { throw 'CPU_FAULT_ACCEPTANCE_INTERRUPTED_RESUME_FAILED' }
        $restored=& $module { param($Binding,$Target) Get-LabCpuFaultSnapshot $Binding $Target } $binding $target
        $sameRestored=& $module { param($Left,$Right) (ConvertTo-LabCpuFaultCanonicalJson $Left) -ceq (ConvertTo-LabCpuFaultCanonicalJson $Right) } $restored $checkpoint.Baseline
        $counts=& $module { @($script:CpuFaultAcceptanceActivations,$script:CpuFaultAcceptanceRestores,$script:CpuFaultAcceptanceSql) }
        if (-not $sameRestored -or $counts[0] -ne 0 -or $counts[1] -ne 1 -or $counts[2] -ne 1) { throw 'CPU_FAULT_ACCEPTANCE_RESTORE_EVIDENCE_FAILED' }
    }
    else {
        $result=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerCpuFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password } $target $testRoot $key $secret
        if ($result.Status -ne 'PASSED' -or -not $result.AppliedVerified -or -not $result.RestoredVerified -or $result.CleanupStatus -ne 'PASSED') { throw 'CPU_FAULT_ACCEPTANCE_PULSE_FAILED' }
    }
    $journalBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))
    $resume=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerCpuFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password -Resume } $target $testRoot $key $secret
    if (($resume | ConvertTo-Json -Compress) -cne ($result | ConvertTo-Json -Compress) -or $journalBytes -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))) { throw 'CPU_FAULT_ACCEPTANCE_RESUME_FAILED' }
    if ($HardInterrupt) {
        $finalCounts=& $module { @($script:CpuFaultAcceptanceActivations,$script:CpuFaultAcceptanceRestores,$script:CpuFaultAcceptanceSql) }
        if (($counts -join ',') -cne ($finalCounts -join ',')) { throw 'CPU_FAULT_ACCEPTANCE_TERMINAL_MUTATION' }
        Write-Host 'CPU_FAULT_HARD_INTERRUPT: checkpoint=AUTHENTICATED child=TERMINATED primary=INTERRUPTED restore=EXACT sql=PASSED activationsOnResume=0 terminal=BYTE_IDENTICAL'
    }
    $completed=$true
}
finally {
    try {
        if ($child -and -not $child.HasExited) {
            $child.Kill($true)
            if (-not $child.WaitForExit(5000)) { throw 'CPU_FAULT_ACCEPTANCE_CHILD_TERMINATION_UNCONFIRMED' }
        }
        if ($module) {
            & $module {
                if (Get-Variable -Name CpuFaultAcceptanceNative -Scope Script -ErrorAction SilentlyContinue) {
                    Set-Item -Path Function:script:Invoke-LabCpuFaultNative -Value $script:CpuFaultAcceptanceNative
                    Remove-Variable -Name CpuFaultAcceptanceNative -Scope Script
                }
            }
        }
        if ($module -and (Test-Path -LiteralPath (Join-Path $stateRoot 'runs'))) {
            # The unique root existed only for this operation; no ambient state discovery.
            $runs=@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'runs') -Directory)
            foreach ($run in $runs) {
                $removed=Remove-SqlServerLab -RunId $run.Name -StateRoot $stateRoot -Force -Confirm:$false
                if ($removed.Status -ne 'REMOVED' -or $removed.Errors -ne 0) { throw 'CPU_FAULT_ACCEPTANCE_RUN_CLEANUP_FAILED' }
                $volumes=& $module { param($Binding,$RunId) Invoke-LabCpuFaultNative $Binding @('volume','ls','--filter',('label=sql-server-lab.run-id='+$RunId),'--format','{{.Name}}') } $binding $run.Name
                if ($volumes) { throw 'CPU_FAULT_ACCEPTANCE_VOLUME_REMAINS' }
            }
            $remaining=& $module { param($Binding,$OperationId) Invoke-LabCpuFaultNative $Binding @('ps','-a','--filter',('label=sql-server-lab.test-operation-id='+$OperationId),'--format','{{.ID}}') } $binding $operationId
            if ($remaining) { throw 'CPU_FAULT_ACCEPTANCE_CLEANUP_REMAINS' }
        }
        $cleanupSucceeded=$true
    }
    catch { Write-Warning 'CPU_FAULT_ACCEPTANCE_CLEANUP_FAILED: local state retained' }
    if ($child) { $child.Dispose() }
    if ($secret) { $secret.Dispose() }
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
    if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    if ($cleanupSucceeded -and (Test-Path -LiteralPath $testRoot)) {
        if (-not ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))) -or -not (Split-Path $testRoot -Leaf).StartsWith('sql-lab-cpu-fault-')) { throw 'CPU_FAULT_ACCEPTANCE_CLEANUP_PATH_UNSAFE' }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    Write-Host ('CPU_FAULT_ACCEPTANCE: provider='+$Provider+' hardInterrupt='+$HardInterrupt.IsPresent+' primary='+$(if ($completed) {'PASSED'} else {'FAILED'})+' cleanup='+$(if ($cleanupSucceeded) {'PASSED'} else {'RECOVERY_REQUIRED'}))
    if (-not $cleanupSucceeded) { throw 'CPU_FAULT_ACCEPTANCE_RECOVERY_REQUIRED' }
}
