#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den realen Hyper-V-Storage-Nachweis fuer Gate N5 aus.
.DESCRIPTION
    Verwendet ein verifiziertes SQL_PREPARED_SEALED-Artifact und einen
    SqlServerLab.StorageIntent/1.0. Der Intent muss vier TempDB-Datendateien
    auf vier nachweislich getrennte Backing Devices, ein separates TempDB-Log,
    eine dateigenaue Create-Datenbank, eine Restore-Regel und eine Backup-Lane
    binden. Der Runner prueft SQL-Dienstrestart, TempDB-Postconditions, CREATE,
    einen synthetischen Backup/Restore-Roundtrip, Persistenz nach VM-Restart und
    den scopegebundenen Cleanup aller run-eigenen VHDX.
.PARAMETER StorageIntentPath
    Vollstaendiger Pfad zu einem SqlServerLab.StorageIntent/1.0 JSON. Die im
    Intent verwendeten Selektoren muessen in der lokalen Storage-Registry
    eindeutig und mit belegter physischer Topologie registriert sein.
.PARAMETER MediaRoot
    Externer Media Root fuer den SQL-CompleteImage-Pfad.
.PARAMETER ArtifactId
    Optionales SQL_PREPARED_SEALED-Artifact. Ohne Angabe wird das neueste
    passende SQL-2025-Artifact verwendet.
.PARAMETER CreateDatabaseName
    Datenbank, deren Dateien im Intent unter databaseFiles gebunden sind.
.PARAMETER RestoreDatabaseName
    Datenbank, deren Data-/Log-Ziele im Intent unter restoreRules gebunden sind.
.PARAMETER StateRoot
    Optionaler lokaler Lab-State-Root.
.PARAMETER KeepOnFailure
    Behaelt den fehlgeschlagenen Run fuer eine gezielte lokale Diagnose.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$StorageIntentPath,
    [string]$MediaRoot = 'D:\Lab_Base',
    [string]$ArtifactId,
    [ValidateSet('2025')][string]$SqlVersion = '2025',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$CreateDatabaseName = 'N5Create',
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]{0,127}$')][string]$RestoreDatabaseName = 'N5Restore',
    [ValidateRange(60, 3600)][int]$OobeTimeoutSeconds = 1200,
    [string]$StateRoot,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) "sql-server-lab-hyperv-storage-$([Guid]::NewGuid().ToString('N'))"
$fixturePath = Join-Path $testRoot "$RestoreDatabaseName.bak"
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$module = $null
$lab = $null
$ownedVhdx = @()
$saPlain = $null
$completed = $false
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_HyperV_Storage_Acceptance')
$mutexAcquired = $false

function Assert-HyperVStorageAcceptance {
    param(
        [Parameter(Mandatory)][bool]$Condition,
        [Parameter(Mandatory)][string]$Description,
        [string]$Evidence
    )
    if (-not $Condition) {
        throw "HYPERV_STORAGE_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })"
    }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Invoke-Private {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$Arguments = @())
    & $module $ScriptBlock @Arguments
}

