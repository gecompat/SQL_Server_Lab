#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
$selector = Join-Path $repoRoot 'Tools/Get-CiTestSelection.ps1'

$docs = & $selector -ChangedPath @('Documentation/User/Getting_Started.md')
Add-CheckResult -Name 'Dokumentation loest keinen Runtime-Smoke aus' -Success (
    $docs.DocumentationOnly -and -not $docs.Docker -and -not $docs.Podman -and -not $docs.Mixed -and -not $docs.HyperV -and -not $docs.Adapter
)

$docker = & $selector -ChangedPath @('Providers/Docker/DockerProvider.ps1')
Add-CheckResult -Name 'Docker-Aenderung bleibt auf Docker begrenzt' -Success (
    $docker.Docker -and -not $docker.Podman -and -not $docker.Mixed -and -not $docker.HyperV -and -not $docker.Adapter
)

$hyperV = & $selector -ChangedPath @('Private/HyperVLabEnvironment.ps1')
Add-CheckResult -Name 'Hyper-V-Aenderung aktiviert Hyper-V-Vertraege und Runtime' -Success (
    $hyperV.HyperV -and 'Invoke-HyperVLabEnvironmentChecks.ps1' -in $hyperV.StaticChecks -and -not $hyperV.Docker
)

$externalRuntimeWindows = & $selector -ChangedPath @('Private/ExternalRuntimeWindows.ps1')
Add-CheckResult -Name 'Windows-External-Runtime-Aenderung aktiviert Katalog-, Gast- und Hyper-V-Vertraege' -Success (
    $externalRuntimeWindows.HyperV -and
    'Invoke-ExternalRuntimeWindowsChecks.ps1' -in $externalRuntimeWindows.StaticChecks -and
    'Invoke-SoftwareCatalogChecks.ps1' -in $externalRuntimeWindows.StaticChecks -and
    'Invoke-HyperVLabEnvironmentChecks.ps1' -in $externalRuntimeWindows.StaticChecks
)

$shared = & $selector -ChangedPath @('Private/Common.ps1')
Add-CheckResult -Name 'Unbekannte produktive Aenderung faellt sicher auf Docker zurueck' -Success $shared.Docker

$crossProvider = & $selector -ChangedPath @('Private/ProviderCapability.ps1')
Add-CheckResult -Name 'Provideruebergreifende Aenderung verwendet Mixed-Smoke' -Success $crossProvider.Mixed

$batchWorkflow = & $selector -ChangedPath @('Private/BatchWorkflow.ps1')
Add-CheckResult -Name 'Batch-Aenderung aktiviert Batch-Vertrag und repraesentativen Docker-Smoke' -Success (
    $batchWorkflow.Docker -and 'Invoke-BatchWorkflowChecks.ps1' -in $batchWorkflow.StaticChecks
)

$containerReconcile = & $selector -ChangedPath @('Private/ContainerReconcile.ps1')
Add-CheckResult -Name 'Container-Reconcile aktiviert Vertrag sowie Docker- und Podman-Akzeptanz' -Success (
    $containerReconcile.Docker -and $containerReconcile.Podman -and
    'Invoke-ContainerReconcileChecks.ps1' -in $containerReconcile.StaticChecks -and
    'Invoke-ContainerVolumeContractChecks.ps1' -in $containerReconcile.StaticChecks -and
    'Invoke-ReadinessContractChecks.ps1' -in $containerReconcile.StaticChecks
)

$containerTool = & $selector -ChangedPath @('Public/Test-SqlServerLabContainerTool.ps1')
Add-CheckResult -Name 'Container-Tool-Aenderung aktiviert getrennte Docker- und Podman-Akzeptanz' -Success (
    $containerTool.Docker -and $containerTool.Podman
)

$aiScenario = & $selector -ChangedPath @('Private/AiScenario.ps1', 'Scenarios/Ai/vector-core-ci/1.0/assert.sql')
Add-CheckResult -Name 'KI-Szenario-Aenderung aktiviert Vertrag sowie getrennte Docker-/Podman-Akzeptanz' -Success (
    $aiScenario.Docker -and $aiScenario.Podman -and
    'Invoke-AiScenarioChecks.ps1' -in $aiScenario.StaticChecks -and
    'Invoke-ManifestBuilderChecks.ps1' -in $aiScenario.StaticChecks -and
    'Invoke-ProviderCapabilityChecks.ps1' -in $aiScenario.StaticChecks
)

