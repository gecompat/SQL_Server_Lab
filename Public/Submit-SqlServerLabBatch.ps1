function Submit-SqlServerLabBatch {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$BatchId,

        [string]$StateRoot
    )

    $batch = Get-SqlServerLabBatch -BatchId $BatchId -StateRoot $StateRoot
    if ($batch.status -notin @('Draft', 'Validated')) {
        return $batch
    }
    $blockers = @(Get-LabBatchSubmissionBlocker -Batch $batch -StateRoot $StateRoot)
    if ($blockers.Count -gt 0) {
        $detail = ($blockers | ForEach-Object { "$($_.message) $($_.remedy)" }) -join ' '
        throw "$($blockers[0].code): $detail"
    }
    $batch.status = 'Queued'
    Write-LabBatchState -Batch $batch -StateRoot $StateRoot | Out-Null
    return $batch
}

