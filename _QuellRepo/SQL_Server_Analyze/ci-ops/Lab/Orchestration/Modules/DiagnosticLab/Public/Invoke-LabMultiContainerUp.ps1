function Invoke-LabMultiContainerUp {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    [OutputType([pscustomobject])]
    param(
        [Parameter()]
        [string] $LabRunId = (New-LabRunId),

        [Parameter()]
        [ValidateSet('AUTO', 'WINDOWS_SINGLE_HOST', 'LINUX_NATIVE', 'DISTRIBUTED')]
        [string] $ExecutionMode,

        [Parameter()]
        [string] $ConfigPath,

        [Parameter()]
        [ValidateSet('DOCKER', 'PODMAN')]
        [string] $ContainerEngine = 'DOCKER',

        [Parameter(Mandatory)]
        [ValidateSet('CTR-PAIR', 'CTR-TRIPLE')]
        [string] $TopologyId,

        [Parameter()]
        [ValidateSet(2019, 2022, 2025)]
        [int] $SqlVersion = 2025,

        [Parameter()]
        [ValidateSet('Standard')]
        [string] $ResourceProfile = 'Standard',

        [Parameter()]
        [switch] $AllowRemoteExecution,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    if ($ContainerEngine -eq 'PODMAN') {
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'NOT_EXECUTED'
            ReasonCode = 'PODMAN_COMPATIBILITY_ASSIGNED_TO_WAVE9'
            TopologyId = $TopologyId
        }
    }

    $plan = Get-LabWave4TopologyPlan -TopologyId $TopologyId
    $preflightArguments = @{
        LabRunId = $LabRunId
        StateRoot = $StateRoot
        AllowRemoteExecution = $AllowRemoteExecution
    }
    if ($PSBoundParameters.ContainsKey('ExecutionMode')) {
        $preflightArguments.ExecutionMode = $ExecutionMode
    }
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $preflightArguments.ConfigPath = $ConfigPath
    }
    $preflight = Invoke-LabPreflight @preflightArguments
    if ($preflight.PreflightStatus -ne 'READY') {
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'NOT_EXECUTED'
            ReasonCode = [string] (
                @($preflight.BlockerReasonCodes) |
                    Select-Object -First 1
            )
            TopologyId = $TopologyId
        }
    }
    if ($preflight.ResolvedExecutionMode -ne 'LINUX_NATIVE') {
        $runDirectory = Get-LabRunDirectory -LabRunId $LabRunId -StateRoot $StateRoot
        Set-LabRunState `
            -StatePath (Join-Path $runDirectory 'run-state.json') `
            -Changes @{
                LifecycleStatus = 'NOT_EXECUTED'
                RuntimeReasonCode = 'WAVE4_LINUX_NATIVE_RUNTIME_REQUIRED'
                TopologyId = $TopologyId
            }
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'NOT_EXECUTED'
            ReasonCode = 'WAVE4_LINUX_NATIVE_RUNTIME_REQUIRED'
            TopologyId = $TopologyId
        }
    }

    $configurationArguments = @{}
    if ($PSBoundParameters.ContainsKey('ConfigPath')) {
        $configurationArguments.ConfigPath = $ConfigPath
    }
    if ($PSBoundParameters.ContainsKey('ExecutionMode')) {
        $configurationArguments.ExecutionMode = $ExecutionMode
    }
    $configuration = Resolve-LabConfiguration @configurationArguments
    if (
        -not $configuration.AcceptSqlServerEula -or
        $configuration.ContainerEngine -ne $ContainerEngine -or
        $configuration.ResourceProfile -ne $ResourceProfile -or
        $SqlVersion -notin @($configuration.SqlVersionPriority)
    ) {
        throw 'Local configuration does not authorize the requested Welle 4 runtime.'
    }
    $secretAvailability = Test-LabSecretAvailability `
        -SecretPolicy $configuration.SecretPolicy
    if (
        -not $secretAvailability.IsAvailable -or
        'SQL_SA_PASSWORD' -notin @($configuration.SecretPolicy.RequiredSecretNames)
    ) {
        throw 'The logical SQL_SA_PASSWORD secret is required.'
    }

    $runDirectory = Get-LabRunDirectory -LabRunId $LabRunId -StateRoot $StateRoot
    $runtimeDirectory = Join-Path $runDirectory 'runtime'
    [IO.Directory]::CreateDirectory($runtimeDirectory) | Out-Null
    $storageTargetId = [string] $configuration.StorageRoleBindings.EPHEMERAL_DATA
    $storageTarget = @($configuration.StorageTargets) |
        Where-Object { $_.LogicalTargetId -eq $storageTargetId } |
        Select-Object -First 1
    if ($null -eq $storageTarget -or -not $storageTarget.IsApprovedLabTarget) {
        throw 'EPHEMERAL_DATA must resolve to an approved local target.'
    }
    $dataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $storageTarget.Path "LAB-001/$LabRunId")
    )
    if (-not (Test-LabPathWithinRoot -Path $dataDirectory -Root $storageTarget.Path)) {
        throw 'The Welle 4 run data directory is outside the approved storage target.'
    }

    $budget = Get-LabContainerBudget -ResourceProfile $ResourceProfile
    $beforeSnapshot = Get-LabCurrentResourceSnapshot -StoragePath $storageTarget.Path
    $beforeReserve = Assert-LabResourceBudget `
        -Snapshot $beforeSnapshot `
        -Budget $budget `
        -Phase BEFORE_UP `
        -InstanceCount $plan.Nodes.Count
    $dockerCommand = Get-LabDockerCommand
    $projectName = Get-LabComposeProjectName -LabRunId $LabRunId
    $imageReference = Resolve-LabSqlContainerImage `
        -Configuration $configuration `
        -SqlVersion $SqlVersion

    if (-not $PSCmdlet.ShouldProcess(
            "$TopologyId resources owned by $LabRunId",
            'Up sequentially'
        )) {
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'WHATIF'
            ReasonCode = ''
            TopologyId = $TopologyId
            NodeCount = $plan.Nodes.Count
        }
    }

    $statePath = Join-Path $runDirectory 'run-state.json'
    Set-LabRunState `
        -StatePath $statePath `
        -Changes @{
            LifecycleStatus = 'TOPOLOGY_CREATING'
            RuntimeReasonCode = ''
            TopologyId = $TopologyId
            SqlVersion = $SqlVersion
            ResourceProfile = $ResourceProfile
            ComposeProject = $projectName
            PlannedNodeRoles = @($plan.Nodes | ForEach-Object { $_.Role })
            PlannedNetworkSegments = @($plan.NetworkSegments)
            ManagementPath = $plan.ManagementPath
        }

    $secureSecret = Get-LabSecretValue `
        -LogicalSecretName SQL_SA_PASSWORD `
        -SecretPolicy $configuration.SecretPolicy
    $plainSecret = ConvertFrom-LabSecureString -SecureValue $secureSecret
    $environmentNames = @(
        'LAB_W4_COMPOSE_PROJECT'
        'LAB_W4_RUN_ID'
        'LAB_W4_TOPOLOGY_ID'
        'LAB_W4_SQL_IMAGE'
        'LAB_W4_SQL_SA_PASSWORD'
        'LAB_W4_MSSQL_MEMORY_LIMIT_MB'
        'LAB_W4_CONTAINER_MEMORY_LIMIT'
        'LAB_W4_CONTAINER_CPU_LIMIT'
        'LAB_W4_RUNTIME_DIR'
        'LAB_W4_PRIMARY_DATA_DIR'
        'LAB_W4_SECONDARY_DATA_DIR'
        'LAB_W4_TERTIARY_DATA_DIR'
        'LAB_W4_PRIMARY_HOSTNAME'
        'LAB_W4_SECONDARY_HOSTNAME'
        'LAB_W4_TERTIARY_HOSTNAME'
    )
    $previousEnvironment = @{}
    foreach ($name in $environmentNames) {
        $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable(
            $name,
            [EnvironmentVariableTarget]::Process
        )
    }

    try {
        Invoke-LabLinuxContainerBootstrap
        [IO.Directory]::CreateDirectory($dataDirectory) | Out-Null
        [IO.File]::WriteAllText(
            (Join-Path $dataDirectory '.lab-owner'),
            $LabRunId + [Environment]::NewLine,
            [Text.UTF8Encoding]::new($false)
        )
        Register-LabResource `
            -LabRunId $LabRunId `
            -Provider LOCAL_FILESYSTEM `
            -ResourceType DIRECTORY `
            -ResourceId SQL_DATA_DIRECTORY `
            -ExactLocator $dataDirectory `
            -BoundaryLocator $storageTarget.Path `
            -StateRoot $StateRoot

        $dataPaths = @{
            SQL_PRIMARY = Join-Path $dataDirectory 'sql-primary'
            SQL_SECONDARY = Join-Path $dataDirectory 'sql-secondary'
            SQL_TERTIARY = Join-Path $dataDirectory 'sql-tertiary'
        }
        foreach ($node in $plan.Nodes) {
            $nodePath = [string] $dataPaths[$node.Role]
            [IO.Directory]::CreateDirectory($nodePath) | Out-Null
            if (-not $IsWindows) {
                [IO.File]::SetUnixFileMode(
                    $nodePath,
                    (
                        [IO.UnixFileMode]::UserRead -bor
                        [IO.UnixFileMode]::UserWrite -bor
                        [IO.UnixFileMode]::UserExecute -bor
                        [IO.UnixFileMode]::GroupRead -bor
                        [IO.UnixFileMode]::GroupWrite -bor
                        [IO.UnixFileMode]::GroupExecute -bor
                        [IO.UnixFileMode]::OtherRead -bor
                        [IO.UnixFileMode]::OtherWrite -bor
                        [IO.UnixFileMode]::OtherExecute
                    )
                )
            }
        }

        Invoke-LabExternalCommand `
            -FilePath $dockerCommand `
            -Arguments @('image', 'pull', $imageReference) |
            Out-Null

        $environmentValues = @{
            LAB_W4_COMPOSE_PROJECT = $projectName
            LAB_W4_RUN_ID = $LabRunId
            LAB_W4_TOPOLOGY_ID = $TopologyId
            LAB_W4_SQL_IMAGE = $imageReference
            LAB_W4_SQL_SA_PASSWORD = $plainSecret
            LAB_W4_MSSQL_MEMORY_LIMIT_MB = [string] $budget.SqlMemoryLimitMiB
            LAB_W4_CONTAINER_MEMORY_LIMIT = "$($budget.MemoryMiB)m"
            LAB_W4_CONTAINER_CPU_LIMIT = $budget.LogicalProcessors.ToString(
                [Globalization.CultureInfo]::InvariantCulture
            )
            LAB_W4_RUNTIME_DIR = $runtimeDirectory
            LAB_W4_PRIMARY_DATA_DIR = [string] $dataPaths.SQL_PRIMARY
            LAB_W4_SECONDARY_DATA_DIR = [string] $dataPaths.SQL_SECONDARY
            LAB_W4_TERTIARY_DATA_DIR = [string] $dataPaths.SQL_TERTIARY
            LAB_W4_PRIMARY_HOSTNAME = 'lab-sql-primary'
            LAB_W4_SECONDARY_HOSTNAME = 'lab-sql-secondary'
            LAB_W4_TERTIARY_HOSTNAME = 'lab-sql-tertiary'
        }
        foreach ($name in $environmentValues.Keys) {
            [Environment]::SetEnvironmentVariable(
                $name,
                [string] $environmentValues[$name],
                [EnvironmentVariableTarget]::Process
            )
        }

        $nodeResults = [Collections.Generic.List[object]]::new()
        $networkResources = @()
        $expectedMajor = @{ 2019 = 15; 2022 = 16; 2025 = 17 }[$SqlVersion]
        foreach ($node in $plan.Nodes) {
            Invoke-LabWave4DockerCompose `
                -DockerCommand $dockerCommand `
                -ProjectName $projectName `
                -Arguments @('up', '--detach', $node.ServiceName) |
                Out-Null
            $containerId = Get-LabWave4ServiceContainerId `
                -DockerCommand $dockerCommand `
                -ProjectName $projectName `
                -ServiceName $node.ServiceName
            Assert-LabWave4ContainerOwnership `
                -DockerCommand $dockerCommand `
                -ContainerId $containerId `
                -LabRunId $LabRunId `
                -TopologyId $TopologyId `
                -Role $node.Role
            Register-LabResource `
                -LabRunId $LabRunId `
                -Provider DOCKER `
                -ResourceType CONTAINER `
                -ResourceId $node.ResourceId `
                -ExactLocator $containerId `
                -StateRoot $StateRoot

            if ($networkResources.Count -eq 0) {
                $networkResources = @(
                    Get-LabWave4NetworkResources `
                        -DockerCommand $dockerCommand `
                        -LabRunId $LabRunId `
                        -TopologyId $TopologyId
                )
                foreach ($network in $networkResources) {
                    Register-LabResource `
                        -LabRunId $LabRunId `
                        -Provider DOCKER `
                        -ResourceType NETWORK `
                        -ResourceId $network.ResourceId `
                        -ExactLocator $network.NetworkId `
                        -StateRoot $StateRoot
                }
            }

            Wait-LabSqlContainerHealthy `
                -DockerCommand $dockerCommand `
                -ContainerId $containerId `
                -TimeoutSeconds 300
            $major = Invoke-LabContainerSqlScalar `
                -DockerCommand $dockerCommand `
                -ContainerId $containerId `
                -Query "SET NOCOUNT ON; SELECT CONVERT(int, SERVERPROPERTY('ProductMajorVersion'));"
            if ([int] $major -ne [int] $expectedMajor) {
                throw "SQL Server role $($node.Role) returned an unexpected major version."
            }
            $framework = Install-LabContainerFramework `
                -Runtime DOCKER `
                -RuntimeCommand $dockerCommand `
                -ContainerId $containerId `
                -RunDirectory $runDirectory
            if ([string] $framework.VerificationStatus -ne 'FRAMEWORK_READY') {
                throw "SQL Server role $($node.Role) did not verify the framework."
            }
            $measurement = Measure-LabContainerResources `
                -DockerCommand $dockerCommand `
                -ContainerId $containerId `
                -Budget $budget
            $nodeResults.Add([pscustomobject] @{
                    Ordinal = $node.Ordinal
                    Role = $node.Role
                    ResourceId = $node.ResourceId
                    ContainerId = $containerId
                    SqlVersion = $SqlVersion
                    ProductMajorVersion = $expectedMajor
                    HealthStatus = 'healthy'
                    FrameworkStatus = [string] $framework.Status
                    FrameworkVerification = [string] $framework.VerificationStatus
                    ResourceMeasurement = $measurement
                })
            Set-LabRunState `
                -StatePath $statePath `
                -Changes @{
                    LifecycleStatus = 'TOPOLOGY_CREATING'
                    RegisteredNodeRoles = @(
                        $nodeResults |
                            ForEach-Object { $_.Role }
                    )
                    RegisteredContainerResourceIds = @(
                        $nodeResults |
                            ForEach-Object { $_.ResourceId }
                    )
                }
        }

        $afterSnapshot = Get-LabCurrentResourceSnapshot -StoragePath $storageTarget.Path
        $afterReserve = Assert-LabResourceBudget `
            -Snapshot $afterSnapshot `
            -Budget $budget `
            -Phase AFTER_UP `
            -InstanceCount $plan.Nodes.Count
        Write-LabJsonFile `
            -Path (Join-Path $runDirectory 'wave4-resource-measurements.json') `
            -InputObject ([ordered] @{
                SchemaVersion = '1.0'
                DataClassification = 'LOCAL_RUNTIME_STATE'
                LabRunId = $LabRunId
                TopologyId = $TopologyId
                SqlVersion = $SqlVersion
                ResourceProfile = $ResourceProfile
                NodeCount = $nodeResults.Count
                BeforeUp = $beforeSnapshot
                BeforeReserve = $beforeReserve
                AfterUp = $afterSnapshot
                AfterReserve = $afterReserve
                Nodes = $nodeResults.ToArray()
            })
        Set-LabRunState `
            -StatePath $statePath `
            -Changes @{
                LifecycleStatus = 'TOPOLOGY_READY'
                RuntimeReasonCode = ''
                TopologyId = $TopologyId
                SqlVersion = $SqlVersion
                ResourceProfile = $ResourceProfile
                ComposeProject = $projectName
                NodeCount = $nodeResults.Count
                ContainerResourceIds = @(
                    $nodeResults |
                        ForEach-Object { $_.ResourceId }
                )
                NetworkResourceIds = @(
                    $networkResources |
                        ForEach-Object { $_.ResourceId }
                )
                ManagementPath = $plan.ManagementPath
                Wave4RuntimeStatus = 'IMPLEMENTED_EXTERNAL_EVIDENCE_PENDING'
            }
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'READY'
            TopologyId = $TopologyId
            SqlVersion = $SqlVersion
            ResourceProfile = $ResourceProfile
            ManagementPath = $plan.ManagementPath
            Nodes = $nodeResults.ToArray()
            Networks = $networkResources
        }
    }
    catch {
        $originalError = $_
        try {
            Register-LabDiscoveredDockerResources `
                -DockerCommand $dockerCommand `
                -LabRunId $LabRunId `
                -StateRoot $StateRoot
            Invoke-LabCleanup `
                -LabRunId $LabRunId `
                -StateRoot $StateRoot `
                -Recovery `
                -Confirm:$false `
                -ErrorAction SilentlyContinue |
                Out-Null
        }
        catch {
            # Preserve the original Up exception. Remaining resources stay registered.
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
        $plainSecret = $null
    }
}
