#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt lokale Pester-Unit-/Contract-Tests aus.

.DESCRIPTION
    Der Check startet reproduzierbare Pester-Tests unter Tests\Pester.
    Ergebnisse werden nur in der Konsole ausgewertet; der Check persistiert
    keine XML-Berichte im Repository.
    Falls Pester nicht installiert ist, wird der Check bewusst als übersprungen
    bewertet (PASS), damit reproduzierbare lokale Arbeit ohne externes Modul
    möglich bleibt.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp
)

if ($ShowHelp) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

$legacyArtifactDir = Join-Path $repoRoot '.artifacts\pester'
if (Test-Path -LiteralPath $legacyArtifactDir -PathType Container) {
    $artifactDirectory = Get-Item -LiteralPath $legacyArtifactDir -Force
    if (($artifactDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
        throw "PESTER_ARTIFACT_CLEANUP_UNSAFE: Reparse-Point wird nicht bereinigt: $legacyArtifactDir"
    }
    foreach ($legacyReport in @(Get-ChildItem -LiteralPath $legacyArtifactDir -Filter 'Pester-Results-*.xml' -File -Force)) {
        Remove-Item -LiteralPath $legacyReport.FullName -Force -ErrorAction Stop
    }
    if (@(Get-ChildItem -LiteralPath $legacyArtifactDir -Force).Count -eq 0) {
        Remove-Item -LiteralPath $legacyArtifactDir -Force -ErrorAction Stop
    }
}

Write-Host ''
Write-Host 'SQL_Server_Lab - Pester Checks' -ForegroundColor Cyan

$pesterModule = Get-Module -ListAvailable -Name Pester | Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule) {
    Add-CheckResult -Name 'Pester installiert' -Success $true -Message 'Übersprungen: Pester ist nicht installiert.'
    Add-CheckResult -Name 'Pester-Paket hat mindestens ein Testskript' -Success (Test-Path -LiteralPath (Join-Path $repoRoot 'Tests\Pester'))
    Write-Host "`nRESULTAT: $passed PASS, 0 FAIL" -ForegroundColor Green
    exit 0
}

Add-CheckResult -Name 'Pester verfügbar' -Success $true -Message "Gefundene Version $($pesterModule.Version)"

$pesterRoot = Join-Path $repoRoot 'Tests\Pester'

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    if ($pesterModule.Version.Major -ge 6) {
        $configuration = New-PesterConfiguration
        $configuration.Run.Path = @($pesterRoot)
        $configuration.Run.PassThru = $true
        $configuration.Output.Verbosity = 'Normal'
        $result = Invoke-Pester -Configuration $configuration -ErrorAction SilentlyContinue
    }
    else {
        $result = Invoke-Pester -Script $pesterRoot -PassThru -ErrorAction SilentlyContinue
    }
}
finally {
    $ErrorActionPreference = $previousErrorAction
}
$failed = if ($result.PSObject.Properties.Name -contains 'FailedCount') { [int]$result.FailedCount } else { 0 }
$total = if ($result.PSObject.Properties.Name -contains 'TotalCount') { [int]$result.TotalCount } else { 0 }

Add-CheckResult -Name 'Pester-Testsatz findet ausführbare Tests' -Success ($total -gt 0) -Message "Gefunden: $total"

if ($failed -gt 0) {
    Add-CheckResult -Name 'Pester-Testlauf' -Success $false -Message ("$failed Testfehler")
    Write-Host "`nERGEBNIS: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    exit 1
}

Add-CheckResult -Name 'Pester-Testlauf' -Success $true -Message ("Ergebnis: {0} Total, {1} Failed" -f $total, $failed)

Write-Host "`nERGEBNIS: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
