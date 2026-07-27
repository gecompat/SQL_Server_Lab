<#
.SYNOPSIS
    Serialisiert die Auswahl und Bindung lokaler Labports.
.DESCRIPTION
    Ein reiner Portscan ist bei parallelen Provisionierungen nicht atomar: Mehrere
    Prozesse koennen denselben freien Port finden, bevor eine Runtime ihn bindet.
    Diese Hilfsfunktion haelt deshalb einen hostweiten Mutex waehrend Portsuche und
    Containererstellung. Docker und Podman verwenden absichtlich denselben Lock.
#>

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
            # Mutex jetzt und kann die Portbelegung erneut vollstaendig pruefen.
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
