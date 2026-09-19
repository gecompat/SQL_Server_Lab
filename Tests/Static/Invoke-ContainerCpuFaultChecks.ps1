#Requires -Version 7.2
[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$repoRoot=(Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/ContainerCpuFault.ps1')
. (Join-Path $repoRoot 'Tests/Fixtures/ContainerCpuFault/FakeProvider.ps1')
$testRoot=Join-Path ([IO.Path]::GetTempPath()) ('cpu-fault-' + [guid]::NewGuid().ToString('N'))
$null=New-Item -ItemType Directory -Path $testRoot
$script:providerPath=Join-Path $testRoot 'provider.json'
$key=[Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$secret=[Security.SecureString]::new()
$secret.AppendChar('x'); $secret.MakeReadOnly()
$script:passed=0
function Assert-Check { param([bool]$Condition,[string]$Name) if (-not $Condition) { throw "CPU_FAULT_CHECK_FAILED: $Name" }; $script:passed++ }
function Assert-Rejected { param([scriptblock]$Action,[string]$Reason) $rejected=$false; try { $null=& $Action } catch { $rejected=$_.Exception.Message -eq $Reason }; Assert-Check $rejected $Reason }
function New-Fixture {
    param([string]$Provider='docker',[string]$Mode='')
    $script:faultMode=$Mode
    $target=[ordered]@{ ContractVersion='SqlServerLab.InternalContainerCpuFaultTarget/0.1'; Profile='container.cpu-limit'; Provider=$Provider; OperationId=[guid]::NewGuid().ToString(); RunId=[guid]::NewGuid().ToString(); ScopeId=[guid]::NewGuid().ToString(); InstanceId='synthetic-sql'; ContainerId=('c'*64); CreatedAfterUtc=[DateTimeOffset]::UtcNow.AddSeconds(-2).ToString('o') }
    $labels=[ordered]@{ 'sql-server-lab.run-id'=$target.RunId; 'sql-server-lab.scope-id'=$target.ScopeId; 'sql-server-lab.instance-id'=$target.InstanceId; 'sql-server-lab.provider'=$Provider; 'sql-server-lab.test-operation-id'=$target.OperationId; 'sql-server-lab.lifecycle'='test' }
    $cpu=[ordered]@{ NanoCpus=2000000000; CpuPeriod=0; CpuQuota=0; CpuShares=0; CpuRealtimePeriod=0; CpuRealtimeRuntime=0; CpusetCpus=''; CpusetMems=''; CpuCount=0; CpuPercent=0 }
    if ($Provider -eq 'podman') { $cpu.CpuPeriod=100000; $cpu.CpuQuota=200000 }
    $state=@{ Container=@{ Id=$target.ContainerId; State=@{Running=$true}; Config=@{Labels=$labels}; Created=[DateTimeOffset]::UtcNow.ToString('o'); Image='sha256:synthetic'; HostConfig=$cpu }; Updates=0; Activations=0; Restores=0 }
    [IO.File]::WriteAllText($script:providerPath,($state | ConvertTo-Json -Depth 15 -Compress))
    return $target
}
function Read-Provider { [IO.File]::ReadAllText($script:providerPath) | ConvertFrom-Json -AsHashtable }
function Write-Provider { param($State) [IO.File]::WriteAllText($script:providerPath,($State | ConvertTo-Json -Depth 15 -Compress)) }
function Invoke-Fixture { param($Target,[switch]$Resume,[byte[]]$TestKey=$key,[Threading.CancellationToken]$Token=[Threading.CancellationToken]::None) Invoke-LabContainerCpuFault -Target $Target -JournalDirectory $testRoot -OwnershipKey $TestKey -Password $secret -Resume:$Resume -CancellationToken $Token }
try {
    Assert-Check ((ConvertTo-LabCpuFaultCanonicalJson ([ordered]@{b=2;a=1})) -ceq (ConvertTo-LabCpuFaultCanonicalJson (@{a=1;b=2}))) 'hash and postconditions ignore dictionary enumeration order'
    foreach ($provider in @('docker','podman')) {
        $target=New-Fixture $provider
        $result=Invoke-Fixture $target
        Assert-Check ($result.Status -eq 'PASSED' -and $result.AppliedVerified -and $result.RestoredVerified -and $result.CleanupStatus -eq 'PASSED') "$provider exact restore"
        $native=Read-Provider
        Assert-Check ($native.Activations -eq 1 -and $native.Restores -eq 1) 'one activation and restore'
        $path=Join-Path $testRoot ($target.OperationId+'.cpu-fault.json')
        $bytes=[IO.File]::ReadAllText($path)
        $null=Invoke-Fixture $target -Resume
        Assert-Check ($bytes -ceq [IO.File]::ReadAllText($path) -and (Read-Provider).Updates -eq 2) 'completed resume no mutation'
        Assert-Rejected { Invoke-Fixture $target } 'CPU_FAULT_OPERATION_EXISTS'
        Assert-Rejected { Invoke-Fixture $target -Resume -TestKey ([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) } 'CPU_FAULT_JOURNAL_UNTRUSTED'
    }
    foreach ($kind in @('Foreign','Protected','Stopped','Unlimited','Ambiguous','Old','BeforeCreation','WrongId','SqlNotReady')) {
        $target=New-Fixture
        $state=Read-Provider
        $reason=switch ($kind) {
            'Foreign' { $state.Container.Config.Labels.'sql-server-lab.test-operation-id'=[guid]::NewGuid().ToString(); 'CPU_FAULT_OWNERSHIP_MISMATCH' }
            'Protected' { $state.Container.Config.Labels['sql-server-lab.protected']='true'; 'CPU_FAULT_PROTECTED_TARGET' }
            'Stopped' { $state.Container.State.Running=$false; 'CPU_FAULT_IDENTITY_MISMATCH' }
            'Unlimited' { $state.Container.HostConfig.NanoCpus=0; 'CPU_FAULT_CAP_UNSUPPORTED' }
            'Ambiguous' { $state.Container.HostConfig.CpuQuota=200000; 'CPU_FAULT_CAP_UNSUPPORTED' }
            'Old' { $target.CreatedAfterUtc=[DateTimeOffset]::UtcNow.AddHours(-2).ToString('o'); 'CPU_FAULT_FRESH_TARGET_REQUIRED' }
            'BeforeCreation' { $state.Container.Created=[DateTimeOffset]::UtcNow.AddMinutes(-5).ToString('o'); 'CPU_FAULT_FRESH_TARGET_REQUIRED' }
            'WrongId' { $state.Container.Id='d'*64; 'CPU_FAULT_IDENTITY_MISMATCH' }
            'SqlNotReady' { $script:faultMode=$kind; 'CPU_FAULT_SQL_NOT_READY' }
        }
        Write-Provider $state
        Assert-Rejected { Invoke-Fixture $target } $reason
        Assert-Check ((Read-Provider).Updates -eq 0) "$kind no mutation"
    }
    $target=New-Fixture
    $target['Command']='arbitrary'
    Assert-Rejected { Invoke-Fixture $target } 'CPU_FAULT_TARGET_INVALID'
    $target=New-Fixture 'podman'
    $state=Read-Provider; $state.Container.HostConfig.NanoCpus=0; Write-Provider $state
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'PASSED' -and (Read-Provider).Container.HostConfig.NanoCpus -eq 0) 'quota without NanoCpus projection remains exact'
    $target=New-Fixture
    $state=Read-Provider; $state.Container.HostConfig.CpuPeriod=100000; $state.Container.HostConfig.CpuQuota=200000; Write-Provider $state
    Assert-Rejected { Invoke-Fixture $target } 'CPU_FAULT_CAP_UNSUPPORTED'
    $target=New-Fixture -Mode RuntimeChanged
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and (Read-Provider).Updates -eq 0) 'runtime drift fails closed without mutation'
    foreach ($mode in @('ApplyFailure','ObservationFailure','Timeout','CancelAfterApply')) {
        $target=New-Fixture -Mode $mode
        $script:cancelSource=[Threading.CancellationTokenSource]::new()
        try {
            $result=Invoke-Fixture $target -Token $script:cancelSource.Token
            Assert-Check ($result.Status -ne 'PASSED' -and $result.CleanupStatus -eq 'PASSED' -and (Read-Provider).Restores -eq 1) "$mode restores"
        } finally { $script:cancelSource.Dispose() }
    }
    $target=New-Fixture
    $cancel=[Threading.CancellationTokenSource]::new(); $cancel.Cancel()
    try {
        $result=Invoke-Fixture $target -Token $cancel.Token
        Assert-Check ($result.Status -eq 'CANCELLED' -and (Read-Provider).Updates -eq 0 -and -not (Test-Path (Join-Path $testRoot ($target.OperationId+'.cpu-fault.lock')))) 'cancel before activation no files or mutations'
    } finally { $cancel.Dispose() }
    $target=New-Fixture -Mode RestoreFailure
    $result=Invoke-Fixture $target
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and $result.PrimaryStatus -eq 'PASSED' -and $result.CleanupStatus -eq 'FAILED') 'primary and cleanup separate'
    $script:faultMode=''
    $result=Invoke-Fixture $target -Resume
    Assert-Check ($result.CleanupStatus -eq 'PASSED' -and (Read-Provider).Activations -eq 1) 'restore-only resume'
    $target=New-Fixture -Mode RestoreFailure
    $null=Invoke-Fixture $target
    $state=Read-Provider; $state.Container.HostConfig.NanoCpus=3000000000; Write-Provider $state
    $script:faultMode=''
    $result=Invoke-Fixture $target -Resume
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and (Read-Provider).Restores -eq 0) 'unexpected CPU drift is not overwritten'
    $target=New-Fixture -Mode RestoreFailure
    $null=Invoke-Fixture $target
    $null=Invoke-Fixture $target -Resume
    $null=Invoke-Fixture $target -Resume
    $path=Join-Path $testRoot ($target.OperationId+'.cpu-fault.json')
    $bytes=[IO.File]::ReadAllText($path)
    $script:faultMode=''
    $result=Invoke-Fixture $target -Resume
    Assert-Check ($result.Status -eq 'RECOVERY_REQUIRED' -and $bytes -ceq [IO.File]::ReadAllText($path) -and (Read-Provider).Restores -eq 0) 'three persisted cleanup attempts exhausted'
    $target=New-Fixture -Mode RestoreFailure
    $null=Invoke-Fixture $target
    $path=Join-Path $testRoot ($target.OperationId+'.cpu-fault.json')
    [IO.File]::WriteAllText($path,([IO.File]::ReadAllText($path).Replace('RESTORE_REQUIRED','COMPLETED').Replace('RECOVERY_REQUIRED','COMPLETED')))
    Assert-Rejected { Invoke-Fixture $target -Resume } 'CPU_FAULT_JOURNAL_UNTRUSTED'
    Assert-Check ((Read-Provider).Restores -eq 0) 'tampering cannot authorize restoration'
    $target=New-Fixture
    $inputPath=Join-Path $testRoot 'child.json'
    [IO.File]::WriteAllText($inputPath,(@{Target=$target; Directory=$testRoot; ProviderPath=$script:providerPath; Key=[Convert]::ToBase64String($key)} | ConvertTo-Json -Depth 15))
    $start=[Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute=$false; $start.CreateNoWindow=$true; $start.RedirectStandardOutput=$true; $start.RedirectStandardError=$true
    foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $repoRoot 'Tests/Fixtures/ContainerCpuFault/Invoke-InterruptedFixture.ps1'),'-InputPath',$inputPath)) { $start.ArgumentList.Add($argument) }
    $child=[Diagnostics.Process]::Start($start)
    try {
        $clock=[Diagnostics.Stopwatch]::StartNew()
        while (-not $child.HasExited -and $clock.ElapsedMilliseconds -lt 15000 -and (Read-Provider).Activations -eq 0) { [Threading.Thread]::Sleep(20) }
        Assert-Check ((Read-Provider).Activations -eq 1) 'real child activated after durable restore intent'
        $child.Kill($true)
        Assert-Check ($child.WaitForExit(5000)) 'child hard termination confirmed'
        $script:faultMode=''
        $result=Invoke-Fixture $target -Resume
        Assert-Check ($result.PrimaryStatus -eq 'INTERRUPTED' -and $result.CleanupStatus -eq 'PASSED' -and (Read-Provider).Activations -eq 1 -and (Read-Provider).Restores -eq 1) 'hard interruption restores without replay'
    } finally { if (-not $child.HasExited) { $child.Kill($true); $null=$child.WaitForExit(5000) }; $child.Dispose() }
    $source=Get-Content -LiteralPath (Join-Path $repoRoot 'Private/ContainerCpuFault.ps1') -Raw
    Assert-Check ($source -notmatch 'Update-SqlServerLabContainer|Invoke-Expression|\[scriptblock\]') 'no arbitrary command or reconcile input'
    Write-Host "CONTAINER_CPU_FAULT_CHECKS: PASS ($script:passed checks)"
}
finally {
    if ([IO.Path]::GetFullPath($testRoot).StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath())) -and (Split-Path $testRoot -Leaf).StartsWith('cpu-fault-')) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
}
