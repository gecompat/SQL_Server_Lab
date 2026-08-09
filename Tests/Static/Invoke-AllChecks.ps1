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
    'Invoke-ArtifactResolverChecks.ps1',
    'Invoke-CleanupRecoveryChecks.ps1',
    'Invoke-PodmanBootstrapChecks.ps1',
    'Invoke-LabNetworkChecks.ps1',
    'Invoke-MediaRootLayoutChecks.ps1',
    'Invoke-HyperVProviderChecks.ps1',
    'Invoke-HyperVLabEnvironmentChecks.ps1',
    'Invoke-HyperVImageRegistryChecks.ps1',
    'Invoke-HyperVImageBuilderChecks.ps1',
    'Invoke-HyperVImageOperatorChecks.ps1',
    'Invoke-HyperVSqlImageBuilderChecks.ps1',
    'Invoke-WorkflowUiChecks.ps1',
    'Invoke-HyperVSqlAcceptanceEnvironmentChecks.ps1',
    'Invoke-HyperVWindowsBaselineAcceptanceChecks.ps1',
    'Invoke-DataRootChecks.ps1',
    'Invoke-ReadinessContractChecks.ps1',
    'Invoke-ReconcileContractChecks.ps1',
    'Invoke-ReconcileActionContractChecks.ps1',
    'Invoke-ProviderCapabilityChecks.ps1',
    'Invoke-InstanceIntentChecks.ps1',
    'Invoke-MixedProviderLifecycleChecks.ps1',
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



