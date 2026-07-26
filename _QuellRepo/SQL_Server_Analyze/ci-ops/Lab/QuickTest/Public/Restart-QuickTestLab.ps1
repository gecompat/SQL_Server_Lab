Set-StrictMode -Version Latest

function Restart-QuickTestLab {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
        [string] $ScopeName = 'sql-analyze-quicktest',

        [Parameter()]
        [string] $StateRoot = (Join-Path $script:QuickTestLabRoot '.state/quick-test'),

        [Parameter()]
        [ValidateRange(1, 300)]
        [int] $StopTimeoutSeconds = 30
    )

    $statusBefore = Get-QuickTestLabStatus `
        -ScopeName $ScopeName `
        -StateRoot $StateRoot
    if ($statusBefore.Status -eq 'NOT_INSTALLED') {
        return [pscustomobject] @{
            Status = 'NOT_INSTALLED'
            ScopeName = $ScopeName
        }
    }
    if ($statusBefore.Status -eq 'RUNTIME_UNAVAILABLE') {
        return $statusBefore
    }
    if ($statusBefore.Status -ne 'READY') {
        return [pscustomobject] @{
            Status = 'RESTART_STATE_INVALID'
            ScopeName = $ScopeName
            LifecycleStatus = [string] $statusBefore.LifecycleStatus
        }
    }

    $expectedStateRoot = [IO.Path]::GetFullPath($StateRoot)
    $scopeStateDirectory = [IO.Path]::GetFullPath(
        (Join-Path $expectedStateRoot $ScopeName)
    )
    $statePath = Join-Path $scopeStateDirectory 'state.json'
    $stateBefore = Read-QuickTestJson -Path $statePath
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $stateBefore.RunId)) {
        throw 'Restart refused an unowned or out-of-bound state directory.'
    }
    $runIdBefore = [string] $stateBefore.RunId
    $networkIdBefore = [string] $stateBefore.NetworkId
    if ($networkIdBefore -notmatch '^[a-f0-9]{64}$') {
        throw 'Restart found a non-canonical network ID in state.'
    }
    $containerIdsBefore = @(
        $stateBefore.Containers |
            Sort-Object -Property SqlVersion |
            ForEach-Object {
                $containerId = [string] $_.ContainerId
                if ($containerId -notmatch '^[a-f0-9]{64}$') {
                    throw 'Restart found a non-canonical container ID in state.'
                }
                $containerId
            }
    )
    if ($containerIdsBefore.Count -eq 0) {
        throw 'Restart found no registered containers in state.'
    }

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Stop and restart existing registered SQL Server containers'
        )) {
        return [pscustomobject] @{
            Status = 'WHATIF'
            ScopeName = $ScopeName
        }
    }

    $stopResult = Stop-QuickTestLab `
        -ScopeName $ScopeName `
        -StateRoot $expectedStateRoot `
        -TimeoutSeconds $StopTimeoutSeconds `
        -Confirm:$false
    if ($stopResult.Status -ne 'STOPPED') {
        return [pscustomobject] @{
            Status = 'RESTART_STOP_FAILED'
            ScopeName = $ScopeName
            StopStatus = [string] $stopResult.Status
        }
    }

    $startResult = Start-QuickTestStoppedLab `
        -ScopeName $ScopeName `
        -StateRoot $expectedStateRoot `
        -Confirm:$false
    if ($startResult.Status -ne 'READY') {
        return [pscustomobject] @{
            Status = 'RESTART_START_FAILED'
            ScopeName = $ScopeName
            StartStatus = [string] $startResult.Status
        }
    }

    $stateAfter = Read-QuickTestJson -Path $statePath
    $containerIdsAfter = @(
        $stateAfter.Containers |
            Sort-Object -Property SqlVersion |
            ForEach-Object { [string] $_.ContainerId }
    )
    if (
        [string] $stateAfter.RunId -ne $runIdBefore -or
        [string] $stateAfter.NetworkId -ne $networkIdBefore -or
        $containerIdsAfter.Count -ne $containerIdsBefore.Count
    ) {
        throw 'Restart changed the preserved quick-test runtime identity.'
    }
    for ($index = 0; $index -lt $containerIdsBefore.Count; $index++) {
        if ($containerIdsAfter[$index] -ne $containerIdsBefore[$index]) {
            throw 'Restart changed a preserved quick-test container ID.'
        }
    }

    $statusAfter = Get-QuickTestLabStatus `
        -ScopeName $ScopeName `
        -StateRoot $expectedStateRoot
    if ($statusAfter.Status -ne 'READY') {
        throw 'Restart completed without a fully READY quick-test scope.'
    }

    return [pscustomobject] @{
        Status = 'READY'
        ScopeName = $ScopeName
        Runtime = $startResult.Runtime
        Restarted = $true
        ContainersRestarted = $containerIdsBefore.Count
        RuntimeIdentityPreserved = $true
        NetworkPreserved = $true
        DataPreserved = $true
        StatePreserved = $true
        Connections = $startResult.Connections
    }
}
