#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
. (Join-Path $repoRoot 'Private/ScenarioExecutor.ps1')
$contract = Get-Content -LiteralPath (Join-Path $repoRoot 'Schemas/scenario-contract.example.json') -Raw | ConvertFrom-Json
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('scenario-executor-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$owner = [guid]::NewGuid()
$key = [Security.Cryptography.RandomNumberGenerator]::GetBytes(32)
$passed = 0

function Assert-Check {
    param([bool]$Condition, [string]$Name)
    if (-not $Condition) { throw "SCENARIO_EXECUTOR_CHECK_FAILED: $Name" }
    $script:passed++
}
function New-TestPlan {
    return [pscustomobject]@{
        ContractVersion = 'SqlServerLab.InternalSyntheticScenarioPlan/0.1'
        TimeoutMilliseconds = 10000; CleanupTimeoutMilliseconds = 10000
        Phases = @(@('Arrange','Act','Observe','Assert','Cleanup') | ForEach-Object {
            [pscustomobject]@{ Phase = $_; StepId = 'collect-synthetic-observation'; Handler = 'Synthetic'; DelayMilliseconds = 0 }
        })
    }
}
function Invoke-TestScenario {
    param($Plan, [guid]$Id = [guid]::NewGuid(), [switch]$Resume, [byte[]]$TestKey = $key, [guid]$TestOwner = $owner,
        [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None)
    Invoke-LabSyntheticScenario -Contract $contract -Plan $Plan -JournalDirectory $testRoot -OwnerId $TestOwner -OperationId $Id -OwnershipKey $TestKey -Resume:$Resume -CancellationToken $Token
}
function Assert-Rejected {
    param([scriptblock]$Action, [string]$Reason)
    $rejected = $false
    try { $null = & $Action } catch { $rejected = $_.Exception.Message -eq $Reason }
    Assert-Check $rejected $Reason
}

try {
    $plan = New-TestPlan
    $id = [guid]::NewGuid()
    $result = Invoke-TestScenario $plan $id
    Assert-Check ($result.Status -eq 'PASSED' -and $result.CleanupStatus -eq 'PASSED') 'success requires cleanup'
    Assert-Check (($result.Phases.Phase -join ',') -ceq 'Arrange,Act,Observe,Assert,Cleanup') 'phase order'
    $path = Join-Path $testRoot "$id.scenario.json"
    $before = [IO.File]::ReadAllBytes($path)
    $repeated = Invoke-TestScenario $plan $id -Resume
    Assert-Check (($result | ConvertTo-Json -Depth 10 -Compress) -ceq ($repeated | ConvertTo-Json -Depth 10 -Compress)) 'terminal resume result'
    Assert-Check ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'terminal resume no write'
    Assert-Rejected { Invoke-TestScenario $plan $id } 'SCENARIO_OPERATION_EXISTS'
    Assert-Rejected { Invoke-TestScenario $plan $id -Resume -TestOwner ([guid]::NewGuid()) } 'SCENARIO_JOURNAL_UNTRUSTED'
    Assert-Rejected { Invoke-TestScenario $plan $id -Resume -TestKey ([Security.Cryptography.RandomNumberGenerator]::GetBytes(32)) } 'SCENARIO_JOURNAL_UNTRUSTED'
    $changedPlan = New-TestPlan
    $changedPlan.TimeoutMilliseconds++
    Assert-Rejected { Invoke-TestScenario $changedPlan $id -Resume } 'SCENARIO_JOURNAL_UNTRUSTED'
    Assert-Check ([Convert]::ToBase64String($before) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($path))) 'rejected ownership leaves journal unchanged'

    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $cancellation.Cancel()
        $cancelId = [guid]::NewGuid()
        $cancelled = Invoke-TestScenario $plan $cancelId -Token $cancellation.Token
        Assert-Check ($cancelled.Status -eq 'CANCELLED' -and $cancelled.CleanupStatus -eq 'NOT_REQUIRED') 'cancel before mutation'
        Assert-Check (-not (Test-Path (Join-Path $testRoot "$cancelId.scenario.json")) -and -not (Test-Path (Join-Path $testRoot "$cancelId.lock"))) 'cancel creates no files'
    }
    finally { $cancellation.Dispose() }

    $timeoutPlan = New-TestPlan
    $timeoutPlan.TimeoutMilliseconds = 200
    $timeoutPlan.Phases[1].DelayMilliseconds = 1000
    $timer = [Diagnostics.Stopwatch]::StartNew()
    $timedOut = Invoke-TestScenario $timeoutPlan
    Assert-Check ($timedOut.Status -eq 'TIMED_OUT' -and $timedOut.CleanupStatus -eq 'PASSED' -and $timer.ElapsedMilliseconds -lt 4000) 'bounded timeout and independent cleanup'
    $cancelPlan = New-TestPlan
    $cancelPlan.Phases[1].DelayMilliseconds = 2000
    $cancellation = [Threading.CancellationTokenSource]::new()
    try {
        $cancellation.CancelAfter(500)
        $cancelled = Invoke-TestScenario $cancelPlan -Token $cancellation.Token
        Assert-Check ($cancelled.Status -eq 'CANCELLED' -and $cancelled.CleanupStatus -eq 'PASSED' -and 'Act' -in $cancelled.Phases.Phase) 'cancel after arrange cleans up'
    }
    finally { $cancellation.Dispose() }

    foreach ($index in 0..3) {
        $failurePlan = New-TestPlan
        $failurePlan.Phases[$index].Handler = 'Fail'
        $failure = Invoke-TestScenario $failurePlan
        Assert-Check ($failure.Status -eq 'HANDLER_FAILED' -and $failure.CleanupStatus -eq 'PASSED' -and $failure.Phases.Count -eq ($index + 2)) "failure in phase $index cleans up"
    }
    $failurePlan = New-TestPlan
    $failurePlan.Phases[1].Handler = 'Fail'
    $failurePlan.Phases[4].Handler = 'FailOnce'
    $recoveryId = [guid]::NewGuid()
    $failure = Invoke-TestScenario $failurePlan $recoveryId
    Assert-Check ($failure.Status -eq 'RECOVERY_REQUIRED' -and $failure.PrimaryStatus -eq 'HANDLER_FAILED' -and $failure.CleanupStatus -eq 'HANDLER_FAILED') 'preserve primary and cleanup failures'
    $recovery = Invoke-TestScenario $failurePlan $recoveryId -Resume
    Assert-Check ($recovery.Status -eq 'HANDLER_FAILED' -and $recovery.CleanupStatus -eq 'PASSED' -and @($recovery.Phases | Where-Object Phase -EQ 'Act').Count -eq 1) 'resume only cleanup'
    $cleanupTimeoutPlan = New-TestPlan
    $cleanupTimeoutPlan.CleanupTimeoutMilliseconds = 20
    $cleanupTimeoutPlan.Phases[4].DelayMilliseconds = 1000
    $cleanupTimeout = Invoke-TestScenario $cleanupTimeoutPlan
    Assert-Check ($cleanupTimeout.Status -eq 'RECOVERY_REQUIRED' -and $cleanupTimeout.PrimaryStatus -eq 'PASSED' -and $cleanupTimeout.CleanupStatus -eq 'TIMED_OUT') 'cleanup timeout never passes'

    # Simulate a durable in-progress checkpoint produced before process termination.
    $crashId = [guid]::NewGuid()
    $crashPlan = New-TestPlan
    $crashPlan.Phases[4].Handler = 'FailOnce'
    $null = Invoke-TestScenario $crashPlan $crashId
    $crashPath = Join-Path $testRoot "$crashId.scenario.json"
    $envelope = [IO.File]::ReadAllText($crashPath) | ConvertFrom-Json
    $state = $envelope.Payload | ConvertFrom-Json -AsHashtable
    $state.Status = 'IN_PROGRESS'; $state.PrimaryStatus = 'NOT_EXECUTED'; $state.CleanupStatus = 'PENDING'
    $state.CleanupAttempts = 1
    $state.Phases = @(@{ Phase = 'Arrange'; Status = 'PASSED' }, @{ Phase = 'Act'; Status = 'IN_PROGRESS' })
    $null = Write-LabScenarioJournal $crashPath $key $state $envelope.Authentication
    $interrupted = Invoke-TestScenario $crashPlan $crashId -Resume
    Assert-Check ($interrupted.Status -eq 'INTERRUPTED' -and $interrupted.CleanupStatus -eq 'PASSED' -and $interrupted.Phases.Count -eq 3) 'interrupted work is not replayed or passed'

    $childPlan = New-TestPlan
    $childPlan.TimeoutMilliseconds = 30000
    $childPlan.Phases[1].DelayMilliseconds = 30000
    $childId = [guid]::NewGuid()
    $childPath = Join-Path $testRoot "$childId.scenario.json"
    $inputPath = Join-Path $testRoot 'child-input.json'
    [IO.File]::WriteAllText($inputPath, (@{ Contract = $contract; Plan = $childPlan; Directory = $testRoot; Owner = $owner; Operation = $childId; Key = [Convert]::ToBase64String($key) } | ConvertTo-Json -Depth 30))
    $startInfo = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $startInfo.UseShellExecute = $false; $startInfo.CreateNoWindow = $true
    $startInfo.RedirectStandardOutput = $true; $startInfo.RedirectStandardError = $true
    foreach ($argument in @('-NoLogo','-NoProfile','-File',(Join-Path $repoRoot 'Tests/Fixtures/ScenarioExecutor/Invoke-InterruptedFixture.ps1'),'-InputPath',$inputPath)) { $startInfo.ArgumentList.Add($argument) }
    $child = [Diagnostics.Process]::Start($startInfo)
    try {
        $wait = [Diagnostics.Stopwatch]::StartNew()
        $checkpointSeen = $false
        while (-not $child.HasExited -and $wait.Elapsed.TotalSeconds -lt 15) {
            if (Test-Path -LiteralPath $childPath) {
                $childState = ([IO.File]::ReadAllText($childPath) | ConvertFrom-Json).Payload | ConvertFrom-Json
                $checkpointSeen = @($childState.Phases | Where-Object { $_.Phase -eq 'Act' -and $_.Status -eq 'IN_PROGRESS' }).Count -eq 1
                if ($checkpointSeen) { break }
            }
            [Threading.Thread]::Sleep(20)
        }
        Assert-Check $checkpointSeen 'real child committed in-progress checkpoint'
        $child.Kill($true)
        Assert-Check ($child.WaitForExit(5000)) 'real child termination confirmed'
        $restarted = Invoke-TestScenario $childPlan $childId -Resume
        Assert-Check ($restarted.Status -eq 'INTERRUPTED' -and $restarted.CleanupStatus -eq 'PASSED' -and $restarted.Phases.Count -eq 3) 'real process interruption resumes cleanup only'
    }
    finally {
        if (-not $child.HasExited) { $child.Kill($true); $null = $child.WaitForExit(5000) }
        $child.Dispose()
    }

    $permanentFailurePlan = New-TestPlan
    $permanentFailurePlan.Phases[4].Handler = 'Fail'
    $permanentId = [guid]::NewGuid()
    $null = Invoke-TestScenario $permanentFailurePlan $permanentId
    $null = Invoke-TestScenario $permanentFailurePlan $permanentId -Resume
    $null = Invoke-TestScenario $permanentFailurePlan $permanentId -Resume
    $exhaustedPath = Join-Path $testRoot "$permanentId.scenario.json"
    $exhaustedBefore = [IO.File]::ReadAllText($exhaustedPath)
    $exhausted = Invoke-TestScenario $permanentFailurePlan $permanentId -Resume
    Assert-Check ($exhausted.Status -eq 'RECOVERY_REQUIRED' -and [IO.File]::ReadAllText($exhaustedPath) -ceq $exhaustedBefore) 'cleanup retry budget is durable'

    $lockedId = [guid]::NewGuid()
    $held = [IO.File]::Open((Join-Path $testRoot "$lockedId.lock"), [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try { Assert-Rejected { Invoke-TestScenario $plan $lockedId } 'SCENARIO_LOCK_UNAVAILABLE' }
    finally { $held.Dispose() }

    $malformedId = [guid]::NewGuid()
    $null = Invoke-TestScenario $plan $malformedId
    $malformedPath = Join-Path $testRoot "$malformedId.scenario.json"
    $envelope = [IO.File]::ReadAllText($malformedPath) | ConvertFrom-Json
    $malformedState = $envelope.Payload | ConvertFrom-Json -AsHashtable
    $malformedState['Unexpected'] = 'synthetic-rejected-field'
    $null = Write-LabScenarioJournal $malformedPath $key $malformedState $envelope.Authentication
    Assert-Rejected { Invoke-TestScenario $plan $malformedId -Resume } 'SCENARIO_JOURNAL_UNTRUSTED'

    $envelope = [IO.File]::ReadAllText($path) | ConvertFrom-Json
    $envelope.Payload = $envelope.Payload.Replace('COMPLETED','IN_PROGRESS')
    [IO.File]::WriteAllText($path, ($envelope | ConvertTo-Json -Compress))
    $tampered = [IO.File]::ReadAllText($path)
    Assert-Rejected { Invoke-TestScenario $plan $id -Resume } 'SCENARIO_JOURNAL_UNTRUSTED'
    Assert-Check ([IO.File]::ReadAllText($path) -ceq $tampered) 'tampered journal preserved for investigation'
    $invalid = New-TestPlan
    $invalid.Phases[1].Handler = 'Invoke-Expression'
    Assert-Rejected { Invoke-TestScenario $invalid } 'SCENARIO_INPUT_INVALID'
    $invalid = New-TestPlan
    $invalid.Phases[0].Phase = 'Act'
    Assert-Rejected { Invoke-TestScenario $invalid } 'SCENARIO_PHASE_INVALID'
    $invalid = New-TestPlan
    $invalid.Phases[0].StepId = 'missing-step'
    Assert-Rejected { Invoke-TestScenario $invalid } 'SCENARIO_PHASE_INVALID'
    Assert-Rejected { Invoke-TestScenario $plan -TestKey ([byte[]]@(1,2,3)) } 'SCENARIO_OWNERSHIP_INVALID'
    $manifest = Import-PowerShellDataFile (Join-Path $repoRoot 'SqlServerLab.psd1')
    Assert-Check ('Invoke-LabSyntheticScenario' -notin $manifest.FunctionsToExport) 'executor remains internal'
    $serialized = $result | ConvertTo-Json -Depth 20
    Assert-Check (-not $serialized.Contains($testRoot) -and -not $serialized.Contains([Convert]::ToBase64String($key)) -and $serialized -notmatch 'Payload|PlanHash|OwnerId|SyntheticValue') 'result projection contains no local payload'
    Assert-Check (@(Get-ChildItem $testRoot -Filter '*.tmp').Count -eq 0) 'atomic writes leave no temporary files'
    Write-Host "SCENARIO EXECUTOR CHECKS: PASS ($passed checks)"
}
finally {
    # Only this fixture's freshly allocated directory is eligible for removal.
    $resolved = [IO.Path]::GetFullPath($testRoot)
    $temporaryRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $resolved.StartsWith($temporaryRoot, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resolved) -notmatch '^scenario-executor-[0-9a-f]{32}$') { throw 'SCENARIO_TEST_CLEANUP_SCOPE_INVALID' }
    Remove-Item -LiteralPath $resolved -Recurse -Force
}