$bacpac = & $selector -ChangedPath @('Catalogs/sample-databases.json', 'Private/SampleArtifactHandlers.ps1')
Add-CheckResult -Name 'BACPAC-Aenderung aktiviert getrennte Docker- und Podman-Akzeptanz' -Success (
    $bacpac.Docker -and $bacpac.Podman
)

$containerInstanceStore = & $selector -ChangedPath @('Private/ContainerInstanceStore.ps1')
Add-CheckResult -Name 'Container-Instanzstore aktiviert Core-Verträge sowie getrennte Docker-/Podman-Nachweise' -Success (
    $containerInstanceStore.Docker -and $containerInstanceStore.Podman -and
    'Invoke-ContainerInstanceStoreChecks.ps1' -in $containerInstanceStore.StaticChecks -and
    'Invoke-ContainerVolumeContractChecks.ps1' -in $containerInstanceStore.StaticChecks
)

$containerRuntimeScope = & $selector -ChangedPath @('Private/ContainerRuntimeScope.ps1')
Add-CheckResult -Name 'Container-Runtime-Scope aktiviert read-only Vertrag sowie Docker-/Podman-Nachweise' -Success (
    $containerRuntimeScope.Docker -and $containerRuntimeScope.Podman -and
    'Invoke-ContainerRuntimeScopeChecks.ps1' -in $containerRuntimeScope.StaticChecks
)

$persistentStorageArtifact = & $selector -ChangedPath @('Public/Sync-SqlServerLabPersistentStorageArtifact.ps1')
Add-CheckResult -Name 'Reiner Persistent-Storage-Artefakt-Sync aktiviert nur die betroffenen statischen Verträge' -Success (
    -not $persistentStorageArtifact.Docker -and -not $persistentStorageArtifact.Podman -and
    -not $persistentStorageArtifact.Mixed -and -not $persistentStorageArtifact.HyperV -and -not $persistentStorageArtifact.Adapter -and
    'Invoke-PersistentStorageCatalogChecks.ps1' -in $persistentStorageArtifact.StaticChecks -and
    'Invoke-BackupLibraryChecks.ps1' -in $persistentStorageArtifact.StaticChecks -and
    'Invoke-DatabasePackageChecks.ps1' -in $persistentStorageArtifact.StaticChecks
)

$resourceSet = & $selector -ChangedPath @('Public/Save-SqlServerLabResourceSet.ps1', 'Private/ResourceSet.ps1')
Add-CheckResult -Name 'Resource-Prefetch aktiviert nur seine Store- und Katalogverträge' -Success (
    -not $resourceSet.Docker -and -not $resourceSet.Podman -and -not $resourceSet.Mixed -and
    -not $resourceSet.HyperV -and -not $resourceSet.Adapter -and
    'Invoke-ResourceSetChecks.ps1' -in $resourceSet.StaticChecks -and
    'Invoke-ArtifactResolverChecks.ps1' -in $resourceSet.StaticChecks -and
    'Invoke-ExternalRuntimeWindowsChecks.ps1' -in $resourceSet.StaticChecks
)

$hostToolResolution = & $selector -ChangedPath @('Private/HostToolResolution.ps1')
Add-CheckResult -Name 'Host-Tool-Auflösung aktiviert Resolver-/Bootstrap-Verträge und beide Container-Runtimes' -Success (
    $hostToolResolution.Docker -and $hostToolResolution.Podman -and
    'Invoke-HostToolResolutionChecks.ps1' -in $hostToolResolution.StaticChecks -and
    'Invoke-PodmanBootstrapChecks.ps1' -in $hostToolResolution.StaticChecks
)

$backupLibrary = & $selector -ChangedPath @('Private/BackupLibrary.ps1')
Add-CheckResult -Name 'Backup-Bibliothek aktiviert statischen Vertrag und providerübergreifenden Runtime-Nachweis' -Success (
    $backupLibrary.Mixed -and
    'Invoke-BackupLibraryChecks.ps1' -in $backupLibrary.StaticChecks -and
    'Invoke-DatabaseMigrationDependencyChecks.ps1' -in $backupLibrary.StaticChecks -and
    'Invoke-SampleBaselineRuntimeChecks.ps1' -in $backupLibrary.StaticChecks
)

