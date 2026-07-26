<#
.SYNOPSIS
    SQL-Readiness-Pruefung fuer SQL_Server_Lab.
.DESCRIPTION
    Wartet bis SQL Server antwortet, prueft Major-Version und
    baut Connection-Strings.
#>

function Wait-SqlReady {
    <#
    .SYNOPSIS Wartet bis SQL Server auf dem angegebenen Port antwortet.
    .PARAMETER Host Hostname (Default: 127.0.0.1).
    .PARAMETER Port SQL-Server-Port.
    .PARAMETER SaPassword SecureString mit SA-Passwort.
    .PARAMETER TimeoutSeconds Maximale Wartezeit (Default: 120).
    .PARAMETER ExpectedMajorVersion Erwartete Major-Version (optional).
    .OUTPUTS PSCustomObject mit Ready (bool), Version, Message.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [int]$TimeoutSeconds = 120,
        [int]$ExpectedMajorVersion = 0
    )

    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $interval = 3
    $attempt = 0

    Write-LabInfo "Warte auf SQL-Bereitschaft ($HostName`:$Port, Timeout: ${TimeoutSeconds}s)..."

    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $attempt++
        Start-Sleep -Seconds $interval

        try {
            # Versuche Verbindung via sqlcmd oder .NET
            $result = Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain `
                -Query "SELECT SERVERPROPERTY('ProductMajorVersion') AS MajorVersion, @@VERSION AS FullVersion"

            if ($result) {
                # .NET SqlClient: Properties MajorVersion + FullVersion
                # sqlcmd Fallback: nur RawOutput (Text)
                if ($result.MajorVersion) {
                    $majorVersion = [int]$result.MajorVersion
                    $fullVersion = $result.FullVersion
                }
                elseif ($result.RawOutput) {
                    # sqlcmd: "17   Microsoft SQL Server 2025..."
                    if ($result.RawOutput -match '(\d+)') {
                        $majorVersion = [int]$Matches[1]
                    } else { $majorVersion = 0 }
                    $fullVersion = $result.RawOutput
                }
                else {
                    $majorVersion = 0
                    $fullVersion = 'Unbekannt'
                }

                # Version pruefen
                if ($ExpectedMajorVersion -gt 0 -and $majorVersion -ne $ExpectedMajorVersion) {
                    $saPlain = $null
                    return [PSCustomObject]@{
                        Ready   = $false
                        Version = $fullVersion
                        Message = "Version-Mismatch: erwartet Major $ExpectedMajorVersion, erhalten $majorVersion"
                        ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
                    }
                }

                $saPlain = $null
                Write-LabSuccess "SQL Server bereit nach $([math]::Round($stopwatch.Elapsed.TotalSeconds, 1))s (Major: $majorVersion)"
                return [PSCustomObject]@{
                    Ready          = $true
                    Version        = $fullVersion
                    MajorVersion   = $majorVersion
                    Message        = ''
                    ElapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
                }
            }
        }
        catch {
            # Noch nicht bereit - weiter warten
            Write-Verbose "Versuch $attempt fehlgeschlagen: $_"
        }
    }

    $saPlain = $null
    return [PSCustomObject]@{
        Ready          = $false
        Version        = $null
        Message        = "Timeout nach ${TimeoutSeconds}s - SQL Server antwortet nicht."
        ElapsedSeconds = $TimeoutSeconds
    }
}

function Invoke-SqlQuery {
    <#
    .SYNOPSIS Fuehrt eine SQL-Abfrage via .NET SqlClient aus.
    .DESCRIPTION Fallback-Kette:
        1. Microsoft.Data.SqlClient (modern, PowerShell 7)
        2. System.Data.SqlClient (Legacy/.NET Framework)
        3. sqlcmd (CLI-Fallback)
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$SaPlain,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$TimeoutSeconds = 10
    )

    $connStr = "Server=$HostName,$Port;Database=$Database;User Id=sa;Password=$SaPlain;TrustServerCertificate=True;Connection Timeout=$TimeoutSeconds;"

    # --- Versuch 1: Microsoft.Data.SqlClient (bevorzugt) ---
    try {
        $connType = [Microsoft.Data.SqlClient.SqlConnection]
        $conn = $connType::new($connStr)
        $conn.Open()
        return Invoke-SqlReader -Connection $conn -Query $Query -TimeoutSeconds $TimeoutSeconds
    }
    catch [System.Management.Automation.RuntimeException] {
        # Typ nicht verfuegbar - weiter zu Fallback 2
    }
    catch {
        # Connection-Fehler -> weiter zu sqlcmd
    }

    # --- Versuch 2: System.Data.SqlClient (Legacy) ---
    try {
        $connType = [System.Data.SqlClient.SqlConnection]
        $conn = $connType::new($connStr)
        $conn.Open()
        return Invoke-SqlReader -Connection $conn -Query $Query -TimeoutSeconds $TimeoutSeconds
    }
    catch [System.Management.Automation.RuntimeException] {
        # Typ nicht verfuegbar - weiter zu sqlcmd
    }
    catch {
        # Connection-/SQL-Fehler -> weiter zu sqlcmd
    }

    # --- Versuch 3: sqlcmd CLI-Fallback ---
    if (Test-CommandExists 'sqlcmd') {
        $output = sqlcmd -S "$HostName,$Port" -U sa -P $SaPlain -d $Database -Q $Query -h -1 -W 2>&1
        $outputText = ($output -join "`n").Trim()

        # SQL-Fehler erkennen
        if ($outputText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
            throw "SQL-Fehler: $outputText"
        }
        if ($LASTEXITCODE -ne 0) {
            throw "sqlcmd fehlgeschlagen (Exit $LASTEXITCODE): $outputText"
        }
        if ($outputText) {
            return [PSCustomObject]@{ RawOutput = $outputText }
        }
        return $null
    }

    throw "Keine SQL-Verbindung moeglich: Microsoft.Data.SqlClient, System.Data.SqlClient und sqlcmd nicht verfuegbar."
}

