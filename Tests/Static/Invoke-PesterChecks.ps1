#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt lokale Pester-Unit-/Contract-Tests aus.

.DESCRIPTION
    Der Check startet reproduzierbare Pester-Tests unter Tests\Pester.
    Ergebnisse werden nur in der Konsole ausgewertet; der Check persistiert
    keine XML-Berichte im Repository.
    Benoetigt Pester ab Version 5 fuer die vorhandenen BeforeAll-/Mock-Vertraege.
    Fehlendes oder zu altes Pester sowie nicht ausgefuehrte Testfaelle bleiben
    NOT_EXECUTED (Infrastruktur-Exitcode 2). Test- und Runnerfehler liefern 1;
    nur ein vollstaendiger erfolgreicher Lauf liefert 0.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [string[]]$ChangedPath
)

if ($ShowHelp) {
    Get-Help -Full -Name $PSCommandPath | Out-Host
    return
}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$scope = & (Join-Path $repoRoot 'Tools/Get-StaticValidationScope.ps1') -ChangedPath $ChangedPath
if (-not $scope.Global -and $scope.Pester.Count -eq 0) {
    Write-Host 'Pester: NOT_APPLICABLE (no affected Pester contract; not an executed PASS).'
    exit 0
}
Write-Host ''
Write-Host 'SQL_Server_Lab - Pester Checks' -ForegroundColor Cyan

$pesterModule = Get-Module -ListAvailable -Name Pester |
    Where-Object { $_.Version.Major -ge 5 } |
    Sort-Object Version -Descending | Select-Object -First 1
if (-not $pesterModule) {
    Write-Host 'Pester: INFRASTRUCTURE_UNAVAILABLE (Pester ab Version 5 nicht verfuegbar).' -ForegroundColor Yellow
    Write-Host 'Pester: NOT_EXECUTED (keine Unit-/Contract-Tests ausgefuehrt).' -ForegroundColor Yellow
    exit 2
}

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

$pesterRoot = Join-Path $repoRoot 'Tests\Pester'
try {
    Import-Module $pesterModule.Path -Force -ErrorAction Stop
    $configuration = New-PesterConfiguration
    if ($scope.Global) { $configuration.Run.Path = @($pesterRoot) }
    else { $configuration.Run.Path = @($scope.Pester | ForEach-Object { Join-Path $repoRoot $_ }) }
    $configuration.Run.PassThru = $true
    $configuration.Output.Verbosity = 'Normal'
    $result = Invoke-Pester -Configuration $configuration -ErrorAction Stop
    if ($null -eq $result -or $result -is [array]) { throw 'PESTER_RESULT_MISSING' }
    $counts = @{}
    foreach ($name in @('TotalCount','PassedCount','FailedCount','SkippedCount','NotRunCount','InconclusiveCount')) {
        $property = $result.PSObject.Properties[$name]
        if ($null -eq $property -or $property.Value -isnot [int] -or $property.Value -lt 0) {
            throw "PESTER_RESULT_INVALID: $name"
        }
        $counts[$name] = $property.Value
    }
    $sum = $counts.PassedCount + $counts.FailedCount + $counts.SkippedCount + $counts.NotRunCount + $counts.InconclusiveCount
    if ($counts.TotalCount -eq 0 -or $counts.TotalCount -ne $sum) { throw 'PESTER_RESULT_INVALID: TotalCount' }
    if ($counts.FailedCount -gt 0 -or $result.Result -eq 'Failed' -or $result.FailedContainersCount -gt 0) {
        throw 'PESTER_TESTS_FAILED'
    }
}
catch {
    Write-Host "Pester: FAIL ($($_.Exception.Message))" -ForegroundColor Red
    exit 1
}

Write-Host ("Pester-Testfaelle: {0} insgesamt, {1} bestanden, {2} uebersprungen, {3} nicht ausgefuehrt, {4} unentschieden." -f
    $counts.TotalCount, $counts.PassedCount, $counts.SkippedCount, $counts.NotRunCount, $counts.InconclusiveCount)
if ($counts.SkippedCount + $counts.NotRunCount + $counts.InconclusiveCount -gt 0) {
    Write-Host 'Pester: NOT_EXECUTED (Testnachweis unvollstaendig).' -ForegroundColor Yellow
    exit 2
}
if ($result.Result -ne 'Passed') {
    Write-Host 'Pester: FAIL (kein bestaetigter erfolgreicher Gesamtstatus).' -ForegroundColor Red
    exit 1
}

Write-Host "Pester: PASS ($($counts.PassedCount) ausgefuehrte Tests)." -ForegroundColor Green
exit 0
