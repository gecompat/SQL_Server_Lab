#Requires -Version 7.2
[CmdletBinding()] param()
$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$toolPath = Join-Path $repoRoot 'Tools/Initialize-SqlServerLabDataRoot.ps1'
$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-data-root-$([guid]::NewGuid().ToString('N'))"
$failures = [System.Collections.Generic.List[string]]::new(); $passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')
Write-Host ''; Write-Host 'SQL_Server_Lab - Data Root Checks' -ForegroundColor Cyan
try {
    $receipt = & $toolPath -RootPath $temporaryRoot -LabId evaluation-refresh
    Add-CheckResult -Name 'Zentraler Data Root wird ausserhalb von Run-State angelegt' -Success ($receipt.DataRoot -eq $temporaryRoot)
    foreach ($version in @('2019','2022','2025')) {
        Add-CheckResult -Name "SQL-$version-Datendateien sind versionsgetrennt" -Success (
            Test-Path -LiteralPath (Join-Path $temporaryRoot "Labs/evaluation-refresh/Versions/$version/Data")
        )
    }
    Add-CheckResult -Name 'Portable Full-Backup-Ebene wird pro Lab angelegt' -Success (
        Test-Path -LiteralPath (Join-Path $temporaryRoot 'Labs/evaluation-refresh/Backups/Full')
    )
    $rootReadme = Get-Content -LiteralPath (Join-Path $temporaryRoot 'README.md') -Raw -Encoding utf8
    Add-CheckResult -Name 'Lokale Anleitung beschreibt Evaluation-Refresh und Backup/Restore' -Success (
        $rootReadme -match 'Evaluation' -and $rootReadme -match 'Full-Backup' -and $rootReadme -match 'nicht rueckwaertskompatibel|nicht.*Downgrade'
    )
    $second = & $toolPath -RootPath $temporaryRoot -LabId evaluation-refresh
    Add-CheckResult -Name 'Data-Root-Initialisierung ist idempotent' -Success (
        @($second.CreatedDirectories).Count -eq 0 -and @($second.SkippedReadmeFiles).Count -eq 0
    )
}
catch { Add-CheckResult -Name 'Data-Root-Testausfuehrung' -Success $false -Message $_.Exception.Message }
finally { if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force } }
Write-Host ''; Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count) { exit 1 }; exit 0
