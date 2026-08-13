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
    $batch.status = 'Queued'
    Write-LabBatchState -Batch $batch -StateRoot $StateRoot | Out-Null
    return $batch
}

