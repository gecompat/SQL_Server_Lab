#Requires -Version 7.2
<#
.SYNOPSIS
    Ermittelt die fuer eine Aenderung erforderlichen PR-Pruefungen.
.DESCRIPTION
    Ordnet Repository-Pfade statischen Vertragssuites und gezielten Runtime-
    Smokes zu. Unbekannte produktive Aenderungen fallen sicher auf Docker als
    repraesentativen Runtime-Smoke zurueck. Die vollstaendige Regression bleibt
    dem Nightly-Workflow vorbehalten.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [AllowEmptyCollection()]
    [string[]]$ChangedPath,

    [switch]$AsJson,
    [switch]$WriteGitHubOutput
)

begin {
    $allPaths = [System.Collections.Generic.List[string]]::new()
}

process {
    foreach ($path in $ChangedPath) {
        if (-not [string]::IsNullOrWhiteSpace($path)) {
            $allPaths.Add(($path.Trim() -replace '\\', '/'))
        }
    }
}

end {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $checks = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $runtime = [ordered]@{ Docker = $false; Podman = $false; Mixed = $false; HyperV = $false; Adapter = $false }

    function Add-Check {
        param([Parameter(Mandatory)][string]$Name)
        $path = Join-Path $repoRoot "Tests/Static/$Name"
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            throw "CI_CHECK_NOT_FOUND: $Name"
        }
        [void]$checks.Add($Name)
    }

    function Test-AnyPath {
        param([Parameter(Mandatory)][string]$Pattern)
        return @($allPaths | Where-Object { $_ -match $Pattern }).Count -gt 0
    }

    $hasPowerShell = Test-AnyPath '\.(ps1|psm1|psd1)$'
    $hasProductCode = Test-AnyPath '^(Private|Public|Providers|Adapters|Catalogs|Schemas)/|^SqlServerLab\.(psd1|psm1)$'
    $docsOnly = $allPaths.Count -gt 0 -and -not $hasProductCode -and -not $hasPowerShell -and
        -not (Test-AnyPath '^\.github/workflows/')

    Add-Check 'Invoke-DocumentationChecks.ps1'
    Add-Check 'Invoke-PrivacyScannerChecks.ps1'
    if ($hasPowerShell -or $hasProductCode) {
        Add-Check 'Invoke-PSScriptAnalyzerChecks.ps1'
        Add-Check 'Invoke-PesterChecks.ps1'
    }

    $staticGroups = @(
        @{ Pattern = '(?i)(Cleanup|Remove-SqlServerLab|Clear-SqlServerLab)'; Checks = @('Invoke-CleanupRecoveryChecks.ps1','Invoke-CleanupAuditChecks.ps1') },
        @{ Pattern = '(?i)(BatchWorkflow|BatchConsole|lab-batch)'; Checks = @('Invoke-BatchWorkflowChecks.ps1') },
        @{ Pattern = '(?i)(ConsoleUi|Invoke-SqlServerLab\.ps1|Workflow)'; Checks = @('Invoke-ConsoleUiChecks.ps1','Invoke-WorkflowUiChecks.ps1') },
        @{ Pattern = '(?i)(ActionResult|Invoke-SqlServerLab\.ps1)'; Checks = @('Invoke-ActionResultChecks.ps1') },
        @{ Pattern = '(?i)(Elevation|Invoke-SqlServerLab\.ps1)'; Checks = @('Invoke-ElevationChecks.ps1') },
        @{ Pattern = '(?i)(ArtifactResolver|MediaSourceCatalog|SevenZip)'; Checks = @('Invoke-ArtifactResolverChecks.ps1','Invoke-MediaRootLayoutChecks.ps1') },
        @{ Pattern = '(?i)(ContainerAutoStart|Start-SqlServerLab|Stop-SqlServerLab|Restart-SqlServerLab)'; Checks = @('Invoke-ContainerAutoStartChecks.ps1') },
        @{ Pattern = '(?i)(DockerProvider|PodmanProvider|ContainerVolume)'; Checks = @('Invoke-ContainerVolumeContractChecks.ps1','Invoke-PortAllocationChecks.ps1') },
        @{ Pattern = '(?i)(LabNetwork|PortAllocation)'; Checks = @('Invoke-LabNetworkChecks.ps1','Invoke-PortAllocationChecks.ps1') },
        @{ Pattern = '(?i)(LabPreferences|PersistentLabData|StorageContract|StorageFilePlacement|lab-storage-(intent|bound-plan|runtime-receipt)|SecretProvider|TestEnvironment)'; Checks = @('Invoke-DataRootChecks.ps1','Invoke-StorageMigrationChecks.ps1','Invoke-StorageFilePlacementChecks.ps1','Invoke-TestEnvironmentChecks.ps1') },
        @{ Pattern = '(?i)(VersionCatalog|sql-server-versions)'; Checks = @('Invoke-VersionCatalogChecks.ps1') },
        @{ Pattern = '(?i)(SoftwareCatalog|software-catalog|Catalogs/software\.json)'; Checks = @('Invoke-SoftwareCatalogChecks.ps1','Invoke-ExternalRuntimeContainerImageChecks.ps1','Invoke-ExternalRuntimeWindowsChecks.ps1','Invoke-InstanceIntentChecks.ps1') },
        @{ Pattern = '(?i)(ContainerImageArtifact|ExternalRuntimeLifecycle|Images[\\/]ExternalLanguages|Providers[\\/](Docker|Podman)[\\/]|Public[\\/]New-SqlServerLab\.ps1)'; Checks = @('Invoke-ExternalRuntimeContainerImageChecks.ps1','Invoke-ExternalRuntimeWindowsChecks.ps1','Invoke-SoftwareCatalogChecks.ps1','Invoke-ReadinessContractChecks.ps1') },
        @{ Pattern = '(?i)(ExternalRuntimeReconcile|Invoke-ExternalRuntimeContainerAcceptance|Invoke-SqlServerLabReconcileAction)'; Checks = @('Invoke-ExternalRuntimeReconcileChecks.ps1','Invoke-ExternalRuntimeContainerImageChecks.ps1','Invoke-ReconcileContractChecks.ps1','Invoke-ReconcileActionContractChecks.ps1') },
        @{ Pattern = '(?i)(ExternalRuntimeWindows|Images[\\/]ExternalLanguages[\\/]Windows|ExternalRuntimeHyperVAcceptance)'; Checks = @('Invoke-ExternalRuntimeWindowsChecks.ps1','Invoke-SoftwareCatalogChecks.ps1','Invoke-HyperVLabEnvironmentChecks.ps1','Invoke-HyperVSqlImageBuilderChecks.ps1') },
        @{ Pattern = '(?i)(New-SqlServerLabDatabase|DatabaseCommand)'; Checks = @('Invoke-DatabaseCommandChecks.ps1') },
        @{ Pattern = '(?i)(SqlReadiness|Readiness)'; Checks = @('Invoke-ReadinessContractChecks.ps1') },
        @{ Pattern = '(?i)(DesiredState|ReconcileContract|Get-SqlServerLabReconcilePlan)'; Checks = @('Invoke-ReconcileContractChecks.ps1','Invoke-ReconcileActionContractChecks.ps1') },
        @{ Pattern = '(?i)(ProviderCapability|provider\.json)'; Checks = @('Invoke-ProviderCapabilityChecks.ps1') },
        @{ Pattern = '(?i)(InstanceIntent|ServerConfig|ResourceAssessment)'; Checks = @('Invoke-InstanceIntentChecks.ps1') },
        @{ Pattern = '(?i)(ManifestBuilder|ManifestParser|lab-manifest|New-SqlServerLabManifest)'; Checks = @('Invoke-ManifestBuilderChecks.ps1') },
        @{ Pattern = '(?i)(SampleArtifact|sample-databases)'; Checks = @('Invoke-SampleHandlerChecks.ps1','Invoke-SampleBaselineRegistryChecks.ps1','Invoke-SampleBaselineRuntimeChecks.ps1') },
        @{ Pattern = '(?i)(ProjectAdapter|Adapters/|project-adapter)'; Checks = @('Invoke-ProjectAdapterChecks.ps1') },
        @{ Pattern = '(?i)(MixedProvider|ProviderSubRun|StateMachine)'; Checks = @('Invoke-MixedProviderLifecycleChecks.ps1') },
        @{ Pattern = '(?i)(HyperVProvider|Providers/HyperV)'; Checks = @('Invoke-HyperVProviderChecks.ps1') },
        @{ Pattern = '(?i)(HyperVLabEnvironment)'; Checks = @('Invoke-HyperVLabEnvironmentChecks.ps1') },
        @{ Pattern = '(?i)(HyperVImageRegistry)'; Checks = @('Invoke-HyperVImageRegistryChecks.ps1') },
        @{ Pattern = '(?i)(HyperVImageBuilder)'; Checks = @('Invoke-HyperVImageBuilderChecks.ps1') },
        @{ Pattern = '(?i)(HyperVImageOperator)'; Checks = @('Invoke-HyperVImageOperatorChecks.ps1') },
        @{ Pattern = '(?i)(HyperVSqlImageBuilder)'; Checks = @('Invoke-HyperVSqlImageBuilderChecks.ps1') },
        @{ Pattern = '(?i)(HyperVSqlAcceptance)'; Checks = @('Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1') },
        @{ Pattern = '(?i)(HyperVWindowsBaseline)'; Checks = @('Invoke-HyperVWindowsBaselineAcceptanceChecks.ps1') }
    )
    foreach ($group in $staticGroups) {
        if (Test-AnyPath $group.Pattern) {
            foreach ($check in $group.Checks) { Add-Check $check }
        }
    }

    $orchestratorChecks = @('Invoke-AllChecks.ps1','Invoke-ImpactedChecks.ps1','Invoke-CiStrategyChecks.ps1')
    foreach ($testPath in @($allPaths | Where-Object { $_ -match '^Tests/Static/(Invoke-.+Checks\.ps1)$' })) {
        $checkName = [IO.Path]::GetFileName($testPath)
        if ($checkName -notin $orchestratorChecks) { Add-Check $checkName }
    }

    $ciInfrastructure = Test-AnyPath '^(\.github/workflows/(static-contracts|nightly-regression)|Tools/Get-CiTestSelection|Tests/Static/Invoke-CiStrategyChecks)'
    if ($ciInfrastructure) {
        $runtime.Docker = $true
        $runtime.Podman = $true
        $runtime.Mixed = $true
        $runtime.HyperV = $true
        $runtime.Adapter = $true
        Add-Check 'Invoke-CiStrategyChecks.ps1'
    }
    else {
        if (Test-AnyPath '(?i)(^Providers/Docker/|runtime-smoke-docker\.yml|Invoke-Smoke(Matrix|Test)|Invoke-RestoreSmokeTest|BatchWorkflow|BatchConsole|lab-batch)') { $runtime.Docker = $true }
        if (Test-AnyPath '(?i)(^Providers/Podman/|runtime-smoke-podman\.yml|PodmanBootstrap|Initialize-PodmanRuntime)') { $runtime.Podman = $true }
        if (Test-AnyPath '(?i)(ExternalRuntimeReconcile|Invoke-ExternalRuntimeContainerAcceptance|Invoke-SqlServerLabReconcileAction)') { $runtime.Docker = $true; $runtime.Podman = $true }
        if (Test-AnyPath '(?i)(runtime-smoke-mixed-providers\.yml|MixedProvider|ProviderCapability|DesiredState|ReconcileContract|ProviderSubRun)') { $runtime.Mixed = $true }
        if (Test-AnyPath '(?i)(^Providers/HyperV/|runtime-smoke-hyperv\.yml|/HyperV|^Private/HyperV|HyperVSmokeTest|^Private/ExternalRuntimeWindows|Images/ExternalLanguages/Windows|ExternalRuntimeHyperVAcceptance)') { $runtime.HyperV = $true }
        if (Test-AnyPath '(?i)(^Adapters/|ProjectAdapter|adapter-smoke|project-adapter)') { $runtime.Adapter = $true }

        $knownDomainChange = $runtime.Docker -or $runtime.Podman -or $runtime.Mixed -or $runtime.HyperV -or $runtime.Adapter
        if ($hasProductCode -and -not $knownDomainChange) {
            $runtime.Docker = $true
        }
    }

    $selection = [pscustomobject]@{
        ChangedPaths = @($allPaths)
        DocumentationOnly = $docsOnly
        StaticChecks = @($checks | Sort-Object)
        Docker = [bool]$runtime.Docker
        Podman = [bool]$runtime.Podman
        Mixed = [bool]$runtime.Mixed
        HyperV = [bool]$runtime.HyperV
        Adapter = [bool]$runtime.Adapter
    }

    if ($WriteGitHubOutput) {
        if (-not $env:GITHUB_OUTPUT) { throw 'GITHUB_OUTPUT_NOT_SET' }
        foreach ($name in @('Docker','Podman','Mixed','HyperV','Adapter')) {
            $value = ([string]$selection.$name).ToLowerInvariant()
            "$($name.ToLowerInvariant())=$value" |
                Out-File -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8 -Append
        }
        $documentationOnly = ([string]$selection.DocumentationOnly).ToLowerInvariant()
        "documentation_only=$documentationOnly" |
            Out-File -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8 -Append
    }

    if ($AsJson) { return ($selection | ConvertTo-Json -Depth 5 -Compress) }
    return $selection
}
