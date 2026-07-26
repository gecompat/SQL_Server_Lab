function Invoke-LabUp {
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

        [Parameter()]
        [ValidateSet('CTR-SINGLE')]
        [string] $TopologyId = 'CTR-SINGLE',

        [Parameter()]
        [ValidateSet(2019, 2022, 2025)]
        [int] $SqlVersion = 2025,

        [Parameter()]
        [ValidateSet('Compact')]
        [string] $ResourceProfile = 'Compact',

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
        }
    }

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
        }
    }
    if ($preflight.ResolvedExecutionMode -ne 'LINUX_NATIVE') {
        Set-LabRunState `
            -StatePath (Join-Path (
                Get-LabRunDirectory -LabRunId $LabRunId -StateRoot $StateRoot
            ) 'run-state.json') `
            -Changes @{
                LifecycleStatus = 'NOT_EXECUTED'
                RuntimeReasonCode = 'HYPERV_LINUX_RUNTIME_GATE_REQUIRED'
            }
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'NOT_EXECUTED'
            ReasonCode = 'HYPERV_LINUX_RUNTIME_GATE_REQUIRED'
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
        throw 'Local configuration does not authorize the requested LAB-001 runtime.'
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
    $storageTargetId = [string] (
        $configuration.StorageRoleBindings.EPHEMERAL_DATA
    )
    $storageTarget = @($configuration.StorageTargets) |
        Where-Object { $_.LogicalTargetId -eq $storageTargetId } |
        Select-Object -First 1
    if ($null -eq $storageTarget -or -not $storageTarget.IsApprovedLabTarget) {
        throw 'EPHEMERAL_DATA must resolve to an approved local target.'
    }
    $dataDirectory = [IO.Path]::GetFullPath(
        (Join-Path $storageTarget.Path "LAB-001/$LabRunId")
    )
    if (
        -not (Test-LabPathWithinRoot `
                -Path $dataDirectory `
                -Root $storageTarget.Path)
    ) {
        throw 'The run data directory is outside the approved storage target.'
    }
    $budget = Get-LabCompactContainerBudget
    $beforeSnapshot = Get-LabCurrentResourceSnapshot `
        -StoragePath $storageTarget.Path
    $beforeReserve = Assert-LabResourceBudget `
        -Snapshot $beforeSnapshot `
        -Budget $budget `
        -Phase BEFORE_UP

    $dockerCommand = Get-LabDockerCommand
    $projectName = Get-LabComposeProjectName -LabRunId $LabRunId
    $imageReference = Resolve-LabSqlContainerImage `
        -Configuration $configuration `
        -SqlVersion $SqlVersion
    if (-not $PSCmdlet.ShouldProcess(
            "CTR-SINGLE resources owned by $LabRunId",
            'Up'
        )) {
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'WHATIF'
            ReasonCode = ''
        }
    }

    $secureSecret = Get-LabSecretValue `
        -LogicalSecretName SQL_SA_PASSWORD `
        -SecretPolicy $configuration.SecretPolicy
    $plainSecret = ConvertFrom-LabSecureString -SecureValue $secureSecret
    $environmentNames = @(
        'LAB_COMPOSE_PROJECT'
        'LAB_RUN_ID'
        'LAB_CONTAINER_HOSTNAME'
        'LAB_RUNTIME_DIR'
        'LAB_DATA_DIR'
        'LAB_SQL_IMAGE'
        'LAB_SQL_SA_PASSWORD'
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
        if (-not $IsWindows) {
            # SQL Server Linux containers run as UID 10001. This directory is
            # isolated below the approved per-run boundary and contains only
            # synthetic lab data.
            [IO.File]::SetUnixFileMode(
                $dataDirectory,
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

        Invoke-LabExternalCommand `
            -FilePath $dockerCommand `
            -Arguments @('image', 'pull', $imageReference) |
            Out-Null

        [Environment]::SetEnvironmentVariable(
            'LAB_COMPOSE_PROJECT',
            $projectName,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'LAB_RUN_ID',
            $LabRunId,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'LAB_CONTAINER_HOSTNAME',
            'lab-sql',
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'LAB_RUNTIME_DIR',
            $runtimeDirectory,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'LAB_DATA_DIR',
            $dataDirectory,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'LAB_SQL_IMAGE',
            $imageReference,
            [EnvironmentVariableTarget]::Process
        )
        [Environment]::SetEnvironmentVariable(
            'LAB_SQL_SA_PASSWORD',
            $plainSecret,
            [EnvironmentVariableTarget]::Process
        )

        Invoke-LabDockerCompose `
            -DockerCommand $dockerCommand `
            -ProjectName $projectName `
            -Arguments @('up', '--detach') |
            Out-Null
        $resources = Get-LabRunDockerResources `
            -DockerCommand $dockerCommand `
            -ProjectName $projectName `
            -LabRunId $LabRunId
        Register-LabResource `
            -LabRunId $LabRunId `
            -Provider DOCKER `
            -ResourceType CONTAINER `
            -ResourceId SQL_CONTAINER `
            -ExactLocator $resources.ContainerId `
            -StateRoot $StateRoot
        Register-LabResource `
            -LabRunId $LabRunId `
            -Provider DOCKER `
            -ResourceType NETWORK `
            -ResourceId LAB_DATA_NETWORK `
            -ExactLocator $resources.NetworkId `
            -StateRoot $StateRoot
        Wait-LabSqlContainerHealthy `
            -DockerCommand $dockerCommand `
            -ContainerId $resources.ContainerId `
            -TimeoutSeconds 300
        Install-LabFramework `
            -DockerCommand $dockerCommand `
            -ContainerId $resources.ContainerId `
            -RunDirectory $runDirectory

        $afterSnapshot = Get-LabCurrentResourceSnapshot `
            -StoragePath $storageTarget.Path
        $afterReserve = Assert-LabResourceBudget `
            -Snapshot $afterSnapshot `
            -Budget $budget `
            -Phase AFTER_UP
        $containerMeasurement = Measure-LabContainerResources `
            -DockerCommand $dockerCommand `
            -ContainerId $resources.ContainerId `
            -Budget $budget
        Write-LabJsonFile `
            -Path (Join-Path $runDirectory 'resource-measurements.json') `
            -InputObject ([ordered] @{
                SchemaVersion = '1.0'
                DataClassification = 'LOCAL_RUNTIME_STATE'
                LabRunId = $LabRunId
                TopologyId = $TopologyId
                SqlVersion = $SqlVersion
                ResourceProfile = $ResourceProfile
                BeforeUp = $beforeSnapshot
                BeforeReserve = $beforeReserve
                AfterUp = $afterSnapshot
                AfterReserve = $afterReserve
                Container = $containerMeasurement
            })
        Set-LabRunState `
            -StatePath (Join-Path $runDirectory 'run-state.json') `
            -Changes @{
                LifecycleStatus = 'TOPOLOGY_READY'
                TopologyId = $TopologyId
                SqlVersion = $SqlVersion
                ResourceProfile = $ResourceProfile
                ComposeProject = $projectName
                ContainerResourceId = 'SQL_CONTAINER'
            }
        return [pscustomobject] @{
            LabRunId = $LabRunId
            Status = 'READY'
            TopologyId = $TopologyId
            SqlVersion = $SqlVersion
            ResourceProfile = $ResourceProfile
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
