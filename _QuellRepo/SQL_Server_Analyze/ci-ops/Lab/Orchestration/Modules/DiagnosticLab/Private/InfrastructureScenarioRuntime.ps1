function Copy-LabInfrastructureScenarioScripts {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Contract,

        [Parameter(Mandatory)]
        [string] $RunDirectory
    )

    $targetDirectory = Join-Path (
        $RunDirectory
    ) ("runtime/scenarios/" + [string] $Contract.Definition.ScenarioId)
    [IO.Directory]::CreateDirectory($targetDirectory) | Out-Null
    $scripts = @(Get-ChildItem -LiteralPath $Contract.Directory -Filter '*.sql' -File)
    if ($scripts.Count -lt 8) {
        throw 'The infrastructure scenario SQL package is incomplete.'
    }
    foreach ($script in $scripts) {
        [IO.File]::Copy(
            $script.FullName,
            (Join-Path $targetDirectory $script.Name),
            $true
        )
    }
    return $targetDirectory
}

function ConvertFrom-LabPrefixedJson {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string[]] $CommandOutput,

        [Parameter(Mandatory)]
        [ValidatePattern('^[A-Z_]+=$')]
        [string] $Prefix
    )

    $line = $CommandOutput |
        Where-Object { $_.StartsWith($Prefix, [StringComparison]::Ordinal) } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($line)) {
        throw "Infrastructure scenario output lacks $Prefix"
    }
    return $line.Substring($Prefix.Length) | ConvertFrom-Json -Depth 100
}

