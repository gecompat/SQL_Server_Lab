# Internal SCN-802/SCN-804 slice. Synthetic state exists only in the owned journal.
# No scriptblocks, provider adapters, SQL, or externally supplied commands.

function Assert-LabSyntheticScenarioInput {
    param([Parameter(Mandatory)]$Contract, [Parameter(Mandatory)]$Plan)
    $schemas = Join-Path $PSScriptRoot '../Schemas'
    foreach ($pair in @(@($Contract, 'scenario-contract.schema.json'), @($Plan, 'scenario-execution-plan.schema.json'))) {
        $json = $pair[0] | ConvertTo-Json -Depth 30 -Compress
        if ($json.Length -gt 65536 -or -not ($json | Test-Json -SchemaFile (Join-Path $schemas $pair[1]) -ErrorAction SilentlyContinue)) {
            throw 'SCENARIO_INPUT_INVALID'
        }
    }
    foreach ($collection in @('Steps', 'Evidence', 'Outcomes')) {
        $ids = @($Contract.$collection.Id)
        if ($ids.Count -ne @($ids | Select-Object -Unique).Count) { throw 'SCENARIO_REFERENCE_INVALID' }
    }
    foreach ($entry in @($Contract.Steps) + @($Contract.Outcomes)) {
        foreach ($id in $entry.EvidenceIds) {
            if ($id -cnotin @($Contract.Evidence.Id)) { throw 'SCENARIO_REFERENCE_INVALID' }
        }
    }
    foreach ($step in $Contract.Steps) {
        foreach ($id in $step.OutcomeIds) {
            if ($id -cnotin @($Contract.Outcomes.Id)) { throw 'SCENARIO_REFERENCE_INVALID' }
        }
    }
    if (@($Contract.Evidence | Where-Object Classification -CNE 'SYNTHETIC').Count) { throw 'SCENARIO_SYNTHETIC_REQUIRED' }
    $phases = @('Arrange', 'Act', 'Observe', 'Assert', 'Cleanup')
    for ($i = 0; $i -lt 5; $i++) {
        $phase = $Plan.Phases[$i]
        if ($phase.Phase -cne $phases[$i] -or $phase.StepId -cnotin @($Contract.Steps.Id) -or
            ($phase.Handler -ceq 'FailOnce' -and $phase.Phase -cne 'Cleanup')) { throw 'SCENARIO_PHASE_INVALID' }
        if ($i -lt 4 -and $phase.PhaseTimeoutMilliseconds -gt $Plan.TimeoutMilliseconds) { throw 'SCENARIO_PHASE_TIMEOUT_INVALID' }
    }
}

function Assert-LabScenarioPath {
    param([Parameter(Mandatory)][string]$Path)
    $cursor = [IO.Path]::GetFullPath($Path)
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'SCENARIO_PATH_UNSAFE' }
        }
        $cursor = [IO.Path]::GetDirectoryName($cursor)
    }
}

function Get-LabScenarioAuthentication {
    param([Parameter(Mandatory)][string]$Content, [Parameter(Mandatory)][byte[]]$OwnershipKey)
    $hmac = [Security.Cryptography.HMACSHA256]::new($OwnershipKey)
    try { return [Convert]::ToHexString($hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($Content))).ToLowerInvariant() }
    finally { $hmac.Dispose() }
}

