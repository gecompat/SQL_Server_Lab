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
$storageOperationsText = Get-Content -LiteralPath (Join-Path $repoRoot 'Private/SqlStorageOperations.ps1') -Raw
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
        $script:hyperVRestoreCalls = [System.Collections.Generic.List[object]]::new()
        $script:hyperVExportPaths = [System.Collections.Generic.List[string]]::new()
        $script:hyperVRemovePaths = [System.Collections.Generic.List[string]]::new()
        $script:hyperVReceiptStatus = 'VERIFIED'

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
                [string]$DatabaseName, [string]$ContainerName, [string]$Provider,
                [string]$RunId, [string]$InstanceId, [PSCredential]$GuestCredential,
                [string]$RunDirectory, [string]$StateRoot
            )
            $script:restoreSources.Add($BackupSource)
            if ($RunId) {
                $script:hyperVRestoreCalls.Add([PSCustomObject]@{
                    RunId=$RunId; InstanceId=$InstanceId; Credential=$GuestCredential
                    BackupSource=$BackupSource; RunDirectory=$RunDirectory
                })
            }
            return [PSCustomObject]@{ Success = $true; Message = 'RESTORE erfolgreich' }
        }
        function script:Resolve-LabRunInstance {
            param([string]$RunId, [string]$InstanceId, [string]$StateRoot)
            return [PSCustomObject]@{
                HostName='192.0.2.25'; Port=1433; Provider='hyperv'
                ContainerName=$null; VMName='synthetic-baseline-vm'; Version='2022'
            }
        }
        function script:Get-LabVerifiedStorageRuntimeContext {
            param([string]$RunId, [string]$InstanceId, [string]$StateRoot)
            return [PSCustomObject]@{
                Plan=[PSCustomObject]@{ Provider='hyperv' }
                Receipt=[PSCustomObject]@{ Status=$script:hyperVReceiptStatus; FileBindings=@(
                    [PSCustomObject]@{ Role='backup'; SqlPhysicalPath='V:\SQLLab\Backup' }
                ) }
                StateRoot=$StateRoot
            }
        }
        function script:Copy-LabFileFromHyperVGuest {
            param(
                [string]$RunId, [string]$SourcePath, [string]$DestinationPath,
                [PSCredential]$Credential, [string]$StateRoot
            )
            $script:hyperVExportPaths.Add($SourcePath)
            [System.IO.File]::WriteAllText($DestinationPath, 'verified-hyperv-baseline')
            return $DestinationPath
        }
        function script:Remove-LabHyperVGuestFile {
            param([string]$RunId, [string]$Path, [PSCredential]$Credential, [string]$StateRoot)
            $script:hyperVRemovePaths.Add($Path)
        }

        $stateRoot = Join-Path $Root 'state'
        $testDataRoot = Join-Path $Root 'testdata'
        $runDirectory = Join-Path $stateRoot 'runs/runtime-baseline-check'
        New-Item -Path $runDirectory -ItemType Directory -Force | Out-Null
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
            -RunDirectory $runDirectory `
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
            -RunDirectory $runDirectory `
            -StateRoot $stateRoot `
            -TestDataRoot $testDataRoot

        $hyperVDefinition = [PSCustomObject]@{
            sampleId = 'runtime-hyperv-baseline'
            sampleVariant = 'script'
            category = 'training'
            artifactType = 'sql-script'
            handlerContractVersion = '1'
            source = 'https://example.invalid/hyperv-runtime.sql'
            expectedSha256 = ('e' * 64)
            compatibility = 160
            trustPolicy = 'catalog-sha256'
            expectedOutputs = @([PSCustomObject]@{ name = 'HyperVBaseline'; kind = 'database' })
            installation = [PSCustomObject]@{
                kind = 'sql-script'
                executionMode = 'existing-database'
                timeoutSeconds = 30
                idempotencyMode = 'fail-if-exists'
                baselinePolicy = 'eligible-after-verification'
            }
        }
        $hyperVKey = New-LabSampleBaselineRequestKey `
            -RestoreDefinition $hyperVDefinition `
            -SourceSha256 $hyperVDefinition.expectedSha256 `
            -SqlVersion '2022'
        $guestCredential = [PSCredential]::new('Administrator', $password)
        $missingCredentialMessage = try {
            Initialize-LabSampleBaselineBackupTarget `
                -Provider hyperv -Port 1433 -RunId 'synthetic-hyperv-run' `
                -InstanceId 'primary' -StateRoot $stateRoot | Out-Null
            ''
        }
        catch { $_.Exception.Message }
        $script:hyperVReceiptStatus = 'RECOVERY_REQUIRED'
        $unverifiedReceiptMessage = try {
            Initialize-LabSampleBaselineBackupTarget `
                -Provider hyperv -Port 1433 -RunId 'synthetic-hyperv-run' `
                -InstanceId 'primary' -GuestCredential $guestCredential -StateRoot $stateRoot | Out-Null
            ''
        }
        catch { $_.Exception.Message }
        $script:hyperVReceiptStatus = 'VERIFIED'
        $hyperVGenerated = New-LabSampleBaselineBackup `
            -Provider hyperv `
            -Port 1433 `
            -SaPassword $password `
            -RunId 'synthetic-hyperv-run' `
            -InstanceId 'primary' `
            -GuestCredential $guestCredential `
            -DatabaseName 'HyperVBaseline' `
            -Key $hyperVKey `
            -StateRoot $stateRoot `
            -TestDataRoot $testDataRoot
        $hyperVInstall = Install-LabSampleDatabase `
            -Provider hyperv `
            -Port 1433 `
            -SaPassword $password `
            -RunId 'synthetic-hyperv-run' `
            -InstanceId 'primary' `
            -GuestCredential $guestCredential `
            -RestoreDefinition $hyperVDefinition `
            -SqlVersion '2022' `
            -NonInteractive `
            -RunDirectory $runDirectory `
            -StateRoot $stateRoot `
            -TestDataRoot $testDataRoot

        $allBaselineSql = $script:baselineSql -join "`n"
        $lockPath = Join-Path $runDirectory 'manifest.lock.json'
        $manifestLock = if (Test-Path -LiteralPath $lockPath -PathType Leaf) {
            Get-Content -LiteralPath $lockPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 30
        }
        else {
            $null
        }
        $singleLock = @($manifestLock.artifacts | Where-Object sampleId -eq 'runtime-baseline')[0]
        $bundleLock = @($manifestLock.artifacts | Where-Object sampleId -eq 'runtime-bundle')[0]
        $hyperVLock = @($manifestLock.artifacts | Where-Object sampleId -eq 'runtime-hyperv-baseline')[0]

        [PSCustomObject]@{
            Generated = $generated.Status -eq 'BASELINE_REGISTERED' -and (Test-Path -LiteralPath $generated.Path -PathType Leaf)
            SqlVerified = $allBaselineSql -match 'WITH COPY_ONLY, INIT, CHECKSUM' -and $allBaselineSql -match 'RESTORE VERIFYONLY' -and $allBaselineSql -match 'WITH CHECKSUM'
            Preferred = $install.Success -and $install.Artifact.IntegrityOrigin -eq 'LAB_GENERATED' -and $script:restoreSources -contains $generated.Path
            OriginalSkipped = $script:originalResolverCalls -eq 0
            MultiGenerated = $generatedBundle.Record.artifactFormat -eq 'multi-database-zip' -and (Test-Path -LiteralPath $generatedBundle.Path -PathType Leaf)
            MultiPreferred = $bundleInstall.Success -and $bundleInstall.Artifact.ArtifactFormat -eq 'multi-database-zip' -and @($script:restoreSources | Where-Object { $_ -match 'Runtime(One|Two)\.bak$' }).Count -eq 2
            HyperVGenerated = $hyperVGenerated.Status -eq 'BASELINE_REGISTERED' -and
                $hyperVGenerated.Provider -eq 'hyperv' -and
                @($script:hyperVExportPaths).Count -eq 1 -and
                @($script:hyperVRemovePaths).Count -eq 1 -and
                $script:hyperVExportPaths[0] -eq $script:hyperVRemovePaths[0] -and
                $script:hyperVExportPaths[0] -like 'V:\SQLLab\Backup\baseline-*.bak'
            HyperVPreferred = $hyperVInstall.Success -and
                $hyperVInstall.Artifact.IntegrityOrigin -eq 'LAB_GENERATED' -and
                @($script:hyperVRestoreCalls).Count -eq 1 -and
                $script:hyperVRestoreCalls[0].RunId -eq 'synthetic-hyperv-run' -and
                $script:hyperVRestoreCalls[0].InstanceId -eq 'primary' -and
                $script:hyperVRestoreCalls[0].Credential.UserName -eq 'Administrator' -and
                $script:hyperVRestoreCalls[0].BackupSource -eq $hyperVGenerated.Path
            HyperVMissingCredentialMessage = $missingCredentialMessage
            HyperVUnverifiedReceiptMessage = $unverifiedReceiptMessage
            BaselineLockBound = $manifestLock -and @($manifestLock.artifacts).Count -eq 3 -and
                $singleLock.sha256 -eq $sourceSha -and
                $singleLock.integrityOrigin -eq 'catalog-verified' -and
                $singleLock.resolvedArtifact.origin -eq 'LAB_GENERATED' -and
                $singleLock.resolvedArtifact.keyId -eq $generated.Record.keyId -and
                $singleLock.resolvedArtifact.sha256 -eq $generated.Record.backupSha256 -and
                $singleLock.resolvedArtifact.artifactFormat -eq 'database-backup' -and
                $bundleLock.resolvedArtifact.keyId -eq $generatedBundle.Record.keyId -and
                $bundleLock.resolvedArtifact.sha256 -eq $generatedBundle.Record.backupSha256 -and
                $bundleLock.resolvedArtifact.artifactFormat -eq 'multi-database-zip' -and
                $hyperVLock.resolvedArtifact.keyId -eq $hyperVGenerated.Record.keyId -and
                $hyperVLock.resolvedArtifact.sha256 -eq $hyperVGenerated.Record.backupSha256 -and
                $hyperVLock.resolvedArtifact.artifactFormat -eq 'database-backup'
            BaselineLockPortable = $manifestLock -and (($manifestLock | ConvertTo-Json -Depth 30) -notmatch [regex]::Escape($Root))
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Verifiziertes Single-Output-Sample wird als LAB_GENERATED registriert' -Success $result.Generated
    Add-CheckResult -Name 'Baseline-Erzeugung verwendet BACKUP CHECKSUM und RESTORE VERIFYONLY' -Success $result.SqlVerified
    Add-CheckResult -Name 'Verifizierte Baseline wird vor dem Originalartefakt wiederhergestellt' -Success $result.Preferred
    Add-CheckResult -Name 'Originalresolver bleibt bei Baseline-Hit unangetastet' -Success $result.OriginalSkipped
    Add-CheckResult -Name 'Multi-Output-Sample wird als typisiertes ZIP registriert' -Success $result.MultiGenerated
    Add-CheckResult -Name 'Multi-Output-Baseline stellt exakt alle erwarteten Backups wieder her' -Success $result.MultiPreferred
    Add-CheckResult -Name 'Hyper-V exportiert LAB_GENERATED nur aus der verifizierten Backup-Lane und räumt die Gastkopie auf' -Success $result.HyperVGenerated
    Add-CheckResult -Name 'Hyper-V bevorzugt die registrierte Baseline und nutzt den run-gebundenen Restorepfad' -Success $result.HyperVPreferred
    Add-CheckResult -Name 'Hyper-V-Baseline blockiert ohne Run- und Gastcredential vor dem Backup' -Success (
        $result.HyperVMissingCredentialMessage -match 'SAMPLE_BASELINE_HYPERV_RUN_AND_GUEST_CREDENTIAL_REQUIRED'
    )
    Add-CheckResult -Name 'Hyper-V-Baseline blockiert bei nicht verifiziertem Storage-Receipt' -Success (
        $result.HyperVUnverifiedReceiptMessage -match 'SAMPLE_BASELINE_HYPERV_VERIFIED_RECEIPT_REQUIRED'
    )
    Add-CheckResult -Name 'Hyper-V-Gastexport prüft VM-Zustand, Quelldatei und Hostkopie' -Success (
        $storageOperationsText -match 'function Copy-LabFileFromHyperVGuest' -and
        $storageOperationsText -match 'HYPERV_STORAGE_FILE_COPY_VM_NOT_RUNNING' -and
        $storageOperationsText -match 'Copy-Item -LiteralPath \$SourcePath -Destination \$DestinationPath -FromSession' -and
        $storageOperationsText -match 'HYPERV_STORAGE_GUEST_EXPORT_SOURCE_INVALID' -and
        $storageOperationsText -match 'HYPERV_STORAGE_GUEST_EXPORT_FAILED'
    )
    Add-CheckResult -Name 'Baseline-Hit bindet Originalvertrag und aufgeloestes LAB_GENERATED-Artifact im Run Lock' -Success $result.BaselineLockBound
    Add-CheckResult -Name 'Baseline-Run-Lock enthaelt keine lokalen Pfade' -Success $result.BaselineLockPortable
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
