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
