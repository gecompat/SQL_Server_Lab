<#
.SYNOPSIS
    Neustartfaehige TempDB-Provisionierung fuer Containerinstanzen.
.DESCRIPTION
    Ueberschreibt Set-LabServerConfig nach dem Laden von ServerConfig.ps1.
    TempDB-Pfadwechsel werden in drei Phasen ausgefuehrt:
    1. Primaere Daten- und Logdatei im Katalog auf Zielpfade setzen.
    2. Container neu starten und SQL-Bereitschaft abwarten.
    3. Aktive Dateien dimensionieren, weitere Dateien anlegen und Pfade validieren.
#>

function Restart-LabContainerForTempDb {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )

    Write-LabInfo "TempDB-Pfadwechsel erfordert Neustart von '$ContainerName'..."
    switch ($Provider) {
        'docker' {
            Stop-DockerInstance -ContainerIdOrName $ContainerName
            Start-DockerInstance -ContainerIdOrName $ContainerName
        }
        'podman' {
            Stop-PodmanInstance -ContainerIdOrName $ContainerName
            Start-PodmanInstance -ContainerIdOrName $ContainerName
        }
    }

    $readiness = Wait-SqlReady -Port $Port -SaPassword $SaPassword -TimeoutSeconds 180
    if (-not $readiness.Ready) {
        throw "SQL Server nach TempDB-Neustart nicht bereit: $($readiness.Message)"
    }
}

