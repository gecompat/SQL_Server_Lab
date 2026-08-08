#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Repository-Dateien auf privacyrelevante, statische Auffaelligkeiten.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Privacy Scanner Checks' -ForegroundColor Cyan

$excludePathPattern = [regex]'(?:[\\/]\.git[\\/]|[\\/]_QuellRepo[\\/]|[\\/]private_Note[\\/]|[\\/]\\.runtime[\\/]|[\\/]\\.state[\\/]|[\\/]\\.secrets[\\/]|[\\/]\\.artifacts[\\/]|[\\/]\\.cache[\\/]|[\\/]\\.local[\\/])'

function Get-FilteredFiles {
    param(
        [Parameter(Mandatory)][scriptblock]$Filter
    )

    Get-ChildItem -LiteralPath $repoRoot -Recurse -File |
        Where-Object {
            -not $excludePathPattern.IsMatch($_.FullName) -and (& $Filter $_)
        }
}

function Is-AllowedSecretPlaceholder {
    param(
        [Parameter(Mandatory)][string]$Value
    )

    $trimmed = $Value.Trim()
    @(
        'SYNTHETIC',
        'SYNTHETIC_ONLY',
        'not-in-plan',
        'TODO',
        'REDACTED',
        'REDACTED_VALUE',
        'PLACEHOLDER',
        'YOUR_PASSWORD',
        'CHANGE_ME',
        'MUST_REPLACE',
        '<PLACEHOLDER>',
        '<YOUR_',
        '***'
    ) | ForEach-Object {
        if ($trimmed -like "*$_*") { return $true }
    }

    if ($trimmed -match '^\$[A-Za-z_][A-Za-z0-9_]*$' -or $trimmed -match '^\$\{') {
        return $true
    }

    return $trimmed -match '^`?"?\s*\(?if|^\(?\s*New-' -or $trimmed -match '^\$null$|^\$true$|^\$false$|^\($' -or $trimmed -match '^\{'
}

function Remove-CommentTail {
    param([string]$Line)
    $result = $Line
    $hashIndex = $Line.IndexOf('#')
    if ($hashIndex -ge 0) {
        $result = $Line.Substring(0, $hashIndex)
    }
    return $result.Trim()
}

$secretNamedFiles = @(
    '.env',
    '.env.test',
    '.env.local',
    '.env.production',
    '.env.production.local',
    '.env.development',
    '.env.dev'
)

$allFiles = Get-FilteredFiles { $true }
$forbiddenFiles = @()
foreach ($file in $allFiles) {
    $nameLower = $file.Name.ToLowerInvariant()
    $ext = ($file.Extension ?? '').ToLowerInvariant()
    if ($nameLower -eq '.env' -or ($nameLower -like '.env.*' -and $nameLower -ne '.env.example') -or ($secretNamedFiles -contains $nameLower)) {
        $forbiddenFiles += $file.FullName
        continue
    }
    if ($ext -in '.secret', '.secrets', '.pem', '.pfx', '.p12', '.key', '.jks', '.cer', '.crt', '.ppk', '.pvk') {
        $forbiddenFiles += $file.FullName
    }
}

Add-CheckResult `
    -Name 'Keine sensiblen Secret-/Key-/Env-Dateien im Repo' `
    -Success ($forbiddenFiles.Count -eq 0) `
    -Message (($forbiddenFiles | Sort-Object | ForEach-Object { [System.IO.Path]::GetRelativePath($repoRoot, $_) }) -join '; ')

# 2) Reparse-Points / Junctions
$reparsePoints = @()
try {
    $reparsePoints = Get-ChildItem -LiteralPath $repoRoot -Recurse -Force -ErrorAction SilentlyContinue |
        Where-Object { -not $excludePathPattern.IsMatch($_.FullName) -and ($_.Attributes -band [System.IO.FileAttributes]::ReparsePoint) }
}
catch {
    # Get-ChildItem with -Recurse auf ReparsePoints kann in seltenen Umgebungen flackern.
}
Add-CheckResult `
    -Name 'Keine Reparse-Points/Junctions im aktiven Repositoryumfang' `
    -Success ($reparsePoints.Count -eq 0) `
    -Message (($reparsePoints | Select-Object -ExpandProperty FullName) -join '; ')

