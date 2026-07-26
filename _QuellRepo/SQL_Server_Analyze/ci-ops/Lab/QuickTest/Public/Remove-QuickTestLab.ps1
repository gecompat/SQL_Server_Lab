Set-StrictMode -Version Latest

function Remove-QuickTestLab {
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
        throw 'Destroy refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'Destroy refused an unowned or out-of-bound state directory.'
    }

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Destroy registered containers, network, state, credentials, and local data'
        )) {
        return [pscustomobject] @{
            Status = 'DESTROY_CONFIRMATION_REQUIRED'
            ScopeName = $ScopeName
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

    $registeredContainerIds = [Collections.Generic.List[string]]::new()
    foreach ($container in @($state.Containers)) {
        $containerId = [string] $container.ContainerId
        if ([string]::IsNullOrWhiteSpace($containerId)) {
            if ([string] $state.LifecycleStatus -ne 'DOWN') {
                throw 'State contains an empty container ID outside the DOWN lifecycle state.'
            }
            continue
        }
        if ($containerId -notmatch '^[a-f0-9]{64}$') {
            throw 'State contains a non-canonical container ID.'
        }
        $registeredContainerIds.Add($containerId)
    }

    $registeredNetworkIds = [Collections.Generic.List[string]]::new()
    if (-not [string]::IsNullOrWhiteSpace([string] $state.NetworkId)) {
        if ([string] $state.NetworkId -notmatch '^[a-f0-9]{64}$') {
            throw 'State contains a non-canonical network ID.'
        }
        $registeredNetworkIds.Add([string] $state.NetworkId)
    }

    $discovered = Get-QuickTestResourcesByRunId `
        -RuntimeInfo $runtimeInfo `
        -RunId $state.RunId
    $unexpectedContainers = @(
        $discovered.ContainerIds |
            Where-Object { $_ -notin $registeredContainerIds.ToArray() }
    )
    $unexpectedNetworks = @(
        $discovered.NetworkIds |
            Where-Object { $_ -notin $registeredNetworkIds.ToArray() }
    )
    if ($unexpectedContainers.Count -gt 0 -or $unexpectedNetworks.Count -gt 0) {
        throw 'Destroy found run-labeled resources that are not registered in state.'
    }

    $existingContainerIds = @(
        $registeredContainerIds.ToArray() |
            Where-Object { $_ -in $discovered.ContainerIds }
    )
    $existingNetworkIds = @(
        $registeredNetworkIds.ToArray() |
            Where-Object { $_ -in $discovered.NetworkIds }
    )
    if ($existingContainerIds.Count -gt 0 -or $existingNetworkIds.Count -gt 0) {
        Remove-QuickTestRuntimeResources `
            -RuntimeInfo $runtimeInfo `
            -RunId $state.RunId `
            -ContainerIds $existingContainerIds `
            -NetworkIds $existingNetworkIds
    }

    if (Test-Path -LiteralPath $state.DataRoot) {
        if (-not (Test-QuickTestOwnedDirectory `
                -Path $state.DataRoot `
                -Root $state.DataBaseRoot `
                -RunId $state.RunId)) {
            throw 'Data cleanup refused an unowned or out-of-bound directory.'
        }
        Remove-Item -LiteralPath $state.DataRoot -Recurse -Force
    }

    if (
        $state.CredentialDirectory -and
        (Test-Path -LiteralPath $state.CredentialDirectory)
    ) {
        if (-not (Test-QuickTestOwnedDirectory `
                -Path $state.CredentialDirectory `
                -Root $state.CredentialBaseRoot `
                -RunId $state.RunId)) {
            throw 'Credential cleanup refused an unowned or out-of-bound directory.'
        }
        Remove-Item `
            -LiteralPath $state.CredentialDirectory `
            -Recurse `
            -Force
    }

    Remove-Item -LiteralPath $scopeStateDirectory -Recurse -Force

    return [pscustomobject] @{
        Status = 'DESTROYED'
        ScopeName = $ScopeName
        DataRemoved = $true
        ContainersRemoved = $existingContainerIds.Count
        NetworksRemoved = $existingNetworkIds.Count
    }
}
