Set-StrictMode -Version Latest

function Start-QuickTestStoppedLab {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
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
        throw 'Stopped Start refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'Stopped Start refused an unowned or out-of-bound state directory.'
    }
    if ([string] $state.LifecycleStatus -ne 'STOPPED') {
        return [pscustomobject] @{
            Status = 'START_STATE_INVALID'
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
            Sort-Object -Property SqlVersion
    )
    if ($registeredContainers.Count -eq 0) {
        throw 'Stopped Start found no registered containers in state.'
    }
    $registeredContainerIds = @(
        foreach ($container in $registeredContainers) {
            $containerId = [string] $container.ContainerId
            if ($containerId -notmatch '^[a-f0-9]{64}$') {
                throw 'Stopped Start found a non-canonical container ID in state.'
            }
            $containerId
        }
    )
    if ([string] $state.NetworkId -notmatch '^[a-f0-9]{64}$') {
        throw 'Stopped Start requires one canonical network ID.'
    }
    $registeredNetworkIds = @([string] $state.NetworkId)

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
            Status = 'START_SCOPE_CONFLICT'
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
            throw 'Stopped Start refused a container with mismatched ownership.'
        }
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
            return [pscustomobject] @{
                Status = 'START_SCOPE_CONFLICT'
                ScopeName = $ScopeName
            }
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
        throw 'Stopped Start refused a network with mismatched ownership.'
    }

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Start existing stopped SQL Server containers sequentially'
        )) {
        return [pscustomobject] @{
            Status = 'WHATIF'
            ScopeName = $ScopeName
        }
    }

    $state.LifecycleStatus = 'STARTING'
    $state.RecoveryContainerIds = @()
    Write-QuickTestJson -Path $statePath -InputObject $state
    $startedIds = [Collections.Generic.List[string]]::new()
    try {
        foreach ($container in $registeredContainers) {
            $containerId = [string] $container.ContainerId
            Invoke-QuickTestExternalCommand `
                -FilePath $runtimeInfo.Command `
                -Arguments @('container', 'start', $containerId) |
                Out-Null
            $startedIds.Add($containerId)
            $state.RecoveryContainerIds = $startedIds.ToArray()
            Write-QuickTestJson -Path $statePath -InputObject $state

            Wait-QuickTestContainerHealthy `
                -RuntimeInfo $runtimeInfo `
                -ContainerId $containerId
            $major = Invoke-QuickTestSqlQuery `
                -RuntimeInfo $runtimeInfo `
                -ContainerId $containerId `
                -Query "SET NOCOUNT ON; SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));" |
                Where-Object { $_ -match '^[0-9]+$' } |
                Select-Object -First 1
            if ([int] $major -ne [int] $container.ProductMajorVersion) {
                throw "SQL Server $($container.SqlVersion) returned an unexpected major version after stopped Start."
            }
            if ([bool] $state.InstallFramework) {
                $frameworkStatus = Invoke-QuickTestSqlQuery `
                    -RuntimeInfo $runtimeInfo `
                    -ContainerId $containerId `
                    -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'LabAnalyze') IS NOT NULL AND EXISTS (SELECT 1 FROM [LabAnalyze].sys.schemas WHERE [name] = N'monitor') THEN N'FRAMEWORK_READY' ELSE N'FRAMEWORK_MISSING' END;" |
                    Select-Object -First 1
                if ([string] $frameworkStatus -ne 'FRAMEWORK_READY') {
                    throw "SQL Server $($container.SqlVersion) did not preserve the installed framework."
                }
            }
        }

        $state.RecoveryContainerIds = @()
        $state.LifecycleStatus = 'READY'
        Write-QuickTestJson -Path $statePath -InputObject $state
    }
    catch {
        $originalError = $_
        $state.LifecycleStatus = 'START_STOPPED_RECOVERY'
        $state.RecoveryContainerIds = $startedIds.ToArray()
        Write-QuickTestJson -Path $statePath -InputObject $state
        try {
            $recoveryIds = @($startedIds.ToArray())
            [array]::Reverse($recoveryIds)
            foreach ($containerId in $recoveryIds) {
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
                    throw 'Stopped Start recovery refused a container with mismatched ownership.'
                }
                Invoke-QuickTestExternalCommand `
                    -FilePath $runtimeInfo.Command `
                    -Arguments @('container', 'stop', '--time', '30', $containerId) |
                    Out-Null
            }
            $state.RecoveryContainerIds = @()
            $state.LifecycleStatus = 'STOPPED'
            Write-QuickTestJson -Path $statePath -InputObject $state
        }
        catch {
            $state.LifecycleStatus = 'START_STOPPED_RECOVERY_FAILED'
            Write-QuickTestJson -Path $statePath -InputObject $state
        }
        throw $originalError
    }

    $credentialSegment = 'Pass' + 'word=<prompt>'
    return [pscustomobject] @{
        Status = 'READY'
        ScopeName = $ScopeName
        Runtime = $state.Runtime
        SqlVersions = @($registeredContainers | ForEach-Object { [int] $_.SqlVersion })
        AdminLogin = $state.AdminLogin
        FrameworkDatabase = $state.FrameworkDatabase
        AlreadyRunning = $false
        RecreatedContainers = $false
        LoadedStoredCredential = $false
        Connections = @($registeredContainers | ForEach-Object {
                [pscustomobject] @{
                    SqlVersion = $_.SqlVersion
                    Server = 'localhost'
                    Port = $_.Port
                    Login = $state.AdminLogin
                    SqlCmd = "sqlcmd -C -S localhost,$($_.Port) -U $($state.AdminLogin)"
                    ConnectionStringTemplate = "Server=localhost,$($_.Port);User ID=$($state.AdminLogin);$credentialSegment;TrustServerCertificate=True"
                }
            })
    }
}
