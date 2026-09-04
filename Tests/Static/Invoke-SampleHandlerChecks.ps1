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
$sampleHandlerPath = Join-Path $repoRoot 'Private/SampleArtifactHandlers.ps1'
$newLabPath = Join-Path $repoRoot 'Public/New-SqlServerLab.ps1'
$failures = [System.Collections.Generic.List[string]]::new()
$passed = 0

. (Join-Path $PSScriptRoot '..' 'Common' 'CheckResult.ps1')

Write-Host ''
Write-Host 'SQL_Server_Lab - Sample Handler Checks' -ForegroundColor Cyan

$consoleText = Get-Content -LiteralPath $consolePath -Raw -Encoding utf8
$restoreText = Get-Content -LiteralPath $restorePath -Raw -Encoding utf8
$sampleHandlerText = Get-Content -LiteralPath $sampleHandlerPath -Raw -Encoding utf8
$newLabText = Get-Content -LiteralPath $newLabPath -Raw -Encoding utf8

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
            $wrongNameRejected = $_.Exception.Message -match 'erwartet als fuehrende Datenbank'
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

        $bacpacContract = Resolve-LabSampleRestore `
            -SampleDefinition ([PSCustomObject]@{ id = 'wideworldimporters'; variant = 'bacpac-standard' }) `
            -SqlVersion '2022' `
            -TargetDatabaseName 'WideWorldImporters'

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

        $attachZipSource = Join-Path $StateRoot 'attach-zip-source'
        New-Item -Path (Join-Path $attachZipSource 'payload') -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $attachZipSource 'payload/sample.mdf'), 'primary')
        [System.IO.File]::WriteAllText((Join-Path $attachZipSource 'payload/sample_log.ldf'), 'log')
        $attachZipPath = Join-Path $StateRoot 'attach.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($attachZipSource, $attachZipPath)
        $attachArchivePayloads = Get-LabArchiveAttachPayloads -ArchivePath $attachZipPath -ArchiveFormat zip -PayloadLayout @(
            [PSCustomObject]@{ path = 'payload/sample.mdf'; role = 'primary' },
            [PSCustomObject]@{ path = 'payload/sample_log.ldf'; role = 'log' }
        ) -RunDirectory $StateRoot
        $attachArchivePayloadWorks = @($attachArchivePayloads.Payloads).Count -eq 2 -and
            ([System.IO.File]::ReadAllText($attachArchivePayloads.Payloads[0].Path) -eq 'primary') -and
            ([System.IO.File]::ReadAllText($attachArchivePayloads.Payloads[1].Path) -eq 'log')
        Remove-Item -LiteralPath $attachArchivePayloads.WorkingDirectory -Recurse -Force

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

        $attachPayloadLayout = Get-LabAttachPayloadLayout -PayloadLayout @(
            [PSCustomObject]@{ path = 'data/StackOverflow.mdf'; role = 'primary' },
            [PSCustomObject]@{ path = 'data/StackOverflow_Archive.ndf'; role = 'data' },
            [PSCustomObject]@{ path = 'data/StackOverflow_log.ldf'; role = 'log' }
        )
        $unsafeAttachLayoutRejected = $false
        try {
            $null = Get-LabAttachPayloadLayout -PayloadLayout @(
                [PSCustomObject]@{ path = '../outside.mdf'; role = 'primary' },
                [PSCustomObject]@{ path = 'data/inside.ldf'; role = 'log' }
            )
        }
        catch { $unsafeAttachLayoutRejected = $_.Exception.Message -match 'SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID' }
        $duplicateAttachLayoutRejected = $false
        try {
            $null = Get-LabAttachPayloadLayout -PayloadLayout @(
                [PSCustomObject]@{ path = 'data/same.mdf'; role = 'primary' },
                [PSCustomObject]@{ path = 'data/same.mdf'; role = 'data' },
                [PSCustomObject]@{ path = 'data/same.ldf'; role = 'log' }
            )
        }
        catch { $duplicateAttachLayoutRejected = $_.Exception.Message -match 'SAMPLE_ATTACH_PAYLOAD_LAYOUT_INVALID' }

        $schemaPath = Join-Path $script:SchemasPath 'sample-databases.schema.json'
        $attachContractCatalog = Get-Content -LiteralPath (Join-Path $script:CatalogsPath 'sample-databases.json') -Raw | ConvertFrom-Json -Depth 100
        $attachContractVariant = $attachContractCatalog.databases | Where-Object id -eq 'stackoverflow-50gb' | ForEach-Object { $_.versions.'10gb' } | Select-Object -First 1
        $attachContractVariant.runtimeStatus = 'executable'
        $attachContractVariant.installation.payloadSelection = 'catalog-path'
        $attachContractVariant.installation | Add-Member -NotePropertyName payloadLayout -NotePropertyValue @(
            [PSCustomObject]@{ path = 'payload/StackOverflow2010.mdf'; role = 'primary' },
            [PSCustomObject]@{ path = 'payload/StackOverflow2010_log.ldf'; role = 'log' }
        )
        $trustBoundAttachSchemaWorks = (($attachContractCatalog | ConvertTo-Json -Depth 100) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)
        $attachContractVariant.installation.payloadLayout = $null
        $missingAttachLayoutRejected = -not (($attachContractCatalog | ConvertTo-Json -Depth 100) | Test-Json -SchemaFile $schemaPath -ErrorAction SilentlyContinue)

        $containerAttachTarget = "/var/opt/mssql/data/sql-server-lab-attach-$([guid]::NewGuid().ToString('N'))"
        $containerAttachJournal = [ordered]@{
            ContractVersion = 'SqlServerLab.ContainerAttachJournal/1.0'
            RunId = [guid]::NewGuid().ToString()
            InstanceId = 'primary'
            DatabaseName = 'AttachStaticCheck'
            Status = 'COMPLETED'
            TargetDirectory = $containerAttachTarget
            CopyVerified = $true
            AttachInvoked = $true
            PostconditionVerified = $true
            Recovery = 'NOT_REQUIRED'
            UpdatedAt = Get-LabTimestamp
        }
        $containerAttachJournalPath = Join-Path $StateRoot 'container-attach-journal.json'
        $containerAttachJournalSchemaWorks = (Assert-LabContainerAttachJournal -Journal $containerAttachJournal) -and
            (Write-LabContainerAttachJournal -Journal $containerAttachJournal -Path $containerAttachJournalPath).UpdatedAt -and
            ((Get-Content -LiteralPath $containerAttachJournalPath -Raw | ConvertFrom-Json).Status -eq 'COMPLETED')
        $containerAttachFailureJournal = [ordered]@{
            ContractVersion = 'SqlServerLab.ContainerAttachJournal/1.0'
            RunId = [guid]::NewGuid().ToString()
            InstanceId = 'primary'
            DatabaseName = 'AttachStaticCheck'
            Status = 'RECOVERY_REQUIRED'
            TargetDirectory = $containerAttachTarget
            CopyVerified = $true
            AttachInvoked = $true
            PostconditionVerified = $false
            Recovery = 'DETACH_TARGET_COPY_AND_PRESERVE_TARGET'
            UpdatedAt = Get-LabTimestamp
        }
        $containerAttachFailureJournalWorks = Assert-LabContainerAttachJournal -Journal $containerAttachFailureJournal
        $containerAttachInvalidJournalRejected = $false
        $containerAttachInvalidJournal = $containerAttachFailureJournal | ConvertTo-Json -Depth 20 | ConvertFrom-Json
        $containerAttachInvalidJournal.PostconditionVerified = $true
        try { $null = Assert-LabContainerAttachJournal -Journal $containerAttachInvalidJournal }
        catch { $containerAttachInvalidJournalRejected = $_.Exception.Message -match 'CONTAINER_ATTACH_JOURNAL_STATE_INVALID' }

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

        $bundleSourceRoot = Join-Path $StateRoot 'bundle-source'
        $bundleWorkingRoot = Join-Path $bundleSourceRoot 'bundle'
        $bundleIncludeRoot = Join-Path $bundleWorkingRoot 'includes'
        New-Item -Path $bundleIncludeRoot -ItemType Directory -Force | Out-Null
        [System.IO.File]::WriteAllText((Join-Path $bundleWorkingRoot 'entry.sql'), @'
:setvar FirstDatabase BundleOne
CREATE DATABASE [$(FirstDatabase)];
:r includes/second.sql
GO
'@)
        [System.IO.File]::WriteAllText((Join-Path $bundleIncludeRoot 'second.sql'), @'
:setvar SecondDatabase BundleTwo
CREATE DATABASE [$(SecondDatabase)];
'@)
        $bundleArchivePath = Join-Path $StateRoot 'bundle.zip'
        [System.IO.Compression.ZipFile]::CreateFromDirectory($bundleSourceRoot, $bundleArchivePath)

        $bundleCatalogSample = [PSCustomObject]@{
            id = 'static-script-bundle'
            displayName = 'Static Script Bundle'
            description = 'Static only'
            category = 'training'
            license = 'test-only'
            source = 'https://example.invalid/static-script-bundle'
            minSqlVersion = '2019'
            versions = [PSCustomObject]@{
                full = [PSCustomObject]@{
                    url = 'https://example.invalid/static-script-bundle.zip'
                    artifactType = 'script-bundle'
                    handlerContractVersion = '1'
                    downloadSizeMB = 1
                    estimatedInstallSizeMB = 2
                    resourceEstimateStatus = 'catalog-estimated'
                    sha256 = $null
                    integrityOrigin = $null
                    trustPolicy = 'interactive-once'
                    compatibility = 150
                    expectedOutputs = @(
                        [PSCustomObject]@{ name = 'BundleOne'; kind = 'database' },
                        [PSCustomObject]@{ name = 'BundleTwo'; kind = 'database' }
                    )
                    installation = [PSCustomObject]@{
                        kind = 'script-bundle'
                        entrypoint = 'entry.sql'
                        workingDirectory = 'bundle'
                        executionMode = 'self-creates-databases'
                        allowedSqlcmdFeatures = @('go', 'include', 'setvar')
                        timeoutSeconds = 300
                        idempotencyMode = 'fail-if-exists'
                        partialFailurePolicy = 'recovery-required'
                        baselinePolicy = 'none'
                    }
                    runtimeStatus = 'executable'
                }
            }
        }
        $originalSampleCatalog = (Get-Command Get-LabSampleDatabase).ScriptBlock
        try {
            Set-Item Function:Get-LabSampleDatabase -Value { $bundleCatalogSample }
            $bundleContract = Resolve-LabSampleRestore `
                -SampleDefinition ([PSCustomObject]@{ id = 'static-script-bundle'; variant = 'full' }) `
                -SqlVersion '2022' `
                -TargetDatabaseName 'BundleOne'
        }
        finally {
            Set-Item Function:Get-LabSampleDatabase -Value $originalSampleCatalog
        }

        $originalResolver = (Get-Command Resolve-LabArtifact).ScriptBlock
        $originalQuery = (Get-Command Invoke-SqlQuery).ScriptBlock
        $originalCreateDatabase = (Get-Command New-SqlServerLabDatabase).ScriptBlock
        $originalScript = (Get-Command Invoke-LabSqlScript).ScriptBlock
        try {
            $script:SampleHandlerQueryCalls = 0
            $script:SampleHandlerExpectedDatabases = 1
            $script:UseBundleArtifact = $false
            $script:BundleFlattenedContent = $null
            $script:BundleScriptDatabase = $null
            $script:BundleWorkingDirectory = $null
            Set-Item Function:Resolve-LabArtifact -Value {
                $path = if ($script:UseBundleArtifact) { $bundleArchivePath } else { $scriptSourcePath }
                [PSCustomObject]@{ Status = 'ARTIFACT_READY'; Message = 'static'; Path = $path; Sha256 = 'a' * 64 }
            }
            Set-Item Function:Invoke-SqlQuery -Value {
                $script:SampleHandlerQueryCalls++
                if ($script:SampleHandlerQueryCalls -gt $script:SampleHandlerExpectedDatabases) { return @('ONLINE') }
                return @()
            }
            Set-Item Function:New-SqlServerLabDatabase -Value { [PSCustomObject]@{ Success = $true } }
            Set-Item Function:Invoke-LabSqlScript -Value {
                param($ScriptPath, $HostName, $Port, $SaPassword, $Database, [switch]$KeepConnection, $TimeoutSeconds)
                if ($script:UseBundleArtifact) {
                    $script:BundleFlattenedContent = Get-Content -LiteralPath $ScriptPath -Raw
                    $script:BundleScriptDatabase = $Database
                    $script:BundleWorkingDirectory = Split-Path -Parent $ScriptPath
                }
                [PSCustomObject]@{ Success = $true; Message = 'static script'; Batches = 1 }
            }
            $scriptHandlerResult = Install-LabSampleDatabase `
                -Port 14330 `
                -SaPassword $dummyPassword `
                -ContainerName 'static-check-none' `
                -RestoreDefinition $scriptContract `
                -StateRoot $StateRoot

            $script:SampleHandlerQueryCalls = 0
            $script:SampleHandlerExpectedDatabases = 2
            $script:UseBundleArtifact = $true
            $bundleHandlerResult = Install-LabSampleDatabase `
                -Port 14330 `
                -SaPassword $dummyPassword `
                -ContainerName 'static-check-none' `
                -RestoreDefinition $bundleContract `
                -RunDirectory $StateRoot `
                -StateRoot $StateRoot
            $bundleWorkingDirectoryRemoved = -not (Test-Path -LiteralPath $script:BundleWorkingDirectory)
        }
        finally {
            Set-Item Function:Resolve-LabArtifact -Value $originalResolver
            Set-Item Function:Invoke-SqlQuery -Value $originalQuery
            Set-Item Function:New-SqlServerLabDatabase -Value $originalCreateDatabase
            Set-Item Function:Invoke-LabSqlScript -Value $originalScript
            Remove-Variable SampleHandlerQueryCalls -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable SampleHandlerExpectedDatabases -Scope Script -ErrorAction SilentlyContinue
            Remove-Variable UseBundleArtifact -Scope Script -ErrorAction SilentlyContinue
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
            AllExecutableSupported = @($allVariants | Where-Object { $_.ArtifactType -notin @('backup', 'archive-backup', 'sql-script', 'script-bundle', 'bacpac') }).Count -eq 0
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
            BacpacContractWorks   = $bacpacContract.artifactType -eq 'bacpac' -and
                $bacpacContract.installation.importMode -eq 'sqlpackage' -and
                $bacpacContract.idempotencyMode -eq 'fail-if-exists' -and
                $bacpacContract.installation.baselinePolicy -eq 'not-eligible' -and
                $bacpacContract.source -match 'WideWorldImporters-Standard\.bacpac$'
            ScriptHandlerWorks    = $scriptHandlerResult.Status -eq 'DATASET_READY' -and $scriptHandlerResult.Success
            BundleContractWorks   = $bundleContract.artifactType -eq 'script-bundle' -and
                @($bundleContract.expectedOutputs).Count -eq 2 -and
                @($bundleContract.installation.allowedSqlcmdFeatures) -contains 'include'
            BundleHandlerWorks    = $bundleHandlerResult.Status -eq 'DATASET_READY' -and
                $bundleHandlerResult.Success -and
                @($bundleHandlerResult.DatabaseNames).Count -eq 2 -and
                $script:BundleScriptDatabase -eq 'master' -and
                $script:BundleFlattenedContent -match 'CREATE DATABASE \[BundleOne\]' -and
                $script:BundleFlattenedContent -match 'CREATE DATABASE \[BundleTwo\]' -and
                $script:BundleFlattenedContent -notmatch '(?im)^\s*:(?:r|setvar)' -and
                $bundleWorkingDirectoryRemoved
            ArchivePayloadWorks   = $archivePayloadWorks
            AttachArchivePayloadWorks = $attachArchivePayloadWorks
            SevenZipPayloadWorks  = $sevenZipPayloadWorks
            AttachPayloadLayoutWorks = @($attachPayloadLayout).Count -eq 3 -and $attachPayloadLayout[0].Role -eq 'primary' -and $attachPayloadLayout[2].Role -eq 'log'
            UnsafeAttachLayoutRejected = $unsafeAttachLayoutRejected
            DuplicateAttachLayoutRejected = $duplicateAttachLayoutRejected
            TrustBoundAttachSchemaWorks = $trustBoundAttachSchemaWorks
            MissingAttachLayoutRejected = $missingAttachLayoutRejected
            ContainerAttachJournalSchemaWorks = $containerAttachJournalSchemaWorks
            ContainerAttachFailureJournalWorks = $containerAttachFailureJournalWorks
            ContainerAttachInvalidJournalRejected = $containerAttachInvalidJournalRejected
            TrustRequired         = $handlerResult.Status -eq 'TRUST_REQUIRED' -and -not $handlerResult.Success
            LocalStatusUntrusted  = $status.TrustStatus -eq 'TRUST_REQUIRED' -and $status.CacheStatus -eq 'MISS'
            InMemoryMoveWorks     = $wideWorldMoves.Count -eq 3 -and
                $wideWorldMoves -contains "MOVE N'WWI_InMemory_Data_1' TO N'/var/opt/mssql/data/WideWorldImporters_SpecialData1'"
        }
    } $temporaryRoot

    Add-CheckResult -Name 'Katalogliste enthaelt nur freigegebene Sample-Handler-Varianten' -Success $result.AllExecutableSupported
    Add-CheckResult -Name 'Beschreibende Attach-Varianten bleiben ausgeschlossen' -Success $result.NoDescriptiveVariants
    Add-CheckResult -Name 'Attach-Payload-Layout ist rollen- und pfadgebunden' -Success $result.AttachPayloadLayoutWorks
    Add-CheckResult -Name 'ZIP-Attach-Payloads werden exakt und isoliert extrahiert' -Success $result.AttachArchivePayloadWorks
    Add-CheckResult -Name 'Attach-Payload-Layout weist Traversal und doppelte Pfade ab' -Success ($result.UnsafeAttachLayoutRejected -and $result.DuplicateAttachLayoutRejected)
    Add-CheckResult -Name 'Ausfuehrbare Attach-Varianten koennen per Trust-Hash und Katalogpfad gebunden werden' -Success ($result.TrustBoundAttachSchemaWorks -and $result.MissingAttachLayoutRejected)
    Add-CheckResult -Name 'Container-Attach-Journal ist schema- und zeitstempelgebunden atomar persistiert' -Success $result.ContainerAttachJournalSchemaWorks
    Add-CheckResult -Name 'Container-Attach-Journal bildet erfolgreiche und fehlgeschlagene Recovery-Zustaende fail-closed ab' -Success ($result.ContainerAttachFailureJournalWorks -and $result.ContainerAttachInvalidJournalRejected)
    Add-CheckResult -Name 'Versionsfilter beruecksichtigt minSqlVersion und CU-Bezeichner' -Success $result.VersionFilterWorks
    Add-CheckResult -Name 'Aktuelle Microsoft-Backups fuer AdventureWorks und Data Warehouse sind katalogisiert' -Success $result.CurrentMicrosoftBackups
    Add-CheckResult -Name 'Contoso-Backups sind als direkt restaurierbare Groessenvarianten katalogisiert' -Success $result.ContosoBackups
    Add-CheckResult -Name 'Sample-Aufloesung liefert Trust-, Idempotenz- und Groessenvertrag' -Success $result.ResolvedContract
    Add-CheckResult -Name 'Abweichender Zieldatenbankname wird abgelehnt' -Success $result.WrongNameRejected
    Add-CheckResult -Name 'Beschreibende Varianten werden nicht ausgefuehrt' -Success $result.DescriptiveRejected
    Add-CheckResult -Name 'SQL-Skript-Sample liefert einen typisierten Installationsvertrag' -Success $result.ScriptContractWorks
    Add-CheckResult -Name 'Wide World Importers BACPAC liefert einen typisierten SqlPackage-Importvertrag' -Success $result.BacpacContractWorks
    Add-CheckResult -Name 'SQL-Skript-Handler erstellt Ziel und verifiziert die Datenbank' -Success $result.ScriptHandlerWorks
    Add-CheckResult -Name 'Script-Bundle-Aufloesung liefert mehrere typisierte Datenbankoutputs' -Success $result.BundleContractWorks
    Add-CheckResult -Name 'Script-Bundle-Handler expandiert sichere sqlcmd-Includes und verifiziert alle Outputs' -Success $result.BundleHandlerWorks
    Add-CheckResult -Name 'ZIP-Backup-Payload wird nur im temporaeren Arbeitsbereich extrahiert' -Success $result.ArchivePayloadWorks
    Add-CheckResult -Name '7z-Backup-Payload wird bei verfügbarem 7-Zip sicher extrahiert' -Success $result.SevenZipPayloadWorks
    Add-CheckResult -Name 'Nicht interaktiver Handler ohne Trust endet mit TRUST_REQUIRED' -Success $result.TrustRequired
    Add-CheckResult -Name 'Lokaler Trust-/Cache-Status wird read-only gemeldet' -Success $result.LocalStatusUntrusted
    Add-CheckResult -Name 'In-Memory-OLTP-Container wird beim Restore per MOVE in den Linux-Datenpfad umgeleitet' -Success $result.InMemoryMoveWorks
    Add-CheckResult -Name 'Konsolenaktion Datenbank anlegen bietet den Sample-Katalog an' -Success (
        $consoleText -match "Testdatenbank aus dem Katalog wiederherstellen" -and
        $consoleText -match 'Select-LabSampleSelection -SqlVersion \$target.Version -SkipInitialConfirm' -and
        $consoleText -match 'Install-LabSampleDatabase @handlerArguments' -and
        $consoleText -match '\[switch\]\$SkipInitialConfirm'
    )
    Add-CheckResult -Name 'Konsolen-Samplepfad bindet Hyper-V an Run, Gastcredential und Storage-Lane' -Success (
        $consoleText -match '\[string\]\$target\.Provider -eq ''hyperv''' -and
        $consoleText -match 'Gastpasswort für den gebundenen Backup-Transfer' -and
        $consoleText -match '\$handlerArguments.RunId=\$runId' -and
        $consoleText -match '\$handlerArguments.GuestCredential=\$guestCredential'
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
    Add-CheckResult -Name 'BACPAC-Handler bindet Container, Scope, Versionsprobe, temporäre Kopie und Cleanup fail-closed' -Success (
        $sampleHandlerText -match 'function Invoke-LabContainerBacpacImport' -and
        $sampleHandlerText -match 'sql-server-lab\.run-id' -and
        $sampleHandlerText -match 'sql-server-lab\.scope-id' -and
        $sampleHandlerText -match 'sql-server-lab\.container-tool\.ids' -and
        $sampleHandlerText -match 'sqlpackage /Version' -and
        $sampleHandlerText -match 'BACPAC_SQLPACKAGE_VERSION_MISMATCH' -and
        $sampleHandlerText -match 'BACPAC_CONTAINER_COPY_FAILED' -and
        $sampleHandlerText -match 'BACPAC_IMPORT_CLEANUP_FAILED' -and
        $sampleHandlerText -match 'rm -f -- \$containerArtifactPath'
    )
    Add-CheckResult -Name 'Ad-hoc-BACPAC-Sample bindet SqlPackage vor jeder Container-Mutation automatisch' -Success (
        $newLabText -match "artifactType -eq 'bacpac'" -and
        $newLabText -match 'id = ''sqlpackage''; version = \$null; variant = \$null; scope = ''instance''' -and
        $newLabText -match '-ContainerTools \$labInstance\.ContainerTools'
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



