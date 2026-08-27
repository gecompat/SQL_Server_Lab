#Requires -Version 7.2
<#
.SYNOPSIS
    Fuehrt den vertieften CLI-Akzeptanztest fuer Docker oder Podman aus.
.DESCRIPTION
    Provisioniert genau einen repraesentativen SQL-Server-CU, installiert eine
    katalogverifizierte Testdatenbank und prueft getrennte Daten-, Log- und
    TempDB-Volumes, SQL-Ressourcenkonfiguration, Container-Ressourcen,
    Port-Reconcile, Persistenz sowie den vollstaendigen Cleanup.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
    [string]$Version = '2022-CU18',
    [string]$Sample = 'chinook:sql-server',
    [switch]$KeepOnFailure
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path
$modulePath = Join-Path $repoRoot 'SqlServerLab.psd1'
$testRoot = Join-Path ([System.IO.Path]::GetTempPath()) "sql-server-lab-cli-$Provider-$([guid]::NewGuid().ToString('N'))"
$stateRoot = Join-Path $testRoot 'state'
$testDataRoot = Join-Path $testRoot 'test-data'
$scriptPath = Join-Path $testRoot 'cli-acceptance.sql'
$previousStateRoot = $env:SQL_SERVER_LAB_STATE
$previousTestDataRoot = $env:SQL_SERVER_LAB_TEST_DATA_ROOT
$lab = $null
$saPlain = $null
$sqlHost = '127.0.0.1'
$completed = $false

function Assert-Acceptance {
    param([Parameter(Mandatory)][bool]$Condition, [Parameter(Mandatory)][string]$Description, [string]$Evidence)
    if (-not $Condition) { throw "CLI_ACCEPTANCE_FAILED: $Description$(if ($Evidence) { ": $Evidence" })" }
    Write-Host "PASS: $Description" -ForegroundColor Green
}