$databasePackage = & $selector -ChangedPath @('Private/DatabasePackage.ps1')
Add-CheckResult -Name 'Datenbankpaket aktiviert Offline-Dateivertrag und Hyper-V-Runtime-Nachweis' -Success (
    $databasePackage.HyperV -and -not $databasePackage.Docker -and -not $databasePackage.Podman -and
    'Invoke-DatabasePackageChecks.ps1' -in $databasePackage.StaticChecks -and
    'Invoke-DatabaseMigrationDependencyChecks.ps1' -in $databasePackage.StaticChecks
)

$migrationDependency = & $selector -ChangedPath @('Private/DatabaseMigrationDependency.ps1')
Add-CheckResult -Name 'Migrationsabhaengigkeiten aktivieren Core-, Backup-/Package- und getrennte Runtime-Grenzen' -Success (
    $migrationDependency.Mixed -and $migrationDependency.HyperV -and
    'Invoke-DatabaseMigrationDependencyChecks.ps1' -in $migrationDependency.StaticChecks -and
    'Invoke-BackupLibraryChecks.ps1' -in $migrationDependency.StaticChecks -and
    'Invoke-DatabasePackageChecks.ps1' -in $migrationDependency.StaticChecks
)

$hyperVPersistentData = & $selector -ChangedPath @('Private/HyperVPersistentDataDrive.ps1')
Add-CheckResult -Name 'Hyper-V-Persistent-Data aktiviert eigenen Vertrag und nur den Hyper-V-Runtime-Nachweis' -Success (
    $hyperVPersistentData.HyperV -and -not $hyperVPersistentData.Docker -and -not $hyperVPersistentData.Podman -and
    'Invoke-HyperVPersistentDataDriveChecks.ps1' -in $hyperVPersistentData.StaticChecks -and
    'Invoke-HyperVProviderChecks.ps1' -in $hyperVPersistentData.StaticChecks
)

$ci = & $selector -ChangedPath @('.github/workflows/static-contracts.yml')
Add-CheckResult -Name 'CI-Infrastruktur prueft einmalig alle Runtime-Gates' -Success (
    $ci.Docker -and $ci.Podman -and $ci.Mixed -and $ci.HyperV -and $ci.Adapter
)

