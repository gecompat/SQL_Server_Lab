Set-StrictMode -Version Latest

function Install-QuickTestLab {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [ValidateSet('DOCKER', 'PODMAN')]
        [string] $Runtime,

        [Parameter(Mandatory)]
        [int[]] $SqlVersions,

        [Parameter()]
        [hashtable] $Ports = @{},

        [Parameter(Mandatory)]
        [securestring] $AdminSecret,

        [Parameter()]
        [ValidatePattern('^(sa|[A-Za-z][A-Za-z0-9_]{2,31})$')]
        [string] $AdminLogin = 'ExampleSqlAdmin',

        [Parameter()]
        [ValidateSet('SMALL', 'MEDIUM', 'LARGE')]
        [string] $ResourceProfile = 'SMALL',

        [Parameter()]
        [ValidateSet('PERSISTENT', 'TEMPORARY')]
        [string] $PersistenceMode = 'TEMPORARY',

        [Parameter()]
        [ValidatePattern('^[a-z][a-z0-9-]{2,31}$')]
        [string] $ScopeName = 'sql-analyze-quicktest',

        [Parameter()]
        [switch] $InstallFramework,

        [Parameter()]
        [switch] $PersistGeneratedCredential,

        [Parameter(Mandatory)]
        [switch] $AcceptEula,

        [Parameter()]
        [string] $StateRoot = (Join-Path $script:QuickTestLabRoot '.state/quick-test'),

        [Parameter()]
        [string] $DataRoot = (Join-Path $script:QuickTestLabRoot '.artifacts/quick-test'),

        [Parameter()]
        [string] $CredentialRoot = (Join-Path $script:QuickTestLabRoot '.secrets/quick-test'),

        [Parameter()]
        [switch] $SkipImageAvailabilityCheck
    )

    if (-not $AcceptEula) {
        throw 'Explicit SQL Server EULA acceptance is required.'
    }
    if (-not (Test-QuickTestPassword -SecureValue $AdminSecret)) {
        throw 'The SQL Server credential does not satisfy the quick-test complexity contract.'
    }

    $versions = @($SqlVersions | Sort-Object -Unique)
    $resolvedPorts = Resolve-QuickTestPorts `
        -SqlVersions $versions `
        -Ports $Ports
    $stateBaseRoot = [IO.Path]::GetFullPath($StateRoot)
    $dataBaseRoot = [IO.Path]::GetFullPath($DataRoot)
    $credentialBaseRoot = [IO.Path]::GetFullPath($CredentialRoot)
    $scopeStateDirectory = [IO.Path]::GetFullPath(
        (Join-Path $stateBaseRoot $ScopeName)
    )
    $scopeDataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $dataBaseRoot $ScopeName)
    )
    $scopeCredentialDirectory = [IO.Path]::GetFullPath(
        (Join-Path $credentialBaseRoot $ScopeName)
    )
    $statePath = Join-Path $scopeStateDirectory 'state.json'

    foreach ($boundary in @(
            [pscustomobject] @{ Path = $scopeStateDirectory; Root = $stateBaseRoot }
            [pscustomobject] @{ Path = $scopeDataDirectory; Root = $dataBaseRoot }
            [pscustomobject] @{ Path = $scopeCredentialDirectory; Root = $credentialBaseRoot }
        )) {
        if (
            -not (Test-QuickTestPathWithinRoot `
                -Path $boundary.Path `
                -Root $boundary.Root) -or
            $boundary.Path -eq $boundary.Root
        ) {
            throw 'A quick-test lifecycle path is outside its approved child scope.'
        }
    }

    if (Test-Path -LiteralPath $statePath -PathType Leaf) {
        return Get-QuickTestLabStatus `
            -ScopeName $ScopeName `
            -StateRoot $stateBaseRoot
    }

    $localConflicts = @(
        @(
            $scopeStateDirectory
            $scopeDataDirectory
            $scopeCredentialDirectory
        ) | Where-Object { Test-Path -LiteralPath $_ }
    )
    if ($localConflicts.Count -gt 0) {
        return [pscustomobject] @{
            Status = 'PREFLIGHT_FAILED'
            ScopeName = $ScopeName
            BlockerReasonCodes = @('LOCAL_SCOPE_CONFLICT')
            MutationBoundary = 'READ_ONLY_PREFLIGHT'
        }
    }

    $preflight = Invoke-QuickTestPreflight `
        -Runtime $Runtime `
        -SqlVersions $versions `
        -Ports $resolvedPorts `
        -AdminLogin $AdminLogin `
        -AdminSecret $AdminSecret `
        -ResourceProfile $ResourceProfile `
        -DataRoot $scopeDataDirectory `
        -ScopeName $ScopeName `
        -AcceptEula:$AcceptEula `
        -SkipImageAvailabilityCheck:$SkipImageAvailabilityCheck
    if ($preflight.Status -ne 'READY') {
        return $preflight
    }

    if (-not $PSCmdlet.ShouldProcess(
            "quick-test scope $ScopeName",
            'Install exact Docker or Podman SQL Server test instances'
        )) {
        return [pscustomobject] @{
            Status = 'WHATIF'
            ScopeName = $ScopeName
            SqlVersions = $versions
        }
    }

    $runtimeInfo = Resolve-QuickTestRuntime -Runtime $Runtime
    $profile = Get-QuickTestResourceProfile -Name $ResourceProfile
    $runId = New-QuickTestRunId
    $projectName = $ScopeName
    $runtimeDirectory = Join-Path $scopeStateDirectory 'runtime'
    $containers = [Collections.Generic.List[object]]::new()
    $networkId = ''
    $credentialPath = ''
    $baseEnvironment = $null
    $state = $null

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

    $plainValue = ConvertFrom-QuickTestSecureString -SecureValue $AdminSecret
    try {
        Set-QuickTestOwnerMarker -Path $scopeStateDirectory -RunId $runId
        Set-QuickTestPrivateDirectoryPermissions -Path $scopeStateDirectory
        [IO.Directory]::CreateDirectory($runtimeDirectory) | Out-Null
        Set-QuickTestDirectoryPermissions -Path $runtimeDirectory
        Set-QuickTestOwnerMarker -Path $scopeDataDirectory -RunId $runId
        Set-QuickTestDirectoryPermissions -Path $scopeDataDirectory

        $state = [ordered] @{
            SchemaVersion = '1.0'
            DataClassification = 'LOCAL_RUNTIME_STATE'
            LifecycleStatus = 'INSTALLING'
            ScopeName = $ScopeName
            RunId = $runId
            Runtime = $Runtime
            ProjectName = $projectName
            SqlVersions = $versions
            ResourceProfile = $ResourceProfile
            PersistenceMode = $PersistenceMode
            InstallFramework = [bool] $InstallFramework
            AdminLogin = $AdminLogin
            FrameworkDatabase = ''
            StateBaseRoot = $stateBaseRoot
            StateDirectory = $scopeStateDirectory
            DataBaseRoot = $dataBaseRoot
            DataRoot = $scopeDataDirectory
            CredentialBaseRoot = $credentialBaseRoot
            CredentialDirectory = ''
            GeneratedCredentialStored = $false
            NetworkId = ''
            Containers = @()
            RecoveryContainerIds = @()
            RecoveryNetworkIds = @()
        }
        Write-QuickTestJson -Path $statePath -InputObject $state

        if ($PersistGeneratedCredential) {
            $credentialPath = Save-QuickTestGeneratedCredential `
                -CredentialDirectory $scopeCredentialDirectory `
                -SecureValue $AdminSecret `
                -RunId $runId
            $state.CredentialDirectory = $scopeCredentialDirectory
            $state.GeneratedCredentialStored = $true
            Write-QuickTestJson -Path $statePath -InputObject $state
        }

        $baseEnvironment = @{
            QTLAB_COMPOSE_PROJECT = $projectName
            QTLAB_SCOPE = $ScopeName
            QTLAB_RUN_ID = $runId
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

        foreach ($version in $versions) {
            $versionRoot = Join-Path $scopeDataDirectory ([string] $version)
            $directories = @{
                DATA_DIR = Join-Path $versionRoot 'data'
                LOG_DIR = Join-Path $versionRoot 'log'
                BACKUP_DIR = Join-Path $versionRoot 'backup'
            }
            foreach ($directory in $directories.Values) {
                [IO.Directory]::CreateDirectory($directory) | Out-Null
                Set-QuickTestDirectoryPermissions -Path $directory
            }
            $values = @{
                IMAGE = Get-QuickTestImageReference -SqlVersion $version
                CONTAINER = "$ScopeName-sql$version"
                PORT = [string] $resolvedPorts[$version]
                DATA_DIR = $directories.DATA_DIR
                LOG_DIR = $directories.LOG_DIR
                BACKUP_DIR = $directories.BACKUP_DIR
            }
            foreach ($suffix in $values.Keys) {
                [Environment]::SetEnvironmentVariable(
                    "QTLAB_SQL${version}_$suffix",
                    [string] $values[$suffix],
                    [EnvironmentVariableTarget]::Process
                )
            }
        }

        Invoke-QuickTestCompose `
            -RuntimeInfo $runtimeInfo `
            -ProjectName $projectName `
            -SqlVersions $versions `
            -Arguments @('pull') |
            Out-Null

        foreach ($version in $versions) {
            $service = Get-QuickTestServiceName -SqlVersion $version
            Invoke-QuickTestCompose `
                -RuntimeInfo $runtimeInfo `
                -ProjectName $projectName `
                -SqlVersions $versions `
                -Arguments @('up', '--detach', $service) |
                Out-Null

            $containerId = Get-QuickTestContainerId `
                -RuntimeInfo $runtimeInfo `
                -ProjectName $projectName `
                -SqlVersions $versions `
                -SqlVersion $version
            $expectedMajor = @{ 2019 = 15; 2022 = 16; 2025 = 17 }[$version]
            $containers.Add([pscustomobject] @{
                    SqlVersion = $version
                    ProductMajorVersion = $expectedMajor
                    ServiceName = $service
                    ContainerId = $containerId
                    ContainerName = "$ScopeName-sql$version"
                    Port = [int] $resolvedPorts[$version]
                    ImageReference = Get-QuickTestImageReference -SqlVersion $version
                })
            $state.Containers = $containers.ToArray()

            if (-not $networkId) {
                $resources = Get-QuickTestResourcesByRunId `
                    -RuntimeInfo $runtimeInfo `
                    -RunId $runId
                if (@($resources.NetworkIds).Count -ne 1) {
                    throw 'The quick-test install did not resolve exactly one owned network.'
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
            if ([int] $major -ne $expectedMajor) {
                throw "SQL Server $version returned an unexpected major version."
            }

            if ($AdminLogin -ne 'sa') {
                Initialize-QuickTestAdminLogin `
                    -RuntimeInfo $runtimeInfo `
                    -ContainerId $containerId `
                    -AdminLogin $AdminLogin `
                    -SecureValue $AdminSecret
            }
            if ($InstallFramework) {
                $diagnosticModulePath = Join-Path (
                    $script:QuickTestLabRoot
                ) 'Orchestration/Modules/DiagnosticLab/DiagnosticLab.psd1'
                Import-Module `
                    -Name $diagnosticModulePath `
                    -Force `
                    -ErrorAction Stop
                Install-LabContainerFramework `
                    -Runtime $Runtime `
                    -RuntimeCommand $runtimeInfo.Command `
                    -ContainerId $containerId `
                    -RunDirectory $scopeStateDirectory |
                    Out-Null
            }
        }

        $state.LifecycleStatus = 'READY'
        if ($InstallFramework) {
            $state.FrameworkDatabase = 'LabAnalyze'
        }
        Write-QuickTestJson -Path $statePath -InputObject $state

        $credentialSegment = 'Pass' + 'word=<prompt>'
        return [pscustomobject] @{
            Status = 'READY'
            ScopeName = $ScopeName
            Runtime = $Runtime
            SqlVersions = $versions
            AdminLogin = $AdminLogin
            FrameworkDatabase = $state.FrameworkDatabase
            GeneratedCredentialPath = $credentialPath
            Connections = @($containers | ForEach-Object {
                    [pscustomobject] @{
                        SqlVersion = $_.SqlVersion
                        Server = 'localhost'
                        Port = $_.Port
                        Login = $AdminLogin
                        SqlCmd = "sqlcmd -C -S localhost,$($_.Port) -U $AdminLogin"
                        ConnectionStringTemplate = "Server=localhost,$($_.Port);User ID=$AdminLogin;$credentialSegment;TrustServerCertificate=True"
                    }
                })
        }
    }
    catch {
        $originalError = $_
        try {
            $resources = Get-QuickTestResourcesByRunId `
                -RuntimeInfo $runtimeInfo `
                -RunId $runId
            if ($null -ne $state) {
                $state.LifecycleStatus = 'RECOVERY_CLEANUP'
                $state.RecoveryContainerIds = @($resources.ContainerIds)
                $state.RecoveryNetworkIds = @($resources.NetworkIds)
                Write-QuickTestJson -Path $statePath -InputObject $state
            }
            Remove-QuickTestRuntimeResources `
                -RuntimeInfo $runtimeInfo `
                -RunId $runId `
                -ContainerIds @($resources.ContainerIds) `
                -NetworkIds @($resources.NetworkIds)

            if (
                (Test-Path -LiteralPath $scopeDataDirectory) -and
                (Test-QuickTestOwnedDirectory `
                    -Path $scopeDataDirectory `
                    -Root $dataBaseRoot `
                    -RunId $runId)
            ) {
                Remove-Item -LiteralPath $scopeDataDirectory -Recurse -Force
            }
            if (
                (Test-Path -LiteralPath $scopeCredentialDirectory) -and
                (Test-QuickTestOwnedDirectory `
                    -Path $scopeCredentialDirectory `
                    -Root $credentialBaseRoot `
                    -RunId $runId)
            ) {
                Remove-Item `
                    -LiteralPath $scopeCredentialDirectory `
                    -Recurse `
                    -Force
            }
            if (
                (Test-Path -LiteralPath $scopeStateDirectory) -and
                (Test-QuickTestOwnedDirectory `
                    -Path $scopeStateDirectory `
                    -Root $stateBaseRoot `
                    -RunId $runId)
            ) {
                Remove-Item -LiteralPath $scopeStateDirectory -Recurse -Force
            }
        }
        catch {
            # Preserve the original failure. Remaining resources stay discoverable by run label.
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
        if ($null -ne $baseEnvironment) {
            foreach ($name in @($baseEnvironment.Keys)) {
                $baseEnvironment[$name] = $null
            }
        }
        $plainValue = $null
    }
}
