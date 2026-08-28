<#
.SYNOPSIS
    Server-, TempDB-, Datenbank- und External-Languages-Konfiguration.
.DESCRIPTION
    Fuehrt nur validierte Konfigurationswerte aus. Angeforderte Konfigurationen
    schlagen bei Fehlern hart fehl, damit kein teilweise konfiguriertes Lab als
    erfolgreich bereitgestellt gemeldet wird.
#>

function ConvertFrom-LabSecureString {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][SecureString]$SecureString
    )

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureString)
    try {
        return [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Assert-LabSqlIdentifier {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Value,
        [string]$Label = 'Identifier'
    )

    if ($Value -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "$Label '$Value' ist ungueltig."
    }
}

function Assert-LabContainerPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [string]$Label = 'Containerpfad'
    )

    $isLinuxPath = $Path.StartsWith('/')
    # C: ist der reguläre Systemdatenträger eines Windows-Gasts. Die Prüfung
    # bewertet ausschließlich einen SQL-internen Gastpfad und darf ihn daher
    # nicht wie einen schreibenden Hostpfad behandeln.
    $isWindowsPath = $Path -match '^[C-Zc-z]:\\'
    if ((-not $isLinuxPath -and -not $isWindowsPath) -or $Path -match "['\r\n]") {
        throw "$Label '$Path' ist kein sicherer absoluter Linux- oder Windows-Gastpfad."
    }
}

function Resolve-LabContainerProvider {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerName,
        [ValidateSet('docker', 'podman')][string]$PreferredProvider
    )

    $providers = if ($PreferredProvider) { @($PreferredProvider) } else { @('docker', 'podman') }
    $matches = @()

    foreach ($provider in $providers) {
        if (-not (Get-Command $provider -ErrorAction SilentlyContinue)) {
            continue
        }

        & $provider inspect $ContainerName 1>$null 2>$null
        if ($LASTEXITCODE -eq 0) {
            $matches += $provider
        }
    }

    $matches = @($matches | Sort-Object -Unique)
    if ($matches.Count -eq 0) {
        throw "Container '$ContainerName' wurde bei keinem erreichbaren Provider gefunden."
    }
    if ($matches.Count -gt 1) {
        throw "Container '$ContainerName' ist bei mehreren Providern vorhanden. PreferredProvider ist erforderlich."
    }

    return $matches[0]
}

function Invoke-LabConfigurationQuery {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$TimeoutSeconds = 60
    )

    $saPlain = ConvertFrom-LabSecureString -SecureString $SaPassword
    try {
        $null = Invoke-SqlQuery `
            -HostName $HostName `
            -Port $Port `
            -SaPlain $saPlain `
            -Query $Query `
            -Database $Database `
            -TimeoutSeconds $TimeoutSeconds
    }
    finally {
        $saPlain = $null
    }
}

function Set-LabExternalRuntimeResourceGovernor {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        $ResourceGovernor
    )

    # SQL Server installiert den default External Resource Pool mit 20 Prozent.
    # Dieser Wert reicht fuer die kataloggebundene Python-/Pandas-Probe nicht
    # zuverlaessig aus. Der Default folgt deshalb der dokumentierten Microsoft-
    # Konfiguration fuer Machine-Learning-Workloads; ein Manifest darf ihn nur
    # innerhalb der engeren Schema-Grenzen ueberschreiben.
    $maxMemoryPercent = 40
    # Ein sauber gestarteter kombinierter Python-/R-Lauf erreicht einschliesslich
    # Worker- und Satellite-Kindprozessen mehr als 20 vom Resource Governor
    # gezaehlte Prozesse. 32 erlaubt den katalogisierten Python-/R-/Java-Mix,
    # bleibt aber im Gegensatz zum SQL-Default 0 weiterhin explizit begrenzt.
    $maxProcesses = 32
    if ($ResourceGovernor) {
        if ($ResourceGovernor.PSObject.Properties['maxMemoryPercent']) {
            $maxMemoryPercent = [int]$ResourceGovernor.maxMemoryPercent
        }
        if ($ResourceGovernor.PSObject.Properties['maxProcesses']) {
            $maxProcesses = [int]$ResourceGovernor.maxProcesses
        }
    }
    if ($maxMemoryPercent -lt 5 -or $maxMemoryPercent -gt 70) {
        throw 'EXTERNAL_RUNTIME_RESOURCE_GOVERNOR_MEMORY_INVALID'
    }
    if ($maxProcesses -lt 1) {
        throw 'EXTERNAL_RUNTIME_RESOURCE_GOVERNOR_PROCESSES_INVALID'
    }

    $query = @"
