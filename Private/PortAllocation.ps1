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
