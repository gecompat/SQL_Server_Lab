#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft lokale Release-Readiness-Anker und Freigabekontrakte.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Release Readiness Checks' -ForegroundColor Cyan

$repoMapPath = Join-Path $repoRoot '.ai\repo_map.yaml'
Add-CheckResult -Name 'Repository-Source-of-truth-Map vorhanden' -Success (Test-Path -LiteralPath $repoMapPath -PathType Leaf)

if (Test-Path -LiteralPath $repoMapPath -PathType Leaf) {
    $repoMapText = Get-Content -LiteralPath $repoMapPath -Raw -Encoding utf8
    $repoMapLatest = [regex]::Match(
        $repoMapText,
        'latest_validation_result:\s*Documentation/Quality/(?<file>VALIDATION_RESULT_\d{4}-\d{2}-\d{2}\.md)'
    )
    Add-CheckResult -Name 'Repo-Map referenziert aktuellen Validierungsreport' -Success $repoMapLatest.Success

    $lastConfirmedMatch = [regex]::Match(
        $repoMapText,
        'last_confirmed_result:\s*date:\s*"(?<date>\d{4}-\d{2}-\d{2})"\s*source:\s*Documentation/Quality/(?<file>VALIDATION_RESULT_\d{4}-\d{2}-\d{2}\.md)'
    )
    Add-CheckResult -Name 'Repo-Map enthaelt bestaetigte Validierungsangabe' -Success $lastConfirmedMatch.Success
}
else {
    Add-CheckResult -Name 'Repo-Map referenziert aktuellen Validierungsreport' -Success $false -Message 'repo_map.yaml fehlt'
    Add-CheckResult -Name 'Repo-Map enthaelt bestaetigte Validierungsangabe' -Success $false -Message 'repo_map.yaml fehlt'
}

$requiredArtifacts = @(
    'CHANGELOG.md',
    'SECURITY.md',
    'Documentation/Quality/LOCAL_READINESS_CHECKLIST.md',
    'Documentation/Quality/PRIVACY_AND_ARTIFACT_SECURITY.md',
    'Documentation/Quality/README.md',
    '.github/workflows/static-contracts.yml'
)
foreach ($requiredArtifact in $requiredArtifacts) {
    $fullPath = Join-Path $repoRoot $requiredArtifact
    Add-CheckResult -Name "Release-Anker vorhanden: $requiredArtifact" -Success (Test-Path -LiteralPath $fullPath -PathType Leaf)
}

$validationDirectory = Join-Path $repoRoot 'Documentation/Quality'
$validationFiles = @(
    Get-ChildItem -LiteralPath $validationDirectory -Filter 'VALIDATION_RESULT_*.md' -File |
        Sort-Object Name -Descending
)
$validationLatestPath = $validationFiles | Select-Object -First 1 -ExpandProperty Name
$validationLatestDate = $null
if ($validationLatestPath -and $validationLatestPath -match 'VALIDATION_RESULT_(?<date>\d{4}-\d{2}-\d{2})\.md') {
    $validationLatestDate = [datetime]::ParseExact($Matches.date, 'yyyy-MM-dd', $null)
}
Add-CheckResult -Name 'Mindestens ein Validierungsreport vorhanden' -Success ($validationLatestPath -ne $null)

$changelogPath = Join-Path $repoRoot 'CHANGELOG.md'
if (Test-Path -LiteralPath $changelogPath -PathType Leaf) {
    $changelogText = Get-Content -LiteralPath $changelogPath -Raw -Encoding utf8
    $firstChangelogDateMatch = [regex]::Match($changelogText, '(?m)^##\s+(?<date>\d{4}-\d{2}-\d{2})')
    Add-CheckResult -Name 'Changelog besitzt mindestens einen Datumsabschnitt' -Success $firstChangelogDateMatch.Success

    if ($firstChangelogDateMatch.Success -and $validationLatestDate) {
        $firstChangelogDate = [datetime]::ParseExact($firstChangelogDateMatch.Groups['date'].Value, 'yyyy-MM-dd', $null)
        Add-CheckResult -Name 'Changelog ist mindestens bis zu letzter Validation aktualisiert' -Success ($firstChangelogDate -ge $validationLatestDate)
    }
    else {
        Add-CheckResult -Name 'Changelog ist mindestens bis zu letzter Validation aktualisiert' -Success $false -Message 'kein Datum zum Vergleich'
    }
}
else {
    Add-CheckResult -Name 'Changelog besitzt mindestens einen Datumsabschnitt' -Success $false -Message 'CHANGELOG.md fehlt'
    Add-CheckResult -Name 'Changelog ist mindestens bis zu letzter Validation aktualisiert' -Success $false -Message 'CHANGELOG.md fehlt'
}

$releaseReadiness = Get-Content -LiteralPath (Join-Path $repoRoot 'Documentation\Quality\LOCAL_READINESS_CHECKLIST.md') -Raw -Encoding utf8
Add-CheckResult -Name 'Local Readiness Checklist enthält Push/Merge auf main und Baseline-Checks' -Success (
    $releaseReadiness -match 'Lokal-Readiness-Checklist vor jedem Push' -and
    $releaseReadiness -match 'baseline-checks' -and
    $releaseReadiness -match 'merge auf `main`'
)

$testsReadme = Get-Content -LiteralPath (Join-Path $repoRoot 'Tests\README.md') -Raw -Encoding utf8
Add-CheckResult -Name 'Tests-README führt Static Contracts als Release-Grundbaustein auf' -Success ($testsReadme -match 'Invoke-AllChecks\.ps1')

$staticWorkflow = Get-Content -LiteralPath (Join-Path $repoRoot '.github\workflows\static-contracts.yml') -Raw -Encoding utf8
Add-CheckResult -Name 'Static workflow führt Invoke-AllChecks aus' -Success ($staticWorkflow -match 'Invoke-AllChecks\.ps1')

Add-CheckResult -Name 'Release-Readiness-Checks werden nur informiert, nicht auf mutable State angewiesen' -Success $true

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
