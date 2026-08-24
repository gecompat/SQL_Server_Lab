<#
.SYNOPSIS
    SQL-Bereitschafts-, Query- und Skriptfunktionen fuer SQL_Server_Lab.
.DESCRIPTION
    Kapselt sqlcmd-Aufrufe, Timeouts, Fehlererkennung und die kurzzeitige
    SecureString-Konvertierung fuer lokale Labverbindungen.
#>

function Get-PodmanWindowsLocalhostDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][int]$Port
    )

    if (-not $IsWindows -or -not (Get-Command podman -ErrorAction SilentlyContinue)) {
        return $null
    }

    $containerNames = @(
        podman ps --filter "publish=$Port" --format '{{.Names}}' 2>$null |
            ForEach-Object { ([string]$_).Trim() } |
            Where-Object { $_ }
    )

    if ($LASTEXITCODE -ne 0 -or $containerNames.Count -eq 0) {
        return $null
    }

    foreach ($containerName in $containerNames) {
        $logs = podman logs --tail 200 $containerName 2>&1
        $logText = ($logs | ForEach-Object { [string]$_ }) -join "`n"
        if ($logText -notmatch 'SQL Server is now ready for client connections') {
            continue
        }

        $wslConfigPath = Join-Path $HOME '.wslconfig'
        $mirroredConfigured = $false
        if (Test-Path -LiteralPath $wslConfigPath -PathType Leaf) {
            $wslConfigText = Get-Content -LiteralPath $wslConfigPath -Raw -ErrorAction SilentlyContinue
            $mirroredConfigured = $wslConfigText -match '(?im)^\s*networkingMode\s*=\s*mirrored\s*$'
        }

        $configState = if ($mirroredConfigured) {
            'WSL mirrored networking ist konfiguriert; pruefen Sie, ob WSL und die Podman-Machine danach vollstaendig neu gestartet wurden.'
        }
        else {
            'WSL mirrored networking ist nicht erkennbar konfiguriert.'
        }

        return @"
Podman-Container '$containerName' meldet SQL-Bereitschaft, aber 127.0.0.1:$Port ist vom Windows-Host nicht erreichbar.
$configState

Empfohlene Konfiguration in %USERPROFILE%\.wslconfig:

[wsl2]
networkingMode=mirrored

Danach ausfuehren:

podman machine stop
wsl --shutdown
podman machine start

Hinweis: --user-mode-networking allein stellt die Localhost-Portweiterleitung nicht auf jedem Host her. Eine dynamische eth0-Adresse der Podman-WSL-Machine ist nur fuer Diagnosezwecke geeignet und kann sich nach einem Neustart aendern.
"@
    }

    return $null
}

function Resolve-PodmanWindowsHostName {
    [CmdletBinding()]
    param([string]$FallbackHostName = '127.0.0.1')

    if (-not $IsWindows -or
        -not (Get-Command podman -ErrorAction SilentlyContinue) -or
        -not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) {
        return $FallbackHostName
    }

    try {
        $connections = @(podman system connection list --format json 2>$null | ConvertFrom-Json)
        $defaultConnection = @($connections | Where-Object { $_.Default } | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or $defaultConnection.Count -ne 1) { return $FallbackHostName }

        $uriMatch = [regex]::Match([string]$defaultConnection[0].URI, ':(?<Port>[0-9]+)/')
        if (-not $uriMatch.Success) { return $FallbackHostName }

        $connectionPort = [int]$uriMatch.Groups['Port'].Value
        $machines = @(podman machine list --format json 2>$null | ConvertFrom-Json)
        $machine = @(
            $machines |
                Where-Object { $_.Running -and [int]$_.Port -eq $connectionPort } |
                Select-Object -First 1
        )
        if ($LASTEXITCODE -ne 0 -or $machine.Count -ne 1 -or [string]$machine[0].VMType -ne 'wsl') {
            return $FallbackHostName
        }

        $distributionName = "podman-$([string]$machine[0].Name)"
        $addressOutput = @(
            & wsl.exe -d $distributionName -u root -- ip -4 -o addr show dev eth0 scope global 2>$null |
                ForEach-Object { [string]$_ }
        ) -join "`n"
        if ($LASTEXITCODE -ne 0) { return $FallbackHostName }

        $addressMatch = [regex]::Match($addressOutput, '\binet\s+(?<Address>[0-9]+(?:\.[0-9]+){3})/')
        $parsedAddress = $null
        if ($addressMatch.Success -and
            [System.Net.IPAddress]::TryParse($addressMatch.Groups['Address'].Value, [ref]$parsedAddress) -and
            $parsedAddress.AddressFamily -eq [System.Net.Sockets.AddressFamily]::InterNetwork) {
            return $parsedAddress.ToString()
        }
    }
    catch {
        Write-LabWarning "Podman-WSL-Adresse konnte nicht aufgelöst werden; Fallback auf $FallbackHostName. $($_.Exception.Message)"
    }

    return $FallbackHostName
}