function ConvertFrom-AcceptanceSecureString {
    param([Parameter(Mandatory)][SecureString]$Value)
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($Value)
    try { [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}

function Invoke-AcceptanceQuery {
    param([Parameter(Mandatory)][string]$Query, [string]$Database = 'master', [int]$Port = $lab.Instances[0].Port)
    $output = @(& sqlcmd -S "$sqlHost,$Port" -U sa -P $saPlain -C -b -d $Database -Q $Query -h -1 -W 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "SQLCMD_FAILED: $(($output | ForEach-Object { [string]$_ }) -join "`n")" }
    return (($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ -and $_ -notmatch '^Changed database context' }) -join "`n")
}

function Get-FreeTcpPort {
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    try { $listener.Start(); return ([Net.IPEndPoint]$listener.LocalEndpoint).Port }
    finally { $listener.Stop() }
}

try {
    Write-Host "CLI-Akzeptanz: $Provider / SQL Server $Version" -ForegroundColor Cyan
    if ($Provider -eq 'podman') { & (Join-Path $PSScriptRoot 'Initialize-PodmanRuntime.ps1') | Out-Host }
    foreach ($command in @($Provider, 'sqlcmd')) {
        Assert-Acceptance ([bool](Get-Command $command -ErrorAction SilentlyContinue)) "Befehl '$command' ist verfuegbar"
    }
    & $Provider info 1>$null 2>$null
    Assert-Acceptance ($LASTEXITCODE -eq 0) "Runtime '$Provider' ist erreichbar"

    New-Item -Path $testRoot -ItemType Directory -Force | Out-Null
    $env:SQL_SERVER_LAB_STATE = $stateRoot
    $env:SQL_SERVER_LAB_TEST_DATA_ROOT = $testDataRoot
    Remove-Module SqlServerLab -Force -ErrorAction SilentlyContinue
    $module = Import-Module $modulePath -Force -PassThru

    $token = [guid]::NewGuid().ToString('N').Substring(0, 16)
    $saPassword = ConvertTo-SecureString "CliAccept_${token}!Aa7" -AsPlainText -Force
    $saPlain = ConvertFrom-AcceptanceSecureString $saPassword
    $labName = "cli-$Provider-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $drives = @(
        [PSCustomObject]@{ id='data'; containerPath='/sqldata'; type='ssd' },
        [PSCustomObject]@{ id='log'; containerPath='/sqllog'; type='ssd' },
        [PSCustomObject]@{ id='tempdb1'; containerPath='/sqltemp1'; type='ssd' },
        [PSCustomObject]@{ id='tempdb2'; containerPath='/sqltemp2'; type='ssd' },
        [PSCustomObject]@{ id='backup'; containerPath='/sqlbackup'; type='ssd' }
    )
    $serverConfig = [PSCustomObject]@{
        memory = [PSCustomObject]@{ minMB=0; maxMB=1536 }
        maxDop = 2
        costThreshold = 40
        tempdb = [PSCustomObject]@{
            dataFiles = @(
                [PSCustomObject]@{ path='/sqltemp1/tempdev.mdf'; sizeMB=64; growth='32MB' },
                [PSCustomObject]@{ path='/sqltemp2/temp2.ndf'; sizeMB=64; growth='32MB' }
            )
            logFile = [PSCustomObject]@{ path='/sqltemp1/templog.ldf'; sizeMB=64; growth='32MB' }
            equalSize = $true
        }
        spConfigure = [PSCustomObject]@{ 'optimize for ad hoc workloads'=1 }
    }

    $lab = New-SqlServerLab -Version $Version -Provider $Provider -Profile compact -Cpu 2 -MemoryMB 3072 `
        -LabName $labName -Sample $Sample -Drives $drives -ServerConfig $serverConfig `
        -SaPassword $saPassword -StateRoot $stateRoot -SkipAssessment
    Assert-Acceptance ($lab.State -eq 'Running') 'Lab wurde vollstaendig provisioniert'
    $instance = $lab.Instances[0]
    $sqlHost = if ($instance.Host) { [string]$instance.Host } else { '127.0.0.1' }
    $containerName = [string]$instance.ContainerName
    $ownedVolumeNames = @((& $Provider inspect $containerName | ConvertFrom-Json -Depth 50).Mounts | Where-Object Type -eq volume | ForEach-Object Name)

    Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force | Out-Null
    $versionEvidence = Invoke-AcceptanceQuery "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS varchar(8)) + '|' + @@VERSION;"
    Assert-Acceptance ($versionEvidence -match '^16\|' -and $versionEvidence -match 'CU18') 'Repraesentativer SQL Server 2022 CU18 laeuft' $versionEvidence

    $configEvidence = Invoke-AcceptanceQuery @"
SET NOCOUNT ON;
SELECT name + '=' + CAST(value_in_use AS varchar(20))
FROM sys.configurations
WHERE name IN ('max server memory (MB)','max degree of parallelism','cost threshold for parallelism','optimize for ad hoc workloads')
ORDER BY name;
"@
    foreach ($expected in @('max server memory (MB)=1536','max degree of parallelism=2','cost threshold for parallelism=40','optimize for ad hoc workloads=1')) {
        Assert-Acceptance ($configEvidence -match [regex]::Escape($expected)) "SQL-Ressourcenkonfiguration '$expected' ist aktiv" $configEvidence
    }

    $tempdbEvidence = Invoke-AcceptanceQuery "SET NOCOUNT ON; SELECT physical_name FROM tempdb.sys.database_files ORDER BY file_id;"
    Assert-Acceptance ($tempdbEvidence -match '/sqltemp1/tempdev\.mdf' -and $tempdbEvidence -match '/sqltemp2/temp2\.ndf' -and $tempdbEvidence -match '/sqltemp1/templog\.ldf') 'TempDB liegt auf zwei getrennten TempDB-Volumes' $tempdbEvidence

    $sampleEvidence = Invoke-AcceptanceQuery 'SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM dbo.Artist;' -Database Chinook
    Assert-Acceptance ([long]$sampleEvidence -gt 0) 'Katalogverifizierte Chinook-Testdatenbank wurde heruntergeladen und installiert' $sampleEvidence

    New-SqlServerLabDatabase -Port $instance.Port -SaPassword $saPassword -DatabaseName CliStorageEvidence `
        -DataFiles @(
            [PSCustomObject]@{ name='CliStorage_Data1'; path='/sqldata/CliStorage_Data1.mdf'; sizeMB=32; filegrowthMB=16 },
            [PSCustomObject]@{ name='CliStorage_Data2'; path='/sqldata/CliStorage_Data2.ndf'; sizeMB=32; filegrowthMB=16 }
        ) -LogFiles @([PSCustomObject]@{ name='CliStorage_Log'; path='/sqllog/CliStorage_Log.ldf'; sizeMB=16; filegrowthMB=16 }) `
        -Options ([PSCustomObject]@{ queryStore=$true; compatibility=160 }) | Out-Null
    $storageEvidence = Invoke-AcceptanceQuery "SET NOCOUNT ON; SELECT physical_name FROM CliStorageEvidence.sys.database_files ORDER BY file_id;"
    Assert-Acceptance ($storageEvidence -match '/sqldata/CliStorage_Data1\.mdf' -and $storageEvidence -match '/sqldata/CliStorage_Data2\.ndf' -and $storageEvidence -match '/sqllog/CliStorage_Log\.ldf') 'Daten- und Logdateien liegen auf getrennten Volumes' $storageEvidence

    Set-Content -LiteralPath $scriptPath -Encoding utf8 -Value @'
CREATE TABLE dbo.CliAcceptance(Id int NOT NULL PRIMARY KEY, Evidence nvarchar(100) NOT NULL);
GO
INSERT dbo.CliAcceptance(Id, Evidence) VALUES (1, N'persisted-before-reconcile');
GO
'@
    $scriptResult = Invoke-SqlServerLabScript -ScriptPath $scriptPath -Port $instance.Port -SaPassword $saPassword -Database CliStorageEvidence
    Assert-Acceptance ($scriptResult.Success -and $scriptResult.Batches -eq 2) 'Mehrbatch-SQL-Skript wurde ueber die CLI ausgefuehrt'

    $status = Get-SqlServerLab -RunId $lab.RunId -Detailed
    Assert-Acceptance ($status.State -eq 'RUNNING' -and $status.Instances[0].ContainerUp) 'Detaillierter CLI-Status stimmt mit der Runtime ueberein'
    $null = Get-SqlServerLabCatalog
    $null = Get-SqlServerLabWorkflow
    $null = Get-SqlServerLabConnectionCenter -StateRoot $stateRoot
    Assert-Acceptance $true 'Katalog, Workflowmodell und Connection Center sind lesbar'

    $rename = Invoke-SqlServerLabWorkflowAction -Action RenameLab -BuildId $lab.RunId -LabName "$labName-renamed"
    Assert-Acceptance ($rename.Result.Changed -and $rename.Result.RuntimeRenamed) 'Lab und Container wurden ueber die Workflow-CLI umbenannt'
    $containerName = [string]$rename.Result.RuntimeObjects[0].NewName

    $resourceAction = Invoke-SqlServerLabWorkflowAction -Action SetLabResources -BuildId $lab.RunId -MemoryMB 2560 -ProcessorCount 1
    Assert-Acceptance $resourceAction.Result.Changed 'CPU und Container-RAM wurden in-place geaendert'
    $inspect = @(& $Provider inspect $containerName | ConvertFrom-Json -Depth 50)[0]
    Assert-Acceptance ([long]$inspect.HostConfig.Memory -eq 2560MB) 'Runtime meldet 2560 MB Container-RAM'

    $newPort = Get-FreeTcpPort
    $reconcile = & $module {
        param($RunId,$Port,$Root)
        Update-SqlServerLabContainer -RunId $RunId -Cpu 1 -MemoryMB 2560 -Port $Port `
            -ReadinessTimeoutSeconds 180 -StateRoot $Root -Confirm:$false
    } $lab.RunId $newPort $stateRoot
    Assert-Acceptance ($reconcile.Recreated -and $reconcile.Port -eq $newPort) 'Hostport wurde durch kontrolliertes Container-Reconcile geaendert'
    $databaseReadiness = & $module {
        param($HostName,$Port,$Password)
        Wait-LabDatabaseReady -HostName $HostName -Port $Port -SaPassword $Password -Database CliStorageEvidence -TimeoutSeconds 180
    } $sqlHost $newPort $saPassword
    Assert-Acceptance $databaseReadiness.Ready 'Eigene Testdatenbank ist nach dem Reconcile bereit'
    $persistentEvidence = Invoke-AcceptanceQuery 'SET NOCOUNT ON; SELECT Evidence FROM dbo.CliAcceptance WHERE Id=1;' -Database CliStorageEvidence -Port $newPort
    Assert-Acceptance ($persistentEvidence -eq 'persisted-before-reconcile') 'Daten, Mounts und Testdatenbank ueberstehen das Reconcile'

    Stop-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force | Out-Null
    Start-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -TimeoutSeconds 180 | Out-Null
    Restart-SqlServerLab -RunId $lab.RunId -TimeoutSeconds 180 -Force | Out-Null
    Assert-Acceptance ((Invoke-AcceptanceQuery 'SET NOCOUNT ON; SELECT COUNT_BIG(*) FROM dbo.CliAcceptance;' -Database CliStorageEvidence -Port $newPort) -eq '1') 'Stop, Start und Restart erhalten den Datenzustand'

    Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false | Out-Null
    $lab = $null
    $containerCheck = @(& $Provider ps -a -q --filter "name=$containerName" 2>$null)
    Assert-Acceptance ([string]::IsNullOrWhiteSpace(($containerCheck -join ''))) 'Container wurde vollstaendig entfernt'
    foreach ($volumeName in $ownedVolumeNames) {
        $volumeCheck = @(& $Provider volume ls -q --filter "name=^${volumeName}$" 2>$null)
        Assert-Acceptance ([string]::IsNullOrWhiteSpace(($volumeCheck -join ''))) "Run-eigenes Volume '$volumeName' wurde entfernt"
    }
    $completed = $true
}
finally {
    $saPlain = $null
    if ($lab -and -not $KeepOnFailure) {
        try { Remove-SqlServerLab -RunId $lab.RunId -StateRoot $stateRoot -Force -Confirm:$false | Out-Null }
        catch { Write-Warning "Fehler-Cleanup des Runs schlug fehl: $($_.Exception.Message)" }
    }
    if (($completed -or -not $KeepOnFailure) -and (Test-Path -LiteralPath $testRoot)) {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    $env:SQL_SERVER_LAB_STATE = $previousStateRoot
    $env:SQL_SERVER_LAB_TEST_DATA_ROOT = $previousTestDataRoot
}

Write-Host "CLI-Akzeptanz erfolgreich: $Provider / $Version" -ForegroundColor Green
