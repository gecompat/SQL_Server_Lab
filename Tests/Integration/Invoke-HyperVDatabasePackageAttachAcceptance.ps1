#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den nativen oeffentlichen Hyper-V-Datenbankpaket-Attach-Nachweis aus.
.DESCRIPTION
    Verwendet wahlweise einen expliziten laufenden, verwalteten SQL-2025-Run
    oder erstellt aus einem Prepared-Artifact einen isolierten Run. Darin wird
    eine kleine Datenbank erzeugt und detached, in einem isolierten Lab_Data-
    Root publiziert und ueber den oeffentlichen pfadfreien Vertrag an denselben
    scopegebundenen Run attached.

    Der Test beweist die Live-Bindung an SQLs Default-Data-Verzeichnis,
    PowerShell-Direct-Kopie, Hashverifikation im Gast, Online-Postcondition,
    Inhaltsidentitaet und scopegebundenen Cleanup. FILESTREAM wird separat vom
    nativen Windows-SQL-Pakettest abgedeckt; dieser Lauf prueft den Hyper-V-
    Transport mit einer portablen MDF/NDF/LDF-Dateimenge.
.PARAMETER ArtifactId
    Optionales SQL_PREPARED_SEALED-Artifact. Ohne Angabe wird das neueste
    verifizierte SQL-2025-Artifact im State Root verwendet.
.PARAMETER StateRoot
    Optionaler State Root fuer Run- und Artifact-Aufloesung.
.PARAMETER RunId
    Optionaler bereits laufender, verwalteter Hyper-V-SQL-2025-Run. Sein
    DPAPI-geschuetztes Gast-Credential wird nur im Prozess geladen. Der Test
    erzeugt darin ausschliesslich eine zufaellig benannte Datenbank und entfernt
    Datenbank, Dateien und Operationsjournal wieder. Ohne RunId wird ein neuer
    Run aus ArtifactId erstellt.
.PARAMETER OobeTimeoutSeconds
    Timeout fuer Windows-Spezialisierung, CompleteImage und SQL-Readiness.
.PARAMETER KeepOnFailure
    Belaesst einen fehlgeschlagenen Run samt Journal fuer den Recovery-Pfad.
#>
[CmdletBinding()]
param(
    [string]$ArtifactId,
    [string]$StateRoot,
    [string]$RunId,
    [ValidateRange(300, 3600)][int]$OobeTimeoutSeconds = 1200,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('sql-lab-hv-package-attach-' + [Guid]::NewGuid().ToString('N'))
$dataRoot = Join-Path $testRoot 'Lab_Data'
$manifestPath = Join-Path $testRoot 'manifest.json'
$sourceCopyRoot = Join-Path $testRoot 'source-copy'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$previousDataRoot = $env:SQL_SERVER_LAB_DATA_ROOT
$module = $null
$lab = $null
$completed = $false
$targetContext = $null
$guestCredential = $null
$sourceGuestPaths = @()
$databaseMayExist = $false
$targetGuestDirectory = $null
$operationDirectory = $null
$databaseName = 'LabPkgHv_' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_HyperV_Database_Package_Attach_Acceptance')
$mutexAcquired = $false

function Assert-HyperVPackageAttachAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [string]$Evidence
    )
    if (-not $Condition) {
        throw "HYPERV_DATABASE_PACKAGE_ATTACH_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })"
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Invoke-Private {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$Arguments = @())
    & $module $ScriptBlock @Arguments
}

function Invoke-AcceptanceQuery {
    param(
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master'
    )
    if (-not $script:targetContext -or -not $script:guestCredential) {
        throw 'HYPERV_DATABASE_PACKAGE_QUERY_CONTEXT_MISSING'
    }
    $result = Invoke-Private {
        param($Context, $Credential, $Sql, $DatabaseName)
        Invoke-HyperVPowerShellDirect -VMName ([string]$Context.Instance.vmName) `
            -ExpectedRunId ([string]$Context.Run.runId) -ExpectedScopeId ([string]$Context.Run.scopeId) `
            -Credential $Credential -ArgumentList @($Sql, $DatabaseName) -ScriptBlock {
                param($Query, $Database)
                $ErrorActionPreference = 'Stop'
                Add-Type -AssemblyName System.Data
                $connection = [Data.SqlClient.SqlConnection]::new(
                    "Server=localhost;Database=$Database;Integrated Security=True;Encrypt=True;TrustServerCertificate=True;Connect Timeout=30;")
                try {
                    $connection.Open()
                    $command = $connection.CreateCommand()
                    $command.CommandTimeout = 180
                    $command.CommandText = $Query
                    $reader = $command.ExecuteReader()
                    while ($reader.Read()) {
                        if (-not $reader.IsDBNull(0)) { [string]$reader.GetValue(0) }
                    }
                    $reader.Dispose()
                }
                finally { $connection.Dispose() }
            }
    } @($script:targetContext, $script:guestCredential, $Query, $Database)
    return @($result)
}