function Get-LabContainerReadinessDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('docker', 'podman')][string]$Provider,
        [Parameter(Mandatory)][string]$ContainerIdOrName,
        [switch]$IncludeLogs
    )

    if (-not (Get-Command $Provider -ErrorAction SilentlyContinue)) { return $null }
    try {
        $stateOutput = & $Provider inspect --format '{{.State.Status}}|{{.State.ExitCode}}|{{.State.OOMKilled}}|{{.State.Error}}' $ContainerIdOrName 2>&1
        if ($LASTEXITCODE -ne 0) { return $null }
        $stateText = (($stateOutput | ForEach-Object { [string]$_ }) -join ' ').Trim()
        $parts = @($stateText -split '\|', 4)
        $status = if ($parts.Count -gt 0) { [string]$parts[0] } else { 'unknown' }
        $exitCode = if ($parts.Count -gt 1) { [string]$parts[1] } else { '?' }
        $oomKilled = if ($parts.Count -gt 2) { [string]$parts[2] } else { '?' }
        $runtimeError = if ($parts.Count -gt 3) { [string]$parts[3] } else { '' }
        $message = "Containerstatus: $status; ExitCode: $exitCode; OOMKilled: $oomKilled"
        if (-not [string]::IsNullOrWhiteSpace($runtimeError)) { $message += "; RuntimeError: $runtimeError" }

        if ($IncludeLogs) {
            $logOutput = & $Provider logs --tail 80 $ContainerIdOrName 2>&1
            $logText = (($logOutput | ForEach-Object { [string]$_ }) -join "`n").Trim()
            if ($logText) {
                $logText = [regex]::Replace($logText, '(?i)((?:sa_)?password\s*[=:]\s*)\S+', '$1***')
                if ($logText.Length -gt 6000) { $logText = $logText.Substring($logText.Length - 6000) }
                $message += "`nContainer-Logs (letzte Zeilen):`n$logText"
            }
        }
        return [PSCustomObject]@{ Status = $status; Running = $status -eq 'running'; Message = $message }
    }
    catch { return $null }
}