function Get-LabInfrastructureContainerResource {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [pscustomobject] $Registry,

        [Parameter(Mandatory)]
        [ValidateSet('SQL_PRIMARY_CONTAINER', 'SQL_SECONDARY_CONTAINER')]
        [string] $ResourceId,

        [Parameter(Mandatory)]
        [ValidateSet('SQL_PRIMARY', 'SQL_SECONDARY')]
        [string] $Role,

        [Parameter(Mandatory)]
        [string] $DockerCommand,

        [Parameter(Mandatory)]
        [string] $LabRunId
    )

    $resource = @($Registry.Resources) |
        Where-Object {
            $_.Provider -eq 'DOCKER' -and
            $_.ResourceType -eq 'CONTAINER' -and
            $_.ResourceId -eq $ResourceId
        } |
        Select-Object -First 1
    if ($null -eq $resource -or [string] $resource.ExactLocator -notmatch '^[a-f0-9]{64}$') {
        throw "The registered infrastructure container is missing: $ResourceId"
    }
    Assert-LabWave4ContainerOwnership `
        -DockerCommand $DockerCommand `
        -ContainerId ([string] $resource.ExactLocator) `
        -LabRunId $LabRunId `
        -TopologyId CTR-PAIR `
        -Role $Role
    return $resource
}

function Get-LabPathLeaf {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $PathValue
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ''
    }
    $normalized = $PathValue.Replace('\', '/')
    return [string] ($normalized.Split('/') | Select-Object -Last 1)
}

function Test-LabAnalyzerStatus {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [AllowNull()]
        [string] $StatusCode
    )

    return $StatusCode -in @(
        'AVAILABLE',
        'AVAILABLE_LIMITED',
        'AVAILABLE_WITH_FINDING'
    )
}

function Initialize-LabScenarioTransferDirectory {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)]
        [string] $ScenarioDirectory,

        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [string] $ScenarioId
    )

    $transferDirectory = [IO.Path]::GetFullPath(
        (Join-Path $ScenarioDirectory 'transfer')
    )
    if (-not (Test-LabPathWithinRoot -Path $transferDirectory -Root $ScenarioDirectory)) {
        throw 'The infrastructure transfer directory is outside the scenario boundary.'
    }
    foreach ($directory in @(
            $transferDirectory,
            (Join-Path $transferDirectory 'source'),
            (Join-Path $transferDirectory 'destination')
        )) {
        [IO.Directory]::CreateDirectory($directory) | Out-Null
        if (-not $IsWindows) {
            [IO.File]::SetUnixFileMode(
                $directory,
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
    [IO.File]::WriteAllText(
        (Join-Path $transferDirectory '.lab-scenario-owner'),
        "$LabRunId|$ScenarioId" + [Environment]::NewLine,
        [Text.UTF8Encoding]::new($false)
    )
    return $transferDirectory
}

function Remove-LabScenarioTransferDirectory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $ScenarioDirectory,

        [Parameter(Mandatory)]
        [string] $TransferDirectory,

        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [string] $ScenarioId
    )

    if (-not (Test-Path -LiteralPath $TransferDirectory -PathType Container)) {
        return
    }
    if (-not (Test-LabPathWithinRoot -Path $TransferDirectory -Root $ScenarioDirectory)) {
        throw 'Infrastructure cleanup refused an out-of-bound transfer directory.'
    }
    $markerPath = Join-Path $TransferDirectory '.lab-scenario-owner'
    if (-not (Test-Path -LiteralPath $markerPath -PathType Leaf)) {
        throw 'Infrastructure cleanup refused an unmarked transfer directory.'
    }
    $marker = [IO.File]::ReadAllText($markerPath, [Text.Encoding]::UTF8).Trim()
    if ($marker -ne "$LabRunId|$ScenarioId") {
        throw 'Infrastructure cleanup refused a foreign transfer directory.'
    }
    [IO.Directory]::Delete($TransferDirectory, $true)
}

function Invoke-LabInfrastructureScenario {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [string] $LabRunId,

        [Parameter(Mandatory)]
        [ValidateSet('LAB-LS-001')]
        [string] $ScenarioId,

        [Parameter(Mandatory)]
        [pscustomobject] $Contract,

        [Parameter()]
        [string] $StateRoot = (Get-LabDefaultStateRoot)
    )

    if (
        $Contract.Runbook.RuntimeAction -ne 'MULTI_CONTAINER_LOG_SHIPPING' -or
        $Contract.Definition.TopologyId -ne 'CTR-PAIR' -or
        $Contract.Definition.ResourceProfile -ne 'Standard'
    ) {
        throw 'The infrastructure scenario contract is outside the implemented boundary.'
    }

    $paths = Initialize-LabRunState -LabRunId $LabRunId -StateRoot $StateRoot
    $state = Read-LabJsonFile -Path $paths.StatePath
    if ($state.LifecycleStatus -notin @(
            'TOPOLOGY_READY',
            'SCENARIO_COMPLETED',
            'SCENARIO_VALIDATED'
        )) {
        throw 'Infrastructure scenario execution requires a ready topology.'
    }
    if (
        [string] $state.TopologyId -ne 'CTR-PAIR' -or
        [string] $state.ResourceProfile -ne 'Standard' -or
        [int] $state.SqlVersion -notin @($Contract.Runbook.SqlVersions)
    ) {
        throw 'LAB-LS-001 requires a matching CTR-PAIR runtime.'
    }

    $registry = Read-LabJsonFile -Path $paths.RegistryPath
    $dockerCommand = Get-LabDockerCommand
    $primary = Get-LabInfrastructureContainerResource `
        -Registry $registry `
        -ResourceId SQL_PRIMARY_CONTAINER `
        -Role SQL_PRIMARY `
        -DockerCommand $dockerCommand `
        -LabRunId $LabRunId
    $secondary = Get-LabInfrastructureContainerResource `
        -Registry $registry `
        -ResourceId SQL_SECONDARY_CONTAINER `
        -Role SQL_SECONDARY `
        -DockerCommand $dockerCommand `
        -LabRunId $LabRunId

    $primaryServer = Invoke-LabContainerSqlScalar `
        -DockerCommand $dockerCommand `
        -ContainerId ([string] $primary.ExactLocator) `
        -Query "SET NOCOUNT ON; SELECT CONVERT(sysname, SERVERPROPERTY('ServerName'));"
    $secondaryServer = Invoke-LabContainerSqlScalar `
        -DockerCommand $dockerCommand `
        -ContainerId ([string] $secondary.ExactLocator) `
        -Query "SET NOCOUNT ON; SELECT CONVERT(sysname, SERVERPROPERTY('ServerName'));"
    foreach ($serverName in @($primaryServer, $secondaryServer)) {
        if ([string] $serverName -notmatch '^[A-Za-z0-9_.-]{1,128}$') {
            throw 'Infrastructure scenario resolved an invalid SQL Server name.'
        }
    }

    $scenarioDirectory = Copy-LabInfrastructureScenarioScripts `
        -Contract $Contract `
        -RunDirectory $paths.RunDirectory
    $transferDirectory = Initialize-LabScenarioTransferDirectory `
        -ScenarioDirectory $scenarioDirectory `
        -LabRunId $LabRunId `
        -ScenarioId $ScenarioId
    $containerDirectory = "/lab/runtime/scenarios/$ScenarioId"
    $variables = @{
        ScenarioId = $ScenarioId
        LabRunId = $LabRunId
        PrimaryServer = [string] $primaryServer
        SecondaryServer = [string] $secondaryServer
    }

    Set-LabRunState -StatePath $paths.StatePath -Changes @{
        LifecycleStatus = 'SCENARIO_RUNNING'
        ScenarioId = $ScenarioId
        ScenarioPhase = 'RESET'
        ScenarioTransferBoundary = $transferDirectory
    }

    $setupStarted = $false
    $operationError = $null
    $cleanupError = $null
    $scenarioResult = $null
    try {
        $secondaryCleanup = Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId ([string] $secondary.ExactLocator) `
            -ContainerSqlPath "$containerDirectory/Cleanup_Secondary.sql" `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds 300
        Test-LabCleanupOutput -ScenarioId $ScenarioId -CommandOutput $secondaryCleanup
        $primaryCleanup = Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId ([string] $primary.ExactLocator) `
            -ContainerSqlPath "$containerDirectory/Cleanup_Primary.sql" `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds 300
        Test-LabCleanupOutput -ScenarioId $ScenarioId -CommandOutput $primaryCleanup

        $setupStarted = $true
        Set-LabRunState -StatePath $paths.StatePath -Changes @{
            ScenarioPhase = 'SETUP_PRIMARY'
        }
        Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId ([string] $primary.ExactLocator) `
            -ContainerSqlPath "$containerDirectory/Setup_Primary.sql" `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds 600 |
            Out-Null

        Set-LabRunState -StatePath $paths.StatePath -Changes @{
            ScenarioPhase = 'SETUP_SECONDARY'
        }
        Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId ([string] $secondary.ExactLocator) `
            -ContainerSqlPath "$containerDirectory/Setup_Secondary.sql" `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds 600 |
            Out-Null

        $healthyVariables = @{} + $variables
        $healthyVariables.CycleOrdinal = '1'
        Set-LabRunState -StatePath $paths.StatePath -Changes @{
            ScenarioPhase = 'HEALTHY_BACKUP_COPY_RESTORE'
        }
        Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId ([string] $primary.ExactLocator) `
            -ContainerSqlPath "$containerDirectory/Primary_Backup_Cycle.sql" `
            -SqlCmdVariables $healthyVariables `
            -QueryTimeoutSeconds 180 |
            Out-Null
        Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId ([string] $secondary.ExactLocator) `
            -ContainerSqlPath "$containerDirectory/Secondary_Copy_Restore_Cycle.sql" `
            -SqlCmdVariables $variables `
            -QueryTimeoutSeconds 300 |
            Out-Null

        $baselinePrimary = ConvertFrom-LabPrefixedJson `
            -CommandOutput (Invoke-LabSqlFile `
                -DockerCommand $dockerCommand `
                -ContainerId ([string] $primary.ExactLocator) `
                -ContainerSqlPath "$containerDirectory/Observe_Primary.sql" `
                -SqlCmdVariables $variables `
                -QueryTimeoutSeconds 300) `
            -Prefix 'LAB_ANALYZER_JSON='
        $baselineSecondary = ConvertFrom-LabPrefixedJson `
            -CommandOutput (Invoke-LabSqlFile `
                -DockerCommand $dockerCommand `
                -ContainerId ([string] $secondary.ExactLocator) `
                -ContainerSqlPath "$containerDirectory/Observe_Secondary.sql" `
                -SqlCmdVariables $variables `
                -QueryTimeoutSeconds 300) `
            -Prefix 'LAB_ANALYZER_JSON='

        $lagVariables = @{} + $variables
        $lagVariables.CycleOrdinal = '2'
        Set-LabRunState -StatePath $paths.StatePath -Changes @{
            ScenarioPhase = 'VISIBLE_LAG_BACKUP_ONLY'
        }
        Invoke-LabSqlFile `
            -DockerCommand $dockerCommand `
            -ContainerId ([string] $primary.ExactLocator) `
            -ContainerSqlPath "$containerDirectory/Primary_Backup_Cycle.sql" `
            -SqlCmdVariables $lagVariables `
            -QueryTimeoutSeconds 180 |
            Out-Null

        $lagPrimary = ConvertFrom-LabPrefixedJson `
            -CommandOutput (Invoke-LabSqlFile `
                -DockerCommand $dockerCommand `
                -ContainerId ([string] $primary.ExactLocator) `
                -ContainerSqlPath "$containerDirectory/Observe_Primary.sql" `
                -SqlCmdVariables $variables `
                -QueryTimeoutSeconds 300) `
            -Prefix 'LAB_ANALYZER_JSON='
        $lagSecondary = ConvertFrom-LabPrefixedJson `
            -CommandOutput (Invoke-LabSqlFile `
                -DockerCommand $dockerCommand `
                -ContainerId ([string] $secondary.ExactLocator) `
                -ContainerSqlPath "$containerDirectory/Observe_Secondary.sql" `
                -SqlCmdVariables $variables `
                -QueryTimeoutSeconds 300) `
            -Prefix 'LAB_ANALYZER_JSON='

        $baselinePrimaryRow = @($baselinePrimary.logShipping.primary) | Select-Object -First 1
        $baselineSecondaryRow = @($baselineSecondary.logShipping.secondary) | Select-Object -First 1
        $lagPrimaryRow = @($lagPrimary.logShipping.primary) | Select-Object -First 1
        $lagSecondaryRow = @($lagSecondary.logShipping.secondary) | Select-Object -First 1
        $baselineBackupLeaf = Get-LabPathLeaf $baselinePrimaryRow.LastBackupFile
        $baselineCopiedLeaf = Get-LabPathLeaf $baselineSecondaryRow.LastCopiedFile
        $baselineRestoredLeaf = Get-LabPathLeaf $baselineSecondaryRow.LastRestoredFile
        $lagBackupLeaf = Get-LabPathLeaf $lagPrimaryRow.LastBackupFile
        $lagCopiedLeaf = Get-LabPathLeaf $lagSecondaryRow.LastCopiedFile
        $lagRestoredLeaf = Get-LabPathLeaf $lagSecondaryRow.LastRestoredFile

        $statusValues = @(
            [string] $baselinePrimary.logShipping.meta.statusCode
            [string] $baselineSecondary.logShipping.meta.statusCode
            [string] $lagPrimary.logShipping.meta.statusCode
            [string] $lagSecondary.logShipping.meta.statusCode
            [string] $lagPrimary.backupChain.meta.statusCode
            [string] $lagPrimary.infrastructure.meta.statusCode
        )
        if (@($statusValues | Where-Object { -not (Test-LabAnalyzerStatus $_) }).Count -gt 0) {
            throw 'LAB-LS-001 analyzer status is outside the accepted boundary.'
        }
        if (
            [string]::IsNullOrWhiteSpace($baselineBackupLeaf) -or
            $baselineBackupLeaf -ne $baselineCopiedLeaf -or
            $baselineBackupLeaf -ne $baselineRestoredLeaf
        ) {
            throw 'LAB-LS-001 did not prove a healthy backup-copy-restore cycle.'
        }
        if (
            [string]::IsNullOrWhiteSpace($lagBackupLeaf) -or
            $lagBackupLeaf -eq $baselineBackupLeaf -or
            $lagCopiedLeaf -ne $baselineCopiedLeaf -or
            $lagRestoredLeaf -ne $baselineRestoredLeaf -or
            $lagCopiedLeaf -ne $lagRestoredLeaf
        ) {
            throw 'LAB-LS-001 did not create the declared visible lag state.'
        }
        if (@($lagPrimary.backupChain.summary).Count -lt 1) {
            throw 'LAB-LS-001 did not expose backup-chain evidence.'
        }

        $scenarioResult = [pscustomobject] @{
            ScenarioId = $ScenarioId
            Status = 'PASS'
            AnalyzerStatus = [string] $lagPrimary.logShipping.meta.statusCode
            PrimaryAnalyzer = 'USP_LogShippingStatus'
            FindingCodes = @(
                'LOG_SHIPPING_HEALTHY_CYCLE_OBSERVED'
                'LOG_SHIPPING_LAG_VISIBLE'
                'BACKUP_CHAIN_VISIBLE'
            )
            ObservedValue = [pscustomobject] @{
                HealthyCycleFileMatched = $true
                LaterBackupPending = $true
                PrimaryStatus = [string] $lagPrimary.logShipping.meta.statusCode
                SecondaryStatus = [string] $lagSecondary.logShipping.meta.statusCode
                BackupChainStatus = [string] $lagPrimary.backupChain.meta.statusCode
                InfrastructureStatus = [string] $lagPrimary.infrastructure.meta.statusCode
            }
            AlternativeEvidenceUsed = $false
            ProductMajorVersion = @{ 2019 = 15; 2022 = 16; 2025 = 17 }[[int] $state.SqlVersion]
        }
    }
    catch {
        $operationError = $_
    }
    finally {
        if ($setupStarted) {
            try {
                Set-LabRunState -StatePath $paths.StatePath -Changes @{
                    ScenarioPhase = 'CLEANUP'
                }
                $secondaryCleanup = Invoke-LabSqlFile `
                    -DockerCommand $dockerCommand `
                    -ContainerId ([string] $secondary.ExactLocator) `
                    -ContainerSqlPath "$containerDirectory/Cleanup_Secondary.sql" `
                    -SqlCmdVariables $variables `
                    -QueryTimeoutSeconds 300
                Test-LabCleanupOutput -ScenarioId $ScenarioId -CommandOutput $secondaryCleanup
                $primaryCleanup = Invoke-LabSqlFile `
                    -DockerCommand $dockerCommand `
                    -ContainerId ([string] $primary.ExactLocator) `
                    -ContainerSqlPath "$containerDirectory/Cleanup_Primary.sql" `
                    -SqlCmdVariables $variables `
                    -QueryTimeoutSeconds 300
                Test-LabCleanupOutput -ScenarioId $ScenarioId -CommandOutput $primaryCleanup
                Remove-LabScenarioTransferDirectory `
                    -ScenarioDirectory $scenarioDirectory `
                    -TransferDirectory $transferDirectory `
                    -LabRunId $LabRunId `
                    -ScenarioId $ScenarioId
            }
            catch {
                $cleanupError = $_
            }
        }
    }

    if ($null -ne $cleanupError) {
        throw 'LAB-LS-001 cleanup failed inside the exact synthetic scope.'
    }
    if ($null -ne $operationError) {
        throw $operationError
    }
    if ($null -eq $scenarioResult) {
        throw 'LAB-LS-001 did not produce a scenario result.'
    }

    $result = Write-LabScenarioResult `
        -RunDirectory $paths.RunDirectory `
        -ScenarioId $ScenarioId `
        -Result $scenarioResult `
        -CleanupStatus PASS
    Set-LabRunState -StatePath $paths.StatePath -Changes @{
        LifecycleStatus = 'SCENARIO_COMPLETED'
        ScenarioId = $ScenarioId
        ScenarioStatus = $result.Status
        ScenarioCleanupStatus = $result.CleanupStatus
        ScenarioPhase = 'COMPLETED'
    }
    return $result
}
