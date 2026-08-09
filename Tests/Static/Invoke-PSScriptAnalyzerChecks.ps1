#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt PSScriptAnalyzer auf zentralen PowerShell-Dateien mit projektweiter Baseline aus.

.DESCRIPTION
    Der Check ist lokal reproduzierbar und mutiert keine Artefakte. Fehler blockieren
    den Lauf; Warnungen werden als gruppierte technische Schuld sichtbar ausgegeben.
    Bei fehlendem Modul wird der Check bewusst als "skipped" bewertet.
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
$settingsPath = Join-Path $PSScriptRoot 'PSScriptAnalyzerSettings.psd1'
$settings = Import-PowerShellDataFile -Path $settingsPath -ErrorAction Stop
$errorBaseline = if ($settings.ErrorBaseline -is [System.Collections.IDictionary]) {
    $settings.ErrorBaseline
}
else {
    @{}
}
$excludedPathRegex = [System.Text.RegularExpressions.Regex]::new('([\\/]_QuellRepo[\\/]|[\\/]private_Note[\\/]|[\\/]\\.secrets[\\/]|[\\/]Tests[\\/]Integration[\\/])')
$scriptAnalyzerCommand = Get-Command Invoke-ScriptAnalyzer -ErrorAction SilentlyContinue

if (-not $scriptAnalyzerCommand) {
    Write-Warning 'PSScriptAnalyzer nicht installiert. Check wird uebersprungen.'
    Write-Host 'Installation: Install-Module PSScriptAnalyzer -Scope CurrentUser -Force' -ForegroundColor Cyan
    Write-Host 'Dieser Check gilt als bestanden, bis das Modul in der Umgebung verfuegbar ist.' -ForegroundColor Cyan
    exit 0
}

Import-Module $scriptAnalyzerCommand.Module.Name -ErrorAction Stop | Out-Null

$sourceFiles = Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
    Where-Object {
        $_.Extension -in @('.ps1', '.psm1') -and
        -not $excludedPathRegex.IsMatch($_.FullName)
    }

$results = @()
foreach ($file in $sourceFiles) {
    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)
    Write-Host "  Analysiere $relativePath"
    $fileResults = Invoke-ScriptAnalyzer -Path $file.FullName -Settings $settingsPath -Severity @('Error','Warning')
    if ($fileResults) {
        $results += $fileResults
    }
}

$warnings = @($results | Where-Object { $_.Severity.ToString() -eq 'Warning' })
$errors = @($results | Where-Object { $_.Severity.ToString() -eq 'Error' })
$blockingErrors = @()

if ($warnings.Count -gt 0) {
    Write-Host "PSScriptAnalyzer: WARN ($($warnings.Count) Fundmeldungen)" -ForegroundColor Yellow
    foreach ($group in @($warnings | Group-Object -Property RuleName | Sort-Object -Property Count -Descending)) {
        Write-Host ("  WARN  {0}: {1}" -f $group.Name, $group.Count) -ForegroundColor Yellow
    }
}

foreach ($group in @($errors | Group-Object -Property RuleName | Sort-Object -Property Name)) {
    $baselineCount = 0
    if ($errorBaseline.Contains($group.Name)) {
        $baselineCount = [int]$errorBaseline[$group.Name]
    }

    if ($group.Count -gt $baselineCount) {
        $blockingErrors += $group.Group
        Write-Host ("  FAIL  {0}: {1} Fundmeldungen, Baseline {2}" -f $group.Name, $group.Count, $baselineCount) -ForegroundColor Red
    }
    elseif ($group.Count -lt $baselineCount) {
        Write-Host ("  BASELINE-DRIFT  {0}: {1} Fundmeldungen, Baseline {2}" -f $group.Name, $group.Count, $baselineCount) -ForegroundColor Yellow
    }
    else {
        Write-Host ("  BASELINE  {0}: {1}" -f $group.Name, $group.Count) -ForegroundColor DarkYellow
    }
}

if ($blockingErrors.Count -eq 0) {
    Write-Host 'PSScriptAnalyzer: PASS (keine Error-Fundmeldungen)' -ForegroundColor Green
    exit 0
}

$issueByFile = $blockingErrors | Group-Object -Property ScriptPath | Sort-Object Name
foreach ($group in $issueByFile) {
    foreach ($issue in @($group.Group | Sort-Object Line, Column, RuleName)) {
        Write-Host ("  FAIL  {0}:{1}:{2} [{3}] {4}" -f $issue.ScriptPath, $issue.Line, $issue.Column, $issue.RuleName, $issue.Message) -ForegroundColor Red
    }
}

Write-Host "PSScriptAnalyzer: FAIL ($($blockingErrors.Count) neue Error-Fundmeldungen)" -ForegroundColor Red
exit 1
