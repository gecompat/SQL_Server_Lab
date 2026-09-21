#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
. (Join-Path $PSScriptRoot '..\Common\CheckResult.ps1')

$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
$selector = Join-Path $repoRoot 'Tools/Get-CiTestSelection.ps1'
foreach($setupPath in @('Private/AiPodmanSetup.ps1','Private/AiPodmanSetupProcess.ps1','Tools/Invoke-AiPodmanSetupWorker.ps1','Schemas/ai-podman-setup.schema.json','Tests/Integration/Invoke-AiPodmanSetupAcceptance.ps1')) {
    foreach($path in @($setupPath,$setupPath.Replace('/','\'))) {
        $selected=& $selector -ChangedPath @($path)
        Add-CheckResult -Name "KI-Erstellung bleibt je Einzelpfad Podman: $path" -Success (
            $selected.Podman -and -not $selected.Docker -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter -and
            'Invoke-AiPodmanSetupChecks.ps1' -in $selected.StaticChecks -and 'Invoke-AiPodmanSetupProcessChecks.ps1' -in $selected.StaticChecks)
    }
}
foreach($referencePath in @('Tests/Integration/Invoke-AiPodmanSamplesReferenceAcceptance.ps1','Tests\\Integration\\Invoke-AiPodmanSamplesReferenceAcceptance.ps1',
    'Tests/Integration/Support/Invoke-AiPodmanSamplesReferenceWorker.ps1','Tests/Common/AiPodmanSamplesReferenceScenario.ps1','Tests/Common/AiPodmanSamplesReferenceSupervisor.ps1')) {
    $selected = & $selector -ChangedPath @($referencePath)
    Add-CheckResult -Name "Podman-Sample-Referenz bleibt providergebunden: $referencePath" -Success (
        $selected.Podman -and -not $selected.Docker -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter -and
        'Invoke-AiPodmanSamplesReferenceChecks.ps1' -in $selected.StaticChecks)
}
$setupShared=& $selector -ChangedPath @('Private/AiPodmanSetup.ps1','Private/AiEndpoint.ps1')
Add-CheckResult -Name 'Podman-Erstellung unterdrückt keine gemeinsame KI-Providerprüfung' -Success ($setupShared.Docker -and $setupShared.Podman -and $setupShared.HyperV)
$setupInfrastructure=& $selector -ChangedPath @('Private/AiPodmanSetup.ps1','Tools/Get-CiTestSelection.ps1')
Add-CheckResult -Name 'Podman-Erstellung ändert die volle Infrastrukturmatrix nicht' -Success ($setupInfrastructure.Docker -and $setupInfrastructure.Podman -and $setupInfrastructure.HyperV -and $setupInfrastructure.Mixed -and $setupInfrastructure.Adapter)

$docs = & $selector -ChangedPath @('Documentation/User/Getting_Started.md')
Add-CheckResult -Name 'Dokumentation loest keinen Runtime-Smoke aus' -Success (
    $docs.DocumentationOnly -and -not $docs.Docker -and -not $docs.Podman -and -not $docs.Mixed -and -not $docs.HyperV -and -not $docs.Adapter
)

$docker = & $selector -ChangedPath @('Providers/Docker/DockerProvider.ps1')
Add-CheckResult -Name 'Docker-Aenderung bleibt auf Docker begrenzt' -Success (
    $docker.Docker -and -not $docker.Podman -and -not $docker.Mixed -and -not $docker.HyperV -and -not $docker.Adapter
)

$hyperV = & $selector -ChangedPath @('Private/HyperVLabEnvironment.ps1')
foreach($bridgePath in @('Private/AiSqlHttpsBridge.ps1','Schemas/ai-sql-https-bridge-receipt.schema.json','Tests/Integration/Invoke-AiSqlHttpsBridgeAcceptance.ps1','Tests/Integration/Support/Invoke-AiSqlHttpsBridgeServer.ps1')) {
    foreach($path in @($bridgePath,$bridgePath.Replace('/','\'))) {
        $selected = & $selector -ChangedPath @($path)
        Add-CheckResult -Name "SQL-HTTPS-Referenz bleibt Docker-only: $path" -Success (
            'Invoke-AiSqlHttpsBridgeChecks.ps1' -in $selected.StaticChecks -and $selected.Docker -and
            -not $selected.Podman -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter)
    }
}
$bridgeShared = & $selector -ChangedPath @('Private/AiSqlHttpsBridge.ps1','Private/AiEndpoint.ps1')
Add-CheckResult -Name 'SQL-HTTPS-Ausnahme unterdrückt keine gemeinsame AI-Änderung' -Success ($bridgeShared.Docker -and $bridgeShared.Podman -and $bridgeShared.HyperV)
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
foreach ($assessmentPath in @('Private/ResourceAssessment.ps1','Private/ResourceAssessmentDecision.ps1','Schemas/resource-assessment-record.schema.json')) {
    foreach ($path in @($assessmentPath,$assessmentPath.Replace('/','\'))) {
        $selected = & $selector -ChangedPath @($path)
        Add-CheckResult -Name "Assessment bindet gemeinsame Erstellung und separate Provider: $path" -Success (
            'Invoke-ResourceAssessmentChecks.ps1' -in $selected.StaticChecks -and
            $selected.Docker -and $selected.Podman -and $selected.HyperV -and $selected.Mixed)
    }
}
foreach ($faultPath in @('Private/ContainerMemoryFault.ps1','Schemas/container-memory-fault-target.schema.json','Schemas/container-memory-fault-journal.schema.json','Tests/Integration/Invoke-ContainerMemoryFaultAcceptance.ps1')) {
    foreach ($path in @($faultPath,$faultPath.Replace('/','\'))) {
        $selected = & $selector -ChangedPath @($path)
        Add-CheckResult -Name "Memory-Fault waehlt getrennte Containerprovider: $path" -Success (
            'Invoke-ContainerMemoryFaultChecks.ps1' -in $selected.StaticChecks -and
            $selected.Docker -and $selected.Podman -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter)
    }
}
$memoryTransport = & $selector -ChangedPath @('Private/ContainerCpuFault.ps1')
Add-CheckResult -Name 'CPU-Transportaenderung prueft auch den Memory-Consumer' -Success ('Invoke-ContainerMemoryFaultChecks.ps1' -in $memoryTransport.StaticChecks)
foreach ($faultPath in @('Private/ContainerCpuFault.ps1','Schemas/container-cpu-fault-target.schema.json','Schemas/container-cpu-fault-journal.schema.json','Tests/Integration/Invoke-ContainerCpuFaultAcceptance.ps1')) {
    foreach ($path in @($faultPath,$faultPath.Replace('/','\'))) {
        $selected = & $selector -ChangedPath @($path)
        Add-CheckResult -Name "CPU-Fault waehlt getrennte Containerprovider: $path" -Success (
            'Invoke-ContainerCpuFaultChecks.ps1' -in $selected.StaticChecks -and
            $selected.Docker -and $selected.Podman -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter)
    }
}
foreach ($scenarioPath in @('Private/ScenarioExecutor.ps1','Schemas/scenario-execution-plan.schema.json','Schemas/scenario-execution-journal.schema.json','Tests/Fixtures/ScenarioExecutor/Invoke-InterruptedFixture.ps1')) {
    $selected = & $selector -ChangedPath @($scenarioPath)
    Add-CheckResult -Name "Synthetischer interner Executor bleibt providerlos: $scenarioPath" -Success (
        'Invoke-ScenarioExecutorChecks.ps1' -in $selected.StaticChecks -and
        'Invoke-ScenarioContractChecks.ps1' -in $selected.StaticChecks -and
        -not $selected.Docker -and -not $selected.Podman -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter)
}
$scenarioMixed = & $selector -ChangedPath @('Private/ScenarioExecutor.ps1','Private/UnknownScenarioExecutor.ps1')
Add-CheckResult -Name 'Synthetischer Executor unterdrueckt keinen unbekannten produktiven Runtime-Fallback' -Success $scenarioMixed.Docker
foreach ($capabilityPath in @('Private/ScenarioCapabilityDecision.ps1','Schemas/scenario-capability-plan.schema.json','Schemas/scenario-capability-decision.schema.json')) {
    foreach ($path in @($capabilityPath,$capabilityPath.Replace('/','\'))) {
        $selected = & $selector -ChangedPath @($path)
        Add-CheckResult -Name "Capability-Entscheidung bleibt providerlos: $path" -Success (
            'Invoke-ScenarioCapabilityDecisionChecks.ps1' -in $selected.StaticChecks -and
            'Invoke-ScenarioContractChecks.ps1' -in $selected.StaticChecks -and
            -not $selected.Docker -and -not $selected.Podman -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter)
    }
}
$capabilityMixed = & $selector -ChangedPath @('Private/ScenarioCapabilityDecision.ps1','Private/UnknownScenarioCapabilityDecision.ps1')
Add-CheckResult -Name 'Capability-Entscheidung unterdrueckt keinen unbekannten Runtime-Fallback' -Success $capabilityMixed.Docker
$capabilityConsumer = & $selector -ChangedPath @('Schemas/scenario-contract.schema.json')
Add-CheckResult -Name 'SCN-801-Aenderung prueft Capability-Consumer mit' -Success ('Invoke-ScenarioCapabilityDecisionChecks.ps1' -in $capabilityConsumer.StaticChecks)
foreach ($securityPath in @('Private/SecurityToolCatalog.ps1','Public/Get-SqlServerLabSecurityToolPlan.ps1',
    'Catalogs/security-tools.json','Schemas/security-tool-catalog.schema.json','Schemas/security-tool-request.schema.json',
    'Schemas/security-tool-plan.schema.json','Tests/Fixtures/SecurityTools/catalog.json')) {
    foreach ($path in @($securityPath,$securityPath.Replace('/','\'))) {
        $selected = & $selector -ChangedPath @($path)
        Add-CheckResult -Name "Security-Tool-Metadatenpfad bleibt statisch: $path" -Success (
            'Invoke-SecurityToolCatalogChecks.ps1' -in $selected.StaticChecks -and
            -not $selected.Docker -and -not $selected.Podman -and -not $selected.HyperV -and -not $selected.Mixed -and -not $selected.Adapter)
    }
}
$securityMixed = & $selector -ChangedPath @('Private/SecurityToolCatalog.ps1','Private/UnknownSecurityToolExecutor.ps1')
Add-CheckResult -Name 'Metadatenpfad unterdrueckt keinen unbekannten produktiven Runtime-Fallback' -Success $securityMixed.Docker
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

$transferPreflight = & $selector -ChangedPath @('Private/PortableContainerTransferPreflight.ps1')
Add-CheckResult -Name 'Transfer-Staging-Preflight aktiviert seinen Vertrag und getrennte Container-Nachweise' -Success (
    $transferPreflight.Docker -and $transferPreflight.Podman -and
    'Invoke-PortableContainerTransferPreflightChecks.ps1' -in $transferPreflight.StaticChecks -and
    'Invoke-PortableContainerTransferExecutorChecks.ps1' -in $transferPreflight.StaticChecks
)

$transferRuntime = & $selector -ChangedPath @('Private/PortableContainerTransferExecutorRuntime.ps1')
Add-CheckResult -Name 'Ein-Datenbank-Transferexecutor aktiviert seine Runtime- und Inhaltsvertraege nur fuer Docker und Podman' -Success (
    $transferRuntime.Docker -and $transferRuntime.Podman -and
    -not $transferRuntime.Mixed -and -not $transferRuntime.HyperV -and -not $transferRuntime.Adapter -and
    'Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1' -in $transferRuntime.StaticChecks -and
    'Invoke-RelationalCoreComparisonChecks.ps1' -in $transferRuntime.StaticChecks
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
    @{ Path = 'Private/CleanupEngine.ps1'; Checks = @('Invoke-CleanupRecoveryChecks.ps1','Invoke-MixedCleanupRecoveryChecks.ps1','Invoke-CleanupAuditChecks.ps1','Invoke-CleanupVolumeOwnershipChecks.ps1'); Runtime = @('Docker','Podman','Mixed','HyperV','Adapter') },
    @{ Path = 'Tools/Remove-HyperVOrphanWithOwnedStorage.ps1'; Checks = @('Invoke-HyperVOrphanCleanupToolChecks.ps1'); Runtime = @() },
    @{ Path = 'Tests/Integration/Invoke-AiVectorIndexAcceptance.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1','Invoke-ContainerVolumeContractChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Tests/Integration/Fixtures/VectorIndex/1.0/setup.sql'; Checks = @('Invoke-AiScenarioChecks.ps1','Invoke-ContainerVolumeContractChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Tests/Integration/Fixtures/VectorIndex/1.0/assert.sql'; Checks = @('Invoke-AiScenarioChecks.ps1','Invoke-ContainerVolumeContractChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Documentation/Quality/capability-evidence-index.json'; Checks = @('Invoke-CapabilityInventoryChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/capability-evidence-index.schema.json'; Checks = @('Invoke-CapabilityInventoryChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/HyperVSqlAcceptanceEnvironment.ps1'; Checks = @('Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1','Invoke-BlockingActionProgressChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Tools/Prepare-LocalRelease.ps1'; Checks = @('Invoke-ReleaseArtifactChecks.ps1','Invoke-ReleaseReadinessChecks.ps1'); Runtime = @() },
    @{ Path = 'Providers/HyperV/HyperVProvider.ps1'; Checks = @('Invoke-LabNetworkChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Private/SqlStorageOperations.ps1'; Checks = @('Invoke-SampleBaselineRuntimeChecks.ps1','Invoke-StorageFilePlacementChecks.ps1','Invoke-SessionTransferProgressChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Tests/Integration/Invoke-HyperVResourceReconcileAcceptance.ps1'; Checks = @('Invoke-HyperVResourceReconcileChecks.ps1','Invoke-HyperVResourceReconcileAcceptanceChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Tests/Integration/Invoke-HyperVResourceReconcileCiAcceptance.ps1'; Checks = @('Invoke-HyperVResourceReconcileAcceptanceChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Tests/Integration/Invoke-HyperVStorageReconcileAcceptance.ps1'; Checks = @('Invoke-HyperVStorageReconcileChecks.ps1','Invoke-HyperVStorageReconcileAcceptanceChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Tests/Integration/Invoke-HyperVSqlStorageReconcileAcceptance.ps1'; Checks = @('Invoke-HyperVStorageReconcileChecks.ps1','Invoke-HyperVSqlStorageReconcileChecks.ps1','Invoke-HyperVSqlStorageReconcileAcceptanceChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Tests/Integration/Invoke-HyperVSampleManifestAcceptance.ps1'; Checks = @('Invoke-HyperVSampleManifestAcceptanceChecks.ps1','Invoke-SampleHandlerChecks.ps1','Invoke-SampleBaselineRegistryChecks.ps1','Invoke-SampleBaselineRuntimeChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Private/SessionTransferProgress.ps1'; Checks = @('Invoke-SampleBaselineRuntimeChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Private/AiEndpoint.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Public/Invoke-SqlServerLabAiRag.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Private/AiReembedding.ps1'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Schemas/ai-reembedding-plan.schema.json'; Checks = @('Invoke-AiScenarioChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Private/StateUpgrade.ps1'; Checks = @('Invoke-RunStateUpgradeChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/StateMachine.ps1'; Checks = @('Invoke-RunStateUpgradeChecks.ps1','Invoke-MixedProviderLifecycleChecks.ps1'); Runtime = @() },
    @{ Path = 'Public/Get-SqlServerLabRunStateUpgradePlan.ps1'; Checks = @('Invoke-RunStateUpgradeChecks.ps1'); Runtime = @() },
    @{ Path = 'Public/Invoke-SqlServerLabRunStateUpgrade.ps1'; Checks = @('Invoke-RunStateUpgradeChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/CollationCatalog.ps1'; Checks = @('Invoke-CollationCatalogChecks.ps1','Invoke-VersionCatalogChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/CollationRuntimeEvidence.ps1'; Checks = @('Invoke-CollationRuntimeEvidenceChecks.ps1','Invoke-CollationCatalogChecks.ps1','Invoke-VersionCatalogChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Tests/Integration/Invoke-ContainerCollationAcceptance.ps1'; Checks = @('Invoke-CollationRuntimeEvidenceChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Public/Find-SqlServerLabCollation.ps1'; Checks = @('Invoke-CollationCatalogChecks.ps1'); Runtime = @() },
    @{ Path = 'Catalogs/sql-server-collations.json'; Checks = @('Invoke-CollationCatalogChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/sql-server-collation-catalog.schema.json'; Checks = @('Invoke-CollationCatalogChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/ManifestParser.ps1'; Checks = @('Invoke-CollationCatalogChecks.ps1','Invoke-ManifestBuilderChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/ManifestBuilder.ps1'; Checks = @('Invoke-CollationCatalogChecks.ps1','Invoke-ManifestBuilderChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/InstanceCapabilityAssessment.ps1'; Checks = @('Invoke-InstanceCapabilityAssessmentChecks.ps1','Invoke-InstanceIntentChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/instance-capability-assessment.schema.json'; Checks = @('Invoke-InstanceCapabilityAssessmentChecks.ps1','Invoke-InstanceIntentChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/DesiredState.ps1'; Checks = @('Invoke-InstanceCapabilityAssessmentChecks.ps1','Invoke-InstanceIntentChecks.ps1','Invoke-ReconcileContractChecks.ps1','Invoke-PersistedSoftwareIntentChecks.ps1','Invoke-HyperVResourceReconcileChecks.ps1'); Runtime = @('Mixed') },
    @{ Path = 'Private/VersionCatalog.ps1'; Checks = @('Invoke-ManifestBuilderChecks.ps1','Invoke-InstanceCapabilityAssessmentChecks.ps1'); Runtime = @() },
    @{ Path = 'Catalogs/sql-server-versions.json'; Checks = @('Invoke-ManifestBuilderChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/lab-manifest.schema.json'; Checks = @('Invoke-CollationCatalogChecks.ps1'); Runtime = @() },
    @{ Path = 'Public/New-SqlServerLab.ps1'; Checks = @('Invoke-CollationCatalogChecks.ps1','Invoke-CollationRuntimeEvidenceChecks.ps1','Invoke-HyperVSqlConfigurationReconcileChecks.ps1','Invoke-ReconcileActionContractChecks.ps1','Invoke-InstanceIntentChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Public/Invoke-SqlServerLab.ps1'; Checks = @('Invoke-CollationCatalogChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/ConsoleHelp.ps1'; Checks = @('Invoke-ConsoleUiChecks.ps1','Invoke-WorkflowUiChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/PortableLabImport.ps1'; Checks = @('Invoke-PortableLabImportChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/PortableContainerTransferExecutor.ps1'; Checks = @('Invoke-PortableContainerTransferExecutorChecks.ps1'); Runtime = @() },
    @{ Path = 'Public/Get-SqlServerLabPortableContainerTransferExecutorPlan.ps1'; Checks = @('Invoke-PortableContainerTransferExecutorChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/portable-container-transfer-executor-plan.schema.json'; Checks = @('Invoke-PortableContainerTransferExecutorChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/portable-container-transfer-executor-journal.schema.json'; Checks = @('Invoke-PortableContainerTransferExecutorChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/PortableContainerTransferExecutorRuntime.ps1'; Checks = @('Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1','Invoke-RelationalCoreComparisonChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Public/Invoke-SqlServerLabPortableContainerTransfer.ps1'; Checks = @('Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1','Invoke-RelationalCoreComparisonChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Schemas/portable-container-transfer-journal.schema.json'; Checks = @('Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1','Invoke-RelationalCoreComparisonChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Tests/Integration/Invoke-PortableContainerTransferAcceptance.ps1'; Checks = @('Invoke-PortableContainerTransferExecutorRuntimeChecks.ps1','Invoke-RelationalCoreComparisonChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Private/PortableContainerTransferPreflight.ps1'; Checks = @('Invoke-PortableContainerTransferPreflightChecks.ps1','Invoke-PortableContainerTransferExecutorChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Public/Invoke-SqlServerLabPortableContainerTransferPreflight.ps1'; Checks = @('Invoke-PortableContainerTransferPreflightChecks.ps1','Invoke-PortableContainerTransferExecutorChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Schemas/portable-container-transfer-preflight-request.schema.json'; Checks = @('Invoke-PortableContainerTransferPreflightChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Schemas/portable-container-transfer-preflight-result.schema.json'; Checks = @('Invoke-PortableContainerTransferPreflightChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Schemas/portable-container-transfer-preflight-journal.schema.json'; Checks = @('Invoke-PortableContainerTransferPreflightChecks.ps1'); Runtime = @('Docker','Podman') },
    @{ Path = 'Public/Get-SqlServerLabEvaluationWatch.ps1'; Checks = @('Invoke-EvaluationWatchChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/SqlGuestEvaluationEvidence.ps1'; Checks = @('Invoke-EvaluationWatchChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/SqlGuestEvaluationCapture.ps1'; Checks = @('Invoke-SqlGuestEvaluationCaptureChecks.ps1','Invoke-EvaluationWatchChecks.ps1','Invoke-HyperVGuestProgressChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Public/Update-SqlServerLabSqlGuestEvaluationEvidence.ps1'; Checks = @('Invoke-SqlGuestEvaluationCaptureChecks.ps1','Invoke-EvaluationWatchChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Tests/Integration/Invoke-SqlGuestEvaluationCaptureAcceptance.ps1'; Checks = @('Invoke-SqlGuestEvaluationCaptureChecks.ps1'); Runtime = @('HyperV') },
    @{ Path = 'Schemas/sql-guest-evaluation-evidence.schema.json'; Checks = @('Invoke-EvaluationWatchChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/SqlObservabilityEvidence.ps1'; Checks = @('Invoke-SqlObservabilityEvidenceChecks.ps1'); Runtime = @('Docker','Podman','HyperV') },
    @{ Path = 'Private/RecoveryPointPlan.ps1'; Checks = @('Invoke-HyperVRecoveryPointPlanChecks.ps1'); Runtime = @() },
    @{ Path = 'Private/AutomationApiPlan.ps1'; Checks = @('Invoke-AutomationApiPlanChecks.ps1'); Runtime = @() },
    @{ Path = 'Public/Get-SqlServerLabAutomationPlan.ps1'; Checks = @('Invoke-AutomationApiPlanChecks.ps1'); Runtime = @() },
    @{ Path = 'Schemas/automation-api-plan.schema.json'; Checks = @('Invoke-AutomationApiPlanChecks.ps1'); Runtime = @() }
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
Add-CheckResult -Name 'Docker- und Podman-Gates enthalten die getrennte Collation-Akzeptanz' -Success (
    $dockerWorkflow -match 'Invoke-ContainerCollationAcceptance\.ps1\s+`?\s*-Provider docker' -and
    $podmanWorkflow -match 'Invoke-ContainerCollationAcceptance\.ps1\s+`?\s*-Provider podman'
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
Add-CheckResult -Name 'Hyper-V-Workflow fuehrt SQL-Konfigurations-Reconcile nur im exakten Akzeptanzmodus aus' -Success (
    $hyperVWorkflow -match '(?m)^\s*- sql-configuration-reconcile-acceptance\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'sql-configuration-reconcile-acceptance'" -and
    $hyperVWorkflow -match 'Invoke-HyperVSqlConfigurationReconcileAcceptance\.ps1 @arguments' -and
    $hyperVWorkflow -match '\$arguments\.ArtifactId = \$artifactId'
)
Add-CheckResult -Name 'Hyper-V-Workflow bindet SQL-Gast-Capture nur an manuellen Same-Repo-Dispatch mit explizitem Artifact und optionalem State Root' -Success (
    $hyperVWorkflow -match '(?m)^\s*- sql-guest-evaluation-capture-acceptance\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'sql-guest-evaluation-capture-acceptance'" -and
    $hyperVWorkflow -match 'SQL_GUEST_CAPTURE_MANUAL_DISPATCH_REQUIRED' -and
    $hyperVWorkflow -match 'SQL_GUEST_CAPTURE_EXPLICIT_ARTIFACT_REQUIRED' -and
    $hyperVWorkflow -match 'github\.event_name == ''workflow_dispatch'' && github\.event\.repository\.full_name == github\.repository' -and
    $hyperVWorkflow -match 'capture_state_root:' -and
    $hyperVWorkflow -match 'SQL_GUEST_CAPTURE_STATE_ROOT' -and
    $hyperVWorkflow -match 'Invoke-SqlGuestEvaluationCaptureAcceptance\.ps1 -ArtifactId \$env:SQL_GUEST_CAPTURE_ARTIFACT_ID -StateRoot \$env:SQL_GUEST_CAPTURE_STATE_ROOT'
)
Add-CheckResult -Name 'Hyper-V-Workflow fuehrt SQL-Port-Reconcile nur im exakten Akzeptanzmodus aus' -Success (
    $hyperVWorkflow -match '(?m)^\s*- sql-port-reconcile-acceptance\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'sql-port-reconcile-acceptance'" -and
    $hyperVWorkflow -match 'Invoke-HyperVSqlPortReconcileAcceptance\.ps1 @arguments' -and
    $hyperVWorkflow -match '\$arguments\.ArtifactId = \$artifactId'
)
Add-CheckResult -Name 'Hyper-V-KI-Abnahme bleibt explizit manuell mit Artifact und read-only Vorprüfung' -Success (
    $hyperVWorkflow -match '(?m)^\s*- ai-rag-own-run-acceptance\s*$' -and
    $hyperVWorkflow -match 'AI_HYPERV_MANUAL_DISPATCH_REQUIRED' -and
    $hyperVWorkflow -match 'AI_HYPERV_EXPLICIT_ARTIFACT_REQUIRED' -and
    $hyperVWorkflow -match 'github\.event\.repository\.full_name == github\.repository' -and
    $hyperVWorkflow -match 'inputs\.ai_preflight_only == false' -and
    $hyperVWorkflow -match 'Invoke-AiHyperVOwnRunAcceptance\.ps1 -ArtifactId .* -PreflightOnly' -and
    $hyperVWorkflow -match 'SQL_SERVER_LAB_CI_AI_STATE_ROOT'
)

Add-CheckResult -Name 'Hyper-V-Workflow fuehrt Ressourcen-Reconcile-Akzeptanz nur manuell auf main mit kontrolliertem Artifact-Input aus' -Success (
    $hyperVWorkflow -match '(?m)^\s*- resource-reconcile-acceptance\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'resource-reconcile-acceptance'" -and
    $hyperVWorkflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'" -and
    $hyperVWorkflow -match 'HYPERV_RESOURCE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and
    $hyperVWorkflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID' -and
    $hyperVWorkflow -match 'Invoke-HyperVResourceReconcileCiAcceptance\.ps1 @arguments'
)

Add-CheckResult -Name 'Hyper-V-Workflow fuehrt Storage-Reconcile-Akzeptanz nur manuell auf main mit kontrolliertem Artifact-Input aus' -Success (
    $hyperVWorkflow -match '(?m)^\s*- storage-reconcile-acceptance\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'storage-reconcile-acceptance'" -and
    $hyperVWorkflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'" -and
    $hyperVWorkflow -match 'HYPERV_STORAGE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and
    $hyperVWorkflow -match 'SQL_SERVER_LAB_CI_CLONE_SOURCE_RUN_ID' -and
    $hyperVWorkflow -match 'HYPERV_STORAGE_RECONCILE_CI_CLONE_SOURCE_REQUIRED' -and
    $hyperVWorkflow -match 'Invoke-HyperVStorageReconcileAcceptance\.ps1 @arguments'
)

Add-CheckResult -Name 'Hyper-V-Workflow fuehrt SQL-Storage-Reconcile-Akzeptanz nur manuell auf main mit kontrollierter Clone-Quelle aus' -Success (
    $hyperVWorkflow -match '(?m)^\s*- sql-storage-reconcile-acceptance\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'sql-storage-reconcile-acceptance'" -and
    $hyperVWorkflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'" -and
    $hyperVWorkflow -match 'HYPERV_SQL_STORAGE_RECONCILE_CI_MANUAL_MAIN_REQUIRED' -and
    $hyperVWorkflow -match 'SQL_SERVER_LAB_CI_CLONE_SOURCE_RUN_ID' -and
    $hyperVWorkflow -match 'HYPERV_SQL_STORAGE_RECONCILE_CI_CLONE_SOURCE_REQUIRED' -and
    $hyperVWorkflow -match 'Invoke-HyperVSqlStorageReconcileAcceptance\.ps1 @arguments'
)

Add-CheckResult -Name 'Hyper-V-Workflow fuehrt Sample-Manifest-Akzeptanz nur manuell auf main mit kontrolliertem Artifact-Input aus' -Success (
    $hyperVWorkflow -match '(?m)^\s*- sample-manifest-acceptance\s*$' -and
    $hyperVWorkflow -match "inputs\.mode == 'sample-manifest-acceptance'" -and
    $hyperVWorkflow -match "github\.event_name == 'workflow_dispatch' && github\.ref == 'refs/heads/main'" -and
    $hyperVWorkflow -match 'HYPERV_SAMPLE_MANIFEST_CI_MANUAL_MAIN_REQUIRED' -and
    $hyperVWorkflow -match 'SQL_SERVER_LAB_CI_IMAGE_ARTIFACT_ID' -and
    $hyperVWorkflow -match 'Invoke-HyperVSampleManifestCiAcceptance\.ps1 @arguments'
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

foreach($path in @('Private/AiPersistentRetrieval.ps1','Private/AiPersistentRetrievalSql.ps1','Private/AiPersistentRetrievalMigration.ps1','Public/Invoke-SqlServerLabAiPersistentRetrieval.ps1','Schemas/ai-persistent-retrieval-journal.schema.json','Schemas/ai-persistent-retrieval-journal-v2.schema.json','Scenarios/Ai/persistent-retrieval/1.0/fixture.json')){
    $persistent=& $selector -ChangedPath @($path)
    Add-CheckResult -Name "Persistentes Retrieval bleibt je Einzelpfad Docker/Podman: $path" -Success ($persistent.Docker -and $persistent.Podman -and -not $persistent.HyperV -and -not $persistent.Mixed -and -not $persistent.Adapter -and 'Invoke-AiPersistentRetrievalChecks.ps1' -in $persistent.StaticChecks)
    Add-CheckResult -Name "Persistenzänderung erreicht auch Migrationsregression: $path" -Success ('Invoke-AiPersistentRetrievalMigrationChecks.ps1' -in $persistent.StaticChecks)
}
$combinedPersistent=& $selector -ChangedPath @('Private/AiPersistentRetrieval.ps1','Private/AiRag.ps1')
Add-CheckResult -Name 'Geteilter KI-Vertrag behält Hyper-V trotz begrenztem Persistenzpfad' -Success ($combinedPersistent.HyperV -and $combinedPersistent.Docker -and $combinedPersistent.Podman)
$persistentInfrastructure=& $selector -ChangedPath @('Private/AiPersistentRetrieval.ps1','Tools/Get-CiTestSelection.ps1')
Add-CheckResult -Name 'CI-Infrastrukturänderung behält vollständige Runtimeauswahl' -Success ($persistentInfrastructure.Docker -and $persistentInfrastructure.Podman -and $persistentInfrastructure.HyperV -and $persistentInfrastructure.Mixed -and $persistentInfrastructure.Adapter)

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}

Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
