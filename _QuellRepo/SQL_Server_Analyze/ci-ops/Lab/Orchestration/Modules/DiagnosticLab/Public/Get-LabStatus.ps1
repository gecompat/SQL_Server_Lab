function Get-LabStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $runDirectory = Get-LabRunDirectory -LabRunId $LabRunId -StateRoot $StateRoot
    if (-not (Test-Path -LiteralPath $runDirectory -PathType Container)) {
        throw 'LAB-001 run state does not exist.'
    }
    $lockPath = Join-Path $runDirectory 'run.lock'
    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) {
        throw 'LAB-001 run lock does not exist.'
    }
    $stateLock = Enter-LabStateLock -LockPath $lockPath
    try {
        $state = Read-LabJsonFile -Path (Join-Path $runDirectory 'run-state.json')
        $registry = Read-LabJsonFile `
            -Path (Join-Path $runDirectory 'resource-registry.json')

        return [pscustomobject] @{
            SchemaVersion = '1.0'
            DataClassification = 'LOCAL_RUNTIME_STATE'
            LabRunId = $LabRunId
            LifecycleStatus = $state.LifecycleStatus
            PreflightStatus = $state.PreflightStatus
            RequestedExecutionMode = $state.RequestedExecutionMode
            ResolvedExecutionMode = $state.ResolvedExecutionMode
            LocalHostClass = $state.LocalHostClass
            PreflightInvocationCount = $state.PreflightInvocationCount
            RegisteredResourceCount = @($registry.Resources).Count
            RegisteredResourceIds = @(
                $registry.Resources | ForEach-Object { $_.ResourceId }
            )
            LastUpdatedAtUtc = $state.LastUpdatedAtUtc
        }
    }
    finally {
        $stateLock.Dispose()
    }
}
