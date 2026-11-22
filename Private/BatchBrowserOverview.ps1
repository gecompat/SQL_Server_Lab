function Get-LabBrowserBatchOverview {
    param([object[]]$Batches)
    foreach ($batch in @($Batches | Select-Object -First 50)) {
        if ($null -eq $batch -or $batch.PSObject.Properties['batchId']?.Value -isnot [string] -or
            $batch.batchId -cnotmatch '\Abatch-\d{14}-[0-9a-f]{8}\z' -or
            $batch.PSObject.Properties['status']?.Value -isnot [string] -or
            $batch.status -cnotin @('Draft','Validated','Queued','Running','Waiting','CleanupQueued','Completed','CompletedWithErrors','Cancelled')) {
            continue
        }
        $progress = $batch.PSObject.Properties['progress']?.Value
        $errors = $batch.PSObject.Properties['errorStatus']?.Value
        if ($null -eq $progress -or $null -eq $errors) { continue }
        $percent = $progress.PSObject.Properties['percent']?.Value
        $total = $progress.PSObject.Properties['total']?.Value
        $failed = $errors.PSObject.Properties['failed']?.Value
        $cancelled = $errors.PSObject.Properties['cancelled']?.Value
        if (($percent -isnot [long] -and $percent -isnot [double] -and $percent -isnot [int]) -or
            [double]::IsNaN($percent) -or $percent -lt 0 -or $percent -gt 100 -or
            @(@($total,$failed,$cancelled) | Where-Object { ($_ -isnot [int] -and $_ -isnot [long]) -or $_ -lt 0 -or $_ -gt [int]::MaxValue }).Count -or
            ($failed + $cancelled) -gt $total) { continue }
        [pscustomobject]@{
            BatchId=$batch.batchId; Status=$batch.status; Percent=$percent; Total=$total
            Failed=$failed; Cancelled=$cancelled
        }
    }
}

function Get-LabBrowserBatchStopSnapshot {
    param([string]$BatchId, [string]$StateRoot)

    if ($BatchId -cnotmatch '\Abatch-\d{14}-[0-9a-f]{8}\z') { throw 'BROWSER_BATCH_STOP_INVALID_BATCH' }
    $batch = Read-LabWorkflowJson -Path (Join-Path (Join-Path $StateRoot 'batches') ($BatchId + '.json'))
    if ($null -eq $batch -or $batch.contract -cne 'SqlServerLab.Batch/1.0' -or $batch.batchId -cne $BatchId -or
        $batch.status -cnotin @('Queued','Running','Waiting','CleanupQueued')) {
        throw 'BROWSER_BATCH_STOP_BATCH_UNAVAILABLE'
    }

    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $prefix = 'op-' + $BatchId + '-'
    $targets = @(foreach ($id in @($batch.operationIds)) {
        if ($id -isnot [string] -or -not $id.StartsWith($prefix,[StringComparison]::Ordinal) -or
            $id -cnotmatch '\A[a-z0-9_-]+\z' -or -not $ids.Add($id)) {
            throw 'BROWSER_BATCH_STOP_BATCH_INVALID'
        }
        $operation = Read-LabWorkflowJson -Path (Join-Path (Join-Path $StateRoot 'operations') ($id + '.json'))
        if ($null -eq $operation -or $operation.contract -cne 'SqlServerLab.Operation/1.0' -or $operation.operationId -cne $id -or $operation.batchId -cne $BatchId -or
            $operation.status -cnotin @('Draft','Queued','WaitingForDependency','WaitingForUser','CandidateSatisfied','Paused','Running','CleanupQueued','Completed','Failed','Cancelled')) {
            throw 'BROWSER_BATCH_STOP_BATCH_INVALID'
        }
        if (-not (Test-LabOperationTerminal -Status $operation.status) -and
            $operation.status -cne 'CleanupQueued' -and -not $operation.cancelRequested) {
            [pscustomobject]@{ Id=$id; Status=[string]$operation.status }
        }
    })
    $signature = ConvertTo-Json -InputObject $targets -Depth 4 -Compress
    [pscustomobject]@{
        Key=(Get-LabWorkflowHash -Text $signature -Length 64)
        Targets=$targets
    }
}

function New-LabBrowserBatchStopPreview {
    param([string]$BatchId, [string]$StateRoot)

    $script:LabBrowserBatchStopPreview = $null
    $snapshot = Get-LabBrowserBatchStopSnapshot -BatchId $BatchId -StateRoot $StateRoot
    if ($snapshot.Targets.Count -eq 0) { throw 'BROWSER_BATCH_STOP_NO_TARGETS' }

    $token = [guid]::NewGuid().ToString('N')
    $script:LabBrowserBatchStopPreview = [pscustomobject]@{
        Id=$token; BatchId=$BatchId; StateRoot=$StateRoot; Key=$snapshot.Key
        Expires=[datetime]::UtcNow.AddMinutes(5)
    }
    [pscustomobject]@{
        PreviewId=$token; BatchId=$BatchId
        Pending=$snapshot.Targets.Count
        Running=@($snapshot.Targets | Where-Object Status -CEQ 'Running').Count
    }
}

function Invoke-LabBrowserBatchStopPreview {
    param([string]$BatchId, [string]$PreviewId, [string]$StateRoot)

    $preview = $script:LabBrowserBatchStopPreview
    if ($null -eq $preview -or $PreviewId -cnotmatch '\A[0-9a-f]{32}\z' -or
        $preview.Id -cne $PreviewId -or $preview.BatchId -cne $BatchId -or
        $preview.StateRoot -cne $StateRoot -or $preview.Expires -le [datetime]::UtcNow) {
        throw 'BROWSER_BATCH_STOP_PREVIEW_REQUIRED'
    }
    $script:LabBrowserBatchStopPreview = $null
    Invoke-WithLabWorkflowLock -StateRoot $StateRoot -ScriptBlock {
        $snapshot = Get-LabBrowserBatchStopSnapshot -BatchId $BatchId -StateRoot $StateRoot
        if ($snapshot.Key -cne $preview.Key) { throw 'BROWSER_BATCH_STOP_PREVIEW_STALE' }

        $requested = 0
        foreach ($target in $snapshot.Targets) {
            $operation = Stop-LabWorkflowOperation -OperationId $target.Id -Cleanup -UnfinishedOnly -StateRoot $StateRoot
            if ($operation.cancelRequested -and $operation.cleanupRequested -and
                -not (Test-LabOperationTerminal -Status $operation.status)) {
                $requested++
            }
        }
        [pscustomobject]@{ BatchId=$BatchId; Requested=$requested }
    }
}
