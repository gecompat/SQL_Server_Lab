#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft LAB_GENERATED-Baseline-Key, Registry, Auswahl und Quarantaene.
#>
[CmdletBinding()]
param([Alias('h','help','?')][switch]$ShowHelp)

if ($ShowHelp) { Get-Help -Full -Name $PSCommandPath | Out-Host; return }

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0
. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Sample Baseline Registry Checks' -ForegroundColor Cyan

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-baseline-check-$([guid]::NewGuid().ToString('N'))"
try {
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab
    $result = & $module {
        param($Root)

        $stateRoot = Join-Path $Root 'state'
        $testDataRoot = Join-Path $Root 'testdata'
        $restoreDefinition = [PSCustomObject]@{
            sampleId = 'static-bundle'
            sampleVariant = 'full'
            artifactType = 'script-bundle'
            handlerContractVersion = '1'
            expectedOutputs = @(
                [PSCustomObject]@{ name = 'BundleOne'; kind = 'database' },
                [PSCustomObject]@{ name = 'BundleTwo'; kind = 'database' }
            )
        }
        $sourceSha = 'a' * 64
        $variablesA = [ordered]@{ Scale = 'small'; Language = 'de-DE' }
        $variablesB = [ordered]@{ Language = 'de-DE'; Scale = 'small' }
        $key2022 = New-LabSampleBaselineKey -RestoreDefinition $restoreDefinition -SourceSha256 $sourceSha -SqlVersion '2022-CU16' -FeatureRequirements @('FullText', 'InMemory') -CompatibilityLevel 160 -Variables $variablesA
        $key2022Reordered = New-LabSampleBaselineKey -RestoreDefinition $restoreDefinition -SourceSha256 $sourceSha -SqlVersion '2022-CU16' -FeatureRequirements @('InMemory', 'FullText') -CompatibilityLevel 160 -Variables $variablesB

        $backupPath = Join-Path $Root 'baseline.bak'
        New-Item -Path $Root -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText($backupPath, 'verified-static-baseline')
        $registered = Register-LabSampleBaseline -Key $key2022 -BackupPath $backupPath -StateRoot $stateRoot -TestDataRoot $testDataRoot
        $exact = Get-LabSampleBaseline -Key $key2022 -StateRoot $stateRoot -TestDataRoot $testDataRoot

        $key2025 = New-LabSampleBaselineKey -RestoreDefinition $restoreDefinition -SourceSha256 $sourceSha -SqlVersion '2025' -FeatureRequirements @('FullText', 'InMemory') -CompatibilityLevel 170 -Variables $variablesA
        $compatible = Get-LabSampleBaseline -Key $key2025 -AllowCompatible -StateRoot $stateRoot -TestDataRoot $testDataRoot
        $changedSourceKey = New-LabSampleBaselineKey -RestoreDefinition $restoreDefinition -SourceSha256 ('b' * 64) -SqlVersion '2025' -FeatureRequirements @('FullText', 'InMemory') -CompatibilityLevel 170 -Variables $variablesA
        $changedSourceMiss = $null -eq (Get-LabSampleBaseline -Key $changedSourceKey -AllowCompatible -StateRoot $stateRoot -TestDataRoot $testDataRoot)

        $paths = Get-LabSampleBaselinePaths -StateRoot $stateRoot -TestDataRoot $testDataRoot
        $portableRegistry = Get-Content -LiteralPath $paths.RegistryPath -Raw -Encoding utf8
        $registeredBeforeCorruption = Test-Path -LiteralPath $exact.Path -PathType Leaf
        [System.IO.File]::WriteAllText($registered.Path, 'tampered')
        $corruptMiss = $null -eq (Get-LabSampleBaseline -Key $key2022 -StateRoot $stateRoot -TestDataRoot $testDataRoot)
        $registryAfter = Get-Content -LiteralPath $paths.RegistryPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
        $quarantined = @($registryAfter.records | Where-Object { $_.keyId -eq $key2022.KeyId -and $_.quarantined -eq $true -and $_.quarantineReason -eq 'baseline-hash-mismatch' }).Count -eq 1

        $secretRejected = $false
        try {
            $null = New-LabSampleBaselineKey -RestoreDefinition $restoreDefinition -SourceSha256 $sourceSha -SqlVersion '2022' -CompatibilityLevel 160 -Variables @{ SaPassword = 'never-store' }
        }
        catch { $secretRejected = $_.Exception.Message -match 'SAMPLE_BASELINE_KEY_SECRET_REJECTED' }

        [PSCustomObject]@{
            StableKey = $key2022.KeyId -eq $key2022Reordered.KeyId
            Registered = $registered.Record.origin -eq 'LAB_GENERATED' -and $registeredBeforeCorruption
            ExactSelection = $exact.MatchType -eq 'exact'
            CompatibleSelection = $compatible.MatchType -eq 'compatible' -and $compatible.KeyId -eq $key2022.KeyId
            SourceInvalidates = $changedSourceMiss
            PortableRegistry = $portableRegistry -notmatch [regex]::Escape($Root) -and $portableRegistry -notmatch '(?i)runId|hostPort'
            CorruptionQuarantined = $corruptMiss -and $quarantined
            SecretRejected = $secretRejected
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Baseline-Key ist bei sortierbaren Eingaben deterministisch' -Success $result.StableKey
    Add-CheckResult -Name 'LAB_GENERATED-Backup wird inhaltsadressiert registriert' -Success $result.Registered
    Add-CheckResult -Name 'Exakter Baseline-Key wird bevorzugt' -Success $result.ExactSelection
    Add-CheckResult -Name 'Kompatible aeltere SQL-Baseline wird deterministisch gewaehlt' -Success $result.CompatibleSelection
    Add-CheckResult -Name 'Geaenderter Quellhash invalidiert die Baseline-Auswahl' -Success $result.SourceInvalidates
    Add-CheckResult -Name 'Registry bleibt frei von Host- und Run-Werten' -Success $result.PortableRegistry
    Add-CheckResult -Name 'Hash-Abweichung quarantainisiert die Baseline' -Success $result.CorruptionQuarantined
    Add-CheckResult -Name 'Secretartige Installationsvariablen werden abgelehnt' -Success $result.SecretRejected
}
catch {
    Add-CheckResult -Name 'Sample Baseline Registry Testausfuehrung' -Success $false -Message $_.Exception.Message
}
finally {
    if (Test-Path -LiteralPath $temporaryRoot) { Remove-Item -LiteralPath $temporaryRoot -Recurse -Force }
}

Write-Host ''
Write-Host "Ergebnis: $passed PASS, $($failures.Count) FAIL" -ForegroundColor Cyan
if ($failures.Count -gt 0) {
    $failures | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
exit 0
