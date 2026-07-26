Set-StrictMode -Version Latest

function Stop-QuickTestLab {
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
        [int] $TimeoutSeconds = 30
    )

    $expectedStateRoot = [IO.Path]::GetFullPath($StateRoot)
    $scopeStateDirectory = [IO.Path]::GetFullPath(
        (Join-Path $expectedStateRoot $ScopeName)
    )
    $statePath = Join-Path $scopeStateDirectory 'state.json'
    if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) {
        return [pscustomobject] @{
            Status = 'NOT_INSTALLED'
            ScopeName = $ScopeName
        }
    }

    $state = Read-QuickTestJson -Path $statePath
    if (
        [IO.Path]::GetFullPath([string] $state.StateBaseRoot) -ne $expectedStateRoot -or
        [IO.Path]::GetFullPath([string] $state.StateDirectory) -ne $scopeStateDirectory
    ) {
        throw 'Stop refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'Stop refused an unowned or out-of-bound state directory.'
    }

    if ([string] $state.LifecycleStatus -eq 'DOWN') {
        return [pscustomobject] @{
            Status = 'STOP_STATE_INVALID'
            ScopeName = $ScopeName
            LifecycleStatus = 'DOWN'
        }
    }
    if ([string] $state.LifecycleStatus -notin @(
            'READY'
            'STOPPING'
            'STOP_FAILED'
            'STOPPED'
        )) {
        return [pscustomobject] @{
            Status = 'STOP_STATE_INVALID'
            ScopeName = $ScopeName
            LifecycleStatus = [string] $state.LifecycleStatus
        }
    }

    $runtimeInfo = Resolve-QuickTestRuntime -Runtime $state.Runtime
    if (-not $runtimeInfo.IsAvailable) {
        return [pscustomobject] @{
            Status = 'RUNTIME_UNAVAILABLE'
            ScopeName = $ScopeName
            Runtime = $state.Runtime
        }
    }

    $registeredContainers = @(
        $state.Containers |
            Sort-Object -Property SqlVersion -Descending
    )
    if ($registeredContainers.Count -eq 0) {
        throw 'Stop found no registered containers in state.'
    }
    $registeredContainerIds = @(
        foreach ($container in $registeredContainers) {
            $containerId = [string] $container.ContainerId
            if ($containerId -notmatch '^[a-f0-9]{64}$') {
                throw 'Stop found a non-canonical container ID in state.'
            }
            $containerId
        }
    )
    $registeredNetworkIds = @()
    if (-not [string]::IsNullOrWhiteSpace([string] $state.NetworkId)) {
        if ([string] $state.NetworkId -notmatch '^[a-f0-9]{64}$') {
            throw 'Stop found a non-canonical network ID in state.'
        }
        $registeredNetworkIds = @([string] $state.NetworkId)
    }
    if ($registeredNetworkIds.Count -ne 1) {
        throw 'Stop requires exactly one registered network ID.'
    }

    $discovered = Get-QuickTestResourcesByRunId `
        -RuntimeInfo $runtimeInfo `
        -RunId $state.RunId
    $unexpectedContainers = @(
        $discovered.ContainerIds |
            Where-Object { $_ -notin $registeredContainerIds }
    )
    $unexpectedNetworks = @(
        $discovered.NetworkIds |
            Where-Object { $_ -notin $registeredNetworkIds }
    )
    $missingContainers = @(
        $registeredContainerIds |
            Where-Object { $_ -notin $discovered.ContainerIds }
    )
    $missingNetworks = @(
        $registeredNetworkIds |
            Where-Object { $_ -notin $discovered.NetworkIds }
    )
    if (
        $unexpectedContainers.Count -gt 0 -or
        $unexpectedNetworks.Count -gt 0 -or
        $missingContainers.Count -gt 0 -or
        $missingNetworks.Count -gt 0
    ) {
        return [pscustomobject] @{
            Status = 'STOP_SCOPE_CONFLICT'
            ScopeName = $ScopeName
        }
    }

    foreach ($containerId in $registeredContainerIds) {
        $runOwner = Get-QuickTestObjectLabel `
            -RuntimeInfo $runtimeInfo `
            -ResourceType CONTAINER `
            -ExactLocator $containerId `
            -LabelName 'qt-lab.run-id'
        $frameworkOwner = Get-QuickTestObjectLabel `
            -RuntimeInfo $runtimeInfo `
            -ResourceType CONTAINER `
            -ExactLocator $containerId `
            -LabelName 'qt-lab.owner'
        if ($runOwner -ne $state.RunId -or $frameworkOwner -ne 'SQL_SERVER_ANALYZE') {
            throw 'Stop refused a container with mismatched ownership.'
        }
    }
    $networkId = $registeredNetworkIds[0]
    $networkRunOwner = Get-QuickTestObjectLabel `
        -RuntimeInfo $runtimeInfo `
        -ResourceType NETWORK `
        -ExactLocator $networkId `
        -LabelName 'qt-lab.run-id'
    $networkFrameworkOwner = Get-QuickTestObjectLabel `
        -RuntimeInfo $runtimeInfo `
        -ResourceType NETWORK `
        -ExactLocator $networkId `
        -LabelName 'qt-lab.owner'
    if (
        $networkRunOwner -ne $state.RunId -or
        $networkFrameworkOwner -ne 'SQL_SERVER_ANALYZE'
    ) {
        throw 'Stop refused a network with mismatched ownership.'
    }

    $allStopped = $true
    foreach ($containerId in $registeredContainerIds) {
        $runtimeStatus = [string] (
            Invoke-QuickTestExternalCommand `
                -FilePath $runtimeInfo.Command `
                -Arguments @(
                    'container'
                    'inspect'
                    '--format'
                    '{{.State.Status}}'
                    $containerId
                ) |
                Select-Object -First 1
        )
        if ($runtimeStatus -notin @('exited', 'stopped')) {
            $allStopped = $false
            break
        }
    }
    if ([string] $state.LifecycleStatus -eq 'STOPPED' -and $allStopped) {
        return [pscustomobject] @{
            Status = 'STOPPED'
            ScopeName = $ScopeName
            AlreadyStopped = $true
            ContainersStopped = 0
            NetworkPreserved = $true
            DataPreserved = $true
            StatePreserved = $true
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Stop registered SQL Server containers while preserving network, state, and data'
        )) {
        return [pscustomobject] @{
            Status = 'WHATIF'
            ScopeName = $ScopeName
        }
    }

    $state.LifecycleStatus = 'STOPPING'
    Write-QuickTestJson -Path $statePath -InputObject $state
    $stoppedCount = 0
    try {
        foreach ($container in $registeredContainers) {
            $containerId = [string] $container.ContainerId
            Invoke-QuickTestExternalCommand `
                -FilePath $runtimeInfo.Command `
                -Arguments @(
                    'container'
                    'stop'
                    '--time'
                    [string] $TimeoutSeconds
                    $containerId
                ) |
                Out-Null
            $runtimeStatus = [string] (
                Invoke-QuickTestExternalCommand `
                    -FilePath $runtimeInfo.Command `
                    -Arguments @(
                        'container'
                        'inspect'
                        '--format'
                        '{{.State.Status}}'
                        $containerId
                    ) |
                    Select-Object -First 1
            )
            if ($runtimeStatus -notin @('exited', 'stopped')) {
                throw "SQL Server $($container.SqlVersion) did not reach a stopped state."
            }
            $stoppedCount++
        }
        $state.LifecycleStatus = 'STOPPED'
        Write-QuickTestJson -Path $statePath -InputObject $state
    }
    catch {
        $state.LifecycleStatus = 'STOP_FAILED'
        Write-QuickTestJson -Path $statePath -InputObject $state
        throw
    }

    return [pscustomobject] @{
        Status = 'STOPPED'
        ScopeName = $ScopeName
        AlreadyStopped = $false
        ContainersStopped = $stoppedCount
        NetworkPreserved = $true
        DataPreserved = $true
        StatePreserved = $true
    }
}