ALTER EXTERNAL RESOURCE POOL [default]
WITH (MAX_MEMORY_PERCENT = $maxMemoryPercent, MAX_PROCESSES = $maxProcesses);
ALTER RESOURCE GOVERNOR RECONFIGURE;
IF NOT EXISTS (
    SELECT 1
    FROM sys.resource_governor_external_resource_pools
    WHERE [name] = N'default'
      AND max_memory_percent = $maxMemoryPercent
      AND max_processes = $maxProcesses
)
    THROW 51000, 'EXTERNAL_RUNTIME_RESOURCE_GOVERNOR_POSTCONDITION_FAILED', 1;
"@
    Invoke-LabConfigurationQuery -HostName $HostName -Port $Port -SaPassword $SaPassword -Query $query
    return [PSCustomObject]@{
        Id = 'external-runtime-resource-governor'
        Status = 'PASS'
        Pool = 'default'
        MaxMemoryPercent = $maxMemoryPercent
        MaxProcesses = $maxProcesses
    }
}

function ConvertTo-LabGrowthClause {
    [CmdletBinding()]
    param(
        [string]$Growth
    )

    if (-not $Growth) {
        return '64MB'
    }
    if ($Growth -match '^(\d+)(MB|%)$') {
        $value = [int]$Matches[1]
        if ($value -le 0) {
            throw "FILEGROWTH '$Growth' muss groesser als null sein."
        }
        return "$value$($Matches[2])"
    }

    throw "FILEGROWTH '$Growth' ist ungueltig. Erlaubt sind beispielsweise 64MB oder 10%."
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
        if ($Config.memory.minMB) {
            $minimumMemory = [int]$Config.memory.minMB
            if ($minimumMemory -lt 0) {
                throw 'serverConfig.memory.minMB darf nicht negativ sein.'
            }
            $configurationStatements += "EXEC sp_configure N'min server memory (MB)', $minimumMemory;"
            $configurationStatements += 'RECONFIGURE;'
        }
        if ($Config.memory.maxMB) {
            $maximumMemory = [int]$Config.memory.maxMB
            if ($maximumMemory -lt 128) {
                throw 'serverConfig.memory.maxMB muss mindestens 128 MB betragen.'
            }
            if ($Config.memory.minMB -and $maximumMemory -lt [int]$Config.memory.minMB) {
                throw 'serverConfig.memory.maxMB darf nicht kleiner als minMB sein.'
            }
            $configurationStatements += "EXEC sp_configure N'max server memory (MB)', $maximumMemory;"
            $configurationStatements += 'RECONFIGURE;'
        }
    }

    if ($null -ne $Config.maxDop) {
        $maxDop = [int]$Config.maxDop
        if ($maxDop -lt 0 -or $maxDop -gt 64) {
            throw 'serverConfig.maxDop muss zwischen 0 und 64 liegen.'
        }
        $configurationStatements += "EXEC sp_configure N'max degree of parallelism', $maxDop;"
        $configurationStatements += 'RECONFIGURE;'
    }

    if ($null -ne $Config.costThreshold) {
        $costThreshold = [int]$Config.costThreshold
        if ($costThreshold -lt 0 -or $costThreshold -gt 32767) {
            throw 'serverConfig.costThreshold muss zwischen 0 und 32767 liegen.'
        }
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
        if ($traceFlags | Where-Object { $_ -le 0 }) {
            throw 'Trace-Flag-Nummern muessen positiv sein.'
        }
        $configurationStatements += "DBCC TRACEON ($($traceFlags -join ', '), -1) WITH NO_INFOMSGS;"
    }

    Invoke-LabConfigurationQuery `
        -HostName $HostName `
        -Port $Port `
        -SaPassword $SaPassword `
        -Query ($configurationStatements -join "`n")

    if ($Config.tempdb) {
        Set-LabTempDbConfig `
            -Config $Config.tempdb `
            -HostName $HostName `
            -Port $Port `
            -SaPassword $SaPassword
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

function Set-LabTempDbConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )

    $statements = @()
    $dataFiles = @($Config.dataFiles)

    for ($index = 0; $index -lt $dataFiles.Count; $index++) {
        $file = $dataFiles[$index]
        $path = [string]$file.path
        Assert-LabContainerPath -Path $path -Label 'TempDB-Data-File-Pfad'

        $size = if ($file.sizeMB) { [int]$file.sizeMB } else { 256 }
        if ($size -le 0) {
            throw 'TempDB-Dateigroesse muss positiv sein.'
        }
        $growth = ConvertTo-LabGrowthClause -Growth ([string]$file.growth)
        $escapedPath = $path.Replace("'", "''")
        $logicalName = if ($index -eq 0) { 'tempdev' } else { "temp$($index + 1)" }

        if ($index -eq 0) {
            $statements += "ALTER DATABASE tempdb MODIFY FILE (NAME = N'tempdev', FILENAME = N'$escapedPath', SIZE = ${size}MB, FILEGROWTH = $growth);"
        }
        else {
            $statements += @"
IF EXISTS (SELECT 1 FROM tempdb.sys.database_files WHERE name = N'$logicalName')
    ALTER DATABASE tempdb MODIFY FILE (NAME = N'$logicalName', FILENAME = N'$escapedPath', SIZE = ${size}MB, FILEGROWTH = $growth);
ELSE
    ALTER DATABASE tempdb ADD FILE (NAME = N'$logicalName', FILENAME = N'$escapedPath', SIZE = ${size}MB, FILEGROWTH = $growth);
"@
        }
    }

    if ($dataFiles.Count -gt 0) {
        $desiredLogicalNames = @(for ($index = 0; $index -lt $dataFiles.Count; $index++) {
            if ($index -eq 0) { 'tempdev' } else { "temp$($index + 1)" }
        })
        $desiredSqlNames = @($desiredLogicalNames | ForEach-Object { "N'$($_.Replace("'", "''"))'" }) -join ', '
        $statements += @"
USE [tempdb];
DECLARE @SqlLabFileName sysname, @SqlLabRemove nvarchar(max);
DECLARE SqlLabExtraTempDbFiles CURSOR LOCAL FAST_FORWARD FOR
    SELECT [name]
    FROM tempdb.sys.database_files
    WHERE [type] = 0 AND [name] NOT IN ($desiredSqlNames);
OPEN SqlLabExtraTempDbFiles;
FETCH NEXT FROM SqlLabExtraTempDbFiles INTO @SqlLabFileName;
WHILE @@FETCH_STATUS = 0
BEGIN
    SET @SqlLabRemove = N'DBCC SHRINKFILE (' + QUOTENAME(@SqlLabFileName, '''') + N', EMPTYFILE) WITH NO_INFOMSGS; ' +
        N'ALTER DATABASE [tempdb] REMOVE FILE ' + QUOTENAME(@SqlLabFileName) + N';';
    EXEC sys.sp_executesql @SqlLabRemove;
    FETCH NEXT FROM SqlLabExtraTempDbFiles INTO @SqlLabFileName;
END;
CLOSE SqlLabExtraTempDbFiles;
DEALLOCATE SqlLabExtraTempDbFiles;
USE [master];
"@
    }

    if ($Config.logFile) {
        $logPath = [string]$Config.logFile.path
        Assert-LabContainerPath -Path $logPath -Label 'TempDB-Log-File-Pfad'
        $logSize = if ($Config.logFile.sizeMB) { [int]$Config.logFile.sizeMB } else { 128 }
        if ($logSize -le 0) {
            throw 'TempDB-Loggroesse muss positiv sein.'
        }
        $logGrowth = ConvertTo-LabGrowthClause -Growth ([string]$Config.logFile.growth)
        $escapedLogPath = $logPath.Replace("'", "''")
        $statements += "ALTER DATABASE tempdb MODIFY FILE (NAME = N'templog', FILENAME = N'$escapedLogPath', SIZE = ${logSize}MB, FILEGROWTH = $logGrowth);"
    }

    if ($statements.Count -eq 0) {
        return
    }

    Invoke-LabConfigurationQuery `
        -HostName $HostName `
        -Port $Port `
        -SaPassword $SaPassword `
        -Query ($statements -join "`n")
}

function Set-LabDatabaseOptions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$DatabaseName,
        [Parameter(Mandatory)]$Options,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword
    )

    Assert-LabSqlIdentifier -Value $DatabaseName -Label 'DatabaseName'
    $statements = @()

    if ($Options.recoveryModel) {
        $recoveryModel = [string]$Options.recoveryModel
        if ($recoveryModel -notin @('FULL', 'SIMPLE', 'BULK_LOGGED')) {
            throw "Recovery Model '$recoveryModel' ist ungueltig."
        }
        $statements += "ALTER DATABASE [$DatabaseName] SET RECOVERY $recoveryModel;"
    }

    if ($Options.compatibility) {
        $compatibilityLevel = [int]$Options.compatibility
        if ($compatibilityLevel -notin @(150, 160, 170)) {
            throw "Compatibility Level '$compatibilityLevel' ist ungueltig."
        }
        $statements += "ALTER DATABASE [$DatabaseName] SET COMPATIBILITY_LEVEL = $compatibilityLevel;"
    }

    foreach ($booleanOption in @(
        @{ Property = 'autoClose'; Sql = 'AUTO_CLOSE' },
        @{ Property = 'autoShrink'; Sql = 'AUTO_SHRINK' },
        @{ Property = 'rcsi'; Sql = 'READ_COMMITTED_SNAPSHOT' },
        @{ Property = 'snapshotIsolation'; Sql = 'ALLOW_SNAPSHOT_ISOLATION' }
    )) {
        $property = $Options.PSObject.Properties[$booleanOption.Property]
        if ($null -ne $property) {
            $valueText = if ([bool]$property.Value) { 'ON' } else { 'OFF' }
            $statements += "ALTER DATABASE [$DatabaseName] SET $($booleanOption.Sql) $valueText;"
        }
    }

    if ($Options.pageVerify) {
        $pageVerify = [string]$Options.pageVerify
        if ($pageVerify -notin @('CHECKSUM', 'TORN_PAGE_DETECTION', 'NONE')) {
            throw "PAGE_VERIFY '$pageVerify' ist ungueltig."
        }
        $statements += "ALTER DATABASE [$DatabaseName] SET PAGE_VERIFY $pageVerify;"
    }

    if ($Options.delayedDurability) {
        $delayedDurability = [string]$Options.delayedDurability
        if ($delayedDurability -notin @('DISABLED', 'ALLOWED', 'FORCED')) {
            throw "DELAYED_DURABILITY '$delayedDurability' ist ungueltig."
        }
        $statements += "ALTER DATABASE [$DatabaseName] SET DELAYED_DURABILITY = $delayedDurability;"
    }

    if ($null -ne $Options.targetRecoveryTime) {
        $targetRecoveryTime = [int]$Options.targetRecoveryTime
        if ($targetRecoveryTime -lt 0) {
            throw 'targetRecoveryTime darf nicht negativ sein.'
        }
        $statements += "ALTER DATABASE [$DatabaseName] SET TARGET_RECOVERY_TIME = $targetRecoveryTime SECONDS;"
    }

    if ($null -ne $Options.maxDop) {
        $databaseMaxDop = [int]$Options.maxDop
        if ($databaseMaxDop -lt 0 -or $databaseMaxDop -gt 64) {
            throw 'Database-scoped MAXDOP muss zwischen 0 und 64 liegen.'
        }
        $statements += "ALTER DATABASE SCOPED CONFIGURATION SET MAXDOP = $databaseMaxDop;"
    }

    $queryStoreProperty = $Options.PSObject.Properties['queryStore']
    if ($null -ne $queryStoreProperty) {
        $queryStore = $queryStoreProperty.Value
        if ($queryStore -is [bool]) {
            $queryStoreState = if ($queryStore) { 'ON' } else { 'OFF' }
            $statements += "ALTER DATABASE [$DatabaseName] SET QUERY_STORE = $queryStoreState;"
        }
        else {
            $enabled = if ($null -ne $queryStore.enabled) { [bool]$queryStore.enabled } else { $true }
            if (-not $enabled) {
                $statements += "ALTER DATABASE [$DatabaseName] SET QUERY_STORE = OFF;"
            }
            else {
                $captureMode = if ($queryStore.captureMode) { [string]$queryStore.captureMode } else { 'AUTO' }
                if ($captureMode -notin @('ALL', 'AUTO', 'NONE', 'CUSTOM')) {
                    throw "Query Store Capture Mode '$captureMode' ist ungueltig."
                }

                $queryStoreOptions = @("QUERY_CAPTURE_MODE = $captureMode")
                if ($queryStore.maxSizeMB) {
                    $queryStoreOptions += "MAX_STORAGE_SIZE_MB = $([int]$queryStore.maxSizeMB)"
                }
                if ($queryStore.intervalMinutes) {
                    $queryStoreOptions += "INTERVAL_LENGTH_MINUTES = $([int]$queryStore.intervalMinutes)"
                }
                if ($queryStore.staleQueryThresholdDays) {
                    $queryStoreOptions += "CLEANUP_POLICY = (STALE_QUERY_THRESHOLD_DAYS = $([int]$queryStore.staleQueryThresholdDays))"
                }
                if ($null -ne $queryStore.waitStatsCapture) {
                    $waitStatsMode = if ([bool]$queryStore.waitStatsCapture) { 'ON' } else { 'OFF' }
                    $queryStoreOptions += "WAIT_STATS_CAPTURE_MODE = $waitStatsMode"
                }

                $statements += "ALTER DATABASE [$DatabaseName] SET QUERY_STORE = ON ($($queryStoreOptions -join ', '));"
            }
        }
    }

    if ($statements.Count -eq 0) {
        return [PSCustomObject]@{ Success = $true; DatabaseName = $DatabaseName; Applied = 0 }
    }

    Invoke-LabConfigurationQuery `
        -HostName $HostName `
        -Port $Port `
        -SaPassword $SaPassword `
        -Query ($statements -join "`n")

    return [PSCustomObject]@{
        Success      = $true
        DatabaseName = $DatabaseName
        Applied      = $statements.Count
    }
}

function Install-LabExternalLanguages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ContainerName,
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$SqlVersion,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$HostName = '127.0.0.1',
        [ValidateSet('docker', 'podman')][string]$Provider
    )

    if ($Config.enabled -eq $false) {
        return [PSCustomObject]@{ Success = $true; Applied = $false; Reason = 'Disabled' }
    }
    if ($Config.installMethod -in @('custom-image', 'pre-built') -or $Config.customImage) {
        throw 'Custom-Image- und Pre-Built-External-Languages sind noch nicht in die Provider-Imageauswahl integriert.'
    }

    $requests = @(ConvertTo-LabExternalRuntimeRequests -Software @() -ExternalScripts $Config)
    foreach ($request in $requests) {
        $plan = Resolve-LabExternalRuntimePlan `
            -SoftwareItem $request `
            -SqlVersion $SqlVersion `
            -Provider $Provider `
            -OperatingSystem 'linux'
        if ([string]$plan.Status -ne 'RESOLVED') {
            throw "EXTERNAL_RUNTIME_PLAN_REJECTED: $($plan.SoftwareId) / $($plan.ReasonCode) - $($plan.Reason)"
        }
    }

    throw 'EXTERNAL_RUNTIME_LEGACY_POST_START_DISABLED: External Runtimes werden ausschließlich vor dem Providerstart aus kataloggebundenen Derived Images bereitgestellt.'
}
