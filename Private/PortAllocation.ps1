<#
.SYNOPSIS
    Serialisiert und validiert die Auswahl lokaler Labports.
.DESCRIPTION
    Ein reiner Portscan ist bei parallelen Provisionierungen nicht atomar: Mehrere
    Prozesse koennen denselben freien Port finden, bevor eine Runtime ihn bindet.
    Diese Hilfsfunktionen ermitteln deshalb belegte Ports runtimeuebergreifend und
    halten waehrend Portsuche und Containererstellung einen hostweiten Mutex.
#>

function Get-LabReservedSqlPorts {
    [CmdletBinding()]
    param()

    $ports = [System.Collections.Generic.HashSet[int]]::new()

    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        foreach ($listener in $listeners) {
            $null = $ports.Add([int]$listener.Port)
        }
    }
    catch {
        Write-Verbose "Aktive TCP-Listener konnten nicht vollstaendig gelesen werden: $($_.Exception.Message)"
    }

    foreach ($runtime in @('docker', 'podman')) {
        if (-not (Get-Command $runtime -ErrorAction SilentlyContinue)) {
            continue
        }

        try {
            $portLines = & $runtime ps -a --format '{{.Ports}}' 2>$null
            if ($LASTEXITCODE -ne 0) {
                continue
            }

            foreach ($line in @($portLines)) {
                foreach ($match in [regex]::Matches([string]$line, '(?<!\d)(\d{1,5})->1433(?:/tcp)?')) {
                    $port = [int]$match.Groups[1].Value
                    if ($port -ge 1 -and $port -le 65535) {
                        $null = $ports.Add($port)
                    }
                }
            }
        }
        catch {
            Write-Verbose "Portbelegung von '$runtime' konnte nicht gelesen werden: $($_.Exception.Message)"
        }
    }

    return @($ports | Sort-Object)
}

function Test-LabEndpointBinding {
    <#
    .SYNOPSIS
        Prueft einen expliziten SQL-Hostport ohne ihn zu reservieren oder zu aendern.
    .DESCRIPTION
        Liefert fuer die UI-Pruefung und den atomaren Runtime-Bindungsschritt
        einen stabilen Befund mit Besitzer und Grund. Containerzuordnungen werden
        vor generischen TCP-Listenern ausgewertet, damit die Diagnose moeglichst
        konkret bleibt.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateRange(1, 65535)]
        [int]$Port
    )

    foreach ($runtime in @('docker', 'podman')) {
        if (-not (Get-Command $runtime -ErrorAction SilentlyContinue)) {
            continue
        }

        try {
            $containerLines = & $runtime ps -a --format '{{.ID}}|{{.Names}}|{{.Ports}}' 2>$null
            if ($LASTEXITCODE -ne 0) {
                continue
            }

            foreach ($line in @($containerLines)) {
                $parts = ([string]$line).Split('|', 3)
                if ($parts.Count -lt 3 -or [string]::IsNullOrWhiteSpace($parts[2])) {
                    continue
                }
                $mappedPorts = @([regex]::Matches($parts[2], '(?<!\d)(\d{1,5})->1433(?:/tcp)?') |
                    ForEach-Object { [int]$_.Groups[1].Value })
                if ($Port -notin $mappedPorts) {
                    continue
                }

                return [PSCustomObject]@{
                    Port = $Port
                    Available = $false
                    Owner = "${runtime}:$($parts[1]) ($($parts[0]))"
                    Reason = "Der Port ist bereits als SQL-Hostport eines $runtime-Containers veroeffentlicht."
                }
            }
        }
        catch {
            Write-Verbose "Endpoint-Bindungen von '$runtime' konnten nicht gelesen werden: $($_.Exception.Message)"
        }
    }

    try {
        $listeners = @([System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
            Where-Object { [int]$_.Port -eq $Port })
        if ($listeners.Count -gt 0) {
            $owner = 'lokaler TCP-Listener'
            $getNetTcpConnection = Get-Command Get-NetTCPConnection -ErrorAction SilentlyContinue
            if ($getNetTcpConnection) {
                try {
                    $connection = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction Stop | Select-Object -First 1)
                    if ($connection.Count -gt 0 -and [int]$connection[0].OwningProcess -gt 0) {
                        $processId = [int]$connection[0].OwningProcess
                        $process = Get-Process -Id $processId -ErrorAction SilentlyContinue
                        $owner = if ($process) { "$($process.ProcessName) (PID $processId)" } else { "PID $processId" }
                    }
                }
                catch {
                    Write-Verbose "Besitzer des TCP-Listeners auf Port $Port konnte nicht ermittelt werden: $($_.Exception.Message)"
                }
            }

            return [PSCustomObject]@{
                Port = $Port
                Available = $false
                Owner = $owner
                Reason = "Auf $($listeners[0].Address):$Port lauscht bereits ein TCP-Endpunkt."
            }
        }
    }
    catch {
        Write-Verbose "Aktive TCP-Listener konnten fuer Port $Port nicht vollstaendig gelesen werden: $($_.Exception.Message)"
    }

    $probe = $null
    try {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Any, $Port)
        $probe.Start()
    }
    catch {
        return [PSCustomObject]@{
            Port = $Port
            Available = $false
            Owner = 'nicht ermittelbarer lokaler Endpunkt'
            Reason = "Der Betriebssystem-Bindungstest ist fehlgeschlagen: $($_.Exception.Message)"
        }
    }
    finally {
        if ($probe) {
            $probe.Stop()
        }
    }

    return [PSCustomObject]@{
        Port = $Port
        Available = $true
        Owner = $null
        Reason = 'Kein aktiver TCP-Listener und keine Docker-/Podman-SQL-Zuordnung gefunden.'
    }
}

