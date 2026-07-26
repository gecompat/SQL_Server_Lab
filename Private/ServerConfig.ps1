<#
.SYNOPSIS
    Wendet Server-Konfiguration auf eine Lab-Instanz an.
.DESCRIPTION
    Setzt sp_configure-Optionen, Memory-Grenzen, MaxDOP, TempDB-Layout,
    Trace Flags und benutzerdefinierte Einstellungen via T-SQL.
    Wird nach SQL_READY und vor Datenbank-Erstellung ausgefuehrt.
#>

function Set-LabServerConfig {
    <#
    .SYNOPSIS Wendet serverConfig aus dem Manifest auf eine Instanz an.
    .PARAMETER Config PSCustomObject mit Memory, TempDB, MaxDOP etc.
    .PARAMETER Port SQL-Server-Port.
    .PARAMETER SaPassword SecureString.
    .PARAMETER HostName Default 127.0.0.1.
    .PARAMETER ContainerName Fuer TempDB-Pfad-Erstellung im Container.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$HostName = '127.0.0.1',
        [string]$ContainerName
    )

    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    $statements = @()

    # =========================================================================
    # 1. sp_configure: show advanced options
    # =========================================================================
    $statements += "EXEC sp_configure 'show advanced options', 1;"
    $statements += "RECONFIGURE;"

    # =========================================================================
    # 2. Memory-Grenzen
    # =========================================================================
    if ($Config.memory) {
        if ($Config.memory.maxMB) {
            $statements += "EXEC sp_configure 'max server memory (MB)', $($Config.memory.maxMB);"
            Write-LabInfo "  Memory: max = $($Config.memory.maxMB) MB"
        }
        if ($Config.memory.minMB) {
            $statements += "EXEC sp_configure 'min server memory (MB)', $($Config.memory.minMB);"
            Write-LabInfo "  Memory: min = $($Config.memory.minMB) MB"
        }
    }

    # =========================================================================
    # 3. MaxDOP + Cost Threshold
    # =========================================================================
    if ($null -ne $Config.maxDop -and $Config.maxDop -ge 0) {
        $statements += "EXEC sp_configure 'max degree of parallelism', $($Config.maxDop);"
        Write-LabInfo "  MaxDOP: $($Config.maxDop)"
    }
    if ($null -ne $Config.costThreshold -and $Config.costThreshold -ne 5) {
        $statements += "EXEC sp_configure 'cost threshold for parallelism', $($Config.costThreshold);"
        Write-LabInfo "  Cost Threshold: $($Config.costThreshold)"
    }

    # =========================================================================
    # 4. Benutzerdefinierte sp_configure
    # =========================================================================
    if ($Config.spConfigure) {
        $Config.spConfigure.PSObject.Properties | ForEach-Object {
            $statements += "EXEC sp_configure '$($_.Name)', $($_.Value);"
            Write-LabInfo "  sp_configure: $($_.Name) = $($_.Value)"
        }
    }

    # RECONFIGURE nach allen sp_configure-Aenderungen
    $statements += "RECONFIGURE;"

    # =========================================================================
    # 5. TempDB-Konfiguration
    # =========================================================================
    if ($Config.tempdb -and $Config.tempdb.dataFiles) {
        $rt = Get-ContainerRuntime

        # Verzeichnisse im Container anlegen
        $paths = @()
        foreach ($f in $Config.tempdb.dataFiles) {
            if ($f.path) { $paths += Split-Path $f.path -Parent }
        }
        if ($Config.tempdb.logFile -and $Config.tempdb.logFile.path) {
            $paths += Split-Path $Config.tempdb.logFile.path -Parent
        }
        $uniquePaths = $paths | Sort-Object -Unique
        foreach ($p in $uniquePaths) {
            if ($ContainerName -and $rt) {
                & $rt exec $ContainerName mkdir -p $p 2>$null
                & $rt exec $ContainerName chown mssql:root $p 2>$null
            }
        }

        # Bestehende TempDB-Dateien ermitteln
        $existingFiles = Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain `
            -Query "SELECT file_id, name, physical_name, type FROM sys.master_files WHERE database_id = 2 ORDER BY file_id" `
            -Database 'master'
        if ($existingFiles -isnot [array]) { $existingFiles = @($existingFiles) }

        $dataFileCount = ($existingFiles | Where-Object { $_.type -eq 0 }).Count
        $targetCount = $Config.tempdb.dataFiles.Count

        # Bestehende Data-Files anpassen (MODIFY FILE)
        for ($i = 0; $i -lt [Math]::Min($dataFileCount, $targetCount); $i++) {
            $f = $Config.tempdb.dataFiles[$i]
            $existing = ($existingFiles | Where-Object { $_.type -eq 0 })[$i]
            $sizeMB = if ($f.sizeMB) { $f.sizeMB } else { 64 }
            $growth = Resolve-GrowthClause -GrowthString $f.growth
            $filePath = if ($f.path) { $f.path } else { $existing.physical_name }

            $statements += "ALTER DATABASE tempdb MODIFY FILE (NAME = '$($existing.name)', FILENAME = '$filePath', SIZE = ${sizeMB}MB$growth);"
        }

        # Zusaetzliche Data-Files hinzufuegen (ADD FILE)
        for ($i = $dataFileCount; $i -lt $targetCount; $i++) {
            $f = $Config.tempdb.dataFiles[$i]
            $sizeMB = if ($f.sizeMB) { $f.sizeMB } else { 64 }
            $growth = Resolve-GrowthClause -GrowthString $f.growth
            $fileName = "tempdev$($i + 1)"
            $filePath = if ($f.path) { $f.path } else { "/var/opt/mssql/data/${fileName}.ndf" }

            $statements += "ALTER DATABASE tempdb ADD FILE (NAME = '$fileName', FILENAME = '$filePath', SIZE = ${sizeMB}MB$growth);"
        }

        # Log-File anpassen
        if ($Config.tempdb.logFile) {
            $logF = $Config.tempdb.logFile
            $existingLog = $existingFiles | Where-Object { $_.type -eq 1 } | Select-Object -First 1
            if ($existingLog) {
                $sizeMB = if ($logF.sizeMB) { $logF.sizeMB } else { 32 }
                $growth = Resolve-GrowthClause -GrowthString $logF.growth
                $filePath = if ($logF.path) { $logF.path } else { $existingLog.physical_name }
                $statements += "ALTER DATABASE tempdb MODIFY FILE (NAME = '$($existingLog.name)', FILENAME = '$filePath', SIZE = ${sizeMB}MB$growth);"
            }
        }

        Write-LabInfo "  TempDB: $targetCount Data-Files konfiguriert"
    }

    # =========================================================================
    # 6. Trace Flags
    # =========================================================================
    if ($Config.traceFlags -and $Config.traceFlags.Count -gt 0) {
        $flagList = $Config.traceFlags -join ', '
        $statements += "DBCC TRACEON($flagList, -1);"
        Write-LabInfo "  Trace Flags: $flagList"
    }

    # =========================================================================
    # Ausfuehren
    # =========================================================================
    if ($statements.Count -gt 2) {  # Mehr als nur show advanced + reconfigure
        $sql = $statements -join "`n"
        try {
            Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain `
                -Query $sql -Database 'master' -TimeoutSeconds 30
            Write-LabSuccess "Server-Konfiguration angewendet ($($statements.Count) Statements)"
        }
        catch {
            Write-LabWarning "Server-Konfiguration teilweise fehlgeschlagen: $_"
        }
    }

    $saPlain = $null
}

function Resolve-GrowthClause {
    <#
    .SYNOPSIS Konvertiert Growth-String ('64MB' oder '10%') in SQL-Klausel.
    #>
    [CmdletBinding()]
    param([string]$GrowthString)

    if (-not $GrowthString) { return ', FILEGROWTH = 64MB' }

    if ($GrowthString -match '^(\d+)MB$') {
        return ", FILEGROWTH = $($Matches[1])MB"
    }
    elseif ($GrowthString -match '^(\d+)%$') {
        return ", FILEGROWTH = $($Matches[1])%"
    }
    else {
        return ", FILEGROWTH = 64MB"
    }
}
