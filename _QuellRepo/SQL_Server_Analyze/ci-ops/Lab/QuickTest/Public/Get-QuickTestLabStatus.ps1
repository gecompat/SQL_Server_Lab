Set-StrictMode -Version Latest

function Get-QuickTestLabStatus {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
        [string] $ScopeName = 'sql-analyze-quicktest',

        [Parameter()]
        [string] $StateRoot = (Join-Path $script:QuickTestLabRoot '.state/quick-test')
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
            Instances = @()
        }
    }

    $state = Read-QuickTestJson -Path $statePath
    if (
        [IO.Path]::GetFullPath([string] $state.StateBaseRoot) -ne $expectedStateRoot -or
        [IO.Path]::GetFullPath([string] $state.StateDirectory) -ne $scopeStateDirectory
    ) {
        throw 'Status refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'Status refused an unowned or out-of-bound state directory.'
    }

    if ([string] $state.LifecycleStatus -eq 'DOWN') {
        $downInstances = @(
            foreach ($container in @($state.Containers)) {
                $previousContainerId = ''
                if ($container.PSObject.Properties.Name -contains 'PreviousContainerId') {
                    $previousContainerId = [string] $container.PreviousContainerId
                }
                [pscustomobject] @{
                    SqlVersion = [int] $container.SqlVersion
                    ContainerId = ''
                    PreviousContainerId = $previousContainerId
                    ContainerName = [string] $container.ContainerName
                    Port = [int] $container.Port
                    RuntimeStatus = 'removed'
                    HealthStatus = ''
                    OwnershipValid = $null
                    Ready = $false
                    Stopped = $false
                }
            }
        )
        return [pscustomobject] @{
            Status = 'DOWN'
            ScopeName = $ScopeName
            Runtime = $state.Runtime
            LifecycleStatus = $state.LifecycleStatus
            AdminLogin = $state.AdminLogin
            FrameworkDatabase = $state.FrameworkDatabase
            PersistenceMode = $state.PersistenceMode
            DataPreserved = $true
            StatePreserved = $true
            CredentialPreserved = -not [string]::IsNullOrWhiteSpace(
                [string] $state.CredentialDirectory
            )
            Instances = $downInstances
        }
    }

    $runtimeInfo = Resolve-QuickTestRuntime -Runtime $state.Runtime
    if (-not $runtimeInfo.IsAvailable) {
        return [pscustomobject] @{
            Status = 'RUNTIME_UNAVAILABLE'
            ScopeName = $ScopeName
            Runtime = $state.Runtime
            LifecycleStatus = $state.LifecycleStatus
            Instances = @()
        }
    }

    $instances = [Collections.Generic.List[object]]::new()
    foreach ($container in $state.Containers) {
        $containerId = [string] $container.ContainerId
        if ($containerId -notmatch '^[a-f0-9]{64}$') {
            throw 'Status found a non-canonical container ID in state.'
        }
        $runtimeState = 'missing|missing'
        $runOwnerValid = $false
        $frameworkOwnerValid = $false
        try {
            $runtimeState = [string] (
                Invoke-QuickTestExternalCommand `
                    -FilePath $runtimeInfo.Command `
                    -Arguments @(
                        'container'
                        'inspect'
                        '--format'
                        '{{.State.Status}}|{{.State.Health.Status}}'
                        $containerId
                    ) |
                    Select-Object -First 1
            )
            $runOwnerValid = (
                Get-QuickTestObjectLabel `
                    -RuntimeInfo $runtimeInfo `
                    -ResourceType CONTAINER `
                    -ExactLocator $containerId `
                    -LabelName 'qt-lab.run-id'
            ) -eq $state.RunId
            $frameworkOwnerValid = (
                Get-QuickTestObjectLabel `
                    -RuntimeInfo $runtimeInfo `
                    -ResourceType CONTAINER `
                    -ExactLocator $containerId `
                    -LabelName 'qt-lab.owner'
            ) -eq 'SQL_SERVER_ANALYZE'
        }
        catch {
            $runtimeState = 'missing|missing'
        }
        $parts = $runtimeState.Split('|')
        $runtimeStatus = $parts[0]
        $healthStatus = if ($parts.Count -gt 1) { $parts[1] } else { '' }
        $ownershipValid = $runOwnerValid -and $frameworkOwnerValid
        $ready = (
            $runtimeStatus -eq 'running' -and
            $healthStatus -eq 'healthy' -and
            $ownershipValid
        )
        $stopped = (
            $runtimeStatus -in @('exited', 'stopped') -and
            $ownershipValid
        )
        $instances.Add([pscustomobject] @{
                SqlVersion = [int] $container.SqlVersion
                ContainerId = $containerId
                ContainerName = [string] $container.ContainerName
                Port = [int] $container.Port
                RuntimeStatus = $runtimeStatus
                HealthStatus = $healthStatus
                OwnershipValid = $ownershipValid
                Ready = $ready
                Stopped = $stopped
            })
    }

    $readyCount = @($instances | Where-Object { $_.Ready }).Count
    $stoppedCount = @($instances | Where-Object { $_.Stopped }).Count
    $overallStatus = if (
        $state.LifecycleStatus -eq 'READY' -and
        $instances.Count -gt 0 -and
        $readyCount -eq $instances.Count
    ) {
        'READY'
    }
    elseif (
        $state.LifecycleStatus -eq 'STOPPED' -and
        $instances.Count -gt 0 -and
        $stoppedCount -eq $instances.Count
    ) {
        'STOPPED'
    }
    else {
        'PARTIAL_SUCCESS'
    }

    return [pscustomobject] @{
        Status = $overallStatus
        ScopeName = $ScopeName
        Runtime = $state.Runtime
        LifecycleStatus = $state.LifecycleStatus
        AdminLogin = $state.AdminLogin
        FrameworkDatabase = $state.FrameworkDatabase
        PersistenceMode = $state.PersistenceMode
        DataPreserved = $true
        StatePreserved = $true
        NetworkPreserved = ($state.LifecycleStatus -eq 'STOPPED')
        Instances = $instances.ToArray()
    }
}