function Find-LabAvailablePort {
    [CmdletBinding()]
    param(
        [int]$RangeStart = 14330,
        [int]$RangeEnd = 14399
    )

    if ($RangeStart -lt 1 -or $RangeEnd -gt 65535 -or $RangeStart -gt $RangeEnd) {
        throw "Ungueltiger Portbereich: $RangeStart-$RangeEnd"
    }

    $usedPorts = @(Get-LabReservedSqlPorts)

    for ($port = $RangeStart; $port -le $RangeEnd; $port++) {
        if ($port -in $usedPorts) {
            continue
        }

        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new(
                [System.Net.IPAddress]::Any,
                $port
            )
            $listener.Start()
            return $port
        }
        catch {
            continue
        }
        finally {
            if ($listener) {
                $listener.Stop()
            }
        }
    }

    throw "Kein freier Port im Bereich $RangeStart-$RangeEnd gefunden."
}

function Invoke-LabPortAllocationLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock]$Action,
        [int]$TimeoutSeconds = 30
    )

    if ($TimeoutSeconds -le 0) {
        throw 'TimeoutSeconds muss positiv sein.'
    }

    $mutexName = if ($IsWindows) {
        'Global\SQL_Server_Lab_Port_Allocation'
    }
    else {
        'SQL_Server_Lab_Port_Allocation'
    }

    $mutex = [System.Threading.Mutex]::new($false, $mutexName)
    $acquired = $false

    try {
        try {
            $acquired = $mutex.WaitOne([TimeSpan]::FromSeconds($TimeoutSeconds))
        }
        catch [System.Threading.AbandonedMutexException] {
            # Der vorherige Prozess wurde beendet. Der aktuelle Prozess besitzt den
            # Mutex jetzt und prueft die Portbelegung erneut vollstaendig.
            $acquired = $true
        }

        if (-not $acquired) {
            throw "PORT_ALLOCATION_LOCK_TIMEOUT: Der hostweite Port-Lock konnte innerhalb von ${TimeoutSeconds}s nicht erworben werden."
        }

        return & $Action
    }
    finally {
        if ($acquired) {
            try {
                $mutex.ReleaseMutex()
            }
            catch {
                # Der urspruengliche Fehler aus $Action darf nicht verdeckt werden.
            }
        }
        $mutex.Dispose()
    }
}
