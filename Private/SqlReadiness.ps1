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
                $majorVersion = [int]$result.MajorVersion
                $fullVersion = $result.FullVersion

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
    .DESCRIPTION Verwendet System.Data.SqlClient (Framework) oder
                 Microsoft.Data.SqlClient (Core). Fallback auf sqlcmd.
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

    # .NET SqlClient
    try {
        $conn = [System.Data.SqlClient.SqlConnection]::new($connStr)
        $conn.Open()
        $cmd = $conn.CreateCommand()
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
        $conn.Close()
        $conn.Dispose()

        if ($results.Count -eq 1) { return $results[0] }
        return $results
    }
    catch {
        # Fallback: sqlcmd (falls installiert)
        if (Test-CommandExists 'sqlcmd') {
            $output = sqlcmd -S "$HostName,$Port" -U sa -P $SaPlain -Q $Query -h -1 -W 2>&1
            if ($LASTEXITCODE -eq 0) {
                # Einfaches Parsing fuer Single-Row-Ergebnisse
                return [PSCustomObject]@{ RawOutput = ($output -join "`n").Trim() }
            }
        }
        throw $_
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
    .OUTPUTS PSCustomObject mit Success (bool), Message, Duration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$Database = 'master'
    )

    if (-not (Test-Path $ScriptPath)) {
        throw "SQL-Skript nicht gefunden: $ScriptPath"
    }

    $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringAuto(
        [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword))

    $sql = Get-Content $ScriptPath -Raw -Encoding utf8
    $sw = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        # GO-Batches aufteilen
        $batches = $sql -split '(?m)^\s*GO\s*

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
 | Where-Object { $_.Trim() }

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
