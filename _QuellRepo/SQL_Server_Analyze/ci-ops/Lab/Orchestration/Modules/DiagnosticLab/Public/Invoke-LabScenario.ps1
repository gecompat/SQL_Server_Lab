function Invoke-LabScenario {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [ValidatePattern('^LAB-[A-Z0-9]+-[0-9]{3}$')]
        [string] $ScenarioId,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    $contract = Get-LabScenarioContract -ScenarioId $ScenarioId
    $paths = Initialize-LabRunState `
        -LabRunId $LabRunId `
        -StateRoot $StateRoot
    $runDirectory = $paths.RunDirectory
    $statePath = $paths.StatePath

    if (
        $contract.Category -eq 'PERFORMANCE' -and
        $contract.Runbook.RuntimeAction -eq 'CONTRACT_FIXTURE'
    ) {
        $fixtureResult = New-LabFixtureScenarioResult -Contract $contract
        $result = Write-LabScenarioResult `
            -RunDirectory $runDirectory `
            -ScenarioId $ScenarioId `
            -Result $fixtureResult `
            -CleanupStatus NOT_REQUIRED
        Set-LabRunState -StatePath $statePath -Changes @{
            LifecycleStatus = 'SCENARIO_COMPLETED'
            ScenarioId = $ScenarioId
            ScenarioStatus = $result.Status
            EvidenceClass = 'CONTRACT_FIXTURE'
        }
        return $result
    }

    $registryPath = $paths.RegistryPath
    $state = Read-LabJsonFile -Path $statePath
    if ($state.LifecycleStatus -notin @(
            'TOPOLOGY_READY',
            'SCENARIO_COMPLETED',
            'SCENARIO_VALIDATED'
        )) {
        throw 'Scenario execution requires a ready CTR-SINGLE topology.'
    }
    if (
        $contract.Definition.TopologyId -ne 'CTR-SINGLE' -or
        $contract.Definition.ResourceProfile -ne 'Compact' -or
        [int] $state.SqlVersion -notin @($contract.Definition.SqlVersions)
    ) {
        throw 'Scenario definition is outside the active runtime boundary.'
    }

    $registry = Read-LabJsonFile -Path $registryPath
    $container = @($registry.Resources) |
        Where-Object {
            $_.Provider -eq 'DOCKER' -and
            $_.ResourceType -eq 'CONTAINER' -and
            $_.ResourceId -eq 'SQL_CONTAINER'
        } |
        Select-Object -First 1
    if ($null -eq $container) {
        throw 'The registered SQL container is missing.'
    }

    $dockerCommand = Get-LabDockerCommand
    $owner = Get-LabDockerObjectLabel `
        -DockerCommand $dockerCommand `
        -ResourceType CONTAINER `
        -ExactLocator $container.ExactLocator
    if ($owner -ne $LabRunId) {
        throw 'The SQL container ownership label does not match the run.'
    }

    if ($contract.Category -eq 'CORE') {
        $runtimeScenarioDirectory = Join-Path $runDirectory 'runtime/scenarios'
        [IO.Directory]::CreateDirectory($runtimeScenarioDirectory) | Out-Null
        $runtimeSqlPath = Join-Path $runtimeScenarioDirectory "$ScenarioId.sql"
        [IO.File]::Copy(
            (Join-Path $contract.Directory 'scenario.sql'),
            $runtimeSqlPath,
            $true
        )
        $output = Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId $container.ExactLocator `
            -ContainerSqlPath "/lab/runtime/scenarios/$ScenarioId.sql"
        $scenarioResult = ConvertFrom-LabScenarioOutput `
            -ScenarioId $ScenarioId `
            -CommandOutput $output
        $result = Write-LabScenarioResult `
            -RunDirectory $runDirectory `
            -ScenarioId $ScenarioId `
            -Result $scenarioResult `
            -CleanupStatus NOT_REQUIRED
        Set-LabRunState -StatePath $statePath -Changes @{
            LifecycleStatus = 'SCENARIO_COMPLETED'
            ScenarioId = $ScenarioId
            ScenarioStatus = $result.Status
        }
        return $result
    }

    if ($null -eq $contract.Runbook) {
        throw 'The Welle 3 scenario runbook is missing.'
    }
    if (
        $contract.Runbook.ScenarioId -ne $ScenarioId -or
        [int] $state.SqlVersion -notin @($contract.Runbook.SqlVersions)
    ) {
        throw 'The Welle 3 runbook does not match the active SQL version.'
    }

    Copy-LabWave3RuntimeScripts -RunDirectory $runDirectory | Out-Null
    $variables = @{
        ScenarioId = $ScenarioId
        LabRunId = $LabRunId
        PrimaryAnalyzer = [string] $contract.Runbook.PrimaryAnalyzer
        FindingCode = [string] $contract.Runbook.FindingCode
    }
    $workers = [Collections.Generic.List[object]]::new()
    $scenarioResult = $null
    $operationError = $null
    $cleanupError = $null
    $workerError = $null
    $setupStarted = $false

    try {
        $resetOutput = Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId $container.ExactLocator `
            -ContainerSqlPath '/lab/runtime/scenarios/_shared/Cleanup.sql' `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds 300
        Test-LabCleanupOutput `
            -ScenarioId $ScenarioId `
            -CommandOutput $resetOutput

        $setupStarted = $true
        Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId $container.ExactLocator `
            -ContainerSqlPath '/lab/runtime/scenarios/_shared/Setup.sql' `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds 300 |
            Out-Null

        for (
            $workerId = 1;
            $workerId -le [int] $contract.Runbook.WorkerCount;
            $workerId++
        ) {
            $workers.Add(
                (Start-LabSqlWorker `
                    -DockerCommand $dockerCommand `
                    -ContainerId $container.ExactLocator `
                    -SqlCmdVariables $variables `
                    -QueryTimeoutSeconds (
                        [int] $contract.Runbook.WorkerTimeoutSeconds
                    ) `
                    -WorkerId $workerId)
            )
        }
        if ([int] $contract.Runbook.WorkerStartLeadSeconds -gt 0) {
            Start-Sleep `
                -Seconds ([int] $contract.Runbook.WorkerStartLeadSeconds)
        }

        if ($contract.Runbook.RuntimeAction -eq 'CONTAINER_RESTART') {
            $currentOwner = Get-LabDockerObjectLabel `
                -DockerCommand $dockerCommand `
                -ResourceType CONTAINER `
                -ExactLocator $container.ExactLocator
            if ($currentOwner -ne $LabRunId) {
                throw 'Container restart refused a foreign ownership label.'
            }
            Invoke-LabExternalCommand `
                -FilePath $dockerCommand `
                -Arguments @(
                    'container',
                    'restart',
                    '--time',
                    '10',
                    $container.ExactLocator
                ) |
                Out-Null
            Wait-LabSqlContainerHealthy `
                -DockerCommand $dockerCommand `
                -ContainerId $container.ExactLocator `
                -TimeoutSeconds 300
        }

        $output = Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId $container.ExactLocator `
            -ContainerSqlPath '/lab/runtime/scenarios/_shared/Observe.sql' `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds (
                [int] $contract.Runbook.ScenarioTimeoutSeconds
            )
        $scenarioResult = ConvertFrom-LabScenarioOutput `
            -ScenarioId $ScenarioId `
            -CommandOutput $output
    }
    catch {
        $operationError = $_
    }
    finally {
        if ($setupStarted) {
            try {
                $cleanupOutput = Invoke-LabSqlFile `
                    -DockerCommand $dockerCommand `
                    -ContainerId $container.ExactLocator `
                    -ContainerSqlPath (
                        '/lab/runtime/scenarios/_shared/Cleanup.sql'
                    ) `
                    -SqlCmdVariables $variables `
                    -QueryTimeoutSeconds 300
                Test-LabCleanupOutput `
                    -ScenarioId $ScenarioId `
                    -CommandOutput $cleanupOutput
            }
            catch {
                $cleanupError = $_
            }
        }
        try {
            Complete-LabSqlWorkers `
                -Workers $workers.ToArray() `
                -AllowedExitCodes @(
                    $contract.Runbook.AllowedWorkerExitCodes
                )
        }
        catch {
            $workerError = $_
        }
    }

    if ($null -ne $cleanupError) {
        throw 'Welle 3 scenario cleanup failed inside the exact synthetic scope.'
    }
    if ($null -ne $operationError) {
        throw $operationError
    }
    if ($null -ne $workerError) {
        throw $workerError
    }
    if ($null -eq $scenarioResult) {
        throw 'Welle 3 did not produce a scenario result.'
    }

    $result = Write-LabScenarioResult `
        -RunDirectory $runDirectory `
        -ScenarioId $ScenarioId `
        -Result $scenarioResult `
        -CleanupStatus PASS
    Set-LabRunState -StatePath $statePath -Changes @{
        LifecycleStatus = 'SCENARIO_COMPLETED'
        ScenarioId = $ScenarioId
        ScenarioStatus = $result.Status
        ScenarioCleanupStatus = $result.CleanupStatus
    }
    return $result
}