function ConvertFrom-AcceptanceSecureString {
    param([Parameter(Mandatory)][SecureString]$Value)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-AcceptanceQuery {
    param([Parameter(Mandatory)][string]$Query, [string]$Database = 'master')
    $output = @(& sqlcmd -S "$script:sqlAddress,1433" -U sa -P $saPlain -C -b -d $Database -Q $Query -h -1 -W 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "SQLCMD_FAILED: $(($output | ForEach-Object { [string]$_ }) -join "`n")"
    }
    (($output | ForEach-Object { ([string]$_).Trim() } | Where-Object {
        $_ -and $_ -notmatch '^Changed database context'
    }) -join "`n")
}

function Wait-AcceptanceSqlReady {
    param([Parameter(Mandatory)][ValidateRange(1, 99)][int]$ExpectedMajorVersion)

    $context = Invoke-Private {
        param($RunId, $Root)
        Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
    } @($lab.RunId, $StateRoot)
    $credential = [PSCredential]::new('Administrator', $guestPassword)
    Invoke-Private {
        param($VmName, $RunId, $ScopeId, $Credential, $SaPassword, $Address, $ExpectedMajor)
        Wait-HyperVGuestSqlReady -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId `
            -Credential $Credential -SaPassword $SaPassword -FallbackAddress $Address `
            -ExpectedMajorVersion $ExpectedMajor -TimeoutSeconds 1200
    } @(
        [string]$context.Instance.vmName,
        [string]$context.Run.runId,
        [string]$context.Run.scopeId,
        $credential,
        $saPassword,
        [string]$context.Instance.oobeAutomation.labAddress,
        $ExpectedMajorVersion
    )
}

function Get-StorageContext {
    Invoke-Private {
        param($RunId, $Root)
        Get-LabVerifiedStorageRuntimeContext -RunId $RunId -InstanceId primary -StateRoot $Root
    } @($lab.RunId, $StateRoot)
}

try {
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(15))
    if (-not $mutexAcquired) { throw 'HYPERV_STORAGE_ACCEPTANCE_HOST_LOCK_TIMEOUT' }

    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVStorageAcceptance $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner arbeitet erhoeht'
    Assert-HyperVStorageAcceptance (Test-Path -LiteralPath $MediaRoot -PathType Container) 'Media Root ist vorhanden'
    Assert-HyperVStorageAcceptance (Test-Path -LiteralPath $StorageIntentPath -PathType Leaf) 'Storage-Intent ist vorhanden'
    Get-Command Get-VM, Get-VHD, sqlcmd -ErrorAction Stop | Out-Null

    $resolvedIntentPath = (Resolve-Path -LiteralPath $StorageIntentPath).Path
    $storageIntent = Get-Content -LiteralPath $resolvedIntentPath -Raw -Encoding utf8 | ConvertFrom-Json -Depth 40
    $module = Import-Module $modulePath -Force -PassThru
    if (-not $StateRoot) { $StateRoot = Invoke-Private { Get-LabStateRoot } }
    $env:SQL_SERVER_LAB_STATE = $StateRoot

    $null = Invoke-Private { param($Intent) Assert-LabStorageIntent -StorageIntent $Intent } @($storageIntent)
    $preflight = Invoke-Private {
        param($Intent)
        New-LabStorageBoundPlan -StorageIntent $Intent -RunId ([Guid]::NewGuid().ToString('D')) `
            -LabName 'n5-storage-preflight' -InstanceId primary -Provider hyperv
    } @($storageIntent)

    Assert-HyperVStorageAcceptance ([string]$preflight.Status -eq 'READY') 'Storage-Bound-Plan ist vor der Mutation READY' (@($preflight.Blockers) -join ', ')
    Assert-HyperVStorageAcceptance ([string]$preflight.TopologyEvidence.Status -eq 'PASS') 'Physische TempDB-Topologie ist belegt'
    $tempDataBindings = @($preflight.SqlFiles | Where-Object Role -eq 'tempdb-data')
    $tempLogBindings = @($preflight.SqlFiles | Where-Object Role -eq 'tempdb-log')
    $tempLocations = @($tempDataBindings.LocationId | Sort-Object -Unique)
    $tempBackingDevices = @(
        foreach ($file in $tempDataBindings) {
            @($preflight.Bindings | Where-Object LocationId -eq [string]$file.LocationId | Select-Object -First 1).BackingDeviceIds
        }
    ) | Sort-Object -Unique
    Assert-HyperVStorageAcceptance (
        $tempDataBindings.Count -eq 4 -and $tempLocations.Count -eq 4 -and $tempBackingDevices.Count -eq 4
    ) 'Vier TempDB-Datendateien binden vier getrennte Volumes und Backing Devices'
    Assert-HyperVStorageAcceptance (
        $tempLogBindings.Count -eq 1 -and [string]$tempLogBindings[0].LocationId -notin $tempLocations
    ) 'TempDB-Log besitzt eine eigene Storage-Lane'

    $createDataBindings = @($preflight.SqlFiles | Where-Object { $_.Database -eq $CreateDatabaseName -and $_.Role -eq 'database-data' })
    $createLogBindings = @($preflight.SqlFiles | Where-Object { $_.Database -eq $CreateDatabaseName -and $_.Role -eq 'database-log' })
    Assert-HyperVStorageAcceptance (
        $createDataBindings.Count -gt 0 -and $createLogBindings.Count -gt 0 -and
        @($createDataBindings.LocationId + $createLogBindings.LocationId | Sort-Object -Unique).Count -ge 2
    ) 'Create-Datenbank ist dateigenau auf getrennte Data-/Log-Lanes geplant'
    $restoreDataRule = @($preflight.SqlFiles | Where-Object { $_.Database -eq $RestoreDatabaseName -and $_.Role -eq 'restore-data-rule' })
    $restoreLogRule = @($preflight.SqlFiles | Where-Object { $_.Database -eq $RestoreDatabaseName -and $_.Role -eq 'restore-log-rule' })
    Assert-HyperVStorageAcceptance (
        $restoreDataRule.Count -eq 1 -and $restoreLogRule.Count -eq 1 -and
        [string]$restoreDataRule[0].LocationId -ne [string]$restoreLogRule[0].LocationId
    ) 'Restore-Regel trennt Data- und Log-Ziele'
    Assert-HyperVStorageAcceptance (@($preflight.SqlFiles | Where-Object Role -eq 'backup').Count -eq 1) 'Genau eine Backup-Lane ist geplant'

    if (-not $ArtifactId) {
        $artifact = Invoke-Private {
            param($Root, $Version)
            @(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck | Where-Object {
                [string]$_.artifactState -eq 'SQL_PREPARED_SEALED' -and
                [string]$_.sql.version -eq $Version -and
                [string]$_.licenseType -ne 'test-only'
            } | Sort-Object { [datetime]$_.registeredAt } -Descending | Select-Object -First 1)[0]
        } @($StateRoot, $SqlVersion)
        if (-not $artifact) { throw "HYPERV_STORAGE_SQL_PREPARED_ARTIFACT_NOT_FOUND: SQL Server $SqlVersion" }
        $ArtifactId = [string]$artifact.artifactId
    }
    $artifact = Invoke-Private {
        param($Id, $Root)
        Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root
    } @($ArtifactId, $StateRoot)
    Assert-HyperVStorageAcceptance (
        [string]$artifact.artifactState -eq 'SQL_PREPARED_SEALED' -and [string]$artifact.sql.version -eq $SqlVersion
    ) 'Passendes verifiziertes SQL_PREPARED_SEALED-Artifact ist verfuegbar'

    $null = New-Item -Path $testRoot -ItemType Directory -Force
    $labName = "n5-storage-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
    $lab = Invoke-Private {
        param($Id, $Name, $Intent, $Root)
        New-HyperVLabEnvironment -ArtifactId $Id -LabName $Name -InstanceId primary `
            -MemoryStartupMB 6144 -ProcessorCount 4 -StorageIntent $Intent -StateRoot $Root
    } @($ArtifactId, $labName, $storageIntent, $StateRoot)
    $ownedVhdx = @(Invoke-Private {
        param($RunId, $Root)
        $context = Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
        $identity = (Get-HyperVManagedVM -VMName $context.Instance.vmName `
            -ExpectedRunId $context.Run.runId -ExpectedScopeId $context.Run.scopeId).Identity
        @([string]$identity.childVhdxPath) + @($identity.additionalDrives | ForEach-Object { [string]$_.path })
    } @($lab.RunId, $StateRoot))
    Assert-HyperVStorageAcceptance ([string]$lab.State -eq 'STOPPED') 'SQL-Prepared-Klon wurde ausgeschaltet und scopegebunden angelegt'

    $passwordToken = [Guid]::NewGuid().ToString('N').Substring(0, 16)
    $guestPassword = ConvertTo-SecureString "N5Win_${passwordToken}!Aa7" -AsPlainText -Force
    $saPassword = ConvertTo-SecureString "N5Sql_${passwordToken}!Bb8" -AsPlainText -Force
    $guestCredential = [PSCredential]::new('Administrator', $guestPassword)
    $provision = Invoke-Private {
        param($RunId, $GuestPassword, $SaPassword, $Timeout, $MediaRoot, $Root)
        Invoke-HyperVLabUnattendedProvision -RunId $RunId -AdministratorPassword $GuestPassword `
            -SqlSaPassword $SaPassword -PasswordSource user -TimeoutSeconds $Timeout -Region AT `
            -SystemLocale de-AT -UiLanguage en-US -InputLocale '0407:00000407' `
            -TimeZone 'W. Europe Standard Time' -MediaRoot $MediaRoot -StateRoot $Root
    } @($lab.RunId, $guestPassword, $saPassword, $OobeTimeoutSeconds, $MediaRoot, $StateRoot)
    $script:sqlAddress = [string]$provision.HostSqlAccess.Network.Address
    Assert-HyperVStorageAcceptance (-not [string]::IsNullOrWhiteSpace($script:sqlAddress)) 'SQL-Hostzugriff wurde ohne persistiertes Secret aufgeloest'
    $saPlain = ConvertFrom-AcceptanceSecureString $saPassword

    $storageContext = Get-StorageContext
    $receipt = $storageContext.Receipt
    Assert-HyperVStorageAcceptance (
        [string]$receipt.Status -eq 'VERIFIED' -and @($receipt.Postconditions | Where-Object Status -ne 'PASS').Count -eq 0
    ) 'Storage-Receipt bestaetigt SQL-Dienstrestart, Defaultpfade und TempDB-Postconditions'
    $runtimeTemp = @($receipt.FileBindings | Where-Object Role -eq 'tempdb-data')
    Assert-HyperVStorageAcceptance (
        $runtimeTemp.Count -eq 4 -and @($runtimeTemp.RuntimeStorageId | Sort-Object -Unique).Count -eq 4 -and
        @($runtimeTemp.GuestDiskId | Sort-Object -Unique).Count -eq 4
    ) 'Runtime-Receipt verbindet vier TempDB-Dateien mit vier VHDX und Gastdisks'
    $tempDbEvidence = Invoke-AcceptanceQuery "SET NOCOUNT ON; SELECT name + N'|' + physical_name FROM tempdb.sys.database_files ORDER BY file_id;"
    foreach ($binding in @($receipt.FileBindings | Where-Object Role -in @('tempdb-data', 'tempdb-log'))) {
        Assert-HyperVStorageAcceptance (
            $tempDbEvidence -match [regex]::Escape("$($binding.LogicalName)|$($binding.SqlPhysicalPath)")
        ) "TempDB-Datei $($binding.LogicalName) liegt am gebundenen SQL-Pfad"
    }

    $createDataFiles = @($createDataBindings | ForEach-Object {
        [PSCustomObject]@{ name = [string]$_.LogicalName; path = $null; sizeMB = 64; filegrowthMB = 32 }
    })
    $createLogFiles = @($createLogBindings | ForEach-Object {
        [PSCustomObject]@{ name = [string]$_.LogicalName; path = $null; sizeMB = 32; filegrowthMB = 32 }
    })
    $createResult = New-SqlServerLabDatabase -HostName $script:sqlAddress -Port 1433 -SaPassword $saPassword `
        -DatabaseName $CreateDatabaseName -DataFiles $createDataFiles -LogFiles $createLogFiles `
        -RunId $lab.RunId -InstanceId primary -StateRoot $StateRoot
    Assert-HyperVStorageAcceptance (
        $createResult.Success -and [string]$createResult.StoragePlanId -eq [string]$storageContext.Plan.PlanId
    ) 'CREATE DATABASE verwendet den verifizierten Storage-Vertrag'
    $null = Invoke-AcceptanceQuery "SET NOCOUNT ON; CREATE TABLE dbo.N5Evidence(Id int NOT NULL PRIMARY KEY, Marker nvarchar(64) NOT NULL); INSERT dbo.N5Evidence VALUES(1,N'persisted-through-storage-roundtrip');" -Database $CreateDatabaseName

    $storageContext = Get-StorageContext
    $backupBinding = @($storageContext.Receipt.FileBindings | Where-Object Role -eq 'backup')
    Assert-HyperVStorageAcceptance ($backupBinding.Count -eq 1) 'Runtime-Receipt enthaelt genau eine Backup-Lane'
    $guestBackupPath = Invoke-Private {
        param($Root, $Name)
        Get-LabStorageGuestChildPath -Root $Root -Child "$Name.bak"
    } @([string]$backupBinding[0].SqlPhysicalPath, $RestoreDatabaseName)
    $escapedGuestBackupPath = $guestBackupPath.Replace("'", "''")
    $null = Invoke-AcceptanceQuery "BACKUP DATABASE [$CreateDatabaseName] TO DISK=N'$escapedGuestBackupPath' WITH INIT, CHECKSUM;"

    $vmContext = Invoke-Private {
        param($RunId, $Root)
        Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
    } @($lab.RunId, $StateRoot)
    $session = $null
    try {
        $session = New-PSSession -VMName ([string]$vmContext.Instance.vmName) -Credential $guestCredential -ErrorAction Stop
        Copy-Item -LiteralPath $guestBackupPath -Destination $fixturePath -FromSession $session -Force -ErrorAction Stop
    }
    finally {
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
    }
    Assert-HyperVStorageAcceptance (Test-Path -LiteralPath $fixturePath -PathType Leaf) 'Synthetisches Backup wurde fuer den Restore-Handler bereitgestellt'
    $fixtureHash = (Get-FileHash -LiteralPath $fixturePath -Algorithm SHA256).Hash.ToLowerInvariant()

    $restoreResult = Restore-SqlServerLabDatabase -RunId $lab.RunId -InstanceId primary `
        -SaPassword $saPassword -BackupSource $fixturePath -ExpectedSha256 $fixtureHash `
        -DatabaseName $RestoreDatabaseName -GuestCredential $guestCredential -StateRoot $StateRoot -NonInteractive
    Assert-HyperVStorageAcceptance (
        $restoreResult.Success -and [string]$restoreResult.StoragePlanId
    ) 'RESTORE DATABASE verwendet FILELISTONLY, Bound Plan und verifiziertes Runtime-Receipt'
    $restoredMarker = Invoke-AcceptanceQuery 'SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM dbo.N5Evidence WHERE Id=1 AND Marker=N''persisted-through-storage-roundtrip'';' -Database $RestoreDatabaseName
    Assert-HyperVStorageAcceptance ([long]$restoredMarker -eq 1) 'Restore-Datenbank enthaelt den synthetischen Datenmarker'

    $storageContext = Get-StorageContext
    $restoreBindings = @($storageContext.Receipt.FileBindings | Where-Object OperationId -eq "restore:$RestoreDatabaseName")
    Assert-HyperVStorageAcceptance (
        $restoreBindings.Count -ge 2 -and
        @($restoreBindings | Where-Object Role -eq 'restore-data').Count -ge 1 -and
        @($restoreBindings | Where-Object Role -eq 'restore-log').Count -ge 1 -and
        @($restoreBindings.SqlPhysicalPath | Sort-Object -Unique).Count -eq $restoreBindings.Count
    ) 'Restore-Receipt bindet jede FILELIST-Datei an ein eindeutiges typgerechtes Ziel'

    Restart-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -TimeoutSeconds 1200 -Force -Confirm:$false | Out-Null
    $restartReadiness = Wait-AcceptanceSqlReady -ExpectedMajorVersion 17
    Assert-HyperVStorageAcceptance $restartReadiness.Ready 'SQL ist nach vollstaendigem VM-Restart wieder bereit'
    $persistedMarker = Invoke-AcceptanceQuery 'SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM dbo.N5Evidence WHERE Id=1;' -Database $RestoreDatabaseName
    Assert-HyperVStorageAcceptance ([long]$persistedMarker -eq 1) 'Restore-Daten bleiben nach VM-Restart erhalten'

    Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null
    $lab = $null
    foreach ($path in @($ownedVhdx | Where-Object { $_ })) {
        Assert-HyperVStorageAcceptance (-not (Test-Path -LiteralPath $path)) 'Run-eigene VHDX wurde entfernt'
    }
    $completed = $true
}
finally {
    $saPlain = $null
    if ($lab -and -not $KeepOnFailure) {
        try { Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning "Fehler-Cleanup des Hyper-V-Storage-Runs schlug fehl: $($_.Exception.Message)" }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    if ($previousStateRoot) { $env:SQL_SERVER_LAB_STATE = $previousStateRoot }
    else { Remove-Item Env:SQL_SERVER_LAB_STATE -ErrorAction SilentlyContinue }
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
