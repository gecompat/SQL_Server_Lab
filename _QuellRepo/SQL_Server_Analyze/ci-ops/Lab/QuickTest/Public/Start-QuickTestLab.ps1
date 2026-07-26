Set-StrictMode -Version Latest

function Start-QuickTestLab {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
        [string] $ScopeName = 'sql-analyze-quicktest',

        [Parameter()]
        [string] $StateRoot = (Join-Path $script:QuickTestLabRoot '.state/quick-test'),

        [Parameter()]
        [securestring] $AdminSecret
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
        throw 'Start refused state paths that do not match the requested scope.'
    }
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $scopeStateDirectory `
            -Root $expectedStateRoot `
            -RunId $state.RunId)) {
        throw 'Start refused an unowned or out-of-bound state directory.'
    }

    if ([string] $state.LifecycleStatus -eq 'READY') {
        $currentStatus = Get-QuickTestLabStatus `
            -ScopeName $ScopeName `
            -StateRoot $expectedStateRoot
        if ($currentStatus.Status -ne 'READY') {
            throw 'Start found READY state without fully ready runtime objects.'
        }
        $currentStatus | Add-Member `
            -NotePropertyName AlreadyRunning `
            -NotePropertyValue $true `
            -PassThru
        return
    }
    if ([string] $state.LifecycleStatus -ne 'DOWN') {
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
    $existing = Get-QuickTestResourcesByRunId `
        -RuntimeInfo $runtimeInfo `
        -RunId $state.RunId
    if (
        @($existing.ContainerIds).Count -gt 0 -or
        @($existing.NetworkIds).Count -gt 0
    ) {
        return [pscustomobject] @{
            Status = 'START_SCOPE_CONFLICT'
            ScopeName = $ScopeName
        }
    }

    $dataRoot = [IO.Path]::GetFullPath([string] $state.DataRoot)
    $dataBaseRoot = [IO.Path]::GetFullPath([string] $state.DataBaseRoot)
    if (-not (Test-QuickTestOwnedDirectory `
            -Path $dataRoot `
            -Root $dataBaseRoot `
            -RunId $state.RunId)) {
        throw 'Start refused an unowned or out-of-bound data directory.'
    }

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
            $credentialBaseRoot = [IO.Path]::GetFullPath(
                [string] $state.CredentialBaseRoot
            )
            if (-not (Test-QuickTestOwnedDirectory `
                    -Path $credentialDirectory `
                    -Root $credentialBaseRoot `
                    -RunId $state.RunId)) {
                throw 'Start refused an unowned or out-of-bound credential directory.'
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
                Status = 'START_CREDENTIAL_REQUIRED'
                ScopeName = $ScopeName
            }
        }
    }
    if (-not (Test-QuickTestPassword -SecureValue $effectiveSecret)) {
        throw 'The SQL Server credential does not satisfy the quick-test complexity contract.'
    }

    $versions = @($state.SqlVersions | ForEach-Object { [int] $_ })
    if ($versions.Count -eq 0) {
        throw 'Start found no SQL Server versions in state.'
    }
    $profile = Get-QuickTestResourceProfile -Name ([string] $state.ResourceProfile)
    $runtimeDirectory = Join-Path $scopeStateDirectory 'runtime'
    if (-not (Test-Path -LiteralPath $runtimeDirectory -PathType Container)) {
        throw 'Start found no runtime directory in state scope.'
    }

    foreach ($container in @($state.Containers)) {
        if (-not [string]::IsNullOrWhiteSpace([string] $container.ContainerId)) {
            throw 'Start requires empty current container IDs in DOWN state.'
        }
        $version = [int] $container.SqlVersion
        if ($version -notin $versions) {
            throw 'Start found inconsistent container-version state.'
        }
        foreach ($leaf in @('data', 'log', 'backup')) {
            $path = Join-Path (Join-Path $dataRoot ([string] $version)) $leaf
            if (-not (Test-Path -LiteralPath $path -PathType Container)) {
                throw "Start found a missing SQL Server $version $leaf directory."
            }
        }
    }

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Recreate registered SQL Server containers and network from preserved state'
        )) {
        return [pscustomobject] @{
            Status = 'START_CONFIRMATION_REQUIRED'
            ScopeName = $ScopeName
        }
    }

    $environmentNames = [Collections.Generic.List[string]]::new()
    foreach ($name in @(
            'QTLAB_COMPOSE_PROJECT'
            'QTLAB_SCOPE'
            'QTLAB_RUN_ID'
            'QTLAB_RUNTIME_DIR'
            'QTLAB_SQL_MEMORY_MB'
            'QTLAB_MEMORY_LIMIT'
            'QTLAB_CPU_LIMIT'
            'MSSQL_SA_PASSWORD'
        )) {
        $environmentNames.Add($name)
    }
    foreach ($version in @(2019, 2022, 2025)) {
        foreach ($suffix in @(
                'IMAGE'
                'CONTAINER'
                'PORT'
                'DATA_DIR'
                'LOG_DIR'
                'BACKUP_DIR'
            )) {
            $environmentNames.Add("QTLAB_SQL${version}_$suffix")
        }
    }
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable(
            $name,
            [EnvironmentVariableTarget]::Process
        )
    }

    $plainValue = ConvertFrom-QuickTestSecureString -SecureValue $effectiveSecret
    $startedContainers = [Collections.Generic.List[object]]::new()
    $networkId = ''
    $state.LifecycleStatus = 'STARTING'
    $state.RecoveryContainerIds = @()
    $state.RecoveryNetworkIds = @()
    Write-QuickTestJson -Path $statePath -InputObject $state

    try {
        $baseEnvironment = @{
            QTLAB_COMPOSE_PROJECT = [string] $state.ProjectName
            QTLAB_SCOPE = $ScopeName
            QTLAB_RUN_ID = [string] $state.RunId
            QTLAB_RUNTIME_DIR = $runtimeDirectory
            QTLAB_SQL_MEMORY_MB = [string] $profile.SqlMemoryMiB
            QTLAB_MEMORY_LIMIT = "$($profile.ContainerMemoryMiB)m"
            QTLAB_CPU_LIMIT = $profile.CpuLimit.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            MSSQL_SA_PASSWORD = $plainValue
        }
        foreach ($name in $baseEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable(
                $name,
                [string] $baseEnvironment[$name],
                [EnvironmentVariableTarget]::Process
            )
        }

        foreach ($container in @($state.Containers)) {
            $version = [int] $container.SqlVersion
            $versionRoot = Join-Path $dataRoot ([string] $version)
            $values = @{
                IMAGE = [string] $container.ImageReference
                CONTAINER = [string] $container.ContainerName
                PORT = [string] $container.Port
                DATA_DIR = Join-Path $versionRoot 'data'
                LOG_DIR = Join-Path $versionRoot 'log'
                BACKUP_DIR = Join-Path $versionRoot 'backup'
            }
            if ([string]::IsNullOrWhiteSpace($values.IMAGE)) {
                throw "Start found no image reference for SQL Server $version."
            }
            foreach ($suffix in $values.Keys) {
                [Environment]::SetEnvironmentVariable(
                    "QTLAB_SQL${version}_$suffix",
                    [string] $values[$suffix],
                    [EnvironmentVariableTarget]::Process
                )
            }
        }

        foreach ($version in $versions) {
            $service = Get-QuickTestServiceName -SqlVersion $version
            Invoke-QuickTestCompose `
                -RuntimeInfo $runtimeInfo `
                -ProjectName ([string] $state.ProjectName) `
                -SqlVersions $versions `
                -Arguments @('up', '--detach', $service) |
                Out-Null

            $containerId = Get-QuickTestContainerId `
                -RuntimeInfo $runtimeInfo `
                -ProjectName ([string] $state.ProjectName) `
                -SqlVersions $versions `
                -SqlVersion $version
            $source = @(
                $state.Containers |
                    Where-Object { [int] $_.SqlVersion -eq $version }
            )
            if ($source.Count -ne 1) {
                throw "Start found an invalid state entry for SQL Server $version."
            }
            $entry = [ordered] @{}
            foreach ($property in $source[0].PSObject.Properties) {
                $entry[$property.Name] = $property.Value
            }
            $entry['ContainerId'] = $containerId
            $startedContainers.Add([pscustomobject] $entry)
            $state.Containers = $startedContainers.ToArray() + @(
                $state.Containers |
                    Where-Object { [int] $_.SqlVersion -notin @(
                        $startedContainers | ForEach-Object { [int] $_.SqlVersion }
                    ) }
            )

            if (-not $networkId) {
                $resources = Get-QuickTestResourcesByRunId `
                    -RuntimeInfo $runtimeInfo `
                    -RunId $state.RunId
                if (@($resources.NetworkIds).Count -ne 1) {
                    throw 'Start did not resolve exactly one owned network.'
                }
                $networkId = [string] @($resources.NetworkIds)[0]
                $state.NetworkId = $networkId
            }
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
            if ([int] $major -ne [int] $source[0].ProductMajorVersion) {
                throw "SQL Server $version returned an unexpected major version after Start."
            }

            if ([bool] $state.InstallFramework) {
                $frameworkStatus = Invoke-QuickTestSqlQuery `
                    -RuntimeInfo $runtimeInfo `
                    -ContainerId $containerId `
                    -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'LabAnalyze') IS NOT NULL AND EXISTS (SELECT 1 FROM [LabAnalyze].sys.schemas WHERE [name] = N'monitor') THEN N'FRAMEWORK_READY' ELSE N'FRAMEWORK_MISSING' END;" |
                    Select-Object -First 1
                if ([string] $frameworkStatus -ne 'FRAMEWORK_READY') {
                    throw "SQL Server $version did not preserve the installed framework."
                }
            }
        }

        $state.Containers = @(
            $startedContainers |
                Sort-Object -Property SqlVersion
        )
        $state.NetworkId = $networkId
        $state.RecoveryContainerIds = @()
        $state.RecoveryNetworkIds = @()
        $state.LifecycleStatus = 'READY'
        Write-QuickTestJson -Path $statePath -InputObject $state

        $credentialSegment = 'Pass' + 'word=<prompt>'
        return [pscustomobject] @{
            Status = 'READY'
            ScopeName = $ScopeName
            Runtime = $state.Runtime
            SqlVersions = $versions
            AdminLogin = $state.AdminLogin
            FrameworkDatabase = $state.FrameworkDatabase
            AlreadyRunning = $false
            LoadedStoredCredential = $loadedStoredCredential
            Connections = @($startedContainers | ForEach-Object {
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
    catch {
        $originalError = $_
        try {
            $resources = Get-QuickTestResourcesByRunId `
                -RuntimeInfo $runtimeInfo `
                -RunId $state.RunId
            $state.LifecycleStatus = 'START_RECOVERY_CLEANUP'
            $state.RecoveryContainerIds = @($resources.ContainerIds)
            $state.RecoveryNetworkIds = @($resources.NetworkIds)
            Write-QuickTestJson -Path $statePath -InputObject $state
            if (
                @($resources.ContainerIds).Count -gt 0 -or
                @($resources.NetworkIds).Count -gt 0
            ) {
                Remove-QuickTestRuntimeResources `
                    -RuntimeInfo $runtimeInfo `
                    -RunId $state.RunId `
                    -ContainerIds @($resources.ContainerIds) `
                    -NetworkIds @($resources.NetworkIds)
            }
            foreach ($container in @($state.Containers)) {
                $container.ContainerId = ''
            }
            $state.NetworkId = ''
            $state.RecoveryContainerIds = @()
            $state.RecoveryNetworkIds = @()
            $state.LifecycleStatus = 'DOWN'
            Write-QuickTestJson -Path $statePath -InputObject $state
        }
        catch {
            # Preserve the original Start failure and the registered recovery state.
        }
        throw $originalError
    }
    finally {
        foreach ($name in $environmentNames) {
            [Environment]::SetEnvironmentVariable(
                $name,
                $previousEnvironment[$name],
                [EnvironmentVariableTarget]::Process
            )
        }
        $plainValue = $null
        $plainStoredCredential = $null
    }
}