function Read-LabScenarioJournal {
    param([string]$Path, [byte[]]$OwnershipKey, [string]$OwnerId, [string]$OperationId, [string]$PlanHash)
    Assert-LabScenarioPath $Path
    try {
        if ((Get-Item -LiteralPath $Path -Force).Length -gt 65536) { throw 'size' }
        $envelope = [IO.File]::ReadAllText($Path) | ConvertFrom-Json -Depth 30 -AsHashtable
        if (($envelope.Keys | Sort-Object) -join ',' -cne 'Authentication,Payload') { throw 'envelope' }
        $authentication = Get-LabScenarioAuthentication -Content $envelope.Payload -OwnershipKey $OwnershipKey
        if ($authentication -cne $envelope.Authentication) { throw 'authentication' }
        $state = $envelope.Payload | ConvertFrom-Json -Depth 20 -AsHashtable
        $stateSchema = Join-Path $PSScriptRoot '../Schemas/scenario-execution-journal.schema.json'
        if (-not ($envelope.Payload | Test-Json -SchemaFile $stateSchema -ErrorAction SilentlyContinue)) { throw 'shape' }
        if ($state.ContractVersion -cne 'SqlServerLab.InternalSyntheticScenarioJournal/0.1' -or
            $state.OwnerId -cne $OwnerId -or $state.OperationId -cne $OperationId -or $state.PlanHash -cne $PlanHash) { throw 'binding' }
        if (($state.Status -eq 'COMPLETED' -and $state.ArrangeBegun -and ($state.CleanupStatus -ne 'PASSED' -or $state.ResourcePresent)) -or
            ($state.PrimaryStatus -eq 'PASSED' -and @($state.Phases | Where-Object { $_.Phase -eq 'Assert' -and $_.Status -eq 'PASSED' }).Count -ne 1)) { throw 'outcome' }
        return $state
    }
    catch { throw 'SCENARIO_JOURNAL_UNTRUSTED' }
}

function Write-LabScenarioJournal {
    param([string]$Path, [byte[]]$OwnershipKey, [System.Collections.IDictionary]$State, [AllowEmptyString()][string]$PreviousAuthentication)
    Assert-LabScenarioPath $Path
    if (Test-Path -LiteralPath $Path) {
        $null = Read-LabScenarioJournal -Path $Path -OwnershipKey $OwnershipKey -OwnerId $State.OwnerId -OperationId $State.OperationId -PlanHash $State.PlanHash
        $previous = [IO.File]::ReadAllText($Path) | ConvertFrom-Json
        if (-not $PreviousAuthentication -or $previous.Authentication -cne $PreviousAuthentication) { throw 'SCENARIO_JOURNAL_CHANGED' }
    }
    elseif ($PreviousAuthentication) { throw 'SCENARIO_JOURNAL_CHANGED' }
    $payload = $State | ConvertTo-Json -Depth 20 -Compress
    $authentication = Get-LabScenarioAuthentication $payload $OwnershipKey
    $content = @{ Payload = $payload; Authentication = $authentication } | ConvertTo-Json -Compress
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $stream = $null
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        $bytes = [Text.Encoding]::UTF8.GetBytes($content)
        $stream.Write($bytes, 0, $bytes.Length)
        $stream.Flush($true)
        $stream.Dispose(); $stream = $null
        [IO.File]::Move($temporary, $Path, [bool]$PreviousAuthentication)
    }
    finally {
        if ($stream) { $stream.Dispose() }
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
    return $authentication
}

function Invoke-LabSyntheticScenarioPhase {
    param($Phase, [System.Collections.IDictionary]$State, [Diagnostics.Stopwatch]$Clock,
        [int]$TimeoutMilliseconds, [Threading.CancellationToken]$CancellationToken,
        [Diagnostics.Stopwatch]$PhaseClock, [int]$PhaseTimeoutMilliseconds)
    $delay = [Diagnostics.Stopwatch]::StartNew()
    do {
        if ($CancellationToken.IsCancellationRequested) { return 'CANCELLED' }
        if ($Clock.ElapsedMilliseconds -ge $TimeoutMilliseconds) { return 'TIMED_OUT' }
        if ($PhaseClock -and $PhaseClock.ElapsedMilliseconds -ge $PhaseTimeoutMilliseconds) { return 'TIMED_OUT' }
        if ($delay.ElapsedMilliseconds -ge $Phase.DelayMilliseconds) { break }
        [Threading.Thread]::Sleep(1)
    } while ($true)
    if ($Phase.Handler -ceq 'Fail' -or ($Phase.Handler -ceq 'FailOnce' -and $State.CleanupAttempts -eq 1)) { return 'HANDLER_FAILED' }
    switch -CaseSensitive ($Phase.Phase) {
        'Arrange' { $State.SyntheticValue = 0; $State.ResourcePresent = $true }
        'Act' { $State.SyntheticValue = 1 }
        'Observe' { $State.ObservedValue = $State.SyntheticValue }
        'Assert' { if ($State.ObservedValue -ne 1) { return 'ASSERTION_FAILED' } }
        'Cleanup' { $State.ResourcePresent = $false; $State.SyntheticValue = $null; $State.ObservedValue = $null }
    }
    return 'PASSED'
}

