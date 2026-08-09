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

if ($warnings.Count -gt 0) {
    Write-Host "PSScriptAnalyzer: WARN ($($warnings.Count) Fundmeldungen)" -ForegroundColor Yellow
    foreach ($group in @($warnings | Group-Object -Property RuleName | Sort-Object -Property Count -Descending)) {
        Write-Host ("  WARN  {0}: {1}" -f $group.Name, $group.Count) -ForegroundColor Yellow
    }
}

if ($errors.Count -eq 0) {
    Write-Host 'PSScriptAnalyzer: PASS (keine Error-Fundmeldungen)' -ForegroundColor Green
    exit 0
}

$issueByFile = $errors | Group-Object -Property ScriptPath | Sort-Object Name
foreach ($group in $issueByFile) {
    foreach ($issue in @($group.Group | Sort-Object Line, Column, RuleName)) {
        Write-Host ("  FAIL  {0}:{1}:{2} [{3}] {4}" -f $issue.ScriptPath, $issue.Line, $issue.Column, $issue.RuleName, $issue.Message) -ForegroundColor Red
    }
}

Write-Host "PSScriptAnalyzer: FAIL ($($errors.Count) Error-Fundmeldungen)" -ForegroundColor Red
exit 1
