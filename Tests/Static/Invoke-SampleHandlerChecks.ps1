#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft den Sample-Backup-Handler-Vertrag ohne Netzwerk, Container oder SQL Server.
.DESCRIPTION
    Validiert Katalogfilterung, Sample-Aufloesung, Idempotenz- und Trust-Metadaten
    sowie den nicht interaktiven TRUST_REQUIRED-Pfad des Handlers. Es werden nur
    temporaere, synthetische State-Dateien verwendet.
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Sample Handler Checks' -ForegroundColor Cyan

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-sample-check-$([guid]::NewGuid().ToString('N'))"
try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    $result = & $module {
        param($StateRoot)

        $allVariants = @(Get-LabExecutableSampleVariant)
        $variants2019 = @(Get-LabExecutableSampleVariant -SqlVersion '2019')
        $variants2022 = @(Get-LabExecutableSampleVariant -SqlVersion '2022-CU16')

        $resolved = Resolve-LabSampleRestore `
            -SampleDefinition ([PSCustomObject]@{ id = 'adventureworks-2022'; variant = 'lightweight' }) `
            -SqlVersion '2022' `
            -TargetDatabaseName 'AdventureWorksLT2022'

        $wrongNameRejected = $false
        try {
            $null = Resolve-LabSampleRestore `
                -SampleDefinition ([PSCustomObject]@{ id = 'adventureworks-2022'; variant = 'lightweight' }) `
                -SqlVersion '2022' `
                -TargetDatabaseName 'FalscherName'
        }
        catch {
            $wrongNameRejected = $_.Exception.Message -match 'erwartet die Datenbank'
        }

        $descriptiveRejected = $false
        try {
            $null = Resolve-LabSampleRestore `
                -SampleDefinition ([PSCustomObject]@{ id = 'stackoverflow-50gb'; variant = '10gb' }) `
                -SqlVersion '2022' `
                -TargetDatabaseName 'StackOverflow2010'
        }
        catch {
            $descriptiveRejected = $_.Exception.Message -match 'beschreibend katalogisiert'
        }

        $scriptRejected = $false
        try {
            $null = Resolve-LabSampleRestore `
                -SampleDefinition ([PSCustomObject]@{ id = 'northwind'; variant = 'script' }) `
                -SqlVersion '2022' `
                -TargetDatabaseName 'Northwind'
        }
        catch {
            $scriptRejected = $_.Exception.Message -match 'beschreibend katalogisiert|Backup-Handler'
        }

        $dummyPassword = ConvertTo-SecureString 'Static-Check-Only-1!' -AsPlainText -Force
        $handlerResult = Install-LabSampleDatabase `
            -Port 14330 `
            -SaPassword $dummyPassword `
            -ContainerName 'static-check-none' `
            -RestoreDefinition $resolved `
            -NonInteractive `
            -StateRoot $StateRoot

        $status = Get-LabSampleArtifactLocalStatus `
            -Source $resolved.source `
            -SampleId $resolved.sampleId `
            -SampleVariant $resolved.sampleVariant `
            -StateRoot $StateRoot

        [PSCustomObject]@{
            AllBackupExecutable   = @($allVariants | Where-Object { $_.ArtifactType -ne 'backup' }).Count -eq 0
            NoDescriptiveVariants = @($allVariants | Where-Object { $_.SampleId -in @('stackoverflow-50gb', 'northwind') }).Count -eq 0
            VersionFilterWorks    = @($variants2019 | Where-Object { $_.MinSqlVersion -eq '2022' }).Count -eq 0 -and
                @($variants2022 | Where-Object { $_.SampleId -eq 'adventureworks-2022' }).Count -gt 0
            ResolvedContract      = $resolved.replace -eq $false -and
                $resolved.idempotencyMode -eq 'fail-if-exists' -and
                $resolved.trustPolicy -eq 'interactive-once' -and
                $resolved.sampleId -eq 'adventureworks-2022' -and
                $resolved.downloadSizeMB -gt 0
            WrongNameRejected     = $wrongNameRejected
            DescriptiveRejected   = $descriptiveRejected
            ScriptRejected        = $scriptRejected
            TrustRequired         = $handlerResult.Status -eq 'TRUST_REQUIRED' -and -not $handlerResult.Success
            LocalStatusUntrusted  = $status.TrustStatus -eq 'TRUST_REQUIRED' -and $status.CacheStatus -eq 'MISS'
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Katalogliste enthaelt nur Backup-Handler-Varianten' -Success $result.AllBackupExecutable
    Add-CheckResult -Name 'Beschreibende Varianten (Attach/SQL-Skript) bleiben ausgeschlossen' -Success $result.NoDescriptiveVariants
    Add-CheckResult -Name 'Versionsfilter beruecksichtigt minSqlVersion und CU-Bezeichner' -Success $result.VersionFilterWorks
    Add-CheckResult -Name 'Sample-Aufloesung liefert Trust-, Idempotenz- und Groessenvertrag' -Success $result.ResolvedContract
    Add-CheckResult -Name 'Abweichender Zieldatenbankname wird abgelehnt' -Success $result.WrongNameRejected
    Add-CheckResult -Name 'Beschreibende Varianten werden nicht ausgefuehrt' -Success $result.DescriptiveRejected
    Add-CheckResult -Name 'SQL-Skript-Samples werden nicht als Restore umgedeutet' -Success $result.ScriptRejected
    Add-CheckResult -Name 'Nicht interaktiver Handler ohne Trust endet mit TRUST_REQUIRED' -Success $result.TrustRequired
    Add-CheckResult -Name 'Lokaler Trust-/Cache-Status wird read-only gemeldet' -Success $result.LocalStatusUntrusted
}
catch {
    Add-CheckResult -Name 'Sample Handler Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) {
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force
    }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

exit 0