function Wait-SqlReady {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [int]$TimeoutSeconds = 120,
        [int]$PollIntervalMilliseconds = 500,
        [int]$ExpectedMajorVersion = 0,
        [ValidateRange(2, 20)][int]$RequiredConsecutiveSuccesses = 2,
        [ValidateRange(1, 60)][int]$StabilitySeconds = 5,
        [ValidateSet('docker', 'podman')][string]$Provider,
        [string]$ContainerIdOrName
    )

    if (-not (Get-Command sqlcmd -ErrorAction SilentlyContinue)) {
        throw 'sqlcmd wurde nicht gefunden. Installieren Sie die SQL Server Command Line Tools.'
    }
    if ($Port -lt 1 -or $Port -gt 65535) {
        throw "Port '$Port' liegt ausserhalb des gueltigen TCP-Portbereichs."
    }
    if ($TimeoutSeconds -le 0 -or $PollIntervalMilliseconds -le 0) {
        throw 'TimeoutSeconds und PollIntervalMilliseconds muessen positiv sein.'
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
    $podmanDiagnosticChecked = $false
    $nextRuntimeCheckSeconds = 0
    $nextTransientLoginCheckSeconds = 15
    $consecutiveSuccesses = 0
    $readySinceSeconds = $null

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
                -l 2 `
                -Q $query `
                -h -1 `
                -W 2>&1
            $exitCode = $LASTEXITCODE
            $outputText = ($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join "`n"

            if ($exitCode -eq 0 -and $outputText -match '^\d+$') {
                $majorVersion = [int]$outputText
                if ($ExpectedMajorVersion -gt 0 -and $majorVersion -ne $ExpectedMajorVersion) {
                    $lastError = "Erwartete Major-Version $ExpectedMajorVersion, gefunden $majorVersion."
                    $consecutiveSuccesses = 0
                    $readySinceSeconds = $null
                }
                else {
                    if ($null -eq $readySinceSeconds) { $readySinceSeconds = $stopwatch.Elapsed.TotalSeconds }
                    $consecutiveSuccesses++
                    $stableForSeconds = $stopwatch.Elapsed.TotalSeconds - $readySinceSeconds
                    if ($consecutiveSuccesses -ge $RequiredConsecutiveSuccesses -and $stableForSeconds -ge $StabilitySeconds) {
                        $stopwatch.Stop()
                        Write-LabSuccess "SQL Server stabil bereit nach $($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s (Major: $majorVersion)"
                        return [PSCustomObject]@{
                            Ready        = $true
                            MajorVersion = $majorVersion
                            Duration     = $stopwatch.Elapsed
                            Message      = 'SQL Server stabil bereit'
                        }
                    }
                    $lastError = "SQL Server antwortet; Stabilisierung ${stableForSeconds}s/${StabilitySeconds}s, erfolgreiche Probes: $consecutiveSuccesses/$RequiredConsecutiveSuccesses."
                }
            }
            else {
                $lastError = if ($outputText) { $outputText } else { "sqlcmd Exitcode $exitCode" }
                $consecutiveSuccesses = 0
                $readySinceSeconds = $null
            }

            if ($Provider -and $ContainerIdOrName -and $stopwatch.Elapsed.TotalSeconds -ge $nextRuntimeCheckSeconds) {
                $runtimeDiagnostic = Get-LabContainerReadinessDiagnostic -Provider $Provider -ContainerIdOrName $ContainerIdOrName
                $nextRuntimeCheckSeconds = $stopwatch.Elapsed.TotalSeconds + 2
                if ($runtimeDiagnostic -and -not $runtimeDiagnostic.Running) {
                    $stopwatch.Stop()
                    $runtimeDiagnostic = Get-LabContainerReadinessDiagnostic -Provider $Provider -ContainerIdOrName $ContainerIdOrName -IncludeLogs
                    return [PSCustomObject]@{
                        Ready        = $false
                        MajorVersion = $null
                        Duration     = $stopwatch.Elapsed
                        Message      = "SQL-Container wurde vor der Bereitschaft beendet. $($runtimeDiagnostic.Message)"
                    }
                }
            }

            if ($Provider -and $ContainerIdOrName -and
                $stopwatch.Elapsed.TotalSeconds -ge $nextTransientLoginCheckSeconds -and
                $lastError -match '(?i)(login timeout|unable to complete login|18456)') {
                $nextTransientLoginCheckSeconds = $stopwatch.Elapsed.TotalSeconds + 15
                $transientDiagnostic = Get-LabContainerReadinessDiagnostic `
                    -Provider $Provider `
                    -ContainerIdOrName $ContainerIdOrName `
                    -IncludeLogs
                if ($transientDiagnostic -and $transientDiagnostic.Message -match '(?i)Error:\s*18456[\s\S]{0,120}State:\s*115') {
                    $stopwatch.Stop()
                    return [PSCustomObject]@{
                        Ready        = $false
                        MajorVersion = $null
                        Duration     = $stopwatch.Elapsed
                        Message      = "LAB_SQL_TRANSIENT_LOGIN_STATE_115: SQL-2025-Initialisierung blieb in einem transienten Loginzustand. $($transientDiagnostic.Message)"
                    }
                }
            }

            if (-not $podmanDiagnosticChecked -and $HostName -in @('127.0.0.1', 'localhost') -and $stopwatch.Elapsed.TotalSeconds -ge 5) {
                $podmanDiagnostic = Get-PodmanWindowsLocalhostDiagnostic -Port $Port
                if ($podmanDiagnostic) {
                    $stopwatch.Stop()
                    Write-LabWarning $podmanDiagnostic
                    return [PSCustomObject]@{
                        Ready        = $false
                        MajorVersion = $null
                        Duration     = $stopwatch.Elapsed
                        Message      = $podmanDiagnostic
                    }
                }
                $podmanDiagnosticChecked = $true
            }

            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }

        $stopwatch.Stop()
        if ($Provider -and $ContainerIdOrName) {
            $runtimeDiagnostic = Get-LabContainerReadinessDiagnostic -Provider $Provider -ContainerIdOrName $ContainerIdOrName -IncludeLogs
            if ($runtimeDiagnostic) { $lastError += "`n$($runtimeDiagnostic.Message)" }
        }
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

function Wait-LabDatabaseReady {
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$Database,
        [int]$TimeoutSeconds = 60,
        [int]$PollIntervalMilliseconds = 500
    )

    if ($Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "Database '$Database' ist ungueltig."
    }
    if ($TimeoutSeconds -le 0 -or $PollIntervalMilliseconds -le 0) {
        throw 'TimeoutSeconds und PollIntervalMilliseconds muessen positiv sein.'
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
        Write-LabInfo "Warte auf Datenbank-Bereitschaft (${HostName}:$Port/$Database, Timeout: ${TimeoutSeconds}s)..."

        while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
            $output = sqlcmd `
                -S "${HostName},${Port}" `
                -U sa `
                -P $saPlain `
                -C `
                -b `
                -l 2 `
                -d $Database `
                -Q 'SET NOCOUNT ON; SELECT 1;' `
                -h -1 `
                -W 2>&1
            $exitCode = $LASTEXITCODE
            $outputText = ($output | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join "`n"

            if ($exitCode -eq 0 -and $outputText -eq '1') {
                $stopwatch.Stop()
                Write-LabSuccess "Datenbank '$Database' bereit nach $($stopwatch.Elapsed.TotalSeconds.ToString('F1'))s"
                return [PSCustomObject]@{
                    Ready    = $true
                    Database = $Database
                    Duration = $stopwatch.Elapsed
                    Message  = 'Datenbank bereit'
                }
            }

            $lastError = if ($outputText) { $outputText } else { "sqlcmd Exitcode $exitCode" }
            Start-Sleep -Milliseconds $PollIntervalMilliseconds
        }

        $stopwatch.Stop()
        return [PSCustomObject]@{
            Ready    = $false
            Database = $Database
            Duration = $stopwatch.Elapsed
            Message  = "Datenbank '$Database' nach ${TimeoutSeconds}s nicht bereit. Letzter Fehler: $lastError"
        }
    }
    finally {
        $saPlain = $null
    }
}

