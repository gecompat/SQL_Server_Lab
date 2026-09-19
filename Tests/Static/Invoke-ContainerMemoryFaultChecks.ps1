#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/ContainerCpuFault.ps1')
. (Join-Path $repoRoot 'Private/ContainerMemoryFault.ps1')
. (Join-Path $repoRoot 'Tests/Fixtures/ContainerMemoryFault/FakeProvider.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('memory-fault-'+[guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$script:providerPath=Join-Path $testRoot 'provider.json'
$key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$secret=[Security.SecureString]::new(); $secret.AppendChar('x'); $secret.MakeReadOnly()
$script:passed=0
function Assert-Check { param([bool]$Condition,[string]$Name) if (-not $Condition) { throw "MEMORY_FAULT_CHECK_FAILED: $Name" }; $script:passed++ }
function Assert-Rejected { param([scriptblock]$Action,[string]$Reason) $rejected=$false; try { $null=& $Action } catch { $rejected=$_.Exception.Message -eq $Reason }; Assert-Check $rejected $Reason }
function Read-Provider { [IO.File]::ReadAllText($script:providerPath) | ConvertFrom-Json -AsHashtable }
function Write-Provider { param($State) [IO.File]::WriteAllText($script:providerPath,($State | ConvertTo-Json -Depth 15 -Compress)) }
function New-Fixture {
    param([string]$Provider='docker',[string]$Mode='')
    $script:faultMode=$Mode
    $target=[ordered]@{ContractVersion='SqlServerLab.InternalContainerMemoryFaultTarget/0.1'; Profile='container.memory-limit'; Provider=$Provider; OperationId=[guid]::NewGuid().ToString(); RunId=[guid]::NewGuid().ToString(); ScopeId=[guid]::NewGuid().ToString(); InstanceId='synthetic-sql'; ContainerId=('c'*64); CreatedAfterUtc=[DateTimeOffset]::UtcNow.AddSeconds(-2).ToString('o')}
    $labels=[ordered]@{'sql-server-lab.run-id'=$target.RunId; 'sql-server-lab.scope-id'=$target.ScopeId; 'sql-server-lab.instance-id'=$target.InstanceId; 'sql-server-lab.provider'=$Provider; 'sql-server-lab.test-operation-id'=$target.OperationId; 'sql-server-lab.lifecycle'='test'}
    $memory=[ordered]@{Memory=3221225472; MemorySwap=6442450944; MemoryReservation=0; MemorySwappiness=$null; KernelMemory=$null; KernelMemoryTCP=$null; OomKillDisable=$false}
    if ($Provider -eq 'podman') { $memory.MemorySwappiness=0; $memory.KernelMemory=0; $memory.KernelMemoryTCP=0 }
    Write-Provider @{Container=@{Id=$target.ContainerId; State=@{Running=$true}; Config=@{Labels=$labels}; Created=[DateTimeOffset]::UtcNow.ToString('o'); Image='sha256:synthetic'; HostConfig=$memory}; Updates=0; Activations=0; Restores=0; SqlCalls=0}
    return $target
}
function Invoke-Fixture { param($Target,[switch]$Resume,[byte[]]$TestKey=$key,[Threading.CancellationToken]$Token=[Threading.CancellationToken]::None) Invoke-LabContainerMemoryFault -Target $Target -JournalDirectory $testRoot -OwnershipKey $TestKey -Password $secret -Resume:$Resume -CancellationToken $Token }
function Get-Journal { param($Target) Read-LabMemoryFaultJournal (Join-Path $testRoot ($Target.OperationId+'.memory-fault.json')) $key (Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $Target)) }
try {
    foreach ($provider in @('docker','podman')) {
        $target=New-Fixture $provider
        $original=ConvertTo-LabCpuFaultCanonicalJson (Read-Provider).Container.HostConfig
        $result=Invoke-Fixture $target
        Assert-Check ($result.Status -eq 'PASSED' -and $result.AppliedVerified -and $result.LimitRestoredVerified -and $result.SqlRestoredVerified -and $result.CleanupStatus -eq 'PASSED') "$provider complete pulse"
        Assert-Check ((ConvertTo-LabCpuFaultCanonicalJson (Read-Provider).Container.HostConfig) -ceq $original -and (Read-Provider).Activations -eq 1 -and (Read-Provider).Restores -eq 1) "$provider exact raw restore"
        $path=Join-Path $testRoot ($target.OperationId+'.memory-fault.json')
        $bytes=[IO.File]::ReadAllText($path); $sqlCalls=(Read-Provider).SqlCalls
        $null=Invoke-Fixture $target -Resume
        Assert-Check ($bytes -ceq [IO.File]::ReadAllText($path) -and (Read-Provider).Updates -eq 2 -and (Read-Provider).SqlCalls -eq $sqlCalls) 'terminal resume no mutation or SQL'
        Assert-Rejected { Invoke-Fixture $target } 'MEMORY_FAULT_OPERATION_EXISTS'
        Assert-Rejected { Invoke-Fixture $target -Resume -TestKey ([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) } 'MEMORY_FAULT_JOURNAL_UNTRUSTED'
    }
    foreach ($kind in @('Foreign','Protected','Reserved','Supporting','NotTest','Stopped','Old','BeforeCreation','WrongId','SqlNotReady')) {
        $target=New-Fixture
        $state=Read-Provider
        $reason=switch ($kind) {
            'Foreign' { $state.Container.Config.Labels.'sql-server-lab.test-operation-id'=[guid]::NewGuid().ToString(); 'MEMORY_FAULT_OWNERSHIP_MISMATCH' }
            'Protected' { $state.Container.Config.Labels['sql-server-lab.protected']='true'; 'MEMORY_FAULT_PROTECTED_TARGET' }
            'Reserved' { $state.Container.Config.Labels['sql-server-lab.test-environment']='matrix'; 'MEMORY_FAULT_PROTECTED_TARGET' }
            'Supporting' { $state.Container.Config.Labels['sql-server-lab.supporting']='true'; 'MEMORY_FAULT_PROTECTED_TARGET' }
            'NotTest' { $state.Container.Config.Labels.'sql-server-lab.lifecycle'='persistent'; 'MEMORY_FAULT_DISPOSABLE_REQUIRED' }
            'Stopped' { $state.Container.State.Running=$false; 'MEMORY_FAULT_RUNNING_REQUIRED' }
            'Old' { $target.CreatedAfterUtc=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o'); 'MEMORY_FAULT_FRESH_TARGET_REQUIRED' }
            'BeforeCreation' { $state.Container.Created=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o'); 'MEMORY_FAULT_FRESH_TARGET_REQUIRED' }
            'WrongId' { $state.Container.Id='d'*64; 'MEMORY_FAULT_IDENTITY_MISMATCH' }
            'SqlNotReady' { $script:faultMode=$kind; 'MEMORY_FAULT_SQL_NOT_READY' }
        }
        Write-Provider $state
        Assert-Rejected { Invoke-Fixture $target } $reason
        Assert-Check ((Read-Provider).Updates -eq 0) "$kind no mutation"
    }
    foreach ($field in @('Memory','MemorySwap','MemoryReservation','MemorySwappiness','KernelMemory','KernelMemoryTCP','OomKillDisable')) {
        $target=New-Fixture; $state=Read-Provider
        $state.Container.HostConfig[$field]=if ($field -eq 'OomKillDisable') { $true } else { 7 }
        Write-Provider $state
        Assert-Rejected { Invoke-Fixture $target } 'MEMORY_FAULT_BASELINE_UNSUPPORTED'
        Assert-Check ((Read-Provider).Updates -eq 0) "$field unsupported raw value"
    }
    foreach ($field in @('Memory','MemorySwap','MemoryReservation')) {
        $target=New-Fixture; $state=Read-Provider; $state.Container.HostConfig.Remove($field); Write-Provider $state
        Assert-Rejected { Invoke-Fixture $target } 'MEMORY_FAULT_BASELINE_UNSUPPORTED'
    }
    foreach ($provider in @('docker','podman')) {
        $target=New-Fixture $provider; $state=Read-Provider; $state.Container.HostConfig.OomKillDisable=$null; Write-Provider $state
        $result=Invoke-Fixture $target
        Assert-Check ($result.Status -eq 'PASSED' -and $null -eq (Read-Provider).Container.HostConfig.OomKillDisable) 'cgroup v2 retains absent OOM control without normalizing'
        $target=New-Fixture $provider -Mode CgroupV1; $state=Read-Provider; $state.Container.HostConfig.OomKillDisable=$null; Write-Provider $state
        Assert-Rejected { Invoke-Fixture $target } 'MEMORY_FAULT_BASELINE_UNSUPPORTED'
        Assert-Check ((Read-Provider).Updates -eq 0) 'cgroup v1 absent OOM control rejected'
        $target=New-Fixture $provider -Mode CgroupUnknown
        Assert-Rejected { Invoke-Fixture $target } 'MEMORY_FAULT_CGROUP_UNKNOWN'
    }
    $target=New-Fixture; $target['Command']='arbitrary'
    Assert-Rejected { Invoke-Fixture $target } 'MEMORY_FAULT_TARGET_INVALID'
    $target=New-Fixture -Mode RuntimeChanged
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and (Read-Provider).Updates -eq 0) 'runtime drift fails closed'
    foreach ($mode in @('ApplyFailure','ObservationFailure','Timeout','CancelAfterApply')) {
        $target=New-Fixture -Mode $mode; $script:cancelSource=[Threading.CancellationTokenSource]::new()
        try {
            $result=Invoke-Fixture $target -Token $script:cancelSource.Token
            Assert-Check ($result.Status -ne 'PASSED' -and $result.CleanupStatus -eq 'PASSED' -and (Read-Provider).Restores -eq 1) "$mode restores"
        } finally { $script:cancelSource.Dispose() }
    }
    $target=New-Fixture; $cancel=[Threading.CancellationTokenSource]::new(); $cancel.Cancel()
    try {
        $result=Invoke-Fixture $target -Token $cancel.Token
        Assert-Check ($result.Status -eq 'CANCELLED' -and (Read-Provider).Updates -eq 0 -and -not (Test-Path (Join-Path $testRoot ($target.OperationId+'.memory-fault.lock')))) 'pre-cancel no files'
    } finally { $cancel.Dispose() }
    $target=New-Fixture -Mode StopAfterApply
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and $result.LimitRestoredVerified -and -not $result.SqlRestoredVerified -and (Read-Provider).Restores -eq 1 -and -not (Read-Provider).Container.State.Running -and (Read-Provider).SqlCalls -eq 1) 'stopped own container restored without start or SQL call'
    Assert-Check ((Get-Journal $target).LimitRestoredVerified -and -not (Get-Journal $target).SqlRestoredVerified) 'separate restore evidence durable'
    $script:faultMode=''; $state=Read-Provider; $state.Container.State.Running=$true; Write-Provider $state
    $result=Invoke-Fixture $target -Resume
    Assert-Check ($result.CleanupStatus -eq 'PASSED' -and (Read-Provider).Restores -eq 1 -and (Read-Provider).Activations -eq 1) 'external restart permits SQL verification without limit replay'
    $target=New-Fixture podman -Mode StopAfterApply
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and -not $result.LimitRestoredVerified -and -not $result.SqlRestoredVerified -and (Read-Provider).Container.HostConfig.Memory -eq 2684354560 -and -not (Read-Provider).Container.State.Running) 'Podman stopped inspect cannot attest restore from update exit alone'
    $null=Invoke-Fixture $target -Resume; $null=Invoke-Fixture $target -Resume
    Assert-Check ((Get-Journal $target).CleanupAttempts -eq 3 -and (Read-Provider).Restores -eq 3 -and (Read-Provider).Activations -eq 1 -and (Read-Provider).SqlCalls -eq 1) 'Podman unverified stopped restoration remains bounded without start or SQL'
    $target=New-Fixture -Mode RestoreSqlFailure
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and $result.PrimaryStatus -eq 'PASSED' -and $result.LimitRestoredVerified -and -not $result.SqlRestoredVerified) 'SQL restore failure not hidden by exact limits'
    $target=New-Fixture -Mode DriftAfterApply
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and -not $result.LimitRestoredVerified -and (Read-Provider).Restores -eq 0) 'unexpected apply drift never overwritten during finally'
    $target=New-Fixture
    $binding=New-LabCpuFaultRuntimeBinding docker
    $baseline=Get-LabMemoryFaultSnapshot $binding $target -Fresh -RequireRunning
    $state=[ordered]@{ContractVersion='SqlServerLab.InternalContainerMemoryFaultJournal/0.1'; Profile='container.memory-limit'; Target=$target; TargetHash=(Get-LabCpuFaultHash (ConvertTo-LabCpuFaultCanonicalJson $target)); Runtime=$binding; Baseline=$baseline; RestoreIntent=$true; Status='RESTORE_REQUIRED'; PrimaryStatus='NOT_EXECUTED'; CleanupStatus='PENDING'; CleanupAttempts=0; AppliedVerified=$false; LimitRestoredVerified=$false; SqlRestoredVerified=$false}
    $null=Write-LabMemoryFaultJournal (Join-Path $testRoot ($target.OperationId+'.memory-fault.json')) $key $state ''
    $result=Invoke-Fixture $target -Resume
    Assert-Check ($result.Status -eq 'INTERRUPTED' -and -not $result.AppliedVerified -and $result.LimitRestoredVerified -and $result.SqlRestoredVerified -and (Read-Provider).Updates -eq 0) 'write-ahead interruption before apply never activates'
    $target=New-Fixture -Mode RestoreFailure
    $null=Invoke-Fixture $target
    $script:faultMode=''; $result=Invoke-Fixture $target -Resume
    Assert-Check ($result.CleanupStatus -eq 'PASSED' -and (Read-Provider).Activations -eq 1) 'restore-only resume'
    foreach ($kind in @('Memory','Swap','Reservation','Identity','Ownership')) {
        $target=New-Fixture -Mode RestoreFailure; $null=Invoke-Fixture $target
        $state=Read-Provider
        switch ($kind) {
            Memory { $state.Container.HostConfig.Memory=3000000000 }
            Swap { $state.Container.HostConfig.MemorySwap=7000000000 }
            Reservation { $state.Container.HostConfig.MemoryReservation=1 }
            Identity { $state.Container.Image='sha256:other' }
            Ownership { $state.Container.Config.Labels.'sql-server-lab.run-id'=[guid]::NewGuid().ToString() }
        }
        Write-Provider $state; $script:faultMode=''; $result=Invoke-Fixture $target -Resume
        Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and (Read-Provider).Restores -eq 0) "$kind drift never overwritten"
    }
    $target=New-Fixture -Mode RestoreFailure
    $null=Invoke-Fixture $target; $null=Invoke-Fixture $target -Resume; $null=Invoke-Fixture $target -Resume
    $path=Join-Path $testRoot ($target.OperationId+'.memory-fault.json'); $bytes=[IO.File]::ReadAllText($path)
    $script:faultMode=''; $result=Invoke-Fixture $target -Resume
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and (Get-Journal $target).CleanupAttempts -eq 3 -and $bytes -ceq [IO.File]::ReadAllText($path) -and (Read-Provider).Restores -eq 0) 'three durable attempts exhausted'
    [IO.File]::WriteAllText($path,$bytes.Replace('RECOVERY_REQUIRED','COMPLETED'))
    Assert-Rejected { Invoke-Fixture $target -Resume } 'MEMORY_FAULT_JOURNAL_UNTRUSTED'
    foreach ($provider in @('docker','podman')) {
        $target=New-Fixture $provider
        $baseline=Get-LabMemoryFaultSnapshot (New-LabCpuFaultRuntimeBinding $provider) $target -Fresh -RequireRunning
        $path=Join-Path $testRoot ($target.OperationId+'.memory-fault.json')
        $inputPath=Join-Path $testRoot 'child.json'
        [IO.File]::WriteAllText($inputPath,(@{Target=$target; Directory=$testRoot; ProviderPath=$script:providerPath; Key=[Convert]::ToBase64String($key)} | ConvertTo-Json -Depth 15))
        $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
        foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $repoRoot 'Tests/Fixtures/ContainerMemoryFault/Invoke-InterruptedFixture.ps1'),'-InputPath',$inputPath)) { $start.ArgumentList.Add($argument) }
        $child=[Diagnostics.Process]::Start($start)
        try {
            $clock=[Diagnostics.Stopwatch]::StartNew(); $checkpoint=$null
            while (-not $child.HasExited -and $clock.ElapsedMilliseconds -lt 15000) {
                if (Test-Path -LiteralPath $path) { $candidate=Get-Journal $target; if ($candidate.AppliedVerified) { $checkpoint=$candidate; break } }
                [Threading.Thread]::Sleep(20)
            }
            Assert-Check ($null -ne $checkpoint -and -not $child.HasExited) "$provider authenticated applied checkpoint"
            Assert-Check ($checkpoint.PrimaryStatus -eq 'NOT_EXECUTED' -and $checkpoint.CleanupAttempts -eq 0 -and -not $checkpoint.LimitRestoredVerified -and -not $checkpoint.SqlRestoredVerified) 'checkpoint precedes cleanup'
            Assert-Check ((ConvertTo-LabCpuFaultCanonicalJson $checkpoint.Baseline) -ceq (ConvertTo-LabCpuFaultCanonicalJson $baseline)) 'checkpoint exact raw baseline'
            Assert-Rejected { Invoke-Fixture $target -Resume } 'MEMORY_FAULT_LOCK_UNAVAILABLE'
            $child.Kill($true); Assert-Check ($child.WaitForExit(5000)) 'confirmed hard termination'
            Assert-Check ((Read-Provider).Activations -eq 1 -and (Read-Provider).Restores -eq 0) 'child finally bypassed'
            $result=Invoke-Fixture $target -Resume
            Assert-Check ($result.Status -eq 'INTERRUPTED' -and $result.CleanupStatus -eq 'PASSED' -and $result.AppliedVerified -and $result.LimitRestoredVerified -and $result.SqlRestoredVerified -and (Read-Provider).Activations -eq 1 -and (Read-Provider).Restores -eq 1) 'hard interrupt restore without replay'
            $bytes=[IO.File]::ReadAllText($path); $sqlCalls=(Read-Provider).SqlCalls
            $null=Invoke-Fixture $target -Resume
            Assert-Check ($bytes -ceq [IO.File]::ReadAllText($path) -and (Read-Provider).Updates -eq 2 -and (Read-Provider).SqlCalls -eq $sqlCalls) 'interrupted terminal byte identity'
        } finally { if (-not $child.HasExited) { $child.Kill($true); $null=$child.WaitForExit(5000) }; $child.Dispose() }
    }
    $source=Get-Content (Join-Path $repoRoot 'Private/ContainerMemoryFault.ps1') -Raw
    Assert-Check ($source -notmatch 'Update-SqlServerLabContainer|Invoke-Expression|\[scriptblock\]|''start''|''restart''') 'closed profile has no arbitrary commands or start'
    Write-Host "CONTAINER_MEMORY_FAULT_CHECKS: PASS ($script:passed checks)"
} finally {
    $secret.Dispose()
    if ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $testRoot -Leaf).StartsWith('memory-fault-')) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