function Set-LabTempDbConfigWithRestart {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider
    )

    $dataFiles = @($Config.dataFiles)
    if ($dataFiles.Count -eq 0) {
        throw 'serverConfig.tempdb.dataFiles muss mindestens eine Datendatei enthalten.'
    }

    $primary = $dataFiles[0]
    $primaryPath = [string]$primary.path
    Assert-LabContainerPath -Path $primaryPath -Label 'TempDB-Data-File-Pfad'
    $primaryGrowth = ConvertTo-LabGrowthClause -Growth ([string]$primary.growth)
    $escapedPrimaryPath = $primaryPath.Replace("'", "''")

    $catalogStatements = @(
        "ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev', FILENAME = N'$escapedPrimaryPath', FILEGROWTH = $primaryGrowth);"
    )

    $logPath = $null
    if ($Config.logFile) {
        $logPath = [string]$Config.logFile.path
        Assert-LabContainerPath -Path $logPath -Label 'TempDB-Log-File-Pfad'
        $logGrowth = ConvertTo-LabGrowthClause -Growth ([string]$Config.logFile.growth)
        $escapedLogPath = $logPath.Replace("'", "''")
        $catalogStatements += "ALTER DATABASE tempdb MODIFY FILE (NAME = N'templog', FILENAME = N'$escapedLogPath', FILEGROWTH = $logGrowth);"
    }

    # Noch keine zusaetzliche Datei anlegen und keine Datei vergroessern. Beides
    # wuerde vor dem notwendigen Neustart sofort auf dem Ziel-Mount initialisieren.
    Invoke-LabConfigurationQuery `
        -HostName $HostName `
        -Port $Port `
        -SaPassword $SaPassword `
        -Query ($catalogStatements -join "`n")

    Restart-LabContainerForTempDb `
        -ContainerName $ContainerName `
        -Provider $Provider `
        -Port $Port `
        -SaPassword $SaPassword

    $activeStatements = @()
    $primarySize = if ($primary.sizeMB) { [int]$primary.sizeMB } else { 256 }
    if ($primarySize -le 0) { throw 'TempDB-Dateigroesse muss positiv sein.' }
    $activeStatements += "ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev', SIZE = ${primarySize}MB, FILEGROWTH = $primaryGrowth);"

    for ($index = 1; $index -lt $dataFiles.Count; $index++) {
        $file = $dataFiles[$index]
        $path = [string]$file.path
        Assert-LabContainerPath -Path $path -Label 'TempDB-Data-File-Pfad'
        $size = if ($file.sizeMB) { [int]$file.sizeMB } else { 256 }
        if ($size -le 0) { throw 'TempDB-Dateigroesse muss positiv sein.' }
        $growth = ConvertTo-LabGrowthClause -Growth ([string]$file.growth)
        $escapedPath = $path.Replace("'", "''")
        $logicalName = "temp$($index + 1)"
        $activeStatements += @"
IF EXISTS (SELECT 1 FROM tempdb.sys.database_files WHERE name = N'$logicalName')
    ALTER DATABASE tempdb MODIFY FILE (NAME = N'$logicalName', FILENAME = N'$escapedPath', SIZE = ${size}MB, FILEGROWTH = $growth);
ELSE
    ALTER DATABASE tempdb ADD FILE (NAME = N'$logicalName', FILENAME = N'$escapedPath', SIZE = ${size}MB, FILEGROWTH = $growth);
"@
    }

    if ($Config.logFile) {
        $logSize = if ($Config.logFile.sizeMB) { [int]$Config.logFile.sizeMB } else { 128 }
        if ($logSize -le 0) { throw 'TempDB-Loggroesse muss positiv sein.' }
        $logGrowth = ConvertTo-LabGrowthClause -Growth ([string]$Config.logFile.growth)
        $activeStatements += "ALTER DATABASE tempdb MODIFY FILE (NAME = N'templog', SIZE = ${logSize}MB, FILEGROWTH = $logGrowth);"
    }

    Invoke-LabConfigurationQuery `
        -HostName $HostName `
        -Port $Port `
        -SaPassword $SaPassword `
        -Query ($activeStatements -join "`n")

    $expectedPaths = @($dataFiles | ForEach-Object { [string]$_.path })
    if ($logPath) { $expectedPaths += $logPath }
    $escapedExpected = @($expectedPaths | ForEach-Object { "N'$($_.Replace("'", "''"))'" })
    $validationQuery = @"
SET NOCOUNT ON;
DECLARE @Expected int = $($expectedPaths.Count);
DECLARE @Actual int = (
    SELECT COUNT(*)
    FROM tempdb.sys.database_files
    WHERE physical_name IN ($($escapedExpected -join ', '))
);
IF @Actual <> @Expected
BEGIN
    SELECT name, physical_name, state_desc FROM tempdb.sys.database_files ORDER BY file_id;
    THROW 51001, 'TEMPDB_PATH_VALIDATION_FAILED', 1;
END;
"@
    Invoke-LabConfigurationQuery -HostName $HostName -Port $Port -SaPassword $SaPassword -Query $validationQuery
}

function Set-LabServerConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$ContainerName,
        [ValidateSet('docker', 'podman')][string]$Provider
    )

    $configurationStatements = @(
        "EXEC sp_configure N'show advanced options', 1;",
        'RECONFIGURE;'
    )

    if ($Config.memory) {
        if ($null -ne $Config.memory.minMB) {
            $minimumMemory = [int]$Config.memory.minMB
            if ($minimumMemory -lt 0) { throw 'serverConfig.memory.minMB darf nicht negativ sein.' }
            $configurationStatements += "EXEC sp_configure N'min server memory (MB)', $minimumMemory;"
            $configurationStatements += 'RECONFIGURE;'
        }
        if ($Config.memory.maxMB) {
            $maximumMemory = [int]$Config.memory.maxMB
            if ($maximumMemory -lt 128) { throw 'serverConfig.memory.maxMB muss mindestens 128 MB betragen.' }
            if ($null -ne $Config.memory.minMB -and $maximumMemory -lt [int]$Config.memory.minMB) {
                throw 'serverConfig.memory.maxMB darf nicht kleiner als minMB sein.'
            }
            $configurationStatements += "EXEC sp_configure N'max server memory (MB)', $maximumMemory;"
            $configurationStatements += 'RECONFIGURE;'
        }
    }

    if ($null -ne $Config.maxDop) {
        $maxDop = [int]$Config.maxDop
        if ($maxDop -lt 0 -or $maxDop -gt 64) { throw 'serverConfig.maxDop muss zwischen 0 und 64 liegen.' }
        $configurationStatements += "EXEC sp_configure N'max degree of parallelism', $maxDop;"
        $configurationStatements += 'RECONFIGURE;'
    }

    if ($null -ne $Config.costThreshold) {
        $costThreshold = [int]$Config.costThreshold
        if ($costThreshold -lt 0 -or $costThreshold -gt 32767) { throw 'serverConfig.costThreshold muss zwischen 0 und 32767 liegen.' }
        $configurationStatements += "EXEC sp_configure N'cost threshold for parallelism', $costThreshold;"
        $configurationStatements += 'RECONFIGURE;'
    }

    if ($Config.spConfigure) {
        foreach ($property in $Config.spConfigure.PSObject.Properties) {
            $configurationName = [string]$property.Name
            if ($configurationName -notmatch '^[A-Za-z0-9 ()_-]+$') {
                throw "sp_configure-Name '$configurationName' enthaelt unzulaessige Zeichen."
            }
            $configurationValue = [int]$property.Value
            $escapedConfigurationName = $configurationName.Replace("'", "''")
            $configurationStatements += "EXEC sp_configure N'$escapedConfigurationName', $configurationValue;"
            $configurationStatements += 'RECONFIGURE;'
        }
    }

    if ($Config.traceFlags -and @($Config.traceFlags).Count -gt 0) {
        $traceFlags = @($Config.traceFlags | ForEach-Object { [int]$_ })
        if ($traceFlags | Where-Object { $_ -le 0 }) { throw 'Trace-Flag-Nummern muessen positiv sein.' }
        $configurationStatements += "DBCC TRACEON ($($traceFlags -join ', '), -1) WITH NO_INFOMSGS;"
    }

    Invoke-LabConfigurationQuery -HostName $HostName -Port $Port -SaPassword $SaPassword -Query ($configurationStatements -join "`n")

    if ($Config.tempdb) {
        if (-not $ContainerName -or -not $Provider) {
            throw 'TempDB-Pfadkonfiguration erfordert ContainerName und Provider.'
        }
        Set-LabTempDbConfigWithRestart `
            -Config $Config.tempdb `
            -HostName $HostName `
            -Port $Port `
            -SaPassword $SaPassword `
            -ContainerName $ContainerName `
            -Provider $Provider

        # Globale Trace Flags sind nicht neustartfest und werden nach dem
        # TempDB-Neustart erneut aktiviert.
        if ($Config.traceFlags -and @($Config.traceFlags).Count -gt 0) {
            $traceFlags = @($Config.traceFlags | ForEach-Object { [int]$_ })
            Invoke-LabConfigurationQuery `
                -HostName $HostName `
                -Port $Port `
                -SaPassword $SaPassword `
                -Query "DBCC TRACEON ($($traceFlags -join ', '), -1) WITH NO_INFOMSGS;"
        }
    }

    return [PSCustomObject]@{
        Success       = $true
        MemoryApplied = [bool]$Config.memory
        TempDbApplied = [bool]$Config.tempdb
        MaxDop        = $Config.maxDop
        CostThreshold = $Config.costThreshold
        TraceFlags    = @($Config.traceFlags)
    }
}