function Test-LabSqlcmdFailure {
    <#
    .SYNOPSIS
        Einheitliche Fehlererkennung fuer sqlcmd-Aufrufe.
    .DESCRIPTION
        Ein Aufruf gilt als fehlgeschlagen, wenn der Exitcode ungleich 0 ist
        (durch -b bei Fehlerschwere > 10) oder die Ausgabe eine Fehlerschwere
        >= 11 meldet. Beide sqlcmd-Pfade (Query und Single-Connection-Skript)
        verwenden dieselbe Regel, damit sie nicht auseinanderlaufen.
    #>
    [CmdletBinding()]
    param(
        [int]$ExitCode,
        [string]$OutputText
    )

    return ($ExitCode -ne 0 -or $OutputText -match 'Msg \d+, Level (1[1-9]|[2-9]\d)')
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

    $loginTimeoutSeconds = [Math]::Max(2, [Math]::Min($TimeoutSeconds, 30))
    $output = sqlcmd `
        -S "${HostName},${Port}" `
        -U sa `
        -P $SaPlain `
        -C `
        -d $Database `
        -Q $Query `
        -b `
        -l $loginTimeoutSeconds `
        -t $TimeoutSeconds `
        -W 2>&1
    $exitCode = $LASTEXITCODE
    $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"

    if (Test-LabSqlcmdFailure -ExitCode $exitCode -OutputText $outputText) {
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
        [switch]$SkipDatabaseReadyCheck,
        [int]$TimeoutSeconds = 300
    )

    if (-not (Test-Path -LiteralPath $ScriptPath -PathType Leaf)) {
        throw "SQL-Skript nicht gefunden: $ScriptPath"
    }
    if ($Database -notmatch '^[A-Za-z][A-Za-z0-9_]{0,127}$') {
        throw "Database '$Database' ist ungueltig."
    }

    if ($Database -ne 'master' -and -not $SkipDatabaseReadyCheck) {
        $databaseReadiness = Wait-LabDatabaseReady `
            -HostName $HostName `
            -Port $Port `
            -SaPassword $SaPassword `
            -Database $Database `
            -TimeoutSeconds ([Math]::Min($TimeoutSeconds, 60))
        if (-not $databaseReadiness.Ready) {
            return [PSCustomObject]@{
                Success  = $false
                Batches  = 0
                Duration = $databaseReadiness.Duration
                Message  = $databaseReadiness.Message
            }
        }
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
    $tempScriptPath = $null

    try {
        if ($KeepConnection) {
            # Gesamtes Skript in einem sqlcmd-Prozess: alle GO-Batches teilen
            # sich dieselbe Session (USE, temporaere Objekte und SET-Optionen
            # bleiben ueber GO hinweg erhalten). -t wirkt pro Statement.
            #
            # Der Adaptervertrag fuehrt ausschliesslich reines T-SQL aus. Die
            # sqlcmd-Skriptebene wird daher vollstaendig deaktiviert:
            #   -X1  deaktiviert :!!, :r, :ed und den Zugriff auf Host-Umgebungs-
            #        variablen und bricht ab, sobald ein solcher Befehl auftritt
            #        (verhindert Shell-Ausfuehrung und das Einbinden von Dateien
            #        ausserhalb des Adapter-Roots, die der Resolver nie sieht);
            #   -x   deaktiviert die $(var)-Substitution, damit T-SQL mit '$('
            #        literal an den Server geht statt als Skriptvariable.
            # Das Skript wird zusaetzlich als UTF-8 mit BOM in eine temporaere
            # Datei geschrieben, damit sqlcmd den Inhalt plattformunabhaengig als
            # UTF-8 erkennt (ohne BOM nimmt der ODBC-Client unter Windows die
            # ANSI-Codepage an und verstuemmelt Nicht-ASCII-Zeichen).
            $tempScriptPath = [System.IO.Path]::GetTempFileName()
            [System.IO.File]::WriteAllText($tempScriptPath, $scriptContent, [System.Text.UTF8Encoding]::new($true))

            $output = sqlcmd `
                -S "${HostName},${Port}" `
                -U sa `
                -P $saPlain `
                -C `
                -d $Database `
                -i $tempScriptPath `
                -b `
                -X1 `
                -x `
                -t $TimeoutSeconds `
                -W 2>&1
            $exitCode = $LASTEXITCODE
            $outputText = ($output | ForEach-Object { [string]$_ }) -join "`n"
            $stopwatch.Stop()

            if (Test-LabSqlcmdFailure -ExitCode $exitCode -OutputText $outputText) {
                return [PSCustomObject]@{
                    Success  = $false
                    Batches  = 0
                    Duration = $stopwatch.Elapsed
                    Message  = "Skript fehlgeschlagen (Single-Connection): $outputText"
                }
            }

            return [PSCustomObject]@{
                Success  = $true
                Batches  = $batches.Count
                Duration = $stopwatch.Elapsed
                Message  = "Skript erfolgreich ausgefuehrt: $(Split-Path $ScriptPath -Leaf)"
            }
        }

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
        $failureContext = if ($KeepConnection) {
            'Skript fehlgeschlagen (Single-Connection)'
        }
        else {
            "Skript fehlgeschlagen in Batch $($executedBatches + 1)"
        }
        return [PSCustomObject]@{
            Success  = $false
            Batches  = $executedBatches
            Duration = $stopwatch.Elapsed
            Message  = "${failureContext}: $($_.Exception.Message)"
        }
    }
    finally {
        $saPlain = $null
        if ($tempScriptPath -and (Test-Path -LiteralPath $tempScriptPath)) {
            Remove-Item -LiteralPath $tempScriptPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Test-LabDatabaseExists {
    <#
    .SYNOPSIS
        Prueft read-only ob eine Datenbank auf der Zielinstanz existiert.
    #>
    [CmdletBinding()]
    param(
        [string]$HostName = '127.0.0.1',
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][SecureString]$SaPassword,
        [Parameter(Mandatory)][string]$Database
    )

    Assert-LabSqlIdentifier -Value $Database -Label 'Database'

    $saPlain = ConvertFrom-LabSecureString -SecureString $SaPassword
    try {
        $output = Invoke-SqlQuery `
            -HostName $HostName `
            -Port $Port `
            -SaPlain $saPlain `
            -Query "SET NOCOUNT ON; SELECT CASE WHEN DB_ID(N'$Database') IS NULL THEN 0 ELSE 1 END;" `
            -Database 'master'
        return (($output | ForEach-Object { ([string]$_).Trim() }) -contains '1')
    }
    finally {
        $saPlain = $null
    }
}