function Write-AcceptanceManifest {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$LabName,
        [Parameter(Mandatory)][string]$PreparedArtifactId
    )
    $manifest = [ordered]@{
        '$schema' = (Join-Path $repoRoot 'Schemas/lab-manifest.schema.json')
        name = $LabName
        automation = [ordered]@{ mode = 'unattended' }
        instances = @([ordered]@{
            id = 'primary'; version = '2025'; provider = 'hyperv'; os = 'windows'; profile = 'standard'; autostart = 'off'
            network = [ordered]@{ intent = 'hostOnly'; exposure = 'host' }
            hyperv = [ordered]@{
                preparedImageId = $PreparedArtifactId; memoryStartupMB = 6144; processorCount = 4
                sqlPort = 1433; guestPasswordMode = 'prompt'
            }
            storageIntent = [ordered]@{
                contractVersion = 'SqlServerLab.StorageIntent/1.0'; placementPolicy = 'logical-only'; physicalIsolation = 'not-required'
                roles = [ordered]@{
                    defaultData = [ordered]@{ selector = 'default' }
                    defaultLog = [ordered]@{ selector = 'default' }
                    backup = [ordered]@{ selector = 'default' }
                }
                tempDb = [ordered]@{
                    distribution = 'single-location'; dataFileCount = 1; dataLocationSelectors = @('default')
                    logPlacement = [ordered]@{ selector = 'default'; logicalName = 'templog'; fileName = 'templog.ldf'; sizeMB = 64; growth = '32MB' }
                }
                databaseFiles = @(); restoreRules = @()
            }
        })
    }
    $manifest | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $Path -Encoding utf8
}