# 3) Inhaltliche Muster
$scanFileExtensions = @('.ps1', '.psm1', '.psd1', '.json', '.yml', '.yaml', '.xml', '.md')
$scanFiles = Get-FilteredFiles { $_.Extension.ToLowerInvariant() -in $scanFileExtensions }

$findings = @()
foreach ($file in $scanFiles) {
    $text = Get-Content -LiteralPath $file.FullName -Raw -Encoding utf8 -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($text)) { continue }

    $relativePath = [System.IO.Path]::GetRelativePath($repoRoot, $file.FullName)

    # Potenzielle harte Secret- oder Token-Zuweisung
    $secretAssignmentPattern = [regex]'(?im)^\s*(?:export\s+|\$)(?<name>[A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)*_(?:[Ss]ecret|[Pp]asswort|[Pp]assword|[Tt]oken|[Aa]pi[_-]?[Kk]ey|[Cc]onnection[Ss]tring|[Ss]a[Pp]assword))\s*(?:=|:)\s*(?<value>.+)$'
    foreach ($m in $secretAssignmentPattern.Matches($text)) {
        $value = Remove-CommentTail $m.Groups['value'].Value.Trim()
        if ([string]::IsNullOrWhiteSpace($value)) { continue }
        if (Is-AllowedSecretPlaceholder $value) { continue }
        if ($value.Length -lt 8) { continue }
        $findings += [PSCustomObject]@{
            File  = $relativePath
            Kind  = 'Hardcoded secret-like assignment'
            Match = $m.Value.Trim()
        }
    }

    # ConnectionString mit offenem Password/Wert
    $csPattern = [regex]'(?i)\bServer\s*=\s*[^;''"\r\n]+;[^;\r\n]*\b(?:User Id|Uid|Password|Pwd)\s*=\s*(?<value>[^;''"\r\n]+)'
    foreach ($m in $csPattern.Matches($text)) {
        $value = $m.Groups['value'].Value.Trim()
        if (Is-AllowedSecretPlaceholder $value) { continue }
        if ($value.Length -lt 6) { continue }
        $findings += [PSCustomObject]@{
            File  = $relativePath
            Kind  = 'ConnectionString with explicit password value'
            Match = $m.Value.Trim()
        }
    }

    # Absolute Windows-Pfade
    $pathPattern = [regex]'(?im)(?<![A-Za-z0-9])[A-Z]:\\\\[^\\s"''<>|:*?]+\.[A-Za-z0-9]+'
    foreach ($m in $pathPattern.Matches($text)) {
        $findings += [PSCustomObject]@{
            File  = $relativePath
            Kind  = 'Absoluter Windows-Dateipfad'
            Match = $m.Value
        }
    }

    # E-Mail-Adressen
    $emailPattern = [regex]'[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
    foreach ($m in $emailPattern.Matches($text)) {
        $findings += [PSCustomObject]@{
            File  = $relativePath
            Kind  = 'E-Mail-Adresse'
            Match = $m.Value
        }
    }
}

$findings = $findings | Sort-Object File, Kind, Match | Select-Object -Unique
Add-CheckResult `
    -Name 'Keine harten Secret-/Token-/Path-/E-Mail-Hinweise in Versionierungspfad' `
    -Success ($findings.Count -eq 0) `
    -Message ($findings | ForEach-Object { "$($_.File):$($_.Kind):$($_.Match)" } | Out-String).Trim()

if ($failures.Count -gt 0) {
    Write-Host "`nErgebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Red
    foreach ($failure in $failures) {
        Write-Host "  - $failure" -ForegroundColor Red
    }
    exit 1
}

Write-Host "`nErgebnis: $passed PASS, 0 FAIL" -ForegroundColor Green
exit 0
