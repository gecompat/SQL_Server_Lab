function Set-SqlServerLabBatchPriority {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$BatchId,
        [Parameter(Mandatory)][ValidateSet('High', 'Normal', 'Low')][string]$Priority,
        [string]$StateRoot
    )

    $batch = Get-SqlServerLabBatch -BatchId $BatchId -StateRoot $StateRoot
    $batch.priority = $Priority
    foreach ($operation in @(Get-SqlServerLabOperation -BatchId $BatchId -StateRoot $StateRoot)) {
        if (-not [bool]$operation.priorityOverridden -and -not (Test-LabOperationTerminal -Status $operation.status)) {
            $operation.priority = $Priority
            Add-LabOperationEvent -Operation $operation -Type 'BatchPriorityChanged' -Message "Batch-Prioritaet wurde auf '$Priority' gesetzt." -StateRoot $StateRoot | Out-Null
            Write-LabOperationState -Operation $operation -StateRoot $StateRoot | Out-Null
        }
    }
    Write-LabBatchState -Batch $batch -StateRoot $StateRoot | Out-Null
    return $batch
}