# Einzelpfade verhindern, dass ein zweiter Dateiname eine fehlende Abhaengigkeit verdeckt.
$dependencyCases = @(
    @{ Path = 'Private/CleanupEngine.ps1'; Checks = @('Invoke-CleanupRecoveryChecks.ps1','Invoke-CleanupAuditChecks.ps1','Invoke-CleanupVolumeOwnershipChecks.ps1'); Runtime = @('Docker','Podman','Mixed','HyperV','Adapter') },
    @{ Path = 'Tests/Integration/Invoke-AiVectorIndexAcceptance.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1','Invoke-ContainerVolumeContractChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Tests/Integration/Fixtures/VectorIndex/1.0/setup.sql'; Checks = @('Invoke-AiScenarioChecks.ps1','Invoke-ContainerVolumeContractChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Tests/Integration/Fixtures/VectorIndex/1.0/assert.sql'; Checks = @('Invoke-AiScenarioChecks.ps1','Invoke-ContainerVolumeContractChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Documentation/Quality/capability-evidence-index.json'; Checks = @('Invoke-CapabilityInventoryChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/capability-evidence-index.schema.json'; Checks = @('Invoke-CapabilityInventoryChecks.ps1'); Runtime = @() },
    @{ Path = 'Tools/Prepare-LocalRelease.ps1'; Checks = @('Invoke-ReleaseArtifactChecks.ps1','Invoke-ReleaseReadinessChecks.ps1'); Runtime = @() },
    @{ Path = 'Providers/HyperV/HyperVProvider.ps1'; Checks = @('Invoke-LabNetworkChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Private/SqlStorageOperations.ps1'; Checks = @('Invoke-SampleBaselineRuntimeChecks.ps1','Invoke-StorageFilePlacementChecks.ps1','Invoke-SessionTransferProgressChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Private/SessionTransferProgress.ps1'; Checks = @('Invoke-SampleBaselineRuntimeChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Private/AiEndpoint.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Public/Invoke-SqlServerLabAiRag.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Private/AiReembedding.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Schemas/ai-reembedding-plan.schema.json'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Private/StateUpgrade.ps1'; Checks = @('Invoke-RunStateUpgradeChecks.ps1'); Runtime = @() },
    @{ Path = 'Public/Get-SqlServerLabRunStateUpgradePlan.ps1'; Checks = @('Invoke-RunStateUpgradeChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/PortableLabImport.ps1'; Checks = @('Invoke-PortableLabImportChecks.ps1'); Runtime = @() },
    @{ Path = 'Public/Get-SqlServerLabEvaluationWatch.ps1'; Checks = @('Invoke-EvaluationWatchChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/SqlObservabilityEvidence.ps1'; Checks = @('Invoke-SqlObservabilityEvidenceChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Private/RecoveryPointPlan.ps1'; Checks = @('Invoke-HyperVRecoveryPointPlanChecks.ps1'); Runtime = @() }
)
foreach ($case in $dependencyCases) {
    foreach ($path in @($case.Path, $case.Path.Replace('/', '\'))) {
        $selected = & $selector -ChangedPath @($path)
        $missingChecks = @($case.Checks | Where-Object { $_ -notin $selected.StaticChecks })
        $missingRuntime = @($case.Runtime | Where-Object { -not $selected.$_ })
        Add-CheckResult -Name "Abhaengige Vertraege werden einzeln ausgewaehlt: $path" `
            -Success ($missingChecks.Count -eq 0 -and $missingRuntime.Count -eq 0) `
            -Message "Fehlende Suites: $($missingChecks -join ', '); fehlende Provider: $($missingRuntime -join ', ')"
    }
}

foreach ($companion in @('Private/ResourceSet.ps1', 'Providers/HyperV/HyperVProvider.ps1')) {
    $combined = & $selector -ChangedPath @($companion, 'Private/Common.ps1')
    Add-CheckResult -Name "Unbekannter Produktpfad behaelt seinen Docker-Fallback neben $companion" -Success $combined.Docker
}
$composed = & $selector -ChangedPath @('Private/AiEndpoint.ps1', 'Private/ResourceSet.ps1', 'Private/SqlStorageOperations.ps1')
$individualChecks = @('Private/AiEndpoint.ps1', 'Private/ResourceSet.ps1', 'Private/SqlStorageOperations.ps1' | ForEach-Object {
    (& $selector -ChangedPath @($_)).StaticChecks
} | Sort-Object -Unique)
Add-CheckResult -Name 'Mehrdateiauswahl erhaelt die Vereinigung aller Einzelvertraege' -Success (
    @($individualChecks | Where-Object { $_ -notin $composed.StaticChecks }).Count -eq 0 -and
    $composed.Docker -and $composed.Podman -and $composed.HyperV
)

$outputPath = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-ci-output-$([guid]::NewGuid().ToString('N')).txt"
try {
    $env:GITHUB_OUTPUT = $outputPath
    $null = & $selector -ChangedPath @('.github/workflows/static-contracts.yml') -WriteGitHubOutput
    $outputText = Get-Content -LiteralPath $outputPath -Raw -Encoding utf8
    Add-CheckResult -Name 'GitHub-Outputs verwenden exakte boolesche Kleinbuchstabenwerte' -Success (
        $outputText -match '(?m)^docker=true\r?$' -and $outputText -match '(?m)^hyperv=true\r?$' -and
        $outputText -notmatch 'ToLowerInvariant'
    )
}
finally {
    Remove-Item Env:GITHUB_OUTPUT -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
}

$allChecksText = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'Invoke-AllChecks.ps1') -Raw -Encoding utf8
Add-CheckResult -Name 'CI-Strategievertrag ist Teil der Vollregression' -Success ($allChecksText -match 'Invoke-CiStrategyChecks\.ps1')

$runtimeWorkflows = @(
    'runtime-smoke-docker.yml', 'runtime-smoke-podman.yml',
    'runtime-smoke-mixed-providers.yml', 'runtime-smoke-hyperv.yml'
)
$duplicates = @()
$unsafeCancellation = @()
foreach ($workflow in $runtimeWorkflows) {
    $text = Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/$workflow") -Raw -Encoding utf8
    if ($text -match 'Invoke-AllChecks\.ps1|name:\s*Static contracts') { $duplicates += $workflow }
    if ($text -notmatch '(?m)^\s{2}cancel-in-progress:\s*false\s*$') { $unsafeCancellation += $workflow }
}
Add-CheckResult -Name 'Runtime-Workflows wiederholen keine statische Vollregression' -Success ($duplicates.Count -eq 0) -Message ($duplicates -join ', ')
Add-CheckResult -Name 'Self-hosted Runtime-Workflows werden vor ihrem regulären Cleanup nicht hart abgebrochen' `
    -Success ($unsafeCancellation.Count -eq 0) -Message ($unsafeCancellation -join ', ')

$dockerWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-docker.yml') -Raw -Encoding utf8
$podmanWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-podman.yml') -Raw -Encoding utf8
$hyperVWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'Docker- und Podman-Gates enthalten den realen Batch-Smoke' -Success (
    $dockerWorkflow -match 'Invoke-BatchWorkflowSmokeTest\.ps1\s+`?\s*-Provider docker' -and
    $podmanWorkflow -match 'Invoke-BatchWorkflowSmokeTest\.ps1\s+`?\s*-Provider podman'
)
Add-CheckResult -Name 'Docker- und Podman-Gates enthalten die getrennte AI-Vector-Core-Abnahme' -Success (
    $dockerWorkflow -match 'Invoke-AiVectorCoreAcceptance\.ps1\s+`?\s*-Provider docker' -and
    $podmanWorkflow -match 'Invoke-AiVectorCoreAcceptance\.ps1\s+`?\s*-Provider podman'
)
Add-CheckResult -Name 'Hyper-V-Workflow bietet gezielten OS-Slot-Batch mit scopegebundenem Cleanup' -Success (
    $hyperVWorkflow -match '(?m)^\s*- slot-batch\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'slot-batch'" -and
    $hyperVWorkflow -match 'Sort-Object \{ \[datetime\]\$_\.registeredAt \} -Descending' -and
    $hyperVWorkflow -match 'Invoke-BatchWorkflowSmokeTest\.ps1\s+`' -and
    $hyperVWorkflow -match '(?m)^\s+-Provider hyperv\s+`' -and
    $hyperVWorkflow -match '-ArtifactId \$artifactId'
)
Add-CheckResult -Name 'Hyper-V-Workflow kann geschuetzte Testumgebungen gezielt reaktivieren und abnehmen' -Success (
    $hyperVWorkflow -match '(?m)^\s*- shared-environments\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'shared-environments'" -and
    $hyperVWorkflow -match 'Invoke-TestEnvironmentRuntimeReadiness\.ps1 -Recover' -and
    $hyperVWorkflow -match 'Invoke-TestEnvironmentAcceptance\.ps1'
)

$prWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/static-contracts.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'PR-Gate laeuft nicht erneut bei Push auf main' -Success ($prWorkflow -notmatch '(?m)^\s*push:\s*$')
Add-CheckResult -Name 'PR-Gate besitzt stabilen Abschlusscheck' -Success ($prWorkflow -match 'name:\s*PR Gate')
Add-CheckResult -Name 'PR-Gate reiht neue Revisionen hinter laufenden nativen Cleanups ein' -Success (
    $prWorkflow -match '(?m)^\s{2}cancel-in-progress:\s*false\s*$'
)
Add-CheckResult -Name 'PR-Gate schützt Self-hosted Runner vor Fork-Code' -Success (
    $prWorkflow -match 'pull_request\.head\.repo\.full_name == github\.repository'
)
Add-CheckResult -Name 'PR-Gate validiert betroffene Foundation-Aenderungen gegen den gebundenen Quellcommit' -Success (
    $prWorkflow -match '(?m)^\s{2}foundation-integrity:\s*$' -and
    $prWorkflow -match 'if:\s*needs\.classify\.outputs\.foundation == ''true''' -and
    $prWorkflow -match '\.ai/foundation-upgrade-assessments/' -and
    $prWorkflow -match 'repository:\s*gecompat/AI_Repository_Foundation' -and
    $prWorkflow -match 'ref:\s*8e27de7eb20926f340fbfb856eacd96d3099e5c8' -and
    $prWorkflow -match 'foundation_validator\.py' -and
    $prWorkflow -match '--adapters github-copilot' -and
    $prWorkflow -match '--capabilities rule-context-cache' -and
    $prWorkflow -match "foundation = '\$\{\{ needs\.foundation-integrity\.result \}\}'"
)

$nightly = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/nightly-regression.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'Nightly enthaelt Vollregression und taeglichen Zeitplan' -Success (
    $nightly -match 'Invoke-AllChecks\.ps1' -and $nightly -match '(?m)^\s*schedule:\s*$'
)

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