function Test-ScopedTemporaryRoot {
    param([Parameter(Mandatory)][string]$Path)
    $resolved = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\')
    $actualParent = [IO.Directory]::GetParent($resolved).FullName.TrimEnd('\')
    return $actualParent.Equals($expectedParent, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resolved) -match '^sql-lab-hv-package-attach-[a-f0-9]{32}$'
}

function Remove-GuestAcceptanceArtifacts {
    if (-not $script:targetContext -or -not $script:guestCredential) { return }
    $session = $null
    try {
        $session = New-PSSession -VMName ([string]$script:targetContext.Instance.vmName) `
            -Credential $script:guestCredential -ErrorAction Stop
        Invoke-Command -Session $session -ArgumentList @(
            @($script:sourceGuestPaths), $script:targetGuestDirectory, $script:databaseName
        ) -ScriptBlock {
            param($SourcePaths, $TargetDirectory, $DatabaseName)
            $ErrorActionPreference = 'Stop'
            foreach ($path in @($SourcePaths | Where-Object { $_ })) {
                $fullPath = [IO.Path]::GetFullPath([string]$path)
                if (-not [IO.Path]::GetFileName($fullPath).StartsWith($DatabaseName, [StringComparison]::OrdinalIgnoreCase)) {
                    throw 'HYPERV_DATABASE_PACKAGE_SOURCE_CLEANUP_SCOPE_INVALID'
                }
                if (Test-Path -LiteralPath $fullPath -PathType Leaf) {
                    Remove-Item -LiteralPath $fullPath -Force -ErrorAction Stop
                }
            }
            if ($TargetDirectory) {
                $target = [IO.Path]::GetFullPath([string]$TargetDirectory).TrimEnd('\')
                $parent = [IO.Directory]::GetParent($target)
                if (-not $parent -or $parent.Name -ne 'DatabasePackages' -or
                    [IO.Path]::GetFileName($target) -notmatch '^[0-9a-fA-F-]{36}$') {
                    throw 'HYPERV_DATABASE_PACKAGE_TARGET_CLEANUP_SCOPE_INVALID'
                }
                if (Test-Path -LiteralPath $target -PathType Container) {
                    Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction Stop
                }
            }
        } -ErrorAction Stop
    }
    finally {
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
}

try {
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(15))
    if (-not $mutexAcquired) { throw 'HYPERV_DATABASE_PACKAGE_ATTACH_HOST_LOCK_TIMEOUT' }
    $module = Import-Module $modulePath -Force -PassThru
    Get-Command Get-VM -ErrorAction Stop | Out-Null
    $availability = Invoke-Private { Test-HyperVAvailable }
    Assert-HyperVPackageAttachAcceptance ([bool]$availability.Available) `
        'Runner besitzt die benoetigte Hyper-V-Host-Capability' ([string]$availability.Message)

    $null = New-Item -Path $testRoot -ItemType Directory -Force
    $null = New-Item -Path $sourceCopyRoot -ItemType Directory -Force
    if (-not $StateRoot) { $StateRoot = Invoke-Private { Get-LabStateRoot } }
    $env:SQL_SERVER_LAB_STATE = $StateRoot
    $null = Invoke-Private {
        param($Root)
        Initialize-LabManagedDataRoot -DataRoot $Root -ControllerId ([Guid]::NewGuid().ToString('D')) -Confirm:$false
    } @($dataRoot)
    $env:SQL_SERVER_LAB_DATA_ROOT = $dataRoot

    if ($RunId) {
        $targetContext = Invoke-Private {
            param($Id, $Root)
            Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root
        } @($RunId, $StateRoot)
        $guestPassword = Invoke-Private {
            param($RunDirectory)
            Get-LabSecret -Path $RunDirectory -Name 'guest-administrator-password'
        } @([string]$targetContext.RunDirectory)
        if (-not $guestPassword) { throw 'HYPERV_DATABASE_PACKAGE_GUEST_CREDENTIAL_NOT_AVAILABLE' }
        $guestCredential = [PSCredential]::new('Administrator', $guestPassword)
        $managed = Invoke-Private {
            param($Context)
            Get-HyperVManagedVM -VMName ([string]$Context.Instance.vmName) `
                -ExpectedRunId ([string]$Context.Run.runId) -ExpectedScopeId ([string]$Context.Run.scopeId)
        } @($targetContext)
        Assert-HyperVPackageAttachAcceptance (
            [string]$targetContext.Instance.workload -eq 'sql' -and
            [string]$targetContext.Instance.sqlVersion -eq '2025' -and
            [string]$managed.VM.State -eq 'Running'
        ) 'Vorhandener scopegebundener SQL-2025-Run ist als sparsames Testziel geeignet'
    }
    else {
        if (-not $ArtifactId) {
            $artifact = Invoke-Private {
                param($Root)
                @(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck | Where-Object {
                    [string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and
                    [string]$_.sql.version -eq '2025' -and [string]$_.licenseType -ne 'test-only'
                } | Sort-Object { [datetime]$_.registeredAt } -Descending | Select-Object -First 1)[0]
            } @($StateRoot)
            if (-not $artifact) { throw 'HYPERV_DATABASE_PACKAGE_SQL_PREPARED_ARTIFACT_NOT_FOUND' }
            $ArtifactId = [string]$artifact.artifactId
        }
        $artifact = Invoke-Private {
            param($Id, $Root)
            Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
        } @($ArtifactId, $StateRoot)
        Assert-HyperVPackageAttachAcceptance (
            [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq '2025'
        ) 'Verifiziertes SQL-2025-Prepared-Artifact ist verfuegbar' $ArtifactId

        $labName = 'hv-package-attach-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)
        Write-AcceptanceManifest -Path $manifestPath -LabName $labName -PreparedArtifactId $ArtifactId
        $manifestValidation = Test-SqlServerLabManifest -Path $manifestPath
        Assert-HyperVPackageAttachAcceptance $manifestValidation.IsValid 'Zielmanifest ist vor Mutation gueltig' ($manifestValidation.Errors -join '; ')

        $guestPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
        $saPassword = Invoke-Private { New-HyperVSqlUnattendedPassword }
        $guestCredential = [PSCredential]::new('Administrator', $guestPassword)
        $lab = New-SqlServerLab -Manifest $manifestPath -GuestPassword $guestPassword `
            -SqlSaPassword $saPassword -NonInteractive -StateRoot $StateRoot `
            -Region AT -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' `
            -TimeZone 'W. Europe Standard Time'
        $saPassword = $null
        Assert-HyperVPackageAttachAcceptance ([string]$lab.State -eq 'RUNNING') 'Isolierter SQL-Prepared-Manifest-Run ist bereit'
        $RunId = [string]$lab.RunId
        $targetContext = Invoke-Private {
            param($Id, $Root)
            Get-HyperVLabWorkflowRun -RunId $Id -StateRoot $Root
        } @($RunId, $StateRoot)
    }

    $script:targetContext = $targetContext
    $script:guestCredential = $guestCredential
    Assert-HyperVPackageAttachAcceptance (
        -not [string]::IsNullOrWhiteSpace([string]$targetContext.Instance.vmName)
    ) 'PowerShell-Direct-SQL-Zugriff ist an den Ziel-Run gebunden'

    $paths = @(Invoke-AcceptanceQuery -Query @'
SET NOCOUNT ON;
SELECT CONCAT(CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultDataPath')),N'|',
              CONVERT(nvarchar(4000),SERVERPROPERTY('InstanceDefaultLogPath')),N'|',
              CONVERT(nvarchar(10),SERVERPROPERTY('ProductMajorVersion')));
'@)[0].Split('|')
    Assert-HyperVPackageAttachAcceptance (
        $paths.Count -eq 3 -and [int]$paths[2] -ge 17
    ) 'SQL-Zielpfade und Major-Version wurden live ermittelt'
    $dataPath = [string]$paths[0]
    $logPath = if ([string]::IsNullOrWhiteSpace([string]$paths[1])) { $dataPath } else { [string]$paths[1] }
    $escapedDatabase = $databaseName.Replace(']', ']]')
    $mdf = Join-Path $dataPath "$databaseName.mdf"
    $ndf = Join-Path $dataPath "${databaseName}_2.ndf"
    $ldf = Join-Path $logPath "$databaseName.ldf"
    $marker = [Guid]::NewGuid().ToString('D')
    $databaseMayExist = $true
    $null = Invoke-AcceptanceQuery -Query @"
CREATE DATABASE [$escapedDatabase]
ON PRIMARY (NAME=N'${databaseName}_Primary',FILENAME=N'$($mdf.Replace("'","''"))',SIZE=16MB),
FILEGROUP [${databaseName}_Data] (NAME=N'${databaseName}_Secondary',FILENAME=N'$($ndf.Replace("'","''"))',SIZE=8MB)
LOG ON (NAME=N'${databaseName}_Log',FILENAME=N'$($ldf.Replace("'","''"))',SIZE=8MB);
"@
    $null = Invoke-AcceptanceQuery -Database $databaseName -Query "CREATE TABLE dbo.Evidence(Id int NOT NULL PRIMARY KEY, Marker uniqueidentifier NOT NULL); INSERT dbo.Evidence VALUES(1,'$marker');"
    $inventoryLines = @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT CONCAT(name,N'|',CASE type WHEN 0 THEN N'DATA' WHEN 1 THEN N'LOG' END,N'|',physical_name) FROM sys.master_files WHERE database_id=DB_ID(N'$databaseName') ORDER BY file_id;")
    Assert-HyperVPackageAttachAcceptance ($inventoryLines.Count -eq 3) 'SQL inventarisiert MDF, NDF und LDF vor dem Detach'
    $sourceGuestPaths = @($inventoryLines | ForEach-Object { ([string]$_).Split('|', 3)[2] })
    $null = Invoke-AcceptanceQuery -Query "ALTER DATABASE [$escapedDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; EXEC master.dbo.sp_detach_db N'$databaseName';"
    $databaseMayExist = $false
    Assert-HyperVPackageAttachAcceptance (
        @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name=N'$databaseName';").Count -eq 0
    ) 'Quelldatenbank ist vor der Paketpublikation sauber detached'

    $session = $null
    try {
        $session = New-PSSession -VMName ([string]$targetContext.Instance.vmName) -Credential $guestCredential -ErrorAction Stop
        $fileInventory = [Collections.Generic.List[object]]::new()
        foreach ($line in $inventoryLines) {
            $parts = ([string]$line).Split('|', 3)
            if ($parts.Count -ne 3) { throw 'HYPERV_DATABASE_PACKAGE_SOURCE_INVENTORY_INVALID' }
            $hostPath = Join-Path $sourceCopyRoot ([IO.Path]::GetFileName([string]$parts[2]))
            Copy-Item -LiteralPath ([string]$parts[2]) -Destination $hostPath -FromSession $session -Force -ErrorAction Stop
            $fileInventory.Add([PSCustomObject]@{ LogicalName = [string]$parts[0]; Type = [string]$parts[1]; FullPath = $hostPath })
        }
    }
    finally {
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    Assert-HyperVPackageAttachAcceptance (
        @($fileInventory | Where-Object { Test-Path -LiteralPath $_.FullPath -PathType Leaf }).Count -eq 3
    ) 'Detached Dateimenge wurde ueber PowerShell Direct isoliert auf den Host kopiert'

    $package = Invoke-Private {
        param($Name, $Run, $Inventory, $Root)
        New-LabDatabasePackage -DatabaseName $Name -Provider hyperv -SqlMajorVersion '17' `
            -RunId $Run -InstanceId primary `
            -SourceEvidence ([PSCustomObject]@{
                DatabaseState = 'DETACHED'; DetachState = 'CLEAN_DETACHED'; AccessMode = 'EXCLUSIVE'
                WriterCount = 0; StateObservedAfterLock = $true
            }) `
            -DatabaseMetadata ([PSCustomObject]@{
                HasFileStream = $false; FileStreamInventoryComplete = $true
                IsEncrypted = $false; TdeKeyEvidenceVerified = $false
            }) `
            -FileInventory @($Inventory) -DataRoot $Root
    } @($databaseName, $runId, @($fileInventory), $dataRoot)
    Assert-HyperVPackageAttachAcceptance (
        [string]$package.Status -eq 'REUSABLE' -and -not [string]::IsNullOrWhiteSpace([string]$package.DatabasePackageId)
    ) 'Detached Dateimenge ist als vollstaendig gehashtes DATABASE_PACKAGE publiziert'

    $attachContext = Invoke-Private {
        param($PackageId, $Run, $Credential, $Root, $State)
        $selected = Get-LabDatabasePackage -DatabasePackageId $PackageId -DataRoot $Root
        Get-LabHyperVDatabasePackageAttachContext -Package $selected -RunId $Run `
            -InstanceId primary -Credential $Credential -StateRoot $State
    } @([string]$package.DatabasePackageId, $runId, $guestCredential, $dataRoot, $StateRoot)
    $targetGuestDirectory = [string]$attachContext.TargetDirectory
    $operationDirectory = [string]$attachContext.OperationDirectory

    $planned = Invoke-SqlServerLabDatabasePackageAttach -DatabasePackageId ([string]$package.DatabasePackageId) `
        -RunId $runId -InstanceId primary -GuestCredential $guestCredential `
        -DataRoot $dataRoot -StateRoot $StateRoot -WhatIf
    Assert-HyperVPackageAttachAcceptance (
        [string]$planned.Status -eq 'PLANNED' -and -not $planned.AttachInvoked -and
        @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name=N'$databaseName';").Count -eq 0
    ) 'Oeffentlicher WhatIf bindet per stabiler ID und mutiert das Ziel nicht'

    $attached = Invoke-SqlServerLabDatabasePackageAttach -DatabasePackageId ([string]$package.DatabasePackageId) `
        -RunId $runId -InstanceId primary -GuestCredential $guestCredential `
        -DataRoot $dataRoot -StateRoot $StateRoot -Confirm:$false
    $databaseMayExist = $true
    $attachedMarker = @(Invoke-AcceptanceQuery -Database $databaseName -Query 'SET NOCOUNT ON; SELECT CONVERT(nvarchar(36),Marker) FROM dbo.Evidence WHERE Id=1;')[0]
    Assert-HyperVPackageAttachAcceptance (
        [string]$attached.Status -eq 'ATTACHED' -and $attached.TargetCopyVerified -and
        $attached.AttachInvoked -and $attached.PostconditionVerified -and $attachedMarker -eq $marker
    ) 'Oeffentlicher Hyper-V-Attach ist online und bewahrt den Dateninhalt'
    $serializedResult = $attached | ConvertTo-Json -Depth 30
    Assert-HyperVPackageAttachAcceptance (
        $serializedResult -notmatch [regex]::Escape($dataPath) -and
        $serializedResult -notmatch '(?i)sha256|password|credential'
    ) 'Oeffentliches Ergebnis enthaelt keine Pfade, Hashes oder Credentials'

    $journalPath = Join-Path ([string]$attachContext.OperationDirectory) 'database-package-attach-journal.json'
    $journal = Get-Content -LiteralPath $journalPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 20
    Assert-HyperVPackageAttachAcceptance (
        [string]$journal.Status -eq 'COMPLETED' -and $journal.TargetCopyVerified -and
        $journal.AttachInvoked -and $journal.PostconditionVerified -and [string]$journal.Recovery -eq 'NOT_REQUIRED'
    ) 'Hostseitiges Journal belegt Kopie, Mutation und Online-Postcondition'

    $null = Invoke-AcceptanceQuery -Query "ALTER DATABASE [$escapedDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$escapedDatabase];"
    $databaseMayExist = $false
    Remove-GuestAcceptanceArtifacts
    $sourceGuestPaths = @()
    $targetGuestDirectory = $null
    if ($operationDirectory -and (Test-Path -LiteralPath $operationDirectory -PathType Container)) {
        $operationFull = [IO.Path]::GetFullPath($operationDirectory).TrimEnd('\')
        $runDirectoryFull = [IO.Path]::GetFullPath([string]$targetContext.RunDirectory).TrimEnd('\')
        if (-not $operationFull.StartsWith("$runDirectoryFull\operations\database-package-attach\", [StringComparison]::OrdinalIgnoreCase)) {
            throw 'HYPERV_DATABASE_PACKAGE_OPERATION_CLEANUP_SCOPE_INVALID'
        }
        Remove-Item -LiteralPath $operationFull -Recurse -Force -ErrorAction Stop
    }
    $operationDirectory = $null
    if ($lab) {
        $cleanup = Remove-SqlServerLab -RunId $runId -StateRoot $StateRoot -Force -Confirm:$false
        Assert-HyperVPackageAttachAcceptance ([string]$cleanup.Status -in @('REMOVED', 'COMPLETED')) `
            'Run wurde scopegebunden entfernt' ([string]$cleanup.Status)
        $lab = $null
    }
    else {
        Assert-HyperVPackageAttachAcceptance (
            [string](Get-VM -Name ([string]$targetContext.Instance.vmName) -ErrorAction Stop).State -eq 'Running'
        ) 'Vorhandener Ziel-Run bleibt nach Test-Cleanup unveraendert laufend'
    }
    $completed = $true
}
catch {
    if ($lab -and $KeepOnFailure) {
        Write-Host "RECOVERY_RUN_ID=$([string]$lab.RunId)"
        Write-Host "RECOVERY_MANIFEST_ROOT=$testRoot"
    }
    throw
}
finally {
    if ($targetContext -and $guestCredential) {
        $targetCleanupVerified = $false
        try {
            $present = @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name=N'$databaseName';")
            if ($present.Count -gt 0) {
                $null = Invoke-AcceptanceQuery -Query "ALTER DATABASE [$escapedDatabase] SET SINGLE_USER WITH ROLLBACK IMMEDIATE; DROP DATABASE [$escapedDatabase];"
            }
            $targetCleanupVerified = @(Invoke-AcceptanceQuery -Query "SET NOCOUNT ON; SELECT name FROM sys.databases WHERE name=N'$databaseName';").Count -eq 0
        }
        catch {
            Write-Warning "SQL-Cleanup des Hyper-V-Paket-Attach-Tests schlug fehl: $($_.Exception.Message)"
        }
        $preservedTargetDirectory = $targetGuestDirectory
        if (-not $targetCleanupVerified) { $targetGuestDirectory = $null }
        try { Remove-GuestAcceptanceArtifacts }
        catch { Write-Warning "Datei-Cleanup des Hyper-V-Paket-Attach-Tests schlug fehl: $($_.Exception.Message)" }
        $targetGuestDirectory = $preservedTargetDirectory
    }
    if ($lab -and -not $KeepOnFailure) {
        try { Remove-SqlServerLab -RunId ([string]$lab.RunId) -StateRoot $StateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning "Fehler-Cleanup des Hyper-V-Paket-Attach-Runs schlug fehl: $($_.Exception.Message)" }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        if (-not (Test-ScopedTemporaryRoot -Path $testRoot)) { throw 'HYPERV_DATABASE_PACKAGE_ATTACH_TEMP_SCOPE_INVALID' }
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction Stop
    }
    if ($previousStateRoot) { $env:SQL_SERVER_LAB_STATE = $previousStateRoot }
    else { Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue }
    if ($previousDataRoot) { $env:SQL_SERVER_LAB_DATA_ROOT = $previousDataRoot }
    else { Remove-Item Env:SQL_SERVER_LAB_DATA_ROOT -ErrorAction SilentlyContinue }
    $script:guestCredential = $null
    $guestCredential = $null
    $guestPassword = $null
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Write-Host 'Native oeffentliche Hyper-V-DATABASE_PACKAGE-Attach-Akzeptanz erfolgreich.' -ForegroundColor Green
