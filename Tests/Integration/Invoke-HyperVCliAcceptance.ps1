#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt eine reale CLI-Akzeptanz auf einem frischen Windows-OS-Slot aus.
.DESCRIPTION
    Klont eine OS_SEALED-Baseline, schliesst OOBE ab, installiert SQL Server
    aus hashregistrierten Medien in Lab_Base und prueft getrennte VHDX fuer
    Daten, Log, zwei TempDB-Pfade und Backup. Der Test entfernt den Run und
    alle run-eigenen VHDX anschliessend wieder.
#>
[CmdletBinding()]
param(
    [string]$MediaRoot = 'D:\Lab_Base',
    [string]$ArtifactId,
    [ValidateSet('2019','2022','2025')][string]$SqlVersion = '2025',
    [ValidateSet('Eval','Enterprise','Standard')][string]$MediaEdition = 'Enterprise',
    [string]$SqlMediaPath,
    [ValidateRange(60,3600)][int]$OobeTimeoutSeconds = 1200,
    [ValidateRange(60,10800)][int]$SetupTimeoutSeconds = 7200,
    [string]$StateRoot,
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-server-lab-hyperv-cli-$([guid]::NewGuid().ToString('N'))"
$samplePath = Join-Path $testRoot 'Chinook_SqlServer.sql'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$module = $null
$lab = $null
$ownedVhdx = @()
$saPlain = $null
$completed = $false
$mutex = [Threading.Mutex]::new($false, 'Global\SQL_Server_Lab_HyperV_Cli_Acceptance')
$mutexAcquired = $false

function Assert-HyperVCli {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description, [string]$Evidence)
    if (-not $Condition) { throw "HYPERV_CLI_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function Invoke-Private {
    param([Parameter(Mandatory)][scriptblock]$ScriptBlock, [object[]]$Arguments=@())
    & $module $ScriptBlock @Arguments
}

function ConvertFrom-AcceptanceSecureString {
    param([Parameter(Mandatory)][SecureString]$Value)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-WindowsAcceptanceQuery {
    param([Parameter(Mandatory)][string]$Query, [string]$Database='master')
    $output = @(& sqlcmd -S "$script:sqlAddress,1433" -U sa -P $saPlain -C -b -d $Database -Q $Query -h -1 -W 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "SQLCMD_FAILED: $(($output | ForEach-Object { [string]$_ }) -join "`n")" }
    (($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_ -notmatch '^Changed database context' }) -join "`n")
}

function Wait-WindowsAcceptanceSqlReady {
    param(
        [Parameter(Mandatory)][ValidateRange(1,99)][int]$ExpectedMajorVersion,
        [ValidateRange(1,3600)][int]$TimeoutSeconds = 1200
    )

    $context = Invoke-Private {
        param($RunId,$Root)
        Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
    } @($lab.RunId,$StateRoot)
    $credential = [PSCredential]::new('Administrator', $guestPassword)
    return Invoke-Private {
        param($VmName,$RunId,$ScopeId,$Credential,$SaPassword,$Address,$ExpectedMajor,$Timeout)
        Wait-HyperVGuestSqlReady -VMName $VmName -ExpectedRunId $RunId -ExpectedScopeId $ScopeId `
            -Credential $Credential -SaPassword $SaPassword -FallbackAddress $Address `
            -ExpectedMajorVersion $ExpectedMajor -TimeoutSeconds $Timeout
    } @(
        [string]$context.Instance.vmName,
        [string]$context.Run.runId,
        [string]$context.Run.scopeId,
        $credential,
        $saPassword,
        [string]$context.Instance.oobeAutomation.labAddress,
        $ExpectedMajorVersion,
        $TimeoutSeconds
    )
}

try {
    $mutexAcquired = $mutex.WaitOne([TimeSpan]::FromMinutes(15))
    if (-not $mutexAcquired) { throw 'HYPERV_CLI_ACCEPTANCE_HOST_LOCK_TIMEOUT' }
    $principal = [Security.Principal.WindowsPrincipal]::new([Security.Principal.WindowsIdentity]::GetCurrent())
    Assert-HyperVCli $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) 'Runner arbeitet erhoeht'
    Assert-HyperVCli (Test-Path -LiteralPath $MediaRoot -PathType Container) "Media Root ist vorhanden: $MediaRoot"
    Get-Command Get-VM, New-VHD, sqlcmd -ErrorAction Stop | Out-Null

    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
    $module = Import-Module $modulePath -Force -PassThru
    if (-not $StateRoot) { $StateRoot = Invoke-Private { Get-LabStateRoot } }
    $env:SQL_SERVER_LAB_STATE = $StateRoot

    if (-not $ArtifactId) {
        $artifact = Invoke-Private {
            param($Root)
            @(Get-HyperVImageArtifact -StateRoot $Root -SkipIntegrityCheck | Where-Object {
                [string]$_.artifactState -eq 'OS_SEALED' -and [string]$_.licenseType -ne 'test-only'
            } | Sort-Object { [datetime]$_.registeredAt } -Descending | Select-Object -First 1)[0]
        } @($StateRoot)
        if (-not $artifact) { throw 'HYPERV_CLI_OS_SEALED_ARTIFACT_NOT_FOUND' }
        $ArtifactId = [string]$artifact.artifactId
    }
    $artifact = Invoke-Private { param($Id,$Root) Get-HyperVImageArtifact -ArtifactId $Id -StateRoot $Root } @($ArtifactId,$StateRoot)
    Assert-HyperVCli ($artifact.artifactState -eq 'OS_SEALED') 'Verifizierter OS_SEALED-Slot ist verfuegbar' $ArtifactId

    if (-not $SqlMediaPath) {
        $mediaCandidate = Invoke-Private {
            param($Root,$Version,$Edition)
            @(Get-HyperVSqlInstallationMediaCandidates -MediaRoot $Root | Where-Object {
                $_.State -eq 'READY' -and $_.SqlVersion -eq $Version -and $_.MediaEdition -eq $Edition
            } | Select-Object -First 1)[0]
        } @($MediaRoot,$SqlVersion,$MediaEdition)
        if (-not $mediaCandidate) {
            throw "HYPERV_CLI_SQL_MEDIA_NOT_FOUND: SQL Server $SqlVersion $MediaEdition ISO unter $MediaRoot\SQL. Manueller Bezug: https://www.microsoft.com/en-us/evalcenter/sql-server-2025-download"
        }
        $SqlMediaPath = [string]$mediaCandidate.MediaId
    }
    $media = Invoke-Private {
        param($Root,$Version,$Edition,$Path)
        $resolved = Resolve-HyperVSqlInstallationMedia -MediaRoot $Root -SqlVersion $Version -MediaEdition $Edition -SqlMediaPath $Path
        if ($resolved.HashStatus -ne 'SIDECAR_READY') {
            $resolved = New-HyperVSqlMediaHashSidecar -MediaRoot $Root -SqlVersion $Version -MediaEdition $Edition -SqlMediaPath $Path -Confirm:$false
        }
        $resolved
    } @($MediaRoot,$SqlVersion,$MediaEdition,$SqlMediaPath)
    Assert-HyperVCli ($media.HashStatus -eq 'SIDECAR_READY') 'SQL-ISO ist per SHA-256 registriert' $media.RelativePath

    $labName = "win-cli-$([guid]::NewGuid().ToString('N').Substring(0,8))"
    $drives = @(
        [PSCustomObject]@{ id='data'; role='sqlData'; sizeBytes=4GB; vhdType='dynamic'; guestPath='E:\SQLData'; allocationUnitKB=64 },
        [PSCustomObject]@{ id='log'; role='sqlLog'; sizeBytes=2GB; vhdType='dynamic'; guestPath='L:\SQLLog'; allocationUnitKB=64 },
        [PSCustomObject]@{ id='tempdb1'; role='tempdb'; sizeBytes=2GB; vhdType='dynamic'; guestPath='T:\TempDB'; allocationUnitKB=64 },
        [PSCustomObject]@{ id='tempdb2'; role='tempdb'; sizeBytes=2GB; vhdType='dynamic'; guestPath='U:\TempDB'; allocationUnitKB=64 },
        [PSCustomObject]@{ id='backup'; role='backup'; sizeBytes=2GB; vhdType='dynamic'; guestPath='R:\SQLBackup'; allocationUnitKB=64 }
    )
    $lab = Invoke-Private {
        param($Id,$Name,$Drives,$Root)
        New-HyperVLabEnvironment -ArtifactId $Id -LabName $Name -InstanceId sql -MemoryStartupMB 6144 `
            -ProcessorCount 4 -AdditionalDrives $Drives -StateRoot $Root
    } @($ArtifactId,$labName,$drives,$StateRoot)
    $ownedVhdx = @(Invoke-Private {
        param($RunId,$Root)
        $ctx=Get-HyperVLabWorkflowRun -RunId $RunId -StateRoot $Root
        $identity=(Get-HyperVManagedVM -VMName $ctx.Instance.vmName -ExpectedRunId $ctx.Run.runId -ExpectedScopeId $ctx.Run.scopeId).Identity
        @([string]$identity.childVhdxPath) + @($identity.additionalDrives | ForEach-Object { [string]$_.path })
    } @($lab.RunId,$StateRoot))
    Assert-HyperVCli ($lab.State -eq 'STOPPED') 'Frischer Windows-Slot wurde ausgeschaltet angelegt'

    $passwordToken = [guid]::NewGuid().ToString('N').Substring(0,16)
    $guestPassword = ConvertTo-SecureString "WinCli_${passwordToken}!Aa7" -AsPlainText -Force
    $saPassword = ConvertTo-SecureString "SqlCli_${passwordToken}!Bb8" -AsPlainText -Force
    Invoke-Private {
        param($RunId,$GuestPassword,$SaPassword,$Timeout,$Root,$MediaRoot)
        Invoke-HyperVLabUnattendedProvision -RunId $RunId -AdministratorPassword $GuestPassword -SqlSaPassword $SaPassword `
            -PasswordSource user -TimeoutSeconds $Timeout -Region AT -SystemLocale de-AT -UiLanguage en-US `
            -InputLocale '0407:00000407' -TimeZone 'W. Europe Standard Time' -MediaRoot $MediaRoot -StateRoot $Root
    } @($lab.RunId,$guestPassword,$saPassword,$OobeTimeoutSeconds,$StateRoot,$MediaRoot) | Out-Null
    Stop-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null

    $serverConfig = [PSCustomObject]@{
        memory=[PSCustomObject]@{ minMB=0; maxMB=4096 }
        maxDop=2
        costThreshold=40
        tempdb=[PSCustomObject]@{
            dataFiles=@(
                [PSCustomObject]@{ path='T:\TempDB\tempdev.mdf'; sizeMB=64; growth='32MB' },
                [PSCustomObject]@{ path='U:\TempDB\temp2.ndf'; sizeMB=64; growth='32MB' }
            )
            logFile=[PSCustomObject]@{ path='T:\TempDB\templog.ldf'; sizeMB=64; growth='32MB' }
            equalSize=$true
        }
        spConfigure=[PSCustomObject]@{ 'optimize for ad hoc workloads'=1 }
    }
    $storage = [PSCustomObject]@{ dataPath='E:\SQLData'; logPath='L:\SQLLog'; tempDbPaths=@('T:\TempDB','U:\TempDB'); backupPath='R:\SQLBackup' }
    Invoke-Private {
        param($RunId,$Version,$Edition,$MediaPath,$Config,$Storage,$Root)
        Set-HyperVLabSqlDeploymentPlan -RunId $RunId -SqlVersion $Version -DeploymentMode adhoc-install `
            -MediaEdition $Edition -SqlMediaPath $MediaPath -ProcessorCount 4 -MemoryStartupMB 6144 `
            -ServerConfig $Config -StorageConfiguration $Storage -StateRoot $Root
    } @($lab.RunId,$SqlVersion,$MediaEdition,$SqlMediaPath,$serverConfig,$storage,$StateRoot) | Out-Null
    $install = Invoke-Private {
        param($RunId,$MediaRoot,$SaPassword,$Timeout,$Root)
        Invoke-HyperVLabSqlSlotInstall -RunId $RunId -MediaRoot $MediaRoot -SqlSaPassword $SaPassword `
            -SetupTimeoutSeconds $Timeout -ReadinessTimeoutSeconds 1200 -StateRoot $Root
    } @($lab.RunId,$MediaRoot,$saPassword,$SetupTimeoutSeconds,$StateRoot)
    Assert-HyperVCli ($install.State -eq 'SQL_SLOT_READY') 'SQL Server wurde in den frischen Windows-Slot installiert'
    $script:sqlAddress = [string]$install.HostSqlAccess.Network.Address
    $saPlain = ConvertFrom-AcceptanceSecureString $saPassword

    $expectedMajor = @{ '2019'='15'; '2022'='16'; '2025'='17' }[$SqlVersion]
    Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 1200 -Force -Confirm:$false | Out-Null
    $restartReadiness = Wait-WindowsAcceptanceSqlReady -ExpectedMajorVersion $expectedMajor
    Assert-HyperVCli $restartReadiness.Ready 'SQL ist nach Restart-SqlServerLab wieder bereit'
    $versionEvidence = Invoke-WindowsAcceptanceQuery "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS varchar(8));"
    Assert-HyperVCli ($versionEvidence -eq $expectedMajor) "SQL Server $SqlVersion meldet den erwarteten Major Build" $versionEvidence

    $configEvidence = Invoke-WindowsAcceptanceQuery "SET NOCOUNT ON; SELECT name + '=' + CAST(value_in_use AS varchar(20)) FROM sys.configurations WHERE name IN ('max server memory (MB)','max degree of parallelism','cost threshold for parallelism','optimize for ad hoc workloads') ORDER BY name;"
    foreach ($expected in @('max server memory (MB)=4096','max degree of parallelism=2','cost threshold for parallelism=40','optimize for ad hoc workloads=1')) {
        Assert-HyperVCli ($configEvidence -match [regex]::Escape($expected)) "SQL-Konfiguration '$expected' ist aktiv" $configEvidence
    }
    $tempEvidence = Invoke-WindowsAcceptanceQuery "SET NOCOUNT ON; SELECT physical_name FROM tempdb.sys.database_files ORDER BY file_id;"
    Assert-HyperVCli ($tempEvidence -match 'T:\\TempDB\\tempdev\.mdf' -and $tempEvidence -match 'U:\\TempDB\\temp2\.ndf' -and $tempEvidence -match 'T:\\TempDB\\templog\.ldf') 'TempDB verwendet zwei getrennte VHDX' $tempEvidence

    New-SqlServerLabDatabase -HostName $script:sqlAddress -Port 1433 -SaPassword $saPassword -DatabaseName CliStorageEvidence `
        -DataFiles @(
            [PSCustomObject]@{ name='CliStorage_Data1'; path='E:\SQLData\CliStorage_Data1.mdf'; sizeMB=32; filegrowthMB=16 },
            [PSCustomObject]@{ name='CliStorage_Data2'; path='E:\SQLData\CliStorage_Data2.ndf'; sizeMB=32; filegrowthMB=16 }
        ) -LogFiles @([PSCustomObject]@{ name='CliStorage_Log'; path='L:\SQLLog\CliStorage_Log.ldf'; sizeMB=16; filegrowthMB=16 }) `
        -Options ([PSCustomObject]@{ queryStore=$true; compatibility=[int]($expectedMajor+'0') }) | Out-Null
    $dbEvidence = Invoke-WindowsAcceptanceQuery "SET NOCOUNT ON; SELECT physical_name FROM CliStorageEvidence.sys.database_files ORDER BY file_id;"
    Assert-HyperVCli ($dbEvidence -match 'E:\\SQLData\\CliStorage_Data1\.mdf' -and $dbEvidence -match 'L:\\SQLLog\\CliStorage_Log\.ldf') 'CLI erstellt Datenbank mit getrennten Daten- und Log-VHDX' $dbEvidence

    $sampleUrl = 'https://raw.githubusercontent.com/lerocha/chinook-database/7f67772503d71ba90f19283c38e93923addb43fa/ChinookDatabase/DataSources/Chinook_SqlServer.sql'
    Invoke-WebRequest -Uri $sampleUrl -OutFile $samplePath -UseBasicParsing
    $sampleHash = (Get-FileHash -LiteralPath $samplePath -Algorithm SHA256).Hash.ToLowerInvariant()
    Assert-HyperVCli ($sampleHash -eq '5ea75c9e925ead917d3fabea6ed3cc8c1ff1d036b61e915c94631aafa2b0802b') 'Chinook-Download entspricht dem Katalog-Hash'
    $sampleResult = Invoke-SqlServerLabScript -ScriptPath $samplePath -HostName $script:sqlAddress -Port 1433 -SaPassword $saPassword
    Assert-HyperVCli $sampleResult.Success 'Chinook-Skript wurde ueber die CLI ohne fehlgeschlagenen Batch ausgefuehrt' $sampleResult.Message
    Assert-HyperVCli ([long](Invoke-WindowsAcceptanceQuery 'SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM dbo.Artist;' -Database Chinook) -gt 0) 'Reale Chinook-Testdatenbank wurde installiert'

    $rename = Invoke-SqlServerLabWorkflowAction -Action RenameLab -BuildId $lab.RunId -LabName "$labName-renamed"
    Assert-HyperVCli $rename.Result.Changed 'Lab und Hyper-V-VM wurden ueber die Workflow-CLI umbenannt'
    Stop-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null
    $resources = Invoke-SqlServerLabWorkflowAction -Action SetLabResources -BuildId $lab.RunId -MemoryMB 5120 -ProcessorCount 3
    Assert-HyperVCli ($resources.Result.Changed -and $resources.Result.Instances[0].MemoryStartupMB -eq 5120 -and $resources.Result.Instances[0].ProcessorCount -eq 3) 'Hyper-V-vCPU und RAM wurden ueber die CLI geaendert'
    Start-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -TimeoutSeconds 1200 | Out-Null
    $resourceReadiness = Wait-WindowsAcceptanceSqlReady -ExpectedMajorVersion $expectedMajor
    Assert-HyperVCli $resourceReadiness.Ready 'SQL ist nach Ressourcenwechsel und Start wieder bereit'
    Assert-HyperVCli ((Invoke-WindowsAcceptanceQuery "SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM CliStorageEvidence.sys.tables;") -gt 0) 'Datenzustand bleibt nach Ressourcenwechsel und Neustart erreichbar'

    Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null
    $lab = $null
    foreach ($path in $ownedVhdx | Where-Object { $_ }) {
        Assert-HyperVCli (-not (Test-Path -LiteralPath $path)) "Run-eigene VHDX wurde freigegeben: $path"
    }
    $completed = $true
}
finally {
    $saPlain = $null
    if ($lab -and -not $KeepOnFailure) {
        try { Remove-SqlServerLab -RunId $lab.RunId -StateRoot $StateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning "Fehler-Cleanup des Hyper-V-Runs schlug fehl: $($_.Exception.Message)" }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
    if ($mutexAcquired) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}

Write-Host "Hyper-V-CLI-Akzeptanz erfolgreich: SQL Server $SqlVersion" -ForegroundColor Green
