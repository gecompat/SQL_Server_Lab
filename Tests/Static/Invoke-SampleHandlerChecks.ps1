#Requires -Version 7.2
<#
.SYNOPSIS
    Prueft die Sample-Handler-Vertraege ohne Netzwerk, Container oder SQL Server.
.DESCRIPTION
    Validiert Katalogfilterung, Sample-Aufloesung, Idempotenz- und Trust-Metadaten,
    ZIP-Payload-Schutz sowie den nicht interaktiven TRUST_REQUIRED-Pfad. Es werden
    nur temporaere, synthetische State-Dateien verwendet.
#>
[CmdletBinding()]
param(
    [Alias('h','help','?')][switch]$ShowHelp,
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$RemainingArgs)

$showHelpRequested = $ShowHelp.IsPresent -or @($RemainingArgs) -contains '/?' -or @($RemainingArgs) -contains '-?' -or @($RemainingArgs) -contains '-h' -or @($RemainingArgs) -contains '--help'

if ($showHelpRequested) {

    Get-Help -Full -Name $PSCommandPath | Out-Host

    return

}

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$consolePath = Join-Path $repoRoot 'Public/Invoke-SqlServerLab.ps1'
$restorePath = Join-Path $repoRoot 'Public/Restore-SqlServerLabDatabase.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Sample Handler Checks' -ForegroundColor Cyan

$consoleText = Get-Content -LiteralPath $consolePath -Raw -Encoding utf8
$restoreText = Get-Content -LiteralPath $restorePath -Raw -Encoding utf8

$temporaryRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-lab-sample-check-$([guid]::NewGuid().ToString('N'))"
try {
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    Import-Module $modulePath -Force -ErrorAction Stop
    $module = Get-Module SqlServerLab

    $result = & $module {
        param($StateRoot)

        $env:SQL_SERVER_LAB_TEST_DATA_ROOT = Join-Path $StateRoot 'Testdaten'
        $allVariants = @(Get-LabExecutableSampleVariant)
        $variants2019 = @(Get-LabExecutableSampleVariant -SqlVersion '2019')
        $variants2022 = @(Get-LabExecutableSampleVariant -SqlVersion '2022-CU16')
        $variants2025 = @(Get-LabExecutableSampleVariant -SqlVersion '2025')

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

        $scriptContract = Resolve-LabSampleRestore `
            -SampleDefinition ([PSCustomObject]@{ id = 'northwind'; variant = 'script' }) `
            -SqlVersion '2022' `
            -TargetDatabaseName 'Northwind'

        Add-Type -AssemblyName System.IO.Compression -ErrorAction Stop
        $zipPath = Join-Path $StateRoot 'archive.zip'
        $zipWorking = Join-Path $StateRoot 'zip-source'
        New-Item -Path $zipWorking -ItemType Directory -Force | Out-Null
        $backupPath = Join-Path $zipWorking 'nested/sample.bak'
        New-Item -Path (Split-Path -Parent $backupPath) -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText($backupPath, 'static-check-backup')
        [System.IO.Compression.ZipFile]::CreateFromDirectory($zipWorking, $zipPath)
        $archivePayload = Get-LabArchiveBackupPayload -ArchivePath $zipPath -PayloadPath 'nested/sample.bak' -ArchiveFormat zip -RunDirectory $StateRoot
        $archivePayloadWorks = (Test-Path -LiteralPath $archivePayload.Path -PathType Leaf) -and
            ([System.IO.File]::ReadAllText($archivePayload.Path) -eq 'static-check-backup')
        Remove-Item -LiteralPath $archivePayload.WorkingDirectory -Recurse -Force

        $sevenZipPayloadWorks = $true
        $sevenZip = Get-Lab7ZipExecutable
        if ($sevenZip) {
            $sevenZipSource = Join-Path $StateRoot 'seven-zip-source'
            New-Item -Path (Join-Path $sevenZipSource 'nested') -ItemType Directory -Force | Out-Null
            [System.IO.File]::WriteAllText((Join-Path $sevenZipSource 'nested/sample.bak'), 'static-check-7z-backup')
            $sevenZipArchive = Join-Path $StateRoot 'archive.7z'
            Push-Location $sevenZipSource
            try {
                & ([string]$sevenZip.Path) a -t7z $sevenZipArchive 'nested/sample.bak' | Out-Null
                if ($LASTEXITCODE -ne 0) { throw "Statisches 7z-Testarchiv konnte nicht erstellt werden (ExitCode $LASTEXITCODE)." }
            }
            finally { Pop-Location }
            $sevenZipPayload = Get-LabArchiveBackupPayload -ArchivePath $sevenZipArchive -PayloadPath 'nested/sample.bak' -ArchiveFormat 7z -RunDirectory $StateRoot
            $sevenZipPayloadWorks = (Test-Path -LiteralPath $sevenZipPayload.Path -PathType Leaf) -and
                ([System.IO.File]::ReadAllText($sevenZipPayload.Path) -eq 'static-check-7z-backup')
            Remove-Item -LiteralPath $sevenZipPayload.WorkingDirectory -Recurse -Force
        }

        $dummyPassword = ConvertTo-SecureString 'Static-Check-Only-1!' -AsPlainText -Force
        $handlerResult = Install-LabSampleDatabase `
            -Port 14330 `
            -SaPassword $dummyPassword `
            -ContainerName 'static-check-none' `
            -RestoreDefinition $resolved `
            -NonInteractive `
            -TestDataRoot (Join-Path $StateRoot 'Testdaten') `
            -StateRoot $StateRoot

        $scriptSourcePath = Join-Path $StateRoot 'northwind.sql'
        [System.IO.File]::WriteAllText($scriptSourcePath, 'SELECT 1;')
        $originalResolver = (Get-Command Resolve-LabArtifact).ScriptBlock
        $originalQuery = (Get-Command Invoke-SqlQuery).ScriptBlock
        $originalCreateDatabase = (Get-Command New-SqlServerLabDatabase).ScriptBlock
        $originalScript = (Get-Command Invoke-LabSqlScript).ScriptBlock
        try {
            $script:SampleHandlerQueryCalls = 0
            Set-Item Function:Resolve-LabArtifact -Value {
                [PSCustomObject]@{ Status = 'ARTIFACT_READY'; Message = 'static'; Path = $scriptSourcePath; Sha256 = 'a' * 64 }
            }
            Set-Item Function:Invoke-SqlQuery -Value {
                $script:SampleHandlerQueryCalls++
                if ($script:SampleHandlerQueryCalls -ge 2) { return @('ONLINE') }
                return @()
            }
            Set-Item Function:New-SqlServerLabDatabase -Value { [PSCustomObject]@{ Success = $true } }
            Set-Item Function:Invoke-LabSqlScript -Value { [PSCustomObject]@{ Success = $true; Message = 'static script'; Batches = 1 } }
            $scriptHandlerResult = Install-LabSampleDatabase `
                -Port 14330 `
                -SaPassword $dummyPassword `
                -ContainerName 'static-check-none' `
                -RestoreDefinition $scriptContract `
                -StateRoot $StateRoot
        }
        finally {
            Set-Item Function:Resolve-LabArtifact -Value $originalResolver
            Set-Item Function:Invoke-SqlQuery -Value $originalQuery
            Set-Item Function:New-SqlServerLabDatabase -Value $originalCreateDatabase
            Set-Item Function:Invoke-LabSqlScript -Value $originalScript
            Remove-Variable SampleHandlerQueryCalls -Scope Script -ErrorAction SilentlyContinue
        }

        $status = Get-LabSampleArtifactLocalStatus `
            -Source $resolved.source `
            -SampleId $resolved.sampleId `
            -SampleVariant $resolved.sampleVariant `
            -TestDataRoot (Join-Path $StateRoot 'Testdaten') `
            -StateRoot $StateRoot

        $wideWorldMoves = @(New-LabRestoreMoveStatements `
            -FileListOutput @(
                'WWI_Primary|D:\\Program Files\\Microsoft SQL Server\\MSSQL13.SQL16\\MSSQL\\DATA\\WideWorldImporters.mdf|D|PRIMARY',
                'WWI_Log|D:\\Program Files\\Microsoft SQL Server\\MSSQL13.SQL16\\MSSQL\\DATA\\WideWorldImporters.ldf|L|NULL',
                'WWI_InMemory_Data_1|D:\\Program Files\\Microsoft SQL Server\\MSSQL13.SQL16\\MSSQL\\DATA\\WideWorldImporters_InMemory_Data_1|S|WWI_InMemory_Data'
            ) `
            -DataPath '/var/opt/mssql/data' `
            -DatabaseName 'WideWorldImporters')

        [PSCustomObject]@{
            AllExecutableSupported = @($allVariants | Where-Object { $_.ArtifactType -notin @('backup', 'archive-backup', 'sql-script') }).Count -eq 0
            NoDescriptiveVariants = @($allVariants | Where-Object { $_.SampleId -eq 'stackoverflow-50gb' }).Count -eq 0
            VersionFilterWorks    = @($variants2019 | Where-Object { $_.MinSqlVersion -eq '2022' }).Count -eq 0 -and
                @($variants2022 | Where-Object { $_.SampleId -eq 'adventureworks-2022' }).Count -gt 0
            CurrentMicrosoftBackups = @($variants2025 | Where-Object {
                $_.SampleId -in @('adventureworks-2025', 'adventureworks-dw-2025') -and
                $_.Source -match '^https://github\.com/microsoft/sql-server-samples/releases/download/adventureworks/AdventureWorks'
            }).Count -eq 3 -and
                @($variants2019 | Where-Object { $_.SampleId -eq 'adventureworks-dw-2019' }).Count -eq 1
            ContosoBackups = @($variants2019 | Where-Object {
                $_.SampleId -eq 'contoso-data-generator' -and
                $_.Source -match '^https://github\.com/sql-bi/Contoso-Data-Generator/releases/download/v1\.0\.0/Contoso\.(10K|100K|1M|10M)\.bak$' -and
                $_.ExpectedDatabase -match '^Contoso(10K|100K|1M|10M)$'
            }).Count -eq 4
            ResolvedContract      = $resolved.replace -eq $false -and
                $resolved.idempotencyMode -eq 'fail-if-exists' -and
                $resolved.trustPolicy -eq 'interactive-once' -and
                $resolved.sampleId -eq 'adventureworks-2022' -and
                $resolved.downloadSizeMB -gt 0
            WrongNameRejected     = $wrongNameRejected
            DescriptiveRejected   = $descriptiveRejected
            ScriptContractWorks   = $scriptContract.artifactType -eq 'sql-script' -and
                $scriptContract.installation.executionMode -eq 'existing-database'
            ScriptHandlerWorks    = $scriptHandlerResult.Status -eq 'DATASET_READY' -and $scriptHandlerResult.Success
            ArchivePayloadWorks   = $archivePayloadWorks
            SevenZipPayloadWorks  = $sevenZipPayloadWorks
            TrustRequired         = $handlerResult.Status -eq 'TRUST_REQUIRED' -and -not $handlerResult.Success
            LocalStatusUntrusted  = $status.TrustStatus -eq 'TRUST_REQUIRED' -and $status.CacheStatus -eq 'MISS'
            InMemoryMoveWorks     = $wideWorldMoves.Count -eq 3 -and
                $wideWorldMoves -contains "MOVE N'WWI_InMemory_Data_1' TO N'/var/opt/mssql/data/WideWorldImporters_SpecialData1'"
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Katalogliste enthaelt nur freigegebene Sample-Handler-Varianten' -Success $result.AllExecutableSupported
    Add-CheckResult -Name 'Beschreibende Attach-Varianten bleiben ausgeschlossen' -Success $result.NoDescriptiveVariants
    Add-CheckResult -Name 'Versionsfilter beruecksichtigt minSqlVersion und CU-Bezeichner' -Success $result.VersionFilterWorks
    Add-CheckResult -Name 'Aktuelle Microsoft-Backups fuer AdventureWorks und Data Warehouse sind katalogisiert' -Success $result.CurrentMicrosoftBackups
    Add-CheckResult -Name 'Contoso-Backups sind als direkt restaurierbare Groessenvarianten katalogisiert' -Success $result.ContosoBackups
    Add-CheckResult -Name 'Sample-Aufloesung liefert Trust-, Idempotenz- und Groessenvertrag' -Success $result.ResolvedContract
    Add-CheckResult -Name 'Abweichender Zieldatenbankname wird abgelehnt' -Success $result.WrongNameRejected
    Add-CheckResult -Name 'Beschreibende Varianten werden nicht ausgefuehrt' -Success $result.DescriptiveRejected
    Add-CheckResult -Name 'SQL-Skript-Sample liefert einen typisierten Installationsvertrag' -Success $result.ScriptContractWorks
    Add-CheckResult -Name 'SQL-Skript-Handler erstellt Ziel und verifiziert die Datenbank' -Success $result.ScriptHandlerWorks
    Add-CheckResult -Name 'ZIP-Backup-Payload wird nur im temporaeren Arbeitsbereich extrahiert' -Success $result.ArchivePayloadWorks
    Add-CheckResult -Name '7z-Backup-Payload wird bei verfügbarem 7-Zip sicher extrahiert' -Success $result.SevenZipPayloadWorks
    Add-CheckResult -Name 'Nicht interaktiver Handler ohne Trust endet mit TRUST_REQUIRED' -Success $result.TrustRequired
    Add-CheckResult -Name 'Lokaler Trust-/Cache-Status wird read-only gemeldet' -Success $result.LocalStatusUntrusted
    Add-CheckResult -Name 'In-Memory-OLTP-Container wird beim Restore per MOVE in den Linux-Datenpfad umgeleitet' -Success $result.InMemoryMoveWorks
    Add-CheckResult -Name 'Konsolenaktion Datenbank anlegen bietet den Sample-Katalog an' -Success (
        $consoleText -match "Testdatenbank aus dem Katalog wiederherstellen" -and
        $consoleText -match 'Select-LabSampleSelection -SqlVersion \$target.Version -SkipInitialConfirm' -and
        $consoleText -match 'Install-LabSampleDatabase -HostName \$target.HostName' -and
        $consoleText -match '\[switch\]\$SkipInitialConfirm'
    )
    Add-CheckResult -Name 'Restore erkennt docker oder podman ohne leeren Provider-Parameter automatisch' -Success (
        $restoreText -match '\$restoreTargetArguments = @\{' -and
        $restoreText -match 'if \(\$Provider\) \{ \$restoreTargetArguments.Provider = \$Provider \}' -and
        $restoreText -match 'Resolve-LabRestoreContainer @restoreTargetArguments'
    )
    Add-CheckResult -Name 'FILELISTONLY verwirft sqlcmd-Leerzeilen vor der MOVE-Erzeugung' -Success (
        $restoreText -match "-h -1" -and
        $restoreText -match '\$fileListLines = @\(' -and
        $restoreText -match 'FILELISTONLY lieferte keine Dateizeilen' -and
        $restoreText -match 'New-LabRestoreMoveStatements -FileListOutput \$fileListLines'
    )
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



