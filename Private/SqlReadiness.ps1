<#
.SYNOPSIS
    SQL-Bereitschafts-, Query- und Skriptfunktionen fuer SQL_Server_Lab.
.DESCRIPTION
    Kapselt sqlcmd-Aufrufe, Timeouts, Fehlererkennung und die kurzzeitige
    SecureString-Konvertierung fuer lokale Labverbindungen.
#>

function Wait-SqlReady {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [int]$TimeoutSeconds = 120,
        [int]$PollIntervalSeconds = 3,
        [int]$ExpectedMajorVersion = 0
    )

    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        throw 'sqlcmd wurde nicht gefunden. Installieren Sie die SQL Server Command Line Tools.'
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "Port '$Port' liegt ausserhalb des gueltigen TCP-Portbereichs."
    }
    if ($TimeoutSeconds -le 0 -or $PollIntervalSeconds -le 0) {
        throw 'TimeoutSeconds und PollIntervalSeconds muessen positiv sein.'
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $lastError = ''

    try {
        Write-LabInfo "Warte auf SQL-Bereitschaft (${HostName}:$Port, Timeout: ${TimeoutSeconds}s)..."

        while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $query = "SET NOCOUNT ON; SELECT CAST(SERVERPROPERTY('ProductMajorVersion') AS varchar(10));"
            $output = sqlcmd `
                -S "${HostName},${Port}" `
                -U sa `
                -P $saPlain `
                -C `
                -b `
                -Q $query `
                -h -1 `
                -W 2>&1
            $exitCode = $LASTEXITCODE
            $outputText = ($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join "`n"

            if ($exitCode -eq 0 -and $outputText -match '^\d+$') {
                $majorVersion = [int]$outputText
                if ($ExpectedMajorVersion -gt 0 -and $majorVersion -ne $ExpectedMajorVersion) {
                    $lastError = "Erwartete Major-Version $ExpectedMajorVersion, gefunden $majorVersion."
                }
                else {
                    $stopwatch.Stop()
                    Write-LabSuccess "SQL Server bereit nach $($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s (Major: $majorVersion)"
                    return [PSCustomObject]@{
                        Ready        = $true
                        MajorVersion = $majorVersion
                        Duration     = $stopwatch.Elapsed
                        Message      = 'SQL Server bereit'
                    }
                }
            }
            else {
                $lastError = if ($outputText) { $outputText } else { "sqlcmd Exitcode $exitCode" }
            }

            Start-Sleep -Seconds $PollIntervalSeconds
        }

        $stopwatch.Stop()
        return [PSCustomObject]@{
            Ready        = $false
            MajorVersion = $null
            Duration     = $stopwatch.Elapsed
            Message      = "SQL Server nach ${TimeoutSeconds}s nicht bereit. Letzter Fehler: $lastError"
        }
    }
    finally {
        $saPlain = $null
    }
}

function Invoke-SqlQuery {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$SaPlain,
        [Parameter(Mandatory)][string]$Query,
        [string]$Database = 'master',
        [int]$TimeoutSeconds = 30
    )

    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        throw 'sqlcmd wurde nicht gefunden.'
    }
    if ($Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "Database '$Database' ist ungueltig."
    }

    $output = sqlcmd `
        -S "${HostName},${Port}" `
        -U sa `
        -P $SaPlain `
        -C `
        -d $Database `
        -Q $Query `
        -b `
        -t $TimeoutSeconds `
        -W 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"

    if ($exitCode -ne 0 -or $outputText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)') {
        throw "SQL-Query fehlgeschlagen: $outputText"
    }

    return $output
}

function New-SqlConnectionString {
    <#
    .SYNOPSIS
        Erzeugt einen SQL-Connection-String fuer eine Labinstanz.
    .DESCRIPTION
        Gibt standardmaessig nur einen maskierten Passwortplatzhalter aus.
        Ein Klartextpasswort wird nur bei explizitem -IncludePassword und
        uebergebenem SecureString kurzzeitig erzeugt.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [string]$Database = 'master',
        [switch]$IncludePassword,
        [SecureString]$SaPassword
    )

    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "Port '$Port' liegt ausserhalb des gueltigen TCP-Portbereichs."
    }
    if ($Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "Database '$Database' ist ungueltig."
    }

    $base = "Server=${HostName},${Port};Database=${Database};User Id=sa;TrustServerCertificate=True;"
    if (-not $IncludePassword) {
        return "${base}Password=***;"
    }
    if (-not $SaPassword) {
        throw '-SaPassword ist erforderlich, wenn -IncludePassword verwendet wird.'
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $plain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        return "${base}Password=${plain};"
    }
    finally {
        $plain = $null
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }
}

function Invoke-LabSqlScript {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [string]$Database = 'master',
        [switch]$KeepConnection,
        [int]$TimeoutSeconds = 300
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "SQL-Skript nicht gefunden: $ScriptPath"
    }
    if ($Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "Database '$Database' ist ungueltig."
    }

    $scriptContent = Get-Content -LiteralPath $ScriptPath -Raw -Encoding utf8
    $batches = @(
        [regex]::Split($scriptContent, '(?im)^\s*GO\s*(?:--.*)?$') |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    )

    if ($batches.Count -eq 0) {
        return [PSCustomObject]@{
            Success  = $true
            Batches  = 0
            Duration = [TimeSpan]::Zero
            Message  = 'Skript enthaelt keine ausfuehrbaren Batches.'
        }
    }

    $bstr = [System.Runtime.InteropServices.Marshal]::SecureStringToBSTR($SaPassword)
    try {
        $saPlain = [System.Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
    }
    finally {
        [System.Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
    }

    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $executedBatches = 0

    try {
        foreach ($batch in $batches) {
            $null = Invoke-SqlQuery `
                -HostName $HostName `
                -Port $Port `
                -SaPlain $saPlain `
                -Query $batch `
                -Database $Database `
                -TimeoutSeconds $TimeoutSeconds
            $executedBatches++
        }

        $stopwatch.Stop()
        return [PSCustomObject]@{
            Success  = $true
            Batches  = $executedBatches
            Duration = $stopwatch.Elapsed
            Message  = "Skript erfolgreich ausgefuehrt: $(Split-Path $ScriptPath -Leaf)"
        }
    }
    catch {
        $stopwatch.Stop()
        return [PSCustomObject]@{
            Success  = $false
            Batches  = $executedBatches
            Duration = $stopwatch.Elapsed
            Message  = "Skript fehlgeschlagen in Batch $($executedBatches + 1): $($_.Exception.Message)"
        }
    }
    finally {
        $saPlain = $null
    }
}
