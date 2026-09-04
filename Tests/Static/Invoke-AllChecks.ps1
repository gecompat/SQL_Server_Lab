#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt alle statischen Vertragspruefungen mit harter Exitcode-Auswertung aus.
.DESCRIPTION
    Startet jede Suite in einem eigenen PowerShell-Prozess. Dadurch kann der
    Exitcode einer fehlschlagenden Suite nicht von einer spaeteren erfolgreichen
    Suite ueberschrieben oder vom aufrufenden Workflow ignoriert werden.
.EXAMPLE
    .\Tests\Static\Invoke-AllChecks.ps1
.OUTPUTS
    Keine. Bei mindestens einer fehlgeschlagenen Suite wird eine Exception
    ausgelöst.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

$ErrorActionPreference = 'Stop'
$pwshCommand = Get-Command pwsh -ErrorAction Stop
$checks = @(
    'Invoke-DocumentationChecks.ps1',
    'Invoke-PSScriptAnalyzerChecks.ps1',
    'Invoke-CiStrategyChecks.ps1',
    'Invoke-ConsoleUiChecks.ps1',
    'Invoke-ActionResultChecks.ps1',
    'Invoke-ElevationChecks.ps1',
    'Invoke-PortAllocationChecks.ps1',
    'Invoke-BatchWorkflowChecks.ps1',
    'Invoke-ArtifactResolverChecks.ps1',
    'Invoke-ResourceSetChecks.ps1',
    'Invoke-CleanupRecoveryChecks.ps1',
    'Invoke-CleanupAuditChecks.ps1',
    'Invoke-PersistentStorageCatalogChecks.ps1',
    'Invoke-PersistentStorageRemovalPlanChecks.ps1',
    'Invoke-PersistentStorageRemovalExecutorChecks.ps1',
    'Invoke-BackupLibraryChecks.ps1',
    'Invoke-DatabasePackageChecks.ps1',
    'Invoke-DatabaseMigrationDependencyChecks.ps1',
    'Invoke-ContainerInstanceStoreChecks.ps1',
    'Invoke-ContainerRuntimeScopeChecks.ps1',
    'Invoke-HyperVPersistentDataDriveChecks.ps1',
    'Invoke-HostToolResolutionChecks.ps1',
    'Invoke-PodmanBootstrapChecks.ps1',
    'Invoke-ContainerAutoStartChecks.ps1',
    'Invoke-ContainerVolumeContractChecks.ps1',
    'Invoke-LabNetworkChecks.ps1',
    'Invoke-MediaRootLayoutChecks.ps1',
    'Invoke-InitialSetupChecks.ps1',
    'Invoke-HyperVProviderChecks.ps1',
    'Invoke-HyperVLabEnvironmentChecks.ps1',
    'Invoke-WindowsSlotPoolChecks.ps1',
    'Invoke-HyperVImageRegistryChecks.ps1',
    'Invoke-HyperVImageBuilderChecks.ps1',
    'Invoke-HyperVImageOperatorChecks.ps1',
    'Invoke-HyperVSqlImageBuilderChecks.ps1',
    'Invoke-WorkflowUiChecks.ps1',
    'Invoke-TestEnvironmentChecks.ps1',
    'Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1',
    'Invoke-HyperVWindowsBaselineAcceptanceChecks.ps1',
    'Invoke-DataRootChecks.ps1',
    'Invoke-HyperVResourceBindingChecks.ps1',
    'Invoke-HyperVImageMigrationChecks.ps1',
    'Invoke-HyperVResourceMigrationChecks.ps1',
    'Invoke-HyperVLegacySqlMigrationBootstrapChecks.ps1',
    'Invoke-StorageMigrationChecks.ps1',
    'Invoke-StorageFilePlacementChecks.ps1',
    'Invoke-VersionCatalogChecks.ps1',
    'Invoke-SoftwareCatalogChecks.ps1',
    'Invoke-ExternalRuntimeContainerImageChecks.ps1',
    'Invoke-ExternalRuntimeReconcileChecks.ps1',
    'Invoke-HyperVExternalRuntimeReconcileChecks.ps1',
    'Invoke-DatabaseCommandChecks.ps1',
    'Invoke-ReadinessContractChecks.ps1',
    'Invoke-ReconcileContractChecks.ps1',
    'Invoke-ReconcileActionContractChecks.ps1',
    'Invoke-HyperVNetworkReconcileChecks.ps1',
    'Invoke-HyperVResourceReconcileChecks.ps1',
    'Invoke-HyperVStorageReconcileChecks.ps1',
    'Invoke-HyperVSqlStorageReconcileChecks.ps1',
    'Invoke-HyperVSqlConfigurationReconcileChecks.ps1',
    'Invoke-HyperVSqlPortReconcileChecks.ps1',
    'Invoke-HyperVTestDatabaseReconcileChecks.ps1',
    'Invoke-ContainerReconcileChecks.ps1',
    'Invoke-ProviderCapabilityChecks.ps1',
    'Invoke-InstanceIntentChecks.ps1',
    'Invoke-MixedProviderLifecycleChecks.ps1',
    'Invoke-RuntimeStateSyncChecks.ps1',
    'Invoke-MaintenanceChecks.ps1',
    'Invoke-ProjectAdapterChecks.ps1',
    'Invoke-SampleHandlerChecks.ps1',
    'Invoke-SampleBaselineRegistryChecks.ps1',
    'Invoke-SampleBaselineRuntimeChecks.ps1',
    'Invoke-ManifestBuilderChecks.ps1',
    'Invoke-PrivacyScannerChecks.ps1',
    'Invoke-PesterChecks.ps1',
    'Invoke-ReleaseReadinessChecks.ps1'
)
$failedChecks = [System.Collections.Generic.List[string]]::new()

foreach ($check in $checks) {
    $checkPath = Join-Path $PSScriptRoot $check
    Write-Host "`n=== $check ===" -ForegroundColor Cyan
    & $pwshCommand.Source -NoLogo -NoProfile -File $checkPath
    if ($LASTEXITCODE -ne 0) {
        $failedChecks.Add("$check (Exitcode $LASTEXITCODE)")
    }
}

if ($failedChecks.Count -gt 0) {
    throw "Statische Vertragspruefungen fehlgeschlagen: $($failedChecks -join '; ')"
}

Write-Host "`nALLE STATISCHEN VERTRAGSPRUEFUNGEN: PASS" -ForegroundColor Green



