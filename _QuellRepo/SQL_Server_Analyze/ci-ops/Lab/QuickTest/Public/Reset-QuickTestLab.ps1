Set-StrictMode -Version Latest

function Reset-QuickTestLab {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
        [string] $ScopeName = 'sql-analyze-quicktest',

        [Parameter()]
        [string] $StateRoot = (Join-Path $script:QuickTestLabRoot '.state/quick-test'),

        [Parameter()]
        [securestring] $AdminSecret,

        [Parameter()]
        [switch] $SkipImageAvailabilityCheck
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
            MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
        }
    }

    $state = Read-QuickTestJson -Path $statePath
    if (
        [IO.Path]::GetFullPath([string] $state.StateBaseRoot) -ne $expectedStateRoot -or
        [IO.Path]::GetFullPath([string] $state.StateDirectory) -ne $scopeStateDirectory
    ) {
        throw 'Reset refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'Reset refused an unowned or out-of-bound state directory.'
    }

    if ([string] $state.PersistenceMode -ne 'TEMPORARY') {
        return [pscustomobject] @{
            Status = 'RESET_PERSISTENT_SCOPE_BLOCKED'
            ScopeName = $ScopeName
            PersistenceMode = [string] $state.PersistenceMode
            MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
        }
    }

    $allowedLifecycleStates = @('READY', 'STOPPED', 'DOWN')
    if ([string] $state.LifecycleStatus -notin $allowedLifecycleStates) {
        return [pscustomobject] @{
            Status = 'RESET_STATE_INVALID'
            ScopeName = $ScopeName
            LifecycleStatus = [string] $state.LifecycleStatus
            MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
        }
    }

    $runtimeInfo = Resolve-QuickTestRuntime -Runtime $state.Runtime
    if (-not $runtimeInfo.IsAvailable) {
        return [pscustomobject] @{
            Status = 'RUNTIME_UNAVAILABLE'
            ScopeName = $ScopeName
            Runtime = $state.Runtime
            MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
        }
    }

    $versions = @(
        $state.SqlVersions |
            ForEach-Object { [int] $_ } |
            Sort-Object -Unique
    )
    if ($versions.Count -eq 0) {
        throw 'Reset found no SQL Server versions in state.'
    }
    foreach ($version in $versions) {
        if ($version -notin @(2019, 2022, 2025)) {
            throw 'Reset found an unsupported SQL Server version in state.'
        }
    }

    $ports = @{}
    foreach ($container in @($state.Containers)) {
        $version = [int] $container.SqlVersion
        if ($version -notin $versions) {
            throw 'Reset found inconsistent container-version state.'
        }
        if ($ports.ContainsKey($version)) {
            throw 'Reset found duplicate SQL Server version state.'
        }
        $ports[$version] = [int] $container.Port
    }
    if ($ports.Count -ne $versions.Count) {
        throw 'Reset found incomplete port state.'
    }
    Resolve-QuickTestPorts -SqlVersions $versions -Ports $ports | Out-Null
    Get-QuickTestResourceProfile -Name ([string] $state.ResourceProfile) | Out-Null

    $dataBaseRoot = [IO.Path]::GetFullPath([string] $state.DataBaseRoot)
    $dataRoot = [IO.Path]::GetFullPath([string] $state.DataRoot)
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $dataRoot `
            -Root $dataBaseRoot `
            -RunId $state.RunId)) {
        throw 'Reset refused an unowned or out-of-bound data directory.'
    }

    $credentialBaseRoot = [IO.Path]::GetFullPath(
        [string] $state.CredentialBaseRoot
    )
    $effectiveSecret = $AdminSecret
    $loadedStoredCredential = $false
    $plainStoredCredential = $null
    if ($null -eq $effectiveSecret) {
        if (
            [bool] $state.GeneratedCredentialStored -and
            -not [string]::IsNullOrWhiteSpace([string] $state.CredentialDirectory)
        ) {
            $credentialDirectory = [IO.Path]::GetFullPath(
                [string] $state.CredentialDirectory
            )
            if (-not (Test-QuickTestOwnedDirectory `
                    -Path $credentialDirectory `
                    -Root $credentialBaseRoot `
                    -RunId $state.RunId)) {
                throw 'Reset refused an unowned or out-of-bound credential directory.'
            }
            $credentialPath = Join-Path $credentialDirectory 'sql-admin.credential'
            if (-not (Test-Path -LiteralPath $credentialPath -PathType Leaf)) {
                throw 'The stored quick-test credential file is missing.'
            }
            $plainStoredCredential = [IO.File]::ReadAllText(
                $credentialPath,
                [Text.Encoding]::UTF8
            )
            if ([string]::IsNullOrWhiteSpace($plainStoredCredential)) {
                throw 'The stored quick-test credential is empty.'
            }
            $effectiveSecret = ConvertTo-QuickTestSecureString `
                -Value $plainStoredCredential
            $plainStoredCredential = $null
            $loadedStoredCredential = $true
        }
        else {
            return [pscustomobject] @{
                Status = 'RESET_CREDENTIAL_REQUIRED'
                ScopeName = $ScopeName
                MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
            }
        }
    }
    if (-not (Test-QuickTestPassword -SecureValue $effectiveSecret)) {
        throw 'The SQL Server credential does not satisfy the quick-test complexity contract.'
    }

    $registeredContainerIds = @(
        foreach ($container in @($state.Containers)) {
            $containerId = [string] $container.ContainerId
            if ([string]::IsNullOrWhiteSpace($containerId)) {
                if ([string] $state.LifecycleStatus -ne 'DOWN') {
                    throw 'Reset found an empty container ID outside DOWN state.'
                }
                continue
            }
            if ($containerId -notmatch '^[a-f0-9]{64}$') {
                throw 'Reset found a non-canonical container ID.'
            }
            $containerId
        }
    )
    $registeredNetworkIds = @()
    if (-not [string]::IsNullOrWhiteSpace([string] $state.NetworkId)) {
        if ([string] $state.NetworkId -notmatch '^[a-f0-9]{64}$') {
            throw 'Reset found a non-canonical network ID.'
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
        return [pscustomobject] @{
            Status = 'RESET_SCOPE_CONFLICT'
            ScopeName = $ScopeName
            MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
        }
    }
    if (
        @($discovered.ContainerIds).Count -ne $registeredContainerIds.Count -or
        @($discovered.NetworkIds).Count -ne $registeredNetworkIds.Count
    ) {
        return [pscustomobject] @{
            Status = 'RESET_SCOPE_INCOMPLETE'
            ScopeName = $ScopeName
            MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "temporary quick-test scope $ScopeName",
            'Delete the complete current scope and install a fresh synthetic scope'
        )) {
        return [pscustomobject] @{
            Status = 'RESET_CONFIRMATION_REQUIRED'
            ScopeName = $ScopeName
            MutationBoundary = 'READ_ONLY_RESET_PREFLIGHT'
        }
    }

    $oldRunId = [string] $state.RunId
    $installFramework = [bool] $state.InstallFramework
    $persistCredential = [bool] $state.GeneratedCredentialStored
    $adminLogin = [string] $state.AdminLogin
    $resourceProfile = [string] $state.ResourceProfile
    $runtime = [string] $state.Runtime

    try {
        $destroyResult = Remove-QuickTestLab `
            -ScopeName $ScopeName `
            -StateRoot $expectedStateRoot `
            -Confirm:$false
        if ($destroyResult.Status -ne 'DESTROYED') {
            throw "Reset Destroy phase returned $($destroyResult.Status)."
        }

        $installResult = Install-QuickTestLab `
            -Runtime $runtime `
            -SqlVersions $versions `
            -Ports $ports `
            -AdminSecret $effectiveSecret `
            -AdminLogin $adminLogin `
            -ResourceProfile $resourceProfile `
            -PersistenceMode TEMPORARY `
            -ScopeName $ScopeName `
            -InstallFramework:$installFramework `
            -PersistGeneratedCredential:$persistCredential `
            -AcceptEula `
            -StateRoot $expectedStateRoot `
            -DataRoot $dataBaseRoot `
            -CredentialRoot $credentialBaseRoot `
            -SkipImageAvailabilityCheck:$SkipImageAvailabilityCheck `
            -Confirm:$false
        if ($installResult.Status -ne 'READY') {
            return [pscustomobject] @{
                Status = 'RESET_INSTALL_FAILED'
                ScopeName = $ScopeName
                PreviousRunId = $oldRunId
                InstallStatus = [string] $installResult.Status
                LoadedStoredCredential = $loadedStoredCredential
            }
        }

        $newState = Read-QuickTestJson -Path $statePath
        if ([string] $newState.RunId -eq $oldRunId) {
            throw 'Reset did not create a new run ID.'
        }
        return [pscustomobject] @{
            Status = 'READY'
            ScopeName = $ScopeName
            PreviousRunId = $oldRunId
            RunId = [string] $newState.RunId
            ResetPerformed = $true
            DataRecreated = $true
            LoadedStoredCredential = $loadedStoredCredential
            Connections = $installResult.Connections
        }
    }
    finally {
        $plainStoredCredential = $null
    }
}
