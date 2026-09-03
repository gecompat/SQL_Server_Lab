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
foreach ($workflow in $runtimeWorkflows) {
    $text = Get-Content -LiteralPath (Join-Path $repoRoot ".github/workflows/$workflow") -Raw -Encoding utf8
    if ($text -match 'Invoke-AllChecks\.ps1|name:\s*Static contracts') { $duplicates += $workflow }
}
Add-CheckResult -Name 'Runtime-Workflows wiederholen keine statische Vollregression' -Success ($duplicates.Count -eq 0) -Message ($duplicates -join ', ')

$dockerWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-docker.yml') -Raw -Encoding utf8
$podmanWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-podman.yml') -Raw -Encoding utf8
$hyperVWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github/workflows/runtime-smoke-hyperv.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'Docker- und Podman-Gates enthalten den realen Batch-Smoke' -Success (
    $dockerWorkflow -match 'Invoke-BatchWorkflowSmokeTest\.ps1\s+`?\s*-Provider docker' -and
    $podmanWorkflow -match 'Invoke-BatchWorkflowSmokeTest\.ps1\s+`?\s*-Provider podman'
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
Add-CheckResult -Name 'PR-Gate schützt Self-hosted Runner vor Fork-Code' -Success (
    $prWorkflow -match 'pull_request\.head\.repo\.full_name == github\.repository'
)
Add-CheckResult -Name 'PR-Gate validiert betroffene Foundation-Aenderungen gegen den gebundenen Quellcommit' -Success (
    $prWorkflow -match '(?m)^\s{2}foundation-integrity:\s*$' -and
    $prWorkflow -match 'if:\s*needs\.classify\.outputs\.foundation == ''true''' -and
    $prWorkflow -match '\.ai/foundation-upgrade-assessments/' -and
    $prWorkflow -match 'repository:\s*gecompat/AI_Repository_Foundation' -and
    $prWorkflow -match 'ref:\s*7ddc29988b23570f462e46ebf527f8dfdd05fd75' -and
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
