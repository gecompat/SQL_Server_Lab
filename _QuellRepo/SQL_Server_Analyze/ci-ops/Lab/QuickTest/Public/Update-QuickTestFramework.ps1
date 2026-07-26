Set-StrictMode -Version Latest

function Update-QuickTestFramework {
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
            Instances = @()
        }
    }

    $state = Read-QuickTestJson -Path $statePath
    if (
        [IO.Path]::GetFullPath([string] $state.StateBaseRoot) -ne $expectedStateRoot -or
        [IO.Path]::GetFullPath([string] $state.StateDirectory) -ne $scopeStateDirectory
    ) {
        throw 'UpdateFramework refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'UpdateFramework refused an unowned or out-of-bound state directory.'
    }
    if ([string] $state.LifecycleStatus -ne 'READY') {
        return [pscustomobject] @{
            Status = 'FRAMEWORK_STATE_INVALID'
            ScopeName = $ScopeName
            LifecycleStatus = [string] $state.LifecycleStatus
            Instances = @()
        }
    }

    $currentStatus = Get-QuickTestLabStatus `
        -ScopeName $ScopeName `
        -StateRoot $expectedStateRoot
    if ($currentStatus.Status -ne 'READY') {
        return [pscustomobject] @{
            Status = 'FRAMEWORK_SCOPE_NOT_READY'
            ScopeName = $ScopeName
            LifecycleStatus = [string] $state.LifecycleStatus
            Instances = @($currentStatus.Instances)
        }
    }

    $runtimeInfo = Resolve-QuickTestRuntime -Runtime $state.Runtime
    if (-not $runtimeInfo.IsAvailable) {
        return [pscustomobject] @{
            Status = 'RUNTIME_UNAVAILABLE'
            ScopeName = $ScopeName
            Runtime = [string] $state.Runtime
            Instances = @()
        }
    }

    $containers = @(
        $state.Containers |
            Sort-Object -Property SqlVersion
    )
    if ($containers.Count -eq 0) {
        throw 'UpdateFramework found no registered containers.'
    }
    $registeredContainerIds = @()
    foreach ($container in $containers) {
        $containerId = [string] $container.ContainerId
        if ($containerId -notmatch '^[a-f0-9]{64}$') {
            throw 'UpdateFramework found a non-canonical container ID.'
        }
        $expectedMajor = [int] $container.ProductMajorVersion
        if ($expectedMajor -notin @(15, 16, 17)) {
            throw 'UpdateFramework found an unsupported SQL Server major version.'
        }
        $registeredContainerIds += $containerId
    }

    $registeredNetworkIds = @()
    if (-not [string]::IsNullOrWhiteSpace([string] $state.NetworkId)) {
        if ([string] $state.NetworkId -notmatch '^[a-f0-9]{64}$') {
            throw 'UpdateFramework found a non-canonical network ID.'
        }
        $registeredNetworkIds = @([string] $state.NetworkId)
    }
    if ($registeredNetworkIds.Count -ne 1) {
        throw 'UpdateFramework requires exactly one registered network.'
    }

    $discovered = Get-QuickTestResourcesByRunId `
        -RuntimeInfo $runtimeInfo `
        -RunId $state.RunId
    if (
        @($discovered.ContainerIds).Count -ne $registeredContainerIds.Count -or
        @($discovered.NetworkIds).Count -ne $registeredNetworkIds.Count -or
        @($discovered.ContainerIds | Where-Object { $_ -notin $registeredContainerIds }).Count -gt 0 -or
        @($discovered.NetworkIds | Where-Object { $_ -notin $registeredNetworkIds }).Count -gt 0
    ) {
        return [pscustomobject] @{
            Status = 'FRAMEWORK_SCOPE_CONFLICT'
            ScopeName = $ScopeName
            Instances = @()
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
            return [pscustomobject] @{
                Status = 'FRAMEWORK_OWNERSHIP_MISMATCH'
                ScopeName = $ScopeName
                Instances = @()
            }
        }
    }
    $networkRunOwner = Get-QuickTestObjectLabel `
        -RuntimeInfo $runtimeInfo `
        -ResourceType NETWORK `
        -ExactLocator $registeredNetworkIds[0] `
        -LabelName 'qt-lab.run-id'
    $networkFrameworkOwner = Get-QuickTestObjectLabel `
        -RuntimeInfo $runtimeInfo `
        -ResourceType NETWORK `
        -ExactLocator $registeredNetworkIds[0] `
        -LabelName 'qt-lab.owner'
    if (
        $networkRunOwner -ne $state.RunId -or
        $networkFrameworkOwner -ne 'SQL_SERVER_ANALYZE'
    ) {
        return [pscustomobject] @{
            Status = 'FRAMEWORK_OWNERSHIP_MISMATCH'
            ScopeName = $ScopeName
            Instances = @()
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Install or update the framework sequentially on all registered SQL Server containers'
        )) {
        return [pscustomobject] @{
            Status = 'WHATIF'
            ScopeName = $ScopeName
            Instances = @()
        }
    }

    $diagnosticModulePath = Join-Path (
        $script:QuickTestLabRoot
    ) 'Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
    Import-Module `
        -Name $diagnosticModulePath `
        -Force `
        -ErrorAction Stop

    $state | Add-Member `
        -NotePropertyName FrameworkUpdateStatus `
        -NotePropertyValue 'IN_PROGRESS' `
        -Force
    $state | Add-Member `
        -NotePropertyName FrameworkInstances `
        -NotePropertyValue @() `
        -Force
    $state.LifecycleStatus = 'FRAMEWORK_UPDATING'
    Write-QuickTestJson -Path $statePath -InputObject $state

    $instanceResults = [Collections.Generic.List[object]]::new()
    foreach ($container in $containers) {
        $containerId = [string] $container.ContainerId
        $version = [int] $container.SqlVersion
        try {
            $major = Invoke-QuickTestSqlQuery `
                -RuntimeInfo $runtimeInfo `
                -ContainerId $containerId `
                -Query "SET NOCOUNT ON; SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));" |
                Where-Object { $_ -match '^[0-9]+$' } |
                Select-Object -First 1
            if ([int] $major -ne [int] $container.ProductMajorVersion) {
                throw 'The SQL Server major version does not match the registered state.'
            }

            $frameworkResult = Install-LabContainerFramework `
                -Runtime ([string] $state.Runtime) `
                -RuntimeCommand $runtimeInfo.Command `
                -ContainerId $containerId `
                -RunDirectory $scopeStateDirectory
            $instanceResults.Add([pscustomobject] @{
                    SqlVersion = $version
                    Status = [string] $frameworkResult.Status
                    VerificationStatus = [string] $frameworkResult.VerificationStatus
                    FrameworkDatabase = [string] $frameworkResult.FrameworkDatabase
                    ErrorMessage = ''
                })
        }
        catch {
            $instanceResults.Add([pscustomobject] @{
                    SqlVersion = $version
                    Status = 'FAILED'
                    VerificationStatus = 'FRAMEWORK_NOT_READY'
                    FrameworkDatabase = 'LabAnalyze'
                    ErrorMessage = [string] $_.Exception.Message
                })
        }
        $state.FrameworkInstances = $instanceResults.ToArray()
        Write-QuickTestJson -Path $statePath -InputObject $state
    }

    $failed = @(
        $instanceResults |
            Where-Object { $_.Status -eq 'FAILED' }
    )
    $state.LifecycleStatus = 'READY'
    if ($failed.Count -gt 0) {
        $state.FrameworkUpdateStatus = 'FAILED'
        Write-QuickTestJson -Path $statePath -InputObject $state
        return [pscustomobject] @{
            Status = 'FRAMEWORK_UPDATE_FAILED'
            ScopeName = $ScopeName
            SuccessfulCount = $instanceResults.Count - $failed.Count
            FailedCount = $failed.Count
            Instances = $instanceResults.ToArray()
        }
    }

    $actions = @($instanceResults | Select-Object -ExpandProperty Status -Unique)
    $overallAction = if ($actions.Count -eq 1) {
        [string] $actions[0]
    }
    else {
        'MIXED'
    }
    $state.InstallFramework = $true
    $state.FrameworkDatabase = 'LabAnalyze'
    $state.FrameworkUpdateStatus = 'READY'
    Write-QuickTestJson -Path $statePath -InputObject $state

    return [pscustomobject] @{
        Status = 'READY'
        ScopeName = $ScopeName
        FrameworkAction = $overallAction
        FrameworkDatabase = 'LabAnalyze'
        SuccessfulCount = $instanceResults.Count
        FailedCount = 0
        Instances = $instanceResults.ToArray()
    }
}
