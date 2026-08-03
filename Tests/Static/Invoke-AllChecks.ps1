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
param()

$ErrorActionPreference = 'Stop'
$pwshCommand = Get-Command pwsh -ErrorAction Stop
$checks = @(
    'Invoke-DocumentationChecks.ps1',
    'Invoke-ArtifactResolverChecks.ps1',
    'Invoke-CleanupRecoveryChecks.ps1',
    'Invoke-PodmanBootstrapChecks.ps1',
    'Invoke-HyperVProviderChecks.ps1',
    'Invoke-HyperVImageRegistryChecks.ps1',
    'Invoke-HyperVImageBuilderChecks.ps1',
    'Invoke-ReadinessContractChecks.ps1',
    'Invoke-MixedProviderLifecycleChecks.ps1',
    'Invoke-ProjectAdapterChecks.ps1',
    'Invoke-SampleHandlerChecks.ps1',
    'Invoke-ManifestBuilderChecks.ps1'
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
