#Requires -Version 7.2
<#
.SYNOPSIS
    Belegt den internen Memory-Puls getrennt auf einem frischen Docker-/Podman-SQL-2025-Run.
.DESCRIPTION
    Verwendet einen eigenen temporären State-Root, operationseigene Lifecycle-Labels
    und ausschließlich eigene Run-IDs. Bestehende Labs werden nicht inventarisiert.
    Behält bei Cleanupfehlern den lokalen State als Recovery-Evidence.
#>
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('docker','podman')][string]$Provider,[switch]$HardInterrupt,[switch]$StopAfterInterrupt)
$ErrorActionPreference='Stop'
if ($StopAfterInterrupt -and -not $HardInterrupt) { throw 'MEMORY_FAULT_ACCEPTANCE_STOP_REQUIRES_INTERRUPT' }
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-memory-fault-'+$Provider+'-'+[guid]::NewGuid().ToString('N'))
$stateRoot=Join-Path $testRoot 'state'
$operationId=[guid]::NewGuid().ToString()
$previous=@{}
foreach ($name in @('SQL_SERVER_LAB_STATE','SQL_SERVER_LAB_RESOURCE_LIFECYCLE','SQL_SERVER_LAB_TEST_OPERATION_ID','DOCKER_HOST','DOCKER_CONTEXT','CONTAINER_HOST','CONTAINER_CONNECTION','CONTAINER_SSHKEY')) { $previous[$name]=[Environment]::GetEnvironmentVariable($name,'Process') }
$lab=$null; $module=$null; $binding=$null; $child=$null; $secret=$null; $completed=$false; $cleanupSucceeded=$false
$mutex=[Threading.Mutex]::new($false,$(if ($IsWindows) { 'Global\SQL_Server_Lab_Runtime_Smoke' } else { 'SQL_Server_Lab_Runtime_Smoke' }))
$acquired=$false
try {
    $readiness=& (Join-Path $repoRoot 'Tools/Test-SqlServerLabClientReadiness.ps1') -Provider $Provider -Operation Create
    if ($readiness.Status -notin @('READY','READY_WITH_WARNINGS') -or @($readiness.MissingPrerequisites).Count -gt 0) { throw 'MEMORY_FAULT_ACCEPTANCE_READINESS_BLOCKED' }
    $resolution=@(& (Join-Path $repoRoot 'Tools/Initialize-SqlServerLabHostTools.ps1') -Name $Provider)[0]
    if (-not $resolution.Available) { throw 'MEMORY_FAULT_ACCEPTANCE_CLI_UNAVAILABLE' }
    $acquired=$mutex.WaitOne([TimeSpan]::FromSeconds(30))
    if (-not $acquired) { throw 'MEMORY_FAULT_ACCEPTANCE_LOCK_TIMEOUT' }
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
    foreach ($character in ('MemoryFault_'+[guid]::NewGuid().ToString('N')+'!Aa7').ToCharArray()) { $secret.AppendChar($character) }
    $secret.MakeReadOnly()
    $key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
    $lab=New-SqlServerLab -Version 2025 -Provider $Provider -Profile compact -Cpu 2 -MemoryMB 3072 -AutoStart off -LabName ('memory-fault-'+$operationId.Substring(0,8)) -SaPassword $secret -StateRoot $stateRoot -SkipAssessment
    $connection=Get-Content -LiteralPath (Join-Path $stateRoot ('runs/'+$lab.RunId+'/connection-info.json')) -Raw | ConvertFrom-Json
    $instance=@($connection.instances)[0]
    $target=[ordered]@{ ContractVersion='SqlServerLab.InternalContainerMemoryFaultTarget/0.1'; Profile='container.memory-limit'; Provider=$Provider; OperationId=$operationId; RunId=[string]$lab.RunId; ScopeId=[string]$lab.ScopeId; InstanceId=[string]$instance.id; ContainerId=[string]$instance.containerId; CreatedAfterUtc=$createdAfter }
    $baseline=& $module { param($Binding,$Target) Get-LabMemoryFaultSnapshot $Binding $Target -Fresh -RequireRunning } $binding $target
    Write-Host ('MEMORY_FAULT_BASELINE: '+($baseline.Memory | ConvertTo-Json -Compress))
    $journalPath=Join-Path $testRoot ($operationId+'.memory-fault.json')
    if ($HardInterrupt) {
        & $module { param($Binding,$Target,$Password) Test-LabMemoryFaultSql $Binding $Target $Password } $binding $target $secret
        $targetHash=& $module { param($Target) Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $Target) } $target
        $inputPath=Join-Path $testRoot 'child.json'
        # Only the operation key and target cross into the child; never the SA secret.
        [IO.File]::WriteAllText($inputPath,(@{Target=$target; Directory=$testRoot; Key=[Convert]::ToBase64String($key)} | ConvertTo-Json -Depth 15))
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach ($name in @('SQLCMDPASSWORD','MSSQL_SA_PASSWORD','SA_PASSWORD','SQL_SERVER_LAB_STATE')) { $null=$start.Environment.Remove($name) }
        foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $repoRoot 'Tests/Fixtures/ContainerMemoryFault/Invoke-InterruptedFixture.ps1'),'-InputPath',$inputPath,'-Native')) { $start.ArgumentList.Add($argument) }
        $child=[Diagnostics.Process]::Start($start)
        $childOut=$child.StandardOutput.ReadToEndAsync(); $childError=$child.StandardError.ReadToEndAsync()
        $clock=[Diagnostics.Stopwatch]::StartNew()
        $checkpoint=$null
        while (-not $child.HasExited -and $clock.ElapsedMilliseconds -lt 20000) {
            if (Test-Path -LiteralPath $journalPath) {
                $candidate=& $module { param($Path,$Key,$Hash) Read-LabMemoryFaultJournal $Path $Key $Hash } $journalPath $key $targetHash
                if ($candidate.AppliedVerified) { $checkpoint=$candidate; break }
            }
            [Threading.Thread]::Sleep(50)
        }
        if ($null -eq $checkpoint -or $child.HasExited) { throw 'MEMORY_FAULT_ACCEPTANCE_CHECKPOINT_MISSING' }
        if ($checkpoint.Status -ne 'RESTORE_REQUIRED' -or $checkpoint.PrimaryStatus -ne 'NOT_EXECUTED' -or $checkpoint.CleanupStatus -ne 'PENDING' -or $checkpoint.CleanupAttempts -ne 0 -or $checkpoint.LimitRestoredVerified -or $checkpoint.SqlRestoredVerified) { throw 'MEMORY_FAULT_ACCEPTANCE_CHECKPOINT_INVALID' }
        $sameBaseline=& $module { param($Left,$Right) (ConvertTo-LabCpuFaultCanonicalJson $Left) -ceq (ConvertTo-LabCpuFaultCanonicalJson $Right) } $baseline $checkpoint.Baseline
        if (-not $sameBaseline) { throw 'MEMORY_FAULT_ACCEPTANCE_BASELINE_MISMATCH' }
        $child.Kill($true)
        if (-not $child.WaitForExit(5000)) { throw 'MEMORY_FAULT_ACCEPTANCE_CHILD_TERMINATION_UNCONFIRMED' }
        $applied=& $module { param($Binding,$Target) Get-LabMemoryFaultSnapshot $Binding $Target } $binding $target
        $expected=$checkpoint.Baseline | ConvertTo-Json -Depth 15 -Compress | ConvertFrom-Json -AsHashtable
        $expected.Memory.Memory=2684354560
        $sameApplied=& $module { param($Left,$Right) (ConvertTo-LabCpuFaultCanonicalJson $Left) -ceq (ConvertTo-LabCpuFaultCanonicalJson $Right) } $applied $expected
        if (-not $sameApplied) { throw 'MEMORY_FAULT_ACCEPTANCE_CHILD_FINALLY_RAN' }
        if ($StopAfterInterrupt) {
            # Only the exact freshly owned target above is stopped by this fixture.
            & $module { param($Binding,$Target) $null=Get-LabMemoryFaultSnapshot $Binding $Target -RequireRunning; $null=Invoke-LabCpuFaultNative $Binding @('stop','--time','5',$Target.ContainerId) 15000 } $binding $target
        }
        # Observe the real native boundary during parent resume; activation is forbidden.
        & $module {
            $script:MemoryFaultAcceptanceNative=${function:Invoke-LabCpuFaultNative}
            $script:MemoryFaultAcceptanceRestores=0; $script:MemoryFaultAcceptanceActivations=0; $script:MemoryFaultAcceptanceSql=0
            function script:Invoke-LabCpuFaultNative {
                param($Binding,[string[]]$Arguments,[int]$TimeoutMilliseconds=5000,[Security.SecureString]$Password)
                if ($Arguments[0] -eq 'update') {
                    if ($Arguments[2] -eq '2684354560') {
                        $script:MemoryFaultAcceptanceActivations++; throw 'MEMORY_FAULT_ACCEPTANCE_ACTIVATION_REPLAY'
                    }
                    $script:MemoryFaultAcceptanceRestores++
                }
                if ($Arguments[0] -eq 'exec') { $script:MemoryFaultAcceptanceSql++ }
                if ($Arguments[0] -in @('start','restart')) { throw 'MEMORY_FAULT_ACCEPTANCE_UNEXPECTED_START' }
                & $script:MemoryFaultAcceptanceNative $Binding $Arguments $TimeoutMilliseconds $Password
            }
        }
        $result=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerMemoryFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password -Resume } $target $testRoot $key $secret
        $expectedStatus=if ($StopAfterInterrupt) { 'RECOVERY_REQUIRED' } else { 'INTERRUPTED' }
        $expectedCleanup=if ($StopAfterInterrupt) { 'FAILED' } else { 'PASSED' }
        $expectedLimitRestored=-not ($StopAfterInterrupt -and $Provider -eq 'podman')
        if ($result.Status -ne $expectedStatus -or $result.PrimaryStatus -ne 'INTERRUPTED' -or -not $result.AppliedVerified -or $result.LimitRestoredVerified -ne $expectedLimitRestored -or $result.SqlRestoredVerified -eq $StopAfterInterrupt.IsPresent -or $result.CleanupStatus -ne $expectedCleanup) {
            Write-Host ('MEMORY_FAULT_RESUME_DIAGNOSTIC: '+($result | Select-Object Status,PrimaryStatus,CleanupStatus,AppliedVerified,LimitRestoredVerified,SqlRestoredVerified | ConvertTo-Json -Compress))
            $diagnostic=& $module { param($Binding,$Target) Get-LabMemoryFaultSnapshot $Binding $Target } $binding $target
            Write-Host ('MEMORY_FAULT_RAW_DIAGNOSTIC: '+($diagnostic | Select-Object @{n='Memory';e={$_.Memory}},@{n='Running';e={$_.Running}},@{n='CgroupVersion';e={$_.CgroupVersion}} | ConvertTo-Json -Compress))
            throw 'MEMORY_FAULT_ACCEPTANCE_INTERRUPTED_RESUME_FAILED'
        }
        $restored=& $module { param($Binding,$Target) Get-LabMemoryFaultSnapshot $Binding $Target } $binding $target
        $expectedRestored=$checkpoint.Baseline | ConvertTo-Json -Depth 15 | ConvertFrom-Json -AsHashtable
        $expectedRestored.Running=-not $StopAfterInterrupt.IsPresent
        if (-not $expectedLimitRestored) { $expectedRestored.Memory.Memory=2684354560 }
        $sameRestored=& $module { param($Left,$Right) (ConvertTo-LabCpuFaultCanonicalJson $Left) -ceq (ConvertTo-LabCpuFaultCanonicalJson $Right) } $restored $expectedRestored
        $counts=& $module { @($script:MemoryFaultAcceptanceActivations,$script:MemoryFaultAcceptanceRestores,$script:MemoryFaultAcceptanceSql) }
        if (-not $sameRestored -or $counts[0] -ne 0 -or $counts[1] -ne 1 -or $counts[2] -ne $(if ($StopAfterInterrupt) { 0 } else { 1 })) { throw 'MEMORY_FAULT_ACCEPTANCE_RESTORE_EVIDENCE_FAILED' }
        if ($StopAfterInterrupt) {
            # Docker needs verification only; Podman may not attest stopped
            # config updates through inspect. Both remain bounded without start.
            1..2 | ForEach-Object { $null=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerMemoryFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password -Resume } $target $testRoot $key $secret }
            $state=& $module { param($Path,$Key,$Hash) Read-LabMemoryFaultJournal $Path $Key $Hash } $journalPath $key $targetHash
            if ($state.CleanupAttempts -ne 3 -or $state.LimitRestoredVerified -ne $expectedLimitRestored -or $state.SqlRestoredVerified -or $state.Status -ne 'RECOVERY_REQUIRED') { throw 'MEMORY_FAULT_ACCEPTANCE_STOPPED_RECOVERY_INVALID' }
            $counts=& $module { @($script:MemoryFaultAcceptanceActivations,$script:MemoryFaultAcceptanceRestores,$script:MemoryFaultAcceptanceSql) }
            if ($counts[0] -ne 0 -or $counts[1] -ne $(if ($expectedLimitRestored) { 1 } else { 3 }) -or $counts[2] -ne 0) { throw 'MEMORY_FAULT_ACCEPTANCE_STOPPED_RETRY_INVALID' }
        }
    }
    else {
        $result=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerMemoryFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password } $target $testRoot $key $secret
        if ($result.Status -ne 'PASSED' -or -not $result.AppliedVerified -or -not $result.LimitRestoredVerified -or -not $result.SqlRestoredVerified -or $result.CleanupStatus -ne 'PASSED') { throw 'MEMORY_FAULT_ACCEPTANCE_PULSE_FAILED' }
    }
    $journalBytes=[Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))
    $resume=& $module { param($Target,$Directory,$Key,$Password) Invoke-LabContainerMemoryFault -Target $Target -JournalDirectory $Directory -OwnershipKey $Key -Password $Password -Resume } $target $testRoot $key $secret
    if (($resume | ConvertTo-Json -Compress) -cne ($result | ConvertTo-Json -Compress) -or $journalBytes -cne [Convert]::ToBase64String([IO.File]::ReadAllBytes($journalPath))) { throw 'MEMORY_FAULT_ACCEPTANCE_RESUME_FAILED' }
    if ($HardInterrupt) {
        $finalCounts=& $module { @($script:MemoryFaultAcceptanceActivations,$script:MemoryFaultAcceptanceRestores,$script:MemoryFaultAcceptanceSql) }
        if (($counts -join ',') -cne ($finalCounts -join ',')) { throw 'MEMORY_FAULT_ACCEPTANCE_TERMINAL_MUTATION' }
        Write-Host ('MEMORY_FAULT_HARD_INTERRUPT: checkpoint=AUTHENTICATED child=TERMINATED primary=INTERRUPTED limit='+$(if ($expectedLimitRestored) { 'EXACT' } else { 'UNVERIFIED_STOPPED' })+' sql='+$(if ($StopAfterInterrupt) { 'UNVERIFIED_STOPPED' } else { 'PASSED' })+' activationsOnResume=0 terminal=BYTE_IDENTICAL')
    }
    $completed=$true
}
finally {
    try {
        if ($child -and -not $child.HasExited) {
            $child.Kill($true)
            if (-not $child.WaitForExit(5000)) { throw 'MEMORY_FAULT_ACCEPTANCE_CHILD_TERMINATION_UNCONFIRMED' }
        }
        if ($module) {
            & $module {
                if (Get-Variable -Name MemoryFaultAcceptanceNative -Scope Script -ErrorAction SilentlyContinue) {
                    Set-Item -Path Function:script:Invoke-LabCpuFaultNative -Value $script:MemoryFaultAcceptanceNative
                    Remove-Variable -Name MemoryFaultAcceptanceNative -Scope Script
                }
            }
        }
        if ($module -and (Test-Path -LiteralPath (Join-Path $stateRoot 'runs'))) {
            # The unique root existed only for this operation; no ambient state discovery.
            $runs=@(Get-ChildItem -LiteralPath (Join-Path $stateRoot 'runs') -Directory)
            foreach ($run in $runs) {
                $removed=Remove-SqlServerLab -RunId $run.Name -StateRoot $stateRoot -Force -Confirm:$false
                if ($removed.Status -ne 'REMOVED' -or $removed.Errors -ne 0) { throw 'MEMORY_FAULT_ACCEPTANCE_RUN_CLEANUP_FAILED' }
                $volumes=& $module { param($Binding,$RunId) Invoke-LabCpuFaultNative $Binding @('volume','ls','--filter',('label=sql-server-lab.run-id='+$RunId),'--format','{{.Name}}') } $binding $run.Name
                if ($volumes) { throw 'MEMORY_FAULT_ACCEPTANCE_VOLUME_REMAINS' }
            }
            $remaining=& $module { param($Binding,$OperationId) Invoke-LabCpuFaultNative $Binding @('ps','-a','--filter',('label=sql-server-lab.test-operation-id='+$OperationId),'--format','{{.ID}}') } $binding $operationId
            if ($remaining) { throw 'MEMORY_FAULT_ACCEPTANCE_CLEANUP_REMAINS' }
        }
        $cleanupSucceeded=$true
    }
    catch { Write-Warning 'MEMORY_FAULT_ACCEPTANCE_CLEANUP_FAILED: local state retained' }
    if ($child) { $child.Dispose() }
    if ($secret) { $secret.Dispose() }
    foreach ($name in $previous.Keys) { [Environment]::SetEnvironmentVariable($name,$previous[$name],'Process') }
    if ($acquired) { $mutex.ReleaseMutex() }; $mutex.Dispose()
    if ($cleanupSucceeded -and (Test-Path -LiteralPath $testRoot)) {
        if (-not ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()))) -or -not (Split-Path $testRoot -Leaf).StartsWith('sql-lab-memory-fault-')) { throw 'MEMORY_FAULT_ACCEPTANCE_CLEANUP_PATH_UNSAFE' }
        Remove-Item -LiteralPath $testRoot -Recurse -Force
    }
    Write-Host ('MEMORY_FAULT_ACCEPTANCE: provider='+$Provider+' hardInterrupt='+$HardInterrupt.IsPresent+' stopped='+$StopAfterInterrupt.IsPresent+' primary='+$(if ($completed) {'PASSED'} else {'FAILED'})+' cleanup='+$(if ($cleanupSucceeded) {'PASSED'} else {'RECOVERY_REQUIRED'}))
    if (-not $cleanupSucceeded) { throw 'MEMORY_FAULT_ACCEPTANCE_RECOVERY_REQUIRED' }
}
