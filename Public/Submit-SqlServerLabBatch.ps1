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

function Get-LabBatchReviewSignature {
    param([Parameter(Mandatory)][object]$Batch, [string]$StateRoot)

    if ($Batch.batchId -cnotmatch '\Abatch-\d{14}-[0-9a-f]{8}\z') { throw 'BATCH_REVIEW_INVALID' }
    $prefix = 'op-' + $Batch.batchId + '-'
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $operations = @(foreach ($id in @($Batch.operationIds)) {
        if ($id -isnot [string] -or !$id.StartsWith($prefix, [StringComparison]::Ordinal) -or
            $id -cnotmatch '\A[a-z0-9_-]+\z' -or !$ids.Add($id)) { throw 'BATCH_REVIEW_INVALID' }
        $operation = Read-LabWorkflowJson -Path (Join-Path (Join-Path $StateRoot 'operations') ($id + '.json'))
        if ($null -eq $operation -or $operation.contract -cne 'SqlServerLab.Operation/1.0' -or
            $operation.operationId -cne $id -or $operation.batchId -cne $Batch.batchId -or
            $operation.status -cnotin @('Draft','Queued','WaitingForDependency','Paused') -or
            $operation.cancelRequested) { throw 'BATCH_REVIEW_STALE' }
        $operation
    })
    if (!$operations.Count) { throw 'BATCH_REVIEW_INVALID' }
    $snapshot = [ordered]@{ Batch=$Batch; Operations=$operations }
    Get-LabWorkflowHash -Text ($snapshot | ConvertTo-Json -Depth 50 -Compress) -Length 64
}

function Submit-LabReviewedBatch {
    param([string]$BatchId, [string]$StateRoot, [string]$Signature)

    if ($BatchId -cnotmatch '\Abatch-\d{14}-[0-9a-f]{8}\z' -or $Signature -cnotmatch '\A[0-9a-f]{64}\z') {
        throw 'BATCH_REVIEW_INVALID'
    }
    Invoke-WithLabWorkflowLock -StateRoot $StateRoot -ScriptBlock {
        $current = Get-SqlServerLabBatch -BatchId $BatchId -StateRoot $StateRoot
        if ($current.contract -cne 'SqlServerLab.Batch/1.0' -or $current.batchId -cne $BatchId -or
            $current.status -cne 'Validated' -or (Get-LabBatchReviewSignature -Batch $current -StateRoot $StateRoot) -cne $Signature) {
            throw 'BATCH_REVIEW_STALE'
        }
        Submit-SqlServerLabBatch -BatchId $BatchId -StateRoot $StateRoot
    }
}

