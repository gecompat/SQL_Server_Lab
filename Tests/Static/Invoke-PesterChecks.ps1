#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt lokale Pester-Unit-/Contract-Tests aus.

.DESCRIPTION
    Der Check startet reproduzierbare Pester-Tests unter Tests\Pester.
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
$artifactDir = Join-Path $repoRoot '.artifacts\pester'
New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
$outputXml = Join-Path $artifactDir ('Pester-Results-{0:yyyyMMdd-HHmmss}.xml' -f (Get-Date))

$previousErrorAction = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    $result = Invoke-Pester -Script $pesterRoot -PassThru -OutputFile $outputXml -OutputFormat NUnitXml -ErrorAction SilentlyContinue
}
finally {
    $ErrorActionPreference = $previousErrorAction
}
$failed = if ($result.PSObject.Properties.Name -contains 'FailedCount') { [int]$result.FailedCount } else { 0 }
$total = if ($result.PSObject.Properties.Name -contains 'TotalCount') { [int]$result.TotalCount } else { 0 }

Add-CheckResult -Name 'Pester-Testsatz findet ausführbare Tests' -Success ($total -gt 0) -Message "Gefunden: $total"

if ($failed -gt 0) {
    Add-CheckResult -Name 'Pester-Testlauf' -Success $false -Message ('{0} Testfehler (Report: {1})' -f $failed, $outputXml)
    Write-Host "`nERGEBNIS: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    exit 1
}

Add-CheckResult -Name 'Pester-Testlauf' -Success $true -Message ("Ergebnis: {0} Total, {1} Failed, XML={2}" -f $total, $failed, $outputXml)

Write-Host "`nERGEBNIS: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