function Invoke-SqlReader {
    <#
    .SYNOPSIS Liest Ergebnisse aus einer offenen SqlConnection.
    .DESCRIPTION Gemeinsamer Reader fuer Microsoft.Data und System.Data.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Connection,
        [Parameter(Mandatory)][string]$Query,
        [int]$TimeoutSeconds = 10
    )

    try {
        $cmd = $Connection.CreateCommand()
        $cmd.CommandText = $Query
        $cmd.CommandTimeout = $TimeoutSeconds
        $reader = $cmd.ExecuteReader()

        $results = @()
        while ($reader.Read()) {
            $row = @{}
            for ($i = 0; $i -lt $reader.FieldCount; $i++) {
                $row[$reader.GetName($i)] = $reader.GetValue($i)
            }
            $results += [PSCustomObject]$row
        }

        $reader.Close()
        $Connection.Close()
        $Connection.Dispose()

        if ($results.Count -eq 1) { return $results[0] }
        return $results
    }
    catch {
        try { $Connection.Close(); $Connection.Dispose() } catch {}
        throw
    }
}

function New-SqlConnectionString {
    <#
    .SYNOPSIS Baut einen ConnectionString (ohne Passwort fuer Ausgabe).
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [string]$Database = 'master',
        [switch]$IncludePassword,
        [SecureString]$SaPassword
    )

    $base = "Server=$HostName,$Port;Database=$Database;User Id=sa;TrustServerCertificate=True;"

    if ($IncludePassword -and $SaPassword) {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
            [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))
        $result = "${base}Password=$plain;"
        $plain = $null
        return $result
    }

    return "${base}Password=***;"
}

function Invoke-LabSqlScript {
    <#
    .SYNOPSIS Fuehrt ein T-SQL-Skript gegen eine Lab-Instanz aus.
    .PARAMETER ScriptPath Pfad zur .sql-Datei.
    .PARAMETER HostName SQL-Server-Host.
    .PARAMETER Port SQL-Server-Port.
    .PARAMETER SaPassword SecureString.
    .PARAMETER Database Zieldatenbank.
    .PARAMETER KeepConnection
        Alle Batches in EINER Connection ausfuehren (USE, Temp-Tabellen bleiben erhalten).
        Nutzt sqlcmd -i oder .NET SqlConnection mit Reuse.
    .OUTPUTS PSCustomObject mit Success (bool), Message, Duration, Batches.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$Database = 'master',
        [switch]$KeepConnection
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "SQL-Skript nicht gefunden: $ScriptPath"
    }

    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        if ($KeepConnection) {
            # === SINGLE-CONNECTION-MODUS ===
            # sqlcmd -i verarbeitet GO-Batches nativ in einer Session
            # USE, Temp-Tabellen, Variablen bleiben erhalten
            $resolvedPath = Resolve-Path $ScriptPath
            $output = sqlcmd -S "$HostName,$Port" -U sa -P $saPlain `
                -d $Database -i "$resolvedPath" -b 2>&1
            $outputText = ($output -join "`n").Trim()

            $saPlain = $null
            $sw.Stop()

            if ($LASTEXITCODE -ne 0 -or $outputText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
                return [PSCustomObject]@{
                    Success  = $false
                    Message  = "Fehler in $(Split-Path $ScriptPath -Leaf): $outputText"
                    Duration = $sw.Elapsed
                    Batches  = 0
                }
            }

            # Batch-Count schaetzen (aus Datei)
            $sql = Get-Content $ScriptPath -Raw -Encoding utf8
            $batchCount = ($sql -split '(?mi)^\s*GO\b' | Where-Object { $_.Trim() }).Count

            return [PSCustomObject]@{
                Success  = $true
                Message  = "Skript erfolgreich: $(Split-Path $ScriptPath -Leaf)"
                Duration = $sw.Elapsed
                Batches  = $batchCount
            }
        }
        else {
            # === MULTI-CONNECTION-MODUS (Original) ===
            # Jeder Batch = neue Connection (USE hat keinen Effekt)
            $sql = Get-Content $ScriptPath -Raw -Encoding utf8
            $batches = $sql -split '(?mi)^\s*GO\b.*' | Where-Object { $_.Trim() }

            foreach ($batch in $batches) {
                Invoke-SqlQuery -HostName $HostName -Port $Port -SaPlain $saPlain `
                    -Query $batch -Database $Database -TimeoutSeconds 300
            }

            $saPlain = $null
            $sw.Stop()

            return [PSCustomObject]@{
                Success  = $true
                Message  = "Skript erfolgreich: $(Split-Path $ScriptPath -Leaf)"
                Duration = $sw.Elapsed
                Batches  = $batches.Count
            }
        }
    }
    catch {
        $saPlain = $null
        $sw.Stop()
        return [PSCustomObject]@{
            Success  = $false
            Message  = "Fehler in $(Split-Path $ScriptPath -Leaf): $_"
            Duration = $sw.Elapsed
            Batches  = 0
        }
    }
}
