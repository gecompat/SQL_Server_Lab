Set-StrictMode -Version Latest

function Invoke-QuickTestLabDown {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
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
        }
    }

    $state = Read-QuickTestJson -Path $statePath
    if (
        [IO.Path]::GetFullPath([string] $state.StateBaseRoot) -ne $expectedStateRoot -or
        [IO.Path]::GetFullPath([string] $state.StateDirectory) -ne $scopeStateDirectory
    ) {
        throw 'Down refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'Down refused an unowned or out-of-bound state directory.'
    }

    if ([string] $state.LifecycleStatus -eq 'DOWN') {
        $runtimeInfo = Resolve-QuickTestRuntime -Runtime $state.Runtime
        if ($runtimeInfo.IsAvailable) {
            $remaining = Get-QuickTestResourcesByRunId `
                -RuntimeInfo $runtimeInfo `
                -RunId $state.RunId
            if (
                @($remaining.ContainerIds).Count -gt 0 -or
                @($remaining.NetworkIds).Count -gt 0
            ) {
                throw 'Down state still has run-labeled runtime resources.'
            }
        }
        return [pscustomobject] @{
            Status = 'DOWN'
            ScopeName = $ScopeName
            AlreadyDown = $true
            DataPreserved = $true
            StatePreserved = $true
            CredentialPreserved = -not [string]::IsNullOrWhiteSpace(
                [string] $state.CredentialDirectory
            )
            ContainersRemoved = 0
            NetworksRemoved = 0
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

    $registeredContainerIds = @(
        $state.Containers |
            ForEach-Object { [string] $_.ContainerId }
    )
    foreach ($containerId in $registeredContainerIds) {
        if ($containerId -notmatch '^[a-f0-9]{64}$') {
            throw 'State contains a non-canonical container ID.'
        }
    }
    $registeredNetworkIds = @()
    if (-not [string]::IsNullOrWhiteSpace([string] $state.NetworkId)) {
        if ([string] $state.NetworkId -notmatch '^[a-f0-9]{64}$') {
            throw 'State contains a non-canonical network ID.'
        }
        $registeredNetworkIds = @([string] $state.NetworkId)
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
    if ($unexpectedContainers.Count -gt 0 -or $unexpectedNetworks.Count -gt 0) {
        throw 'Down found run-labeled resources that are not registered in state.'
    }

    $existingContainerIds = @(
        $registeredContainerIds |
            Where-Object { $_ -in $discovered.ContainerIds }
    )
    $existingNetworkIds = @(
        $registeredNetworkIds |
            Where-Object { $_ -in $discovered.NetworkIds }
    )

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Remove registered containers and network while preserving local state and data'
        )) {
        return [pscustomobject] @{
            Status = 'DOWN_CONFIRMATION_REQUIRED'
            ScopeName = $ScopeName
        }
    }

    $state.LifecycleStatus = 'DOWN_IN_PROGRESS'
    $state.RecoveryContainerIds = $registeredContainerIds
    $state.RecoveryNetworkIds = $registeredNetworkIds
    Write-QuickTestJson -Path $statePath -InputObject $state

    if ($existingContainerIds.Count -gt 0 -or $existingNetworkIds.Count -gt 0) {
        Remove-QuickTestRuntimeResources `
            -RuntimeInfo $runtimeInfo `
            -RunId $state.RunId `
            -ContainerIds $existingContainerIds `
            -NetworkIds $existingNetworkIds
    }

    $updatedContainers = @(
        foreach ($container in @($state.Containers)) {
            $entry = [ordered] @{}
            foreach ($property in $container.PSObject.Properties) {
                $entry[$property.Name] = $property.Value
            }
            $entry['PreviousContainerId'] = [string] $container.ContainerId
            $entry['ContainerId'] = ''
            [pscustomobject] $entry
        }
    )
    $state | Add-Member `
        -NotePropertyName PreviousNetworkId `
        -NotePropertyValue ([string] $state.NetworkId) `
        -Force
    $state.Containers = $updatedContainers
    $state.NetworkId = ''
    $state.RecoveryContainerIds = @()
    $state.RecoveryNetworkIds = @()
    $state.LifecycleStatus = 'DOWN'
    Write-QuickTestJson -Path $statePath -InputObject $state

    return [pscustomobject] @{
        Status = 'DOWN'
        ScopeName = $ScopeName
        AlreadyDown = $false
        DataPreserved = $true
        StatePreserved = $true
        CredentialPreserved = -not [string]::IsNullOrWhiteSpace(
            [string] $state.CredentialDirectory
        )
        ContainersRemoved = $existingContainerIds.Count
        NetworksRemoved = $existingNetworkIds.Count
    }
}