function Invoke-LabSyntheticScenario {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Contract,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][string]$JournalDirectory,
        [Parameter(Mandatory)][guid]$OwnerId,
        [Parameter(Mandatory)][guid]$OperationId,
        [Parameter(Mandatory)][byte[]]$OwnershipKey,
        [Threading.CancellationToken]$CancellationToken = [Threading.CancellationToken]::None,
        [switch]$Resume
    )
    $ErrorActionPreference = 'Stop'
    Assert-LabSyntheticScenarioInput $Contract $Plan
    if ($OwnershipKey.Length -ne 32 -or $OwnerId -eq [guid]::Empty -or $OperationId -eq [guid]::Empty) { throw 'SCENARIO_OWNERSHIP_INVALID' }
    # Snapshot declarative input; subsequent caller changes cannot change execution.
    $contractJson = $Contract | ConvertTo-Json -Depth 30 -Compress
    $planJson = $Plan | ConvertTo-Json -Depth 30 -Compress
    $Plan = $planJson | ConvertFrom-Json
    $planHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$contractJson`n$planJson"))).ToLowerInvariant()
    $directory = [IO.Path]::GetFullPath($JournalDirectory)
    Assert-LabScenarioPath $directory
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) { throw 'SCENARIO_DIRECTORY_REQUIRED' }
    $path = Join-Path $directory "$OperationId.scenario.json"
    $lockPath = Join-Path $directory "$OperationId.lock"
    Assert-LabScenarioPath $path
    Assert-LabScenarioPath $lockPath
    # Cancellation before a fresh operation does not even create a lock or journal.
    if (-not $Resume -and $CancellationToken.IsCancellationRequested) {
        return [pscustomobject]@{ ContractVersion = 'SqlServerLab.InternalSyntheticScenarioResult/0.1'; OperationId = $OperationId.ToString(); Status = 'CANCELLED'; PrimaryStatus = 'CANCELLED'; CleanupStatus = 'NOT_REQUIRED'; Phases = @() }
    }
    $lock = $null
    try {
        try { $lock = [IO.File]::Open($lockPath, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
        catch { throw 'SCENARIO_LOCK_UNAVAILABLE' }
        $authentication = ''
        if ($Resume) {
            $state = Read-LabScenarioJournal $path $OwnershipKey $OwnerId.ToString() $OperationId.ToString() $planHash
            $authentication = ([IO.File]::ReadAllText($path) | ConvertFrom-Json).Authentication
        }
        else {
            if (Test-Path -LiteralPath $path) { throw 'SCENARIO_OPERATION_EXISTS' }
            $state = [ordered]@{
                ContractVersion = 'SqlServerLab.InternalSyntheticScenarioJournal/0.1'
                OwnerId = $OwnerId.ToString(); OperationId = $OperationId.ToString(); PlanHash = $planHash
                Status = 'PREPARED'; PrimaryStatus = 'NOT_EXECUTED'; CleanupStatus = 'NOT_REQUIRED'
                ArrangeBegun = $false; ResourcePresent = $false; SyntheticValue = $null; ObservedValue = $null
                CleanupAttempts = 0; Phases = @()
            }
            $authentication = Write-LabScenarioJournal $path $OwnershipKey $state $authentication
        }
        if ($state.Status -ne 'COMPLETED' -and $state.CleanupAttempts -lt 3) {
            if ($Resume -and $state.ArrangeBegun -and $state.PrimaryStatus -eq 'NOT_EXECUTED') { $state.PrimaryStatus = 'INTERRUPTED' }
            try {
                if (-not $Resume -or -not $state.ArrangeBegun) {
                    $clock = [Diagnostics.Stopwatch]::StartNew()
                    for ($i = 0; $i -lt 4; $i++) {
                        if ($CancellationToken.IsCancellationRequested) { $state.PrimaryStatus = 'CANCELLED'; break }
                        if ($clock.ElapsedMilliseconds -ge $Plan.TimeoutMilliseconds) { $state.PrimaryStatus = 'TIMED_OUT'; break }
                        # Each primary phase gets a new cap; checkpoint time also consumes it.
                        # The global clock is never reset, so the earlier deadline always wins.
                        $phaseClock = [Diagnostics.Stopwatch]::StartNew()
                        if ($i -eq 0) { $state.ArrangeBegun = $true; $state.CleanupStatus = 'PENDING' }
                        $state.Status = 'IN_PROGRESS'
                        $state.Phases += @{ Phase = $Plan.Phases[$i].Phase; Status = 'IN_PROGRESS' }
                        $authentication = Write-LabScenarioJournal $path $OwnershipKey $state $authentication
                        $phaseStatus = Invoke-LabSyntheticScenarioPhase $Plan.Phases[$i] $state $clock $Plan.TimeoutMilliseconds $CancellationToken $phaseClock $Plan.Phases[$i].PhaseTimeoutMilliseconds
                        $state.Phases[-1].Status = $phaseStatus
                        if ($phaseStatus -ne 'PASSED') { $state.PrimaryStatus = $phaseStatus }
                        elseif ($i -eq 3) { $state.PrimaryStatus = 'PASSED' }
                        $authentication = Write-LabScenarioJournal $path $OwnershipKey $state $authentication
                        if ($phaseStatus -ne 'PASSED') { break }
                    }
                }
            }
            catch {
                $state.PrimaryStatus = 'EXECUTION_FAILED'
                throw
            }
            finally {
                if ($state.ArrangeBegun) {
                    # Revalidate before cleanup; a corrupt journal never authorizes mutation.
                    $null = Read-LabScenarioJournal $path $OwnershipKey $OwnerId.ToString() $OperationId.ToString() $planHash
                    $state.CleanupAttempts++
                    $state.CleanupStatus = 'IN_PROGRESS'
                    $authentication = Write-LabScenarioJournal $path $OwnershipKey $state $authentication
                    $cleanupClock = [Diagnostics.Stopwatch]::StartNew()
                    $cleanupStatus = Invoke-LabSyntheticScenarioPhase $Plan.Phases[4] $state $cleanupClock $Plan.CleanupTimeoutMilliseconds ([Threading.CancellationToken]::None)
                    $state.CleanupStatus = $cleanupStatus
                    $state.Phases += @{ Phase = 'Cleanup'; Status = $cleanupStatus }
                    $state.Status = if ($cleanupStatus -eq 'PASSED') { 'COMPLETED' } else { 'RECOVERY_REQUIRED' }
                    $authentication = Write-LabScenarioJournal $path $OwnershipKey $state $authentication
                }
            }
            if (-not $state.ArrangeBegun) {
                $state.Status = 'COMPLETED'
                $authentication = Write-LabScenarioJournal $path $OwnershipKey $state $authentication
            }
        }
        # No paths, key, arbitrary handler output, or raw error details in the result.
        return [pscustomobject]@{
            ContractVersion = 'SqlServerLab.InternalSyntheticScenarioResult/0.1'
            OperationId = $OperationId.ToString()
            Status = if ($state.Status -eq 'RECOVERY_REQUIRED') { 'RECOVERY_REQUIRED' } else { $state.PrimaryStatus }
            PrimaryStatus = $state.PrimaryStatus; CleanupStatus = $state.CleanupStatus
            Phases = @($state.Phases | ForEach-Object { [pscustomobject]@{ Phase = $_.Phase; Status = $_.Status } })
        }
    }
    catch {
        $reason = $_.Exception.Message
        if ($reason -cin @('SCENARIO_JOURNAL_UNTRUSTED', 'SCENARIO_JOURNAL_CHANGED', 'SCENARIO_OPERATION_EXISTS', 'SCENARIO_LOCK_UNAVAILABLE', 'SCENARIO_PATH_UNSAFE')) { throw $reason }
        throw 'SCENARIO_EXECUTION_FAILED'
    }
    finally { if ($lock) { $lock.Dispose() } }
}
