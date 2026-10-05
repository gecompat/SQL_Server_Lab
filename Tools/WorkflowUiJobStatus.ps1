# UI-owned batch status only. Never initialize, repair or schedule the workflow store.
function Read-UiJobState {
    param([string]$StateRoot, [ValidateSet('batches','operations')][string]$Kind, [string]$Id)
    if ($Id -cnotmatch '^[a-z0-9][a-z0-9_-]{0,127}$') { throw 'UI_JOB_SOURCE_INVALID' }
    $root = [IO.Path]::GetFullPath($StateRoot)
    $path = Join-Path (Join-Path $root $Kind) ($Id + '.json')
    $cursor = $path
    while ($cursor) {
        if (Test-Path -LiteralPath $cursor) {
            $item = Get-Item -LiteralPath $cursor -Force -ErrorAction Stop
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'UI_JOB_SOURCE_INVALID' }
        }
        $parent = Split-Path -Parent $cursor
        if ($parent -eq $cursor) { break }; $cursor = $parent
    }
    $file = Get-Item -LiteralPath $path -ErrorAction Stop
    if ($file.PSIsContainer -or $file.Length -gt 1048576) { throw 'UI_JOB_SOURCE_INVALID' }
    $stream = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete))
    $reader = $null
    try {
        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false, $true))
        $buffer = [char[]]::new(1048577)
        $count = $reader.ReadBlock($buffer, 0, $buffer.Length)
        if ($count -eq 0 -or $count -gt 1048576) { throw 'UI_JOB_SOURCE_INVALID' }
        return [string]::new($buffer, 0, $count) | ConvertFrom-Json -Depth 40 -ErrorAction Stop
    }
    finally { if ($reader) { $reader.Dispose() }; $stream.Dispose() }
}

function Get-UiPersistentJobSnapshot {
    param([Parameter(Mandatory)]$Record)
    if ($Record.TerminalSnapshot) { return $Record.TerminalSnapshot }
    $state = 'Unknown'; $reason = 'STATUS_SOURCE_UNAVAILABLE'
    $counts = [ordered]@{}
    $lastActivity = $null
    try {
        $batch = Read-UiJobState -StateRoot $Record.StateRoot -Kind batches -Id $Record.Id
        if ($batch.contract -isnot [string] -or $batch.contract -cne 'SqlServerLab.Batch/1.0' -or $batch.batchId -isnot [string] -or $batch.batchId -cne $Record.Id) { throw 'UI_JOB_SOURCE_INVALID' }
        if ($batch.status -isnot [string] -or $batch.status -cnotin @('Draft','Validated','Queued','Running','Waiting','CleanupQueued','Completed','CompletedWithErrors','Cancelled')) { throw 'UI_JOB_SOURCE_INVALID' }
        $ids = @($batch.operationIds)
        if ($ids.Count -lt 1 -or $ids.Count -gt 64 -or @($ids | Select-Object -Unique).Count -ne $ids.Count) { throw 'UI_JOB_SOURCE_INVALID' }
        if ((($ids | Sort-Object) -join ',') -cne ((@($Record.OperationIds) | Sort-Object) -join ',')) { throw 'UI_JOB_SOURCE_INVALID' }
        $allowed = @('Draft','Queued','Running','WaitingForDependency','WaitingForUser','CandidateSatisfied','Paused','CleanupQueued','Completed','Failed','Cancelled')
        foreach ($id in $ids) {
            if ($id -isnot [string]) { throw 'UI_JOB_SOURCE_INVALID' }
            $operation = Read-UiJobState -StateRoot $Record.StateRoot -Kind operations -Id $id
            if ($operation.contract -isnot [string] -or $operation.contract -cne 'SqlServerLab.Operation/1.0' -or $operation.operationId -isnot [string] -or $operation.operationId -cne $id -or $operation.batchId -isnot [string] -or $operation.batchId -cne $Record.Id -or $operation.status -isnot [string] -or $operation.status -cnotin $allowed) { throw 'UI_JOB_SOURCE_INVALID' }
            if (-not $counts.Contains($operation.status)) { $counts[$operation.status] = 0 }
            $counts[$operation.status]++
            # Only persisted event time, never polling time or a synthetic heartbeat.
            $property = $operation.PSObject.Properties['updatedAt']
            if ($property -and ($property.Value -is [string] -or $property.Value -is [DateTime] -or $property.Value -is [DateTimeOffset])) {
                $timestamp = [DateTimeOffset]::MinValue
                $validTimestamp = if ($property.Value -is [DateTimeOffset]) { $timestamp=$property.Value; $true } elseif ($property.Value -is [DateTime]) { $timestamp=[DateTimeOffset]::new($property.Value.ToUniversalTime()); $true } else { [DateTimeOffset]::TryParse($property.Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind, [ref]$timestamp) }
                if ($validTimestamp) {
                    if ($null -eq $lastActivity -or $timestamp -gt $lastActivity) { $lastActivity = $timestamp }
                }
            }
        }
        $states = @($counts.Keys)
        if (@($states | Where-Object { $_ -notin @('Completed','Failed','Cancelled') }).Count -eq 0) {
            $state = if ($states -contains 'Failed') { 'Failed' } elseif ($states -contains 'Cancelled') { 'Cancelled' } else { 'Completed' }
        }
        elseif ($states -contains 'Running') { $state = 'Running' }
        elseif ($states -contains 'CleanupQueued') { $state = 'Waiting' }
        elseif ($states -contains 'Paused' -or $states -contains 'WaitingForUser' -or $states -contains 'CandidateSatisfied' -or $states -contains 'Draft' -or $batch.status -in @('Draft','Validated')) { $state = 'Blocked' }
        else { $state = 'Waiting' }
        $reason = switch ($state) {
            Running { 'OPERATION_REPORTED_RUNNING' }
            Blocked { 'OPERATION_REQUIRES_RELEASE' }
            Waiting { 'OPERATION_QUEUED_OR_WAITING' }
            Completed { 'OPERATIONS_COMPLETED' }
            Failed { 'OPERATIONS_FAILED' }
            Cancelled { 'OPERATIONS_CANCELLED' }
        }
    }
    catch { $counts = [ordered]@{}; $lastActivity = $null }
    $snapshot = [pscustomobject]@{
        Id = $Record.Id; Action = $Record.Action; State = $state; Source = 'PersistentBatch'
        Reason = $reason; HostStart = $Record.HostStart; StartedAt = $Record.StartedAt
        LastActivityAt = if ($null -ne $lastActivity) { $lastActivity.UtcDateTime.ToString('o') } else { $null }
        Lines = @('[STATUS] ' + $reason) + $(if ($Record.HostStart -eq 'Failed') { @('[HOSTSTART] OPERATION_HOST_START_FAILED · Annahme bleibt bestehen; keine automatische Wiederholung.') } else { @() })
        OperationCounts = [pscustomobject]$counts
    }
    if ($state -in @('Completed','Failed','Cancelled')) { $Record.TerminalSnapshot = $snapshot }
    return $snapshot
}

function Invoke-UiOperationHostStart {
    param([string]$StateRoot)
    try { & (Get-Module SqlServerLab) { param($Root) Start-SqlServerLabOperationHost -StateRoot $Root } $StateRoot | Out-Null; return 'Requested' }
    catch { return 'Failed' }
}
