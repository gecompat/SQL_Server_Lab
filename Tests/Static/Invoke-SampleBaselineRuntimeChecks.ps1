#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft Erzeugung und bevorzugte Wiederverwendung von LAB_GENERATED-Backups.
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
Write-Host 'SQL_Server_Lab - Sample Baseline Runtime Checks' -ForegroundColor Cyan

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-baseline-runtime-$([guid]::NewGuid().ToString('N'))"
try {
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab
    $result = & $module {
        param($Root)

        $script:baselineSql = [System.Collections.Generic.List[string]]::new()
        $script:originalResolverCalls = 0
        $script:restoreSources = [System.Collections.Generic.List[string]]::new()

        function script:Invoke-SqlQuery {
            param([string]$HostName, [int]$Port, [string]$SaPlain, [string]$Query)
            if ($Query -match 'BACKUP DATABASE') {
                $script:baselineSql.Add($Query)
                return @('Backup verified')
            }
            if ($Query -match 'state_desc') { return @('ONLINE') }
            return @()
        }
        function script:Export-LabSampleBaselineContainerBackup {
            param([int]$Port, [string]$ContainerName, [string]$ContainerBackupPath, [string]$DestinationPath)
            [System.IO.File]::WriteAllText($DestinationPath, 'verified-runtime-baseline')
            return [PSCustomObject]@{ Provider = $null; ContainerName = $ContainerName }
        }
        function script:Initialize-LabSampleBaselineContainerBackup {
            param([int]$Port, [string]$ContainerName)
            return [PSCustomObject]@{ Provider = 'static'; ContainerName = $ContainerName }
        }
        function script:Resolve-LabArtifact {
            param([Parameter(ValueFromRemainingArguments = $true)]$Arguments)
            $script:originalResolverCalls++
            throw 'Originalresolver darf bei Baseline-Hit nicht laufen.'
        }
        function script:Restore-SqlServerLabDatabase {
            param(
                [string]$HostName, [int]$Port, [SecureString]$SaPassword,
                [string]$BackupSource, [string]$ExpectedSha256,
                [string]$DatabaseName, [string]$ContainerName, [string]$StateRoot
            )
            $script:restoreSources.Add($BackupSource)
            return [PSCustomObject]@{ Success = $true; Message = 'RESTORE erfolgreich' }
        }

        $stateRoot = Join-Path $Root 'state'
        $testDataRoot = Join-Path $Root 'testdata'
        $sourceSha = 'c' * 64
        $restoreDefinition = [PSCustomObject]@{
            sampleId = 'runtime-baseline'
            sampleVariant = 'script'
            category = 'training'
            artifactType = 'sql-script'
            handlerContractVersion = '1'
            source = 'https://example.invalid/runtime.sql'
            expectedSha256 = $sourceSha
            compatibility = 160
            trustPolicy = 'catalog-sha256'
            expectedOutputs = @([PSCustomObject]@{ name = 'RuntimeBaseline'; kind = 'database' })
            installation = [PSCustomObject]@{
                kind = 'sql-script'
                executionMode = 'existing-database'
                timeoutSeconds = 30
                idempotencyMode = 'fail-if-exists'
                baselinePolicy = 'eligible-after-verification'
            }
        }
        $key = New-LabSampleBaselineRequestKey -RestoreDefinition $restoreDefinition -SourceSha256 $sourceSha -SqlVersion '2022'
        $password = [SecureString]::new()
        $generated = New-LabSampleBaselineBackup `
            -Port 14330 `
            -SaPassword $password `
            -ContainerName 'static-container' `
            -DatabaseName 'RuntimeBaseline' `
            -Key $key `
            -StateRoot $stateRoot `
            -TestDataRoot $testDataRoot

        $install = Install-LabSampleDatabase `
            -Port 14330 `
            -SaPassword $password `
            -ContainerName 'static-container' `
            -RestoreDefinition $restoreDefinition `
            -SqlVersion '2022' `
            -NonInteractive `
            -StateRoot $stateRoot `
            -TestDataRoot $testDataRoot

        $bundleDefinition = [PSCustomObject]@{
            sampleId = 'runtime-bundle'
            sampleVariant = 'multi'
            category = 'training'
            artifactType = 'script-bundle'
            handlerContractVersion = '1'
            source = 'https://example.invalid/runtime.zip'
            expectedSha256 = ('d' * 64)
            compatibility = 160
            trustPolicy = 'catalog-sha256'
            expectedOutputs = @(
                [PSCustomObject]@{ name = 'RuntimeOne'; kind = 'database' },
                [PSCustomObject]@{ name = 'RuntimeTwo'; kind = 'database' }
            )
            installation = [PSCustomObject]@{
                kind = 'script-bundle'
                executionMode = 'self-creates-databases'
                timeoutSeconds = 30
                idempotencyMode = 'fail-if-exists'
                partialFailurePolicy = 'recovery-required'
                baselinePolicy = 'eligible-after-verification'
            }
        }
        $bundleKey = New-LabSampleBaselineRequestKey -RestoreDefinition $bundleDefinition -SourceSha256 $bundleDefinition.expectedSha256 -SqlVersion '2022'
        $generatedBundle = New-LabSampleBaselineBundle `
            -Port 14330 `
            -SaPassword $password `
            -ContainerName 'static-container' `
            -DatabaseNames @('RuntimeOne', 'RuntimeTwo') `
            -Key $bundleKey `
            -StateRoot $stateRoot `
            -TestDataRoot $testDataRoot
        $bundleInstall = Install-LabSampleDatabase `
            -Port 14330 `
            -SaPassword $password `
            -ContainerName 'static-container' `
            -RestoreDefinition $bundleDefinition `
            -SqlVersion '2022' `
            -NonInteractive `
            -StateRoot $stateRoot `
            -TestDataRoot $testDataRoot

        $allBaselineSql = $script:baselineSql -join "`n"

        [PSCustomObject]@{
            Generated = $generated.Status -eq 'BASELINE_REGISTERED' -and (Test-Path -LiteralPath $generated.Path -PathType Leaf)
            SqlVerified = $allBaselineSql -match 'WITH COPY_ONLY, INIT, CHECKSUM' -and $allBaselineSql -match 'RESTORE VERIFYONLY' -and $allBaselineSql -match 'WITH CHECKSUM'
            Preferred = $install.Success -and $install.Artifact.IntegrityOrigin -eq 'LAB_GENERATED' -and $script:restoreSources -contains $generated.Path
            OriginalSkipped = $script:originalResolverCalls -eq 0
            MultiGenerated = $generatedBundle.Record.artifactFormat -eq 'multi-database-zip' -and (Test-Path -LiteralPath $generatedBundle.Path -PathType Leaf)
            MultiPreferred = $bundleInstall.Success -and $bundleInstall.Artifact.ArtifactFormat -eq 'multi-database-zip' -and @($script:restoreSources | Where-Object { $_ -match 'Runtime(One|Two)\.bak$' }).Count -eq 2
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Verifiziertes Single-Output-Sample wird als LAB_GENERATED registriert' -Success $result.Generated
    Add-CheckResult -Name 'Baseline-Erzeugung verwendet BACKUP CHECKSUM und RESTORE VERIFYONLY' -Success $result.SqlVerified
    Add-CheckResult -Name 'Verifizierte Baseline wird vor dem Originalartefakt wiederhergestellt' -Success $result.Preferred
    Add-CheckResult -Name 'Originalresolver bleibt bei Baseline-Hit unangetastet' -Success $result.OriginalSkipped
    Add-CheckResult -Name 'Multi-Output-Sample wird als typisiertes ZIP registriert' -Success $result.MultiGenerated
    Add-CheckResult -Name 'Multi-Output-Baseline stellt exakt alle erwarteten Backups wieder her' -Success $result.MultiPreferred
}
catch {
    Add-CheckResult -Name 'Sample Baseline Runtime Testausfuehrung' -Success $false -Message $_.Exception.Message
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
